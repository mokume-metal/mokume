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
///
/// ## 渦と抵抗を組むと、粒は 1 つの速さに揃う
///
/// 渦 (``swirl(_:_:strength:)``) も距離に依らない加速度なので、減速と組むと、粒は初速を
/// 忘れて**どの半径でもほぼ同じ速さ V** で回るようになる。V は `渦 ÷ 抵抗` に
/// x/(eˣ − 1) (x = 抵抗·Δt) を掛けた値で、`渦 ÷ 抵抗` そのものではない — 1 フレームごとに
/// 速度へ e^(−k·Δt) を掛ける進め方の釣り合いで、60 fps・抵抗 1.2 なら 1% 低い。
///
/// そこで**何が決まるかは、引く力の距離の法則で変わる。** 円く回り続けられるのは、
/// V² ÷ 半径 と引く力が釣り合う半径だけである:
///
/// - **距離に依らない引く力** (``attract(_:_:_:strength:weakeningBeyond:)`` の既定) — 釣り合う
///   半径は V² ÷ `strength` の 1 本で、ずれた粒はそこへ戻る。**長く回すと全粒がその 1 本の
///   輪へ集まり**、撒いた広がりが消える
/// - **`weakeningBeyond` (R) を渡した引く力** — R の外では V² ÷ 半径 と同じく半径に反比例して
///   弱まるので、`strength`·R = V² に合わせると **R の外のどの半径でもおおよそ釣り合い**、
///   撒いた広がりが残る。合っていなければ、ずれの割合に比例した速さで内か外へ流れる。
///   R の内側は距離に依らない引きなので、内側の粒は R の縁へ寄る
public enum Force: Equatable, Sendable {
    /// どこにいても同じ向きへ引く。**(x, y, z) がそのまま加速度**になる。
    case gravity(_ x: Float, _ y: Float, _ z: Float = 0)
    /// 1 点へ向かって引く。**強さを負にすると遠ざける**
    /// (``repel(_:_:_:strength:weakeningBeyond:)``)。
    ///
    /// 粒から (x, y, z) への向きへ、大きさ `strength` の加速度。`weakeningBeyond` を省くと
    /// **距離に依らない** — 近くても遠くても同じ強さで引く。
    ///
    /// `weakeningBeyond` に距離 R を渡すと、**R より遠い粒では距離に反比例して弱まる** —
    /// 距離 r の粒への大きさは、r が R 以内なら `strength`、R より遠ければ `strength`·R/r。
    /// 内側を弱めないのは、中心の近くで力が際限なく大きくならないようにするためである。
    /// 渦と抵抗を組んだときに輪 1 本へ集まらないようにするのに使う (上の「渦と抵抗を
    /// 組むと」)。R は 0 より大きい有限の値で、それ以外を渡すと注意を言って、弱まらない
    /// 力として効かせる。
    case attract(
        _ x: Float, _ y: Float, _ z: Float = 0, strength: Float, weakeningBeyond: Float? = nil)
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
    /// **``attract(_:_:_:strength:weakeningBeyond:)`` の符号を返すだけ** — 引くと押すは同じ
    /// 1 つの計算なので、枝を 2 本持たない。名前を 2 つ置いてあるのは、`strength` を負で書く
    /// より読みやすいためである。`weakeningBeyond` も同じ意味でそのまま渡る。
    public static func repel(
        _ x: Float, _ y: Float, _ z: Float = 0, strength: Float, weakeningBeyond: Float? = nil
    ) -> Force {
        .attract(x, y, z, strength: -strength, weakeningBeyond: weakeningBeyond)
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
        case .attract(let x, let y, let z, let strength, let distance):
            // **省いたら 0。** 0 は「弱まらない」と読まれ、いままでと同じ式を通る
            return [code, x, y, z, strength, distance ?? 0, 0, 0]
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
