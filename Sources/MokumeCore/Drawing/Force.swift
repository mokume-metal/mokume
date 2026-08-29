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
    /// **``attract`` の符号を返すだけ** — 引くと押すは同じ 1 つの計算なので、枝を
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
    /// **一致は検査が見る** (`ParticleTests`)。
    static let slotCount = 8

    var packed: [Float] {
        switch self {
        case .gravity(let x, let y, let z):
            return [0, x, y, z, 0, 0, 0, 0]
        case .attract(let x, let y, let z, let strength):
            return [1, x, y, z, strength, 0, 0, 0]
        case .wander(let strength):
            return [2, 0, 0, 0, strength, 0, 0, 0]
        case .swirl(let x, let y, let strength):
            return [3, x, y, 0, strength, 0, 0, 0]
        case .drag(let amount):
            return [4, 0, 0, 0, amount, 0, 0, 0]
        }
    }
}
