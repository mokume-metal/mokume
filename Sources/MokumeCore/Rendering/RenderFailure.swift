// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

/// 描画の土台で起こりうる失敗。
///
/// 起こりうる失敗が列挙できるので typed throws で運ぶ ([ADR-0010] 決定 7)。
///
/// **大半は「環境かリソースが足りない」形だが、それに限らない。** 要求した値が通らないもの
/// (``invalidSize(width:height:)`` / ``invalidPixelDensity(_:)`` / ``invalidFrameRate(_:)`` /
/// ``invalidWindowScale(_:)`` / ``invalidDisplay(_:)`` / ``invalidCount(_:)``) と、呼ぶ順序や場所が誤っているもの
/// (``commandsAlreadyOpen`` / ``notRunning(call:)``) も同じ型で運ぶ。呼び出し側から見ればどれも `try` した先で
/// 起きたことで、運び方を分けても受け取る場所が増えるだけだからである ([#792])。
///
/// **区別を持つのは ``description`` のほうである。** リソースが足りないなら「走ったままの
/// スケッチを閉じてから試す」、呼び方が誤っているなら「呼ぶ場所を直す」と、次にすることが
/// 文面で分かれる — そこが揃っていないと、踏んだ人を間違った方向へ送る。
///
/// [ADR-0010]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0010-concurrency-model.md
/// [#792]: https://github.com/mokume-metal/mokume/issues/792
public enum RenderFailure: Error, Equatable, Sendable {
    /// GPU が見つからない (仮想環境・GPU を持たない実行環境)。
    case deviceUnavailable

    /// コマンドキューを作れない。
    case commandQueueUnavailable

    /// コマンドアロケーターを作れない。
    case commandAllocatorUnavailable

    /// コマンドを 1 本作れない。
    case commandBufferUnavailable

    /// コマンドを構築している最中に、それを許さない API を呼んだ。**呼び出し順の誤り**で、
    /// リソースは足りている。
    ///
    /// 許さないのは、その API が自分のコマンドをもう 1 本開くからである。開いたままアロケーターの
    /// リングバッファを 1 周すると同じアロケーターを二重に開くことになり、検証層が止める (層が無ければ
    /// 未定義)。いま該当するのは `RenderDevice.makeClearedTexture(descriptor:)` の 1 つ。
    case commandsAlreadyOpen

    /// 常駐させる集合を作れない。
    case residencySetUnavailable(reason: String)

    /// GPU の完了を待つためのシグナルを作れない。
    case synchronizationUnavailable

    /// 指定した大きさの描画先を確保できない。
    case textureUnavailable(width: Int, height: Int)

    /// 読み出し先を確保できない。
    case bufferUnavailable(byteCount: Int)

    /// コマンドエンコーダーを作れない。
    case encoderUnavailable

    /// GPU の完了を待ったが、制限時間内に終わらなかった。
    ///
    /// 待ち時間の上限を秒で持つのは、検証が壁時計の絶対値ではなくこの値そのものを
    /// 物差しにできるようにするため。
    case timedOut(seconds: Int)

    /// GPU が積んだ仕事を打ち切ったので、絵が仕上がっていない。出る場面は 2 つある。
    ///
    /// - **絵を返す API が、依存したコミットの打ち切りを見つけた** ([#1932])。``RenderTarget/readPixels()``・
    ///   ``RenderTarget/encodeForDisplay(scale:)``・``RenderTarget/writePNG(to:)``・
    ///   `SketchRuntime.renderFrame(to:)` は、返す (書き出す) 絵が依存したコミットのどれかを GPU が
    ///   打ち切っていたら、待ちが成り立っていても絵を返さずにこれを投げる。範囲は各 API の説明にある。
    ///   結末の通知が待つ上限までに届かなかったコミットも、仕上がったと確かめられないので打ち切りに
    ///   数える (`reason` がそう報告する)
    /// - **GPU の完了を待ったが制限時間内に終わらず、直近に結末が届いたコミットは GPU が打ち切って
    ///   いた**。``timedOut(seconds:)`` の代わりに出る。`.timedOut` の「描きすぎ」を出すと、読んだ人を
    ///   形や光を減らす方向へ送ってしまう ([#1343])
    ///
    /// 打ち切られたコミットは 1 画素も書かないのに、完了のシグナルは進めるので、待ちの側からは打ち切りと
    /// 正常が区別できない ([#1065])。区別が付くのは結末の記録だけで、原因は描いている量ではなく
    /// 打ち切りの側にある。
    ///
    /// `reason` は Metal が報告した打ち切りの理由 (`Caused GPU Address Fault Error (…)` など)。
    ///
    /// [#1065]: https://github.com/mokume-metal/mokume/issues/1065
    /// [#1343]: https://github.com/mokume-metal/mokume/issues/1343
    /// [#1932]: https://github.com/mokume-metal/mokume/issues/1932
    case workDropped(reason: String)

