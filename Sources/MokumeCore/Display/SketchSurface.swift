// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import AppKit
import Metal
import QuartzCore

/// 絵を映す面。
///
/// [MTKView] のような出来合いの部品は使わず、`CAMetalLayer` を直接持つ
/// ([ADR-0012] 決定 2)。理由は 3 つ:
///
/// - 画素の形式・色空間・拡張ダイナミックレンジの設定を、[ADR-0011] の規範に合わせて
///   直接指定できる
/// - 差し出す間合いを自分で決められる
/// - フレームの駆動を部品の側に握られない ([ADR-0012] 決定 3)
///
/// ## 触った操作の行き先
///
/// 面が拾ったマウス・キー・スクロールは、**外から送られたものと同じ合流点**
/// (``InputState``) へ入る ([ADR-0018] 決定 1)。窓側だけが座標の変換を通る —
/// 外から送るときは既にキャンバスの座標だからである (``SurfaceMapping``)。
///
/// ## カーソルを捕まえる
///
/// 捕まえるかの判定 (``PointerLock``) もこの面が持つ。直に走らせた窓も、道具が出す 2 つの窓も
/// この部品なので、捕まえ方は 1 か所に書ける。捕まえている間は位置ではなく量を送り
/// (``motion(isLocked:location:delta:)``)、押下と解放は捕まえた時点の位置を名乗る
/// ([#1144](https://github.com/mokume-metal/mokume/issues/1144))。
///
/// [ADR-0011]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0011-color-model.md
/// [ADR-0012]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0012-view-layer.md
/// [ADR-0018]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0018-observation-and-control-surface.md
final class SketchSurface: NSView {
    /// 面を作る GPU。**渡さないと面が作れない** — 描く先を用意できないレイヤは
    /// 差し出す面を返さず、絵は 1 枚も出ないまま静かに終わる。
    private let device: any MTLDevice

    /// 拾った操作の行き先。**省略できない** — 入力の行き先を持たない面を作れると、
    /// 「窓は出ているのに触っても効かない」がまた作れてしまう
    /// ([#217](https://github.com/mokume-metal/mokume/issues/217))。
    private let input: InputState
    /// 描く解像度。窓の大きさとは独立。
    ///
    /// **走っているスケッチの窓では変わらない**が、道具が出す窓では**差し替わる** —
    /// 見張りが起こし直した子が別の解像度を名乗ることがあるためである
    /// ([ADR-0032](https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0032-window-ownership.md) 決定 1)。
    ///
    /// 検査から読む (入力の写しがどの寸法に依っているか)。
    private(set) var canvasWidth: Double
    private var canvasHeight: Double

    /// 拾った出来事を、合流点のほかにもう 1 か所へ渡す口。
    ///
    /// **道具の窓のためにある。** 絵を描いているのは別のプロセスなので、拾っただけでは
    /// 何も起きない — 運ばないと効かない ([ADR-0032](https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0032-window-ownership.md) 決定 4)。
    /// 渡すのは**そのまま子の標準入力へ書ける 1 行**で、道具は中身を見ずに転送する。
    var relay: ((String) -> Void)?

    /// 自分が足した、押していない間の移動を配信させる領域 (``updateTrackingAreas()``)。
    /// 外すときにこれだけを名指しできるように覚えておく。
    fileprivate var pointerTracking: NSTrackingArea?

    /// カーソルを捕まえるかの判定 ([#1144](https://github.com/mokume-metal/mokume/issues/1144))。
    /// **この面が観たこと** (押された・Escape・窓が退いた・畳まれる) を伝え、スケッチの要求は
    /// 窓を持つ側が ``followPointerLock(requested:)`` で渡す。
    let pointerLock = PointerLock()

    /// 矢印のカーソルを隠すかの判定 ([#2439](https://github.com/mokume-metal/mokume/issues/2439))。
    /// ``pointerLock`` と同じく、スケッチの要求は窓を持つ側が ``followCursorHiding(requested:)`` で渡し、
    /// 窓の状況はこの面が答える。
    let cursorHiding = CursorHiding()

