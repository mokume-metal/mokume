// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import MokumeDiagnostics

extension Canvas {
    // MARK: - 書体

    /// これから描く文字の書体。
    ///
    /// **この環境に無い名前は効かない。** 名前を取り違えても別の書体が返るだけで
    /// 気付けないので、無い名前は警告して指定を変えない。
    public func textFont(_ name: String) {
        guard Typeface.exists(name: name) else {
            warnMissingFontOnce(name)
            return
        }
        currentFontName = name
    }

    /// 既定の書体へ戻す。
    public func noTextFont() { currentFontName = nil }

    /// これから描く文字の大きさ (画素)。
    public func textSize(_ size: Float) { currentTextSize = max(0, size) }

    /// これから描く文字の太さと傾き。
    public func textStyle(_ style: TextStyle) { currentTextStyle = style }

    /// 文字列を、指定した位置のどちら側へ置くか。
    public func textAlign(
        _ horizontal: HorizontalTextAlign, _ vertical: VerticalTextAlign = .baseline
    ) {
        currentHorizontalTextAlign = horizontal
        currentVerticalTextAlign = vertical
    }

    /// 行と行の間隔 (画素)。
    public func textLeading(_ leading: Float) { currentTextLeading = max(0, leading) }

    // MARK: - 寸法

    /// 実際に使う行送り。指定が無ければ大きさから決める。
    var resolvedTextLeading: Float { currentTextLeading ?? currentTextSize * Self.leadingRatio }

    /// 指定が無いときの行送りを、大きさの何倍にするか。
    static let leadingRatio: Float = 1.25

    /// 文字列の送り幅 (画素)。
    ///
    /// **1 文字ずつの送り幅の合計**なので、部分に切って足しても全体と一致する。
    /// 末尾の空白も幅に数える。改行を含む文字列では、いちばん長い行の幅を返す。
    public func textWidth(_ string: String) -> Float {
        let face = typeface
        var widest: Float = 0
        for line in string.split(separator: "\n", omittingEmptySubsequences: false) {
            widest = max(widest, face.advance(of: line))
        }
        return widest
    }

    /// 基準線から上へ伸びる高さ (画素)。
    public func textAscent() -> Float { typeface.ascent }

    /// 基準線から下へ伸びる深さ (画素)。
    public func textDescent() -> Float { typeface.descent }

    // MARK: - 描く

    /// 文字列を描く。
    ///
    /// 縦の基準は ``textAlign(_:_:)`` が決める。既定は**基準線** — `y` が字の乗る線になる。
    /// 改行で行が分かれ、行の間隔は ``textLeading(_:)`` が決める。
    public func text(_ string: String, _ x: Float, _ y: Float) {
        guard let color = textFillColor, !string.isEmpty, currentTextSize > 0 else { return }
        let face = typeface
        let lines = string.split(separator: "\n", omittingEmptySubsequences: false)
        let leading = resolvedTextLeading
        // 最初の行の基準線から、最後の行の基準線までの距離
        let span = Float(lines.count - 1) * leading

        var baseline = y
        switch currentVerticalTextAlign {
        case .baseline: break
        case .top: baseline = y + face.ascent
        case .bottom: baseline = y - face.descent - span
        case .center: baseline = y + (face.ascent - face.descent - span) / 2
        }

        for line in lines {
            drawLine(line, face: face, x: x, baseline: baseline, color: color)
            baseline += leading
        }
    }

    /// 1 行ぶんを、1 文字ずつ送りながら置く。
    ///
    /// **前に進む量は ``Typeface/advance(of:)`` と同じ値**である。描画と計測が別々に
    /// 幅を数えると、整列が数画素ずれる形で食い違う。
    private func drawLine(
        _ line: some StringProtocol, face: Typeface, x: Float, baseline: Float,
        color: LinearRGBA
    ) {
        guard !line.isEmpty else { return }

        var pen = x
        switch currentHorizontalTextAlign {
        case .left: break
        case .center: pen -= face.advance(of: line) / 2
        case .right: pen -= face.advance(of: line)
        }

        for scalar in line.unicodeScalars {
            guard let resolved = face.glyph(for: scalar) else { continue }
            if let entry = glyphEntry(for: resolved), !entry.isBlank {
                appendGlyphQuad(entry, penX: pen, baseline: baseline, color: color)
            }
            pen += resolved.advance
        }
    }

    /// 無い書体を指定されたことを、初回だけ知らせる。
    private func warnMissingFontOnce(_ name: String) {
        guard !warnedMissingFont else { return }
        warnedMissingFont = true
        Diagnostics.warn("textFont(): 「\(name)」という書体はこの環境にありません。書体は変えません")
    }
}
