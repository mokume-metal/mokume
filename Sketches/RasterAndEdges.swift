// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import mokume

/// 効果なしで、細い線と小数座標を比較するチャート。
///
/// `raster-and-edges` / `raster-and-edges-075` / `raster-and-edges-050` は同じ描画本体で、
/// 起動時の pixelDensity だけが 1 / 0.75 / 0.5。途中では変えない。
/// 各マスの上は静止、下は毎フレーム1/120画素ずつ右下へ移動し、120枚で戻る。
/// `--render /tmp/edges --frames 120` を60 fpsで見ると、特に幅0.5の明るさの跳びを追える。
/// 全参照例の連番が出るので、保存量に注意する。
///
/// 行は太さ、列は座標の小数部。基本図形 / 単色shader指定 / 白いtexture指定を並べる。
/// 線・点の濃さは太さと覆う面積で読む。細い形が突然不透明な1画素へ跳ぶかを観察する。
/// 低密度は拡大によるぼけ・格子への丸めも見える。三角形で描く経路に、基本図形と同じ
/// AAや全画素一致を要求する表ではない。既知の細線の制約 (#2172・#2427・#3242) は残る。
final class RasterAndEdges: Sketch {
    private let density: Float
    private var white: Image?
    private var solid: Shader?

    init() { density = 1 }
    init(density: Float) { self.density = density }

    var settings: SketchSettings {
        SketchSettings(width: 1200, height: 920, title: "raster and edges", pixelDensity: density)
    }

    func setup() throws {
        let image = try createImage(2, 2)
        image.fill(color(255))
        white = image
        solid = try makeShader("""
            float4 paint(Fragment in, Values values) { return float4(1.0); }
            """)
    }

    func draw() {
        background(18)
        noStroke()
        fill(230)
        textSize(16)
        let drift = Float((frameCount - 1) % 120) / 120
        text("density \(density) | \(pixelWidth)x\(pixelHeight) | moving offset \(drift)", 20, 25)
        text("Each cell: static above / moving below. No effects. Width rows; coordinate offset columns.", 20, 49)
        for (path, label) in ["plain", "shader: white", "texture: white"].enumerated() {
            let left = Float(path * 400)
            fill(230)
            noStroke()
            text(label, left + 20, 78)
            for (column, offset) in [Float(0), 0.25, 0.5, 0.75].enumerated() {
                text("+\(offset)", left + 65 + Float(column * 80), 100)
            }
            for (row, weight) in [Float(0.25), 0.5, 1, 2].enumerated() {
                let top = Float(120 + row * 195)
                fill(150)
                noStroke()
                text("w\(weight)", left + 5, top + 15)
                for (column, offset) in [Float(0), 0.25, 0.5, 0.75].enumerated() {
                    for (moving, y) in [Float(0), 90].enumerated() {
                        push()
                        let shift = offset + (moving == 1 ? drift : 0)
                        translate(left + 65 + Float(column * 80) + shift, top + y + shift)
                        if path == 1, let solid { shader(solid) }
                        if path == 2, let white { texture(white) }
                        sample(weight)
                        noTexture()
                        resetShader()
                        pop()
                    }
                }
            }
        }
    }

    private func sample(_ weight: Float) {
        stroke(255)
        strokeWeight(weight)
        line(2, 6, 26, 6)
        line(34, 0, 34, 16)
        line(2, 20, 26, 34)
        point(38, 27)
        noFill()
        circle(12, 52, 20)
        ellipse(38, 52, 22, 14)
        noStroke()
        fill(255)
        rect(2, 70, 40, weight)
    }
}
