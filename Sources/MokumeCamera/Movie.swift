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
///     func setup() throws { clip = try createVideo("assets/clip.mov") }
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
/// 流している間の位置は、流し始めてからスケッチの ``SketchPart/time`` が進んだぶん (に ``speed(_:)``
/// を掛けたぶん) だけ進む。実時間の再生時計は持たない。だから `mokume run` では実時間で流れ、`mokume render`
/// (固定の時計) で書き出すと**同じフレーム番号にはいつも同じコマが出る** ([ADR-0028] 決定 7)。
/// スケッチの時刻を止めれば (``SketchPart/pauseTime()``) 動画も止まる。
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
/// | `speed(rate)` | ``speed(_:)`` |
/// | `time()` / `duration()` | ``time`` / ``duration`` |
/// | `available()` / `read()` | 要らない。`draw()` の前に ``image`` が書かれ、新しいコマかは ``isNewFrame`` |
///
/// ``play()``・``loop()``・``jump(_:)`` は次のフレームで効く (そのフレームに、始めた位置・
/// 飛んだ先のコマが出る)。``pause()`` はすぐ効き、いま映っているコマで止まる。音は鳴らさない。
///
/// ## 向き
///
/// 縦に撮った動画など、ファイルが回転の印 (`preferredTransform`) を持っていれば、その向きを当てて
/// 映す。``width``・``height``・``image`` の大きさは、当てた後 (見えている向き) の値である。
/// 90° 刻みの回転と左右・上下の反転を当てる。それ以外の変換 (斜めの回転など) は当てず、
/// 記録された向きのまま映す。
///
/// ## 外して足し直す
///
/// ``SketchPart/detach(_:)-(Inlet)`` で外した動画は、``SketchPart/attach(_:)-(Inlet)`` で足し直せる。足し直すと
/// また ``image`` が書かれ、``state`` も ``SourceState/running`` に戻る (外している間は
/// ``SourceState/stopped``)。
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
    private var warnedSpeed = false

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
    /// 幅 (画素)。``image`` の幅と同じで、回転の印を当てた後の値 (縦に撮った動画では、記録された幅ではなく高さ)。
    public var width: Int { image.width }
    /// 高さ (画素)。``image`` の高さと同じで、回転の印を当てた後の値。
    public var height: Int { image.height }
    /// 長さ (秒)。
    public var duration: Float { Float(reader.duration) }
    /// いまの位置 (秒)。0 から ``duration`` まで。``jump(_:)`` を頼んだ後なら、その飛び先。
    ///
    /// **時刻を指定した観測の枚の `draw()` の中では、映しているコマの位置**を返す — そこで読む
    /// ``SketchPart/time`` が観測の秒なのと揃う。再生の状態は作者の時計に沿って進んでいて、
    /// 観測の後の枚はそこから続く ([#2357](https://github.com/mokume-metal/mokume/issues/2357))。
    public var time: Float {
        let shown = owner?.time ?? 0
        // 観測の枚の `draw()` の中だけ、見せる時刻と作者の時計の秒が違う。飛ぶよう頼んだ後は飛び先
        guard let owner, shown != owner.authorTime, playhead.reported == playhead.position else {
            return Float(playhead.reported)
        }
        return Float(playhead.position(at: Double(shown)))
    }

    /// 1 度だけ流す。終わりのコマで止まる。
    ///
    /// 止めた位置から流し、終わりまで映していたなら頭から流す。``jump(_:)`` で終わりへ飛ばした後も、
    /// 同じフレームで呼んでも頭から流す。``loop()`` で流していたなら、今回の終わりで止まる。
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
    /// 寄せる (``duration`` を渡せば、長さが単精度で表せない値でも、終わりへ着く)。数でない値 (`.nan`・無限) は位置を変えず、1 度だけ知らせる。
    public func jump(_ seconds: Float) {
        guard playhead.jump(to: playhead.landing(seconds)) else {
            guard !warnedJump else { return }
            warnedJump = true
            return warn("jump(): \(seconds) is not a time, so the video stays where it is")
        }
    }

    /// 流す速さを `rate` 倍にする。1 が等倍 (最初の値)、2 なら倍速、0.5 なら半分、0 なら流れが止まる。
    ///
    /// 位置が進む速さだけを変える。流している間に変えても、位置は跳ばない (変えたフレームの位置から、
    /// 新しい速さで進み直す) ので、毎フレーム呼んでもよい。同じ値を渡し続けても位置は変わらない。
    /// スケッチの時刻を止めれば (``SketchPart/pauseTime()``) 動画も止まる点は変わらない。
    ///
    /// **`draw()` の中で変えた枚の ``time`` は、変える前の速さで数えた値のまま** で、新しい速さは
    /// 次の枚から効く。
    ///
    /// 0 以上の有限の値だけを受ける。**負 (逆再生)・数でない値 (`.nan`)・無限は受けず、速さを変えない**
    /// — 1 度だけ知らせる。
    ///
    /// <!-- example: 文脈 var movie: Movie! -->
    /// ```swift
    /// movie.speed(map(mouseX, 0, width, 0.25, 4))   // マウスの横の位置で 0.25 倍から 4 倍
    /// ```
    public func speed(_ rate: Float) {
        guard playhead.setSpeed(Double(rate)) else {
            guard !warnedSpeed else { return }
            warnedSpeed = true
            return warn("speed(): \(rate) is not a speed (0 or more), so the speed stays as it is")
        }
    }

    // MARK: - Inlet

    public func open() throws {
        // 足し直しでも呼ばれる (``close()`` の後の 2 度目)。外していた間の ``SourceState/stopped`` を戻す
        // (読み手は、止めた後でも次に読むときに開き直すので、ここでは何もしない)。読めなくなって
        // いた (``SourceState/disconnected``) のは、そのまま ``supply()`` が読み直して戻す
        if input.state == .stopped { input.setState(.running) }
    }

    public func supply() {
        // **状態は作者の時計の秒で進め、映すコマは観測の秒で決める** (#2357)。時刻を指定した観測の枚の
        // 指定秒を再生位置・起点として積むと、観測の後に動画が終わりで止まったまま・頭に貼り付く。
        // 観測でない枚では二つの秒は同じで、映す位置は進めた位置そのものである
        let shown = owner?.time ?? 0
        let author = owner?.authorTime ?? shown
        let advanced = playhead.advance(to: Double(author))
        let position = shown == author ? advanced : playhead.position(at: Double(shown))
        do {
            if let picture = try reader.picture(at: position) { input.send(picture) }
            // 読めなくなって、読み直しを試す位置にまだ届いていない間は、試さずに `nil` が返るだけで
            // 読めてはいない。戻すのは読み直して読めたフレームだけ (#2908)
            if input.state == .disconnected, !reader.isWaitingToRetry { input.setState(.running) }
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
