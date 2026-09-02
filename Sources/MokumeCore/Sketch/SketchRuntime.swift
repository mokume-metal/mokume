// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation
import MokumeDiagnostics
import QuartzCore

/// スケッチを走らせる。
///
/// ## フレームを進める入口は 1 つ
///
/// [ADR-0012] 決定 3 のとおり、「次のフレームを描く」判断はここにある。**進める入口は
/// ``advance()`` 1 つ**で、誰がそれを叩くかは外側の話 — 1 回だけ叩けば 1 枚だけ描かれ、
/// 一定の間隔で叩けば動き、表示のリフレッシュに合わせて叩けば画面に追随する。
///
/// 進め方が変わっても描かれる中身は変わらない。だから画面を持たない実行と画面に出す
/// 実行が、別の実装に分かれない。
///
/// [ADR-0012]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0012-view-layer.md
@MainActor
public final class SketchRuntime {
    /// 走らせているスケッチ。
    public let sketch: any Sketch
    /// 描いている面。
    public let canvas: Canvas
    /// 出す先。**画面も保存も観測もこの 1 枚を受け取る** ([ADR-0023] 決定 2)。
    ///
    /// 描く細かさを下げているときは、拡大の段を通ったあとの絵である。出口ごとに
    /// 分かれていないので、「画面ではこう見えるのに書き出すと違う」が起こらない。
    ///
    /// [ADR-0023]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0023-frame-stages-and-outputs.md
    public var target: RenderTarget { canvas.output }

    /// いまの絵が、前のフレームの結果に依っているか。意味の説明は ``Sketch`` 側が正本。
    public var usesFrameHistory: Bool { canvas.usesFrameHistory }

    private let timing: FrameTiming
    private let now: () -> Double
    private var hasSetUp = false
    private var isPaused = false

    /// 登録された出口。**宣言順**に呼ぶ ([ADR-0024] 決定 4)。
    ///
    /// [ADR-0024]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0024-extension-seams.md
    private var outlets: [(outlet: any Outlet, health: SeamHealth)] = []
    /// 登録された入り口。同じく宣言順。
    private var inlets: [(inlet: any Inlet, health: SeamHealth)] = []

    /// 絵をファイルにする組み込みの出口。**頼まれてはじめて作る。**
    ///
    /// 頼まれている間だけ ``outlets`` に居る (``attachRecorderIfNeeded()``)。
    private var recorder: FrameRecorder?
    /// 絵を取り出せなかったことを、既に言ったか。**毎フレーム言わない。**
    private var warnedEncodeFailed = false