    /// 同じプロセスで、GPU の完了を待つのが一度制限時間 (``RenderDevice/waitLimitSeconds``) を越えた
    /// ので、**新しい描画の土台を作らずに断った** ([#2052])。
    ///
    /// 土台を作るたびに、GPU へコマンドを渡すコマンドキューが 1 本増える。応答しない GPU にコマンドキューを追加し続けると、
    /// 止まったコマンドキューが溜まって、画面の描画ごと Mac が止まる。#2052 では、テストが土台を作り直し
    /// 続けて、カーネルパニックまで行った。
    ///
    /// ``timedOut(seconds:)`` とは分ける。あちらは待った本人が受け取り、文面は描く量を減らす方向へ
    /// 送る。こちらは、何も待っていない新しい土台が受け取る。することはプロセスを再起動することである。
    /// 既にある土台はそのまま使える (その待ちは、今までどおり `.timedOut` で打ち切られる)。
    ///
    /// **重い 1 フレームでも、ここへ来る。** 期限を越えた待ちからは、1 フレームが描きすぎたのか、GPU が
    /// 答えなくなったのかを見分けられない。だから文面は両方の場合を述べる。1 行目には、最初に期限を
    /// 越えた待ちの種類・期限・時刻を添える。フラグが立った後の失敗はどれもこれになるので、どの失敗からも
    /// 原因の待ちを辿れるようにするためである。
    ///
    /// [#2052]: https://github.com/mokume-metal/mokume/issues/2052
    case gpuNotResponding

    /// 描画先の大きさが正しくない (幅・高さは 1 以上、テクスチャの一辺の上限以下でなければ
    /// ならない)。上限そのものは ``description`` が示す。
    ///
    /// **上限も同じ case で運ぶ。** 呼び出し側がすることは下限を割ったときと同じ
    /// (要求する大きさを直す) で、分けても選び分ける先が無い ([#885])。
    ///
    /// [#885]: https://github.com/mokume-metal/mokume/issues/885
    case invalidSize(width: Int, height: Int)

    /// グラフィックスの大きさに書き出しの倍率 (`mokume render --scale`) を掛けると、テクスチャの一辺の上限を越える
    /// ([#3453])。`width` と `height` は**要求した座標の大きさ** (掛ける前) で、`scale` は倍率。
    ///
    /// ``invalidSize(width:height:)`` と分ける。あちらは要求した大きさそのものが範囲の外で、直し先は要求する大きさ
    /// だけである。こちらは要求した大きさ自体は通り、倍率との積が越えるので、直し先に倍率が加わる
    /// (大きさを縮めるか、倍率を下げる)。文面が倍率を名指せないと、読んだ人は掛けていない大きさを
    /// 疑ってしまう。
    ///
    /// [#3453]: https://github.com/mokume-metal/mokume/issues/3453
    case sizeBeyondOutputScale(width: Int, height: Int, scale: Int)

    /// 描くピクセル密度が正しくない (0 より大きく 1 以下でなければならない)。
    ///
    /// 1 を超える指定 — 出すより細かく描いて縮める — は引き受けない。拡大器が
    /// 縮小を扱わないうえ、要求も出ていないためである。
    case invalidPixelDensity(Float)

    /// 1 秒あたりのフレーム数が正しくない (1 以上でなければならない)。
    ///
    /// **構築時に拒否し、通知なしに 1 fps へ丸めない** ([ADR-0020] 決定 5 の 2 行目・[#1642])。
    /// `frameRate: 0` を「止める」の意味で書いた人が、1 秒に 1 枚だけ進む絵を見ることになる。
    /// 止めたいなら `noLoop()` を呼ぶ — 文面もそちらへ送る。
    ///
    /// [ADR-0020]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0020-api-naming-and-surface.md
    /// [#1642]: https://github.com/mokume-metal/mokume/issues/1642
    case invalidFrameRate(Int)