    /// 最後に合流点へ名乗った位置 (キャンバスの座標)。**捕まえている間の押下と解放はここを
    /// 名乗る** — 捕まえた時点の位置で、捕まえている間は動かない。
    fileprivate var lastPoint: (x: Float, y: Float)?

    /// 退く・閉じる知らせを受けている窓。外すときに名指しする。
    fileprivate weak var observedWindow: NSWindow?

    /// この面が合流点へ押下として流し、まだ解放を流していないキーと釦。
    ///
    /// **窓が前から退いたら、ここに残っているものへ解放を流す** (``releaseHeld()``)。退いている
    /// 間に離したキーは窓へ届かないので、流さないと押されたまま残る
    /// ([#2443](https://github.com/mokume-metal/mokume/issues/2443))。持つのは面が流した分だけで、
    /// 外から注入した押下は離さない — 人が触っていないものを、窓の都合で動かさない。
    fileprivate var heldKeys: Set<Key> = []
    fileprivate var heldButtons: Set<MouseButton> = []
    /// 退いたときに離した扱いにした釦。**その後に届く本物の解放は流さない** — 押した窓は
    /// 解放も受け取るので、流すと `mouseReleased()` が 2 度呼ばれる。押し直せば外す。
    fileprivate var releasedOnLeave: Set<MouseButton> = []

    /// ⌘ を押している間の keyUp を拾う監視 (``commandKeyUpMonitor(for:)``)。窓に載っている間だけ持つ。
    fileprivate var keyUpMonitor: Any?

