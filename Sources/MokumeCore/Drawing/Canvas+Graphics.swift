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
        let target = try RenderTarget(gpu: gpu, width: max(1, width), height: max(1, height))
        // **透明で始める。** 確保したままの中身は決まっていないので、既定で透けている
        // ことを構造で保証するには 1 度塗るしかない。以後は自動では消さない —
        // 消さないからこそ、前のフレームの上に積み上がる絵が書ける
        try target.fill(with: .transparent)
        return try Canvas(target: target, gpu: gpu)
    }
}
