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
