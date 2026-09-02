// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import AppKit
import IOSurface
import Metal
import MokumeDiagnostics
import QuartzCore

/// 別のプロセスが差し出している絵を、1 つの窓に出す台。
///
/// ## なぜ台を分けるのか
///
/// 道具は窓を 2 種類出す — 何も載せない**作品の窓** (``SharedFrameWindow``) と、制作を
/// 助けるものが載る**プレビュー** (``SharedFramePreview``)。両者の違いは**見た目だけ**で、
/// 区画の見張り方も面の引き方も差し出し方も同じである ([ADR-0032] 決定 1)。
///
/// 二重に書けば片方だけが直る形になるので、同じところはここに 1 つ持つ。
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
final class SharedFrameStage: NSObject {
    /// 窓の見た目。**台が決めないもの**をここへ集める。
    struct Look {
        /// 窓の名前。
        let title: String
        /// 位置を覚えるときの名前。**窓ごとに別にする** — 同じ名前だと互いの位置を
        /// 上書きし合い、2 枚が重なって開く。
        let autosaveName: String
        /// 覚えている枠が無いときの大きさ。
        let defaultSize: NSSize
        /// 覚えている枠が無いとき、中央からどれだけずらすか。
        ///
        /// **2 枚が重なって開くのを避ける。** 作品の窓とプレビューは同じ大きさで中央へ
        /// 出るので、ずらさないと**寸分違わず重なり**、窓が 1 つしか無いように見える (実測)。
        /// 一度動かせば以後は覚えた位置が使われるので、効くのは初めての 1 回だけである。
        var nudge: NSSize = .zero
    }

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
    private let look: Look
    private let presenter: FramePresenter

    /// 窓が拾った出来事の行き先。**渡ってくるのはそのまま子の標準入力へ書ける 1 行。**
    ///
    /// 窓を出した後に差し替えてもよい (見張りは子を入れ替えるので、書き先は変わる)。
    var onInput: ((String) -> Void)?

    /// 表示のリフレッシュごとに呼ばれる。**絵が来ていなくても呼ぶ** — 面を読み直す側は
    /// 絵の有無と関係なく進む必要がある。
    var onTick: (() -> Void)?

    private(set) var window: NSWindow?
    private var view: SketchSurface?

    /// 重ねる面を足す先。**窓が出ている間だけ在る。**
    ///
    /// 後から差し替えられるようにしてあるのは、宣言の顔ぶれが変わったらつまみを
    /// 組み直すためである ([ADR-0032] 決定 5)。
    var host: NSView? { view }
    private var displayLink: CADisplayLink?
    private var linkedScreen: NSScreen?

    private var source: Source?
    /// 区画を最後に読んだときのファイルの更新時刻。**変わったときだけ読み直す。**
    private var manifestReadAt: Date?
    /// 最後に画面へ出した枚数。**同じ絵を二度出さない**ための目印。
    private var lastFrame = 0
    /// 最後に面から読んだ枚数。**出せた枚数とは別に持つ** — 差し出しに失敗した回でも
    /// 数字は届いているので、`lastFrame` に相乗りさせると失敗した回だけ数字が古くなる。
    private var lastSeenFrame = 0
    /// 走っている側が数えた速さ。**自分では数えない** ([ADR-0030] 決定 7)。
    private var tempo = RemoteTempo()
    /// 続けて差し出せなかった数。始まりと終わりだけ言うために持つ。
    private var consecutiveFailures = 0

    /// - Parameter facet: 差し出し元の番号が置かれる区画 (`.mokume/viewport`)。
    init(gpu: RenderDevice, facet: URL, look: Look) throws(RenderFailure) {
        self.gpu = gpu
        self.facet = facet
        self.look = look
        self.presenter = try FramePresenter(gpu: gpu, pixelFormat: RenderTarget.pixelFormat)
        super.init()
    }

