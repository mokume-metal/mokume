// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation
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

    /// 外から観測されるための窓口。区画が無ければ `nil` で、**そのときフレームループは
    /// 観測の存在を一切払わない** (ADR-0018 の面が満たすべき性質)。
    private let observer: FrameObserver?
    /// 外から送られる入力の受け口。区画が無ければ `nil`。
    private let inbox: InputInbox?
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
    /// 直近のフレームの間隔 (秒)。観測が無ければ測らない。
    private var frameIntervals: [Double] = []
    private var previousFrameStart: Double?

    /// 間隔をどれだけ遡って平均するか。
    private static let frameIntervalWindow = 60

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
    }

    /// 観測の窓口を差し替えられる入口 (検査用)。
    init(
        sketch: any Sketch,
        gpu: RenderDevice,
        clock: Clock?,
        now: @escaping () -> Double,
        observer: FrameObserver?,
        inbox: InputInbox? = nil
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
    }

    // MARK: - 進める

    /// 一度だけの初期化を走らせる。``advance()`` が要れば自分で呼ぶので、
    /// 明示的に呼ばなくてもよい。
    public func start() {
        guard !hasSetUp else { return }
        hasSetUp = true
        withActiveRuntime { sketch.setup() }
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
        guard !isPaused else {
            serveObservationIfRequested()
            return
        }
        start()
        timing.advance()
        beginFrame()
        receiveInput()

        var drawFailure: RenderFailure?
        canvas.time = timing.time
        canvas.deltaTime = timing.deltaTime
        do {
            try canvas.draw { withActiveRuntime { sketch.draw() } }
        } catch {
            drawFailure = error
        }
        serveObservationIfRequested(drawFailure: drawFailure)
        if let drawFailure { throw drawFailure }
    }

    /// 溜まった入力をこのフレームへ流し込む。
    ///
    /// **`draw()` の前に流す。** 送られた出来事が同じフレームの `draw()` から見える —
    /// 1 フレーム遅れて効く形にすると、外から動かして確かめるときに毎回 1 枚ぶんずれる。
    private func receiveInput() {
        inbox?.drain(into: input)
        input.beginFrame()
    }

    /// フレームの頭で片付けること。観測が無ければどれも空回りしない。
    private func beginFrame() {
        guard observer != nil else { return }
        exposedValues.removeAll(keepingCapacity: true)
        let started = now()
        if let previous = previousFrameStart {
            frameIntervals.append(started - previous)
            if frameIntervals.count > Self.frameIntervalWindow { frameIntervals.removeFirst() }
        }
        previousFrameStart = started
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
    public func renderFrame(to url: URL) throws {
        try advance()
        try target.writePNG(to: url)
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
            let image = try target.encodeForDisplay(scale: pending.scale)
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
                load: RuntimeLoad.sample(frameDurations: frameIntervals),
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
