// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT
//
// 字形と画像を四角として積む下ごしらえ。`Canvas.swift` の MARK「文字の下ごしらえ」を、
// 区画ごとここへ移した ([#943](https://github.com/mokume-metal/mokume/issues/943))。
//
// **説明文は置かない。** 正本は上の層 (ADR-0020 決定 4) で、api-surface.py の
// slash_doc は宣言の直前に積んだ `//` も説明文として拾う。この覚え書きが
// 拾われないよう、宣言との間は必ず 1 行空ける。

import CoreText
import simd

extension Canvas {

    /// 4 つの数を、いまの読み方で矩形として読む。
    ///
    /// 文字の流し込みもここを通す — 矩形と別の読み方を持つと、同じ 4 つの数が
    /// API ごとに違う場所を指すことになる。
    func resolveRect(_ a: Float, _ b: Float, _ c: Float, _ d: Float)
        -> (x: Float, y: Float, width: Float, height: Float)
    {
        Self.resolveBox(a, b, c, d, mode: style.rectMode)
    }

    /// 文字を塗る色。塗りを止めていれば `nil`。
    var textFillColor: LinearRGBA? { style.hasFill ? fillVertexColor : nil }

    /// いま指定されている書体。同じ指定なら作り直さない。
    var typeface: Typeface {
        let request = TypefaceRequest(
            name: style.fontName, file: style.fontFile, size: style.textSize,
            style: style.textStyle, weight: style.textWeight)
        if let found = typefaces[request] { return found }
        // 代わりの書体から引いた字の面も同じく知らせる (#2561)。書体は面の控えに入るので、面を
        // 強く掴むと巡って離れない
        let face = Typeface(request: request) { [weak self] face, scalar, fallback in
            self?.warnFallbackLackingStyleOnce(face, scalar, fallback)
        }
        typefaces.insert(face, for: request)
        // `textFont()` が確かめた名前でも、書体を作る時にはもう引けないことがある (実行中に書体を外した)。
        // CoreText は別の書体を黙って返すので、ここでも確かめる。確かめるのは作る時だけ ([#2772])
        if let name = request.name, !Typeface.exists(name: name) {
            warnOnce(.unavailableFont, Self.unavailableFontMessage(name: name, used: face.base))
        }
        // 近い太さの面が無ければ、使った面を名乗る (#2445)。頼んだ太さに応えられない指定を、効いたように見せない
        if face.lacksRequestedWeight, let wanted = request.weight, let used = face.usedWeight {
            warnOnce(
                .missingTypefaceWeight,
                "textWeight(): the typeface family \"\(CTFontCopyFamilyName(face.base) as String)\" "
                    + "has no face near \(wanted), so \"\(CTFontCopyPostScriptName(face.base) as String)\" "
                    + "(weight \(used)) is used. A variable typeface can draw any weight from 100 to 900; "
                    + "others use the nearest of the weights they have")
        }
        // 面が無ければ引けた面で描く。黙ると、効かない指定を効いたように見せる (#2444)
        if face.lacksRequestedStyle {
            // どの面で描くかを添える。太斜体で斜体だけが無いなら「太字の立体」と読める (#2562)
            warnOnce(
                .missingTypefaceStyle,
                "textStyle(): the typeface family \"\(CTFontCopyFamilyName(face.base) as String)\" "
                    + "has no \(request.style) face in this environment, so "
                    + "\"\(CTFontCopyPostScriptName(face.base) as String)\" (\(Self.faceTraits(of: face.base))) "
                    + "is used")
        }
        return face
    }

    /// 書体を作る時に名前が引けなかったことの文面 ([#2772])。**代わりに描く書体は、`.` で始まる内部名を
    /// 名乗らない** (``passableName(_:)``)。``textFont(_:)`` が受け付けない名前で、名乗っても渡し直せない。
    ///
    /// [#2772]: https://github.com/mokume-metal/mokume/issues/2772
    static func unavailableFontMessage(name: String, used: CTFont) -> String {
        let source = passableName(used).map { "\"\($0)\"" } ?? "a system typeface"
        return "textFont(): the typeface \"\(name)\" could not be found when it was loaded, so "
            + "\(source) is used instead. "
            + "The typeface may have been removed from this environment while the sketch was running"
    }

    /// 書体の面の太さと傾きを、警告の文面の言い方 (`bold, upright` など) で言う。
    private static func faceTraits(of font: CTFont) -> String {
        let traits = CTFontGetSymbolicTraits(font)
        return "\(traits.contains(.traitBold) ? "bold" : "regular weight"), "
            + (traits.contains(.traitItalic) ? "italic" : "upright")
    }