    /// 外から観測されるための窓口。区画が無ければ `nil` で、**そのときフレームループは
    /// 観測の存在を一切払わない** (ADR-0018 の面が満たすべき性質)。
    private let observer: FrameObserver?
    /// 外から送られる入力の受け口。区画が無ければ `nil`。
    private let inbox: InputInbox?
    /// 道具の窓が拾った出来事の受け口。見張りから起こされたときだけ在る。
    private let relayed: StandardInputEvents?
    /// つまみの面 (区画が在るときだけ働く)。
    private let params: ParamSurface?
    /// 合わせた値の保存。**区画とは無関係に既定で効く** (ADR-0030 決定 6)。
    private let paramStore: ParamStore?
    /// 入力の合流点。窓からの操作も、外から送られたものもここへ集まる。
    public let input = InputState()
    /// 視点を操る道具の状態。**フレームを越える** — 引きずった角度が積み上がる先なので、
    /// 視点 (シーンの記述) と違ってフレームごとには戻らない。まだ触っていなければ `nil`。
    var orbit: Orbit?
    /// 視点を操る道具を、最後に進めたフレーム。
    ///
    /// 1 フレームに 2 回呼ばれても 2 回ぶん回さないための目印。同じ引きずった量を
    /// 2 度食わせると倍の速さで回るが、**絵が速いだけなので気付けない**。
    var orbitAdvancedAt = -1
    /// 乱数の状態。**フレームを越える** — 列は呼んだぶんだけ進むものなので、
    /// フレームの頭で戻すと `draw()` が毎回同じ列を引くことになる。
    ///
    /// 揺らぎ (``Canvas/noiseSeed(_:)``) と違って断片へは届かない。断片には列が無く
    /// (画素どうしが独立している)、**値の一致がそもそも定義できない**ためである。
    var randomness = Randomness()
    /// このフレームでスケッチが差し出した値。観測が無ければ溜めない。
    private var exposedValues: [String: ExposedValue] = [:]
    /// 続けて撮っている最中の列。撮り終えるまで次の要求を拾わない。
    private var capture: FrameCapture?
    /// メニューバーで名乗る係。**組み立てのときには何も出さない** — 出すのは
    /// ``SketchPresence/grace`` 秒ぶん進み続けてからである。
    private lazy var presence = SketchPresence(source: self)
    /// 最初に ``advance()`` が呼ばれた時刻。名乗りの経過はここを起点に測る。
    private var firstAdvanceAt: Double?
    /// いまフレームを描いている最中か。入れ子で描き始めないための目印。
    private var isAdvancingFrame = false
    /// 最後にフレームを描き終えた時刻。**誰かが進めているか**の判断に使う。
    private var lastFrameAt: Double = 0
    /// フレームの速さを数える、**ただ 1 つの集計器** ([ADR-0030] 決定 7)。
    ///
    /// 窓に出る数字も観測の応答が返す数字もここから採る。**観測の有無に関わらず
    /// 数える** — 窓は観測が無くても数字を出すので、観測が有効なときだけ数えると
    /// 窓の側が自分で測り直す羽目になり、源が 2 つに割れる。
    ///
    /// [ADR-0030]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0030-parameter-surfaces.md
    private var tempo = FrameTempo()

    /// 窓に出す数字。**観測の応答が返すものと同じ集計器から採る** (ADR-0030 決定 7)。
    var frameNumbers: FrameNumbers {
        let moment = now()
        return FrameNumbers(
            frameCount: timing.frameCount,
            time: Double(timing.time),
            frameRate: tempo.frameRate(now: moment),
            frameTimeMs: tempo.frameTimeMs(now: moment)?.mean)
    }

    /// これまでに描いたフレームの数。
    public var frameCount: Int { timing.frameCount }
    /// いまのフレームの時刻 (秒)。
    public var time: Float { timing.time }
    /// 前のフレームからの経過 (秒)。
    public var deltaTime: Float { timing.deltaTime }

    /// スケッチとその舞台を組み立てる。
    ///
    /// - Parameters:
    ///   - sketch: 走らせるスケッチ。
    ///   - gpu: 描画の土台。
    ///   - clock: 時刻の出どころ。省略すると設定のフレームレートから導く
    ///     **再現する時計**になる — 画面に出す経路が実時間を選ぶ。
    public convenience init(
        sketch: any Sketch,
        gpu: RenderDevice,
        clock: Clock? = nil
    ) throws(RenderFailure) {
        try self.init(sketch: sketch, gpu: gpu, clock: clock, now: { CACurrentMediaTime() })
    }

    /// 実時間の出どころを差し替えられる入口 (検査用)。
    init(
        sketch: any Sketch,
        gpu: RenderDevice,
        clock: Clock?,
        now: @escaping () -> Double
    ) throws(RenderFailure) {
        let settings = sketch.settings
        self.sketch = sketch
        let target = try RenderTarget(gpu: gpu, width: settings.width, height: settings.height)
        self.canvas = try Canvas(
            output: target, gpu: gpu, pixelDensity: settings.pixelDensity,
            upscale: settings.upscale)
        self.timing = FrameTiming(
            clock: clock ?? .frameIndex(frameRate: settings.frameRate), now: now)
        self.now = now
        self.observer = FrameObserver.makeIfEnabled()
        self.inbox = InputInbox.makeIfEnabled()
        self.relayed = StandardInputEvents.makeIfDriven()
        // 索引は 1 度だけ引き、保存と面が同じものを持ち回る
        let registry = ParamRegistry(of: sketch)
        let store = ParamStore.makeIfNeeded(for: registry)
        self.paramStore = store
        self.params = ParamSurface.makeIfEnabled(for: registry, store: store)
    }

