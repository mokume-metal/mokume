// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import CoreGraphics
import CoreText
import simd

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

    public func textAscent() -> Float { typeface.ascent }

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
        var baseline = firstBaseline(at: y, face: face, lines: lines.count)

        for line in lines {
            drawLine(line, face: face, x: x, baseline: baseline, color: color)
            baseline += leading
        }
    }

    /// 最初の行の基準線。**縦の整列と行数から決まる。**
    ///
    /// 描くとき (``text(_:_:_:)``) と輪郭を返すとき (``textOutline(_:_:_:)``) で
    /// **同じ値でなければならない** — 後者の doc が「描くときと同じ送りで並ぶ」と
    /// 保証しているのに、畳む前はその保証を 2 つの独立した写しが支えていた ([#895])。
    ///
    /// 矩形へ流し込む側 (``textFlow(_:in:)``) は畳んでいない — あちらは塊全体を矩形の
    /// 中へ置く計算で、基準線ではなく上端から決まる。
    ///
    /// [#895]: https://github.com/mokume-metal/mokume/issues/895
    private func firstBaseline(at y: Float, face: Typeface, lines: Int) -> Float {
        // 最初の行の基準線から、最後の行の基準線までの距離
        let span = Float(lines - 1) * resolvedTextLeading
        switch currentVerticalTextAlign {
        case .baseline: return y
        case .top: return y + face.ascent
        case .bottom: return y - face.descent - span
        case .center: return y + (face.ascent - face.descent - span) / 2
        }
    }

    /// 1 行の書き始め。**横の整列と、その行の幅から決まる。**
    ///
    /// 幅は ``Typeface/advance(of:)`` が数える — 描くときと輪郭を返すときで別々に
    /// 数えると、整列が数画素ずれる形で食い違う。
    private func penStart(at x: Float, face: Typeface, line: some StringProtocol) -> Float {
        switch currentHorizontalTextAlign {
        case .left: return x
        case .center: return x - face.advance(of: line) / 2
        case .right: return x - face.advance(of: line)
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

        var pen = penStart(at: x, face: face, line: line)

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
        warnOnce(.missingFont, "textFont(): 「\(name)」という書体はこの環境にありません。書体は変えません")
    }
}

// MARK: - 折り返しと流し込み

extension Canvas {
    /// 幅に収まらなくなったとき、どこで行を折るか。既定は語の切れ目。
    public func textWrap(_ mode: TextWrap) { currentTextWrap = mode }

    /// 矩形の中へ文字列を流し込む。
    ///
    /// 4 つの数の読み方は ``rectMode(_:)`` が決める — ``rect(_:_:_:_:)`` と同じ約束である。
    /// 幅で折り返し、高さに収まる行だけを置く。
    @discardableResult
    public func text(_ string: String, _ a: Float, _ b: Float, _ c: Float, _ d: Float)
        -> TextFlow
    {
        let box = resolveRect(a, b, c, d)
        guard box.width > 0, box.height > 0, currentTextSize > 0, !string.isEmpty else {
            return TextFlow(lineCount: 0, height: 0, remainder: string)
        }

        let face = typeface
        let lines = wrapped(string, face: face, within: box.width)
        let leading = resolvedTextLeading
        let block = face.ascent + face.descent

        // 上から詰めたときに何行入るか。**入る行数を先に決めてから**、その塊を
        // 縦の指定に従って矩形の中へ置く
        var fits = 0
        while fits < lines.count {
            let used = block + Float(fits) * leading
            if used > box.height { break }
            fits += 1
        }
        let height = fits == 0 ? 0 : block + Float(fits - 1) * leading

        let remainder: String
        if fits < lines.count {
            remainder = String(string[lines[fits].startIndex...])
        } else {
            remainder = ""
        }

        guard fits > 0, let color = textFillColor else {
            return TextFlow(lineCount: fits, height: height, remainder: remainder)
        }

        // 縦の指定は塊全体に効く。基準線は矩形の中では意味を持たないので、上と同じに倒す
        var top = box.y
        switch currentVerticalTextAlign {
        case .top, .baseline: break
        case .center: top = box.y + (box.height - height) / 2
        case .bottom: top = box.y + box.height - height
        }

        var baseline = top + face.ascent
        for line in lines.prefix(fits) {
            let x: Float
            switch currentHorizontalTextAlign {
            case .left: x = box.x
            case .center: x = box.x + box.width / 2
            case .right: x = box.x + box.width
            }
            drawLine(line, face: face, x: x, baseline: baseline, color: color)
            baseline += leading
        }

        return TextFlow(lineCount: fits, height: height, remainder: remainder)
    }

    /// 幅に収まるように行へ切り分ける。
    ///
    /// 返るのは**元の文字列の中の範囲**なので、置けなかった行の先頭から先が
    /// そのまま「残り」になる。
    ///
    /// 折るために消費した空白は、どちらの行にも入らない。こうしておくと
    /// **各行の幅は ``textWidth(_:)`` が返す値そのもの**になり、測った幅と描いた幅が
    /// 食い違わない。
    func wrapped(_ string: String, face: Typeface, within limit: Float) -> [Substring] {
        var lines: [Substring] = []
        for paragraph in string.split(separator: "\n", omittingEmptySubsequences: false) {
            guard !paragraph.isEmpty else {
                lines.append(paragraph)
                continue
            }

            var start = paragraph.startIndex
            var index = paragraph.startIndex
            var width: Float = 0
            var lastSpace: String.Index?

            while index < paragraph.endIndex {
                let character = paragraph[index]
                let step = face.advance(of: String(character))

                // **切れ目は、幅を測る前に憶える。** 幅を超えたのが空白そのものだった
                // とき、その空白は「ここまでが 1 行」の合図であって、次の行へ送る
                // 対象ではない
                if character.isWhitespace, index > start { lastSpace = index }

                // **1 文字だけの行は折らない。** 幅より広い字はそのままはみ出させる
                if width + step > limit, index > start {
                    if currentTextWrap == .word, let space = lastSpace, space > start {
                        lines.append(paragraph[start..<space])
                        var next = space
                        while next < paragraph.endIndex, paragraph[next].isWhitespace {
                            next = paragraph.index(after: next)
                        }
                        start = next
                        index = next
                    } else {
                        lines.append(paragraph[start..<index])
                        start = index
                    }
                    width = 0
                    lastSpace = nil
                    continue
                }

                width += step
                index = paragraph.index(after: index)
            }
            lines.append(paragraph[start..<paragraph.endIndex])
        }
        return lines
    }
}

