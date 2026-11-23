// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import AppKit

/// 道具のウィンドウ (`watch` のプレビュー) で、つまみの面を**絵の横の列**に置く容れ物 (#4137)。
///
/// 左につまみの列、残りに絵の面 (``SketchSurface``) を並べ、**2 つを重ねない**。絵の面は残りの矩形に
/// 縦横比を保って絵を収めるので、列を出しても絵は隠れず、小さくなるだけである。
///
/// 絵の面の大きさが変われば、描く大きさと触った座標の写し方は絵の面が自分で追随する
/// (``SketchSurface/synchronizeDrawableSize()``)。だからマウスの座標は列の幅だけずれない。
///
/// 作品のウィンドウ (`run`) には使わない — 上映でウィンドウ = 作品として使うので、そちらは
/// 面を重ねたまま畳めるようにしてある (``KnobOverlay/setCollapsed(_:)``)。どちらも同じウィンドウの中で、
/// 絵のテクスチャには描かない (ADR-0030 決定 1)。
@MainActor
final class KnobColumnLayout: NSView {
    /// 絵の面。列の右の残りいっぱいに置く。
    let surface: NSView

    /// いま列に置いているつまみの面。無ければ列の幅は 0 で、絵の面がウィンドウいっぱいになる。
    private(set) var knobs: KnobOverlay?

    init(frame: NSRect, surface: NSView) {
        self.surface = surface
        super.init(frame: frame)
        // 並べ方は ``arrange()`` が丸ごと決める。自動整列が残っていると、大きさの変化で先に動かされる
        surface.autoresizingMask = []
        addSubview(surface)
        arrange()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// つまみの面を差し替える。前の面は外す。`nil` なら列を畳んで絵の面だけにする。
    func place(_ overlay: KnobOverlay?) {
        knobs?.onResize = nil
        knobs?.removeFromSuperview()
        knobs = overlay
        if let overlay {
            addSubview(overlay)
            // 畳む・開く・警告の欄の出入りで面の幅や丈が変われば、列の幅も変わる
            overlay.onResize = { [weak self] in self?.arrange() }
        }
        arrange()
    }

    /// 面を開いているときの列の幅 (点)。ウィンドウの既定の大きさに足す量に使う。
    static let expandedWidth = KnobPanel.width + 2 * KnobOverlay.inset

    /// 列の幅 (点)。つまみの面の幅に、左右の隔たりを足したもの。
    var columnWidth: CGFloat {
        guard let knobs else { return 0 }
        return knobs.frame.width + 2 * KnobOverlay.inset
    }

    /// つまみの面を左上に留め、絵の面を残りいっぱいに置く。
    func arrange() {
        // 先につまみの面を置く — 列の幅はその幅から決まる
        knobs?.reposition()
        let left = min(columnWidth, bounds.width)
        surface.frame = NSRect(
            x: left, y: 0, width: bounds.width - left, height: bounds.height)
    }

    override func resizeSubviews(withOldSize oldSize: NSSize) { arrange() }
}
