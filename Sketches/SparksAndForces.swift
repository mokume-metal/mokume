// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import mokume

/// 粒を大量に飛ばし、力で曲げる。
///
/// **見どころは、2 本の腕が「渦を描く命令」なしに出てくること。** 置いているのは、
/// 輪の上を向かい合って回る噴き口 2 つから**でたらめな向きへ**粒を出す命令だけである。
/// 腕の形も巻き方も 4 つの力の足し算から出ている — 引く力が内へ、渦が周りへ、抵抗が
/// 速さの上限を決め、弱い重力が上下の対称を崩す。
///
/// 巻くのは、**粒が回る速さと噴き口が回る速さが違う**からである。同じなら腕は伸びた
/// ままになり、渦だと分からない。
///
/// **どれか 1 つを外すと絵はまったく別のものになるが、止まった 1 枚では違いが読めない。**
/// 力は位置ではなく位置の変化に効くからである。抵抗を外せば粒は際限なく速くなって
/// 飛び散り、引く力を外せば渦の外へ流れ去る。
///
/// 種を `setup()` で決めてあるので、走らせるたびに同じ粒が同じ順に出る。時計はフレーム
/// 番号から導くので、**同じ番号のフレームは何度描いても同じ絵**になる。
final class SparksAndForces: Sketch {
    var settings = SketchSettings(width: 960, height: 540, title: "sparks and forces")

    /// 同時に持てる粒の数。**寿命が尽きた粒の枠は次の粒が使う**ので、
    /// 出す速さ × 寿命がこれを超えなければ足りる
    private let capacity = 24_000

    /// 渦の中心。**印を置くのは、粒が巻かれる理由をその場で読めるようにするため。**
    private let eye = (x: Float(480), y: Float(270))
    /// 噴き口が回る輪の半径。**釣り合う半径の近くに置く**ので、生まれた粒はすぐ腕に乗る。
    ///
    /// 釣り合いは 2 つの式で決まる。抵抗と渦が釣り合う速さが `渦 ÷ 抵抗`、その速さで
    /// 回り続けられる半径が `速さ² ÷ 引く力`。下の数はそこから逆に決めてある。
    private let ring: Float = 210

    private var sparks: Particles?

    func setup() {
        randomSeed(20_260_830)
        sparks = try? makeParticles(count: capacity)
    }

    func draw() {
        guard let sparks else { return }
        background(8, 10, 18)

        // 噴き口は 2 つ、輪の上を向かい合って回る。**出る向きはでたらめ**なので、
        // 腕の形は噴き口の動きではなく力のほうから出ている
        let sweep = time * 0.5
        noStroke()
        for side in 0..<2 {
            let angle = sweep + Float(side) * Float.pi
            emit(
                sparks, from: .point(eye.x + cos(angle) * ring, eye.y + sin(angle) * ring),
                rate: 800, speed: 30...90, angle: 0...(2 * Float.pi), life: 2.4...4,
                size: 1.5...4,
                color: color(255, 173, 71))
        }

        // **積んだぶんがまとめて効く。** 4 つのうちどれを外しても、絵は別物になる。
        // 抵抗は渦と釣り合って速さの上限を決めているので、外すと円盤が保てない
        force(
            sparks,
            .attract(eye.x, eye.y, strength: 420),
            .swirl(eye.x, eye.y, strength: 350),
            .drag(1.2),
            .gravity(0, 60))
        particles(sparks)

        // 渦の目と、粒が生まれる輪。**力と生まれる場所が見えていないと、
        // 円盤ができる理由が絵から読めない**
        noFill()
        stroke(115, 191, 255, 178)
        strokeWeight(1.5)
        circle(eye.x, eye.y, 72)
        circle(eye.x, eye.y, 18)
        stroke(102, 153, 230, 76)
        strokeWeight(1)
        circle(eye.x, eye.y, ring * 2)
        // 噴き口そのもの。**動いていることが 1 枚でも読める**ようにする
        stroke(255, 255, 255, 115)
        for side in 0..<2 {
            let angle = sweep + Float(side) * Float.pi
            circle(eye.x + cos(angle) * ring, eye.y + sin(angle) * ring, 16)
        }
    }
}
