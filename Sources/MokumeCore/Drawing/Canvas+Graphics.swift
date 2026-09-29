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
    public func createGraphics(_ width: Int, _ height: Int) throws(RenderFailure) -> Canvas {
        // **大きさはそのまま関所 (`RenderTarget`) へ渡す。** 手前で 1 へ丸めると、1 を割る
        // 指定が `invalidSize` に届かず、1×1 の描き場所が黙って返る (#1642)
        let target = try RenderTarget(gpu: gpu, width: width, height: height)
        // **透明で始める。** 確保したままの中身は決まっていないので、既定で透けている
        // ことを構造で保証するには 1 度塗るしかない。以後は自動では消さない —
        // 消さないからこそ、前のフレームの上に積み上がる絵が書ける
        try target.fill(with: .transparent)
        let graphics = try Canvas(target: target, gpu: gpu)
        // **時刻と刻みは作った面と同じ置き場を指す** (#1467)。本体の面へ時刻を渡すのは
        // ランタイムだけなので、繋がないと描き場所の断片・効果は時刻 0 を、粒は 1/60 秒の
        // 刻みを読み続ける。描き場所から作った描き場所も、同じ 1 つへ辿り着く
        graphics.timebase = timebase
        // **揺らぎの種と細かさも同じ置き場を指す** (#1503)。繋がないと、本体で決めた種が
        // 描き場所の断片に届かず、描き場所で決めた種は本体に届かない — 種はスケッチに 1 つ
        graphics.noiseStore = noiseStore
        // 書き換える前に描き切らせる相手として、両側を置き場に載せる (``changeNoise(_:)``)
        noiseStore.add(reader: self)
        noiseStore.add(reader: graphics)
        // 字形を置くかも引き継ぐ (``placesGlyphs``・#1559)。描き場所に書いた字も同じ絵に載る
        graphics.placesGlyphs = placesGlyphs
        return graphics
    }
}
