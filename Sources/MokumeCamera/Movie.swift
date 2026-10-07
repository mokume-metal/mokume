// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import MokumeCore
import MokumeDiagnostics

/// 動画ファイルを流す入り口。``Sketch/createVideo(_:)`` が作り、走っているスケッチへ足す。
///
/// いま映っているコマは ``image`` に入り、普通の ``Image`` として描ける (貼る・効果を通す・
/// 立体に貼る — [ADR-0028] 決定 5)。毎フレーム呼ぶ口は無い。`draw()` の前に、そのフレームの
/// 位置のコマが ``image`` へ書かれている。
///
/// 流さずに、マウスの横の位置で映すコマを選ぶ:
///
/// ```swift
/// final class Scrub: Sketch {
///     var clip: Movie?
///     func setup() { clip = try? createVideo("assets/clip.mov") }
///     func draw() {
///         guard let clip else { return }
///         image(clip.image, 0, 0, width, height)
///         clip.jump(mouseX / width * clip.duration)
///     }
/// }
/// ```
///
/// ## 位置はスケッチの時刻で決まる
///
/// 流している間の位置は、流し始めてからスケッチの ``Sketch/time`` が進んだぶんだけ進む。
/// 実時間の再生時計は持たない。だから `mokume run` では実時間で流れ、`mokume render`
/// (固定の時計) で書き出すと**同じフレーム番号にはいつも同じコマが出る** ([ADR-0028] 決定 7)。
/// スケッチの時刻を止めれば (``Sketch/pauseTime()``) 動画も止まる。
///
/// 位置に映るのは、表示の時刻がその位置以下で最も遅いコマである。コマの境目の手前 1 ms までは
/// 次のコマとみなす — スケッチの時刻は単精度なので、境目にちょうど乗るはずの時刻がわずかに
/// 割ることがあり、そのたびに前のコマが出るのを防ぐ。
///
/// ## 操作
///
/// | Processing の `Movie` | ここ |
/// | --- | --- |
/// | `play()` | ``play()`` |
/// | `loop()` | ``loop()`` |
/// | `pause()` | ``pause()`` |
/// | `jump(where)` | ``jump(_:)`` |
/// | `time()` / `duration()` | ``time`` / ``duration`` |
/// | `available()` / `read()` | 要らない。`draw()` の前に ``image`` が書かれ、新しいコマかは ``isNewFrame`` |
///
/// ``play()``・``loop()``・``jump(_:)`` は次のフレームで効く (そのフレームに、始めた位置・
/// 飛んだ先のコマが出る)。``pause()`` はすぐ効き、いま映っているコマで止まる。音は鳴らさない。
///
/// ## 読めなくなったとき
///
/// 途中が壊れていて読めなくなっても、フレームの間は投げない ([ADR-0020] 決定 5)。最後に
/// 読めたコマが ``image`` に残り、``state`` が ``SourceState/disconnected`` になり、理由を
/// 1 度だけ知らせる。手前へ戻る (ループの継ぎ目・``jump(_:)``) か、読めなくなった所から
/// 1 秒より先へ進むと読み直し、読めれば ``SourceState/running`` へ戻る。
///
/// [ADR-0020]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0020-api-naming-and-surface.md
/// [ADR-0028]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0028-external-inputs.md
public final class Movie: Inlet {
    /// いま映っているコマ。大きさは動画の大きさで、変わらない。
    public let image: Image
    /// このフレームで新しいコマが ``image`` に書かれたか。
    public private(set) var isNewFrame = false

    let input: ExternalInput<DisplayImage>
    private let reader: MovieReader
    private var playhead: Playhead
    private weak var owner: (any Sketch)?
    private let warn: (String) -> Void
    private var warnedRead = false
    private var warnedJump = false

    init(
        image: Image, reader: MovieReader, name: String, owner: (any Sketch)?,
        warn: @escaping (String) -> Void = Diagnostics.warn
    ) {
        self.image = image
        self.reader = reader
        self.owner = owner
        self.warn = warn
        playhead = Playhead(duration: reader.duration)
        input = ExternalInput(name: name, state: .running)
    }

    /// 出どころの状態。読めている間は ``SourceState/running``。
    public var state: SourceState { input.state }
    /// 最後に新しいコマが届いたフレーム。まだ 1 枚も届いていなければ `nil`。
    public var lastArrival: Arrival? { input.lastArrival }
    /// 幅 (画素)。``image`` の幅と同じ。
    public var width: Int { image.width }
    /// 高さ (画素)。``image`` の高さと同じ。
    public var height: Int { image.height }
    /// 長さ (秒)。
    public var duration: Float { Float(reader.duration) }
    /// いまの位置 (秒)。0 から ``duration`` まで。``jump(_:)`` を頼んだ後なら、その飛び先。
    public var time: Float { Float(playhead.reported) }

    /// 1 度だけ流す。終わりのコマで止まる。
    ///
    /// 止めた位置から流し、終わりまで映していたなら頭から流す。``loop()`` で流していたなら、
    /// 今回の終わりで止まる。
    public func play() {
        playhead.play()
    }

    /// 繰り返し流す。終わりまで行けば頭へ戻る。
    ///
    /// 止めた位置から流し、終わりまで映していたなら頭から流す。
    public func loop() {
        playhead.loop()
    }

    /// いま映っているコマで止める。``play()``・``loop()`` で同じ位置から流し直せる。
    public func pause() {
        playhead.pause()
    }

    /// `seconds` 秒の位置へ飛ぶ。次のフレームにその位置のコマが出る。
    ///
    /// 流している間なら、そこから流れ続ける。0 より前は頭、``duration`` より後は終わりへ
    /// 寄せる。数でない値 (`.nan`・無限) は位置を変えず、1 度だけ知らせる。
    public func jump(_ seconds: Float) {
        guard playhead.jump(to: Double(seconds)) else {
            guard !warnedJump else { return }
            warnedJump = true
            return warn("jump(): \(seconds) is not a time, so the video stays where it is")
        }
    }

    // MARK: - Inlet

    public func supply() {
        let position = playhead.advance(to: Double(owner?.time ?? 0))
        do {
            if let picture = try reader.picture(at: position) { input.send(picture) }
            if input.state == .disconnected { input.setState(.running) }
        } catch {
            input.setState(.disconnected)
            noticeOnce(error, at: position)
        }
        if let picture = input.take() {
            image.write(picture)
            isNewFrame = true
        } else {
            isNewFrame = false
        }
    }

    public func close() {
        reader.close()
        input.setState(.stopped)
    }

    public var report: SourceReport? { input.report }

    /// 読めなくなったことを 1 度だけ言う。毎フレーム走る経路なので投げない (ADR-0020 決定 5)。
    private func noticeOnce(_ failure: MovieReader.Failure, at position: Double) {
        guard !warnedRead else { return }
        warnedRead = true
        warn(
            "Could not read a frame of \"\(reader.path)\" at \(position) s (\(failure.reason)). "
                + "The last frame that was read stays on screen. It tries again when the video goes "
                + "back (a loop or jump()) or moves more than a second past this point")
    }
}