// MARK: - 輪郭

extension Canvas {
    /// 文字列の輪郭を取り出す。
    ///
    /// **描くときと同じ送り**で並ぶので、``text(_:_:_:)`` と同じ位置・同じ字間になる。
    /// 返る点は**いまの座標のまま**で、変換は掛かっていない — そのまま
    /// ``vertex(_:_:)`` へ渡せば、文字を描いたのと同じ場所に出る。
    public func textOutline(_ string: String, _ x: Float, _ y: Float) -> [TextContour] {
        guard !string.isEmpty, currentTextSize > 0 else { return [] }
        let face = typeface
        let lines = string.split(separator: "\n", omittingEmptySubsequences: false)
        let leading = resolvedTextLeading
        var baseline = firstBaseline(at: y, face: face, lines: lines.count)

        var contours: [TextContour] = []
        for line in lines {
            contours += outline(of: line, face: face, x: x, baseline: baseline)
            baseline += leading
        }
        return contours
    }

    /// 1 行ぶんの輪郭。
    private func outline(
        of line: some StringProtocol, face: Typeface, x: Float, baseline: Float
    ) -> [TextContour] {
        var pen = penStart(at: x, face: face, line: line)

        var contours: [TextContour] = []
        for scalar in line.unicodeScalars {
            guard let resolved = face.glyph(for: scalar) else { continue }
            defer { pen += resolved.advance }
            guard let path = CTFontCreatePathForGlyph(resolved.font, resolved.glyph, nil)
            else { continue }
            // 字ごとに、外側の周を先に、穴を後ろに並べる
            let rings = Self.rings(of: path, originX: pen, baseline: baseline)
            contours += rings.filter { !$0.isHole }
            contours += rings.filter(\.isHole)
        }
        return contours
    }

    /// 輪郭の道筋を、点の並びへほどく。
    ///
    /// 書体の座標は基準線から**上向き**に測るので、面の縦向きに合わせて折り返す。
    /// 折り返すと巻きの向きも入れ替わるので、穴かどうかは折り返した後の面積で見る
    /// (面の座標では、外側が正・穴が負になる)。
    static func rings(of path: CGPath, originX: Float, baseline: Float) -> [TextContour] {
        var rings: [[SIMD2<Float>]] = []
        var current: [SIMD2<Float>] = []

        func place(_ point: CGPoint) -> SIMD2<Float> {
            SIMD2(originX + Float(point.x), baseline - Float(point.y))
        }
        func close() {
            if current.count >= 3 { rings.append(current) }
            current = []
        }

        path.applyWithBlock { element in
            let item = element.pointee
            switch item.type {
            case .moveToPoint:
                close()
                current.append(place(item.points[0]))
            case .addLineToPoint:
                current.append(place(item.points[0]))
            case .addQuadCurveToPoint:
                guard let from = current.last else { break }
                let control = place(item.points[0])
                let to = place(item.points[1])
                // 2 次は 3 次に読み替えられる — 曲線を割る計算を 1 つに保つ
                appendCurve(
                    &current, from: from,
                    control1: from + (control - from) * (2.0 / 3.0),
                    control2: to + (control - to) * (2.0 / 3.0), to: to)
            case .addCurveToPoint:
                guard let from = current.last else { break }
                appendCurve(
                    &current, from: from, control1: place(item.points[0]),
                    control2: place(item.points[1]), to: place(item.points[2]))
            case .closeSubpath:
                close()
            @unknown default:
                break
            }
        }
        close()

        return rings.map { TextContour(points: $0, isHole: signedArea(of: $0) < 0) }
    }

    /// 曲線を直線の並びへ割る。**細かさは曲線の大きさから決める** — 字形の曲線は
    /// 大きさがまちまちなので、一律の本数では小さい曲線が過剰になり大きい曲線が粗くなる。
    private static func appendCurve(
        _ points: inout [SIMD2<Float>], from: SIMD2<Float>, control1: SIMD2<Float>,
        control2: SIMD2<Float>, to: SIMD2<Float>
    ) {
        let rough =
            simd_length(control1 - from) + simd_length(control2 - control1)
            + simd_length(to - control2)
        let steps = min(24, max(2, Int((rough / 2).rounded(.up))))
        for step in 1...steps {
            let t = Float(step) / Float(steps)
            points.append(cubicPoint(from, control1, control2, to, t))
        }
    }

    /// 周の符号つき面積。向きを読むために使う。
    static func signedArea(of points: [SIMD2<Float>]) -> Float {
        var total: Float = 0
        for index in points.indices {
            let a = points[index]
            let b = points[(index + 1) % points.count]
            total += a.x * b.y - b.x * a.y
        }
        return total / 2
    }
}
