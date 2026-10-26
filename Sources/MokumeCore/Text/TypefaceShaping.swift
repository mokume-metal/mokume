// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import CoreText
import Foundation

/// 組版した 1 行の字形の並び (``Typeface/shape(_:)``)。[#2404]
///
/// **描く・幅・整列・墨の範囲は、どれもこの 1 つの結果から出す。** 別々に数えると、整列や墨の枠が
/// 数画素ずれる形で食い違う (``Typeface/advance(of:)`` と同じ理由)。
///
/// [#2404]: https://github.com/mokume-metal/mokume/issues/2404
final class ShapedLine {
    /// 1 つの字形。`x`・`y` は行の書き始めと基準線から測った位置 (画素。`y` は上向き)。
    struct Glyph {
        var resolved: ResolvedGlyph
        var x: Float
        var y: Float
    }

    let glyphs: [Glyph]
    /// 行の送り幅 (画素)。カーニング・合字を含む。
    let width: Float
    /// 字形ごとに焼き場で引いた結果の控え。頁の通し番号が一致する間だけ使える (``Typeface/placed`` と同じ約束)。
    /// 段 0 (`textSize` の大きさのまま) の字形を入れる。
    var placed: [PlacedGlyph?]
    /// ``placed`` の、拡大した段 (0 より上) の控え (#3251)。**段をキーに、字形ごとの控えの並びを持つ** —
    /// ``Typeface/placedScaled`` が (字・段) をキーに持つのと同じ約束で、頼んだ段について答えが決まった字形
    /// (``Canvas/GlyphLookup/settled``) だけが入る。**段の数は ``scaledStepLimit`` までで、超えたら古い段から
    /// 捨てる** — 拡大を動かし続ける絵が、通った段の数だけ控えを溜めないように (組版の控えの重みは字形の数で
    /// 数えるので、1 行が抱える控えは段 0 を含めて字形の数の (1 + 上限) 倍までに収まる)。
    private(set) var placedScaled: [Int: [PlacedGlyph?]] = [:]
    /// ``placedScaled`` の段を、入れた順に。
    private var scaledOrder: [Int] = []
    /// 1 行が拡大した段の控えを持つ段の数。拡大を少し動かしたとき (隣り合う段を行き来するとき) に、焼き直さず
    /// 控えから引ける数。
    static let scaledStepLimit = 4

    /// 拡大した段の字形の控えを引く。
    func scaledPlacement(step: Int, at index: Int) -> PlacedGlyph? {
        placedScaled[step]?[index]
    }

    /// 拡大した段の字形を控える。新しい段で上限を超えたら、いちばん古い段を捨てる。
    func notePlacedScaled(_ placed: PlacedGlyph, step: Int, at index: Int) {
        if placedScaled[step] == nil {
            if scaledOrder.count >= Self.scaledStepLimit {
                placedScaled[scaledOrder.removeFirst()] = nil
            }
            scaledOrder.append(step)
            placedScaled[step] = Array(repeating: nil, count: glyphs.count)
        }
        placedScaled[step]?[index] = placed
    }

    init(glyphs: [Glyph], width: Float) {
        self.glyphs = glyphs
        self.width = width
        self.placed = Array(repeating: nil, count: glyphs.count)
    }
}

/// 組版した 1 行の控えの鍵。**スカラ列そのもの**で比べる。
///
/// Swift の `String` は等価もハッシュも**正準等価**で取るので、字形の違う文字列 (`\u{4FAE}` と互換漢字
/// `\u{FA30}`・`\u{03A9}` (Ω) とオーム記号 `\u{2126}`・`\u{00C5}` (Å) とオングストローム記号
/// `\u{212B}`) が同じ鍵になり、先に組んだほうの結果が返ってしまう。`text()` の控えは
/// `Unicode.Scalar` が鍵で起きない ([#2404])。UTF-8 の列は、スカラ列と 1 対 1 に対応する。
///
/// [#2404]: https://github.com/mokume-metal/mokume/issues/2404
struct ShapedLineKey: Hashable {
    let line: String

    static func == (lhs: ShapedLineKey, rhs: ShapedLineKey) -> Bool {
        lhs.line.utf8.elementsEqual(rhs.line.utf8)
    }

    func hash(into hasher: inout Hasher) {
        var copy = line
        copy.withUTF8 { hasher.combine(bytes: UnsafeRawBufferPointer($0)) }
    }
}

/// 組版した字形の墨の控えの鍵。
struct ShapedInkKey: Hashable {
    var fontKey: String
    var glyph: CGGlyph
}