    /// 指定した書体が覆えず別の書体から引いた字が、頼んだ太さ・傾きの面で描けないことを、初回だけ
    /// 知らせる ([#2561])。**字・字を持たなかった面・字を引いた書体・描いた面を名乗る** — 指定した
    /// 書体の面は揃っているので、どの字がどこから来たかを言わないと、効かない理由に辿り着けない。
    /// 絵は変えない (傾けて合成しない)。
    ///
    /// - **字を持たないと言うのは面である。** 判定は頼んだ面 (`face.base`) が字形を持つかで、家族の
    ///   別の面が持つ字もここに来る (Euphemia UCAS の斜体に無く、立体にある U+1400)
    /// - **字にはコードポイントを添える。** 結合する字や見えない字 (U+3099・U+20E3) は字だけでは読めない
    /// - **`.` で始まる内部名は名乗らない** (``passableName(_:)``)。``textFont(_:)`` が受け付けない
    ///   名前で、結びの「`textFont()` に渡せ」と食い違う
    ///
    /// [#2561]: https://github.com/mokume-metal/mokume/issues/2561
    private func warnFallbackLackingStyleOnce(
        _ face: Typeface, _ scalar: Unicode.Scalar, _ fallback: CTFont
    ) {
        let style = ".\(face.request.style)"
        let missing =
            Self.passableName(face.base).map { "\"\($0)\", the face drawn for \(style)," }
            ?? "the system typeface's face for \(style)"
        let source =
            Self.passableName(fallback).map { "\"\($0)\"" } ?? "a system typeface"
        warnOnce(
            .missingFallbackTypefaceStyle,
            "textStyle(): \(missing) has no \(Self.quoted(scalar)), so it is drawn from \(source) "
                + "(\(Self.faceTraits(of: fallback))) without the \(style) style. "
                + Self.fallbackFamilyNotice(face, fallback)
                + "This is said once for all such characters; to draw them in \(style), set textFont() to a "
                + "typeface that has these characters in a face for \(style)"
                + Self.exampleNotice(face, scalar, fallback))
    }

    /// 代わりに使った書体の**家族に頼んだ面が無い**ことを言う文 ([#2924])。mokume が引かなかったのではなく、
    /// 候補の書体が持たないと読める言い方にする。家族が面を持つのに字形だけが無いときは、何も言わない。
    ///
    /// [#2924]: https://github.com/mokume-metal/mokume/issues/2924
    private static func fallbackFamilyNotice(_ face: Typeface, _ fallback: CTFont) -> String {
        guard Typeface.familyLacksFace(of: fallback, requested: Typeface.traits(of: face.request.style)) else {
            return ""
        }
        let subject = passableName(fallback).map { "\"\($0)\"" } ?? "that typeface"
        return "The family of \(subject) has no .\(face.request.style) face, so none could be used. "
    }

    /// その字を頼んだ面で持つ書体の例 ([#2924])。環境から引き、字形と頼んだ面の両方を持つ名前が
    /// 見つかったときだけ、`, for example "<名前>"` を返す。
    ///
    /// [#2924]: https://github.com/mokume-metal/mokume/issues/2924
    private static func exampleNotice(
        _ face: Typeface, _ scalar: Unicode.Scalar, _ fallback: CTFont
    ) -> String {
        guard
            let name = Typeface.exampleTypeface(
                for: scalar, requested: Typeface.traits(of: face.request.style),
                size: CTFontGetSize(fallback))
        else { return "" }
        return ", for example \"\(name)\""
    }

    /// ``textFont(_:)`` に渡せる書体の名前 (PostScript 名)。**`.` で始まる内部名 (`.HiraKakuInterface-W4`) は
    /// `nil`** — ``textFont(_:)`` が断る名前なので、名乗っても渡し直せない。
    private static func passableName(_ font: CTFont) -> String? {
        let name = CTFontCopyPostScriptName(font) as String
        return name.hasPrefix(".") ? nil : name
    }

    /// 字を、引用符とコードポイントで言う (`"も" (U+3082)`)。
    private static func quoted(_ scalar: Unicode.Scalar) -> String {
        let hex = String(scalar.value, radix: 16, uppercase: true)
        return "\"\(Character(scalar))\" (U+\(String(repeating: "0", count: max(0, 4 - hex.count)) + hex))"
    }

    /// 焼き分けの鍵。**焼くときと、測る側が描いた画素を焼き場に預けるとき (#2560) で同じ鍵を使う。**
    ///
    /// `step` は変換の拡大から決めた焼く段 (``glyphStep``)。0 は `textSize` の大きさそのままで、測る側は
    /// 変換を見ないので常に 0 の鍵を使う。
    func glyphKey(for resolved: ResolvedGlyph, step: Int = 0) -> GlyphAtlas.Key {
        GlyphAtlas.Key(
            fontKey: resolved.fontKey, size: style.textSize, style: style.textStyle,
            glyph: resolved.glyph, weight: style.textWeight ?? 0, step: step)
    }

