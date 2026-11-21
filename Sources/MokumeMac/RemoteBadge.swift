// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import AppKit

/// `watch --remote` の窓の右下に重ねる、スマホに読ませる QR コードと 1 行 (#4126)。
///
/// つまみの面 (`KnobOverlay`) と同じく AppKit の層に重ねるだけで、**絵のテクスチャには描かない**
/// (ADR-0030 決定 1)。絵を覆い続けないよう、最初のスマホがつながったら道具が下げる。
@MainActor
final class RemoteBadge: NSView {
    static let inset: CGFloat = 12
    static let padding: CGFloat = 10
    static let gap: CGFloat = 6

    private let backdrop = NSVisualEffectView()
    private let code = NSImageView()
    private let label = NSTextField(labelWithString: "")
    private let side: CGFloat

    /// - Parameters:
    ///   - image: QR コードの絵 (静寂域込み・1 モジュールが整数の画素)。
    ///   - line: 絵の下に添える 1 行。
    init(image: CGImage, line: String) {
        // **画素の倍数で描く。** 半端な倍率で縮めるとモジュールの境がにじみ、カメラが読みにくい
        let modules = CGFloat(image.width)
        side = modules * max(1, (160 / modules).rounded(.down))
        super.init(frame: .zero)
        autoresizingMask = [.minXMargin, .maxYMargin]

        backdrop.material = .hudWindow
        backdrop.blendingMode = .withinWindow
        backdrop.state = .active
        backdrop.wantsLayer = true
        backdrop.layer?.cornerRadius = 8
        backdrop.layer?.masksToBounds = true
        addSubview(backdrop)

        code.image = NSImage(cgImage: image, size: NSSize(width: side, height: side))
        code.imageScaling = .scaleAxesIndependently
        code.wantsLayer = true
        code.layer?.magnificationFilter = .nearest
        addSubview(code)

        label.stringValue = line
        label.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        label.textColor = .labelColor
        label.alignment = .center
        addSubview(label)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// 下の右に置き直す。
    func reposition() {
        let text = label.intrinsicContentSize
        let width = max(side, text.width.rounded(.up) + 1) + 2 * Self.padding
        let height = side + Self.gap + text.height + 2 * Self.padding
        let host = superview?.bounds ?? NSRect(x: 0, y: 0, width: width, height: height)
        frame = NSRect(x: host.width - width - Self.inset, y: Self.inset, width: width, height: height)
        backdrop.frame = bounds
        code.frame = NSRect(x: (width - side) / 2, y: Self.padding + text.height + Self.gap, width: side, height: side)
        label.frame = NSRect(x: Self.padding, y: Self.padding, width: width - 2 * Self.padding, height: text.height)
    }

    override func viewDidMoveToSuperview() { reposition() }
    override func resize(withOldSuperviewSize oldSize: NSSize) { reposition() }
}
