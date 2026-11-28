// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import AppKit
import MokumeCore
import QuartzCore

/// 短い 1 行を、絵の上に重ねる。
///
/// ## 絵に触らない
///
/// 描くのは AppKit の層で、絵は Metal の層を通る。つまみ (`KnobOverlay`) と同じ形で、
/// **経路が別であることそのもの**が「1 画素も触らない」を守っている
/// ([ADR-0032] 決定 6)。作者が「これは作品に写さない」ためのスイッチを書く必要は無い。
///
/// ## 出すウィンドウを選ばない
///
/// ここは重ね方だけを持ち、**何を出すかは持ち主が決める** — 文言の正本は端末であり
/// ([#695](https://github.com/mokume-metal/mokume/issues/695))、それを映すのがこの面である。
/// 言葉をここに持つと、端末と 2 か所で名乗ることになる。
///
/// ## 下の左に置く
///
/// つまみは上の左に立つ ([ADR-0030] 決定 1 の面) ので、重ならないところへ置く。
///
/// [ADR-0030]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0030-parameter-surfaces.md
/// [ADR-0032]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0032-window-ownership.md
@MainActor
final class NoticeOverlay: NSView {
    /// ウィンドウの縁からの隔たり。つまみと揃える。
    static let inset: CGFloat = 12
    /// 文字の周りの余白。
    static let padding: CGFloat = 10
    /// 回っている印の一辺。
    static let markSide: CGFloat = 14
    /// 印と文字の間。
    static let gap: CGFloat = 8

    /// 出しているもの。`nil` は何も出していない。
    private(set) var line: String?
    /// 回っている印を出しているか。
    var isSpinning: Bool { spinner.isHidden == false }
    /// 行の横に添えている段数 (`42 / 44`)。`nil` は添えていない。
    var steps: String? { stepsLabel.isHidden ? nil : stepsLabel.stringValue }

    /// 背景のガラス (#4221)。文字と印は ``content`` に置き、ガラスの `contentView` として渡す —
    /// ガラスの効果 (下の絵に応じた文字の見え方) が及ぶのは `contentView` の中だけである。
    private let backdrop = NSGlassEffectView()
    private let content = NSView()
    private let spinner = NSProgressIndicator()
    private let label = NSTextField(labelWithString: "")
    private let stepsLabel = NSTextField(labelWithString: "")