    /// ウィンドウを開く倍率が正しくない (0 より大きい有限の数でなければならない)。
    ///
    /// **構築時に拒否する** ([ADR-0020] 決定 5 の 2 行目)。ウィンドウを開かない実行 (書き出し・
    /// ウィンドウを持たない `SketchRuntime`) でも拒否するのは、同じスケッチがウィンドウを開く起動方法に
    /// 移ったときに初めて落ちる形にしないためである。画面に収まらない大きさは拒否しない
    /// (``SketchSettings/windowScale`` の「使える値」)。
    ///
    /// [ADR-0020]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0020-api-naming-and-surface.md
    case invalidWindowScale(Float)

    /// 全画面で出すディスプレイの番号が正しくない (1 以上でなければならない)。
    ///
    /// **繋がっていないこと (``displayNotConnected(_:connected:)``) とは分ける。** こちらは要求の
    /// 誤り (番号を直す) で、あちらは機材の話 (繋ぐか、繋がっている番号を選ぶ)。同じ文面にすると、
    /// 0 を渡した人をケーブルの確かめへ送ってしまう (``invalidCount(_:)`` と同じ分け方)。
    case invalidDisplay(Int)

    /// 全画面で出すディスプレイが繋がっていない。`connected` は、いま繋がっている一覧。
    ///
    /// **構築時に拒否し、別の画面へはフォールバックしない** ([ADR-0020] 決定 5 の 2 行目)。展示でプロジェクタへ
    /// 出すつもりのスケッチが、通知なしに手元の画面を全画面で塞ぐことになるからである。繋がっていなければ
    /// ウィンドウで開く、としたいスケッチは ``SketchPart/displays`` を読んで自分で選ぶ
    /// (``SketchSettings/fullScreen(_:)`` の例)。
    ///
    /// [ADR-0020]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0020-api-naming-and-surface.md
    case displayNotConnected(Int, connected: [Display])

    /// 用意する数が正しくない (1 以上でなければならない)。数の並び (`makeNumbers(count:)`)
    /// とパーティクル (`makeParticles(count:)`) の数で出る。
    ///
    /// **``bufferUnavailable(byteCount:)`` とは分ける。** あちらはリソースが足りない (一度に扱う
    /// 数を減らす) で、こちらは要求の誤り (数を直す)。同じ文面にすると、0 を渡した人を
    /// 減らす方向へ送ってしまう ([#1642](https://github.com/mokume-metal/mokume/issues/1642))。
    case invalidCount(Int)

    /// 同梱しているはずのシェーダの原文が見つからない。
    case shaderSourceMissing(name: String)

    /// シェーダをコンパイルできない。
    ///
    /// 理由はコンパイラの言葉のままだが、**エントリポイントを書き違えたシェーダでは、期待するエントリポイントの形を
    /// `<シェーダの名前>: error: …` の 1 行で先頭に追加する** ([#2782](https://github.com/mokume-metal/mokume/issues/2782))。
    /// リンクの段階の `Undefined symbol(s)` は書いたシェーダのどこも指さないので、そのままでは説明の
    /// 「理由が指す所を、書いたシェーダの中で直せ」が成り立たない。計算のエントリポイントの関数が無いときも、この
    /// case で言う (コンパイルしたライブラリを見て拒否する。Metal に任せるとプロセスごと落ちる)。
    ///
    /// **`values:`・`surfaces:` の名前の誤りもこの case で言う** ([#2783](https://github.com/mokume-metal/mokume/issues/2783))。
    /// 書けない文字列はコンパイルの前に拒否し、Metal で使えない名前 (予約語・型・マクロ) はコンパイルの
    /// 誤りに名指しの 1 行を追加する。直す先は Swift の引数なので、説明の最後の行はそちらも挙げる。
    case shaderCompilationFailed(name: String, reason: String)

    /// シェーダをコンパイルするコンパイラーを作れない。
    case shaderCompilerUnavailable

    /// 描画のパイプラインを作れない。
    case pipelineUnavailable(reason: String)

    /// リソースを渡すテーブルを作れない。
    case argumentTableUnavailable(reason: String)

    /// テクスチャの読み取り方を作れない。
    case samplerUnavailable

