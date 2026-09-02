// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import AppKit
import IOSurface
import Metal
import MokumeDiagnostics
import QuartzCore

/// 別のプロセスが差し出している絵を、窓に出す。
///
/// ## なぜ道具が窓を持つのか
///
/// 見張り (`watch`) は保存のたびに子を入れ替えるので、**子が窓を持つ限り窓は死ぬ**。
/// 全画面と、どの画面に置いたかは窓の寿命に紐づいているので、作り直しのたびに一緒に
/// 失われる — 位置を覚えて開き直しても戻らない。見張りから起こした作品も本番になりうる
/// 以上、これは**本番の見え方が保存のたびに壊れる**ということである
/// ([ADR-0032] 決定 1)。
///
/// ## ここに道具の都合を出さない
///
/// これは**作品の窓**である。つまみも、作り直しの状態も、回っている印も載せない — 見張り
/// から本番を回している間、開発の都合が本番の画面に出てはならない ([ADR-0032] 決定 1・6)。
/// それらはプレビューの仕事で、別の窓が持つ。
///
/// ## 焼き直さない
///
/// 出力段を走らせたのは子である ([ADR-0032] 決定 2)。ここが渡す明るさは既定なので、
/// 差し出しの断片は早期に返して画素に 1 ビットも触らない — 面に載っている 1.0 超の
/// 明るさがそのまま画面へ届く。
///
/// ## 子の入れ替わりに、外から知らせなくてよい
///
/// 差し出し元は区画に置かれた番号で決まるので、**区画を見張っていれば自分で気付く**。
/// 道具の側に「差し替えろ」と言う口を作らないのは、言い忘れが「絵が古いまま」という
/// 形でしか出ないためである。
///
/// [ADR-0032]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0032-window-ownership.md
@MainActor
public final class SharedFrameWindow: NSObject {
    /// 面の 1 枚を、差し出せる形にしたもの。
    private struct Frame: PresentableFrame {
        let texture: any MTLTexture
        let width: Int
        let height: Int
        /// **焼き直さない** ([ADR-0032] 決定 2)。既定は断片が早期に返す設定である。
        let brightness = Brightness.default
    }

    /// いま見ている差し出し元。
    private struct Source {
        let ids: [UInt32]
        let width: Int
        let height: Int
        /// 番号ごとのテクスチャ。引けなかった面は入らない。
        let frames: [UInt32: Frame]
    }

    private let gpu: RenderDevice
    private let facet: URL
    private let title: String
    private let presenter: FramePresenter

    private var window: NSWindow?
    private var view: SketchSurface?
    private var displayLink: CADisplayLink?
    private var linkedScreen: NSScreen?

    private var source: Source?
    /// 区画を最後に読んだときのファイルの更新時刻。**変わったときだけ読み直す。**
    private var manifestReadAt: Date?
    /// 最後に画面へ出した枚数。**同じ絵を二度出さない**ための目印。
    private var lastFrame = 0
    /// 続けて差し出せなかった数。始まりと終わりだけ言うために持つ。
    private var consecutiveFailures = 0

    /// - Parameters:
    ///   - facet: 差し出し元の番号が置かれる区画 (`.mokume/viewport`)。
    ///   - title: 窓の名前。
    public init(gpu: RenderDevice, facet: URL, title: String) throws(RenderFailure) {
        self.gpu = gpu
        self.facet = facet
        self.title = title
        self.presenter = try FramePresenter(gpu: gpu, pixelFormat: RenderTarget.pixelFormat)
        super.init()
    }

