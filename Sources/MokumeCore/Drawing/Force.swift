// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

/// 粒に効く力。
///
/// 使い方は ``Sketch/force(_:_:)`` にある。**渡した順に効く。**
public enum Force: Equatable, Sendable {
    /// どこにいても同じ向きへ引く。
    case gravity(_ x: Float, _ y: Float, _ z: Float = 0)
    /// 1 点へ向かって引く。**強さを負にすると遠ざける** (``repel(_:_:_:strength:)``)。
    case attract(_ x: Float, _ y: Float, _ z: Float = 0, strength: Float)
    /// 粒ごとに違う向きへ揺らす。**同じ粒・同じフレームなら同じ揺れ**が出る。
    case wander(strength: Float)
    /// 1 点のまわりを回す (画面の面内)。
    case swirl(_ x: Float, _ y: Float, strength: Float)
    /// 速さに逆らう。1 秒あたりに削る割合で、0 なら効かない。
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
