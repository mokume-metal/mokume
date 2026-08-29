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
    /// 描画先。
    public var target: RenderTarget { canvas.target }

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
        self.canvas = try Canvas(target: target, gpu: gpu)
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
        self.canvas = try Canvas(target: target, gpu: gpu)
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
    /// - Parameter drawFailure: このフレームの描画が失敗していれば、その理由。
    private func serveObservationIfRequested(drawFailure: RenderFailure? = nil) {
        guard let observer, let request = observer.pendingRequest() else { return }
        if drawFailure == nil, timing.frameCount == 0 {
            start()
            timing.advance()
            beginFrame()
            receiveInput()
            try? canvas.draw { withActiveRuntime { sketch.draw() } }
        }
        respond(to: request, through: observer, drawFailure: drawFailure)
    }

    private func respond(
        to request: ObservationRequest, through observer: FrameObserver,
        drawFailure: RenderFailure? = nil
    ) {
        let size = ObservationReport.Size(width: target.width, height: target.height)
        let values = exposedValues.isEmpty ? nil : exposedValues

        // 描画に失敗したフレームでは描画先の中身が信用できないので、**絵は採りに
        // 行かない**。前回の絵は `image: nil` の応答が先に消すので、読み手が古い絵を
        // 新しいと信じることもない (ADR-0018 決定 3)
        if let drawFailure {
            try? observer.respond(
                ObservationReport(
                    id: request.id,
                    image: nil,
                    frame: timing.frameCount,
                    time: Double(timing.time),
                    size: size,
                    warnings: ["このフレームの描画に失敗しました: \(drawFailure)"],
                    load: RuntimeLoad.sample(frameDurations: frameIntervals),
                    values: values,
                    stamp: SourceStamp.current),
                image: nil)
            return
        }

        do {
            let image = try target.encodeForDisplay(scale: request.scale)
            // 描けてはいるが直っていないもの (組み立てに失敗した断片など) は、
            // 応答の警告として出す。**絵が出ているぶん、これが無いと気付けない**
            let failures = canvas.shaderFailures
            try observer.respond(
                ObservationReport(
                    id: request.id,
                    image: FrameObserver.imageFileName,
                    frame: timing.frameCount,
                    time: Double(timing.time),
                    size: size,
                    warnings: failures,
                    stats: FrameStats.summarize(image),
                    load: RuntimeLoad.sample(frameDurations: frameIntervals),
                    values: values,
                    stamp: SourceStamp.current),
                image: image)
        } catch {
            // 採れなくても黙らない。読み手が「まだか / 失敗か / 死んだか」を
            // 区別できるようにするため (ADR-0018 決定 3)
            try? observer.respond(
                ObservationReport(
                    id: request.id,
                    image: nil,
                    frame: timing.frameCount,
                    time: Double(timing.time),
                    size: size,
                    warnings: ["絵を採れませんでした: \(error)"],
                    load: RuntimeLoad.sample(frameDurations: frameIntervals),
                    values: values,
                    stamp: SourceStamp.current),
                image: nil)
        }
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
