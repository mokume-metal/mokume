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
        style.fontName = name
    }

    /// 既定の書体へ戻す。
    public func noTextFont() { style.fontName = nil }

    /// これから描く文字の大きさ (画素)。
    public func textSize(_ size: some ScalarConvertible) {
        let size = size.asFloat
        style.textSize = max(0, size)
    }

    /// これから描く文字の太さと傾き。
    public func textStyle(_ style: TextStyle) { self.style.textStyle = style }

    /// 文字列を、指定した位置のどちら側へ置くか。
    public func textAlign(
        _ horizontal: HorizontalTextAlign, _ vertical: VerticalTextAlign = .baseline
    ) {
        style.horizontalTextAlign = horizontal
        style.verticalTextAlign = vertical
    }

    /// 行と行の間隔 (画素)。
    public func textLeading(_ leading: some ScalarConvertible) {
        let leading = leading.asFloat
        style.textLeading = max(0, leading)
    }

    // MARK: - 寸法

    /// 実際に使う行送り。指定が無ければ大きさから決める。
    var resolvedTextLeading: Float { style.textLeading ?? style.textSize * Self.leadingRatio }

    /// 指定が無いときの行送りを、大きさの何倍にするか。
    static let leadingRatio: Float = 1.25

    /// 文字列の送り幅 (画素)。
    ///
    /// **1 文字ずつの送り幅の合計**なので、部分に切って足しても全体と一致する。
    /// 末尾の空白も幅に数える。改行を含む文字列では、いちばん長い行の幅を返す。
    public func textWidth(_ string: String) -> Float {
        let face = typeface
        var widest: Float = 0
        for line in string.lines {
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
    public func text(_ string: String, _ x: some ScalarConvertible, _ y: some ScalarConvertible) {
        let (x, y) = (x.asFloat, y.asFloat)
        guard let color = textFillColor, !string.isEmpty, style.textSize > 0 else { return }
        let face = typeface
        let lines = string.lines
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
    /// 矩形へ流し込む側 (``text(_:_:_:_:_:)``) は畳んでいない — あちらは塊全体を矩形の
    /// 中へ置く計算で、基準線ではなく上端から決まる。
    ///
    /// [#895]: https://github.com/mokume-metal/mokume/issues/895
    private func firstBaseline(at y: Float, face: Typeface, lines: Int) -> Float {
        // 最初の行の基準線から、最後の行の基準線までの距離
        let span = Float(lines - 1) * resolvedTextLeading
        switch style.verticalTextAlign {
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
        switch style.horizontalTextAlign {
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
        warnOnce(
            .missingFont,
            "textFont(): there is no typeface called \"\(name)\" in this environment. "
                + "The typeface is left as it is")
    }
}

// MARK: - 折り返しと流し込み

extension Canvas {
    /// 幅に収まらなくなったとき、どこで行を折るか。既定は語の切れ目。
    public func textWrap(_ mode: TextWrap) { style.textWrap = mode }

    /// 矩形の中へ文字列を流し込む。
    ///
    /// 4 つの数の読み方は ``rectMode(_:)`` が決める — ``rect(_:_:_:_:)`` と同じ約束である。
    /// 幅で折り返し、高さに収まる行だけを置く。
    ///
    /// **横の揃えは、行の末尾の空白を数えない。** 行をどこで折るかはこちらが決めるので、
    /// 折った行も段落の最後の行も、末尾の空白を除いた幅で揃える ([#1452])。
    /// ``textWidth(_:)`` と点の形の ``text(_:_:_:)`` は末尾の空白も数える — 渡された
    /// 文字列を、渡された位置で終わらせるためである。
    ///
    /// [#1452]: https://github.com/mokume-metal/mokume/issues/1452
    @discardableResult
    public func text(_ string: String, _ a: some ScalarConvertible, _ b: some ScalarConvertible, _ c: some ScalarConvertible, _ d: some ScalarConvertible)
        -> TextFlow
    {
        let (a, b, c, d) = (a.asFloat, b.asFloat, c.asFloat, d.asFloat)
        let box = resolveRect(a, b, c, d)
        guard box.width > 0, box.height > 0, style.textSize > 0, !string.isEmpty else {
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
        switch style.verticalTextAlign {
        case .top, .baseline: break
        case .center: top = box.y + (box.height - height) / 2
        case .bottom: top = box.y + box.height - height
        }

        var baseline = top + face.ascent
        for line in lines.prefix(fits) {
            let x: Float
            switch style.horizontalTextAlign {
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
    /// 折るために消費した空白は、どちらの行にも入らない。**切れ目に空白が続いていれば、
    /// 続いた空白をまとめて消費する** — 前のほうの空白が行の末尾に残ると、行の幅が
    /// その分だけ広く数えられる ([#1412])。こうしておくと**各行の幅は ``textWidth(_:)``
    /// が返す値そのもの**になり、測った幅と描いた幅が食い違わない。行の中ほどで続いた
    /// 空白 (切れ目にならないもの) と、段落の頭の空白 (字下げ) は行に残る。
    ///
    /// **文字の切れ目で折っても、切れ目の空白は同じく消費する** ([#1424])。行の末尾に
    /// 収まった空白も、溢れて次の行へ送られる空白も、どちらの行にも入らない — 行の頭に
    /// 空白が残ると左揃えの行がその幅だけずれ、段落の末尾では空白だけの行ができる。
    ///
    /// **段落の末尾の空白で折ったときは、空の行を足さない。** 切れ目の後ろに語が無く、消費した
    /// 空白の先が段落の終わりなので、次の行に置く字が無い — 空の行を足すと、行数と高さが 1 行
    /// ぶん増え、続きが改行から始まる ([#1419])。元からある空の行 (改行が続いたところ) は、
    /// いままでどおり 1 行に数える。
    ///
    /// **段落の最後の行も、末尾の空白を行に入れない** ([#1452])。溢れずに段落の終わりに達した
    /// 行は切れ目で折らないが、末尾の空白が残ると、折った行と同じく右揃え・中央揃えの行が
    /// その幅だけずれる — 同じ末尾の空白が、溢れれば消費され、収まれば残る、と幅しだいで
    /// 変わっていた。段落の頭の空白 (字下げ) と、空白だけの段落は、空白ごと 1 行に残る。
    ///
    /// 消費した空白 (段落の末尾で折ったときは、段落の終わりの改行も) と、段落の最後の行から
    /// 削った空白は、前の行の終わりと次の行の始まりの**間に、元の文字列のまま残っている** —
    /// 最後の段落の最後の行なら、その行の終わりと文字列の終わりの間である。いくつ消費したかは、
    /// 範囲の隙間を読めば分かる。
    ///
    /// [#1412]: https://github.com/mokume-metal/mokume/issues/1412
    /// [#1419]: https://github.com/mokume-metal/mokume/issues/1419
    /// [#1424]: https://github.com/mokume-metal/mokume/issues/1424
    /// [#1452]: https://github.com/mokume-metal/mokume/issues/1452
    func wrapped(_ string: String, face: Typeface, within limit: Float) -> [Substring] {
        var lines: [Substring] = []
        for paragraph in string.lines {
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
                //
                // **切れ目は、続いた空白の先頭に置く。** 溢れる直前に見た空白を切れ目に
                // すると、それより前の空白が行の末尾に残り、右揃え・中央揃えの行が
                // その幅だけずれる ([#1412])。段落の頭の空白 (字下げ) は、前に語が
                // 無いので切れ目にしない
                if character.isWhitespace, index > start,
                    !paragraph[paragraph.index(before: index)].isWhitespace
                {
                    lastSpace = index
                }

                // **1 文字だけの行は折らない。** 幅より広い字はそのままはみ出させる
                if width + step > limit, index > start {
                    if style.textWrap == .word, let space = lastSpace, space > start {
                        lines.append(paragraph[start..<space])
                        var next = space
                        while next < paragraph.endIndex, paragraph[next].isWhitespace {
                            next = paragraph.index(after: next)
                        }
                        start = next
                        index = next
                    } else {
                        // **文字の切れ目でも、切れ目の空白はまとめて消費する** ([#1424])。
                        // 行の末尾に収まった空白 (`index` の前) も、溢れた空白 (`index` から
                        // 後ろ) も、どちらの行にも入れない — 語の切れ目と同じ扱いである
                        let end = Self.lineEnd(in: paragraph, from: start, upTo: index)
                        lines.append(paragraph[start..<end])
                        // 行が字で終われば切れ目なので、溢れた側の空白も消費する。行の頭から
                        // 空白しか無い (字下げだけで溢れた) 行は空白で終わる — 字下げは切れ目
                        // ではないので消費しない
                        if !paragraph[paragraph.index(before: end)].isWhitespace {
                            while index < paragraph.endIndex, paragraph[index].isWhitespace {
                                index = paragraph.index(after: index)
                            }
                        }
                        start = index
                    }
                    width = 0
                    lastSpace = nil
                    continue
                }

                width += step
                index = paragraph.index(after: index)
            }
            // **段落の末尾の空白で折ったなら、空の行は足さない** ([#1419])。`start` が段落の
            // 終わりに達するのは、切れ目で折って後ろの空白を読み飛ばした先が段落の終わりだった
            // ときだけである — 語の切れ目でも文字の切れ目でも ([#1424])。元からある空の行
            // (空の段落) は頭の `guard` が足す
            //
            // **段落の最後の行も、末尾の空白を行に入れない** ([#1452])。溢れずに段落の終わりに
            // 達した行は切れ目で折らないので、ここで読み戻さないと末尾の空白が行の幅に数えられ、
            // 右揃え・中央揃えの行がずれる。空白だけの段落は空白ごと 1 行に残る
            if start < paragraph.endIndex {
                let end = Self.lineEnd(in: paragraph, from: start, upTo: paragraph.endIndex)
                lines.append(paragraph[start..<end])
            }
        }
        return lines
    }

    /// `start` から `end` までを 1 行にするとき、行の終わりをどこに置くか。
    ///
    /// **行の末尾に続いた空白を読み戻した位置を返す** — 行の末尾の空白は行の幅に数えられ、
    /// 右揃え・中央揃えの行をその幅だけずらす。**行の頭まで空白しか無ければ、`end` のまま
    /// 返す** — そうした行 (字下げだけで溢れた行・空白だけの段落) の空白は切れ目の空白では
    /// ないので、空白ごと 1 行に残す。
    ///
    /// `end` は `start` より後ろに渡す。返る位置も `start` より後ろにあるので、呼ぶ側は返った
    /// 行の最後の字を読める。
    ///
    /// 文字の切れ目で折るとき ([#1424]) と、段落の終わりに達したとき ([#1452]) の 2 か所が
    /// 読む。語の切れ目は切れ目を続いた空白の先頭に置くので ([#1412])、読み戻す空白が無い。
    ///
    /// [#1412]: https://github.com/mokume-metal/mokume/issues/1412
    /// [#1424]: https://github.com/mokume-metal/mokume/issues/1424
    /// [#1452]: https://github.com/mokume-metal/mokume/issues/1452
    private static func lineEnd(
        in paragraph: Substring, from start: String.Index, upTo end: String.Index
    ) -> String.Index {
        var trimmed = end
        while trimmed > start, paragraph[paragraph.index(before: trimmed)].isWhitespace {
            trimmed = paragraph.index(before: trimmed)
        }
        return trimmed > start ? trimmed : end
    }
}

// MARK: - 輪郭

extension Canvas {
    /// 文字列の輪郭を取り出す。
    ///
    /// **描くときと同じ送り**で並ぶので、``text(_:_:_:)`` と同じ位置・同じ字間になる。
    /// 返る点は**いまの座標のまま**で、変換は掛かっていない — そのまま
    /// ``vertex(_:_:)`` へ渡せば、文字を描いたのと同じ場所に出る。
    ///
    /// 字ごとに、外側の周が先・穴が後の順で並ぶ。
    ///
    /// **周の分かれ方は書体の持ち方どおりで、書体と字によって変わる。** 既定の書体は
    /// `A` や `B` のような字を重なった部品で持つので、`A` は重なった外周がいくつも返り、
    /// 三角の穴は ``TextContour/isHole`` の立った周として現れない (重ねて塗れば絵は
    /// 合う)。同じ既定の書体でも `o` や `D` は外周と穴に分かれる。字を「外周 + 穴」の
    /// 1 つの形として扱いたいなら、``textFont(_:)`` で書体を指定する — `Helvetica`
    /// などでは `A` が外周 1 つと穴 1 つになる。
    public func textOutline(_ string: String, _ x: some ScalarConvertible, _ y: some ScalarConvertible) -> [TextContour] {
        let (x, y) = (x.asFloat, y.asFloat)
        guard !string.isEmpty, style.textSize > 0 else { return [] }
        let face = typeface
        let lines = string.lines
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
