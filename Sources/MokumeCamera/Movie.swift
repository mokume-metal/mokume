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
/// | `volume(v)` | 持たない。同じファイルを `loadSound` で鳴らす (下の「音」・[#3452](https://github.com/mokume-metal/mokume/issues/3452)) |
/// | `available()` / `read()` | 要らない。`draw()` の前に ``image`` が書かれ、新しいコマかは ``isNewFrame`` |
///
/// ``play()``・``loop()``・``jump(_:)`` は次のフレームで効く (そのフレームに、始めた位置・
/// 飛んだ先のコマが出る)。``pause()`` はすぐ効き、いま映っているコマで止まる。音は鳴らさない (下の「音」)。
///
/// ## 音
///
/// `Movie` は音を鳴らさない。動画に音があれば、**同じファイルを `loadSound` でも開いて鳴らし**、`jump(_:)` で
/// 映像の位置へ合わせる。`loadSound` は動画の容器 (`.mov`・`.mp4`) の音声トラックを読める。
///
/// ```swift
/// final class Talk: Sketch {
///     var clip: Movie?
///     var song: SoundFile?
///     var lastTime: Float = 0
///     func setup() throws {
///         clip = try createVideo("assets/talk.mov")
///         // 音声トラックの無い動画は `loadSound` が断る。`try?` なら nil のままで、映像だけ流す
///         song = try? loadSound("assets/talk.mov")
///         clip?.play()
///         song?.play()
///     }
///     func draw() {
///         guard let clip else { return }
///         image(clip.image, 0, 0, width, height)
///         // 映像が動いているときだけ、鳴っている音を合わせる。映像が止まっている間 (`clip.pause()`・
///         // `pauseTime()`) は位置が凍っていて、合わせると音を凍った位置へ引き戻し続ける
///         let moving = clip.time != lastTime
///         lastTime = clip.time
///         guard moving, let song, song.isPlaying else { return }
///         // 音が映像の位置から 0.1 秒より外れたら、音を合わせ直す。`jump` は次のフレームの頭で効くので、
///         // 飛び先は 1 フレーム先 (`deltaTime`)。鳴り終えた音 (位置は 0 へ戻る) には打たない (`isPlaying`)
///     }
///     func keyPressed() {
///         // 止めるときは両方を止める (映像だけ止めても、音は鳴り続ける)。止まっている間、上の合わせ直しは働かない
///         clip?.pause()
///         song?.pause()
///     }
/// }
/// ```
///
/// - **映像と音の同期は作品が持つ。** `Movie` の位置は ``SketchPart/time`` に従い、音の位置は音の時計 (書き出しでは
///   フレームの窓) に従う。**``SketchPart/pauseTime()`` で止まるのは映像だけ**で、音は鳴り続ける。`clip.pause()` も
///   映像だけを止める — 止めるなら `song.pause()` も、流し直すなら `clip.play()` と `song.play()` を呼ぶ。映像が
///   止まっている間は `clip.time` が凍るので、上の例のように、動いているときだけ合わせる (止まった位置へ音を
///   引き戻し続けない)
/// - **``speed(_:)`` を 1 以外にすると、音は合わない。** 音の速さを変える口はまだ無い
///   ([#3473](https://github.com/mokume-metal/mokume/issues/3473))
/// - **`song.jump(_:)` は次のフレームの頭で効く**ので、`jump(clip.time)` で合わせると、飛んだ後の音は映像より 1 フレーム
///   (1 / fps 秒) 遅れる (30・60 fps で測った)。上の例のように `clip.time + deltaTime` へ飛べば揃う。合わせ直す閾
///   (例の 0.1 秒) は、`jump(clip.time)` で合わせる書き方では、この 1 フレームより大きく取る (fps が 10 以下だと
///   1 フレームが 0.1 秒に届き、遅れが閾を越えて合わせ直しが毎フレーム起きる)。例の `+ deltaTime` ではそうならない
///   が、**実時間の窓では `deltaTime` は前の枚の値なので、枚の間隔のぶれ (ジッタ) ぶんの誤差は残る** (書き出しでしか
///   測っていない)
/// - **音は鳴り終えると位置が 0 へ戻って止まる**ので、`song.isPlaying` で守らないと、止まった音へ飛ぶ命令を
///   毎フレーム出す。映像も終わりのコマで止まる (``play()``)
/// - **音声トラックの無い動画は、`loadSound` が `AudioFailure.unreadable` で断る** (`setup()` で `try` なら、
///   スケッチが始まらない)。**音声トラックが複数ある動画は、1 本目だけを読む** (確かめたのは、LPCM の 2 本で
///   1 本目だけが読まれること。1 本目が開けず 2 本目なら開ける動画は確かめていない)。macOS が音声として
///   開けない符号のトラックは確かめていない — 音声として開けなければ、コード上は同じく断る
/// - **音声トラックの開始が映像とずれている動画 (頭に空の編集区間がある動画など) は、`jump(clip.time)` でも
///   そのぶんずれる。** `Movie` は映像の時刻のとおりに映すが、`loadSound` は音声トラックの最初の標本から読み、
///   空の区間を無音として足さない (0.5 秒遅れて始まる音を、頭から読むことを確かめた)
/// - **`loadSound` は音の標本を全部メモリに持ち、`setup()` の間に読み切る。** 標本は 1 秒あたり 4 バイト ×
///   (チャンネル数 + 1) × 標本化率 (48 kHz のステレオで 1 分あたり約 35 MB) で、長い動画では大きく、読む間
///   `setup()` が止まる。待たずに読むなら、`Task` の中で読む `requestSound(_:)` を使う
/// - 固定の時計で書き出すと、音は `.mov` の音声トラックに載る。映像と音の頭の関係は、`play()` を呼ぶ場面で違う。
///   **`setup()` で `clip.play()` と `song.play()` を呼ぶと、書き出しの音の頭は映像の頭と揃う。** 最初の `draw()` など
///   **`draw()` の中で同じフレームに両方を呼ぶと、音の頭が映像の頭より 1 フレーム早い** — `play()` は次のフレームで
///   効く (映像) のに対し、音は呼んだフレームの窓の先頭から効く。揃えるなら、`draw()` で `song.play()` を 1 フレーム
///   遅らせる。測ったのは、30・60 fps (それ以外は測っていない) で、最初の `draw()` の中で `beginRecord` する書き方と、
///   `mokume render` と同じ最初のフレームより前に録り始める書き方の両方
/// - **この揃いは書き出しで測った話である。** 窓に出して実時間で回すときは、`setup()` の `play()` はすぐ鳴り始め、
///   最初のコマが出るまでの準備の時間ぶん音が先に進みうる (窓の最初の数フレームは測っていない)。気になるなら、
///   書き出しで測った形に寄せて、最初の `draw()` の中で両方を始める
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
/// **位置は時刻どおりに進む** ([#3152](https://github.com/mokume-metal/mokume/issues/3152))。流していれば、外していた
/// 間もスケッチの時刻は進んでいたものとして、外していた秒数だけ位置が先へ進んだコマが映る (外さずに回したときと
/// 同じコマ)。止めていれば (``pause()``)、止めた位置のまま。
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
