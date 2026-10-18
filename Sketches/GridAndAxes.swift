// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import mokume

/// 床に格子と軸を置いた見下ろしの場面で、漂う粒の速度を短い線で描く
/// ([#2462](https://github.com/mokume-metal/mokume/issues/2462))。
///
/// **見どころは、立体の空間の向きが目印で読めること。** `debugMode()` が面の中心・奥行き 0 に
/// 床の格子と 3 本の軸を出す。x が赤・y が緑・z が青で、**緑の軸は画面の下へ伸びる** — 縦軸が
/// 下向きであることの印である。粒は格子の上の空間を回り、位置を `point(x, y, z)`、速度を
/// `line(x1, y1, z1, x2, y2, z2)` で描く。どちらも 6 つ・3 つの数で書くので視点を通り、
/// 2 つ・4 つの数の平面の図形とは違って、回すと奥行きに沿って動いて見える。
///
/// 引きずると回り、スクロールで寄る (`orbitControl()`)。始まりは少し見下ろす位置へ置いて
/// ある (`orbit`) — 真横からだと格子が 1 本の線に潰れる。`g` を押している間は目印を隠す
/// (`noDebugMode()` を後に書くと、同じフレームの `debugMode()` を打ち消す)。
///
/// 種を `setup()` で決めてあり、時計はフレーム番号から導くので、**同じ番号のフレームは
/// 何度描いても同じ絵**になる。
final class GridAndAxes: Sketch {
    var settings: SketchSettings {
        SketchSettings(width: 960, height: 540, title: "grid and axes")
    }

    /// 粒 1 つ。中心のまわりを回る円の半径・高さ・位相・速さで持つ。
    private struct Mote {
        var radius: Float
        var height: Float
        var phase: Float
        var speed: Float
    }

    private var motes: [Mote] = []

    func setup() {
        randomSeed(20_261_018)
        // 格子の上の空間 (縦軸は下向きなので、上は負の y)
        motes = (0..<60).map { _ in
            Mote(
                radius: random(40, 230), height: random(-160, -20),
                phase: random(0, 2 * Float.pi), speed: random(0.4, 1.1))
        }
        // 少し見下ろし、斜めから見る
        orbit.pitch = 0.45
        orbit.yaw = 0.6
    }

    func draw() {
        background(14, 16, 22)
        orbitControl()
        debugMode()
        // g を押している間は隠す
        if keyboard.isPressed(.g) { noDebugMode() }

        let center = (x: width / 2, y: height / 2)
        for mote in motes {
            let angle = mote.phase + time * mote.speed
            let x = center.x + cos(angle) * mote.radius
            let z = sin(angle) * mote.radius
            let y = center.y + mote.height + sin(time * 1.3 + mote.phase) * 12
            // 速度 (円の接線の向き)。見えるよう 0.35 秒ぶんの長さで引く
            let vx = -sin(angle) * mote.radius * mote.speed * 0.35
            let vz = cos(angle) * mote.radius * mote.speed * 0.35
            stroke(255, 180, 90)
            strokeWeight(2)
            line(x, y, z, x + vx, y, z + vz)
            stroke(255, 236, 200)
            strokeWeight(7)
            point(x, y, z)
        }
    }
}