extension Typeface {
    /// 控える組版結果の重さ (字形の数) の合計の上限。毎フレーム違う文字列 (数の表示など) を渡しても控えが
    /// 育ちきらない。**件数ではなく字形の数で切る** — 長い文字列 1 本が、短い文字列何本ぶんも抱えるため。
    /// 超えたら、古い順に 1 件ずつ捨てる (``BoundedCache``。[ADR-0023] 決定 5)。
    ///
    /// [ADR-0023]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0023-frame-stages-and-outputs.md
    static let shapedBudget = 16384

    /// 1 行を組版する。**改行は含まない** (行の分け方は呼ぶ側 (`Canvas`) が決める)。
    ///
    /// CoreText が文字列を字形の列へ変える (`CTLine`)。複数のスカラでできた絵文字 (肌色の修飾子・国旗・
    /// ZWJ で繋いだ家族・異体字セレクタ・囲み) は 1 つの字形に、結合文字は基の字の字形と、位置をずらした
    /// 結合記号の字形になり、ラテンの字はカーニングが掛かる。書体が覆えない字は、CoreText が行の中で
    /// 別の書体を選ぶが、その書体は ``glyph(for:)`` と同じに扱う — 頼んだ太さ・傾きの面を持つなら
    /// その面へ引き直し、持たなければ知らせる ([#2561]・[#2770])。**幅は部品の幅の和にならない**
    /// (``advance(of:)`` の加法性を持たない)。
    ///
    /// 同じ文字列は控えから返す。**鍵はスカラ列そのもの**で、Swift の `String` の等価 (正準等価) では
    /// 比べない — `\u{212B}` (オングストローム記号) と `\u{00C5}` (Å) のように、字形の違う字が
    /// 同じ鍵にならない ([#2404])。
    ///
    /// [#2404]: https://github.com/mokume-metal/mokume/issues/2404
    /// [#2561]: https://github.com/mokume-metal/mokume/issues/2561
    /// [#2770]: https://github.com/mokume-metal/mokume/issues/2770
    func shape(_ line: String) -> ShapedLine {
        let key = ShapedLineKey(line: line)
        if let found = shaped[key] { return found }
        let made = makeShaped(line)
        shaped.insert(made, for: key)
        return made
    }

    /// 1 つの行を、書体とその上書き (範囲ごとの書体) で `CTLine` にする。
    private static func makeLine(
        _ line: String, base: CTFont, overrides: [(range: CFRange, font: CTFont)]
    ) -> CTLine? {
        guard let text = CFAttributedStringCreateMutable(nil, 0) else { return nil }
        CFAttributedStringReplaceString(text, CFRangeMake(0, 0), line as CFString)
        let length = CFAttributedStringGetLength(text)
        CFAttributedStringSetAttribute(text, CFRangeMake(0, length), kCTFontAttributeName, base)
        for (range, font) in overrides {
            CFAttributedStringSetAttribute(text, range, kCTFontAttributeName, font)
        }
        return CTLineCreateWithAttributedString(text)
    }

    /// 書記素 (``Character``) 1 つぶんの、文字列の中の範囲 (UTF-16) とスカラ。
    private struct Cluster {
        var range: CFRange
        var scalars: [Unicode.Scalar]

        /// 字形を持たずに働く印 (ZWJ・異体字セレクタなど) を除いたスカラ。
        var visible: [Unicode.Scalar] { scalars.filter { !$0.properties.isDefaultIgnorableCodePoint } }

        func contains(_ location: Int) -> Bool {
            location >= range.location && location < range.location + range.length
        }
    }

    private static func clusters(of line: String) -> [Cluster] {
        var location = 0
        var clusters: [Cluster] = []
        for character in line {
            let length = character.utf16.count
            clusters.append(Cluster(range: CFRangeMake(location, length), scalars: Array(character.unicodeScalars)))
            location += length
        }
        return clusters
    }

    /// その書体が、字を全部覆うか (字形を持たずに働く印は問わない)。
    private static func covers(_ scalars: [Unicode.Scalar], in font: CTFont) -> Bool {
        scalars.allSatisfy { $0.properties.isDefaultIgnorableCodePoint || glyphIndex(of: $0, in: font) != 0 }
    }