    /// 観測の窓口を差し替えられる入口 (検査用)。
    init(
        sketch: any Sketch,
        gpu: RenderDevice,
        clock: Clock?,
        now: @escaping () -> Double,
        observer: FrameObserver?,
        inbox: InputInbox? = nil,
        params: ParamSurface? = nil,
        paramStore: ParamStore? = nil
    ) throws(RenderFailure) {
        let settings = sketch.settings
        self.sketch = sketch
        let target = try RenderTarget(gpu: gpu, width: settings.width, height: settings.height)
        self.canvas = try Canvas(
            output: target, gpu: gpu, pixelDensity: settings.pixelDensity,
            upscale: settings.upscale)
        self.timing = FrameTiming(
            clock: clock ?? .frameIndex(frameRate: settings.frameRate), now: now)
        self.now = now
        self.observer = observer
        self.inbox = inbox
        self.relayed = nil
        self.params = params
        self.paramStore = paramStore
    }

    // MARK: - 進める

    /// 一度だけの初期化を走らせる。``advance()`` が要れば自分で呼ぶので、
    /// 明示的に呼ばなくてもよい。
    public func start() {
        guard !hasSetUp else { return }
        hasSetUp = true
        registerPlugins()
        // **戻すのは setup より先。** setup も最初の draw も、復元された値を見る
        // (ADR-0030 決定 6)
        let restoration = paramStore?.restore() ?? .init()
        withActiveRuntime { sketch.setup() }
        // 最初の応答は setup のあとに書く。setup で決めた値が、外から読める最初の
        // 姿になる
        params?.start(after: restoration)
    }

    /// 宣言された束を差込口へ登録する。**組み立てのときに 1 度だけ。**
    ///
    /// 開くのに失敗した束は**それだけ外して続ける** ([ADR-0024] 決定 7)。1 つの束が
    /// 使えないことでスケッチごと動かなくなるのは、代償が釣り合わない。
    ///
    /// [ADR-0024]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0024-extension-seams.md
    private func registerPlugins() {
        for plugin in sketch.plugins {
            let registry = PluginRegistry()
            plugin.register(into: registry)
            // **束の単位で開く。** 出口と入り口の両方を持つ束は、片方が開けなければ
            // 束ごと外れる — 半分だけ生きた束は、書いた人の想定にない状態である
            do {
                for outlet in registry.outlets { try outlet.open() }
                for inlet in registry.inlets { try inlet.open() }
            } catch {
                Diagnostics.warn(
                    "\(type(of: plugin)) を開けませんでした: \(error)。この束は外して続けます")
                continue
            }
            outlets += registry.outlets.map { ($0, SeamHealth()) }
            inlets += registry.inlets.map { ($0, SeamHealth()) }
        }
    }

    /// 差込口を閉じる。**投げない** ([ADR-0024] 決定 7)。
    ///
    /// [ADR-0024]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0024-extension-seams.md
    public func closePlugins() {
        for entry in outlets { entry.outlet.close() }
        for entry in inlets { entry.inlet.close() }
        // **並びに居なくても閉じる。** 撮る係は遊んでいる間は外れているので、
        // 並びだけを畳むと最後に頼んだ 1 枚が書かれないまま終わりうる
        recorder?.close()
        // **まとめている途中の保存を落とさない。** 引いたつまみの最後の 1 手だけが
        // 消えると、直したはずの値が次の起動で戻っていない形で出る
        paramStore?.flushIfPending()
        outlets.removeAll()
        inlets.removeAll()
        recorder = nil
    }