    init(frame: NSRect, device: any MTLDevice, input: InputState, canvasSize: (Int, Int)) {
        self.device = device
        self.input = input
        self.canvasWidth = Double(canvasSize.0)
        self.canvasHeight = Double(canvasSize.1)
        super.init(frame: frame)
        // **ファイルの URL だけを受ける** — ブラウザから落とした文字列や URL では、ドラッグを断る (``droppedPaths(from:)``)
        registerForDraggedTypes([.fileURL])
        // **終わるときに放す** — 終わりの経路 (× の確定・Ctrl-C・`terminate(_:)`) は窓を閉じずに
        // プロセスを畳むことがあり、窓が閉じる知らせだけでは取りこぼす
        NotificationCenter.default.addObserver(
            self, selector: #selector(applicationWillTerminate(_:)),
            name: NSApplication.willTerminateNotification, object: nil)
        // **アプリが退いたときも離す。** 窓が key のまま他のアプリへ移ることがある (窓の
        // 知らせだけでは取りこぼす)
        NotificationCenter.default.addObserver(
            self, selector: #selector(applicationDidResignActive(_:)),
            name: NSApplication.didResignActiveNotification, object: nil)
        // **メニューを開いている間も離す。** AppKit は自前の追跡ループへ入り、その間に離した
        // キーはメニューが取る。窓は key のままでフレームは回り続けるので、押されたまま走る
        NotificationCenter.default.addObserver(
            self, selector: #selector(menuDidBeginTracking(_:)),
            name: NSMenu.didBeginTrackingNotification, object: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// 描く解像度を差し替える。**触った操作を写す規則がこれに依る**ので、絵の出どころが
    /// 入れ替わったら一緒に更新する。
    func setCanvasSize(_ size: (width: Int, height: Int)) {
        canvasWidth = Double(size.width)
        canvasHeight = Double(size.height)
    }

    override func makeBackingLayer() -> CALayer {
        let layer = CAMetalLayer()
        layer.device = device
        layer.pixelFormat = RenderTarget.pixelFormat
        // 作業空間と同じ色空間を面に持たせ、表示のための変換は表示の側に 1 度だけ
        // 行わせる (ADR-0011 決定 3)。ここを既定のままにすると、線形の値が
        // エンコード済みとして解釈されて全体が明るく出る
        layer.colorspace = CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3)
        // 既定は標準レンジ (ADR-0011 決定 5)。表示能力に応じて範囲の外側まで出すのは
        // スケッチが明示的に選んだときだけ
        layer.wantsExtendedDynamicRangeContent = false
        layer.framebufferOnly = true
        return layer
    }

    var metalLayer: CAMetalLayer? { layer as? CAMetalLayer }

    override var wantsUpdateLayer: Bool { true }

    /// 面の実際の画素数へレイヤを合わせる。
    ///
    /// 画面の倍率が変わったとき (別の画面へ移した・拡大率を変えた) にも呼ばれる。
    func synchronizeDrawableSize() {
        guard let metalLayer, let scale = window?.backingScaleFactor else { return }
        metalLayer.contentsScale = scale
        let size = bounds.size
        metalLayer.drawableSize = CGSize(
            width: max(1, size.width * scale), height: max(1, size.height * scale))
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        synchronizeDrawableSize()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        synchronizeDrawableSize()
    }
}

// MARK: - 触った操作を合流点へ流す

extension SketchSurface {
    /// **キーを受け取るために要る。** `false` のままだと `keyDown` は 1 度も呼ばれず、
    /// 警告も出ない — 「マウスは効くのにキーだけ効かない」という形でしか気付けない。
    ///
    /// ## 窓を出す側は、面を第一応答者に据える
    ///
    /// これを返すだけでは足りない。キーは第一応答者へ配られるので、面がそこに居ない窓では
    /// 1 件も来ない。**据える責任は窓を出す側にある** —
    /// `SharedFrameStage.open(overlay:)` と `SketchApplication.didFinishLaunching()` が
    /// どちらも窓を前へ出した後に `makeFirstResponder(_:)` を呼ぶ。
    ///
    /// **AppKit の自動選択には頼らない。** 窓を最初に前へ出すとき、AppKit はキービューの
    /// 環の先頭 — これを返す contentView — を `initialFirstResponder` に自分で選ぶので、
    /// 呼ばなくてもキーは届く (`orderFrontRegardless` でも、応答者になりうる部品を重ねた
    /// 窓でも届く。実測)。**それは文書化されていない挙動である**うえ、窓を出した**後**に
    /// contentView を差し替えると応答者は窓へ戻る (実測) ので、頼ると破れ方が上の
    /// 「キーだけ効かない」になる — 1 行で名乗るほうが安い ([#963])。
    ///
    /// **`makeFirstResponder(_:)` はこの値を見ない。** 拒む面でも据わり、キーはそこへ配られる
    /// (実測)。この値が効くのは AppKit が応答者を**自分で選ぶ**ところ — 環の先頭の選定・
    /// 押して焦点を移す・Tab で辿る — なので、両方が要る。
    ///
    /// 届くこと自体は、窓を出して本物の `NSEvent` を通す検査が覆っている
    /// (`SharedFrameStageTests` / `SketchApplicationTests`)。面の `keyDown` を直に呼ぶ形では、
    /// 窓 → 第一応答者 → 面という覆いたい区間を飛ばすことになる。
    ///
    /// [#963]: https://github.com/mokume-metal/mokume/issues/963
    override var acceptsFirstResponder: Bool { true }

    /// 窓が前に出ていなくても、最初の一撃をその場で拾う。
    ///
    /// 無いと 1 回目のクリックが「窓を前に出す」ことにだけ使われて捨てられる。触って
    /// 動かすものなので、押した回数と効いた回数が食い違わないほうがよい。
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// 押していない間の移動を配信させるための領域。
    ///
    /// **無いと `mouseMoved` が来ない。** 押している間の `mouseDragged` は領域が無くても
    /// 来るので、「引きずるのは効くのに、ただ動かすのは効かない」という形で出る。
    private static let trackingOptions: NSTrackingArea.Options = [
        .mouseMoved, .activeInKeyWindow, .inVisibleRect,
    ]

    override func updateTrackingAreas() {
        // **自分が足した領域だけを外す。** `trackingAreas` を丸ごと消すと、AppKit や
        // 他の層が足したものまで壊す
        if let pointerTracking {
            removeTrackingArea(pointerTracking)
            self.pointerTracking = nil
        }
        // `.inVisibleRect` を付けているので矩形は AppKit が追随させる (渡す値は使われない)
        let area = NSTrackingArea(
            rect: .zero, options: Self.trackingOptions, owner: self, userInfo: nil)
        addTrackingArea(area)
        pointerTracking = area
        super.updateTrackingAreas()
    }

