// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import mokume

/// 不透明な板の前→後ろ→前を通る球を、固定視点と動く視点で比較する。
/// z>0は板より手前、z<0は奥。板が球を隠し、戻れば再び見える。
/// 球の名札はscreenX/Yで投影した位置へ置く2D文字で、球が隠れても位置の目印として残す。
/// 左上の画像とHUDは画面の位置を固定する。3Dの後で塗り・素材の口・視点を明示的に戻す。
/// `--render /tmp/depth --frames 210` の0〜209枚を60 fpsで見ると、約3.14秒で一往復する。
/// 入力は不要。全参照例の連番を出すので枚数と保存量に注意する。
/// 透明物体の自動ソートは要求しない。不透明な基準の遮蔽を先に確かめるため、ここには
/// 半透明物体を混ぜない。半透明稜線等の既知制約 (#1561・#2183〜#2185) を解消する例ではない。
final class DepthAndLabels: Sketch {
    private var panels: [Canvas] = []
    private var checker: Image!
    var settings: SketchSettings { SketchSettings(width: 1000, height: 500, title: "depth and labels") }

    func setup() throws {
        panels = try (0..<2).map { _ in try createGraphics(470, 400) }
        checker = try createImage(32, 32)
        for y in 0..<32 {
            for x in 0..<32 {
                checker.set(x, y, (x / 8 + y / 8) % 2 == 0 ? color(75, 140, 185) : color(30, 65, 110))
            }
        }
    }

    func draw() {
        background(16, 20, 28)
        for index in 0..<2 {
            draw(into: panels[index]) { scene(movingCamera: index == 1) }
            image(panels[index], 20 + index * 490, 40)
            fill(235)
            textSize(17)
            text(index == 0 ? "fixed camera" : "moving camera", 20 + index * 490, 25)
        }
        fill(235)
        text("Opaque board: z = 0. Orange sphere crosses front / back / front. HUD stays on screen.", 20, 475)
    }

    private func scene(movingCamera: Bool) {
        background(25, 30, 40)
        let cx = width / 2
        let cy = height / 2
        camera(cx + (movingCamera ? 170 * sin(time * 0.8) : 0), cy - 55, 520,
               cx, cy, 0, 0, 1, 0)
        perspective(Float.pi / 3, width / height, 10, 2000)
        lights()
        noStroke()
        push()
        translate(cx, cy, 0)
        fill(255)
        texture(checker)
        box(180, 140, 12)
        noTexture()
        pop()

        let z = 120 * cos(time * 2)
        push()
        translate(cx + 55 * sin(time * 2), cy, z)
        fill(255, 150, 45)
        shininess(80)
        metalness(0.3)
        sphere(26)
        let labelX = screenX(0, -42, 0)
        let labelY = screenY(0, -42, 0)
        pop()

        // 名札は投影した位置。HUDは固定の位置。どちらも2Dなので深度で隠さない。
        resetMatrix()
        camera()
        perspective()
        noLights()
        resetShader()
        noTexture()
        noTint()
        metalness(0)
        shininess(0)
        noStroke()
        fill(255)
        textSize(14)
        text("sphere", labelX - 22, labelY)
        image(checker, 10, 10, 24, 24)
        text("frame \(frameCount - 1) / z \(Int(z)) / \(z >= 0 ? "front" : "back")", 42, 28)
        text("board z=0 | +z toward viewer", 12, height - 18)
    }
}
