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
/// [ADR-0011]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0011-color-model.md
/// [ADR-0012]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0012-view-layer.md
final class SketchSurface: NSView {
    /// 面を作る GPU。**渡さないと面が作れない** — 描く先を用意できないレイヤは
    /// 差し出す面を返さず、絵は 1 枚も出ないまま静かに終わる。
    private let device: any MTLDevice

    init(frame: NSRect, device: any MTLDevice) {
        self.device = device
        super.init(frame: frame)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("使わない") }

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