    /// いま面の座標をキャンバスの座標へ写す規則。窓の大きさが変わるたびに変わる。
    private var mapping: SurfaceMapping {
        let size = bounds.size
        let drawable = metalLayer?.drawableSize ?? .zero
        return SurfaceMapping(
            viewWidth: Double(size.width), viewHeight: Double(size.height),
            drawableWidth: Double(drawable.width), drawableHeight: Double(drawable.height),
            canvasWidth: canvasWidth, canvasHeight: canvasHeight)
    }

    /// 出来事の起きた場所を、キャンバスの座標で返す。写せなければ `nil`。
    private func canvasLocation(of event: NSEvent) -> (x: Float, y: Float)? {
        canvasLocation(atWindowPoint: event.locationInWindow)
    }

    /// 窓の座標 (左下原点) の 1 点を、キャンバスの座標で返す。写せなければ `nil`。
    private func canvasLocation(atWindowPoint windowPoint: NSPoint) -> (x: Float, y: Float)? {
        let point = convert(windowPoint, from: nil)
        return mapping.canvasPoint(x: Double(point.x), y: Double(point.y))
    }

    // MARK: マウス

    override func mouseDown(with event: NSEvent) { notePress(event) }
    override func rightMouseDown(with event: NSEvent) { notePress(event) }
    override func otherMouseDown(with event: NSEvent) { notePress(event) }

    override func mouseUp(with event: NSEvent) { noteRelease(event) }
    override func rightMouseUp(with event: NSEvent) { noteRelease(event) }
    override func otherMouseUp(with event: NSEvent) { noteRelease(event) }

    /// 押していない間の移動。トラッキング領域があるときだけ来る。
    override func mouseMoved(with event: NSEvent) { noteMove(event) }

    /// 押している間の移動。**押している間は `mouseMoved` ではなくこちらが来る**ので、
    /// 釦ごとに 3 つとも受ける必要がある。
    override func mouseDragged(with event: NSEvent) { noteMove(event) }
    override func rightMouseDragged(with event: NSEvent) { noteMove(event) }
    override func otherMouseDragged(with event: NSEvent) { noteMove(event) }

    private func notePress(_ event: NSEvent) {
        if let point = pressPoint(of: event) {
            deliver(
                .mouseDown(
                    x: point.x, y: point.y, button: Self.button(of: event),
                    clickCount: event.clickCount))
        }
        // **面そのものへの押しだけを数える** — 重ねたつまみ (`KnobOverlay`) への押しは、応答者の
        // 連なりでここへ上がってきても捕まえの合図にしない (#1144)
        if landsOnSurface(event) { pointerLock.notePress(in: pointerSituation) }
    }

    private func noteRelease(_ event: NSEvent) {
        // 退いたときに離した扱いにした釦の、本物の解放は流さない (``releasedOnLeave``)
        if releasedOnLeave.remove(Self.button(of: event)) != nil { return }
        guard let point = pressPoint(of: event) else { return }
        deliver(.mouseUp(x: point.x, y: point.y, button: Self.button(of: event)))
    }

    /// 押下・解放が名乗る位置。**捕まえている間は、捕まえた時点の位置** (#1144) — 位置を写し
    /// 直さず、最後に名乗った位置をそのまま使う。`mouseX` は捕まえている間動かない約束である。
    private func pressPoint(of event: NSEvent) -> (x: Float, y: Float)? {
        if pointerLock.isLocked { return lastPoint }
        return canvasLocation(of: event)
    }

    /// 押しが面そのものに当たったか (重ねた面の上ではないか)。
    private func landsOnSurface(_ event: NSEvent) -> Bool {
        isOverSurface(atWindowPoint: event.locationInWindow)
    }

    /// 窓の座標の 1 点が、面そのものの上か (重ねた面の上ではないか)。
    private func isOverSurface(atWindowPoint point: NSPoint) -> Bool {
        guard let superview else { return true }
        return hitTest(superview.convert(point, from: nil)) === self
    }

