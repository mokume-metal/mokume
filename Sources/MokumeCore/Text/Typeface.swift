// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import CoreText
import Foundation
import MokumeDiagnostics

/// どの書体を、どの大きさ・太さで使うかの指定。
struct TypefaceRequest: Hashable, Sendable {
    /// 書体の名前。`nil` はこの環境の既定の書体。
    var name: String?
    /// 大きさ (画素)。
    var size: Float
    /// 太さと傾き。
    var style: TextStyle
}

/// 1 文字ぶんの引き当て結果。
///
/// **書体は文字ごとに変わりうる。** 指定した書体が覆えない文字 (欧文の書体に日本語を
/// 渡した場合など) は、この環境が持つ別の書体から引く。送り幅もその書体のものを使う。
struct ResolvedGlyph {
    /// この字形を持っていた書体。
    var font: CTFont
    /// 書体の中での字形の番号。
    var glyph: CGGlyph
    /// 次の字までどれだけ進むか (画素)。
    var advance: Float
    /// 字形を焼き分けるための鍵になる、書体の識別名。
    var fontKey: String
}

/// 焼き場で引いた字形と、それを引いた頁 (``Typeface/placed``)。
struct PlacedGlyph {
    var pageSerial: UInt64
    var entry: GlyphAtlas.Entry
    var advance: Float
}

/// 指定された書体を引き当て、寸法を答える。
///
/// ## 送り幅をここだけで計算する
///
/// **文字列の幅は 1 文字ずつの送り幅の合計である。** 描画・計測・整列の 3 つの経路が
/// この型の ``advance(of:)`` だけを読むので、3 つの間で幅がずれることがない。
///
/// 幅を合計する場所を散らすと、症状は「整列が数画素ずれる」という形で出る —
/// 決定的だが小さく、枠を描いて拡大しないと見えない種類の壊れ方になる。
///
/// ## 組版はしない
///
/// 引き当ては**Unicode スカラ 1 つずつ**で、合字・字形の入れ替え・複雑な文字体系の
/// 並べ替えは行わない。組版の結果を使うと合字には強くなるが、**部分の幅を足しても
/// 全体の幅に一致しなくなる** (加法性が失われる)。両方は成り立たないので、
/// 加法性のほうを選んでいる。
final class Typeface {
    let request: TypefaceRequest
    /// 引き当ての出発点になる書体。
    let base: CTFont
    /// 基準線から上へどれだけ伸びるか (画素)。
    let ascent: Float
    /// 基準線から下へどれだけ伸びるか (画素)。
    let descent: Float

    /// 1 文字ぶんの引き当て結果の控え。同じ文字を何度も引かないために持つ。
    private var resolved: [Unicode.Scalar: ResolvedGlyph] = [:]

    /// 焼き場で引いた字形の控え ([#1783])。**頁の通し番号が一致する間だけ使える。**
    ///
    /// 字を置くたびに、書体の引き当て (``glyph(for:)``) と焼き場の引き当て (文字列を含む鍵の
    /// 辞書) の 2 度を引いていた。この書体の同じ文字は、同じ頁の上では必ず同じ字形を指す —
    /// 焼き分けの鍵 (書体名・大きさ・字体・字形の番号) は書体と文字で決まり、焼いた字形は
    /// 頁を替えるまで動かない。だから文字 1 つで引けるように控える。
    ///
    /// 大きさは ``resolved`` と同じく、この書体で描いた文字の種類の数で決まる。書体そのものは
    /// 面の控え (上限つき) に入っている。
    ///
    /// [#1783]: https://github.com/mokume-metal/mokume/issues/1783
    var placed: [Unicode.Scalar: PlacedGlyph] = [:]

    init(request: TypefaceRequest) {
        self.request = request
        self.base = Self.makeFont(request)
        self.ascent = Float(CTFontGetAscent(base))
        self.descent = Float(CTFontGetDescent(base))
    }