    /// フレームを 1 つ進める。
    ///
    /// 止めている間は描かない — **止めたのに進む**経路を作らないため。ただし観測には
    /// 応える (下記)。呼び出し側は走っているかどうかを気にせずこれを叩けばよい。
    ///
    /// **描けなかったときも観測には応えてから投げる。** 観測を描画の後ろに置いたまま
    /// 素通しで投げると、描画が失敗した瞬間から観測は要求の検出にすら到達せず、
    /// [ADR-0018] 決定 3 の「失敗しても必ず応答する」が効かなくなる。入力は描画の前に
    /// 流し込まれるので生き続け、外からは**観測だけが黙った**ようにしか見えない
    /// ([#221](https://github.com/mokume-metal/mokume/issues/221))。
    ///
    /// [ADR-0018]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0018-observation-and-control-surface.md
    public func advance() throws(RenderFailure) {
        // **描く前に済ませる。** 名乗りのメニューが開くとしたらこの中なので、そのとき
        // ``target`` には直前のフレームが揃っている。止めている間も名乗りは続ける —
        // 止まっているスケッチも、居座っていることに変わりはない
        updatePresence()
        try runFrame()
    }

    /// フレームを 1 つ進める本体。**名乗りの世話は含まない。**
    ///
    /// 分けてあるのは、名乗りのメニューが開いている間だけ**ここが別の駆動源から呼ばれる**
    /// ためである (``advanceForPresence()``)。``advance()`` ごと呼ぶと、追跡ループの中で
    /// 名乗りの世話が入れ子になる。
    private func runFrame() throws(RenderFailure) {
        isAdvancingFrame = true
        defer {
            isAdvancingFrame = false
            lastFrameAt = now()
        }
        guard !isPaused else {
            serveObservationIfRequested()
            return
        }
        start()
        timing.advance()
        beginFrame()
        receiveInput()

        supplyFromInlets()

        var drawFailure: RenderFailure?
        canvas.time = timing.time
        canvas.deltaTime = timing.deltaTime
        do {
            try canvas.draw { withActiveRuntime { sketch.draw() } }
        } catch {
            drawFailure = error
        }
        if drawFailure == nil { deliverToOutlets() }
        detachRecorderIfDone()
        serveObservationIfRequested(drawFailure: drawFailure)
        if let drawFailure { throw drawFailure }
    }

    /// 溜まった入力をこのフレームへ流し込む。
    ///
    /// **`draw()` の前に流す。** 送られた出来事が同じフレームの `draw()` から見える —
    /// 1 フレーム遅れて効く形にすると、外から動かして確かめるときに毎回 1 枚ぶんずれる。
    private func receiveInput() {
        // **窓からのぶんを先に引き取る。** どちらも同じ待ち行列へ入るので、順は
        // 「起きた順に近いほう」を選ぶ — 区画は要求 1 回ぶんをまとめて運ぶので、
        // 窓の 1 件より古いことがある
        relayed?.drain(into: input)
        inbox?.drain(into: input)
        params?.drain()
        paramStore?.tick()
        input.beginFrame()
    }

    /// 入り口に値を供給させる。**`draw()` の直前** ([ADR-0024] 決定 6)。
    ///
    /// 供給した値が同じフレームの `draw()` から見える。1 フレーム遅れて効く形にすると、
    /// 外から動かして確かめるときに毎回 1 枚ぶんずれる。
    ///
    /// [ADR-0024]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0024-extension-seams.md
    private func supplyFromInlets() {
        for index in inlets.indices where inlets[index].health.isAttached {
            inlets[index].inlet.supply()
            if inlets[index].health.note(inlets[index].inlet.failure) {
                Diagnostics.warn(
                    "\(type(of: inlets[index].inlet)) が続けて転んだので外しました"
                        + " (最後の理由: \(inlets[index].inlet.failure ?? "不明"))")
            }
        }
    }