    /// 出来事の釦。**番号を型へ絞る関所は、ここと外から送る経路 (`RawInputEvent`) の
    /// 2 つだけ。** `buttonNumber` は ``MouseButton`` の番号と同じ体系なので、変換はせず
    /// 包むだけにする ([ADR-0034] 決定 1)。
    ///
    /// [ADR-0034]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0034-input-surface-units.md
    private static func button(of event: NSEvent) -> MouseButton {
        MouseButton(rawValue: event.buttonNumber)
    }

    private func noteMove(_ event: NSEvent) {
        let delta = mapping.canvasDelta(dx: Double(event.deltaX), dy: Double(event.deltaY))
        guard
            let motion = Self.motion(
                isLocked: pointerLock.isLocked, location: canvasLocation(of: event), delta: delta)
        else { return }
        deliver(motion)
    }

    /// 移動 1 件を、合流点へ流す出来事にする。**捕まえている間は、位置ではなく量を送る**
    /// ([#1144](https://github.com/mokume-metal/mokume/issues/1144))。
    ///
    /// 捕まえている間はカーソルが動かないので、位置を送っても差は 0 になる。量は出来事の
    /// `deltaX` / `deltaY` を ``SurfaceMapping/canvasDelta(dx:dy:)`` で位置と同じ比に写したもの
    /// である。**`deltaY` は下向きを正、単位は点として読む** — 位置の `locationInWindow` (上向きが
    /// 正) と違い、移動の出来事の量は画面の座標 (左上が原点) で数えられる。この読み方は、手元の
    /// macOS で窓を触って確かめた (#1144 — 手前へ引くと下向きの量になり、捕まえる前と後で同じ
    /// 手つきが同じくらいの量になった)。食い違う環境が見つかれば、直すのはここ 1 か所である。
    ///
    /// 量が 0 の 1 件は送らない — 動いていないのに `mouseMoved()` を呼ぶことになる。
    ///
    /// - Parameters:
    ///   - isLocked: 捕まえているか。
    ///   - location: 出来事の位置 (キャンバスの座標)。写せなければ `nil`。
    ///   - delta: 出来事の量 (描く解像度の画素・縦軸は下向き)。写せなければ `nil`。
    static func motion(
        isLocked: Bool, location: (x: Float, y: Float)?, delta: (dx: Float, dy: Float)?
    ) -> InputEvent? {
        guard isLocked else { return location.map { .mouseMoved(x: $0.x, y: $0.y) } }
        guard let delta, delta.dx != 0 || delta.dy != 0 else { return nil }
        return .mouseMovedBy(dx: delta.dx, dy: delta.dy)
    }

    /// 拾った 1 件の行き先。**ここ 1 つを通す** — 種別ごとに書くと、足した種別だけが
    /// 運ばれない形になる。
    func deliver(_ event: InputEvent) {
        note(event)
        input.enqueue(event)
        relay?(event.wireLine)
    }

    /// 流した出来事から、面が覚えておくものを控える — 名乗った位置 (``lastPoint``) と、
    /// 押したまま残っているキーと釦 (``heldKeys``)。**流す口 1 つで控える**ので、拾い方の違う
    /// 経路 (押下・移動・退いたときの解放) で控え忘れない。
    private func note(_ event: InputEvent) {
        switch event {
        case .keyDown(let code, _, _): heldKeys.insert(code)
        case .keyUp(let code): heldKeys.remove(code)
        case .mouseDown(let x, let y, let button, _):
            lastPoint = (x, y)
            heldButtons.insert(button)
            releasedOnLeave.remove(button)
        case .mouseUp(let x, let y, let button):
            lastPoint = (x, y)
            heldButtons.remove(button)
        case .mouseMoved(let x, let y): lastPoint = (x, y)
        case .fileDropped(_, let x, let y): lastPoint = (x, y)
        case .mouseMovedBy, .scrolled, .pinched, .fileSelected: break
        }
    }

