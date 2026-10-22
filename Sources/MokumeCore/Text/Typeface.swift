// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import CoreText
import Foundation
import MokumeDiagnostics

/// どの書体を、どの大きさ・太さで使うかの指定。
struct TypefaceRequest: Hashable, Sendable {
    /// 書体の名前。`nil` はこの環境の既定の書体。``file`` があれば使わない。
    var name: String?
    /// ファイルから読んだ書体 ([#2445])。あれば ``name`` より先に使う。
    ///
    /// [#2445]: https://github.com/mokume-metal/mokume/issues/2445
    var file: Font?
    /// 大きさ (画素)。
    var size: Float
    /// 太さと傾き。**``weight`` を頼んだなら太字を含まない** (呼ぶ側 (`Canvas`) が落とす)。太さを
    /// 頼んだ面と太字の面を、同じ面に別々の鍵で作らないため。
    var style: TextStyle
    /// 頼んだ太さ (100〜900 の整数)。`nil` は頼んでいない (``style`` の太字か否かで決まる)。
    var weight: Int?

    init(name: String?, file: Font? = nil, size: Float, style: TextStyle, weight: Int? = nil) {
        self.name = name
        self.file = file
        self.size = size
        self.style = style
        self.weight = weight
    }
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

    /// 頼まれた太さ・傾きの面を、書体が持っていなかったか ([#2444])。持っていなければ ``base`` は
    /// 元の面か、引けた片方の性質だけの面で、それを知らせるのは書体を作らせた側 (`Canvas`) である。
    ///
    /// [#2444]: https://github.com/mokume-metal/mokume/issues/2444
    let lacksRequestedStyle: Bool

    /// 頼んだ太さに対して、実際に使った面の太さ (CSS の数)。太さを頼んでいなければ `nil` ([#2445])。
    ///
    /// [#2445]: https://github.com/mokume-metal/mokume/issues/2445
    let usedWeight: Int?

    /// 頼んだ太さから、使った太さが大きく離れたか。持つ面に近い太さが無かった ([#2445])。
    ///
    /// [#2445]: https://github.com/mokume-metal/mokume/issues/2445
    var lacksRequestedWeight: Bool {
        guard let wanted = request.weight, let used = usedWeight else { return false }
        return abs(used - wanted) > TypefaceWeight.noticeableGap
    }

    /// 代わりの書体から引いた字の面が、頼んだ太さ・傾きを欠くときに呼ぶ口 ([#2561])。渡すのは
    /// この書体・その字・字を引いた書体で、知らせるのは書体を作らせた側 (`Canvas`) である。
    ///
    /// **省けない。** 書体を作る経路を足したときに、知らせが黙って落ちないよう、作る側に口を
    /// 必ず決めさせる (知らせない検査は空の口を渡す)。
    ///
    /// [#2561]: https://github.com/mokume-metal/mokume/issues/2561
    private let onFallbackLackingStyle: (Typeface, Unicode.Scalar, CTFont) -> Void

    init(
        request: TypefaceRequest,
        onFallbackLackingStyle: @escaping (Typeface, Unicode.Scalar, CTFont) -> Void
    ) {
        self.request = request
        let made = Self.makeFont(request)
        (self.base, self.lacksRequestedStyle, self.usedWeight) = (made.font, made.lacksStyle, made.usedWeight)
        self.ascent = Float(CTFontGetAscent(base))
        self.descent = Float(CTFontGetDescent(base))
        self.onFallbackLackingStyle = onFallbackLackingStyle
    }

    /// 頼んだ太さ・傾きを、CoreText の性質の印に直す。`.normal` は空。
    static func traits(of style: TextStyle) -> CTFontSymbolicTraits {
        switch style {
        case .normal: []
        case .bold: .traitBold
        case .italic: .traitItalic
        case .boldItalic: [.traitBold, .traitItalic]
        }
    }

