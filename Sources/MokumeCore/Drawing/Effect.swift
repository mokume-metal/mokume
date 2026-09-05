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
                    EffectPass(control: Self.control(kind: .blurX, radius)),
                    EffectPass(control: Self.control(kind: .blurY, radius)),
                ]
            }
            // 大きなぼかしは縮めた絵の上で回す (#755): 箱で縮める → 横 → 縦 → 線形に広げる。
            // 半径も同じ比で縮めるので、17 タップの間隔は 1 画素以下に収まる
            let factor = Float(1 << level)
            let small = radius / factor
            return [
                EffectPass(
                    input: .current, output: .side(0, level: level),
                    control: Self.control(kind: .resize, factor)),
                EffectPass(
                    input: .side(0, level: level), output: .side(1, level: level),
                    control: Self.control(kind: .blurX, small)),
                EffectPass(
                    input: .side(1, level: level), output: .side(0, level: level),
                    control: Self.control(kind: .blurY, small)),
                EffectPass(
                    input: .side(0, level: level), output: .next,
                    control: Self.control(kind: .resize, 1)),
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
                    control: Self.control(kind: .bloomExtract, threshold, factor)),
                EffectPass(
                    input: .side(0, level: level), output: .side(1, level: level),
                    control: Self.control(kind: .blurX, radius / factor)),
                EffectPass(
                    input: .side(1, level: level), output: .side(0, level: level),
                    control: Self.control(kind: .blurY, radius / factor)),
                EffectPass(
                    input: .current, paired: .side(0, level: level), output: .next,
                    control: Self.control(kind: .bloomCombine, amount)),
            ]
        case .invert(let amount):
            return [EffectPass(control: Self.control(kind: .invert, amount))]
        case .monochrome(let amount):
            return [EffectPass(control: Self.control(kind: .monochrome, amount))]
        case .vignette(let amount):
            return [EffectPass(control: Self.control(kind: .vignette, amount))]
        case .fringe(let amount):
            return [EffectPass(control: Self.control(kind: .fringe, amount))]
        case .adjust(let brightness, let contrast, let saturation):
            return [
                EffectPass(control: Self.control(kind: .adjust, brightness, contrast, saturation))
            ]
        case .custom(let shader):
            return [EffectPass(control: Self.control(kind: .copy), shader: shader)]
        }
    }

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
        kind: BuiltinEffectKind, _ p0: Float = 0, _ p1: Float = 0, _ p2: Float = 0,
        _ p3: Float = 0
    ) -> (SIMD4<Float>, SIMD4<Float>) {
        (SIMD4(kind.value, p0, p1, p2), SIMD4(p3, 0, 0, 0))
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

/// 組み込みの効果の種別番号。
///
/// **正本は `Shaders/Kinds.metal`** で、こちらは同じ数を名前で持つ写しである。写しを
/// 許しているのは、Swift と Metal が別の言語で同じ表を読む必要があるからで、割れたら
/// `KindLayoutTests` が赤くなる ([#802])。番号を足すときは両方へ足す。
///
/// **10 は欠番で、再利用してよい。** かつて中間段が使っていた番号で、[#755] が大きな
/// ぼかしを縮めた絵の上で回す形へ変えたときに空いた。飛んでいるのは歴史の跡であって、
/// 空き番号を避ける決まりがあるわけではない。
///
/// ``enlarge`` と ``accumulate`` は**利用者の並びには現れない** — 拡大は解像度の
/// 決め方の一部で、後処理の 1 つではない ([ADR-0015] 決定 1)。それでも通る道は同じ段
/// なので、番号はここで一緒に名乗る。この並びの外に置くと、組み込みの効果を 1 つ
/// 足したときに黙って衝突する。
///
/// [#755]: https://github.com/mokume-metal/mokume/issues/755
/// [#802]: https://github.com/mokume-metal/mokume/issues/802
/// [ADR-0015]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0015-metalfx-role.md
enum BuiltinEffectKind: UInt32, CaseIterable {
    /// そのまま写す。段の連なりの最後に 1 度だけ通る。
    case copy = 0
    case blurX = 1
    case blurY = 2
    case invert = 3
    case monochrome = 4
    case vignette = 5
    case fringe = 6
    case adjust = 7
    /// にじみ: 明るいところだけを取り出しながら縮める。
    case bloomExtract = 8
    /// にじみ: ぼかした明るいところを元へ足す。
    case bloomCombine = 9
    /// 描く細かさの絵を、出す細かさへ広げる。
    case enlarge = 11
    /// 拡大して、前のフレームの結果と混ぜる (時間方向)。
    case accumulate = 12
    /// 縮める / 広げる。大きなぼかしが縮めた絵の上で回るための段 ([#755])。
    case resize = 13

    /// 断片へ渡す形。設定の枠が `Float` なので、そこへ入る形で名乗る。
    var value: Float { Float(rawValue) }

    /// `Kinds.metal` での名前。検査が突き合わせる鍵になる。
    var metalName: String {
        switch self {
        case .copy: "kEffectCopy"
        case .blurX: "kEffectBlurX"
        case .blurY: "kEffectBlurY"
        case .invert: "kEffectInvert"
        case .monochrome: "kEffectMonochrome"
        case .vignette: "kEffectVignette"
        case .fringe: "kEffectFringe"
        case .adjust: "kEffectAdjust"
        case .bloomExtract: "kEffectBloomExtract"
        case .bloomCombine: "kEffectBloomCombine"
        case .enlarge: "kEffectEnlarge"
        case .accumulate: "kEffectAccumulate"
        case .resize: "kEffectResize"
        }
    }
}
