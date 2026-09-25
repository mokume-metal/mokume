// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

/// 粒に効く力。
///
/// 使い方は ``Sketch/force(_:_:)`` にある。**渡した順に効く。**
///
/// ## 力は加速度として足し合わさる
///
/// 減速 (``drag(_:)``) を除くどの力も**加速度** (1 秒あたりの速さの変化) を返し、効かせた
/// 力の分を足し合わせたものがその粒の加速度 a になる。粒は 1 フレームごとに、**先に速度を、
/// 進めた速度で位置を**進める (半陰的オイラー)。刻み Δt は ``Sketch/deltaTime``:
///
/// ```
/// v ← (v + a·Δt)·e^(−k·Δt)
/// x ← x + v·Δt
/// ```
///
/// k は減速の `amount` の和で、**減速だけは加速度として足さない** — 足し合わせた加速度で
/// 進めた速度に、最後に掛ける。そうすると、どれだけ強い減速でも速度の向きは変わらず、
/// 減速だけの粒の減り方がフレームレートに依らない。減速を渡さなければ掛けないので、
/// 1 行目は v ← v + a·Δt のままである。
///
/// 位置を先に進める形 (前進オイラー) とは、同じ力でも 1 フレームぶん位置が違う。
///
/// **散文の約束にしていない。** 検査がこの 2 行と各力の式を CPU で書き直し、GPU が
/// 進めた粒と照合している。
public enum Force: Equatable, Sendable {
    /// どこにいても同じ向きへ引く。**(x, y, z) がそのまま加速度**になる。
    case gravity(_ x: Float, _ y: Float, _ z: Float = 0)
    /// 1 点へ向かって引く。**強さを負にすると遠ざける** (``repel(_:_:_:strength:)``)。
    ///
    /// 粒から (x, y, z) への向きへ、大きさ `strength` の加速度。**距離に依らない** —
    /// 近くても遠くても同じ強さで引く。
    case attract(_ x: Float, _ y: Float, _ z: Float = 0, strength: Float)
    /// 粒ごとに違う向きへ揺らす。**同じ粒・同じフレームなら同じ揺れ**が出る。
    ///
    /// 加速度の各成分 (x・y・z) が、−`strength`…`strength` の一様な値になる。
    case wander(strength: Float)
    /// 1 点のまわりを回す (画面の面内)。
    ///
    /// (x, y) から粒への向き (面内) を **x 軸から y 軸へ 90° 回した向き**へ、大きさ
    /// `strength` の加速度。距離に依らず、奥行き (z) には効かない。y が下向きの画面では
    /// 時計回りになり、`strength` を負にすると逆へ回る。
    case swirl(_ x: Float, _ y: Float, strength: Float)
    /// 速さに逆らう。1 秒あたりに削る割合で、0 なら効かない。
    ///
    /// 1 フレームで速度は e^(−`amount`·Δt) 倍になる — 1 秒で e^(−`amount`) 倍で、
    /// **フレームレートに依らない**。どれだけ強くしても速度の向きは変わらず、速さは増えない
    /// (強いほど、その場に早く止まる)。ほかの力と組むと、それらで進めた速度に掛かる。
    case drag(_ amount: Float)

    /// 1 点から遠ざける。
    ///
    /// **``attract(_:_:_:strength:)`` の符号を返すだけ** — 引くと押すは同じ 1 つの計算なので、枝を
    /// 2 本持たない。名前を 2 つ置いてあるのは、`strength` を負で書くより読みやすい
    /// ためである。
    public static func repel(
        _ x: Float, _ y: Float, _ z: Float = 0, strength: Float
    ) -> Force {
        .attract(x, y, z, strength: -strength)
    }

    /// 置き場へ書く形。**先頭が種類**で、残りはその種類が読む。
    ///
    /// 並びは `Shaders/Computations/Particles.metal` の読み方と一致していなければ
    /// ならない。ずれても例外は出ず、力が別の力として効くだけなので、
    /// **番号の一致は `KindLayoutTests` が GPU 自身に書かせて見る** ([#802])。
    /// この関数の**並び** (どの枠に何を置くか) を見ているのは `ParticleTests` である。
    ///
    /// [#802]: https://github.com/mokume-metal/mokume/issues/802
    static let slotCount = 8

    var kind: ForceKind {
        switch self {
        case .gravity: .gravity
        case .attract: .attract
        case .wander: .wander
        case .swirl: .swirl
        case .drag: .drag
        }
    }

    var packed: [Float] {
        let code = Float(kind.rawValue)
        switch self {
        case .gravity(let x, let y, let z):
            return [code, x, y, z, 0, 0, 0, 0]
        case .attract(let x, let y, let z, let strength):
            return [code, x, y, z, strength, 0, 0, 0]
        case .wander(let strength):
            return [code, 0, 0, 0, strength, 0, 0, 0]
        case .swirl(let x, let y, let strength):
            return [code, x, y, 0, strength, 0, 0, 0]
        case .drag(let amount):
            return [code, 0, 0, 0, amount, 0, 0, 0]
        }
    }
}

/// 粒に掛ける力の種別番号。
///
/// **正本は `Shaders/Kinds.metal`** で、こちらは同じ数を名前で持つ写しである。写しを
/// 許しているのは、Swift と Metal が別の言語で同じ表を読む必要があるからで、割れたら
/// `KindLayoutTests` が赤くなる ([#802])。番号を足すときは両方へ足す。
///
/// [#802]: https://github.com/mokume-metal/mokume/issues/802
enum ForceKind: UInt32, CaseIterable {
    case gravity = 0
    case attract = 1
    case wander = 2
    case swirl = 3
    case drag = 4

    /// `Kinds.metal` での名前。検査が突き合わせる鍵になる。
    var metalName: String {
        switch self {
        case .gravity: "kForceGravity"
        case .attract: "kForceAttract"
        case .wander: "kForceWander"
        case .swirl: "kForceSwirl"
        case .drag: "kForceDrag"
        }
    }
}
