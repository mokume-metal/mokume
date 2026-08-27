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
    private var hasSetUp = false
    private var isPaused = false

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
    /// 止めている間は何もしない — **止めたのに進む**経路を作らないため。
    public func advance() throws(RenderFailure) {
        guard !isPaused else { return }
        start()
        timing.advance()
        try canvas.draw { withActiveRuntime { sketch.draw() } }
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