    /// 名前と大きさと太さから書体を作る。
    private static func makeFont(_ request: TypefaceRequest) -> CTFont {
        let size = CGFloat(request.size)
        let base: CTFont
        if let name = request.name {
            base = CTFontCreateWithName(name as CFString, size, nil)
        } else {
            base =
                CTFontCreateUIFontForLanguage(.system, size, nil)
                ?? CTFontCreateWithName("Helvetica" as CFString, size, nil)
        }

        var traits: CTFontSymbolicTraits = []
        if request.style == .bold || request.style == .boldItalic { traits.insert(.traitBold) }
        if request.style == .italic || request.style == .boldItalic { traits.insert(.traitItalic) }
        guard !traits.isEmpty else { return base }
        return CTFontCreateCopyWithSymbolicTraits(base, size, nil, traits, traits) ?? base
    }

    /// その名前の書体がこの環境にあるか。
    ///
    /// **無い名前を渡しても書体は返ってくる** — この環境は黙って別の書体へ倒すので、
    /// 返ってきた書体の名前と突き合わせないと「指定が効かなかった」ことに気付けない。
    static func exists(name: String) -> Bool {
        let font = CTFontCreateWithName(name as CFString, 12, nil)
        let family = CTFontCopyFamilyName(font) as String
        let postScript = (CTFontCopyPostScriptName(font) as String?) ?? ""
        return family.compare(name, options: .caseInsensitive) == .orderedSame
            || postScript.compare(name, options: .caseInsensitive) == .orderedSame
    }

    /// 1 文字ぶんを引き当てる。字形が無ければ `nil`。
    func glyph(for scalar: Unicode.Scalar) -> ResolvedGlyph? {
        if let cached = resolved[scalar] { return cached }

        var font = base
        var glyph = Self.glyphIndex(of: scalar, in: font)
        if glyph == 0 {
            // この書体が覆えない文字。環境が持つ別の書体から引く
            let text = String(scalar) as CFString
            font = CTFontCreateForString(base, text, CFRangeMake(0, CFStringGetLength(text)))
            glyph = Self.glyphIndex(of: scalar, in: font)
        }
        guard glyph != 0 else { return nil }

        var index = glyph
        var advance = CGSize.zero
        CTFontGetAdvancesForGlyphs(font, .horizontal, &index, &advance, 1)

        let entry = ResolvedGlyph(
            font: font, glyph: glyph, advance: Float(advance.width),
            fontKey: (CTFontCopyPostScriptName(font) as String?) ?? "")
        resolved[scalar] = entry
        return entry
    }

    /// 道筋を持たない字形の墨の範囲の控え。`nil` を控えるのは「墨が無い」(空白など) と分かった字。
    private var bitmapInks: [Unicode.Scalar: CGRect?] = [:]

    /// **道筋を持たない字形** (色を持つ字形・絵文字) の墨の範囲を、字形の座標 (書き始めと基準線
    /// から測り、上向き) で返す。墨が無ければ `nil` ([#2308])。
    ///
    /// こうした字形はビットマップで描かれ、道筋の外接では測れない。外接矩形
    /// (`CTFontGetBoundingRectsForGlyphs`) は送り幅の升目そのもので、見える墨より左右に広い
    /// (Apple Color Emoji の 🌲 は 40 で各 3 画素)。だから**焼き場と同じ描き方
    /// (``GlyphAtlas/render(glyph:font:width:height:penX:penY:)``) で描いて、不透明な画素の範囲を取る。**
    /// 書き始めは整数の升目に置くので、焼き場が焼く絵と同じ升目に乗る。字ごとに控えるので、
    /// 描くのは字の種類ごとに 1 度だけである。
    ///
    /// 外接矩形の面積が無い字 (空白) は、描かずに `nil` を返す (焼き場も焼かない)。焼き場の上限の
    /// 頁に入らない大きさの字は、描かずに外接矩形を返す — 墨を含む、送り幅の升目ぶん広い枠になる。
    ///
    /// [#2308]: https://github.com/mokume-metal/mokume/issues/2308
    func bitmapInk(of scalar: Unicode.Scalar, _ resolved: ResolvedGlyph) -> CGRect? {
        if let cached = bitmapInks[scalar] { return cached }
        let ink = Self.measureBitmapInk(resolved)
        bitmapInks[scalar] = ink
        return ink
    }

