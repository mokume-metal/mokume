// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

// 利用者が書く塗り。
extension Sketch {
    /// 断片を読み込む。
    ///
    /// <!-- example: 文脈 var waves: Shader! -->
    /// ```swift
    /// // waves.metal
    /// // float4 paint(Fragment in, Values values) {
    /// //     float wave = 0.5 + 0.5 * sin(in.place.x * 20 + in.time * values.speed);
    /// //     return float4(values.tint.rgb * wave, 1);
    /// // }
    /// waves = try? loadShader(
    ///     "assets/waves.metal",
    ///     values: ["speed": 2, "tint": .color(color(255, 128, 51))])
    /// ```
    ///
    /// ## 書くのは「その画素の色」だけ
    ///
    /// 断片が用意するのは `paint` 1 本で、返すのはその画素の色である。下地との
    /// 混ぜ方 (``blendMode(_:)``) は書かなくてよい — 組み込みの塗りとまったく同じ
    /// 合成を通るので、**混ぜ方が断片によって食い違わない。**
    ///
    /// `Fragment` から読めるもの: 面の中の位置 (`position` は画素・`place` は 0…1)・
    /// 読む面の位置 (`uv`)・図形の色 (`color`)・読んだ面の値 (`texel`)・秒数
    /// (`time`)・面の大きさ (`resolution`)。
    ///
    /// ## 渡す値は読み込むときに宣言する
    ///
    /// `values` に書いた名前が、断片から `values.名前` で読める。後から名前を増やすと
    /// 断片ごと組み直しになるので、**名前は読み込むときに決め、値だけを後から変える**
    /// (``Shader/set(_:_:)-(_,ShaderValue)``)。
    ///
    /// 渡せるのは **float 換算で 64 個まで** (色は 4 個ぶん・2 つ組は 2 個ぶん) — 値は列
    /// ごとに 1 区画へ載せるので、上限は動かせない。超えた宣言は読み込みの時点で断られる。
    ///
    /// ## 面も名前で渡せる
    ///
    /// `surfaces` に書いた名前が、断片から `surfaces.名前` で読める。**渡せるのは
    /// 読み込んだ絵と、自分で描いた面の両方**である。
    ///
    /// <!-- example: 文脈 var blended: Shader! -->
    /// ```swift
    /// // blended.metal
    /// // float4 paint(Fragment in, Values values, Surfaces surfaces) {
    /// //     float4 wood = mokume_sample(surfaces.grain, in.uv);
    /// //     float4 dirt = mokume_sample(surfaces.smudge, in.place);
    /// //     return float4(wood.rgb * mix(1.0, dirt.r, values.amount), wood.a);
    /// // }
    /// guard let bark = try? loadImage("assets/bark.png"),
    ///     let smudge = try? createGraphics(256, 256)
    /// else { return }
    /// blended = try? loadShader(
    ///     "assets/blended.metal",
    ///     values: ["amount": 0.7],
    ///     surfaces: ["grain": .image(bark), "smudge": .graphics(smudge)])
    /// ```
    ///
    /// **面を宣言した断片だけ、受け取るものが 1 つ増える。** 宣言していない断片は
    /// `paint(Fragment, Values)` のままで、書き換えなくてよい。
    ///
    /// 渡せるのは **4 枚まで** — 面は名前ごとに口を 1 つ使い、口の数は断片によらず
    /// 決まっている。超えた宣言は読み込みの時点で断られる。値と同じく、**名前は
    /// 読み込むときに決め、面だけを後から差し替える** (``Shader/set(_:_:)-(_,ShaderSurface)``)。
    ///
    /// ## 平面にも立体にも同じ断片が効く
    ///
    /// **書き分けは要らない。** `rect` にも `box` にも同じ断片が同じ規約で効く —
    /// 前置きの配り方も、渡す値も、置き場も同じである。立体では `Fragment` の
    /// `color` に**光と材質を通したあとの色**が入るので、`in.color` をそのまま
    /// 返せば組み込みの塗りと同じ絵になり、そこから変えていける。
    ///
    /// 断片が書けるのは**その画素の色だけ**で、頂点の落とし方は差し替えられない。
    /// まとめ描き (``shape(_:at:)``) は頂点の側の仕組みなので、**断片を使っても
    /// まとまり方は変わらない。**
    ///
    /// ## 保存したら差し替わる
    ///
    /// 在処のある断片は保存を拾って組み直される。**組み立てに失敗しても絵は消えない** —
    /// 前の断片がそのまま残り、失敗の理由は観測の警告に出る。平面と立体の両方が
    /// 組み上がってはじめて差し替わるので、片方だけ古い断片が効くことはない。
    ///
    /// - Throws: 見つからないとき・組み立てられないとき・値や面が多すぎるときに ``ShaderFailure``。
    public func loadShader(
        _ path: String, values: [String: ShaderValue] = [:],
        surfaces: [String: ShaderSurface] = [:]
    ) throws(ShaderFailure) -> Shader {
        try canvas.loadShader(path, values: values, surfaces: surfaces)
    }

    /// 文字列から断片を作る。保存の拾い直しは効かない (在処が無いため)。
    ///
    /// - Throws: 組み立てられないとき・値や面が多すぎるときに ``ShaderFailure``。
    public func makeShader(
        _ body: String, name: String = "shader", values: [String: ShaderValue] = [:],
        surfaces: [String: ShaderSurface] = [:]
    ) throws(ShaderFailure) -> Shader {
        try canvas.makeShader(body, name: name, values: values, surfaces: surfaces)
    }

    /// これから描くものを、この断片で塗る。
    ///
    /// **溜めている図形はその場で区切られる**ので、これより前に置いた図形が
    /// 後から差し替わることはない。
    ///
    /// - Note: 断片は**フレームを越える**。一度書けば、書き換えるまで残る。
    public func shader(_ shader: Shader) { canvas.shader(shader) }

    /// 組み込みの塗りへ戻す。
    ///
    /// - Note: 断片は**フレームを越える**。一度書けば、書き換えるまで残る。
    public func resetShader() { canvas.resetShader() }
}
