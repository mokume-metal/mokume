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
    private var canvasWidth: Double
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

    init(frame: NSRect, device: any MTLDevice, input: InputState, canvasSize: (Int, Int)) {
        self.device = device
        self.input = input
        self.canvasWidth = Double(canvasSize.0)
        self.canvasHeight = Double(canvasSize.1)
        super.init(frame: frame)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("使わない") }

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
        let point = convert(event.locationInWindow, from: nil)
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
        guard let point = canvasLocation(of: event) else { return }
        deliver(.mouseDown(x: point.x, y: point.y, button: event.buttonNumber))
    }

    private func noteRelease(_ event: NSEvent) {
        guard let point = canvasLocation(of: event) else { return }
        deliver(.mouseUp(x: point.x, y: point.y, button: event.buttonNumber))
    }

    private func noteMove(_ event: NSEvent) {
        guard let point = canvasLocation(of: event) else { return }
        deliver(.mouseMoved(x: point.x, y: point.y))
    }

    /// 拾った 1 件の行き先。**ここ 1 つを通す** — 種別ごとに書くと、足した種別だけが
    /// 運ばれない形になる。
    func deliver(_ event: InputEvent) {
        input.enqueue(event)
        relay?(event.wireLine)
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

    // MARK: キー

    override func keyDown(with event: NSEvent) {
        deliver(
            .keyDown(
                code: Key(rawValue: Int(event.keyCode)), characters: event.characters ?? "",
                isRepeat: event.isARepeat))
    }

    override func keyUp(with event: NSEvent) {
        deliver(.keyUp(code: Key(rawValue: Int(event.keyCode))))
    }
}