    /// 押したまま残っているキーと釦に、解放を流す。**キーと釦がこの面へ届かなくなるときに呼ぶ** —
    /// 窓が退く・アプリが退く・同じ窓の中で第一応答者が移る・メニューを開く。
    ///
    /// 解放は普通の出来事として合流点へ入るので、`keyReleased()` / `mouseReleased()` も呼ばれ、
    /// 次のフレームで `keyboard.justReleased` が立つ (ADR-0034 決定 7 の挙動 3)。並びは番号順に
    /// 揃え、同じ押し方からは同じ並びが出るようにする。
    func releaseHeld() {
        for code in heldKeys.sorted(by: { $0.rawValue < $1.rawValue }) {
            deliver(.keyUp(code: code))
        }
        // 釦が残っているなら、押下を流したときに位置を控えてある (``note(_:)``)
        guard let point = lastPoint else { return }
        for button in heldButtons.sorted(by: { $0.rawValue < $1.rawValue }) {
            deliver(.mouseUp(x: point.x, y: point.y, button: button))
            releasedOnLeave.insert(button)
        }
    }

    // MARK: スクロール

    /// スクロール量。
    ///
    /// **位置と違って尺度を変えない。** これは面の上の場所ではなく身振りの量なので、
    /// 窓の大きさで割り増すと同じ手つきが窓の大きさによって違う意味になる
    /// (``Orbit/radiansPerPixel`` が面の大きさに依らない割合を選んでいるのと同じ理由)。
    override func scrollWheel(with event: NSEvent) {
        deliver(.scrolled(dx: Float(event.scrollingDeltaX), dy: Float(event.scrollingDeltaY)))
    }

    // MARK: ピンチ

    /// トラックパッドのピンチ。**倍率の差分をそのまま運ぶ** (0.1 で 1.1 倍に開いた・
    /// [#2762](https://github.com/mokume-metal/mokume/issues/2762))。スクロールと同じく身振りの量なので、
    /// 窓の大きさでは変えない。
    override func magnify(with event: NSEvent) {
        deliver(.pinched(amount: Float(event.magnification)))
    }

    // MARK: ファイルのドロップ

    /// ドラッグされている中身から、ファイルの絶対パスを取り出す。**ファイルの URL だけ** — ブラウザから
    /// 落とした文字列や `https://` の URL は含まれず、空になる (``draggingEntered(_:)`` が断る)。
    ///
    /// ファイルの中身は運ばない。パスは `loadImage(_:)` などがそのまま読める形である
    /// ([#3061](https://github.com/mokume-metal/mokume/issues/3061))。
    static func droppedPaths(from pasteboard: NSPasteboard) -> [String] {
        let urls =
            pasteboard.readObjects(
                forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]
        return (urls ?? []).map(\.path)
    }

    /// ファイルを引きずって窓へ入った。**ファイルの URL が 1 本もなければ断る** — 落とす先に見せない。
    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        Self.droppedPaths(from: sender.draggingPasteboard).isEmpty ? [] : .copy
    }

    override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation {
        draggingEntered(sender)
    }

