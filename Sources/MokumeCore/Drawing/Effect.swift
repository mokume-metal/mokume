// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import simd

/// 描いた絵にかける効果。
///
/// 使い方は ``Sketch/effects(_:)`` にある。
///
/// ## 数の意味は名前が決める
///
/// - **`amount` は 0…1 で、0 なら効かない。** 1 がいちばん強い
/// - **寸法は名前で示す** (`radius` は画素)。「強さ」という名前の数に半径を入れない —
///   入れると「大きいほど弱い」という逆の意味になり、直すときに意味の反転を伴う
/// - 増減を表す数 (``adjust(brightness:contrast:saturation:)``) は **0 が無効**で、
///   正で増え負で減る
///
/// **散文の約束にしていない。** 全部の組み込みの効果について「無効の値なら絵が
/// 1 ビットも変わらない」を検査が見ている。
public enum Effect {
    /// ぼかす。`radius` は画素で、0 なら効かない。
    ///
    /// 半径が 8 を越えると縮めた絵の上でぼかして広げる (半径が大きいほど小さく、1/8 まで)。
    /// 見え方は同じ半径で揃えてあるが、絵は全解像度で回したものとは同じにならない。
    case blur(radius: Float)
    /// 明るいところをにじませる。
    case bloom(amount: Float, threshold: Float = 0.7, radius: Float = 12)
    /// 色を反転する。**アルファは動かない。**
    case invert(amount: Float = 1)
    /// 色を抜く。
    case monochrome(amount: Float = 1)
    /// 四隅を落とす。
    case vignette(amount: Float)
    /// 色をずらす (色収差)。
    case fringe(amount: Float)
    /// 明るさ・対比・彩度を動かす。**どれも 0 が無効。**
    case adjust(brightness: Float = 0, contrast: Float = 0, saturation: Float = 0)
    /// 利用者が書いた効果。
    case custom(EffectShader)

    /// この効果が通る段。**順に並べたものがそのまま連なりになる。**
    var passes: [EffectPass] {
        switch self {
        case .blur(let radius):
            let level = Self.reductionLevel(for: radius)
            guard level > 0 else {
                // 小さなぼかしは全解像度で横 → 縦。これまでと同じ 2 段
                return [
                    EffectPass(control: Self.control(kind: 1, radius)),
                    EffectPass(control: Self.control(kind: 2, radius)),
                ]
            }
            // 大きなぼかしは縮めた絵の上で回す (#755): 箱で縮める → 横 → 縦 → 線形に広げる。
            // 半径も同じ比で縮めるので、17 タップの間隔は 1 画素以下に収まる
            let factor = Float(1 << level)
            let small = radius / factor
            return [
                EffectPass(
                    input: .current, output: .side(0, level: level),
                    control: Self.control(kind: 13, factor)),
                EffectPass(
                    input: .side(0, level: level), output: .side(1, level: level),
                    control: Self.control(kind: 1, small)),
                EffectPass(
                    input: .side(1, level: level), output: .side(0, level: level),
                    control: Self.control(kind: 2, small)),
                EffectPass(
                    input: .side(0, level: level), output: .next,
                    control: Self.control(kind: 13, 1)),
            ]
        case .bloom(let amount, let threshold, let radius):
            // 明るいところを取りながら縮める → 横へぼかす → 縦へぼかす → 元へ足す。
            // **脇の 2 枚を使う** — 往復の 2 枚とは別に持たないと、元の絵が消える。
            // にじみは 1/4 以下で足りる (#755) — 光の広がりに 1 画素の精度は要らない。
            // 合成は脇の絵を線形に読むので、広げる段は要らない
            let level = max(2, Self.reductionLevel(for: radius))
            let factor = Float(1 << level)
            return [
                EffectPass(
                    input: .current, output: .side(0, level: level),
                    control: Self.control(kind: 8, threshold, factor)),
                EffectPass(
                    input: .side(0, level: level), output: .side(1, level: level),
                    control: Self.control(kind: 1, radius / factor)),
                EffectPass(
                    input: .side(1, level: level), output: .side(0, level: level),
                    control: Self.control(kind: 2, radius / factor)),
                EffectPass(
                    input: .current, paired: .side(0, level: level), output: .next,
                    control: Self.control(kind: 9, amount)),
            ]
        case .invert(let amount):
            return [EffectPass(control: Self.control(kind: 3, amount))]
        case .monochrome(let amount):
            return [EffectPass(control: Self.control(kind: 4, amount))]
        case .vignette(let amount):
            return [EffectPass(control: Self.control(kind: 5, amount))]
        case .fringe(let amount):
            return [EffectPass(control: Self.control(kind: 6, amount))]
        case .adjust(let brightness, let contrast, let saturation):
            return [
                EffectPass(control: Self.control(kind: 7, brightness, contrast, saturation))
            ]
        case .custom(let shader):
            return [EffectPass(control: Self.control(kind: 0), shader: shader)]
        }
    }