    /// 描いた絵を出口へ渡す。
    ///
    /// **道を通るのは 1 フレームに 1 回**で、出口が何本あっても同じ 1 枚を配る
    /// ([ADR-0024] 決定 6 の「全ての出口が同じ道から受け取る」)。出口が 1 つも
    /// 付いていなければ**道を 1 回も通らない** — 使わない機能の費用を、使っていない
    /// スケッチが払わない。
    ///
    /// [ADR-0024]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0024-extension-seams.md
    private func deliverToOutlets() {
        guard outlets.contains(where: { $0.health.isAttached }) else { return }
        let image: EncodedImage
        do {
            image = try target.encodeToImage()
        } catch {
            // 毎フレーム走る経路なので投げない (ADR-0020 決定 5)。1 度だけ言う
            guard !warnedEncodeFailed else { return }
            warnedEncodeFailed = true
            Diagnostics.warn("出口へ渡す絵を取り出せませんでした: \(error.headline)")
            return
        }
        let frame = OutputFrame(
            image: image, frame: timing.frameCount, time: Double(timing.time))
        for index in outlets.indices where outlets[index].health.isAttached {
            outlets[index].outlet.receive(frame)
            if outlets[index].health.note(outlets[index].outlet.failure) {
                Diagnostics.warn(
                    "\(type(of: outlets[index].outlet)) が続けて転んだので外しました"
                        + " (最後の理由: \(outlets[index].outlet.failure ?? "不明"))")
            }
        }
    }

    // MARK: - 名乗り

    /// 走り続けていることをメニューバーの名乗りへ伝える。
    ///
    /// 起点は**最初のフレーム**で、組み立てた時刻ではない。1 枚も描かないまま持っている
    /// ランタイム (検査が作るもの) は走っているとは言えないため。
    private func updatePresence() {
        let now = self.now()
        guard let started = firstAdvanceAt else {
            firstAdvanceAt = now
            return
        }
        presence.advanced(runningFor: now - started)
    }

    /// 走り続けている時間 (秒)。名乗りが読む。
    var presenceElapsed: Double {
        guard let firstAdvanceAt else { return 0 }
        return now() - firstAdvanceAt
    }

    /// 名乗りのメニューが開いている間、プレビューを動かすために呼ばれる。
    ///
    /// **誰かが既に進めているなら何もしない。** 窓を開く経路の駆動源 (`CADisplayLink`) は
    /// `.common` モードに登録されているので、メニューを開いている間もフレームは進み続ける
    /// — そこで二重に進めると、**メニューを開けている間だけ倍の速さで動く**。
    ///
    /// 逆に窓を開かない経路では、メニューを開いた時点で `advance()` が AppKit の追跡ループ
    /// の中で止まっている。**そのままではプレビューが静止画になる**ので、ここが進める。
    func advanceForPresence() {
        guard !isAdvancingFrame, now() - lastFrameAt > Self.presenceStallThreshold else { return }
        try? runFrame()
    }

    /// これだけ描かれていなければ「誰も進めていない」とみなす (秒)。
    ///
    /// 想定する一番遅い駆動が 30 fps (33 ms) なので、その倍を取る。短くすると、
    /// 進んでいるのに二重に進めてしまう。
    private static let presenceStallThreshold: Double = 0.066

    /// いま描かれている絵を、名乗りのメニューに載る大きさで返す。
    ///
    /// **出口が受け取るのと同じ道を通す** ([ADR-0024] 決定 6)。小さくするのは通した後で、
    /// 出るバイト列は通す前に間引いたのと同じである
    /// ([#382](https://github.com/mokume-metal/mokume/issues/382)) — 観測が絵を採るときと
    /// 同じ理屈なので、経路をもう 1 本作らない。
    ///
    /// **1 枚も描いていなければ `nil`。** 描いていない絵を出すよりは、出さないほうがよい。
    ///
    /// - Parameter maxWidth: 返す絵の幅の上限 (画素)。**縮小率ではなく幅で頼む** — 絵の
    ///   大きさはスケッチが決めるので、率で指定すると出来上がりがスケッチごとに変わる。
    ///
    /// [ADR-0024]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0024-extension-seams.md
    func presencePreview(maxWidth: Int) -> DisplayImage? {
        guard timing.frameCount > 0 else { return nil }
        guard let image = try? self.target.encodeToImage().read() else { return nil }
        return image.scaled(by: min(1, Double(maxWidth) / Double(max(1, image.width))))
    }