    /// 実行中のスケッチを取得できない所で、この型を投げるリソースの API を呼んだ。`call` は呼んだ API の名前
    /// (`"createGraphics(_:_:)"` など)。返すものを実行中のスケッチからしか作れないので、`setup()` などから呼び直す
    /// ([#2683](https://github.com/mokume-metal/mokume/issues/2683))。
    ///
    /// 実行中のスケッチを取得できるのは `setup()`・`draw()`・入力のコールバックの中 (待つ読み込みは、そこで生成した
    /// `Task` の中も) だけで、初期化子の中・後片付けの後・`Task` の中からは取れない。**名前に反して、
    /// スケッチが走っている最中にも起こる** — `draw()` が回っている間に、そこで生成した `Task` から
    /// 同期 API を呼んでもこの場合になる ([#1322](https://github.com/mokume-metal/mokume/issues/1322)
    /// と同じ事情)。
    case notRunning(call: String)

    /// ツール (`mokume render`) が渡した書き出しの要求 (環境変数 `MOKUME_RENDER`) を、子が読めない、
    /// または書き出せない組だった。`value` は渡された値そのまま ([#2481])。
    ///
    /// **ウィンドウへフォールバックせず、起動を拒否する。** フォールバックした子はウィンドウを開いて 0 で終わり、書き出しを要求した人は何も書かれて
    /// いないのに「書けた」と読まされた。形が違うのは、ツールと依存のバージョンがずれたときと、手で値を置いた
    /// ときである。値が無い子はこの case に来ない (いつものウィンドウ)。
    ///
    /// [#2481]: https://github.com/mokume-metal/mokume/issues/2481
    case unreadableRenderRequest(value: String)

    /// ``Sketch/setup()`` が投げたので、スケッチは `draw()` を 1 度も呼ばずに止まった ([#2401])。
    ///
    /// `reason` は投げた失敗の全文 (`loadImage` の失敗なら、何を読めなかったかと次にすること)。**どの経路で
    /// 実行しても** — ウィンドウ・書き出し・`SketchRuntime` を直に回すテスト — 同じ失敗がここにまとめられる。投げた型は
    /// 問わないので、運ぶのは文面だけである。
    ///
    /// [#2401]: https://github.com/mokume-metal/mokume/issues/2401
    case setupFailed(reason: String)
}

