// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

// 描き場所。意味の説明は利用者が最初に触る層 (`Sketch`) が正本で、ここは受け口である
// ([ADR-0020] 決定 4)。
//
// **描き場所は `Canvas` そのもの**である。段が読み書きするのは描画先 (`RenderTarget`)
// で、`Canvas` はそれを `output` に持つ — だから「効果に渡せる絵」と「自分で描ける絵」
// が別の型にならない ([ADR-0023] 決定 1)。別の型を立てると、2D・立体・字・画像・効果の
// 公開 API を丸ごと横流しする層が要る。
//
// [ADR-0020]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0020-api-naming-and-surface.md
// [ADR-0023]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0023-frame-stages-and-outputs.md
extension Canvas {
    /// 画面とは別の描き場所を作る。
    ///
    /// **座標の大きさは `width` × `height` のまま、画素は書き出しの倍率 (`outputScale`) を掛けて刻む**
    /// ([#3453])。本体の面と同じ組み立て (`init(output:gpu:pixelDensity:upscale:outputScale:)`) の 1 本を通るので、
    /// 線の太さ・効果の半径・切り抜き・断片・字の焼き場の鍵は、本体の面と同じ読みで倍率を掛ける。作る側が
    /// 描き場所なら、その倍率を引き継ぐ。倍率 1 (窓・`--scale` の無い書き出し) では、これまでと同じ大きさ・同じ経路。
    ///
    /// [#3453]: https://github.com/mokume-metal/mokume/issues/3453
    public func createGraphics(_ width: Int, _ height: Int) throws(RenderFailure) -> Canvas {
        let scale = outputScale
        // **頼まれた大きさの範囲は、掛ける前に検める。** 掛けた後で検めると、負の大きさが倍率で
        // 別の負の数になり、文面が頼んだ数を名乗れない。上限だけを越えるときは倍率を名指す
        // (``RenderFailure/sizeBeyondOutputScale(width:height:scale:)``)
        try RenderDevice.checkTextureSize(width: width, height: height)
        let (scaledWidth, widthOverflowed) = width.multipliedReportingOverflow(by: scale)
        let (scaledHeight, heightOverflowed) = height.multipliedReportingOverflow(by: scale)
        guard !widthOverflowed, !heightOverflowed,
            RenderDevice.textureSides.contains(scaledWidth),
            RenderDevice.textureSides.contains(scaledHeight)
        else {
            throw .sizeBeyondOutputScale(width: width, height: height, scale: scale)
        }
        // **手前で 1 へ丸めない。** 1 を割る指定が `invalidSize` に届かず、1×1 の描き場所が黙って
        // 返る (#1642)。上の検めを通った大きさだけを関所 (`RenderTarget`) へ渡す
        let target = try RenderTarget(gpu: gpu, width: scaledWidth, height: scaledHeight)
        // **透明で始める。** 確保したままの中身は決まっていないが、`RenderTarget` が作る時点で
        // 透明な黒に塗ってある (#766) — ここで塗り直さない。塗り直すと投入が 1 本増え、
        // 投入済みの全部が終わるまで待つ (#2374)。以後は自動では消さない — 消さないからこそ、
        // 前のフレームの上に積み上がる絵が書ける。奥行きは作りたての面では持ち越さない
        // 扱い (`depthIsHeld = false`) なので、最初の描き切りが必ず消す
        let graphics = try Canvas(
            output: target, gpu: gpu, pixelDensity: 1, upscale: .spatial, outputScale: scale)
        // 時刻と刻み・揺らぎの種と細かさの置き場を、作った面と同じものに繋ぐ (``bind(_:)``)
        bind(graphics)
        // 字形を置くかも引き継ぐ (``placesGlyphs``・#1559)。描き場所に書いた字も同じ絵に載る
        graphics.placesGlyphs = placesGlyphs
        return graphics
    }

    /// `graphics` を、この面のスケッチの置き場 (時刻と刻み・揺らぎの種と細かさ) に繋ぐ。
    /// ``createGraphics(_:_:)`` と ``borrowSketchState(from:)`` (``SketchPart/draw(into:_:)``) がこの 1 本を通る。
    /// **置き場を足すときは、ここへ足す** — 手順を写すと足すたびに片方が漏れる ([#2454])。
    ///
    /// - **時刻と刻みは作った面と同じ置き場を指す** (#1467)。本体の面へ時刻を渡すのは
    ///   ランタイムだけなので、繋がないと描き場所の断片・効果は時刻 0 を、粒は 1/60 秒の
    ///   刻みを読み続ける。描き場所から作った描き場所も、同じ 1 つへ辿り着く。本体のフレームを
    ///   進めるとき、閉じ忘れたフレームを捨てる相手として置き場に載せる (#1834)
    /// - **揺らぎの種と細かさも同じ置き場を指す** (#1503)。繋がないと、本体で決めた種が
    ///   描き場所の断片に届かず、描き場所で決めた種は本体に届かない — 種はスケッチに 1 つ。
    ///   書き換える前に開いた列を閉じさせる相手として、両側を置き場に載せる (``changeNoise(_:)``)
    ///
    /// [#2454]: https://github.com/mokume-metal/mokume/issues/2454
    func bind(_ graphics: Canvas) {
        graphics.timebase = timebase
        timebase.add(layer: graphics)
        graphics.noiseStore = noiseStore
        noiseStore.add(reader: self)
        noiseStore.add(reader: graphics)
    }
}