    /// 代わりの書体の**家族に、頼んだ太さ・傾きの面が無いか** ([#2924])。
    ///
    /// 面の引き方は、同じ家族の中で頼んだ面を引き直す (``styledFace(of:traits:copy:)``) のと同じ —
    /// 家族が頼んだ面を持たなければ、`CTFontCreateCopyWithSymbolicTraits` は `nil` か、頼んだ性質を
    /// 欠く面を返す (ハングルの AppleMyungjo の太字・タイ文字の Ayuthaya の太字)。**家族が面を持つのに、
    /// その面が字形だけを持たないときは、欠かない** — 知らせが「家族に面が無い」と言い間違えない。
    ///
    /// [#2924]: https://github.com/mokume-metal/mokume/issues/2924
    static func familyLacksFace(of font: CTFont, requested: CTFontSymbolicTraits) -> Bool {
        guard !requested.isEmpty else { return false }
        let face = CTFontCreateCopyWithSymbolicTraits(font, CTFontGetSize(font), nil, requested, requested)
        return face.map { !CTFontGetSymbolicTraits($0).contains(requested) } ?? true
    }

    /// その字を頼んだ面で持つ書体の例 (`textFont()` に渡せる名前) を、環境から引く ([#2924])。**固定の
    /// 表は持たない。** 公開の書体 `Helvetica` の頼んだ面を引く元にして ``CTFontCreateForString`` を引き、
    /// 返った書体が**字形と頼んだ面の両方を持つときだけ**名乗る。持たなければ `nil` (例を挙げない)。
    ///
    /// **引く元を `Helvetica` にする理由:** システムの UI 書体を引く元にすると、返る代わりは内部名
    /// (`.AppleSDGothicNeoI-Bold`・`.ThonburiUI-Bold`。macOS 27 で実測) の書体で、`textFont()` が断る名前なので
    /// 挙げられない (名前から引き直すと別の書体が返る)。`Helvetica` からは、公開の名前
    /// (`AppleSDGothicNeo-Bold`・`Thonburi-Bold`) の書体が返る。例は CoreText がその字に選んだ書体で、
    /// 例の表ではない。
    ///
    /// 描く書体は変えない — 知らせの文面で、作者が `textFont()` へ渡せる名前を挙げるためだけに引く。
    /// `.` で始まる内部名や、環境が名前から引けない名前は挙げない (渡し直せない)。
    ///
    /// [#2924]: https://github.com/mokume-metal/mokume/issues/2924
    static func exampleTypeface(for scalar: Unicode.Scalar, requested: CTFontSymbolicTraits, size: CGFloat)
        -> String?
    {
        guard !requested.isEmpty else { return nil }
        let origin = CTFontCreateWithName("Helvetica" as CFString, size, nil)
        let base = CTFontCreateCopyWithSymbolicTraits(origin, size, nil, requested, requested) ?? origin
        let text = String(scalar) as CFString
        let found = CTFontCreateForString(base, text, CFRangeMake(0, CFStringGetLength(text)))
        let name = CTFontCopyPostScriptName(found) as String
        guard CTFontGetSymbolicTraits(found).contains(requested), glyphIndex(of: scalar, in: found) != 0,
            !name.hasPrefix("."), exists(name: name)
        else { return nil }
        return name
    }

    /// 代わりの書体 (``glyph(for:)`` が、この書体が覆えない字を引いた別の書体) から引いた字が、
    /// 頼んだ太さ・傾きを欠く面で描かれるか ([#2561])。何も頼んでいなければ欠かない。
    ///
    /// **知らせても直す手が無い字は、欠かないと見る。** 知らせは面 (`Canvas`) ごとに 1 度きりなので、
    /// 直す手の無い字が先に鳴ると、後から来る直せる字 (欧文の斜体に混ぜた和文) が知らされなくなる。
    ///
    /// - **色の字形を持つ書体** (Apple Color Emoji。`traitColorGlyphs`) の字。字形は絵で、太さ・
    ///   傾きの面という考えが無く、どの書体を指定しても太字や斜体の絵文字にはならない。見るのは
    ///   書体の印で、``measuresByDrawing(_:path:)`` が絵文字を見分けるのと同じ印である。だから ❤
    ///   (U+2764) のように**単色の書体 (Zapf Dingbats) から引く字は知らせる**
    /// - **墨を持たない字** (``hasInk(_:in:)``)。面が違っても絵が変わらない
    ///
    /// [#2561]: https://github.com/mokume-metal/mokume/issues/2561
    static func lacksStyle(
        fallback font: CTFont, glyph: CGGlyph, requested: CTFontSymbolicTraits
    ) -> Bool {
        let traits = CTFontGetSymbolicTraits(font)
        guard !traits.contains(requested), !traits.contains(.traitColorGlyphs) else { return false }
        return hasInk(glyph, in: font)
    }

