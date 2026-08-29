// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

/// 座標を渡すと 0…1 が返る、なめらかな揺らぎ。
///
/// ## 断片側に同じものがある
///
/// **この型と `Common.metal` の `mokume_noise` は同じ式である。** 同じ種・同じ座標
/// なら、CPU で引いても断片で引いても同じ値が出る — 面と立体で同じ模様を出すのに、
/// 揺らぎを 2 つ別々に持たなくて済むようにするためである ([#366])。
///
/// 二重管理を許すのは [ADR-0001] 原則 9 に反するので、**食い違いは機械が見る** —
/// `NoiseParityTests` が代表点で両者を突き合わせ、ずれたら赤くなる。片方を直したら
/// もう片方も直すことになる、という規律を文書ではなく検査に持たせている。
///
/// ## 格子の値はビット単位で一致する
///
/// 格子点の値は**整数演算だけ**で作り、最後に `Float(h >> 8) * (1 / 16777216)` で
/// 落とす。`&*` `&+` `^` `>>` は MSL の `uint` 演算とまったく同じで、`h >> 8` は
/// 24 ビットに収まるので `Float` へ厳密に載り、2 の冪を掛けるのも厳密である。
///
/// 浮動小数が入るのは**繋ぎと重ね合わせだけ**。Metal は既定で fast-math なので
/// そこでは融合や順序の入れ替えが起きうるが、段が浅いので差は最下位ビット数個に
/// 留まる。検査の許容はそこから決めている。
///
/// ## 座標の範囲
///
/// 扱えるのは ±1e6 まで (``coordinateLimit``)。外は端に張り付くので模様は止まるが、
/// 落ちはしない (有限でない座標は 0 を返す)。
///
/// [ADR-0001]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0001-founding-principles.md
/// [#366]: https://github.com/mokume-metal/mokume/issues/366
struct ValueNoise: Equatable, Sendable {
    /// 受け取れる重ねる枚数。上を切るのは、枚数だけで走らせ続けられないため。
    static let octaveRange = 1...16
    /// 扱える座標の端。**外はここへ張り付く。**
    ///
    /// 格子の番号は 32 ビット整数で数えるので、切らないと `Int32` への変換が落ちる —
    /// 読み取りは落ちない約束である (ADR-0020 決定 5)。断片側 (`mokume_noiseLayer`)
    /// も同じ値で切るので、**外に出ても CPU と断片は一致したまま**になる。
    static let coordinateLimit: Float = 1_000_000

    /// 種。**決めなければ 0** — 時刻から作らない (原則 2)。
    var seed: UInt32 = 0
    /// 重ねる枚数。既定は手本と同じ 4 枚。
    var octaves = 4
    /// 1 枚ごとの弱まり。既定は手本と同じ 0.5。
    ///
    /// **既定の値は面の側 (`noiseDetail` の既定引数) にも書かれている。** 既定引数は
    /// リテラルしか置けず、内部の定数を指せないためで、片方を変えたらもう片方も変える。
    var falloff: Float = 0.5

    /// 格子点の値を作る混ぜ合わせ。
    ///
    /// **`Common.metal` の `mokume_noiseHash` と 1 行ずつ対応する。** 片方を触ったら
    /// もう片方も触る (突き合わせは `NoiseParityTests`)。
    static func hash(_ x: Int32, _ y: Int32, _ z: Int32, _ seed: UInt32) -> UInt32 {
        var h = UInt32(bitPattern: x) &* 0x27D4_EB2D
        h ^= UInt32(bitPattern: y) &* 0x1656_67B1
        h ^= UInt32(bitPattern: z) &* 0x9E37_79B1
        h ^= seed &* 0x85EB_CA6B
        h ^= h >> 15
        h = h &* 0x2C1B_3C6D
        h ^= h >> 12
        h = h &* 0x297A_2D39
        h ^= h >> 15
        return h
    }

    /// 格子点の値 (0…1)。
    private static func corner(_ x: Int32, _ y: Int32, _ z: Int32, _ seed: UInt32) -> Float {
        Float(hash(x, y, z, seed) >> 8) * (1.0 / 16_777_216.0)
    }

    /// 格子を繋いだ 1 枚ぶんの揺らぎ。
    ///
    /// 繋ぎ方は端で傾きが 0 になるもの。**折れ目が縞として乗らない**ようにするため。
    static func layer(_ x: Float, _ y: Float, _ z: Float, _ seed: UInt32) -> Float {
        let limit = ValueNoise.coordinateLimit
        let cx = min(max(x, -limit), limit)
        let cy = min(max(y, -limit), limit)
        let cz = min(max(z, -limit), limit)
        let xi = cx.rounded(.down)
        let yi = cy.rounded(.down)
        let zi = cz.rounded(.down)
        let xf = cx - xi
        let yf = cy - yi
        let zf = cz - zi
        let u = xf * xf * (3 - 2 * xf)
        let v = yf * yf * (3 - 2 * yf)
        let w = zf * zf * (3 - 2 * zf)

        let x0 = Int32(xi)
        let y0 = Int32(yi)
        let z0 = Int32(zi)
        let x1 = x0 &+ 1
        let y1 = y0 &+ 1
        let z1 = z0 &+ 1

        let near = mix(
            mix(corner(x0, y0, z0, seed), corner(x1, y0, z0, seed), u),
            mix(corner(x0, y1, z0, seed), corner(x1, y1, z0, seed), u), v)
        let far = mix(
            mix(corner(x0, y0, z1, seed), corner(x1, y0, z1, seed), u),
            mix(corner(x0, y1, z1, seed), corner(x1, y1, z1, seed), u), v)
        return mix(near, far, w)
    }

    /// 倍率を変えて重ねた揺らぎ (0…1)。
    ///
    /// **重ねた合計で割る。** 手本は割らないので弱まりを大きくすると 1 を超えるが、
    /// ここでは「0…1 が返る」を面の約束にしているので、約束のほうを守る。
    func value(_ x: Float, _ y: Float, _ z: Float) -> Float {
        // **落ちない・NaN を返さない。** 読み取りは走っていない時点からも呼ばれる
        // (ADR-0020 決定 5)
        guard x.isFinite, y.isFinite, z.isFinite else { return 0 }

        var sum: Float = 0
        var total: Float = 0
        var amplitude: Float = 1
        var frequency: Float = 1
        for octave in 0..<max(1, octaves) {
            // 枚ごとに種をずらす。ずらさないと、倍率違いの同じ模様が重なって
            // 格子の目が見える
            let layerSeed = seed &+ UInt32(octave) &* 0x9E37_79B1
            sum += Self.layer(x * frequency, y * frequency, z * frequency, layerSeed) * amplitude
            total += amplitude
            amplitude *= falloff
            frequency *= 2
        }
        return total > 0 ? sum / total : 0
    }
}

/// 線形に混ぜる。**`Common.metal` の `mix` と同じ式**にするために自前で書く
/// (`simd` の `mix` は書き方が違うので、並べて読めなくなる)。
private func mix(_ a: Float, _ b: Float, _ t: Float) -> Float {
    a + (b - a) * t
}