    /// 字を焼く拡大の段 ([#2446])。**いまの変換が字を、描く画素で拡げる量**を、対数の最も近い段に丸めたもの。
    ///
    /// 拡大は、変換の左上 2×2 に**出す画素から描く画素への比** (``unitsPerDrawnPixel``・細かさ) を掛けた
    /// 行列の最大の特異値で (``splitScale(of:)``・倍精度・桁あふれに強い)、回転だけなら 1、軸ごとに
    /// 違う倍率なら大きいほう。細かさを下げた面では、描く画素が粗いぶん拡大が小さく数えられる
    /// (細かさ 0.5 の `scale(2)` は 1 対 1 で、段 0)。平面の層は奥行きを捨てる (ADR-0021 決定 2) ので、
    /// 変換の 3 列目 (z) は見ない — `rotateY` などで傾けた字の遠近も、傾きで縮んだ分も数えない。
    /// 拡大が 1 以下 (段 0) は、`textSize` の大きさで焼いたまま描く。段は ``glyphStepLimit`` で頭打ちにする。
    ///
    /// [#2446]: https://github.com/mokume-metal/mokume/issues/2446
    var glyphStep: Int {
        let drawn = drawnLinear(transform.matrix)
        let flat = simd_float4x4(
            columns: (
                SIMD4(drawn.columns.0.x, drawn.columns.0.y, 0, 0),
                SIMD4(drawn.columns.1.x, drawn.columns.1.y, 0, 0),
                SIMD4(0, 0, 1, 0), SIMD4(0, 0, 0, 1)))
        let stretch = Self.splitScale(of: flat)
        guard stretch > 1 else { return 0 }
        let step = Int((RuntimeMath.log2(stretch) * Float(GlyphAtlas.stepsPerOctave)).rounded())
        return min(step, glyphStepLimit)
    }

    /// 頼んでよい最大の段。**1 字の em を 2048 画素までに留める** — 段の倍率が桁あふれしないための
    /// 目安である。実際の頭打ちは 1 字の画素のバイト数で、字形ごとに決まる (``GlyphAtlas/plan(for:font:)``)。
    private var glyphStepLimit: Int {
        let size = style.textSize
        guard size > 0, size < Self.largestBakedEm else { return 0 }
        return Int((RuntimeMath.log2(Self.largestBakedEm / size) * Float(GlyphAtlas.stepsPerOctave)).rounded(.down))
    }

    private static let largestBakedEm: Float = 2048

    /// 引いた字形と、**頼んだ段について決まった答えか** (`settled`)。決まっていれば、書体の控え
    /// (``Typeface/placedScaled``) へ入れて、次のフレームから引き直さない。上限を越えて先送りした字や、
    /// 頁が溢れて低い段で描いた字は決まっていない (次のフレームで頼んだ段を焼き直す)。
    ///
    /// `deferredKey` は、**上限を越えて先送りした**ときだけ、焼くはずだった段の鍵。置いた四角をフレームの
    /// 終わりに払うために控える (``noteDeferredGlyph(_:key:font:penX:baseline:color:)``)。
    struct GlyphLookup {
        var entry: GlyphAtlas.Entry
        var settled: Bool
        var deferredKey: GlyphAtlas.Key?
    }

    /// 焼いてある字形を引く。**場所が足りないときだけ**面を広げる — 上限の面なら、同じ
    /// 大きさの新しい頁へ焼き直す ([#1342])。
    ///
    /// **面を替えると、そこを読む列が変わる。** 既に置いた字は前の面を指しているので、
    /// 替える前に列を閉じ、前の面はその列が頁ごと抱えたまま残す (``GlyphPage``)。
    ///
    /// **広げても入らないものは広げない** ([#738])。広げるたびに焼いた字形は全部
    /// 捨てられるので、入らない 1 字のために他の全部を焼き直させることになる。
    /// どちらなのかは面が名乗る (``GlyphAtlas/Lookup``)。**焼き直しても入らないものも同じ**で、
    /// 作りたての上限の頁にも入らない字は、面が「満杯」ではなく「大きすぎる」を名乗る ([#1492])。
    ///
    /// **入るまで広げる** ([#1460])。面は 1 段ずつ倍になるので、1 度広げた面にも入らない
    /// 大きさの字がある (256 の面に 800 の「M」)。1 度で諦めると、その字はこのフレームで
    /// 欠け、次のフレームでもう一段広がってから出る — 1 フレームだけ描いて書き出す使い方では、
    /// 欠けたまま残る。
    ///
    /// **焼き直すのは 1 フレームに 1 度まで** (``atlasPageFrame``)。このフレームで作った
    /// 上限の頁まで埋まったなら、このフレームで要る字は焼き直しても収まらない。そのときだけ
    /// 知らせて、入らない字を諦める。次のフレームでは、また焼き直せる。
    ///
    /// **繰り返しは必ず止まる。** 広げる段は上限までの有限で、上限の頁を作れるのは 1 フレームに
    /// 1 度だけだからである。1 度の呼び出しで頁を替えるのは、多くて 4 度 (256 → 4096) になる。
    ///
    /// [#738]: https://github.com/mokume-metal/mokume/issues/738
    /// [#1342]: https://github.com/mokume-metal/mokume/issues/1342
    /// [#1460]: https://github.com/mokume-metal/mokume/issues/1460
    /// [#1492]: https://github.com/mokume-metal/mokume/issues/1492
    func glyphLookup(for resolved: ResolvedGlyph, step: Int) -> GlyphLookup? {
        guard step > 0 else {
            return bakedGlyph(for: glyphKey(for: resolved), font: resolved.font)
                .map { GlyphLookup(entry: $0, settled: true) }
        }
        return scaledGlyphLookup(for: resolved, step: step)
    }