    /// 行を組版する。**タブは CoreText に任せず、`text()` と同じに数える** — CoreText のタブは文字の大きさに
    /// 依らない既定の位置 (28 単位ごと) で止まり、大きな字ではほとんど幅を持たない。タブで行を分けて 1 区間ずつ
    /// 組み、タブの字形の送り幅 (``advance(of:)`` と同じ) ぶんだけ次の区間を右へ置く。区間をまたぐ
    /// カーニングは掛からない。
    private func makeShaped(_ source: String) -> ShapedLine {
        guard source.unicodeScalars.contains("\t") else { return makeShapedSegment(source) }
        let tab = glyph(for: "\t")?.advance ?? 0
        var glyphs: [ShapedLine.Glyph] = []
        var pen: Float = 0
        let segments = source.unicodeScalars.split(separator: "\t", omittingEmptySubsequences: false)
        for (index, segment) in segments.enumerated() {
            if index > 0 { pen += tab }
            let piece = makeShapedSegment(String(segment))
            for glyph in piece.glyphs {
                var moved = glyph
                moved.x += pen
                glyphs.append(moved)
            }
            pen += piece.width
        }
        return ShapedLine(glyphs: glyphs, width: pen)
    }

    private func makeShapedSegment(_ line: String) -> ShapedLine {
        guard var ctLine = Self.makeLine(line, base: base, overrides: []) else {
            return ShapedLine(glyphs: [], width: 0)
        }
        var overrides: [(range: CFRange, font: CTFont)] = []
        var clusters: [Cluster]?
        func clusterList() -> [Cluster] {
            if let clusters { return clusters }
            let made = Self.clusters(of: line)
            clusters = made
            return made
        }

        // 1. **絵文字でない字から始まる書記素は、基の字を書体に残す。** 基の字を書体が覆えるのに、後ろに付く
        //    字 (書体が持たない異体字セレクタ 16・ZWJ・モンゴル文字の異体字セレクタ・タグ文字・肌色の修飾子・
        //    囲み記号) があると、CoreText は書記素ごと別の書体へ移し、覆える基の字の書体まで替わる。移された
        //    書記素は、基の字の後ろへ別の書体の区間 (続く字を CoreText が選んだ書体で) を立てて、基の字を
        //    書体に残す。絵文字から始まる書記素 (合成絵文字) は CoreText に任せる
        var moved = Self.runs(of: ctLine, default: base).filter { !CFEqual($0.font, base) }
        var tails: [Int: Cluster] = [:]  // 基の字を残した書記素の、続く字の部分 (書記素の先頭の位置が鍵)
        if !moved.isEmpty {
            for cluster in clusterList() where cluster.scalars.count > 1 {
                let head = cluster.scalars[0]
                guard !head.properties.isEmoji, Self.glyphIndex(of: head, in: base) != 0,
                    moved.contains(where: { $0.contains(cluster.range.location) })
                else { continue }
                let headLength = String(head).utf16.count
                let tail = CFRangeMake(cluster.range.location + headLength, cluster.range.length - headLength)
                var text = String.UnicodeScalarView()
                text.append(contentsOf: cluster.scalars.dropFirst())
                let tailText = String(text) as CFString
                let font = CTFontCreateForString(base, tailText, CFRangeMake(0, CFStringGetLength(tailText)))
                overrides.append((tail, font))
                tails[cluster.range.location] = Cluster(range: tail, scalars: Array(cluster.scalars.dropFirst()))
            }
            if !overrides.isEmpty, let pinned = Self.makeLine(line, base: base, overrides: overrides) {
                ctLine = pinned
            }
        }

        // 2. 代わりの書体 (CoreText が行の中で選んだ、``base`` と違う書体) の字を、``glyph(for:)`` と同じに
        //    **書記素ごと**扱う: 頼んだ太さ・傾きの面へ引き直し、引き直しても面が頼んだ性質を欠くなら知らせる
        //    ([#2561]・[#2770])。面が覆える書記素だけを引き直した面で組み直す (カーニングや結合記号の位置も
        //    その面で決まる)。区間の中の隣の字が面を欠いても、覆える字は頼んだ面になる
        let requested = Self.traits(of: request.style)
        let pins = overrides.count
        moved = Self.runs(of: ctLine, default: base).filter { !CFEqual($0.font, base) }
        if !requested.isEmpty {
            for run in moved {
                for whole in clusterList() {
                    let cluster = tails[whole.range.location] ?? whole
                    guard run.contains(cluster.range.location) else { continue }
                    let visible = cluster.visible
                    guard
                        let sample = visible.first(where: { Self.glyphIndex(of: $0, in: run.font) != 0 })
                    else { continue }
                    // 知らせる字は、書体が持たない最初の字 (持つ字を名乗ると、例の書体に基の書体自身を挙げる)
                    let named = visible.first(where: { Self.glyphIndex(of: $0, in: base) == 0 }) ?? sample
                    let font = run.font
                    let (face, _, lacksStyle) = Self.restyledFallback(
                        font, glyph: Self.glyphIndex(of: sample, in: font), requested: requested,
                        copy: { CTFontCreateCopyWithSymbolicTraits(font, CTFontGetSize(font), nil, $0, $0) },
                        glyphIndex: { Self.covers(cluster.scalars, in: $0) ? Self.glyphIndex(of: sample, in: $0) : 0 })
                    if !CFEqual(face, font) { overrides.append((cluster.range, face)) }
                    if lacksStyle { onFallbackLackingStyle(self, named, face) }
                }
            }
        }
        if overrides.count > pins, let restyled = Self.makeLine(line, base: base, overrides: overrides) {
            ctLine = restyled
        }

        let width = Float(CTLineGetTypographicBounds(ctLine, nil, nil, nil))
        var glyphs: [ShapedLine.Glyph] = []
        for run in CTLineGetGlyphRuns(ctLine) as? [CTRun] ?? [] {
            guard CTRunGetGlyphCount(run) > 0 else { continue }
            let font = Self.font(of: run, default: base)
            let (indices, positions) = Self.glyphs(of: run)
            // 鍵は ``glyph(for:)`` と同じ作り方。ファイルから読んだ書体の字は、同じ PostScript 名の
            // インストール済みの書体と焼き場で混ざらないよう、ファイルの同一性を鍵に含める (#2445)。
            // 代わりの書体 (``base`` と違う書体) はこの環境の書体で、名前だけ。見分けは名前ではなく構造で行う
            var fontKey = (CTFontCopyPostScriptName(font) as String?) ?? ""
            if let file = request.file, CFEqual(font, base) { fontKey += "#" + file.identity }
            for index in indices.indices where indices[index] != 0 {
                let resolved = ResolvedGlyph(font: font, glyph: indices[index], advance: 0, fontKey: fontKey)
                glyphs.append(
                    ShapedLine.Glyph(
                        resolved: resolved, x: Float(positions[index].x), y: Float(positions[index].y)))
            }
        }
        return ShapedLine(glyphs: glyphs, width: width)
    }