    /// その字形が墨を持つか ([#2561])。
    ///
    /// **道筋を持たない字形** (異体字セレクタ U+FE0E・和文の空白 U+3000 など。送り幅 0 のものも
    /// 幅を持つものもある) と、**LastResort から引いた字形** (どの書体も持たない字の代わりに描く
    /// 豆腐。私用領域 U+E000 など) は墨を持たないと見る。色の字形を持つ書体の字形は道筋を
    /// 持たなくても絵を描くので、ここでは問わない (呼ぶ側が先に外す)。
    static func hasInk(_ glyph: CGGlyph, in font: CTFont) -> Bool {
        guard CTFontCopyPostScriptName(font) as String != "LastResort",
            let path = CTFontCreatePathForGlyph(font, glyph, nil)
        else { return false }
        return !path.isEmpty
    }

    /// 書体を作った結果。
    struct MadeFont {
        var font: CTFont
        /// 頼んだ太字・斜体の面が無く、引けた面で描くか。
        var lacksStyle: Bool
        /// 太さを頼んだとき、使った面の太さ (CSS の数)。頼んでいなければ `nil`。
        var usedWeight: Int?
    }

    /// 名前と大きさと太さから書体を作る。太さ・傾きの面が無ければ、引けた面と「無かった」を返す。
    ///
    /// **太さ (``TypefaceRequest/weight``) を頼んだなら、太字の面の代わりにその太さを使う。** 傾きの面は
    /// 先に選び、その面を頼んだ太さへ寄せる (``TypefaceWeight/weighted(_:weight:)``)。
    private static func makeFont(_ request: TypefaceRequest) -> MadeFont {
        let size = CGFloat(request.size)
        if let file = request.file {
            return makeFileFont(file, size: size, request: request)
        }
        let base: CTFont
        if let name = request.name {
            base = CTFontCreateWithName(name as CFString, size, nil)
        } else {
            base =
                CTFontCreateUIFontForLanguage(.system, size, nil)
                ?? CTFontCreateWithName("Helvetica" as CFString, size, nil)
        }

        let traits = traits(of: request.style)
        let (styled, lacksStyle): (CTFont, Bool)
        if traits.isEmpty {
            (styled, lacksStyle) = (base, false)
        } else {
            (styled, lacksStyle) = styledFace(of: base, traits: traits) {
                CTFontCreateCopyWithSymbolicTraits(base, size, nil, $0, $0)
            }
        }
        guard let weight = request.weight else { return MadeFont(font: styled, lacksStyle: lacksStyle, usedWeight: nil) }
        let weighted = TypefaceWeight.weighted(styled, weight: weight)
        return MadeFont(font: weighted.font, lacksStyle: lacksStyle, usedWeight: weighted.used)
    }

    /// ファイルから読んだ書体の面を作る ([#2445])。
    ///
    /// **ファイルの書体は登録しないので、CoreText は兄弟の面を引けない** (`CTFontCreateCopyWithSymbolicTraits`
    /// は、登録された家族の中を探す)。面は、ファイルが持つ面から自分で選ぶ。
    ///
    /// - **可変書体** (面は 1 つ): 軸を既定値へ置いた面が既定の面で、太さは `wght` 軸で動かす。太字は 700。
    ///   斜体の面は持てない (傾きは別のファイル)。
    /// - **それ以外**: 頼んだ太さ (太字は 700・何も頼まなければ 400) に最も近い面を、傾きが合う面から選ぶ
    ///   (``TypefaceWeight/nearest(among:weight:italic:)``)。
    ///
    /// 太字・斜体の面が無ければ引けた面で描き、「無かった」を返す (`textStyle()` の警告になる)。
    ///
    /// [#2445]: https://github.com/mokume-metal/mokume/issues/2445
    private static func makeFileFont(_ file: Font, size: CGFloat, request: TypefaceRequest) -> MadeFont {
        let style = request.style
        let wantsBold = style == .bold || style == .boldItalic
        let wantsItalic = style == .italic || style == .boldItalic
        let target = request.weight ?? (wantsBold ? TypefaceWeight.bold : TypefaceWeight.regular)

        if file.isVariable, let face = file.faces.first {
            let probe = CTFontCreateWithFontDescriptor(face.descriptor, size, nil)
            let axes = TypefaceWeight.axes(of: probe)
            // 全軸を既定値へ置く。ファイルが返す記述子は名前つきのインスタンスの 1 つで、既定とは限らない
            var values = Dictionary(uniqueKeysWithValues: axes.map { ($0.identifier, $0.initial) })
            var used: Int?
            if request.weight != nil || wantsBold,
                let axis = axes.first(where: { $0.identifier == TypefaceWeight.axisIdentifier })
            {
                let value = min(max(Double(target), axis.minimum), axis.maximum)
                values[TypefaceWeight.axisIdentifier] = value
                used = Int(value.rounded())
            }
            let font = TypefaceWeight.copy(of: probe, size: size, axes: values)
            // 軸の無い書体 (幅だけの軸など) は太字にできない。傾きは持てない
            let lacksBold = request.weight == nil && wantsBold && used == nil
            return MadeFont(
                font: font, lacksStyle: lacksBold || (wantsItalic && !face.trait.italic),
                usedWeight: request.weight == nil ? nil : (used ?? Int(face.trait.weight.rounded())))
        }

        let traits = file.faces.map(\.trait)
        guard let index = TypefaceWeight.nearest(among: traits, weight: target, italic: wantsItalic) else {
            // 面が 1 つも無いファイルは読み込みが断っているので、ここへは来ない
            return MadeFont(
                font: CTFontCreateUIFontForLanguage(.system, size, nil)
                    ?? CTFontCreateWithName("Helvetica" as CFString, size, nil),
                lacksStyle: false, usedWeight: nil)
        }
        let chosen = traits[index]
        let font = CTFontCreateWithFontDescriptor(file.faces[index].descriptor, size, nil)
        let lacksBold = request.weight == nil && wantsBold && chosen.weight < 600
        let lacksItalic = wantsItalic && !chosen.italic
        return MadeFont(
            font: font, lacksStyle: lacksBold || lacksItalic,
            usedWeight: request.weight == nil ? nil : Int(chosen.weight.rounded()))
    }