    /// 段 0 の字形を引く (``glyphLookup(for:step:)`` の段 0)。検査が使う。
    func glyphEntry(for resolved: ResolvedGlyph) -> GlyphAtlas.Entry? {
        glyphLookup(for: resolved, step: 0)?.entry
    }

    /// 拡大した段 (`step` が 0 より上) の字形を引く ([#2446])。**どの場合も字は欠かさず、頼んだ段より低い
    /// 段の画素で描くことはあっても、段 0 (以前の焼き方) を下回らない。**
    ///
    /// 1. 焼いてあればそれを返す
    /// 2. **1 字の大きさ**で頭打ちにする: 画素のバイト数が上限 (``GlyphAtlas/scaledBakeByteLimit``) を越える
    ///    段は焼かず、収まる段まで下げる。この下げは字形ごとに決まるので、答えは決まったものとして控える。
    ///    下げたことは、初回だけ知らせる (``Canvas/Warning/softEnlargedText``)
    /// 3. **1 フレームの量**で頭打ちにする (``GlyphAtlas/admitScaledBake(_:bytes:frame:)``): 数・バイト数が
    ///    枠を越えていれば、焼いてある近い段で描き、近い段が無ければ段 0 で焼いて描く。どちらも控えて、
    ///    次のフレームで先に焼く。次のフレームが来ない面は枠を外し、要る段で焼き切る
    ///    (``GlyphAtlas/mayDeferScaledBakes``)
    /// 4. 焼く。**焼き場に入らなければ (頁が溢れた・拡大した字形が面の割合を使い切った) 1 オクターブずつ**
    ///    低い段へ下がり、最後は段 0
    ///
    /// [#2446]: https://github.com/mokume-metal/mokume/issues/2446
    private func scaledGlyphLookup(for resolved: ResolvedGlyph, step: Int) -> GlyphLookup? {
        let wanted = glyphKey(for: resolved, step: step)
        if let found = atlas.cachedEntry(for: wanted) {
            atlas.noteBaked(wanted, frame: framesDrawn)
            return GlyphLookup(entry: found, settled: true)
        }

        let plan = atlas.plan(for: wanted, font: resolved.font)
        if plan.step < step { warnSoftEnlargedTextOnce() }
        let target = glyphKey(for: resolved, step: plan.step)
        if plan.step == 0 {
            atlas.noteBaked(wanted, frame: framesDrawn)
            return bakedGlyph(for: target, font: resolved.font).map { GlyphLookup(entry: $0, settled: true) }
        }
        if let found = atlas.cachedEntry(for: target) {
            atlas.noteBaked(target, frame: framesDrawn)
            return GlyphLookup(entry: found, settled: true)
        }

        // 空白は焼く画素が無いので、数えない。**形の記録の中は先送りしない** — 記録した四角は形に
        // 焼き付いて残るので、近い段のままでは次のフレームで直せない
        let deferrable = !recordingShape
        if plan.bytes > 0,
            !atlas.admitScaledBake(target, bytes: plan.bytes, frame: framesDrawn, deferrable: deferrable)
        {
            if let near = nearestBakedGlyph(for: resolved, step: plan.step) {
                return GlyphLookup(entry: near, settled: false, deferredKey: target)
            }
            return bakedGlyph(for: glyphKey(for: resolved), font: resolved.font)
                .map { GlyphLookup(entry: $0, settled: false, deferredKey: target) }
        }

        var current = plan.step
        while current > 0 {
            let key = glyphKey(for: resolved, step: current)
            if let cached = atlas.cachedEntry(for: key) {
                return GlyphLookup(entry: cached, settled: current == plan.step)
            }
            if let entry = bakedGlyph(for: key, font: resolved.font, reportsFull: false) {
                return GlyphLookup(entry: entry, settled: current == plan.step)
            }
            if current == plan.step { warnSoftEnlargedTextOnce() }
            current = max(0, current - GlyphAtlas.stepsPerOctave)
        }
        return bakedGlyph(for: glyphKey(for: resolved), font: resolved.font)
            .map { GlyphLookup(entry: $0, settled: false) }
    }

