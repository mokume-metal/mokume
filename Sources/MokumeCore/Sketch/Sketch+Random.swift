// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

// 乱数と揺らぎ。
extension Sketch {
    /// 0 以上 1 未満の値。**呼ぶたびに列が進む。**
    ///
    /// **種を決めなくても、走らせるたびに同じ列が出る。** 時刻から種を作らないため
    /// ([ADR-0001] 原則 2)。毎回ちがう絵が欲しければ、変わる値を ``randomSeed(_:)``
    /// へ渡す。
    ///
    /// [ADR-0001]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0001-founding-principles.md
    public func random() -> Float { Self.requireRuntime().randomness.unitValue() }

    /// 0 以上 `high` 未満の値。`high` が負なら `high` 以上 0 未満。
    public func random(_ high: Float) -> Float {
        Self.requireRuntime().randomness.value(from: 0, to: high)
    }

    /// `low` 以上 `high` 未満の値。**順序が逆でも受け取る。**
    public func random(_ low: Float, _ high: Float) -> Float {
        Self.requireRuntime().randomness.value(from: low, to: high)
    }

    /// 乱数の種。同じ種を置いてから同じ順に呼べば、いつでも同じ列が出る。
    ///
    /// **列は ``draw()`` を越えて進み続ける。** フレームの頭で戻したいなら、
    /// そのフレームの頭でこれを呼ぶ。
    public func randomSeed(_ seed: Int) { Self.requireRuntime().randomness = Randomness(seed: seed) }

    /// その座標の揺らぎ (0…1)。**近い座標には近い値**が返る、なめらかな乱れ。
    ///
    /// ``random()`` と違って列ではないので、**同じ座標には何度呼んでも同じ値**が
    /// 返る。フレームをまたいで安定した模様は、これで描く。
    ///
    /// ```swift
    /// for x in stride(from: 0, to: width, by: 4) {
    ///     let y = noise(x * 0.01) * height
    ///     circle(x, y, 3)
    /// }
    /// ```
    ///
    /// **断片からも同じ値が引ける。** 利用者が書いた塗りの中で `mokume_noise(in, p)`
    /// と書くと、``noiseSeed(_:)`` で決めた同じ種の同じ揺らぎが出る — 面と立体で
    /// 同じ模様を出すのに、揺らぎを 2 つ別々に持たなくてよい。
    ///
    /// 座標として扱えるのは ±1e6 くらいまで。それを超えると模様は破綻するが、
    /// 落ちはしない (数でない座標には 0 が返る)。
    public func noise(_ x: Float, _ y: Float = 0, _ z: Float = 0) -> Float {
        canvas.noise(x, y, z)
    }

    /// 揺らぎの種。**断片にも同じ種が届く**ので、配線しなくてよい。
    ///
    /// 乱数の種 (``randomSeed(_:)``) とは別に持つ。片方を決め直しても、もう片方の
    /// 模様は動かない。
    public func noiseSeed(_ seed: Int) { canvas.noiseSeed(seed) }

    /// 揺らぎの細かさ — 重ねる枚数 `lod` と、1 枚ごとの弱まり `falloff`。
    ///
    /// 枚数を増やすほど細かい乱れが乗り、弱まりを大きくするほど細かいほうが目立つ。
    /// 既定は 4 枚・0.5。枚数は 1…16、弱まりは 0…1 で、外れた値は無視して知らせる。
    ///
    /// **断片にも同じ細かさが届く。**
    public func noiseDetail(_ lod: Int, _ falloff: Float = 0.5) {
        canvas.noiseDetail(lod, falloff)
    }
}