extension RenderFailure: CustomStringConvertible {
    /// 人が読む文面。
    ///
    /// **どの失敗にも「次に何をすればよいか」を書く。** 起動できなかったときに出る行は
    /// 利用者が最初に見る失敗で、しかも**配った先で出る** — 読む人はビルド方法を知らない
    /// ことがあるので、状態の報告だけでは足りない ([#527])。ツールの側 (`CommandFailure`) が
    /// 既に持っている規範を、ライブラリの側にも通す。
    ///
    /// **内部の名前をそのまま出さない。** case の名前は実装の都合で決まっていて、読む人が
    /// 次にすることを決める助けにならない。準拠しているので `\(failure)` と書いた場所も
    /// この文面になる — 内部の名前が出る経路が残らない。
    ///
    /// **姉妹型と同じ形で公開する。** ``ImageFailure`` / ``ModelFailure`` / ``ShaderFailure``
    /// はいずれも `CustomStringConvertible` で人向けの文面を出しており、ここだけ internal
    /// だったせいで、アンブレラしか見えない場所 (参照スケッチ) が同じ文面を出せなかった
    /// ([#600])。実需ではなく**既にある規範が要求する一貫性の欠け**を埋めるもの
    /// ([ADR-0022] 決定 6 の 2 行目)。
    ///
    /// 走っている最中の警告は多行を流せないので、そちらは ``headline`` を使う。
    ///
    /// [#527]: https://github.com/mokume-metal/mokume/issues/527
    /// [#600]: https://github.com/mokume-metal/mokume/issues/600
    /// [ADR-0022]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0022-production-track.md
    public var description: String {
        switch self {
        case .deviceUnavailable:
            """
            No GPU here.
            mokume runs only on a Mac that has one, and not inside a virtual machine.
            """
        case .commandQueueUnavailable:
            """
            Cannot create a command queue.
            \(Self.exhaustedAdvice)
            """
        case .commandAllocatorUnavailable:
            """
            Cannot create a command allocator.
            \(Self.exhaustedAdvice)
            """
        case .commandBufferUnavailable:
            """
            Cannot create a command buffer.
            \(Self.exhaustedAdvice)
            """
        case .commandsAlreadyOpen:
            // **資源枯渇の共通文面 (`Self.exhaustedAdvice`) へ寄せない。** あちらは「走った
            // ままのスケッチを閉じてから試す」で終わるが、ここで閉じても何も変わらない (#792)
            """
            Tried to make a painted surface while commands were still being assembled.
            This is the order of the calls rather than a shortage: make surfaces before the
            assembly begins, or after it has been submitted.
            """
        case .residencySetUnavailable(let reason):
            """
            Cannot create a residency set: \(reason)
            \(Self.exhaustedAdvice)
            """
        case .synchronizationUnavailable:
            """
            Cannot create the signal that waits for the GPU to finish.
            \(Self.exhaustedAdvice)
            """
        case .encoderUnavailable:
            """
            Cannot create a command encoder.
            \(Self.exhaustedAdvice)
            """
        case .textureUnavailable(let width, let height):
            """
            Cannot allocate a \(width)×\(height) render target.
            The GPU is out of memory — make the window smaller, or draw at a lower density.
            """
        case .bufferUnavailable(let byteCount):
            """
            Cannot allocate a \(byteCount)-byte buffer to read back into.
            The GPU is out of memory — handle fewer things at once.
            """
        case .timedOut(let seconds):
            """
            Waited \(seconds) seconds for the GPU and it never finished.
            One frame is drawing too much — draw fewer things, or make the shader lighter.
            """
        case .workDropped(let reason):
            // **1 行目に理由を入れる。** ウィンドウの経路は `headline` の 1 行しか流さないので、
            // 2 行目へ回すと、読むべき理由が端末に 1 度も出ない (#1343)。**待ちが終わらなかったとは
            // 言い切らない** — 絵を返す口は、待ちが成り立った後にも打ち切りを見つけて投げる (#1932)
            """
            The GPU dropped work it had queued, so the picture was never finished: \(reason)
            This is not how much is being drawn. If the reason is a hang, one frame's work (a \
            shader) runs too long; otherwise it is most likely a fault inside mokume — please \
            report it with this message at https://github.com/mokume-metal/mokume/issues
            """
        case .gpuNotResponding:
            Self.notResponding(
                after: CommandQueueGate.process.closure,
                record: CommandQueueGate.process.expiryRecordExists
                    ? CommandQueueGate.process.expiryRecordPath?.path : nil)
        case .invalidSize(let width, let height):
            """
            That is not a valid size for a render target: \(width)×\(height)
            Width and height each have to be at least 1 and at most \(RenderDevice.maxTextureSide).
            """
        case .sizeBeyondOutputScale(let width, let height, let scale):
            """
            A drawing target of \(width)×\(height) is too large at the render scale \(scale) (`mokume render --scale \(scale)`): \
            it would be \(Self.scaledText(width, by: scale))×\(Self.scaledText(height, by: scale)) pixels, and each side can be at most \(RenderDevice.maxTextureSide).
            The size is in coordinates and the scale multiplies the pixels. Make the drawing target at most \
            \(RenderDevice.maxTextureSide / scale) wide and high, or render with a smaller --scale.
            """
        case .invalidPixelDensity(let density):
            """
            That is not a valid pixel density: \(density)
            It has to be above 0 and at most 1 (1 draws at exactly the density asked for, and
            anything smaller draws coarser and scales up).
            """
        case .invalidFrameRate(let frameRate):
            """
            That is not a valid frame rate: \(frameRate)
            It has to be at least 1 frame per second. To stop the sketch from moving on, call
            noLoop() instead.
            """
        case .invalidWindowScale(let scale):
            """
            That is not a valid window scale: \(scale)
            It has to be a finite number above 0 — how many points of the window one pixel of \
            the sketch takes (0.5 opens a 960×540 sketch in a 480×270 window).
            """
        case .invalidDisplay(let number):
            """
            That is not a display number: \(number)
            Displays are numbered from 1 — 1 is the one with the menu bar, and 2 onwards follow \
            the arrangement in System Settings › Displays from the left.
            """
        case .displayNotConnected(let number, let connected):
            """
            Display \(number) is not connected, so the sketch cannot go full screen on it.
            Connected now: \(Self.listing(connected)). Connect it, or ask for one of these \
            numbers — a sketch can read them from displays, and open a window when the one it \
            wants is missing.
            """
        case .invalidCount(let count):
            """
            That is not a valid number to make: \(count)
            It has to be at least 1 — ask for as many as the sketch will use.
            """
        case .shaderSourceMissing(let name):
            """
            Cannot find the source of a shader that ships with mokume: \(name)
            This is the failure that shows up most often after handing a work to someone: the
            resources did not make it into what was shipped. Check that
            \(ModuleResources.bundleName).bundle sits next to the executable (for a bundled
            work, in <name>.app/Contents/Resources/ or directly under <name>.app/). If it is
            not there, build the distribution again.
            """
        case .shaderCompilationFailed(let name, let reason):
            """
            Cannot build the shader: \(name)
            \(reason)
            Fix what the reason above points at — in the fragment you wrote, or, where it names
            values:, surfaces: or numbers:, in the names you pass from Swift.
            """
        case .shaderCompilerUnavailable:
            """
            Cannot make anything that compiles shaders.
            This machine's Metal falls short of what mokume asks for — check the macOS version.
            """
        case .pipelineUnavailable(let reason):
            """
            Cannot create the render pipeline: \(reason)
            Check that the shader's entry point name and the resources being passed line up.
            """
        case .argumentTableUnavailable(let reason):
            """
            Cannot create the table that passes resources: \(reason)
            Check whether too many resources are being passed at once.
            """
        case .samplerUnavailable:
            """
            Cannot create a way to read from a texture.
            \(Self.exhaustedAdvice)
            """
        case .notRunning(let call):
            OutsideRun.notRunningNotice(call)
        case .setupFailed(let reason):
            // **投げた失敗の全文をそのまま運ぶ** — 次にすることは投げた側の文面が持っている。
            // 1 行に削る経路 (`headline`) は先頭行だけを使うので、何が起きたかと投げた失敗の最初の行を
            // 1 行目に入れる (名乗りだけが先頭に来ると、理由が落ちる)
            //
            // **前後の空白と改行を落として繋ぐ。** 改行で始まる理由を繋ぐと 1 行目が名乗りだけになり、
            // 1 行に削る経路も、見張りの記録の頭の 1 行も、理由を落とす
            Self.setupFailedText(reason)
        case .unreadableRenderRequest(let value):
            // `.png` で終わらない連番なら、道具の `--out` と同じ理由を名乗る (#3961)
            (RenderRequest.seriesNotPNGReason(environmentValue: value).map {
                "The sketch was asked to render, but it does not write this series: \($0): \(value)\n"
            } ?? "The sketch was asked to render, but it cannot read or write what it was asked: \(value)\n")
                + """
                \(StartupReads.render.key) comes from `mokume render` as <fps>:<frames>:<where to write> (with --scale, \
                x<scale>:<fps>:<frames>:<where to write>) — a whole \
                frame rate and frame count above 0, and a .mov or .mp4 (at most \(RenderRequest.movieFrameRateLimit) \
                frames per second), a .gif (a frame rate that divides 100) or a numbered series ending in .png \
                (out/frame-####.png). If the tool and the \
                sketch use different versions of mokume, bring them to the same one (`mokume doctor` \
                shows both); if the variable was set by hand, unset it to run with a window.
                """
        }
    }