    /// 先送りして近い段の画素で置いた四角 ([#2446])。**置いた頂点の位置と、焼くはずだった段の鍵・置いた
    /// ときの変換を控える。** フレームの終わりにその絵が残ると分かったとき、焼いて頂点を置き直す
    /// (``settleDeferredGlyphs(baking:)``)。
    ///
    /// [#2446]: https://github.com/mokume-metal/mokume/issues/2446
    struct DeferredGlyph {
        /// 6 頂点の先頭の位置 (``Canvas/vertices`` の添字)。
        var start: Int
        /// 焼くはずだった段の鍵と、その字形の書体。
        var key: GlyphAtlas.Key
        var font: CTFont
        /// 置いたときの焼き場の頁 (``GlyphAtlas/pageSerial``)。頁が替わっていたら、置き直す先の面が違う。
        var pageSerial: UInt64
        /// 置いた四角の左上の位置と読む位置 — 頂点がまだそこにあることを確かめる。
        var topLeft: SIMD2<Float>
        var uvMin: SIMD2<Float>
        var penX: Float
        var baseline: Float
        var color: LinearRGBA
        var transform: Transform
    }

    /// 先送りして置いた四角を控える。**置かなかった (区間の外・台帳の指紋) ときは控えない。**
    func noteDeferredGlyph(
        start: Int?, placedWith entry: GlyphAtlas.Entry, key: GlyphAtlas.Key, font: CTFont,
        penX: Float, baseline: Float, color: LinearRGBA
    ) {
        guard let start, start + 6 <= vertices.count else { return }
        deferredGlyphs.append(
            DeferredGlyph(
                start: start, key: key, font: font, pageSerial: atlas.pageSerial,
                topLeft: vertices[start].position, uvMin: entry.uvMin, penX: penX, baseline: baseline,
                color: color, transform: transform))
    }

    /// 先送りした字を払う ([#2446])。**絵が残る (`baking`) なら、焼いて、置いた四角を要る段の画素へ置き直す。**
    /// 残らない (次のフレームが描き直す) なら、控えを捨てるだけで、焼くのは次のフレームに任せる。
    ///
    /// 置き直すのは**頂点の中身だけ**で、列も順番も変えない。置き直せない四角 — 頁が替わって置いた面と焼く面が
    /// 違う・頂点が動いている・焼き場に場所が無い — は近い段のまま残し、拡大が原因だと初回だけ知らせる
    /// (``warnSoftEnlargedTextOnce()``・頁が溢れて低い段で描くときと同じ約束)。
    ///
    /// [#2446]: https://github.com/mokume-metal/mokume/issues/2446
    func settleDeferredGlyphs(baking: Bool) {
        guard !deferredGlyphs.isEmpty else { return }
        let owed = deferredGlyphs
        deferredGlyphs.removeAll(keepingCapacity: true)
        guard baking else { return }
        var left = 0
        for glyph in owed {
            guard glyph.pageSerial == atlas.pageSerial,
                glyph.start + 6 <= vertices.count,
                vertices[glyph.start].position == glyph.topLeft,
                vertices[glyph.start].uv == glyph.uvMin,
                case .found(let entry) = atlas.entry(for: glyph.key, font: glyph.font)
            else {
                left += 1
                continue
            }
            atlas.noteBaked(glyph.key, frame: framesDrawn)
            let color = entry.isColored ? Self.whiteScaled(byAlphaOf: glyph.color) : glyph.color
            let (topLeft, topRight, bottomRight, bottomLeft) = Self.placedCorners(
                glyph.transform, x: glyph.penX + entry.offset.x, y: glyph.baseline + entry.offset.y,
                width: entry.size.x, height: entry.size.y)
            var quad: [ShapeVertex] = []
            quad.reserveCapacity(6)
            Self.appendQuad(
                into: &quad, topLeft, topRight, bottomRight, bottomLeft,
                uvMin: entry.uvMin, uvMax: entry.uvMax, color: color)
            vertices.replaceSubrange(glyph.start..<glyph.start + 6, with: quad)
        }
        if left > 0 { warnSoftEnlargedTextOnce() }
    }

