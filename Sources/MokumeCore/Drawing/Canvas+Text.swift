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
        let name = Typeface.canonicalName(name)
        guard let resolved = Typeface.resolvedName(of: name) else {
            warnMissingFontOnce(name)
            return
        }
        style.fontSelection = .named(resolved)
    }

    /// ファイルから読んだ書体 (``Font``) を使う。
    public func textFont(_ font: Font) { style.fontSelection = .file(font) }

    /// 既定の書体へ戻す。
    public func noTextFont() { style.fontSelection = nil }

    /// これから描く文字の大きさ (画素)。
    public func textSize(_ size: some ScalarConvertible) {
        style.textSize = textMeasure(
            size.asFloat, from: "textSize", "the size", negative: .negativeTextSize)
    }

    /// これから描く文字の太さと傾き。
    ///
    /// **太さ (``textWeight(_:)``) とは後から書いたほうが勝つ。** 太さを頼んでいても、これを書くと
    /// 太さの指定は外れる。
    public func textStyle(_ style: TextStyle) { self.style.textStyle = style }

    /// これから描く文字の太さ (100〜900)。
    ///
    /// 整数に丸め、100 未満・900 超は端へ丸めて 1 度知らせる。数でない値は 1 度知らせて、前の太さのまま。
    public func textWeight(_ weight: some ScalarConvertible) {
        let value = weight.asFloat
        guard value.isFinite else {
            warnOnce(
                .notANumberTextWeight,
                "textWeight(): got \(value), which is not a number a weight can be, so the weight was left as it was")
            return
        }
        let (rounded, wasOutside) = TypefaceWeight.clamped(value)
        if wasOutside {
            warnRounded(
                .badTextWeight, "textWeight", "the weight",
                takes: "\(TypefaceWeight.range.lowerBound) to \(TypefaceWeight.range.upperBound)",
                passed: value, used: rounded)
        }
        // 傾きは、太さの前に頼んだ斜体を残す
        let italic = style.textStyle == .italic || style.textStyle == .boldItalic
        style.textFace = .weight(rounded, italic: italic)
    }

    /// 文字列を、指定した位置のどちら側へ置くか。
    public func textAlign(
        _ horizontal: HorizontalTextAlign, _ vertical: VerticalTextAlign = .baseline
    ) {
        style.horizontalTextAlign = horizontal
        style.verticalTextAlign = vertical
    }

    /// 行と行の間隔 (画素)。
    public func textLeading(_ leading: some ScalarConvertible) {
        style.textLeading = textMeasure(
            leading.asFloat, from: "textLeading", "the leading", negative: .negativeTextLeading)
    }

    /// 字の大きさと行送りに使える、いちばん大きい値 (画素)。
    ///
    /// **字の寸法から作る量がどれも `Float` の有限に収まる所に置く** ([#1587])。寸法は大きさに
    /// 比例し、そこから行送り (× 1.25)・上端と下端の和・送り幅の合計 (× 字数)・行の広がり
    /// (× 行数) を作り、輪郭では点どうしの距離を 2 乗する。上限を置かないと、有限の大きさでも
    /// これらが無限に溢れ、`0 × ∞` や `∞ - ∞` から NaN が出る。2 乗しても溢れない境
    /// (√`Float.greatestFiniteMagnitude` ≈ 1.8e19) より 1 桁下に置けば、字形の数倍の距離の
    /// 2 乗も、字数や行数を掛けた和も収まる。焼き場の上限の頁 (4096 画素) よりはるかに大きい
    /// ので、描ける字の大きさは変わらない。
    ///
    /// [#1587]: https://github.com/mokume-metal/mokume/issues/1587
    static let largestTextMeasure: Float = 1e18

    /// 大きさと行送りの受け口。**負の値は 0 に、数でない値・無限は 0 に、上限を越える値は
    /// 上限に締め、どれも 1 度知らせる** ([ADR-0020] 決定 5)。
    ///
    /// 負の値の知らせは口ごとの鍵 (`negative`) で言い、数でない値・上限越えの
    /// ``Warning/unusableTextMeasure`` とは分ける。以前は負の値だけ「説明に書いた扱い」として
    /// 黙っていたが、丸めたことを言わないのは決定 5 の「警告を出して」に反する ([#1698])。
    ///
    /// [ADR-0020]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0020-api-naming-and-surface.md
    /// [#1698]: https://github.com/mokume-metal/mokume/issues/1698
    private func textMeasure(
        _ value: Float, from name: String, _ quantity: String, negative: Warning
    ) -> Float {
        guard value.isFinite else {
            warnOnce(
                .unusableTextMeasure,
                "\(name)(): got \(value), which is not a number text can use, so 0 was used")
            return 0
        }
        guard value <= Self.largestTextMeasure else {
            warnOnce(
                .unusableTextMeasure,
                "\(name)(): \(value) is larger than text can be measured at, so "
                    + "\(Self.largestTextMeasure) was used")
            return Self.largestTextMeasure
        }
        guard value >= 0 else {
            warnRounded(negative, name, quantity, takes: "0 or more", passed: value, used: 0)
            return 0
        }
        return value
    }

    // MARK: - 寸法

    /// 実際に使う行送り。指定が無ければ大きさから決める。
    var resolvedTextLeading: Float { style.textLeading ?? style.textSize * Self.leadingRatio }

    /// 指定が無いときの行送りを、大きさの何倍にするか。
    static let leadingRatio: Float = 1.25

    /// 文字列の送り幅 (画素)。
    ///
    /// **Unicode のスカラ 1 つずつの送り幅の合計**なので、部分に切って足しても全体と一致する。
    /// 組版をしないので、複数のスカラでできた絵文字の幅は部品の幅の和になる。
    /// 末尾の空白も幅に数える。改行を含む文字列では、いちばん長い行の幅を返す。
    ///
    /// **大きさ 0 では 0 を返す** (高さと深さも同じ)。描く口と同じ見張りで帰る — 大きさ 0 を
    /// 書体へ渡すと、CoreText はそれを書体ごとの既定の大きさ (システム書体なら 13pt) と
    /// 読み替え、何も描かない文字列に幅があると答えてしまう ([#1539])。
    ///
    /// [#1539]: https://github.com/mokume-metal/mokume/issues/1539
    public func textWidth(_ string: String) -> Float {
        guard style.textSize > 0 else { return 0 }
        let face = typeface
        var widest: Float = 0
        for line in string.lines {
            widest = max(widest, face.advance(of: line))
        }
        return widest
    }

    public func textAscent() -> Float { style.textSize > 0 ? typeface.ascent : 0 }

    public func textDescent() -> Float { style.textSize > 0 ? typeface.descent : 0 }

    // MARK: - 描く

    /// 文字列を描く。
    ///
    /// 縦の基準は ``textAlign(_:_:)`` が決める。既定は**基準線** — `y` が字の乗る線になる。
    /// 改行で行が分かれ、行の間隔は ``textLeading(_:)`` が決める。
    /// 字は Unicode のスカラ 1 つずつ引き当てて並べ、組版はしない (複数のスカラでできた絵文字は部品ごとに描かれる)。
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
    func firstBaseline(at y: Float, face: Typeface, lines: Int) -> Float {
        // 最初の行の基準線から、最後の行の基準線までの距離。1 行なら掛けずに 0 — 行送りが
        // 何であれ、1 行の塊に広がりは無い
        let span = lines > 1 ? Float(lines - 1) * resolvedTextLeading : 0
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
        // 区間の外では字を焼き場へ焼くことも始めない (#1672)。焼き場が溢れて作り直すと、その
        // フレームの番号を覚えるので、区間の外で作り直すと次のフレームで作り直せず字が落ちる。
        // 字を置く所 (`appendGlyphQuad`) でも断るが、焼くのはそれより手前である
        guard canPlace else { return warnOutsideFrame(.placing) }
        guard !line.isEmpty else { return }

        var pen = penStart(at: x, face: face, line: line)

        for scalar in line.unicodeScalars {
            // 同じ頁で引いたことのある字は、書体も焼き場も引かない (``Typeface/placed``)
            if let placed = face.placed[scalar], placed.pageSerial == atlas.pageSerial {
                if !placed.entry.isBlank {
                    appendGlyphQuad(placed.entry, penX: pen, baseline: baseline, color: color)
                }
                pen += placed.advance
                continue
            }
            guard let resolved = face.glyph(for: scalar) else { continue }
            if let entry = glyphEntry(for: resolved) {
                // 引いた後の頁の番号で控える — 引く途中で頁を広げていれば、番号も新しい
                face.placed[scalar] = PlacedGlyph(
                    pageSerial: atlas.pageSerial, entry: entry, advance: resolved.advance)
                if !entry.isBlank {
                    appendGlyphQuad(entry, penX: pen, baseline: baseline, color: color)
                }
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
    /// 文字列を、渡された位置で終わらせるためである。改行しない空白 (U+00A0・U+202F・
    /// U+2007) は字と同じに扱うので、行の末尾にあっても幅に数える ([#1540])。
    ///
    /// [#1452]: https://github.com/mokume-metal/mokume/issues/1452
    /// [#1540]: https://github.com/mokume-metal/mokume/issues/1540
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
    /// ここで言う**空白は、折ってよい空白** (`Character.isBreakingSpace`) である。
    /// 改行しない空白 (U+00A0・U+202F・U+2007) は字と同じに扱い、切れ目にせず、消費も
    /// 削りもしない ([#1540])。
    ///
    /// **`.word` の切れ目は、空白だけでなく Unicode の行分割の規則 (UAX #14) が決める**
    /// ([#2448])。切れ目の候補は `lastWordBreak(in:after:upTo:breaks:)` が返し、空白の無い切れ目
    /// (和文の字と字の間) では何も消費しない。1 語 (切れ目と切れ目の間) が幅より長いときは、
    /// いままでどおり文字の切れ目へ倒れる。位置の計算は字ごとの送り幅の和のままである。
    ///
    /// [#2448]: https://github.com/mokume-metal/mokume/issues/2448
    /// [#1412]: https://github.com/mokume-metal/mokume/issues/1412
    /// [#1419]: https://github.com/mokume-metal/mokume/issues/1419
    /// [#1424]: https://github.com/mokume-metal/mokume/issues/1424
    /// [#1452]: https://github.com/mokume-metal/mokume/issues/1452
    /// [#1540]: https://github.com/mokume-metal/mokume/issues/1540
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
            // 段落の切れ目の候補。**溢れて初めて数える** — 1 行に収まる段落は、
            // 切れ目を数える費用を払わない
            var breaks: [WordBreak]?

            while index < paragraph.endIndex {
                let character = paragraph[index]
                let step = face.advance(of: String(character))

                // **1 文字だけの行は折らない。** 幅より広い字はそのままはみ出させる
                if width + step > limit, index > start {
                    // **語の切れ目は、溢れた字の手前までで最後の切れ目。** 幅を超えたのが
                    // 切れ目の空白そのものだったとき、その空白は「ここまでが 1 行」の合図
                    // であって、次の行へ送る対象ではない — 切れ目は空白の手前に置く
                    if style.textWrap == .word,
                        let cut = Self.lastWordBreak(
                            in: paragraph, after: start, upTo: index, breaks: &breaks)
                    {
                        lines.append(paragraph[start..<cut.end])
                        start = cut.next
                        index = cut.next
                    } else {
                        // **文字の切れ目でも、切れ目の空白はまとめて消費する** ([#1424])。
                        // 行の末尾に収まった空白 (`index` の前) も、溢れた空白 (`index` から
                        // 後ろ) も、どちらの行にも入れない — 語の切れ目と同じ扱いである
                        let end = Self.lineEnd(in: paragraph, from: start, upTo: index)
                        lines.append(paragraph[start..<end])
                        // 行が字で終われば切れ目なので、溢れた側の空白も消費する。行の頭から
                        // 空白しか無い (字下げだけで溢れた) 行は空白で終わる — 字下げは切れ目
                        // ではないので消費しない
                        if !paragraph[paragraph.index(before: end)].isBreakingSpace {
                            while index < paragraph.endIndex, paragraph[index].isBreakingSpace {
                                index = paragraph.index(after: index)
                            }
                        }
                        start = index
                    }
                    width = 0
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
    /// 読み戻すのは折ってよい空白 (`Character.isBreakingSpace`) だけで、改行しない
    /// 空白は字と同じく行に残す ([#1540])。
    ///
    /// [#1412]: https://github.com/mokume-metal/mokume/issues/1412
    /// [#1424]: https://github.com/mokume-metal/mokume/issues/1424
    /// [#1452]: https://github.com/mokume-metal/mokume/issues/1452
    /// [#1540]: https://github.com/mokume-metal/mokume/issues/1540
    private static func lineEnd(
        in paragraph: Substring, from start: String.Index, upTo end: String.Index
    ) -> String.Index {
        var trimmed = end
        while trimmed > start, paragraph[paragraph.index(before: trimmed)].isBreakingSpace {
            trimmed = paragraph.index(before: trimmed)
        }
        return trimmed > start ? trimmed : end
    }

    /// 語の切れ目 1 つ。**行が `end` で終わり、次の行が `next` から始まる。**
    ///
    /// `end` と `next` の間にあるのは、切れ目に続く折ってよい空白 (`Character.isBreakingSpace`)
    /// だけで、どちらの行にも入らない。空白の無い切れ目 (和文の字と字の間など) は `end == next`
    /// で、何も消費しない。
    struct WordBreak {
        var end: String.Index
        var next: String.Index
    }

    /// `start` から数えて、`limit` より前で最後の語の切れ目を返す。無ければ `nil`。
    ///
    /// **語の切れ目は Unicode の行分割の規則 (UAX #14) で決める** ([#2448])。組版はせずに
    /// 切れ目だけを `CFStringTokenizer` (`kCFStringTokenizerUnitLineBreak`) から借りる — 位置を
    /// 決める計算は、いまも字ごとの送り幅の和のままである (``Typeface`` の加法性の決定)。
    /// 規則は、行頭に来てはいけない字 (「、」「。」「」」) と行末に残してはいけない字 (「「」) を
    /// 切れ目の前後に置かず、空白の無い和文には字と字の間に切れ目を置き、改行しない空白
    /// (U+00A0・U+202F・U+2007) の前後では切らない。
    ///
    /// 切れ目は、切れ目に続く空白の手前 (`end`) に置く。`start` と同じかその手前に `end` が
    /// 来る切れ目は、行が空になるので数えない — 段落の頭の空白 (字下げ) の後ろの切れ目も
    /// 同じ理由で、前に語が無いので切れ目にしない。
    ///
    /// 段落ごとに最初に呼ばれたときだけ切れ目を数え、`breaks` に残す。
    ///
    /// [#2448]: https://github.com/mokume-metal/mokume/issues/2448
    private static func lastWordBreak(
        in paragraph: Substring, after start: String.Index, upTo limit: String.Index,
        breaks: inout [WordBreak]?
    ) -> WordBreak? {
        let candidates: [WordBreak]
        if let cached = breaks {
            candidates = cached
        } else {
            candidates = wordBreaks(in: paragraph)
            breaks = candidates
        }
        // `end` は昇順に並ぶので、`limit` 以下で最後のものを二分探索する
        var low = 0
        var high = candidates.count
        while low < high {
            let middle = (low + high) / 2
            if candidates[middle].end <= limit {
                low = middle + 1
            } else {
                high = middle
            }
        }
        guard low > 0, candidates[low - 1].end > start else { return nil }
        return candidates[low - 1]
    }

    /// 段落の語の切れ目を、前から順に並べて返す。
    ///
    /// UAX #14 の切れ目の単位は、続く空白までを含む (「語 」)。単位の終わりが次の行の
    /// 始まり (`next`) で、末尾の折ってよい空白を除いた位置が行の終わり (`end`) である。
    /// 字の境界に載らない位置 (結合文字列の途中) の切れ目と、空白しか無い単位 (段落の頭の
    /// 字下げ)、段落の終わりで終わる空白の無い単位は、切れ目にしない。
    private static func wordBreaks(in paragraph: Substring) -> [WordBreak] {
        let units = Array(paragraph.utf16)
        guard
            let text = units.withUnsafeBufferPointer({
                CFStringCreateWithCharacters(nil, $0.baseAddress, units.count)
            })
        else { return [] }
        let tokenizer = CFStringTokenizerCreate(
            nil, text, CFRange(location: 0, length: units.count),
            kCFStringTokenizerUnitLineBreak, nil)

        var result: [WordBreak] = []
        var unitStart = paragraph.startIndex
        var startIsBoundary = true
        var offset = 0
        while CFStringTokenizerAdvanceToNextToken(tokenizer).rawValue != 0 {
            let range = CFStringTokenizerGetCurrentTokenRange(tokenizer)
            // 単位は隙間なく並ぶ。隙間があれば、その単位は飛ばす (切れ目が減るだけで、
            // 溢れた行は文字の切れ目へ倒れる)
            let contiguous = range.location == offset
            offset = range.location + range.length
            let unitEnd = paragraph.utf16.index(paragraph.startIndex, offsetBy: offset)
            let endIsBoundary = unitEnd.samePosition(in: paragraph.base) != nil
            let usable = contiguous && startIsBoundary && endIsBoundary
            let previousStart = unitStart
            unitStart = unitEnd
            startIsBoundary = endIsBoundary
            guard usable else { continue }

            var end = unitEnd
            while end > previousStart, paragraph[paragraph.index(before: end)].isBreakingSpace {
                end = paragraph.index(before: end)
            }
            guard end > previousStart, end < paragraph.endIndex else { continue }
            result.append(WordBreak(end: end, next: unitEnd))
        }
        return result
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
    /// 1 つの形として扱いたいなら、``textFont(_:)-(String)`` で書体を指定する — `Helvetica`
    /// などでは `A` が外周 1 つと穴 1 つになる。
    ///
    /// **色やビットマップの字形を持つ書体の字 (絵文字) は周を返さない** (送りは進める)。描かれるのは
    /// 絵で、書体が道筋を持っていても描く絵の形ではない (国旗の部品 🇯 の矩形など) ([#2308])。
    /// どの字がそれに当たるかは、``textBounds(_:_:_:)`` が描いて測る字と同じ
    /// (`Typeface.measuresByDrawing(_:path:)`) — 返る周の外接は、いつも枠と揃う。
    ///
    /// [#2308]: https://github.com/mokume-metal/mokume/issues/2308
    public func textOutline(_ string: String, _ x: some ScalarConvertible, _ y: some ScalarConvertible) -> [TextContour] {
        outlineContours(string, x.asFloat, y.asFloat)
    }

    /// 文字列の輪郭を、点の間隔を揃えて取り出す。意味の説明は `Sketch` が正本 ([ADR-0020] 決定 4)。
    ///
    /// **点の間隔は画素で渡す。** 周ごとに、折れ目の点を結んだ閉じた折れ線を、周の長さを
    /// 均等に割る点へ取り直す ([#2447])。割る数は周の長さ ÷ `spacing` を切り上げた数で、
    /// 周が潰れないよう 3 点を下限にするので、隣り合う点の距離は `spacing` 以下になる。
    /// 周の並び・``TextContour/isHole``・描くときと同じ送りは、間隔を揃えても変わらない。
    ///
    /// **`spacing` が 0 以下・数でない値・無限のときは、1 度だけ知らせて折れ目の点を返す**
    /// (`spacing` を省いたときと同じ)。読み取りの口なので投げない ([ADR-0020] 決定 5)。
    ///
    /// [ADR-0020]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0020-api-naming-and-surface.md
    /// [#2447]: https://github.com/mokume-metal/mokume/issues/2447
    public func textOutline(
        _ string: String, _ x: some ScalarConvertible, _ y: some ScalarConvertible,
        spacing: some ScalarConvertible
    ) -> [TextContour] {
        let spacing = spacing.asFloat
        guard spacing.isFinite, spacing > 0 else {
            warnOnce(
                .invalidTextOutlineSpacing,
                "textOutline(): spacing takes a number above 0, but \(spacing) was passed, "
                    + "so the corner points of the outline were returned")
            return outlineContours(string, x.asFloat, y.asFloat)
        }
        return outlineContours(string, x.asFloat, y.asFloat, spacing: spacing)
    }

    /// ``textOutline(_:_:_:)`` と ``textOutline(_:_:_:spacing:)`` の本体。`spacing` が `nil` なら折れ目の点のまま。
    ///
    /// 呼ぶ側が、`spacing` を有限の正の数にしてから渡す。
    private func outlineContours(
        _ string: String, _ x: Float, _ y: Float, spacing: Float? = nil
    ) -> [TextContour] {
        var contours: [TextContour] = []
        var tooFine = false
        forEachGlyph(in: string, x, y) { _, resolved, path, pen, baseline in
            // 道筋を持たない字 (空白・ビットマップの字形) と、道筋が描く絵の形ではない字には周が無い
            guard let path, !Typeface.measuresByDrawing(resolved, path: path) else { return }
            // 字ごとに、外側の周を先に、穴を後ろに並べる
            var rings = Self.rings(of: path, originX: pen, baseline: baseline)
            if let spacing {
                rings = rings.map { ring in
                    let (points, capped) = Self.resample(ring.outline, spacing: spacing)
                    tooFine = tooFine || capped
                    return TextContour(outline: points, isHole: ring.isHole)
                }
            }
            contours += rings.filter { !$0.isHole }
            contours += rings.filter(\.isHole)
        }
        if tooFine {
            warnOnce(
                .invalidTextOutlineSpacing,
                "textOutline(): spacing \(spacing ?? 0) is so small that a contour would need more than "
                    + "\(Self.mostPointsPerContour) points, so the spacing was widened to keep to that")
        }
        return contours
    }

    /// 1 つの周に取る点の数の上限。`spacing` が周の長さに比べて極端に小さいときに、点が際限なく増えて
    /// メモリを使い切らないための締め ([#1587] と同じ向き: 読み取りの口は落ちない)。
    ///
    /// [#1587]: https://github.com/mokume-metal/mokume/issues/1587
    nonisolated static let mostPointsPerContour = 65_536

    /// 閉じた折れ線を、周の長さを均等に割る点へ取り直す。
    ///
    /// 始点は元の周の最初の点で、最後の点から最初の点へ戻る辺も周に数える。割る数は
    /// 周の長さ ÷ `spacing` を切り上げた数で、3 を下限、``mostPointsPerContour`` を上限にする。
    /// 長さは `Double` で積む (座標どうしの差の 2 乗が `Float` で溢れる大きさでも、有限なら測れる)。
    /// 返す 2 つ目の値は、上限に当たって間隔が `spacing` より広がったか。
    ///
    /// **周の長さが 0 か有限でないとき (点が 1 か所に潰れている・無限の座標を含む) は、取り直せないので
    /// 元の点のまま返す。**
    nonisolated static func resample(_ points: [SIMD2<Float>], spacing: Float) -> (points: [SIMD2<Float>], capped: Bool) {
        let count = points.count
        guard count >= 2 else { return (points, false) }
        let doubles = points.map { SIMD2<Double>($0) }
        var lengths: [Double] = []
        lengths.reserveCapacity(count)
        var total = 0.0
        for index in 0..<count {
            let length = simd_length(doubles[(index + 1) % count] - doubles[index])
            lengths.append(length)
            total += length
        }
        guard total.isFinite, total > 0 else { return (points, false) }

        let wanted = (total / Double(spacing)).rounded(.up)
        let capped = wanted > Double(mostPointsPerContour)
        let samples = Int(min(Double(mostPointsPerContour), max(3, wanted)))
        let step = total / Double(samples)

        var result: [SIMD2<Float>] = []
        result.reserveCapacity(samples)
        var edge = 0
        var edgeStart = 0.0
        for sample in 0..<samples {
            let target = Double(sample) * step
            // 目標の長さを含む辺まで進める。最後の辺で止まるので、丸めの誤差で配列を越えない
            while edge < count - 1, edgeStart + lengths[edge] < target {
                edgeStart += lengths[edge]
                edge += 1
            }
            let along = lengths[edge] > 0 ? min(1, max(0, (target - edgeStart) / lengths[edge])) : 0
            let from = doubles[edge]
            let to = doubles[(edge + 1) % count]
            result.append(SIMD2<Float>(from + (to - from) * along))
        }
        return (result, capped)
    }

    /// 文字列の墨が載る範囲。意味の説明は `Sketch` が正本 ([ADR-0020] 決定 4)。
    ///
    /// **``textOutline(_:_:_:)`` と同じ字形・同じ送り・同じ基準線から取る** ([#1284])。枠は
    /// 字ごとの墨の範囲の和で、字の墨の取り方は 2 通りある ([#2308]):
    ///
    /// - 書体が道筋で描く字は、**道筋の外接**。輪郭の点の外接と、曲線をほどいた細かさの
    ///   ぶんしか違わない
    /// - 色やビットマップの字形を持つ書体の字 (絵文字) と、道筋を持たない字は、**焼き場と同じ
    ///   描き方で描いた墨の範囲** (`Typeface.drawnInk(of:_:)`)。道筋が無いか、あっても描く絵と別の
    ///   仮の形なので、道筋で測ると `text()` が描く絵文字が枠の外へはみ出す。どちらで測るかは
    ///   `Typeface.measuresByDrawing(_:path:)` が決める
    ///
    /// [ADR-0020]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0020-api-naming-and-surface.md
    /// [#1284]: https://github.com/mokume-metal/mokume/issues/1284
    /// [#2308]: https://github.com/mokume-metal/mokume/issues/2308
    public func textBounds(_ string: String, _ x: some ScalarConvertible, _ y: some ScalarConvertible) -> TextBounds? {
        var box = CGRect.null
        let face = typeface
        forEachGlyph(in: string, x.asFloat, y.asFloat) { scalar, resolved, path, pen, baseline in
            let measured =
                Typeface.measuresByDrawing(resolved, path: path)
                ? face.drawnInk(of: scalar, resolved, keeping: atlas, as: glyphKey(for: resolved))
                : path?.boundingBoxOfPath
            guard let glyph = measured else { return }
            // 道筋を持つが面積の無い字 (点 1 つだけの道筋) は墨に数えない
            guard !glyph.isNull, glyph.width > 0 || glyph.height > 0 else { return }
            // 書体の座標は基準線から上向きなので、面の縦向きへ折り返す (`rings` と同じ)
            box = box.union(
                CGRect(
                    x: CGFloat(pen) + glyph.minX, y: CGFloat(baseline) - glyph.maxY,
                    width: glyph.width, height: glyph.height))
        }
        // 墨が無ければ枠も無い。幅 0 の枠を返すと「そこに墨がある」と読めてしまう
        guard !box.isNull else { return nil }
        return TextBounds(
            x: Float(box.minX), y: Float(box.minY), width: Float(box.width),
            height: Float(box.height))
    }

    /// 文字列の字形を、**描くときと同じ送りと基準線**で 1 つずつ渡す。輪郭と墨の範囲が
    /// 同じ歩き方を読む — 別々に歩くと、整列や行送りが片方でだけずれる形で食い違う。
    ///
    /// 読み取りの口から呼ぶので、数でない位置・無限の位置・大きさ 0 では何も渡さない (#1587)。
    /// **道筋を持たない字も渡す** (道筋は `nil`)。空白だけでなく、色を持つ字形 (絵文字) も道筋を
    /// 持たない — 「道筋が無い字 = 空白」と読んで飛ばすと、絵文字の墨を落とす (#2308)。道筋を
    /// どう読むか (外接を取るか、描いて測るか) は受け取る側が決める。
    private func forEachGlyph(
        in string: String, _ x: Float, _ y: Float,
        _ body: (
            _ scalar: Unicode.Scalar, _ resolved: ResolvedGlyph, _ path: CGPath?, _ pen: Float,
            _ baseline: Float
        ) -> Void
    ) {
        guard !string.isEmpty, style.textSize > 0, x.isFinite, y.isFinite else { return }
        let face = typeface
        let lines = string.lines
        let leading = resolvedTextLeading
        var baseline = firstBaseline(at: y, face: face, lines: lines.count)

        for line in lines {
            var pen = penStart(at: x, face: face, line: line)
            for scalar in line.unicodeScalars {
                guard let resolved = face.glyph(for: scalar) else { continue }
                let path = CTFontCreatePathForGlyph(resolved.font, resolved.glyph, nil)
                body(scalar, resolved, path, pen, baseline)
                pen += resolved.advance
            }
            baseline += leading
        }
    }

    /// 輪郭の道筋を、点の並びへほどく。
    ///
    /// 書体の座標は基準線から**上向き**に測るので、面の縦向きに合わせて折り返す。
    /// 折り返すと巻きの向きも入れ替わるので、穴かどうかは折り返した後の面積で見る
    /// (面の座標では、外側が正・穴が負になる)。
    nonisolated static func rings(of path: CGPath, originX: Float, baseline: Float) -> [TextContour] {
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

        return rings.map { TextContour(outline: $0, isHole: signedArea(of: $0) < 0) }
    }

    /// 曲線を直線の並びへ割る。**細かさは曲線の大きさから決める** — 字形の曲線は
    /// 大きさがまちまちなので、一律の本数では小さい曲線が過剰になり大きい曲線が粗くなる。
    ///
    /// **大きさは字の座標 (文字の大きさの寸法) で測り、変換は見ない** ([#2033])。返す点は
    /// 変換を掛けないデータで、どの変換の下で描かれるかは呼んだ時点で決まらないためである。
    /// 拡大して描くと粗くなることは、`Sketch` の `textOutline` の説明が名乗っている。
    ///
    /// **割る数は `Float` のまま 2…24 に締めてから Int へ直す** ([#1587])。巨大な大きさでは
    /// 曲線の長さが `2 × Int.max` を越えるか、長さを測る 2 乗が `Float` からあふれて無限になる。
    /// 点が無限どうしの差から NaN になったときは、下限の 2 に倒す (絵にならない周なので細かさは
    /// 要らない)。
    ///
    /// [#1587]: https://github.com/mokume-metal/mokume/issues/1587
    /// [#2033]: https://github.com/mokume-metal/mokume/issues/2033
    private nonisolated static func appendCurve(
        _ points: inout [SIMD2<Float>], from: SIMD2<Float>, control1: SIMD2<Float>,
        control2: SIMD2<Float>, to: SIMD2<Float>
    ) {
        let rough =
            simd_length(control1 - from) + simd_length(control2 - control1)
            + simd_length(to - control2)
        let wanted = (rough / 2).rounded(.up)
        let steps = wanted.isNaN ? 2 : Int(min(24, max(2, wanted)))
        for step in 1...steps {
            let t = Float(step) / Float(steps)
            points.append(cubicPoint(from, control1, control2, to, t))
        }
    }

    /// 周の符号つき面積。向きを読むために使う。
    ///
    /// **`Double` で積む** ([#1587])。座標どうしの積は、`Float` では大きな字や原点から遠い
    /// 位置で無限に溢れ、`∞ - ∞` の NaN から穴がすべて外周と読まれる。`Float` の有限の値
    /// どうしの積は `Double` なら溢れない。
    nonisolated static func signedArea(of points: [SIMD2<Float>]) -> Double {
        var total: Double = 0
        for index in points.indices {
            let a = SIMD2<Double>(points[index])
            let b = SIMD2<Double>(points[(index + 1) % points.count])
            total += a.x * b.y - b.x * a.y
        }
        return total / 2
    }
}

// MARK: - 折ってよい空白

nonisolated extension Character {
    /// 流し込みが行を折ってよい空白か ([#1540])。
    ///
    /// **空白のうち、改行しない空白 (U+00A0 NO-BREAK SPACE・U+202F NARROW NO-BREAK SPACE・
    /// U+2007 FIGURE SPACE) を除いたもの。** `isWhitespace` はこの 3 つにも true を返すが、
    /// Unicode の改行規則 (UAX #14) ではこの 3 つは前後で折らない類 (GL) で、「10 km」の
    /// ように切らないために置く。Java の `Character.isWhitespace` も数えない。
    ///
    /// 流し込みはこの判定だけで、折る場所・切れ目の後ろで消費する空白・行末から削る空白を
    /// 決める。3 つの場面で同じ判定を読むので、改行しない空白はどの場面でも字と同じになる。
    ///
    /// [#1540]: https://github.com/mokume-metal/mokume/issues/1540
    var isBreakingSpace: Bool {
        // 改行しない空白はどれも ASCII の外なので、ASCII の字は空白かどうかだけで決まる
        if asciiValue != nil { return isWhitespaceQuickly }
        return isWhitespace && !unicodeScalars.contains { Self.noBreakSpaces.contains($0) }
    }

    /// 改行しない空白。
    private static let noBreakSpaces: Set<Unicode.Scalar> = ["\u{00A0}", "\u{202F}", "\u{2007}"]
}