    /// 拡大の段が使う種別の番号。**利用者の並びには現れない。**
    ///
    /// 拡大は解像度の決め方の一部で、後処理の 1 つではない ([ADR-0015] 決定 1)。
    /// それでも通る道は同じ段なので、種別だけをここで名乗る — 番号がこの並びの外に
    /// あると、組み込みの効果を 1 つ足したときに黙って衝突する。
    ///
    /// [ADR-0015]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0015-metalfx-role.md
    static let enlargeKind: Float = 11
    /// 拡大して、前のフレームの結果と混ぜる種別の番号 (時間方向)。
    static let accumulateKind: Float = 12

    /// 半径 (画素) から、ぼかしを回す段の縮め幅 (2 のべき) を決める。
    ///
    /// ぼかしの 17 タップは半径 / 8 の間隔で置かれる。**縮めた半径を 8 以下に保てば
    /// 間隔は 1 画素以下**に収まり、縮めた絵の画素を 1 つも飛ばさない。半径が大きいほど
    /// 低い段で回し、1/8 より下へは行かない — 半径 64 を越えると間隔が 1 画素を越えるが、
    /// それはこれまで全解像度で半径 8 を越えていたときと同じ体制である (#755)。
    ///
    /// 8 以下では 0 なので、**小さなぼかしの絵はこれまでと 1 ビットも変わらない。**
    static func reductionLevel(for radius: Float) -> Int {
        // nan は比較が偽になるので全解像度へ倒れる
        guard radius > 8 else { return 0 }
        if radius <= 16 { return 1 }
        if radius <= 32 { return 2 }
        return EffectPipeline.maxReductionLevel
    }

    /// 組み込みの効果に渡す設定を詰める。**並びの正本はここ**で、読む側は
    /// `Shaders/Effects/Builtin.metal` にある。
    private static func control(
        kind: Float, _ p0: Float = 0, _ p1: Float = 0, _ p2: Float = 0, _ p3: Float = 0
    ) -> (SIMD4<Float>, SIMD4<Float>) {
        (SIMD4(kind, p0, p1, p2), SIMD4(p3, 0, 0, 0))
    }
}

/// 効果を 1 回通すぶん。
///
/// **絵から絵への変換 1 種類** ([ADR-0023] 決定 1)。有向グラフの機構は持たない —
/// 並びは線形のままで、脇の絵を使う効果 (ぼかし・にじみ) だけが `side` を指す。
///
/// [ADR-0023]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0023-frame-stages-and-outputs.md
struct EffectPass {
    /// 絵の置き場。往復する 2 枚と、脇に置く枚数で足りる。
    enum Slot: Equatable {
        /// いまの絵。
        case current
        /// 次の絵。ここへ書くと往復が 1 つ進む。**並びの最後なら入りの絵そのもの**へ書く
        /// (その段が入りの絵を読んでいない限り)。
        case next
        /// 脇の絵。`level` が 1 以上なら 1 / 2^level に縮めた絵 (#755)。
        case side(Int, level: Int)
    }

    var input: Slot = .current
    /// 組み合わせる相手。`nil` なら入りと同じ絵を束ねる (束ねない口を作らない)。
    var paired: Slot?
    var output: Slot = .next
    var control: (SIMD4<Float>, SIMD4<Float>)
    /// 利用者の効果。`nil` なら組み込み。
    var shader: EffectShader?
}