    /// 頼んだ太さ・傾きの面を選ぶ。`copy` は、その性質の面を頼んだときの CoreText の答え。
    /// 面が無ければ、引けた面と「無かった」を返す。**面の引き方を CoreText から切り離してある** —
    /// 順序を、どの機械でも同じ答えを返す合成の材料で検査できる。
    ///
    /// **写しが返っても、頼んだ面とは限らない。** 面が無いとき、nil を返す書体もあれば、元の
    /// 面や片方の性質だけの面を返す書体もある (Kefa III の斜体は `KefaIII-Regular`、太斜体は
    /// `KefaIII-Bold`)。返った面の性質で見る。引けた面 (太字だけの面など) はそのまま使う。
    ///
    /// **頼んだ性質が揃わなくても、引ける性質は捨てない** ([#2562])。太斜体は「太斜体 → 太字だけ →
    /// 斜体だけ → 元の面」の順に頼み、最初に引けた面を使う。ヒラギノ角ゴシック・游明朝体のように
    /// 太斜体で nil (や太字でない面) を返す書体でも、太字だけで頼めば太字の面が引ける。**太字と
    /// 斜体の両方を持つが太斜体だけ無い書体は太字を取る** — 太さは文字の読みに効き、消えにくい
    /// 強調だから。斜体だけを持つ書体は斜体で描く。
    ///
    /// [#2562]: https://github.com/mokume-metal/mokume/issues/2562
    static func styledFace(
        of base: CTFont, traits: CTFontSymbolicTraits, copy: (CTFontSymbolicTraits) -> CTFont?
    ) -> (font: CTFont, lacksStyle: Bool) {
        let styled = copy(traits)
        if let styled, CTFontGetSymbolicTraits(styled).contains(traits) { return (styled, false) }
        if traits == [.traitBold, .traitItalic] {
            for partial: CTFontSymbolicTraits in [.traitBold, .traitItalic] {
                if let face = copy(partial), CTFontGetSymbolicTraits(face).contains(partial) {
                    return (face, true)
                }
            }
        }
        return (styled ?? base, true)
    }

    /// 書体の名前を、CoreText に渡す綴りへ直す。**濁点を分けた綴り (NFD) を合わせた綴り (NFC) に
    /// する** ([#2444]) — CoreText の名前の索引は合わせた綴りで、`ヒ` + 濁点のように分けて
    /// 綴った名前 (ファイル名やコピーした文字列で起きる) は引けない。
    ///
    /// [#2444]: https://github.com/mokume-metal/mokume/issues/2444
    static func canonicalName(_ name: String) -> String {
        name.precomposedStringWithCanonicalMapping
    }