    /// 窓を出し、区画を見張り始める。
    ///
    /// **覚えている位置があればそこへ戻す。** 覚え方は走っているスケッチの窓と同じ
    /// (`WindowPlacement`) — 使う人から見れば同じ「スケッチの窓」なので、起こし方で
    /// 置き場所が変わらないほうがよい。
    ///
    /// - Parameter overlay: 絵に重ねる面。**無ければ何も足さない** — 作品の窓に道具の
    ///   都合が 1 画素も出ないのは、ここに何も渡さないことで成り立っている
    ///   ([ADR-0032] 決定 1)。
    func open(overlay: NSView? = nil) {
        // 大きさは差し出し元が来るまで分からない。**来てから合わせる**ので、ここは
        // 覚えている枠が無いときの初期値でしかない
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: look.defaultSize),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false)
        window.title = look.title
        // **畳んだときに窓が自分を解放しないようにする。** 素の `NSWindow` の既定は
        // 「閉じたら解放する」で、こちらは強い参照を持ったまま `close()` を呼ぶので、
        // そのままだと二重に解放される — 症状は検査の走り終わりでの落下 (signal 11) と
        // いう、原因から遠いところにしか出ない
        window.isReleasedWhenClosed = false
        if !window.setFrameUsingName(look.autosaveName) {
            window.center()
            if look.nudge != .zero {
                let origin = window.frame.origin
                window.setFrameOrigin(
                    NSPoint(x: origin.x + look.nudge.width, y: origin.y + look.nudge.height))
            }
        }
        window.setFrameAutosaveName(look.autosaveName)

        // **面はスケッチの窓と同じものを使う。** 画素形式・色空間・EDR の既定を 1 か所に
        // 保つためで、別に作ると片方だけが規範から外れる (ADR-0011)
        let view = SketchSurface(
            frame: NSRect(origin: .zero, size: window.contentLayoutRect.size),
            device: gpu.device, input: InputState(), canvasSize: (1, 1))
        view.wantsLayer = true
        view.autoresizingMask = [.width, .height]
        // **窓より先に繋ぐ。** 出してから繋ぐと、その隙間に触ったぶんが落ちる
        view.relay = { [weak self] line in self?.onInput?(line) }
        window.contentView = view
        // **絵の面へ足す。** 別の窓にしないのは、重ねるものが絵と一緒に動く必要が
        // あるからで、経路そのものは絵と別のまま (AppKit の層) である
        if let overlay { view.addSubview(overlay) }
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
    func close() {
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
        onTick?()
        reloadSourceIfChanged()
        guard let source, let view, let layer = view.metalLayer,
            let newest = SharedFrameSurface.newest(among: source.ids)
        else { return }
        readNumbers(from: newest)
        guard newest.frame != lastFrame, let frame = source.frames[newest.id] else { return }
        do {
            // **出せた枚数だけを覚える。** 面を取れずに見送ったときに覚えると、次の
            // リフレッシュで「同じ枚数だから出さない」と判断して 1 枚落とす
            if try presenter.present(frame, to: layer) { lastFrame = newest.frame }
            noteRecovery()
        } catch {
            noteFailure(error)
        }
    }

    // MARK: - 速さ

    /// いま名乗ってよい速さ。**しばらく新しい絵が来なければ `nil`** (``RemoteTempo``)。
    var numbers: FrameNumbers? { tempo.numbers(now: CACurrentMediaTime()) }

    /// 新しい絵が来ていれば、その面に載っている速さを読む。
    ///
    /// **新しい枚数のときだけ引く。** 同じ絵に対して引き直しても数字は変わらないので、
    /// 毎リフレッシュ読むぶんだけ無駄になる。
    private func readNumbers(from newest: (id: UInt32, frame: Int)) {
        guard newest.frame != lastSeenFrame else { return }
        lastSeenFrame = newest.frame
        guard let numbers = SharedFrameSurface.numbers(of: newest.id) else { return }
        tempo.record(numbers, at: CACurrentMediaTime())
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
        // 覚えたままだと、そこへ追い付くまで 1 枚も出さないことになる (速さも同じで、
        // 追い付くまで前の子の数字を名乗り続けることになる)
        lastFrame = 0
        lastSeenFrame = 0
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
