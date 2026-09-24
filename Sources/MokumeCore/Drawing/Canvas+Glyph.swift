// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT
//
// 字形と画像を四角として積む下ごしらえ。`Canvas.swift` の MARK「文字の下ごしらえ」を、
// 区画ごとここへ移した ([#943](https://github.com/mokume-metal/mokume/issues/943))。
//
// **説明文は置かない。** 正本は上の層 (ADR-0020 決定 4) で、api-surface.py の
// slash_doc は宣言の直前に積んだ `//` も説明文として拾う。この覚え書きが
// 拾われないよう、宣言との間は必ず 1 行空ける。

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
    var textFillColor: LinearRGBA? { style.hasFill ? style.fill : nil }

    /// いま指定されている書体。同じ指定なら作り直さない。
    var typeface: Typeface {
        let request = TypefaceRequest(
            name: style.fontName, size: style.textSize, style: style.textStyle)
        if let found = typefaces[request] { return found }
        let face = Typeface(request: request)
        typefaces[request] = face
        return face
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
    func glyphEntry(for resolved: ResolvedGlyph) -> GlyphAtlas.Entry? {
        let key = GlyphAtlas.Key(
            fontKey: resolved.fontKey, size: style.textSize, style: style.textStyle,
            glyph: resolved.glyph)
        while true {
            switch atlas.entry(for: key, font: resolved.font) {
            case .found(let entry): return entry
            // 理由は面の側が名乗っている。広げても変わらないので、ここは黙って諦める
            case .tooLarge, .unbakeable: return nil
            case .full: break
            }

            guard atlas.canGrow || atlasPageFrame != framesDrawn else {
                warnAtlasFullInOneFrameOnce()
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
    private func appendPixelAlignedQuad(
        x: Float, y: Float, width: Float, height: Float,
        uvMin: SIMD2<Float>, uvMax: SIMD2<Float>, color: LinearRGBA
    ) {
        let left = x
        let top = y
        let right = left + width
        let bottom = top + height

        let topLeft = transform.apply(x: left, y: top)
        let topRight = transform.apply(x: right, y: top)
        let bottomRight = transform.apply(x: right, y: bottom)
        let bottomLeft = transform.apply(x: left, y: bottom)

        appendGlyphVertex(topLeft, SIMD2(uvMin.x, uvMin.y), color)
        appendGlyphVertex(topRight, SIMD2(uvMax.x, uvMin.y), color)
        appendGlyphVertex(bottomRight, SIMD2(uvMax.x, uvMax.y), color)
        appendGlyphVertex(topLeft, SIMD2(uvMin.x, uvMin.y), color)
        appendGlyphVertex(bottomRight, SIMD2(uvMax.x, uvMax.y), color)
        appendGlyphVertex(bottomLeft, SIMD2(uvMin.x, uvMax.y), color)
    }

    /// 字形 1 つを四角として置く。
    func appendGlyphQuad(
        _ entry: GlyphAtlas.Entry, penX: Float, baseline: Float, color: LinearRGBA
    ) {
        useGlyphTexture()
        // **色を持つ字形には塗りの色を掛けない。** 焼き場の値に頂点の色を掛けるのが
        // 合成の唯一の式なので、掛けても変わらない色 — 白 — を積めば、字形の色が
        // そのまま出る。塗りの透明度だけは効かせたいので、白をその透明度で乗算した
        // 値にする (乗算済みの白 α は 4 成分すべて α)。
        //
        // 「どちらの式を使うか」を描画側へ伝える道が要らないのはこのためで、
        // 判断は積む側でここだけに閉じている (#271)
        let color = entry.isColored ? Self.whiteScaled(byAlphaOf: color) : color
        appendPixelAlignedQuad(
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

    private func appendGlyphVertex(
        _ position: SIMD2<Float>, _ uv: SIMD2<Float>, _ color: LinearRGBA
    ) {
        beginFlat()
        vertices.append(ShapeVertex(position: position, uv: uv, color: color))
    }

    /// 画像を四角として置く。**字形と同じ約束** (縁が画素の境目に乗る) で置かれる
    /// (``appendPixelAlignedQuad(x:y:width:height:uvMin:uvMax:color:)``)。
    func appendImageQuad(
        _ picture: Picture, x: Float, y: Float, width: Float, height: Float,
        uvMin: SIMD2<Float>, uvMax: SIMD2<Float>, color: LinearRGBA
    ) {
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