    private static func measureBitmapInk(_ resolved: ResolvedGlyph) -> CGRect? {
        var glyph = resolved.glyph
        let bounds = CTFontGetBoundingRectsForGlyphs(resolved.font, .horizontal, &glyph, nil, 1)
        guard bounds.width > 0, bounds.height > 0, bounds.width.isFinite, bounds.height.isFinite
        else { return nil }
        // 焼き場 (`GlyphAtlas.bake`) と同じく、外接矩形を整数へ広げて余白を足した升目に描く
        let pad = CGFloat(GlyphAtlas.padding)
        let leftEdge = bounds.minX.rounded(.down) - pad
        let bottomEdge = bounds.minY.rounded(.down) - pad
        let rightEdge = bounds.maxX.rounded(.up) + pad
        let topEdge = bounds.maxY.rounded(.up) + pad
        // 焼き場の上限の頁に入らない字は描いて測らない (巨大な絵を CPU に描かせない)。外接矩形は
        // 墨を含むので、それを枠にする — 道筋を持つ字も、焼き場に入らない大きさで枠を返す
        guard
            GlyphAtlas.fitsFreshPage(
                width: rightEdge - leftEdge, height: topEdge - bottomEdge,
                side: GlyphAtlas.maximumSize),
            let left = Int(exactly: leftEdge), let bottom = Int(exactly: bottomEdge),
            let right = Int(exactly: rightEdge), let top = Int(exactly: topEdge)
        else { return bounds }
        guard
            let pixels = GlyphAtlas.render(
                glyph: glyph, font: resolved.font, width: right - left, height: top - bottom,
                penX: -left, penY: -bottom)
        else { return nil }

        let width = right - left
        var (minColumn, maxColumn, minRow, maxRow) = (Int.max, Int.min, Int.max, Int.min)
        for (index, texel) in pixels.enumerated() where texel.w > 0 {
            let (row, column) = index.quotientAndRemainder(dividingBy: width)
            minColumn = min(minColumn, column)
            maxColumn = max(maxColumn, column)
            minRow = min(minRow, row)
            maxRow = max(maxRow, row)
        }
        guard minColumn <= maxColumn else { return nil }
        // 並びの先頭は絵の上端。行 r は、字形の座標で top - r - 1 から top - r までを覆う
        return CGRect(
            x: left + minColumn, y: top - maxRow - 1, width: maxColumn - minColumn + 1,
            height: maxRow - minRow + 1)
    }

    /// 書体の中での字形の番号。持っていなければ 0。
    private static func glyphIndex(of scalar: Unicode.Scalar, in font: CTFont) -> CGGlyph {
        var units = Array(String(scalar).utf16)
        var glyphs = [CGGlyph](repeating: 0, count: units.count)
        CTFontGetGlyphsForCharacters(font, &units, &glyphs, units.count)
        // 補助面の文字は先頭に字形が入り、続きは 0 になる
        return glyphs[0]
    }

    /// 文字列の送り幅 (画素)。
    ///
    /// **1 文字ずつの送り幅の合計**である。合計を `Float` で積むので、
    /// 部分文字列の幅を足すと全体の幅にそのまま一致する。改行は幅を持たない。
    func advance(of string: some StringProtocol) -> Float {
        var total: Float = 0
        for scalar in string.unicodeScalars {
            guard scalar != "\n" else { continue }
            total += glyph(for: scalar)?.advance ?? 0
        }
        return total
    }
}