    /// その名前の書体がこの環境にあるか。
    ///
    /// **無い名前を渡しても書体は返ってくる** — この環境は黙って別の書体へ倒すので、
    /// 返ってきた書体の名前と突き合わせないと「指定が効かなかった」ことに気付けない。
    ///
    /// **フルネームと各言語の名前は、CoreText に名前で探させて確かめる** ([#2444])。
    /// `ヒラギノ角ゴシック W3`・`Helvetica Neue Bold` は、返った書体のファミリー名とも
    /// PostScript 名とも一致しない。返った書体の地域化した名前と比べると、比べられるのは
    /// いまの表示言語の名前 1 つだけで、表示言語によって在る名前を断ってしまう。名前を必須に
    /// して探させれば、無い名前では何も見つからず、CoreText の名前の索引に載った名前は表示言語に
    /// 依らず見つかる。**索引に載らない名前** (後から入れた書体の表示名など) は、ここでは引けない —
    /// ``resolvedName(of:)`` が各言語の名前の表 (``TypefaceNameIndex``) で引き直す ([#2563])。
    ///
    /// **`.` で始まる名前は探させない。** システムの内部名 (`.SFNS-Regular` など) は、CoreText が
    /// 別の書体へ差し替えたうえで「見つかった」と答えるので、名前の一致だけで決める。
    ///
    /// [#2444]: https://github.com/mokume-metal/mokume/issues/2444
    /// [#2563]: https://github.com/mokume-metal/mokume/issues/2563
    static func exists(name: String) -> Bool {
        let font = CTFontCreateWithName(name as CFString, 12, nil)
        let family = CTFontCopyFamilyName(font) as String
        let postScript = (CTFontCopyPostScriptName(font) as String?) ?? ""
        if family.compare(name, options: .caseInsensitive) == .orderedSame
            || postScript.compare(name, options: .caseInsensitive) == .orderedSame
        {
            return true
        }
        guard !name.hasPrefix(".") else { return false }
        let wanted = CTFontDescriptorCreateWithNameAndSize(name as CFString, 12)
        let mandatory: Set<String> = [kCTFontNameAttribute as String]
        guard
            let found = CTFontDescriptorCreateMatchingFontDescriptor(wanted, mandatory as CFSet),
            let foundName = CTFontDescriptorCopyAttribute(found, kCTFontNameAttribute) as? String
        else { return false }
        // 見つかった書体が、名前で引いた書体そのものであること
        return foundName == postScript
    }

    /// 名前を、``CTFontCreateWithName`` が同じ書体へ引ける綴りに解く。この環境に無い名前は `nil`。
    ///
    /// CoreText の名前の索引が引ける名前 (``exists(name:)``) は、そのまま返す。**索引に載らない名前**
    /// (日本語表示の `ヒラギノ角ゴ 簡体中文 W3`・`黒体-簡 ミディアム`、後から入れた書体の表示名など) は、
    /// 書体メニューに出る各言語の名前の表 (``TypefaceNameIndex``) で面を探し、その PostScript 名を
    /// 返す ([#2563])。表は初回に 1 度だけ作る。名前が複数の面に当たるときは、表が CoreText の選ぶ
    /// 面に揃える。表が返した名前も CoreText で同じ面に引き直せることを確かめ、引けなければ断る。
    ///
    /// **`.` で始まる名前は表でも引かない** (``exists(name:)`` と同じく、内部名は別の書体へ差し替わる)。
    ///
    /// [#2563]: https://github.com/mokume-metal/mokume/issues/2563
    static func resolvedName(of name: String) -> String? {
        if exists(name: name) { return name }
        guard !name.hasPrefix("."),
            let postScript = TypefaceNameIndex.system.postScriptName(for: name),
            exists(name: postScript)
        else { return nil }
        return postScript
    }