    /// 窓を出し、区画を見張り始める。
    ///
    /// **覚えている位置があればそこへ戻す。** 覚え方は走っているスケッチの窓と同じ
    /// (`WindowPlacement`) — 使う人から見れば同じ「スケッチの窓」なので、起こし方で
    /// 置き場所が変わらないほうがよい。
    public func open() {
        // 大きさは差し出し元が来るまで分からない。**来てから合わせる**ので、ここは
        // 覚えている枠が無いときの初期値でしかない
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: NSSize(width: 480, height: 270)),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false)
        window.title = title
        if !window.setFrameUsingName(WindowPlacement.autosaveName) { window.center() }
        window.setFrameAutosaveName(WindowPlacement.autosaveName)

        // **面はスケッチの窓と同じものを使う。** 画素形式・色空間・EDR の既定を 1 か所に
        // 保つためで、別に作ると片方だけが規範から外れる (ADR-0011)
        let view = SketchSurface(
            frame: NSRect(origin: .zero, size: window.contentLayoutRect.size),
            device: gpu.device, input: InputState(), canvasSize: (1, 1))
        view.wantsLayer = true
        view.autoresizingMask = [.width, .height]
        window.contentView = view
        window.makeKeyAndOrderFront(nil)
        view.synchronizeDrawableSize()

        self.window = window
        self.view = view

        NotificationCenter.default.addObserver(
            self, selector: #selector(windowChangedScreen(_:)),
            name: NSWindow.didChangeScreenNotification, object: window)
        attachDisplayLink(to: window.screen ?? NSScreen.main)
    }

    /// 畳む。
    public func close() {
        displayLink?.invalidate()
        displayLink = nil
        NotificationCenter.default.removeObserver(self)
        window?.close()
        window = nil
        view = nil
    }

    // MARK: - 駆動

    /// 表示のリフレッシュに紐づける。
    ///
    /// **速さを指定しない。** こちらは絵を作っていないので、差し出し元より速く回っても
    /// 出す枚数は増えない (同じ枚数なら出さない)。画面の速さに任せるほうが、相手が何 fps
    /// でも遅れが最小になる。
    private func attachDisplayLink(to screen: NSScreen?) {
        guard let screen else { return }
        displayLink?.invalidate()
        let link = screen.displayLink(target: self, selector: #selector(step(_:)))
        link.add(to: .main, forMode: .common)
        displayLink = link
        linkedScreen = screen
    }

    @objc private func windowChangedScreen(_ notification: Notification) {
        guard let screen = window?.screen, screen !== linkedScreen else { return }
        attachDisplayLink(to: screen)
    }

    @objc private func step(_ link: CADisplayLink) {
        reloadSourceIfChanged()
        guard let source, let view, let layer = view.metalLayer,
            let newest = SharedFrameSurface.newest(among: source.ids),
            newest.frame != lastFrame,
            let frame = source.frames[newest.id]
        else { return }
        do {
            // **出せた枚数だけを覚える。** 面を取れずに見送ったときに覚えると、次の
            // リフレッシュで「同じ枚数だから出さない」と判断して 1 枚落とす
            if try presenter.present(frame, to: layer) { lastFrame = newest.frame }
            noteRecovery()
        } catch {
            noteFailure(error)
        }
    }

    // MARK: - 差し出し元

    /// 区画が変わっていれば読み直す。
    ///
    /// **更新時刻で見る。** 毎フレーム読み解くのは無駄で、中身が変わるのは子が入れ替わった
    /// ときだけである。
    private func reloadSourceIfChanged() {
        let url = facet.appendingPathComponent(SharedFrameSurface.manifestName)
        let modified = (try? FileManager.default.attributesOfItem(atPath: url.path))?[
            .modificationDate] as? Date
        guard let modified else { return }
        guard modified != manifestReadAt else { return }
        manifestReadAt = modified
        guard let manifest = SharedFrameSurface.readManifest(at: facet) else { return }
        adopt(manifest)
    }

    /// 新しい差し出し元へ乗り換える。
    private func adopt(_ manifest: (ids: [UInt32], width: Int, height: Int)) {
        // **前の面を常駐から外す。** 外さないと、見張っている間ずっと死んだ面が積み上がる
        if let previous = source {
            try? gpu.releaseResidency(of: previous.frames.values.map(\.texture))
        }
        var frames: [UInt32: Frame] = [:]
        for id in manifest.ids {
            guard let frame = makeFrame(id: id, width: manifest.width, height: manifest.height)
            else { continue }
            frames[id] = frame
        }
        guard !frames.isEmpty else {
            // 引けなかった = 置いた側が既に居ない。**直前の絵はそのまま残す** (決定 6)
            source = nil
            return
        }
        source = Source(
            ids: manifest.ids, width: manifest.width, height: manifest.height, frames: frames)
        // 触った操作を写す規則は描く解像度に依る (レーン 4 で使う)
        view?.setCanvasSize((manifest.width, manifest.height))
        // **枚数の数え直しに備える。** 新しい子は 1 から数えるので、前の子の枚数を
        // 覚えたままだと、そこへ追い付くまで 1 枚も出さないことになる
        lastFrame = 0
    }

    /// 番号から面を引き、差し出せる形にする。
    private func makeFrame(id: UInt32, width: Int, height: Int) -> Frame? {
        guard let surface = IOSurfaceLookup(id) else { return nil }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: RenderTarget.pixelFormat, width: width, height: height, mipmapped: false)
        descriptor.usage = [.shaderRead]
        guard
            let texture = gpu.device.makeTexture(
                descriptor: descriptor, iosurface: surface, plane: 0)
        else { return nil }
        gpu.makeResident(texture)
        return Frame(texture: texture, width: width, height: height)
    }

    // MARK: - 言うこと

    /// 出せなかったことを 1 度だけ言う。**握り潰すと、絵が止まった理由がどこにも残らない。**
    private func noteFailure(_ failure: RenderFailure) {
        consecutiveFailures += 1
        guard consecutiveFailures == 1 else { return }
        Diagnostics.warn("差し出せませんでした: \(failure.headline) — 次のリフレッシュで試し直します")
    }

    private func noteRecovery() {
        guard consecutiveFailures > 0 else { return }
        Diagnostics.warn("差し出しが回復しました (\(consecutiveFailures) 枚ぶん飛ばしました)")
        consecutiveFailures = 0
    }
}
