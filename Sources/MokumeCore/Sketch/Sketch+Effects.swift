// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

// 効果。
extension Sketch {
    /// このフレームの絵にかける効果を決める。
    ///
    /// ```swift
    /// func draw() {
    ///     // …描く…
    ///     effects([.blur(radius: 4), .bloom(amount: 0.6), .vignette(amount: 0.5)])
    /// }
    /// ```
    ///
    /// ## 並びがそのまま順番
    ///
    /// 前から順にかかる。**並びは値なので、組み替えても差し替えても同じように効く** —
    /// 効果ごとの呼び出し口 (`blur()` のようなもの) は置いていない。置いた時点で
    /// 「並び」を持てなくなり、後から段を差し込む先が無くなるためである。
    ///
    /// ## フレームを越えない
    ///
    /// 光や視点と同じで、`draw()` のたびに書き直す。書かなかったフレームには
    /// 何もかからない (塗りや線のような**描き方**は逆に越える)。
    ///
    /// ## 数の意味
    ///
    /// **`amount` は 0…1 で、0 なら効かない。** 寸法は名前で示す (`radius` は画素)。
    /// 詳しくは ``Effect``。
    ///
    /// ## 画素を読むときとの前後
    ///
    /// 効果はフレームの終わりに立つ段なので、``pixels`` のようにフレームの途中で読む
    /// 画素には**まだ効いていない**。画面・書き出し・観測はいずれも効果を通した同じ
    /// 1 枚を受け取る。
    public func effects(_ effects: [Effect]) { canvas.effects(effects) }

    /// 文字列から効果を作る。保存の拾い直しは効かない (在処が無いため)。
    ///
    /// <!-- example: 文脈 var ripple: EffectShader! -->
    /// ```swift
    /// ripple = try? makeEffect(
    ///     """
    ///     float4 effect(Pixel in, Values values) {
    ///         float wave = sin(in.place.y * 60.0 + in.time * 4.0) * values.depth;
    ///         return mokume_at(in, in.place + float2(wave, 0.0));
    ///     }
    ///     """,
    ///     values: ["depth": 0.01])
    /// ```
    ///
    /// ## 平面・立体の塗りと同じ規約
    ///
    /// 前置きは自動で足されるので、書くのは `float4 effect(Pixel in, Values values)`
    /// 1 本だけ。`in.color` がこの画素、`mokume_at` でほかの場所を読める。渡した値は
    /// `values` から名前で引ける。**組み込みの効果も同じ規約で書いてある。**
    ///
    /// 使うときは ``Effect/custom(_:)`` として並びへ入れる。
    ///
    /// - Throws: 組み立てられないときに ``ShaderFailure``。
    public func makeEffect(
        _ body: String, name: String = "effect", values: [String: ShaderValue] = [:]
    ) throws(ShaderFailure) -> EffectShader {
        try canvas.makeEffect(body, name: name, values: values)
    }

    /// ファイルから効果を読み込む。
    ///
    /// **保存したら差し替わる。** 組み立てに失敗しても絵は止まらない — 前の効果が
    /// そのまま残り、失敗の理由は観測の警告に出る。
    ///
    /// - Throws: 見つからないとき・組み立てられないときに ``ShaderFailure``。
    public func loadEffect(
        _ path: String, values: [String: ShaderValue] = [:]
    ) throws(ShaderFailure) -> EffectShader {
        try canvas.loadEffect(path, values: values)
    }
}