    /// 1 文字ぶんを引き当てる。字形が無ければ `nil`。
    ///
    /// **この書体が覆えない字は、環境が持つ別の書体から引き、その書体が持つ面で描く** — 欧文の斜体に
    /// 混ぜた日本語は、斜体の面を持たない書体の立体で引かれる。引いた書体が頼んだ太さ・傾きの面を
    /// 持つなら、その面で引き直す (``restyledFallback(_:glyph:requested:copy:glyphIndex:)``。[#2770])。
    /// 引き直しても面が頼んだ太さ・傾きを欠けば
    /// (``lacksStyle(fallback:glyph:requested:)``)、知らせの口 (``onFallbackLackingStyle``) を呼ぶ ([#2561])。
    /// 呼ぶのは引き当てを控えに入れる時だけなので、同じ字では 1 度きりである。描画 (`text()`)・
    /// 幅 (``advance(of:)``)・輪郭と墨の枠はどれもここを通るので、どの口から先に引いても同じ 1 度になる。
    ///
    /// [#2561]: https://github.com/mokume-metal/mokume/issues/2561
    func glyph(for scalar: Unicode.Scalar) -> ResolvedGlyph? {
        if let cached = resolved[scalar] { return cached }

        var font = base
        var glyph = Self.glyphIndex(of: scalar, in: font)
        let fellBack = glyph == 0
        // 代わりの書体の面が頼んだ性質を欠くか。判定は ``restyledFallback`` が 1 度だけ行い、控える時に使う
        var fallbackLacksStyle = false
        if fellBack {
            // この書体が覆えない文字。環境が持つ別の書体から引く
            let text = String(scalar) as CFString
            font = CTFontCreateForString(base, text, CFRangeMake(0, CFStringGetLength(text)))
            glyph = Self.glyphIndex(of: scalar, in: font)
            if glyph != 0 {
                // CoreText は、太字を持てなかった (劣化した) base に合わせて代わりを選ぶ。引いた書体が
                // 頼んだ面を持つなら、その面で引き直す ([#2770])
                let picked = font
                (font, glyph, fallbackLacksStyle) = Self.restyledFallback(
                    picked, glyph: glyph, requested: Self.traits(of: request.style),
                    copy: { CTFontCreateCopyWithSymbolicTraits(picked, CTFontGetSize(picked), nil, $0, $0) },
                    glyphIndex: { Self.glyphIndex(of: scalar, in: $0) })
            }
        }
        guard glyph != 0 else { return nil }

        var index = glyph
        var advance = CGSize.zero
        CTFontGetAdvancesForGlyphs(font, .horizontal, &index, &advance, 1)

        // ファイルから読んだ書体の字は、同じ PostScript 名のインストール済みの書体と焼き場で混ざらない
        // よう、ファイルの同一性を鍵に含める。代わりの書体 (``fellBack``) はこの環境の書体で、名前だけ ([#2445])
        var fontKey = (CTFontCopyPostScriptName(font) as String?) ?? ""
        if !fellBack, let file = request.file { fontKey += "#" + file.identity }
        let entry = ResolvedGlyph(
            font: font, glyph: glyph, advance: Float(advance.width), fontKey: fontKey)
        resolved[scalar] = entry
        if fallbackLacksStyle { onFallbackLackingStyle(self, scalar, font) }
        return entry
    }