    /// 拡大した字が、1 字の大きさか頁の上限で、頼んだ段より低い段の画素で描かれたことを、初回だけ知らせる。
    /// **原因が拡大 (`scale()` と `textSize()` の積) であることを名乗る** — 字は欠けず、伸ばして描くので
    /// 縁がぼける。次の一手 (拡大か `textSize()` を下げる・字の種類を減らす) が打てる文面にする。
    private func warnSoftEnlargedTextOnce() {
        warnOnce(
            .softEnlargedText,
            "text(): the text is enlarged (textSize() times scale()) beyond what the baking area keeps "
                + "sharp: a single glyph is baked at most \(atlas.scaledBakeByteLimit >> 20) MiB, and "
                + "enlarged glyphs use only the top \(Int(GlyphAtlas.scaledPageShare * 100))% of the "
                + "area. The glyphs are still drawn, from a smaller image, so their edges look soft — "
                + "lower the enlargement (scale() or textSize()) or draw fewer different enlarged characters")
    }

    /// その字形で焼いてある、頼んだ段に一番近い段の字形。**上の段を先に探す** (縮めて描くほうが、
    /// 伸ばして描くよりぼけない)。範囲は 1 オクターブの上と、段 0 までの下。
    private func nearestBakedGlyph(for resolved: ResolvedGlyph, step: Int) -> GlyphAtlas.Entry? {
        for above in 1...GlyphAtlas.stepsPerOctave {
            if let entry = atlas.cachedEntry(for: glyphKey(for: resolved, step: step + above)) {
                return entry
            }
        }
        for below in stride(from: step - 1, through: 1, by: -1) {
            if let entry = atlas.cachedEntry(for: glyphKey(for: resolved, step: below)) {
                return entry
            }
        }
        return atlas.cachedEntry(for: glyphKey(for: resolved))
    }

    /// 鍵の字形を、焼き場から引く (無ければ焼く)。段 0 も拡大した段も、焼き場の面の広げ方・焼き直しは同じ。
    ///
    /// `reportsFull` が偽なら、1 フレームのうちに溢れて諦めるときも黙る — 呼ぶ側 (拡大した段) が低い段へ
    /// 下がって描き、必要なら自分の言葉で知らせる。
    private func bakedGlyph(
        for key: GlyphAtlas.Key, font: CTFont, reportsFull: Bool = true
    ) -> GlyphAtlas.Entry? {
        while true {
            switch atlas.entry(for: key, font: font) {
            case .found(let entry): return entry
            // 理由は面の側が名乗っている。広げても変わらないので、ここは黙って諦める
            case .tooLarge, .unbakeable: return nil
            case .full: break
            }

            guard atlas.canGrow || atlasPageFrame != framesDrawn else {
                if reportsFull { warnAtlasFullInOneFrameOnce() }
                return nil
            }
            closeBatch()
            do {
                if atlas.canGrow {
                    try atlas.grow(gpu: gpu)
                } else {
                    try atlas.rebake(gpu: gpu)
                }
            } catch {
                return nil
            }
            atlasPageFrame = framesDrawn
            currentTexture = atlas.held
            whiteUV = atlas.whiteUV
        }
    }

    /// 画素の境目に合わせた四角を 1 枚積む。
    ///
    /// 字形と画像は**塗り**なので、縁は整数の座標で画素の境目に乗る ([ADR-0039] 決定 2)。
    /// 焼いた画素と描く画素がそのまま 1 対 1 になるので、ずらしも戻しも要らない。
    ///
    /// **字形と画像はどちらもここを通る。** 置き方を 2 箇所に書くと、片方だけ直した日に
    /// 字と画像がずれる — どちらも同じ座標系に載るので、ずれても「なんとなく滲む」としか
    /// 見えない ([#948](https://github.com/mokume-metal/mokume/issues/948))。
    ///
    /// [ADR-0039]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0039-pixel-grid-and-edge-antialiasing.md
    ///
    /// - Returns: 積んだ 6 頂点の先頭の位置 (``vertices`` の添字)。
    @discardableResult
    private func appendPixelAlignedQuad(
        x: Float, y: Float, width: Float, height: Float,
        uvMin: SIMD2<Float>, uvMax: SIMD2<Float>, color: LinearRGBA
    ) -> Int {
        let (topLeft, topRight, bottomRight, bottomLeft) = Self.placedCorners(
            transform, x: x, y: y, width: width, height: height)

        // **6 頂点を 1 度の書き込みで積む** ([#1783])。1 頂点ずつ面の並びへ足すと、足す
        // たびに排他の確かめ (`swift_beginAccess`) が走り、字 1 つで 12 回になっていた
        //
        // [#1783]: https://github.com/mokume-metal/mokume/issues/1783
        beginFlat()
        let start = vertices.count
        Self.appendQuad(
            into: &vertices, topLeft, topRight, bottomRight, bottomLeft,
            uvMin: uvMin, uvMax: uvMax, color: color)
        return start
    }