    /// 行の区間 (CTRun) の、文字列の範囲と書体。
    private struct RunSpan {
        var range: CFRange
        var font: CTFont

        func contains(_ location: Int) -> Bool {
            location >= range.location && location < range.location + range.length
        }
    }

    private static func runs(of line: CTLine, default fallback: CTFont) -> [RunSpan] {
        (CTLineGetGlyphRuns(line) as? [CTRun] ?? []).map {
            RunSpan(range: CTRunGetStringRange($0), font: font(of: $0, default: fallback))
        }
    }

    private static func font(of run: CTRun, default fallback: CTFont) -> CTFont {
        let attributes = CTRunGetAttributes(run) as NSDictionary
        return (attributes[kCTFontAttributeName] as! CTFont?) ?? fallback
    }

    private static func glyphs(of run: CTRun) -> (indices: [CGGlyph], positions: [CGPoint]) {
        let count = CTRunGetGlyphCount(run)
        var indices = [CGGlyph](repeating: 0, count: count)
        var positions = [CGPoint](repeating: .zero, count: count)
        CTRunGetGlyphs(run, CFRangeMake(0, 0), &indices)
        CTRunGetPositions(run, CFRangeMake(0, 0), &positions)
        return (indices, positions)
    }

    /// 組版した字形の墨の範囲 ([#2308] と同じ測り方)。字形の座標 (書き始めと基準線から測り、上向き) で返す。
    ///
    /// 道筋で描く字形は道筋の外接、色やビットマップの字形・道筋を持たない字形は焼き場と同じ描き方で描いた墨。
    /// 控えは (書体・字形の番号) ごとで、描くのは字形の種類ごとに 1 度だけである。
    ///
    /// 描いた画素は焼き場に預ける。`keepsPixels` が偽なら預けない — 呼ぶ側が拡大して描くときは、
    /// `shapedText()` が別の鍵 (拡大の段) の画素を焼くので、預けても引き取られない (``Typeface/drawnInk``)。
    ///
    /// [#2308]: https://github.com/mokume-metal/mokume/issues/2308
    func ink(
        of glyph: ResolvedGlyph, keeping atlas: GlyphAtlas, as key: GlyphAtlas.Key,
        keepsPixels: Bool = true
    ) -> CGRect? {
        let path = CTFontCreatePathForGlyph(glyph.font, glyph.glyph, nil)
        guard Self.measuresByDrawing(glyph, path: path) else { return path?.boundingBoxOfPath }
        let inkKey = ShapedInkKey(fontKey: glyph.fontKey, glyph: glyph.glyph)
        if let cached = shapedInks[inkKey] { return cached }
        switch Self.draw(glyph, on: atlas) {
        case .ink(let ink, let rendered):
            shapedInks[inkKey] = ink
            if keepsPixels, let rendered { atlas.keepRendered(rendered, for: key) }
            return ink
        case .failed:
            return nil
        }
    }
}