    /// フレームの頭で片付けること。
    private func beginFrame() {
        // 速さは**いつでも**数える。窓は観測が無くても数字を出すためで、ここを
        // 観測に紐づけると窓が自分で測り直すことになる (源が 2 つに割れる)
        tempo.record(now: now())
        guard observer != nil else { return }
        exposedValues.removeAll(keepingCapacity: true)
    }

    /// 進めるのを止める。
    public func pause() { isPaused = true }

    /// 進めるのを再開する。
    ///
    /// **時刻の起点を現在へ寄せ直す。** 止めている間も実時間は進むので、寄せ直さないと
    /// 止めていた時間まるごとが再開後の最初の経過時間として渡る。
    public func resume() {
        isPaused = false
        timing.resync()
    }

    /// 止まっているか。
    public var isRunning: Bool { !isPaused }

    // MARK: - 使いやすい入口

    /// 1 枚だけ描いて、画像に書き出す。
    ///
    /// 既定の時計はフレーム番号から導くので、**同じスケッチを 2 回走らせれば
    /// 同じ絵が出る**。
    ///
    /// **出口が受け取るのと同じ道を通る** ([ADR-0024] 決定 6)。読み戻して CPU で
    /// 変換する経路と出るバイト列は同じだが ([#440] で画素まで一致することを測った)、
    /// 同じ道を通しておけば**一致が構造で保たれる** — 片方だけ直したときに黙って
    /// 食い違うことがなくなる。
    ///
    /// [#440]: https://github.com/mokume-metal/mokume/issues/440
    /// [ADR-0024]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0024-extension-seams.md
    public func renderFrame(to url: URL) throws {
        try advance()
        try PNGFile.write(try target.encodeToImage().read(), to: url)
    }

    // MARK: - 絵をファイルにする

    /// このフレームの絵を 1 枚だけ書き出すよう頼む。転送 (正本は ``Sketch/save(_:)``)。
    public func save(_ path: String) {
        requireRecorder().save(path)
        attachRecorderIfNeeded()
    }

    /// 連番を始める。転送 (正本は ``Sketch/beginRecord(_:)``)。
    public func beginRecord(_ pattern: String) {
        requireRecorder().beginRecord(pattern)
        attachRecorderIfNeeded()
    }

    /// 連番を止める。転送 (正本は ``Sketch/endRecord()``)。
    public func endRecord() {
        guard let recorder else {
            Diagnostics.warn("endRecord(): 撮っていません")
            return
        }
        recorder.endRecord()
    }

    /// 撮る係。**頼まれてはじめて作る** — 撮らないスケッチは 1 バイトも払わない。
    private func requireRecorder() -> FrameRecorder {
        if let recorder { return recorder }
        let made = FrameRecorder(frameRate: sketch.settings.frameRate)
        recorder = made
        return made
    }

    /// 頼まれているなら差込口の並びへ入れる。
    ///
    /// **入れ直すときは健康状態も新しくする。** 並びから外れている理由は「遊んでいた」か
    /// 「続けて転んで外された」かのどちらかで、次に明示的に頼まれた時点がどちらにとっても
    /// 仕切り直しになる。
    private func attachRecorderIfNeeded() {
        guard let recorder, !recorder.isIdle,
            !outlets.contains(where: { $0.outlet === recorder })
        else { return }
        outlets.append((recorder, SeamHealth()))
    }

    /// 頼まれているものが無くなったら並びから外す。
    ///
    /// 付けっぱなしにすると、1 枚だけ撮ったスケッチが以後ずっと毎フレーム道を通る
    /// ([ADR-0023] 決定 5)。続けて転んで外されたものも、並びに置いたままにしない。
    ///
    /// [ADR-0023]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0023-frame-stages-and-outputs.md
    private func detachRecorderIfDone() {
        guard let recorder,
            let entry = outlets.first(where: { $0.outlet === recorder }),
            recorder.isIdle || !entry.health.isAttached
        else { return }
        outlets.removeAll { $0.outlet === recorder }
    }