    /// ファイルが落とされた。**1 回の落としを 1 件の出来事にして**、合流点と運び先へ流す。
    ///
    /// 自前の窓も道具の窓も同じ ``SketchSurface`` なので、ここ 1 か所で両方に効く — 道具の窓では
    /// ``relay`` が `wireLine` を子へ渡す ([ADR-0032] 決定 4)。パスが 0 本の落としは送らない。
    /// 落とした所を写せないとき (面の大きさが 0) も送らず、断る。
    ///
    /// [ADR-0032]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0032-window-ownership.md
    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        let paths = Self.droppedPaths(from: sender.draggingPasteboard)
        guard !paths.isEmpty, let point = canvasLocation(atWindowPoint: sender.draggingLocation)
        else { return false }
        deliver(.fileDropped(paths: paths, x: point.x, y: point.y))
        return true
    }

    // MARK: キー

    override func keyDown(with event: NSEvent) {
        let code = Key(rawValue: Int(event.keyCode))
        // **Escape は捕まえを外してから、普通のキーとして配る** (#1144)。外すのは窓の側なので、
        // 子が居なくても・スケッチが止まっていても (`noLoop()`) 効く
        if code == .escape { pointerLock.releaseByUser() }
        deliver(.keyDown(code: code, characters: event.characters ?? "", isRepeat: event.isARepeat))
    }

    override func keyUp(with event: NSEvent) {
        deliver(.keyUp(code: Key(rawValue: Int(event.keyCode))))
    }

    /// 修飾キー (Shift・Control・Option・Command) の押下と解放。**AppKit は `keyDown` ではなく
    /// ここへ配る** — 受けていなかった頃は、窓で Shift を押しても押されていない扱いだった
    /// ([#2435](https://github.com/mokume-metal/mokume/issues/2435))。
    ///
    /// 合流点へは普通の `keyDown` / `keyUp` として流す。外から `code` 56 を送ったものと同じ形
    /// になるので、2 つの経路が同じ答えを返す。修飾キーが呼び出しを生まないのは合流点の
    /// 規則である (`Key.isModifier`)。
    override func flagsChanged(with event: NSEvent) {
        if let modifier = Self.modifierEvent(
            keyCode: Int(event.keyCode), flags: event.modifierFlags.rawValue)
        {
            deliver(modifier)
        }
        super.flagsChanged(with: event)
    }

    /// 修飾キーの番号と、左右を分けた修飾のビット (`NX_DEVICE*KEYMASK`)。
    ///
    /// **左右を分けたビットで決める。** `modifierFlags.shift` は左右をまとめた旗なので、両方の
    /// Shift を押してから片方を離すと、立ったままの旗から「押した」と読み違える。
    private static let modifierMasks: [Int: UInt] = [
        56: 0x02, 60: 0x04,  // Shift (左・右)
        59: 0x01, 62: 0x2000,  // Control
        58: 0x20, 61: 0x40,  // Option
        55: 0x08, 54: 0x10,  // Command
    ]

    /// 修飾キーの変化 1 件を、合流点へ流す出来事にする。修飾キーでなければ `nil` (Caps Lock・fn)。
    ///
    /// - Parameters:
    ///   - keyCode: 変わったキーの番号 (`NSEvent.keyCode`)。
    ///   - flags: 変わった後の修飾の旗 (`NSEvent.modifierFlags.rawValue`)。
    static func modifierEvent(keyCode: Int, flags: UInt) -> InputEvent? {
        guard let mask = modifierMasks[keyCode] else { return nil }
        let code = Key(rawValue: keyCode)
        return flags & mask != 0
            ? .keyDown(code: code, characters: "", isRepeat: false) : .keyUp(code: code)
    }

    /// ⌘ を押している間の keyUp を拾う監視を作る。
    ///
    /// **AppKit は ⌘ を伴う keyUp を窓へ配らない** (`NSApplication.sendEvent(_:)` が落とす)。
    /// 受けないと、⌘S のように組んだ S が押されたまま残る
    /// ([#2435](https://github.com/mokume-metal/mokume/issues/2435))。そこで配られる前に拾って
    /// 面へ流し、出来事は消費する — 配られる版の AppKit でも、2 度は流れない。
    ///
    /// 拾うのは、この面が載る窓宛てで、面が第一応答者のときだけである (キーが本来ここへ
    /// 届く場合に揃える)。
    private func commandKeyUpMonitor(for window: NSWindow) -> Any? {
        NSEvent.addLocalMonitorForEvents(matching: .keyUp) { [weak self, weak window] event in
            guard let self, let window, event.window === window,
                window.firstResponder === self, event.modifierFlags.contains(.command)
            else { return event }
            self.keyUp(with: event)
            return nil
        }
    }
}

// MARK: - カーソルを捕まえる

extension SketchSurface {
    /// スケッチの要求を渡す。**毎リフレッシュ呼ぶ** — 窓を持つ側が、要求の出どころ
    /// (直に走らせた窓は走っている実行、道具の窓は共有面の属性) から読んで渡す
    /// ([#1144](https://github.com/mokume-metal/mokume/issues/1144))。
    func followPointerLock(requested: Bool) {
        pointerLock.update(requested: requested, in: pointerSituation)
    }

    /// 矢印のカーソルを隠すかの要求を渡す。**毎リフレッシュ呼ぶ** — ``followPointerLock(requested:)``
    /// と同じく、窓を持つ側が要求の出どころから読んで渡す
    /// ([#2439](https://github.com/mokume-metal/mokume/issues/2439))。
    func followCursorHiding(requested: Bool) {
        cursorHiding.update(requested: requested, in: cursorSituation)
    }

