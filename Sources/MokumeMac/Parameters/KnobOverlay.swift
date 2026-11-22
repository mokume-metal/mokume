// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import AppKit
import MokumeCore
import SwiftUI

/// つまみの面を、絵と同じウィンドウに重ねる。
///
/// **絵の外に立つ** ([ADR-0030] 決定 1)。描画の成果物のテクスチャには一切描かず、
/// 出口を通った後の提示に重なるだけである — [ADR-0023] 決定 1 でいう段では**ない**し、
/// 出口の 1 枚を変えない。
///
/// この性質は仕掛けで守るものではなく、**経路が別であることそのもの**である。絵は
/// `Canvas` から `RenderTarget` へ、つまみは AppKit の層へ描かれる。だから作者が
/// 「作品に写さない」ための表示スイッチを書く必要が無い。
///
/// ## 別のウィンドウにしない
///
/// 上映やライブではウィンドウを出したまま触るので、同じウィンドウに重ねる ([ADR-0030] 決定 1)。
/// 全画面でも同じである。
///
/// [ADR-0023]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0023-frame-stages-and-outputs.md
/// [ADR-0030]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0030-parameter-surfaces.md
@MainActor
final class KnobOverlay: NSView {
    /// ウィンドウの縁からの隔たり。
    static let inset: CGFloat = 12

    private let hosting: NSHostingView<KnobPanel>

    /// 並んでいるつまみの数。**検査から見る** — 面が出ていることと、つまみが並んでいることは
    /// 別の問いである (数字だけの面が出る場合がある)。
    let knobCount: Int

    /// 警告の欄に出す値 (#3087)。数字を出す面 (道具のウィンドウ) だけが使う。
    private let warningFeed = WarningFeed()

    /// 畳んでいるか (#4137)。作る側が渡せば、面を作り直しても畳んだままになる。
    let state: KnobPanelState

    /// 枠の大きさが変わったとき (畳む・開く・警告の欄の出入り)。**置き直しのたびには呼ばない** —
    /// 列の容れ物 (``KnobColumnLayout``) は自分の並べ直しの中から ``reposition()`` を呼ぶので、
    /// そこで呼ぶと並べ直しが自分を呼び返す。
    var onResize: (() -> Void)?

    init(
        boxes: [any DeclaredParam], numbers: (() -> FrameNumbers?)? = nil,
        state: KnobPanelState = KnobPanelState()
    ) {
        knobCount = boxes.count
        self.state = state
        // 押されたときの行き先は、自分ができてから据える (`self` を捕まえるため)
        hosting = NSHostingView(
            rootView: KnobPanel(boxes: boxes, numbers: numbers, warnings: warningFeed, state: state))
        super.init(frame: NSRect(origin: .zero, size: hosting.fittingSize))
        hosting.rootView.toggle = { [weak self] in
            guard let self else { return }
            self.setCollapsed(!self.state.isCollapsed)
        }
        hosting.frame = bounds
        hosting.autoresizingMask = [.width, .height]
        // **印を空にしない。** 空のままだと AppKit はウィンドウの大きさが変わったことを
        // 部分ビューへ伝えず、置き直しの入口 (`resize(withOldSuperviewSize:)`) が
        // 一度も呼ばれない。値そのものは使わない — 置き方は下で丸ごと決める
        autoresizingMask = [.minYMargin, .maxXMargin]
        addSubview(hosting)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// 宣言があればつまみの面を作る。1 つも無ければ `nil`。
    ///
    /// **宣言だけでつまみが出る** ([ADR-0030] 決定 8) — 並べ方を書かせない。
    ///
    /// **索引は受け取る。** ここが自分で引くと起動のたびに 2 度数えることになり、
    /// 重複した宣言の警告まで 2 度出る (#994 の 13)。持ち回る形は
    /// ``SketchRuntime`` が既に採っている。
    static func makeIfNeeded(
        for registry: ParamRegistry, numbers: (() -> FrameNumbers?)? = nil
    ) -> KnobOverlay? {
        let boxes = registry.knobs
        guard !boxes.isEmpty else { return nil }
        return KnobOverlay(boxes: boxes, numbers: numbers)
    }

    /// 面へ重ねる。
    ///
    /// 絵の面の**部分ビューとして**足す。ウィンドウを分けないので、上映中にウィンドウを並べ替える
    /// 必要が無い。
    func attach(to host: NSView) {
        host.addSubview(self)
        reposition()
    }

    /// 警告の欄に出すものを差し替える ([#3087](https://github.com/mokume-metal/mokume/issues/3087))。
    ///
    /// **欄が出入りしたり行が増えたりすると面の丈が変わる。** 枠の丈は置いたときに 1 度測って決めるので、
    /// 値を替えただけでは枠が追い付かず、後から来た警告はウィンドウの下に切れて見えない。**変わったら丈を測り直して
    /// 置き直す。** 同じ値なら何もしない (呼ぶ側は拍ごとに押し込んでよい)。
    func show(warnings: WarningSummary?) {
        guard warningFeed.summary != warnings else { return }
        warningFeed.summary = warnings
        remeasure()
    }

    /// 面を畳む・開く (#4137)。畳むと開くボタンだけの小さな面になり、左上の留め方は変わらない。
    func setCollapsed(_ collapsed: Bool) {
        guard state.isCollapsed != collapsed else { return }
        state.isCollapsed = collapsed
        remeasure()
    }

    /// 中身が変わった直後に大きさを測り直して置き直し、変わったことを知らせる。
    private func remeasure() {
        // 値を替えた直後の組み直しを済ませてから測る
        hosting.layoutSubtreeIfNeeded()
        reposition()
        onResize?()
    }

    /// ウィンドウの左上へ留め、収まらない丈は詰める。
    ///
    /// 留め方が左上なのは、下や右に留めるとウィンドウを縮めたときにつまみがウィンドウの外へ出るためで
    /// ある。**丈はウィンドウに収まるところまでに詰める** — 宣言の数は作品が決めるので、
    /// そのまま伸ばすと下のつまみへ手が届かなくなる (詰めたぶんは面の中で巻き取る)。
    func reposition() {
        guard let host = superview else { return }
        let available = max(Self.minimumHeight, host.bounds.height - 2 * Self.inset)
        let fitting = hosting.fittingSize
        let height = min(fitting.height, available)
        // 幅は測った幅 — 畳んだ面は開いた面より狭い
        frame = NSRect(
            x: Self.inset, y: host.bounds.height - height - Self.inset,
            width: fitting.width, height: height)
    }

    /// これより低くは詰めない。ウィンドウが極端に小さいときに面が消えるより、はみ出すほうがよい。
    private static let minimumHeight: CGFloat = 80

    /// ウィンドウの大きさが変わったら置き直す。
    ///
    /// **自動整列 (`autoresizingMask`) では足りない。** 上端と左端を固定したまま丈だけを
    /// ウィンドウに合わせて詰める必要があり、余白の伸び縮みの組み合わせでは表せない。
    override func resize(withOldSuperviewSize oldSize: NSSize) { reposition() }

    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        reposition()
    }
}