    /// 走っている最中に出す 1 行 (``description`` の先頭行 = 何が足りないか)。
    ///
    /// **`Diagnostics.warn` は 1 行しか流せない。** 宣言自身が「ライブラリからの注意を
    /// 1 行、標準エラーへ書く」と名乗っており、毎フレーム起こりうる失敗に多行を流すと
    /// 本当に読むべき行が埋まる (`SketchApplication.noteFrameFailure` のコメント)。
    ///
    /// **1 行に削るのは、人が端末で読む経路だけである** ([#600])。観測レポートの `warnings`
    /// は JSON の配列なので行数の制約が無く、読み手も機械なので全文 (`\(failure)`) を載せる
    /// — 組み立て直しの失敗はコンパイラの言葉が 2 行目に入るので、そこを削ると打つ手が
    /// 消える。起動の失敗も全文を出す (そこで終わりなので、次にすることまで要る)。
    ///
    /// [#600]: https://github.com/mokume-metal/mokume/issues/600
    package nonisolated var headline: String {
        String(description.prefix { $0 != "\n" })
    }

    /// `value` に `scale` を掛けた数の文面。溢れる巨大な値は「溢れる」と書く。
    private nonisolated static func scaledText(_ value: Int, by scale: Int) -> String {
        let (product, overflowed) = value.multipliedReportingOverflow(by: scale)
        return overflowed ? "more than \(Int.max)" : String(product)
    }