    /// 代わりの書体から引いた字の面が頼んだ太さ・傾きを欠くとき、**その書体から頼んだ面を引き直す**
    /// ([#2770])。引き直した面が字形を持てばその面と字形の番号を、持たなければ写す前の面を返す。
    /// 欠いていなければ (``lacksStyle(fallback:glyph:requested:)``) 何もしない。
    ///
    /// **CoreText は、代わりの書体を、頼んだ面ではなく ``base`` から選ぶ。** 指定した書体が太字を
    /// 持たなければ ``base`` は太字でない面へ倒れており (``makeFont(_:)``)、代わりの書体もその細さに
    /// 合わせて選ばれる — Apple Chancery の `.bold` に混ぜた「あ」は、ヒラギノ明朝に太字 (W6) が
    /// あるのに W3 で描かれる。指定した書体の面を選ぶ [#2562] の考え (``styledFace(of:traits:copy:)``)
    /// を、代わりの書体にも同じ順で当てる。**合成はしない** — 引ける面が無ければ写す前の面のまま。
    ///
    /// **引き直した面は、同じ家族の公開の面とは限らない。** 面は `copy` が返した書体で、CoreText が
    /// 内部の面を返すこともある (Times New Roman の太字は、家族名 `.Times Fallback` の `.TimesFB-Bold`)。
    /// **家族をまたいで探し直すことはしない** — 代わりの書体が太字を持たない家族 (ハングルの
    /// AppleMyungjo・タイ文字の Ayuthaya など) は、引き直しても細いまま残る。理由は 2 つある。
    /// CoreText の候補の列 (`CTFontCopyDefaultCascadeList`) に、その字を太字で持つ別の家族が入っていない
    /// (Apple Chancery・Zapfino の「한」は列の中で AppleMyungjo だけが字形を持つ)。列の外から代役を
    /// 決めると、指定した書体から離れる ([#2924])。細いままの字は、知らせ (``onFallbackLackingStyle``) が
    /// 「代わりの書体の家族に面が無い」ことと、その字を頼んだ面で持つ書体の例を名乗る。
    ///
    /// 引き直した面は、頼んだ性質を**写す前の面より多く**持つときだけ採る。別の面へ入れ替わるだけで
    /// 何も頼みに近づかない引き直し (斜体の面が無くて太さの違う面が返る、など) は採らない。
    /// 面の引き方 (`copy`) と字形の引き方 (`glyphIndex`) を CoreText から切り離してあるので、
    /// 字形が無いときの振る舞いを、どの機械でも同じ答えを返す材料で検査できる。
    ///
    /// 返す `lacksStyle` は、**返した面**が頼んだ性質を欠くか。呼ぶ側が知らせるかの判断に使う。
    /// 判定 (墨を見るので道筋を作る) は、欠かない面なら 1 度、引き直さなければ 1 度、
    /// 引き直したときだけ新しい面に 1 度かかる。
    ///
    /// [#2770]: https://github.com/mokume-metal/mokume/issues/2770
    /// [#2562]: https://github.com/mokume-metal/mokume/issues/2562
    /// [#2924]: https://github.com/mokume-metal/mokume/issues/2924
    static func restyledFallback(
        _ font: CTFont, glyph: CGGlyph, requested: CTFontSymbolicTraits,
        copy: (CTFontSymbolicTraits) -> CTFont?, glyphIndex: (CTFont) -> CGGlyph
    ) -> (font: CTFont, glyph: CGGlyph, lacksStyle: Bool) {
        guard lacksStyle(fallback: font, glyph: glyph, requested: requested) else {
            return (font, glyph, false)
        }
        let face = styledFace(of: font, traits: requested, copy: copy).font
        let gained = CTFontGetSymbolicTraits(face).intersection(requested)
        let had = CTFontGetSymbolicTraits(font).intersection(requested)
        guard gained.rawValue & ~had.rawValue != 0 else { return (font, glyph, true) }
        let faceGlyph = glyphIndex(face)
        guard faceGlyph != 0 else { return (font, glyph, true) }
        return (face, faceGlyph, lacksStyle(fallback: face, glyph: faceGlyph, requested: requested))
    }

    /// 描いて測った墨の範囲の控え。`nil` を控えるのは、描いた結果「墨が無い」と分かった字
    /// (空白など)。**描く道具を作れずに描けなかった字は控えず、次に引き直す** (焼き場が
    /// `.unbakeable` を控えないのと同じ)。
    private var drawnInks: [Unicode.Scalar: CGRect?] = [:]
    /// 組版した字形の墨の控え (``ink(of:keeping:as:)``)。
    var shapedInks: [ShapedInkKey: CGRect?] = [:]
    /// 組版した 1 行の控え (``shape(_:)``)。
    var shaped: [String: ShapedLine] = [:]

    /// その字形を、**道筋ではなく描いて測るか** ([#2308])。
    ///
    /// 焼き場は道筋を見ず、どの字形も `CTFontDrawGlyphs` で描く。道筋が描いた墨を表すのは、
    /// 書体が字形を道筋で描くときだけである。**色やビットマップの字形を持つ書体**
    /// (Apple Color Emoji。`traitColorGlyphs`) の字形は、道筋が無いか、あっても描く絵と別の
    /// 仮の形 (国旗の部品 🇯 は 40 で中身の無い矩形を道筋に持ち、描く絵はその右と下へ数画素
    /// はみ出す) なので、描いて測る。道筋を持たない字 (空白・ビットマップだけの字形) も同じ。
    ///
    /// 字形ごとに描いて確かめず書体の印で決めるのは、色の字形を持たない書体の字を 1 つも
    /// 描かずに済ませるためである (描くのは色の書体の字と、道筋の無い字だけ)。字形の絵が
    /// 色を持つか (焼き場の `hasOwnColor`) では決めない — 🇯 は塗りの色で描かれる (色を持たない)
    /// が、描く絵は道筋と違う。
    ///
    /// [#2308]: https://github.com/mokume-metal/mokume/issues/2308
    static func measuresByDrawing(_ resolved: ResolvedGlyph, path: CGPath?) -> Bool {
        path == nil || CTFontGetSymbolicTraits(resolved.font).contains(.traitColorGlyphs)
    }

