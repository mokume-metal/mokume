// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import mokume

/// 勾配の座標、保持した形、shaderの優先、push/popによる復元を比較する。
/// 上段の白いstrokeは勾配にならない。目盛りは停止位置0/.5/1。
/// 中段左は変換してからfill、中央はfillしてから変換。後者の勾配は後の回転には付いてこない。
/// 右の保持形は内部の勾配も回る。緑を記録した形は外の勾配で塗り替わらない (SVGも同じ)。
/// A/Bは位置以外を揃え、間のpush内で変えた塗り・tint・clip・変換が漏れないかを見る。
/// shaderはpush/popの保存対象外なので、pop後にresetShaderで明示的に解除する。
/// pushStyleはスタイルだけ、pushMatrixは変換だけ。ここでは両方を戻すpush/popを使う。
/// fillやtintはフレームを越えるので毎回基準を置く。effectsのように毎フレーム消える状態とは違う。
/// `--render /tmp/gradients --frames 120` を60 fpsで再生し、回転と勾配の関係を見る (全例出力)。
final class GradientsAndState: Sketch {
    private var retained = Shape.empty
    private var colored = Shape.empty
    private var white: Image!
    private var red: Shader!
    var settings: SketchSettings { SketchSettings(width: 1040, height: 860, title: "gradients and state") }

    private func ramp(from: Vector2, to: Vector2) -> Gradient {
        .linearGradient((color(255, 130, 45), 0), (color(60, 210, 230), 0.5),
                        (color(160, 65, 230), 1), from: from, to: to)
    }

    func setup() throws {
        white = try createImage(20, 20)
        white.fill(color(255))
        red = try makeShader("float4 paint(Fragment in, Values values) { return float4(1,0,0,1); }")
        retained = createShape {
            noStroke()
            fill(ramp(from: [-70, 0], to: [70, 0]))
            rect(-70, -40, 140, 80)
        }
        colored = createShape {
            noStroke()
            fill(50, 220, 100)
            rect(-45, -30, 90, 60)
        }
    }

    func draw() {
        background(20, 23, 30)
        resetShader()
        noTexture()
        noTint()
        noClip()
        for index in 0..<2 {
            push()
            translate(30 + index * 500, 45)
            stroke(245)
            strokeWeight(2)
            if index == 0 { fill(ramp(from: [0, 0], to: [300, 0])) }
            else {
                fill(.radialGradient((color(255, 130, 45), 0), (color(60, 210, 230), 0.5),
                                     (color(160, 65, 230), 1), center: [150, 22], radius: 150))
            }
            rect(0, 0, 300, 45)
            circle(45, 100, 65)
            textSize(30)
            text("Gradient", 100, 112)
            noStroke()
            fill(235)
            textSize(16)
            text(index == 0 ? "linear + white stroke" : "radial + white stroke", 0, -15)
            for (i, position) in [Float(0), 150, 300].enumerated() {
                let x = index == 0 ? position : 150 + position / 2
                stroke(220)
                line(x, 140, x, 148)
                noStroke()
                text(["0", "0.5", "1"][i], x, 168)
            }
            pop()
        }

        let angle = sin(time * 2) * 0.4
        push()
        translate(50, 300)
        rotate(angle)
        noStroke()
        fill(ramp(from: [0, 0], to: [180, 0]))
        rect(0, -40, 180, 80)
        pop()
        push()
        fill(ramp(from: [360, 300], to: [540, 300]))
        translate(360, 300)
        rotate(angle)
        noStroke()
        rect(0, -40, 180, 80)
        pop()
        push()
        translate(800, 300)
        rotate(time)
        shape(retained)
        pop()
        label("transform > fill", 30, 390)
        label("fill > transform", 350, 390)
        label("retained gradient rotates", 690, 390)

        noStroke()
        fill(ramp(from: [0, 440], to: [0, 550]))
        baseline(90)
        push()
        fill(255, 0, 0)
        fill(.radialGradient((color(255), 0), (color(255, 0, 0), 1), center: [300, 495], radius: 60))
        tint(255, 0, 0)
        clip(260, 455, 75, 70)
        shader(red)
        translate(300, 495)
        rotate(0.4)
        circle(0, 0, 100)
        pop()
        resetShader() // shaderはpush/popの保存対象外。塗り・tint・clip・変換はpopで戻る。
        baseline(490)
        // popでclipも戻る。この印は上の枠の外にある。
        fill(255, 220, 70)
        square(610, 490, 16)
        fill(ramp(from: [720, 470], to: [860, 470]))
        shape(colored, 800, 495)
        label("A", 80, 580)
        label("inside push: red / clip", 245, 580)
        label("B: pop + resetShader", 430, 580)
        label("recorded green stays green", 690, 580)

        fill(ramp(from: [0, 670], to: [0, 780]))
        shader(red)
        circle(100, 720, 100)
        resetShader()
        circle(400, 720, 100)
        fill(50, 220, 100)
        circle(740, 720, 100)
        label("shader wins", 30, 810)
        label("resetShader: gradient returns", 280, 810)
        label("solid fill removes gradient", 650, 810)
    }

    private func baseline(_ x: Float) {
        circle(x, 495, 100)
        image(white, x + 60, 485) // tintの復元も白で分かる
    }

    private func label(_ caption: String, _ x: Float, _ y: Float) {
        pushStyle()
        noStroke()
        fill(235)
        textSize(16)
        text(caption, x, y)
        popStyle()
    }
}
