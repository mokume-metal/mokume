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
            return [
                EffectPass(control: Self.control(kind: 1, radius)),
                EffectPass(control: Self.control(kind: 2, radius)),
            ]
        case .bloom(let amount, let threshold, let radius):
            // 明るいところを取って横へぼかす → 縦へぼかす → 元へ足す。
            // **脇の 2 枚を使う** — 往復の 2 枚とは別に持たないと、元の絵が消える
            return [
                EffectPass(
                    input: .current, output: .side(0),
                    control: Self.control(kind: 8, threshold, radius)),
                EffectPass(
                    input: .side(0), output: .side(1),
                    control: Self.control(kind: 2, radius)),
                EffectPass(
                    input: .current, paired: .side(1), output: .next,
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
/// 並びは線形のままで、脇の絵を使う効果 (にじみ) だけが `side` を指す。
///
/// [ADR-0023]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0023-frame-stages-and-outputs.md
struct EffectPass {
    /// 絵の置き場。往復する 2 枚と、脇に置く枚数で足りる。
    enum Slot: Equatable {
        /// いまの絵。
        case current
        /// 次の絵。ここへ書くと往復が 1 つ進む。
        case next
        /// 脇の絵。
        case side(Int)
    }

    var input: Slot = .current
    /// 組み合わせる相手。`nil` なら入りと同じ絵を束ねる (束ねない口を作らない)。
    var paired: Slot?
    var output: Slot = .next
    var control: (SIMD4<Float>, SIMD4<Float>)
    /// 利用者の効果。`nil` なら組み込み。
    var shader: EffectShader?
}