    // MARK: - 観測に応える

    /// 外から値を差し出す (``Sketch/expose(_:_:)-(_,Double)`` から呼ばれる)。
    ///
    /// 観測が有効でなければ溜めない。
    func expose(_ name: String, _ value: ExposedValue) {
        guard observer != nil else { return }
        exposedValues[name] = value
    }

    /// 要求が来ていれば応える。
    ///
    /// **止まっていても応える。** 返すのは最後に描いた絵で、観測のためにフレームを
    /// 進めることはしない — 観測の有無で番号が動くと、同じスケッチを 2 回走らせれば
    /// 同じ絵になるという性質が観測に壊される。
    ///
    /// 例外は「まだ 1 枚も描いていない」ときだけで、そのときは 1 枚描いてから応える。
    /// 最初の 1 枚は観測の有無によらず必ず描かれるものなので、再現性は損なわれない。
    ///
    /// **列を撮っている間は次の要求を拾わない。** 拾うと 2 つの列が同じ区画へ混ざり、
    /// どちらの目録も数が合わなくなる。
    ///
    /// - Parameter drawFailure: このフレームの描画が失敗していれば、その理由。
    private func serveObservationIfRequested(drawFailure: RenderFailure? = nil) {
        guard let observer else { return }
        if capture != nil {
            continueCapture(through: observer, drawFailure: drawFailure)
            return
        }
        guard let request = observer.pendingRequest() else { return }
        if drawFailure == nil, timing.frameCount == 0 {
            start()
            timing.advance()
            beginFrame()
            receiveInput()
            try? canvas.draw { withActiveRuntime { sketch.draw() } }
        }
        beginCapture(for: request, through: observer, drawFailure: drawFailure)
    }

    /// 列を撮り始める。1 枚だけの要求も同じ道を通る。
    ///
    /// 枚数で道が分かれると、めったに通らない側だけが腐る。1 枚は「1 枚で終わる列」
    /// として扱い、撮る・目録を書くの手順を 1 本に保つ。
    private func beginCapture(
        for request: ObservationRequest, through observer: FrameObserver,
        drawFailure: RenderFailure?
    ) {
        let limits = request.clamped()
        // 前回の成果物は**撮り始める前に**消す。新しい識別子の目録と古い絵が
        // 組にされると、読み手は古い絵を新しいと信じる (ADR-0018 決定 3)
        observer.clearProducts()

        // 描画に失敗したフレームでは描画先の中身が信用できないので、**絵は採りに
        // 行かない**。目録は空のまま、理由を載せて返す
        if let drawFailure {
            finish(
                id: request.id, through: observer, frames: [], complete: false,
                warnings: limits.warnings + ["このフレームの描画に失敗しました: \(drawFailure)"])
            return
        }
        capture = FrameCapture(
            id: request.id, scale: request.scale, count: limits.count, every: limits.every,
            warnings: limits.warnings)
        continueCapture(through: observer, drawFailure: nil)
    }

