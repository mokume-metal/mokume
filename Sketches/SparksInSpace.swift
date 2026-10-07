// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation
import mokume

/// 粒を空間に飛ばし、視点を回して横から見る。
///
/// **見どころは、横から見ても粒が痩せないこと。** 粒 1 つは四角い板で、板は**視点の
/// ほうを向く** ([#1246](https://github.com/mokume-metal/mokume/issues/1246))。噴き口の
/// 円盤と線分は奥行き 0 の面の上にあるので、視点が真横へ回ると**案内の輪は 1 本の線に
/// 潰れる**が、そこから出た粒は四角のまま残る。止まった 1 枚では違いが読めないので、
/// `--frames` の連番で見る。
///
/// 噴き口は 3 つ。真ん中の**球** (`.sphere`) は奥行きを持つ場所から出るので、どこから
/// 見ても丸い雲になる。**円** (`.circle`) と**線** (`.line`) は面の上から出るので、
/// 視点を回すと形が薄くなる — 3 つを並べると、粒が空間のどこに居るかが形の変わり方で
/// 読める。
///
/// 力は 3 つ。真ん中から**押す力** (`.repel`) が雲を膨らませ、下から昇る幕を左右へ
/// 分ける。**揺らぎ** (`.wander`) は粒ごとに違う向きへ、**奥行きの向きにも**揺らすので、
/// 面から出た粒も少しずつ厚みを持つ。抵抗が速さの上限を決める。
///
/// 上の**星雲**は、出る場所ではなく**飛ぶ向き**が奥行きを持つ例である。1 点から全方位へ
/// (`toward: .sphere`) 撒くので、撒いた瞬間からどこから見ても丸い
/// ([#1042](https://github.com/mokume-metal/mokume/issues/1042))。面内の向き (`toward` を
/// 省いたとき) で撒くと、横から見て 1 本の線に潰れ、奥行きは揺らぎが後から少しずつ育てる
/// だけになる。押す力に流されないよう、星雲は別の群にして抵抗と揺らぎだけを効かせる —
/// 力は群ごとに積む。
///
/// 種を `setup()` で決めてあり、時計はフレーム番号から導くので、**同じ番号のフレームは
/// 何度描いても同じ絵**になる。
final class SparksInSpace: Sketch {
    var settings = SketchSettings(width: 960, height: 540, title: "sparks in space")

    /// 同時に持てる粒の数。3 つの噴き口の `rate × 寿命` の和より多く取る。
    private let capacity = 16_000

    /// 場面の中心。球の噴き口・押す力・視点の見る先がここに揃う。
    private let core = (x: Float(480), y: Float(270))
    /// 円の噴き口の半径。
    private let disc: Float = 230
    /// 線の噴き口の両端 (奥行き 0)。幕はここから上へ昇る。
    private let ground = (y: Float(450), from: Float(250), to: Float(710))
    /// 星雲の噴き口。中心の上の、**奥行き 0 の面から奥へずらした所**に置く — 円盤と幕は
    /// 奥行き 0 の面にあるので、真横から見ると 1 本の線に重なる。奥へずらせば、真横からでも
    /// 星雲がその線から離れて見える。
    private let nebulaAt = (x: Float(480), y: Float(120), z: Float(-200))

    private var sparks: Particles?
    private var nebula: Particles?

    func setup() {
        randomSeed(20_260_923)
        // 加算で光らせる。**混ぜ方は作った瞬間に粒へ焼き付く**ので、作る前に置いて戻す
        blendMode(.add)
        sparks = try? makeParticles(count: capacity)
        nebula = try? makeParticles(count: 2_400)
        blendMode(.blend)
    }

    func draw() {
        guard let sparks, let nebula else { return }
        background(6, 8, 14)

        // **視点を中心のまわりに回す。** 1.5 秒 (90 フレーム) で 4 分の 1 周を少し越え、
        // 終わり近くで円盤と幕を真横から見る
        let yaw = 0.35 + time * 0.9
        let distance = (height / 2) / tan(Float.pi / 6) * 1.1
        camera(
            core.x + distance * sin(yaw), core.y - distance * 0.1, distance * cos(yaw),
            core.x, core.y, 0, 0, 1, 0)

        // 球: 奥行きを持つ場所から出る。**どこから見ても丸い**
        emit(
            sparks, from: .sphere(core.x, core.y, 0, radius: 60),
            rate: 900, speed: 20...60, life: 1.5...3, size: 4...9,
            color: color(255, 180, 90))
        // 円: 奥行き 0 の円盤の内側から出る。**横から見ると薄くなる**
        emit(
            sparks, from: .circle(core.x, core.y, radius: disc),
            rate: 1500, speed: 0...10, life: 1.5...3, size: 2...5,
            color: color(110, 170, 255))
        // 線: 床の線分から上へ。向きは画面の面内 (`.plane`) なので、幕も奥行き 0 の面に立つ
        let up = -Float.pi / 2
        emit(
            sparks, from: .line(ground.from, ground.y, ground.to, ground.y),
            toward: .plane((up - 0.2)...(up + 0.2)), rate: 900, speed: 150...230, life: 2...3,
            size: 3...6, color: color(150, 255, 190))

        // **押す力は 3 次元で効く** — 球から出た粒は奥行きの向きにも押し出される。
        // 揺らぎも 3 つの向きに揺らすので、面から出た粒にも少しずつ厚みが付く
        force(
            sparks,
            .repel(core.x, core.y, 0, strength: 140),
            .wander(strength: 90),
            .drag(0.6))
        particles(sparks)

        // 星雲: 1 点から全方位へ。**向きが奥行きを持つ**ので、場所は 1 点でも丸く広がる。
        // 抵抗で止まるので、広がりは速さ ÷ 抵抗 (およそ 50〜80) で収まる
        emit(
            nebula, from: .point(nebulaAt.x, nebulaAt.y, nebulaAt.z), toward: .sphere,
            rate: 900, speed: 60...100, life: 1.2...2.4, size: 2...5,
            color: color(200, 150, 255))
        force(nebula, .wander(strength: 25), .drag(1.2))
        particles(nebula)

        // 案内の輪と床の線。**立体の線として置く**ので視点を通り、真横から見ると潰れる。
        // 潰れた輪の上に四角い粒が残るのが、板が視点を向いている証拠である
        noFill()
        stroke(140, 180, 255, 120)
        strokeWeight(1.5)
        beginShape()
        for index in 0..<96 {
            let angle = Float(index) / 96 * 2 * Float.pi
            vertex(core.x + cos(angle) * disc, core.y + sin(angle) * disc, 0)
        }
        endShape(.close)
        stroke(150, 255, 190, 150)
        beginShape(.lines)
        vertex(ground.from, ground.y, 0)
        vertex(ground.to, ground.y, 0)
        endShape()

        // 字は画面に貼り付けて読みたいので、視点を戻してから書く
        camera()
        noStroke()
        fill(220, 226, 236)
        textFont("Helvetica")
        textSize(16)
        text("視点 \(Int((yaw * 180 / Float.pi).rounded()))°", 24, 36)
    }
}
