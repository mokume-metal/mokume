// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import AppKit
import SwiftUI

/// つまみの面を、絵と同じ窓に重ねる。
///
/// **絵の外に立つ** ([ADR-0030] 決定 1)。描画の成果物のテクスチャには一切描かず、
/// 出口を通った後の提示に重なるだけである — [ADR-0023] 決定 1 でいう段では**ない**し、
/// 出口の 1 枚を変えない。
///
/// この性質は仕掛けで守るものではなく、**経路が別であることそのもの**である。絵は
/// `Canvas` から `RenderTarget` へ、つまみは AppKit の層へ描かれる。だから作者が
/// 「作品に写さない」ための表示スイッチを書く必要が無い。
///
/// ## 別の窓にしない
///
/// 上映やライブでは窓を出したまま触るので、同じ窓に重ねる ([ADR-0030] 決定 1)。
/// 全画面でも同じである。
///
/// [ADR-0023]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0023-frame-stages-and-outputs.md
/// [ADR-0030]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0030-parameter-surfaces.md
@MainActor
final class KnobOverlay: NSView {
    /// 窓の縁からの隔たり。
    static let inset: CGFloat = 12

    private let hosting: NSHostingView<KnobPanel>

    /// 並んでいるつまみの数。**検査から見る** — 面が出ていることと、つまみが並んでいることは
    /// 別の問いである (数字だけの面が出る場合がある)。
    let knobCount: Int

    init(boxes: [any DeclaredParam], numbers: (() -> FrameNumbers?)? = nil) {
        knobCount = boxes.count
        hosting = NSHostingView(rootView: KnobPanel(boxes: boxes, numbers: numbers))
        super.init(frame: NSRect(origin: .zero, size: hosting.fittingSize))
        hosting.frame = bounds
        hosting.autoresizingMask = [.width, .height]
        // **印を空にしない。** 空のままだと AppKit は窓の大きさが変わったことを
        // 部分ビューへ伝えず、置き直しの入口 (`resize(withOldSuperviewSize:)`) が
        // 一度も呼ばれない。値そのものは使わない — 置き方は下で丸ごと決める
        autoresizingMask = [.minYMargin, .maxXMargin]
        addSubview(hosting)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("使わない") }

    /// 宣言があればつまみの面を作る。1 つも無ければ `nil`。
    ///
    /// **宣言だけでつまみが出る** ([ADR-0030] 決定 8) — 並べ方を書かせない。
    static func makeIfNeeded(for sketch: any Sketch, numbers: (() -> FrameNumbers?)? = nil)
        -> KnobOverlay?
    {
        let boxes = ParamCatalog.indexed(from: sketch).map(\.box)
        guard !boxes.isEmpty else { return nil }
        return KnobOverlay(boxes: boxes, numbers: numbers)
    }

    /// 面へ重ねる。
    ///
    /// 絵の面の**部分ビューとして**足す。窓を分けないので、上映中に窓を並べ替える
    /// 必要が無い。
    func attach(to host: NSView) {
        host.addSubview(self)
        reposition()
    }

    /// 窓の左上へ留め、収まらない丈は詰める。
    ///
    /// 留め方が左上なのは、下や右に留めると窓を縮めたときにつまみが窓の外へ出るためで
    /// ある。**丈は窓に収まるところまでに詰める** — 宣言の数は作品が決めるので、
    /// そのまま伸ばすと下のつまみへ手が届かなくなる (詰めたぶんは面の中で巻き取る)。
    func reposition() {
        guard let host = superview else { return }
        let available = max(Self.minimumHeight, host.bounds.height - 2 * Self.inset)
        let height = min(hosting.fittingSize.height, available)
        frame = NSRect(
            x: Self.inset, y: host.bounds.height - height - Self.inset,
            width: KnobPanel.width, height: height)
    }

    /// これより低くは詰めない。窓が極端に小さいときに面が消えるより、はみ出すほうがよい。
    private static let minimumHeight: CGFloat = 80

    /// 窓の大きさが変わったら置き直す。
    ///
    /// **自動整列 (`autoresizingMask`) では足りない。** 上端と左端を固定したまま丈だけを
    /// 窓に合わせて詰める必要があり、余白の伸び縮みの組み合わせでは表せない。
    override func resize(withOldSuperviewSize oldSize: NSSize) { reposition() }

    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        reposition()
    }
}