    /// 撮っている列を 1 フレームぶん進める。
    ///
    /// **フレームループは止めない。** 撮り終わるまで待つあいだもスケッチは描き続ける —
    /// 止めてから撮ると、測っている対象そのものが変わってしまう。
    private func continueCapture(through observer: FrameObserver, drawFailure: RenderFailure?) {
        guard var pending = capture else { return }

        if let drawFailure {
            // 途中で描けなくなったら、そこまでの絵は目録に残したまま打ち切る。
            // 絵が揃っていないことは「宣言した数と合わない」で読み手に伝わる
            capture = nil
            finish(
                id: pending.id, through: observer, frames: pending.frames, complete: false,
                warnings: pending.warnings + ["このフレームの描画に失敗しました: \(drawFailure)"])
            return
        }

        guard pending.wait == 0 else {
            pending.wait -= 1
            capture = pending
            return
        }

        do {
            // **出口が受け取るのと同じ道を通す** ([ADR-0024] 決定 6)。小さくするのは
            // 通した後で、出るバイト列は通す前に間引いたのと同じである (#382)
            let image = try target.encodeToImage().read().scaled(by: pending.scale)
            let name = try observer.writeFrame(image, at: pending.frames.count)
            pending.frames.append(
                ObservationReport.CapturedFrame(
                    image: name,
                    frame: timing.frameCount,
                    time: Double(timing.time),
                    stats: FrameStats.summarize(image),
                    values: exposedValues.isEmpty ? nil : exposedValues))
        } catch {
            // 採れなくても黙らない。読み手が「まだか / 失敗か / 死んだか」を
            // 区別できるようにするため (ADR-0018 決定 3)
            capture = nil
            finish(
                id: pending.id, through: observer, frames: pending.frames, complete: false,
                warnings: pending.warnings + ["絵を採れませんでした: \(error)"])
            return
        }

        guard pending.frames.count < pending.count else {
            capture = nil
            // 描けてはいるが直っていないもの (組み立てに失敗した断片など) は、
            // 目録の警告として出す。**絵が出ているぶん、これが無いと気付けない**
            finish(
                id: pending.id, through: observer, frames: pending.frames, complete: true,
                warnings: pending.warnings + canvas.shaderFailures
                    + Self.repetitionWarnings(pending.frames))
            return
        }
        pending.wait = pending.every - 1
        capture = pending
    }

    /// 目録を書いて、この要求を終える。
    ///
    /// 上の階の `image` / `frame` / `time` / `stats` は**最後に撮った 1 枚**を指す。
    /// 揃わなかったときは `image` を落とす — 読み手はこの鍵の有無だけで成否を言える。
    private func finish(
        id: String, through observer: FrameObserver,
        frames: [ObservationReport.CapturedFrame], complete: Bool, warnings: [String]
    ) {
        let last = complete ? frames.last : nil
        try? observer.finish(
            ObservationReport(
                id: id,
                image: last?.image,
                frame: timing.frameCount,
                time: Double(timing.time),
                size: ObservationReport.Size(width: target.width, height: target.height),
                warnings: warnings,
                stats: last?.stats,
                load: RuntimeLoad.sample(tempo: tempo, now: now()),
                values: exposedValues.isEmpty ? nil : exposedValues,
                stamp: SourceStamp.current,
                frames: frames))
    }

    /// 同じフレームが並んでいたら、そのことわり。
    ///
    /// 止めているあいだに列を頼むと、同じ絵が枚数ぶん並ぶ。**それは応答としては正しい**
    /// (画面に出ているのはその絵である) が、動きを見たい読み手には見分けが付かない。
    /// フレーム番号という事実から導けるので、止まっているかどうかの旗を見に行かない。
    private static func repetitionWarnings(_ frames: [ObservationReport.CapturedFrame]) -> [String]
    {
        let numbers = frames.map(\.frame)
        guard numbers.count > 1, Set(numbers).count < numbers.count else { return [] }
        return ["同じフレームが並んでいます (進んでいないあいだに撮ると、絵は動きません)"]
    }

    /// 撮っている最中の列。
    private struct FrameCapture {
        let id: String
        let scale: Double
        /// 撮る枚数 (上限で切った後)。
        let count: Int
        /// 何フレームおきに撮るか (上限で切った後)。
        let every: Int
        /// 目録に載せることわり。切り詰めたことなど、撮り始める前に決まるもの。
        var warnings: [String]
        /// ここまでに撮れた絵。
        var frames: [ObservationReport.CapturedFrame] = []
        /// 次に撮るまで残っているフレーム数。0 ならこのフレームで撮る。
        var wait = 0
    }

    /// いま走っているランタイムとして自分を差し込んでから `body` を実行する。
    ///
    /// 差し込みを入れ子にしても壊れないよう、前の値へ必ず戻す。
    private func withActiveRuntime(_ body: () -> Void) {
        let previous = runningSketch
        runningSketch = self
        defer { runningSketch = previous }
        body()
    }
}