    /// 四角の 4 隅を、変換で描く先へ移す。**置くときと、先送りした四角を置き直すとき
    /// (``settleDeferredGlyphs(baking:)``) で同じ式を通す。**
    private static func placedCorners(
        _ transform: Transform, x: Float, y: Float, width: Float, height: Float
    ) -> (SIMD2<Float>, SIMD2<Float>, SIMD2<Float>, SIMD2<Float>) {
        let left = x
        let top = y
        let right = left + width
        let bottom = top + height
        return (
            transform.placed(x: left, y: top), transform.placed(x: right, y: top),
            transform.placed(x: right, y: bottom), transform.placed(x: left, y: bottom))
    }

    /// 四角を 2 つの三角形として積む。並びは左上・右上・右下 / 左上・右下・左下。
    private static func appendQuad(
        into vertices: inout [ShapeVertex],
        _ topLeft: SIMD2<Float>, _ topRight: SIMD2<Float>,
        _ bottomRight: SIMD2<Float>, _ bottomLeft: SIMD2<Float>,
        uvMin: SIMD2<Float>, uvMax: SIMD2<Float>, color: LinearRGBA
    ) {
        vertices.append(ShapeVertex(position: topLeft, uv: SIMD2(uvMin.x, uvMin.y), color: color))
        vertices.append(ShapeVertex(position: topRight, uv: SIMD2(uvMax.x, uvMin.y), color: color))
        vertices.append(
            ShapeVertex(position: bottomRight, uv: SIMD2(uvMax.x, uvMax.y), color: color))
        vertices.append(ShapeVertex(position: topLeft, uv: SIMD2(uvMin.x, uvMin.y), color: color))
        vertices.append(
            ShapeVertex(position: bottomRight, uv: SIMD2(uvMax.x, uvMax.y), color: color))
        vertices.append(
            ShapeVertex(position: bottomLeft, uv: SIMD2(uvMin.x, uvMax.y), color: color))
    }

    /// 字形 1 つを四角として置く。
    ///
    /// - Returns: 積んだ 6 頂点の先頭の位置 (``vertices`` の添字)。置かなかったときは `nil`。
    @discardableResult
    func appendGlyphQuad(
        _ entry: GlyphAtlas.Entry, penX: Float, baseline: Float, color: LinearRGBA
    ) -> Int? {
        // 区間の外では置かない (``Canvas/canPlace``・#1672)。断るのは置く所だけで、`text()` は
        // 送り幅と流し込みの続きを今までどおり返す
        guard canPlace else {
            warnOutsideFrame(.placing)
            return nil
        }
        // 台帳の指紋を採るときは置かない (``placesGlyphs``)。送り幅は呼ぶ側が進める
        guard placesGlyphs else { return nil }
        glyphQuadsPlaced += 1
        useGlyphTexture()
        // **色を持つ字形には塗りの色を掛けない。** 焼き場の値に頂点の色を掛けるのが
        // 合成の唯一の式なので、掛けても変わらない色 — 白 — を積めば、字形の色が
        // そのまま出る。塗りの透明度だけは効かせたいので、白をその透明度で乗算した
        // 値にする (乗算済みの白 α は 4 成分すべて α)。
        //
        // 「どちらの式を使うか」を描画側へ伝える道が要らないのはこのためで、
        // 判断は積む側でここだけに閉じている (#271)
        let color = entry.isColored ? Self.whiteScaled(byAlphaOf: color) : color
        return appendPixelAlignedQuad(
            x: penX + entry.offset.x, y: baseline + entry.offset.y,
            width: entry.size.x, height: entry.size.y,
            uvMin: entry.uvMin, uvMax: entry.uvMax, color: color)
    }

    /// 塗りの透明度だけを持つ白 (乗算済み)。掛けても字形の色を変えない。
    private static func whiteScaled(byAlphaOf color: LinearRGBA) -> LinearRGBA {
        let alpha = color.alpha
        return LinearRGBA(
            premultipliedRed: alpha, green: alpha, blue: alpha, alpha: alpha)
    }

    /// 画像を四角として置く。**字形と同じ約束** (縁が画素の境目に乗る) で置かれる
    /// (``appendPixelAlignedQuad(x:y:width:height:uvMin:uvMax:color:)``)。
    func appendImageQuad(
        _ picture: Picture, x: Float, y: Float, width: Float, height: Float,
        uvMin: SIMD2<Float>, uvMax: SIMD2<Float>, color: LinearRGBA
    ) {
        // 区間の外では、絵を整えることも読む面を替えることもしない (``Canvas/canPlace``・#1672)
        guard canPlace else { return warnOutsideFrame(.placing) }
        picture.prepare()
        useTexture(picture.held)
        appendPixelAlignedQuad(
            x: x, y: y, width: width, height: height,
            uvMin: uvMin, uvMax: uvMax, color: color)
    }