    /// ``gpuNotResponding`` の文面。**最初に期限を越えた待ち** (`closure`) を 1 行目に添える (#2052)。
    ///
    /// **1 行目に理由と、最初の待ちを入れる** (`workDropped` と同じ)。ウィンドウの経路は ``headline`` の 1 行
    /// しか流さない。検査では、印が立った後の GPU の検査がすべてこれで赤になる。最初に期限を越えた
    /// 待ちが土台を畳む時のもの (投げない) なら、原因の検査は緑のまま残る。だから、どの赤からも
    /// 原因の時刻と種類を読めるようにする。
    ///
    /// **描きすぎの場合もあると名乗る。** 期限を越えた待ちからは、重い 1 フレームと答えない GPU を
    /// 見分けられない。どちらでも、することはプロセスを起こし直すことである (#2052 の反証)。
    ///
    /// 付随値は持たない。文面は、プロセスで 1 つの関所が控えた最初の待ちを読む (公開の case に足さない
    /// ため)。検査が自前の関所を渡した土台の断りは、その関所ではなく、プロセスの関所を読む。
    ///
    /// **記録 (`record`) があるとき** (`scripts/gpu-slot.py` の下の検査・計測が残す記録・#2235) は、プロセスを
    /// 起こし直しても記録は消えないので、起こし直しとは言わず、人が GPU の答えを確かめて記録を消すよう言う。
    /// このプロセスが印を立てていれば (`closure`) 「earlier in this process」と、立てていなければ別の回の記録
    /// だと言う — **実際に合わせる**。**頭の句は、検査の記録を読む側 (`scripts/read-test-record.py` の
    /// `GATE_CLOSED`) が畳む 2 つのどちらかにする。**
    nonisolated static func notResponding(
        after closure: CommandQueueGate.Closure?, record: String? = nil
    ) -> String {
        if let record {
            let origin =
                closure.map {
                    "earlier in this process (\($0.summary)), and gpu-slot.py's record (\(record)) stops later runs too"
                } ?? "in another run under gpu-slot.py (record: \(record))"
            return """
                A wait for the GPU went past its limit \(origin), so no new drawing foundation is set up.
                That can be one frame drawing too much or a GPU that stopped answering, and the two look the same from \
                here. New work piled onto a GPU that does not answer can freeze the whole Mac. A person checks that the GPU \
                answers, and then deletes that record; starting this process again does not remove it.
                """
        }
        let first = closure.map { " (\($0.summary))" } ?? ""
        return """
            A wait for the GPU went past its limit earlier in this process, so no new drawing foundation is set up in it\(first).
            That can be one frame drawing too much or a GPU that stopped answering, and the two look the same from \
            here. New work piled onto a GPU that does not answer can freeze the whole Mac, so start the process again.
            """
    }

    /// GPU の資源が尽きているときに添える 1 行。
    ///
    /// **何が用意できなかったかは、各 case が完全な文で名乗る。** かつては骨組み 1 つに
    /// 名詞を流し込んで 8 通りを作っていたが、その形は語順の違う言語で組み替えられない
    /// (ADR-0038 決定 3)。共有するのは**独立した助言の 1 文**だけで、読む人が次にすること
    /// が同じであることは、その 1 文が同じであることで表す。
    private nonisolated static let exhaustedAdvice =
        "The GPU may have run out of resources — close any sketch still running and try again."

    /// `setup()` が投げた失敗の文面。**理由の前後の空白と改行を落とす。** 空なら名乗りだけにする。
    private nonisolated static func setupFailedText(_ reason: String) -> String {
        let reason = reason.trimmingCharacters(in: .whitespacesAndNewlines)
        let lead = "setup() threw, so the sketch did not start"
        return reason.isEmpty ? lead : lead + ": " + reason
    }

    /// 繋がっているディスプレイを 1 行に並べる。1 枚も無ければ `none`。
    private nonisolated static func listing(_ displays: [Display]) -> String {
        displays.isEmpty ? "none" : displays.map(\.description).joined(separator: ", ")
    }
}
