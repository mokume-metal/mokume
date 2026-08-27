// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import AppKit
import QuartzCore

/// スケッチをアプリケーションとして走らせる。
///
/// 窓とアプリケーションの寿命は AppKit が持つ ([ADR-0012] 決定 4)。フレームを進める
/// 判断はランタイムのままで、ここは**表示のリフレッシュに合わせて `advance()` を叩く
/// 3 つ目の駆動源**を足すだけである ([ADR-0012] 決定 3)。
///
/// [ADR-0012]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0012-view-layer.md
@MainActor
public final class SketchApplication: NSObject, NSApplicationDelegate {
    private let gpu: RenderDevice
    private let runtime: SketchRuntime
    private let presenter: FramePresenter
    private let title: String

    private var window: NSWindow?
    private var surface: SketchSurface?
    private var displayLink: CADisplayLink?

    /// 直近に測ったフレームレート。
    public private(set) var measuredFrameRate: Double = 0
    private var frameRateWindowStart: Double = 0
    private var frameRateWindowCount = 0

    /// 面を取れずに見送ったフレームの数。
    public var missedFrames: Int { presenter.missedFrames }

    /// 窓がいま画面に出ているか。
    public var isWindowOnScreen: Bool { window?.isVisible ?? false }

    /// スケッチを画面に出す用意をする。
    ///
    /// 時刻の出どころは**実時間**にする — 画面に出しながら動かす経路なので、
    /// 実際に流れた時間で動くのが正しい。
    public init(sketch: any Sketch, gpu: RenderDevice) throws(RenderFailure) {
        self.gpu = gpu
        self.title = sketch.settings.title
        self.runtime = try SketchRuntime(sketch: sketch, gpu: gpu, clock: .wallClock)
        self.presenter = try FramePresenter(gpu: gpu, pixelFormat: RenderTarget.pixelFormat)
        super.init()
    }

    /// アプリケーションとして走らせる。戻らない。
    public func run() {
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        app.delegate = self
        // **自分を強く持っておく。** AppKit は delegate を弱く参照するので、
        // ここで持たないと、delegate を渡した直後に自分が解放され、以後の
        // 呼び出しが 1 つも来ない (窓が開かない形で表に出る)。走らせている間は
        // 生きているべきものなので、寿命をここで固定する
        SketchApplication.running = self
        app.run()
    }

    /// いま走らせているもの。``run()`` の間だけ入る。
    private static var running: SketchApplication?

    public func applicationDidFinishLaunching(_ notification: Notification) {
        let settings = runtime.sketch.settings
        // 窓は描く解像度の半分で開く。描く解像度と窓の大きさは独立なので、
        // どちらに合わせてもよい — 大きな絵が画面からはみ出さない側を既定にする
        let contentSize = NSSize(width: settings.width / 2, height: settings.height / 2)
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: contentSize),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false)
        window.title = title
        window.center()

        let surface = SketchSurface(
            frame: NSRect(origin: .zero, size: contentSize), device: gpu.device)
        surface.wantsLayer = true
        surface.autoresizingMask = [.width, .height]
        window.contentView = surface
        window.makeKeyAndOrderFront(nil)
        surface.synchronizeDrawableSize()

        self.window = window
        self.surface = surface

        NSApp.activate()

        let link = surface.displayLink(target: self, selector: #selector(step(_:)))
        // **表示のリフレッシュ率をそのまま使わない。** 画面が 120 Hz なら 120 回
        // 呼ばれてしまい、スケッチが求めたフレームレートが無視される。求めた値を
        // 上限にも下限にも据えて、画面の性能に引きずられないようにする
        let rate = Float(max(1, settings.frameRate))
        link.preferredFrameRateRange = CAFrameRateRange(
            minimum: rate, maximum: rate, preferred: rate)
        link.add(to: .main, forMode: .common)
        self.displayLink = link
        frameRateWindowStart = CACurrentMediaTime()
    }

    public func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    public func applicationWillTerminate(_ notification: Notification) {
        displayLink?.invalidate()
        displayLink = nil
    }

    /// 表示のリフレッシュごとに 1 フレーム進めて差し出す。
    @objc private func step(_ link: CADisplayLink) {
        guard let surface, let layer = surface.metalLayer else { return }
        do {
            try runtime.advance()
            try presenter.present(runtime.target, to: layer)
        } catch {
            // 1 フレーム描けなかったことでアプリケーションごと落とさない。
            // 次のリフレッシュでもう一度試す
            return
        }
        recordFrameRate()
    }

    private func recordFrameRate() {
        frameRateWindowCount += 1
        let now = CACurrentMediaTime()
        let elapsed = now - frameRateWindowStart
        guard elapsed >= 1 else { return }
        measuredFrameRate = Double(frameRateWindowCount) / elapsed
        frameRateWindowCount = 0
        frameRateWindowStart = now
    }
}

// MARK: - 入口

extension Sketch {
    /// スケッチを起動する (`@main` から呼ばれる)。
    public static func main() {
        do {
            let gpu = try RenderDevice()
            let application = try SketchApplication(sketch: Self(), gpu: gpu)
            application.run()
        } catch {
            FileHandle.standardError.write(
                Data("スケッチを起動できませんでした: \(error)\n".utf8))
            exit(1)
        }
    }
}