    /// 窓が前に出ているか・ポインタが**面そのもの**の上にあるか。窓が無ければどちらも偽。
    ///
    /// 面の上とは、(1) その点でいちばん手前の窓がこの窓で (別の窓が重なっていれば、面の座標は
    /// 当たっていても見えているのは別の窓)、(2) 重ねたつまみの上ではない、こと。
    private var cursorSituation: CursorHiding.Situation {
        guard let window else { return .away }
        let onTop =
            NSWindow.windowNumber(at: NSEvent.mouseLocation, belowWindowWithWindowNumber: 0)
            == window.windowNumber
        return CursorHiding.Situation(
            isKeyWindow: window.isKeyWindow,
            pointerIsOverSurface: onTop
                && isOverSurface(atWindowPoint: window.mouseLocationOutsideOfEventStream))
    }

    /// 窓が前に出ているか・ポインタがこの面の上にあるか。窓が無ければどちらも偽。
    private var pointerSituation: PointerLock.Situation {
        guard let window else {
            return PointerLock.Situation(isKeyWindow: false, pointerIsInside: false)
        }
        let point = convert(window.mouseLocationOutsideOfEventStream, from: nil)
        return PointerLock.Situation(
            isKeyWindow: window.isKeyWindow, pointerIsInside: bounds.contains(point))
    }

    /// 窓を移る前に放し、前の窓の知らせを外す。
    override func viewWillMove(toWindow newWindow: NSWindow?) {
        super.viewWillMove(toWindow: newWindow)
        guard newWindow !== window else { return }
        pointerLock.tearDown()
        cursorHiding.stop()
        stopObservingWindow()
    }

    /// 載った窓が退く・閉じる知らせを受ける。**放すのは窓の側の出来事なので、面が自分で聞く。**
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        stopObservingWindow()
        guard let window else { return }
        observedWindow = window
        NotificationCenter.default.addObserver(
            self, selector: #selector(windowDidResignKey(_:)),
            name: NSWindow.didResignKeyNotification, object: window)
        NotificationCenter.default.addObserver(
            self, selector: #selector(windowWillClose(_:)),
            name: NSWindow.willCloseNotification, object: window)
        keyUpMonitor = commandKeyUpMonitor(for: window)
    }

    private func stopObservingWindow() {
        if let monitor = keyUpMonitor {
            NSEvent.removeMonitor(monitor)
            keyUpMonitor = nil
        }
        guard let observed = observedWindow else { return }
        NotificationCenter.default.removeObserver(
            self, name: NSWindow.didResignKeyNotification, object: observed)
        NotificationCenter.default.removeObserver(
            self, name: NSWindow.willCloseNotification, object: observed)
        observedWindow = nil
    }

    /// 窓が退いた (⌘Tab・他の窓)。**利用者が外したものとして放す** — 押すまで掛け直さない。
    ///
    /// **押しているキーと釦も離す** (``releaseHeld()``)。
    @objc private func windowDidResignKey(_ notification: Notification) {
        pointerLock.releaseByUser()
        cursorHiding.stop()
        releaseHeld()
    }

    /// アプリが退いた。窓が key のまま他のアプリへ移る経路でも、押しているものを離す。
    @objc fileprivate func applicationDidResignActive(_ notification: Notification) {
        releaseHeld()
    }

    /// メニューを開いた。追跡の間に離したキーは、面へ届かない。
    @objc fileprivate func menuDidBeginTracking(_ notification: Notification) {
        releaseHeld()
    }

    /// 同じ窓の中で、キーの行き先がこの面から移る (重ねたつまみが応答者を取る、など)。窓は
    /// key のままなので、退く知らせは来ない。
    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        if resigned { releaseHeld() }
        return resigned
    }

    /// 窓が閉じる。
    @objc private func windowWillClose(_ notification: Notification) {
        pointerLock.tearDown()
        cursorHiding.stop()
    }

    /// プロセスが終わる。
    @objc fileprivate func applicationWillTerminate(_ notification: Notification) {
        pointerLock.tearDown()
        cursorHiding.stop()
    }
}
