// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

/// 種と細かさを値として持つ、なめらかな揺らぎ。座標を渡すと 0…1 が返る。
///
/// スケッチの揺らぎ (``SketchPart/noise(_:_:_:_:)``) は、種と細かさ (``SketchPart/noiseSeed(_:)``・
/// ``SketchPart/noiseDetail(_:_:)``) がスケッチに 1 つで、部品ごとに別の模様を引くには全体の状態を書き換えるしかない。
/// この型は種・重ねる枚数・弱まりを**値として持つ** — 板ごと・タイルごとに別の種の揺らぎを並べて、スケッチの
/// 種に触れない。`init` の中や部品 (`struct`) の中にも持ち歩ける。
///
/// <!-- example: 文脈 var planks: [NoiseField] = [] -->
/// ```swift
/// func setup() {
///     // 板ごとに別の種。スケッチの noiseSeed には触れない
///     planks = (0..<4).map { NoiseField(seed: 100 + $0) }
/// }
///
/// func draw() {
///     background(23, 26, 31)
///     noStroke()
///     for (i, plank) in planks.enumerated() {
///         for x in stride(from: Float(0), to: width, by: 8) {
///             let grain = plank.value(x * 0.02, time * 0.3)
///             fill(120 + grain * 100, 80 + grain * 60, 50)
///             rect(x, 20 + Float(i) * 90, 8, 80)
///         }
///     }
/// }
/// ```
///
/// ## 同じ設定なら、スケッチの `noise()` と同じ値
///
/// `NoiseField(seed: 11).value(x, y)` は、`noiseSeed(11)` の後の `noise(x, y)` と同じ値を返す
/// (`octaves`・`falloff` は ``SketchPart/noiseDetail(_:_:)`` の枚数と弱まり、既定は 4 枚・0.5)。
/// 座標は 4 つまで渡せる (``SketchPart/noise(_:_:_:_:)``)。
///
/// ## 種は必ず渡す
///
/// 作り方は ``init(seed:octaves:falloff:)`` だけで、**種の無い `init()` は無い** (``RandomSource`` と同じ理由。
/// 時刻から種を作る道を置くと、同じ入力から同じ絵にならず、記録した入力の再生でも再現できない)。
///
/// ## 断片には届かない
///
/// 断片の `mokume_noise` はスケッチの種 (``SketchPart/noiseSeed(_:)``) を読む。この型で作った揺らぎを断片で
/// 引く口は、まだ無い。
///
/// ## 値の型である
///
/// 代入すると写しになる。読むだけで、書き換える口は持たない。
public nonisolated struct NoiseField: Equatable, Sendable {
    /// 中身の揺らぎ。
    var noise: ValueNoise

    /// 種・重ねる枚数・弱まりを決めて作る。
    ///
    /// - Parameters:
    ///   - seed: 種。``SketchPart/noiseSeed(_:)`` と同じ数で、同じ種なら同じ模様になる。
    ///   - octaves: 重ねる枚数。1…16 で、外れた値は端に丸める。既定は 4。
    ///   - falloff: 1 枚ごとの弱まり。0…1 で、外れた値は端に丸める (数でない値は既定の 0.5)。既定は 0.5。
    ///
    /// **外れた値は丸めて受け取る** (``SketchPart/noiseDetail(_:_:)`` は外れた値を無視して知らせるが、値には
    /// 無視する前の設定が無い)。
    public init(seed: Int, octaves: Int = 4, falloff: some ScalarConvertible = 0.5) {
        let falloff = falloff.asFloat
        noise = ValueNoise(
            seed: UInt32(bitPattern: Int32(truncatingIfNeeded: seed)),
            octaves: min(max(octaves, ValueNoise.octaveRange.lowerBound), ValueNoise.octaveRange.upperBound),
            falloff: falloff.isFinite ? min(max(falloff, 0), 1) : 0.5)
    }

    /// その座標の揺らぎ (0…1)。**近い座標には近い値**が返り、同じ座標には何度呼んでも同じ値が返る。
    ///
    /// <!-- example: 文脈 let ground = NoiseField(seed: 3) -->
    /// ```swift
    /// background(23, 26, 31)
    /// noStroke()
    /// for x in stride(from: Float(0), to: width, by: 4) {
    ///     let high = 40 + ground.value(x * 0.01) * 200
    ///     rect(x, height - high, 4, high)
    /// }
    /// ```
    ///
    /// 読み方と座標の扱いは ``SketchPart/noise(_:_:_:_:)`` と同じ (欠けた座標は 0。±1e6 まで。数でない座標には 0)。
    public func value(
        _ x: some ScalarConvertible, _ y: some ScalarConvertible = 0, _ z: some ScalarConvertible = 0,
        _ w: some ScalarConvertible = 0
    ) -> Float {
        noise.value(x.asFloat, y.asFloat, z.asFloat, w.asFloat)
    }
}