    /// 字形を**焼き場と同じ描き方** (``GlyphAtlas/render(glyph:font:width:height:penX:penY:)``)
    /// で描いた墨の範囲を、字形の座標 (書き始めと基準線から測り、上向き) で返す。墨が無ければ
    /// `nil` ([#2308])。
    ///
    /// 外接矩形 (`CTFontGetBoundingRectsForGlyphs`) は色を持つ字形では送り幅の升目そのもので、
    /// 見える墨より左右に広い (Apple Color Emoji の 🌲 は 40 で各 3 画素)。だから描いて測る。
    /// 書き始めは整数の升目に置くので、焼き場が焼く絵と同じ升目に乗る。字ごとに控えるので、
    /// 描くのは字の種類ごとに 1 度だけである。
    ///
    /// 外接矩形の面積が無い字 (空白) は描かずに墨なし (焼き場も焼かない)。焼き場の上限の頁に
    /// 入らない大きさの字は、描かずに外接矩形を墨とする — 墨を含む、送り幅の升目ぶん広い枠に
    /// なる。描く道具を作れなかったときも `nil` を返すが、控えないので次に呼べば描き直す。
    ///
    /// **描いた画素は焼き場に預ける** (`atlas`・`key`・[#2560])。控え (`drawnInks`) は書体ごと、書体は
    /// 大きさごとなので、`textSize()` を毎フレーム動かすと控えは外れ、測るたびに描き直す。その大きさの
    /// 字を `text()` が焼くときは、同じ升目に同じ描き方で描くので、預けた画素をそのまま使えば CPU で
    /// 描くのは 1 回で済む (``GlyphAtlas/keepRendered(_:for:)``)。
    ///
    /// [#2308]: https://github.com/mokume-metal/mokume/issues/2308
    /// [#2560]: https://github.com/mokume-metal/mokume/issues/2560
    func drawnInk(
        of scalar: Unicode.Scalar, _ resolved: ResolvedGlyph, keeping atlas: GlyphAtlas,
        as key: GlyphAtlas.Key
    ) -> CGRect? {
        if let cached = drawnInks[scalar] { return cached }
        switch Self.draw(resolved, on: atlas) {
        case .ink(let ink, let rendered):
            drawnInks[scalar] = ink
            if let rendered { atlas.keepRendered(rendered, for: key) }
            return ink
        case .failed:
            return nil
        }
    }

    /// 描いて測った結果。描けなかったこと (`failed`) と、描いて墨が無かったこと (`ink(nil)`) を分ける。
    /// 描いたときは、その画素も一緒に返す (焼き場へ預ける)。
    enum Drawing {
        case ink(CGRect?, GlyphAtlas.Rendered?)
        case failed
    }

    static func draw(_ resolved: ResolvedGlyph, on atlas: GlyphAtlas) -> Drawing {
        var glyph = resolved.glyph
        let bounds = CTFontGetBoundingRectsForGlyphs(resolved.font, .horizontal, &glyph, nil, 1)
        guard bounds.width > 0, bounds.height > 0, bounds.width.isFinite, bounds.height.isFinite
        else { return .ink(nil, nil) }
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
        else { return .ink(bounds, nil) }
        guard
            let pixels = atlas.renderOnCPU(
                glyph: glyph, font: resolved.font, width: right - left, height: top - bottom,
                penX: -left, penY: -bottom)
        else { return .failed }

        let width = right - left
        var (minColumn, maxColumn, minRow, maxRow) = (Int.max, Int.min, Int.max, Int.min)
        for (index, texel) in pixels.enumerated() where texel.w > 0 {
            let (row, column) = index.quotientAndRemainder(dividingBy: width)
            minColumn = min(minColumn, column)
            maxColumn = max(maxColumn, column)
            minRow = min(minRow, row)
            maxRow = max(maxRow, row)
        }
        let rendered = GlyphAtlas.Rendered(
            width: width, height: top - bottom, penX: -left, penY: -bottom, pixels: pixels)
        guard minColumn <= maxColumn else { return .ink(nil, rendered) }
        // 並びの先頭は絵の上端。行 r は、字形の座標で top - r - 1 から top - r までを覆う
        return .ink(
            CGRect(
                x: left + minColumn, y: top - maxRow - 1, width: maxColumn - minColumn + 1,
                height: maxRow - minRow + 1),
            rendered)
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