    init() {
        super.init(frame: .zero)
        // **ウィンドウの大きさが変わっても、下の左に留まる。** 置き直しは自分で決めるが、
        // 印を空にすると AppKit が大きさの変化を伝えてこない (`KnobOverlay` と同じ)
        autoresizingMask = [.maxXMargin, .maxYMargin]

        backdrop.cornerRadius = 8
        backdrop.contentView = content
        addSubview(backdrop)

        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isIndeterminate = true
        // **止まっている間は消す。** 止まった輪が残っていると、作り直しが続いているのか
        // 終わったのかが見分けられない
        spinner.isDisplayedWhenStopped = false
        content.addSubview(spinner)

        label.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        label.textColor = .labelColor
        content.addSubview(label)

        // **桁の幅を揃える。** 数字が増えるたびに面の幅が揺れない
        stepsLabel.font = .monospacedDigitSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
        stepsLabel.textColor = .secondaryLabelColor
        stepsLabel.isHidden = true
        content.addSubview(stepsLabel)

        isHidden = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// 出すものを差し替える。
    ///
    /// - Parameters:
    ///   - line: 出す 1 行。`nil` なら畳む。
    ///   - spinning: 回っている印を出すか。
    func show(_ line: String?, spinning: Bool) {
        self.line = line
        // 段数はその行の間だけのもので、次の行へ持ち越さない
        stepsLabel.isHidden = true
        guard let line else {
            isHidden = true
            spinner.stopAnimation(nil)
            return
        }
        label.stringValue = line
        isHidden = false
        // **回すかどうかは呼ぶ側が決める。** 終わったのに回り続ける印は、作り直しが
        // 終わっていないと読める
        if spinning { spinner.startAnimation(nil) } else { spinner.stopAnimation(nil) }
        spinner.isHidden = !spinning
        reposition()
        drawNow()
    }

    /// 行の横に段数を添える。**回っている印を出している間だけ** — 終わった行・失敗の行に
    /// 段数が残ると、まだ組み立てていると読める。
    func showSteps(done: Int, total: Int) {
        guard !isHidden, isSpinning else { return }
        stepsLabel.stringValue = "\(done) / \(total)"
        stepsLabel.isHidden = false
        reposition()
        drawNow()
    }

    /// 添えた段数を消す。
    func clearSteps() {
        guard !stepsLabel.isHidden else { return }
        stepsLabel.isHidden = true
        reposition()
        drawNow()
    }

    /// いますぐ描かせる。
    ///
    /// **立てただけでは 1 度も描かれない。** 呼ぶ側はこの直後に作り直しへ入り、それが
    /// 終わるまで巡回へ戻らない — 描くのは巡回の仕事なので、印は出ないまま作り直しが
    /// 終わり、そこで畳まれる (実測: 1 フレームも出なかった)。
    ///
    /// **描いた結果を送り出すところまでやる。** 描画の束 (`CATransaction`) が閉じるのも
    /// 巡回の中なので、閉じさせないと画面には届かない。ついでに、送り出した後の
    /// 回っている印は**描画サーバ側で回り続ける** — 主たる流れが止まっている間も動く。
    private func drawNow() {
        window?.displayIfNeeded()
        CATransaction.flush()
    }

    /// 収める大きさ。**ウィンドウを立てずに決められる形にしてある。**
    ///
    /// - Parameters:
    ///   - textWidth: 文字の幅。
    ///   - textHeight: 文字の丈。
    ///   - spinning: 回っている印を出すか。出さないなら、その幅も間も取らない。
    ///   - stepsWidth: 添える段数の幅。0 なら段数の幅も間も取らない。
    static func size(
        textWidth: CGFloat, textHeight: CGFloat, spinning: Bool, stepsWidth: CGFloat = 0
    ) -> NSSize {
        let mark = spinning ? markSide + gap : 0
        let steps = stepsWidth > 0 ? gap + stepsWidth : 0
        return NSSize(
            width: (textWidth + mark + steps + 2 * padding).rounded(),
            height: (max(textHeight, markSide) + padding).rounded())
    }

    /// 置き場所。**下の左に留める。**
    static func frame(in host: NSRect, size: NSSize) -> NSRect {
        NSRect(x: inset, y: inset, width: min(size.width, host.width - 2 * inset), height: size.height)
    }

    /// 大きさと置き場所を決め直す。
    func reposition() {
        guard !isHidden else { return }
        let text = label.intrinsicContentSize
        // **幅は切り上げ、1 pt 余らせる。** 求めた幅ちょうどでは、最後の桁の右端が欠けた (実測)
        let stepsSize =
            stepsLabel.isHidden
            ? .zero
            : NSSize(
                width: stepsLabel.intrinsicContentSize.width.rounded(.up) + 1,
                height: stepsLabel.intrinsicContentSize.height)
        let wanted = Self.size(
            textWidth: text.width, textHeight: text.height, spinning: !spinner.isHidden,
            stepsWidth: stepsSize.width)
        frame = Self.frame(in: superview?.bounds ?? NSRect(origin: .zero, size: wanted), size: wanted)
        backdrop.frame = bounds
        content.frame = backdrop.bounds
        let mark = spinner.isHidden ? 0 : Self.markSide + Self.gap
        let steps = stepsLabel.isHidden ? 0 : Self.gap + stepsSize.width
        spinner.frame = NSRect(
            x: Self.padding, y: (bounds.height - Self.markSide) / 2,
            width: Self.markSide, height: Self.markSide)
        // **窓が狭ければ行のほうを詰める。** 段数は短く、切れると読めない
        let labelWidth = max(0, bounds.width - 2 * Self.padding - mark - steps)
        label.frame = NSRect(
            x: Self.padding + mark, y: (bounds.height - text.height) / 2,
            width: labelWidth, height: text.height)
        stepsLabel.frame = NSRect(
            x: Self.padding + mark + labelWidth + Self.gap, y: (bounds.height - stepsSize.height) / 2,
            width: stepsSize.width, height: stepsSize.height)
    }

    /// ウィンドウの大きさが変わったら置き直す。**自動整列だけでは足りない** — ウィンドウを縮めたときに
    /// 幅を詰める必要がある。
    override func resize(withOldSuperviewSize oldSize: NSSize) { reposition() }

    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        reposition()
    }
}