    /// 復号した中身から絵を作る。
    func makeImage(_ decoded: ImageFile.Decoded) throws(ImageFailure) -> Image {
        do {
            return try Image(
                width: decoded.width, height: decoded.height, pixels: decoded.pixels, gpu: gpu)
        } catch {
            throw .unplaceable(width: decoded.width, height: decoded.height)
        }
    }

    /// 1 フレームで要る字が、焼き直しても上限の面に収まらなかったことを、初回だけ知らせる。
    ///
    /// **その場面を名乗る** ([#1342])。上限の面が埋まること自体は、焼き直せば戻るので知らせ
    /// ない — 戻れないのは、1 フレームのうちに上限の面を使い切るときだけである。次の一手
    /// (1 フレームで使う字の種類・大きさを減らす) が打てるよう、文面で場面を言う。
    ///
    /// [#1342]: https://github.com/mokume-metal/mokume/issues/1342
    private func warnAtlasFullInOneFrameOnce() {
        let side = GlyphAtlas.maximumSize
        warnOnce(
            .atlasFullInOneFrame,
            "text(): the characters one frame needs do not fit the baking area's limit of "
                + "\(side)x\(side), even after it is baked afresh. The characters beyond that are "
                + "not drawn in such a frame — draw fewer different characters or text sizes in "
                + "one frame, or lower textSize()")
    }

    func appendTriangle(
        _ a: SIMD2<Float>, _ b: SIMD2<Float>, _ c: SIMD2<Float>, color: LinearRGBA
    ) {
        appendTriangle(a, b, c, colors: (color, color, color))
    }

    /// 頂点ごとに色の違う三角形を置く。
    ///
    /// 3 つが同じ色なら 1 色の三角形と区別が付かないので、色を 1 つ受ける形はこれの
    /// 呼び分けである — **頂点ごとの色のために別の経路を作らない** ([ADR-0021] 決定 5)。
    ///
    /// `uvs` は**塗りだけが渡す**読み取り位置。渡さなければ焼き場の白い区画を
    /// 読む — 白を掛けても色は変わらないので、**読み取り位置を持たない形の絵は
    /// 1 ビットも変わらない**。渡したときは貼る絵か 1×1 の白い絵を読む
    /// (``useWrittenUVTexture()``)。輪郭・端点・角はここを渡さない側に居続ける。
    func appendTriangle(
        _ a: SIMD2<Float>, _ b: SIMD2<Float>, _ c: SIMD2<Float>,
        colors: (LinearRGBA, LinearRGBA, LinearRGBA),
        uvs: (SIMD2<Float>, SIMD2<Float>, SIMD2<Float>)? = nil
    ) {
        // 区間の外では、読む面も切り替えない (``Canvas/canPlace``・#1672)
        guard canPlace else { return warnOutsideFrame(.placing) }
        // **図形は白い区画を読む。** 直前に画像を描いていたら、その面を読んだままに
        // なるので戻す (変わらなければ何も起きない)
        beginFlat()
        if uvs != nil { useWrittenUVTexture() } else { useGlyphTexture() }
        let uv = uvs ?? (whiteUV, whiteUV, whiteUV)
        vertices.append(ShapeVertex(position: a, uv: uv.0, color: colors.0))
        vertices.append(ShapeVertex(position: b, uv: uv.1, color: colors.1))
        vertices.append(ShapeVertex(position: c, uv: uv.2, color: colors.2))
    }

    /// 塗りに貼る絵があるなら、囲みの箱を 0…1 に写す関数を返す。
    ///
    /// **変換を掛ける前の座標から作る。** 描画先の座標から作ると、回した図形の上を
    /// 絵が滑る (図形は回ったのに絵は画面に貼り付いたままになる)。
    static func boxUV(of points: [SIMD2<Float>]) -> (SIMD2<Float>) -> SIMD2<Float> {
        var lowest = SIMD2<Float>(repeating: .infinity)
        var highest = SIMD2<Float>(repeating: -.infinity)
        for point in points {
            lowest = simd_min(lowest, point)
            highest = simd_max(highest, point)
        }
        let span = highest - lowest
        // **潰れた軸は 0 に倒す。** 幅の無い図形を 0 で割ると、読み取り位置が数でなく
        // なって面のどこも指さなくなる
        return { point in
            SIMD2(
                span.x > 0 ? (point.x - lowest.x) / span.x : 0,
                span.y > 0 ? (point.y - lowest.y) / span.y : 0)
        }
    }

}
