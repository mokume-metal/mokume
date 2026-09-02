// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import AppKit

/// 短い 1 行を、絵の上に重ねる。
///
/// ## 絵に触らない
///
/// 描くのは AppKit の層で、絵は Metal の層を通る。つまみ (`KnobOverlay`) と同じ形で、
/// **経路が別であることそのもの**が「1 画素も触らない」を守っている
/// ([ADR-0032] 決定 6)。作者が「これは作品に写さない」ためのスイッチを書く必要は無い。
///
/// ## 出す窓を選ばない
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
    /// 窓の縁からの隔たり。つまみと揃える。
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

    private let backdrop = NSVisualEffectView()
    private let spinner = NSProgressIndicator()
    private let label = NSTextField(labelWithString: "")

    init() {
        super.init(frame: .zero)
        // **窓の大きさが変わっても、下の左に留まる。** 置き直しは自分で決めるが、
        // 印を空にすると AppKit が大きさの変化を伝えてこない (`KnobOverlay` と同じ)
        autoresizingMask = [.maxXMargin, .maxYMargin]

        backdrop.material = .hudWindow
        backdrop.blendingMode = .withinWindow
        backdrop.state = .active
        backdrop.wantsLayer = true
        backdrop.layer?.cornerRadius = 8
        backdrop.layer?.masksToBounds = true
        addSubview(backdrop)

        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isIndeterminate = true
        // **止まっている間は消す。** 止まった輪が残っていると、作り直しが続いているのか
        // 終わったのかが見分けられない
        spinner.isDisplayedWhenStopped = false
        addSubview(spinner)

        label.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        label.textColor = .labelColor
        addSubview(label)

        isHidden = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("使わない") }

    /// 出すものを差し替える。
    ///
    /// - Parameters:
    ///   - line: 出す 1 行。`nil` なら畳む。
    ///   - spinning: 回っている印を出すか。
    func show(_ line: String?, spinning: Bool) {
        self.line = line
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
    }

    /// 収める大きさ。**窓を立てずに決められる形にしてある。**
    ///
    /// - Parameters:
    ///   - textWidth: 文字の幅。
    ///   - textHeight: 文字の丈。
    ///   - spinning: 回っている印を出すか。出さないなら、その幅も間も取らない。
    static func size(textWidth: CGFloat, textHeight: CGFloat, spinning: Bool) -> NSSize {
        let mark = spinning ? markSide + gap : 0
        return NSSize(
            width: (textWidth + mark + 2 * padding).rounded(),
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
        let wanted = Self.size(
            textWidth: text.width, textHeight: text.height, spinning: !spinner.isHidden)
        frame = Self.frame(in: superview?.bounds ?? NSRect(origin: .zero, size: wanted), size: wanted)
        backdrop.frame = bounds
        let mark = spinner.isHidden ? 0 : Self.markSide + Self.gap
        spinner.frame = NSRect(
            x: Self.padding, y: (bounds.height - Self.markSide) / 2,
            width: Self.markSide, height: Self.markSide)
        label.frame = NSRect(
            x: Self.padding + mark, y: (bounds.height - text.height) / 2,
            width: max(0, bounds.width - 2 * Self.padding - mark), height: text.height)
    }

    /// 窓の大きさが変わったら置き直す。**自動整列だけでは足りない** — 窓を縮めたときに
    /// 幅を詰める必要がある。
    override func resize(withOldSuperviewSize oldSize: NSSize) { reposition() }

    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        reposition()
    }
}
