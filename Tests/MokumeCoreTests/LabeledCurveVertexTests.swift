// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Testing

@testable import MokumeCore

/// ベジェ曲線と UV を取る `vertex` のラベル付きの形 ([#3781]・[#3782])。GPU を要する。
///
/// 約束は、**ラベル付きの形に位置の形と同じ値を渡すと、描いた絵が 1 ビットも違わない**こと。
/// 中継の口 (`Sketch`) と `Canvas` の直の呼び出しの**両方**で見る。曲線は形の頂点へ刻まれて
/// 描かれるので、絵の一致は置いた頂点の一致を含む。
///
/// **値は座標がどれも違うもの**にして、点や成分の取り違えが絵に出るようにした。UV は貼る絵が
/// 無いと絵に出ないので、画素ごとに色の違う絵を貼ってから置く。どの組も「何も描いていない絵」と
/// 違うことを先に確かめる。
///
/// [#3781]: https://github.com/mokume-metal/mokume/issues/3781
/// [#3782]: https://github.com/mokume-metal/mokume/issues/3782
@Suite(
    "ベジェ曲線と UV を取る vertex のラベル付きの形",
    .enabled(
        if: RenderDevice.isAvailable,
        "この世代のコマンド構造に対応した GPU が無い実行環境ではスキップする")
)
struct LabeledCurveVertexTests {
    final class Stage: Sketch {
        var settings: SketchSettings { SketchSettings(width: 64, height: 48) }
        var scene: (Stage) -> Void = { _ in }
        init() {}
        func draw() { scene(self) }
    }

    /// 1 フレームだけ描いて、面の画素をビット列で返す。
    private func picture(_ gpu: RenderDevice, _ body: @escaping (Stage) -> Void) throws -> [UInt16] {
        let stage = Stage()
        stage.scene = { stage in
            stage.background(10, 12, 16)
            stage.stroke(230, 128, 64)
            stage.strokeWeight(3)
            stage.fill(64, 160, 230)
            body(stage)
        }
        let runtime = try SketchRuntime(sketch: stage, gpu: gpu, clock: nil, now: { 0 })
        try runtime.advance()
        return try runtime.target.readPixels().components.map(\.bitPattern)
    }

    private func differing(_ one: [UInt16], _ other: [UInt16]) -> Int {
        zip(one, other).count { $0.0 != $0.1 } + abs(one.count - other.count)
    }

    /// ラベル付きの形で描いた絵と、位置の形で描いた絵が同じで、何かを描いていること。
    private func agree(
        _ name: String,
        labeled: @escaping (Stage) -> Void,
        positional: @escaping (Stage) -> Void,
        sourceLocation: SourceLocation = #_sourceLocation
    ) throws {
        let gpu = try RenderDevice()
        let blank = try picture(gpu) { _ in }
        let expected = try picture(gpu, positional)
        let actual = try picture(gpu, labeled)
        #expect(differing(expected, blank) > 0, "\(name): 位置の形で描いた絵が空", sourceLocation: sourceLocation)
        let count = differing(actual, expected)
        #expect(count == 0, "\(name): ラベル付きの形の絵が位置の形と \(count) 成分違う", sourceLocation: sourceLocation)
    }

    /// 画素ごとに色の違う 8x6 の絵。横へ進むと赤が、縦へ進むと緑が増える。
    private static func gradient(on canvas: Canvas) -> Image? {
        guard let image = creating({ try canvas.createImage(8, 6) }) else { return nil }
        for y in 0..<6 {
            for x in 0..<8 {
                image.set(x, y, .linear(red: Float(x) / 7, green: Float(y) / 5, blue: 0.5))
            }
        }
        return image
    }

    // MARK: - bezier(from:control1:control2:to:) (#3781)

    @Test("bezier(from:control1:control2:to:) は bezier(8 つの数) と同じ絵")
    func bezierMatches() throws {
        // 8 つの数がどれも違うので、点や成分の取り違えが曲線の形に出る
        try agree(
            "Sketch",
            labeled: { $0.bezier(from: Vector2(6, 40), control1: Vector2(14, 5), control2: Vector2(52, 12), to: Vector2(59, 44)) },
            positional: { $0.bezier(6, 40, 14, 5, 52, 12, 59, 44) })
        try agree(
            "Canvas",
            labeled: {
                $0.canvas.bezier(from: Vector2(6, 40), control1: Vector2(14, 5), control2: Vector2(52, 12), to: Vector2(59, 44))
            },
            positional: { $0.canvas.bezier(6, 40, 14, 5, 52, 12, 59, 44) })
    }

    @Test("Issue の例: bezier(from: (40, 200) …) は位置の形と同じ曲線")
    func bezierIssueExample() throws {
        // 面 64x48 に収まるように 1/6 に縮めて描く。縮めても値はそのまま渡す
        try agree(
            "Issue の例",
            labeled: { stage in
                stage.scale(Float(1) / 6)
                stage.bezier(from: Vector2(40, 200), control1: Vector2(120, 40), control2: Vector2(280, 40), to: Vector2(360, 200))
            },
            positional: { stage in
                stage.scale(Float(1) / 6)
                stage.bezier(40, 200, 120, 40, 280, 40, 360, 200)
            })
    }

    // MARK: - bezierVertex(control1:control2:to:)・quadraticVertex(control:to:) (#3781)

    @Test("形の中の bezierVertex(control1:control2:to:) は bezierVertex(6 つの数) と同じ形")
    func bezierVertexMatches() throws {
        try agree(
            "Sketch",
            labeled: { stage in
                stage.beginShape()
                stage.vertex(6, 10)
                stage.bezierVertex(control1: Vector2(50, 4), control2: Vector2(60, 38), to: Vector2(12, 44))
                stage.endShape(.close)
            },
            positional: { stage in
                stage.beginShape()
                stage.vertex(6, 10)
                stage.bezierVertex(50, 4, 60, 38, 12, 44)
                stage.endShape(.close)
            })
        try agree(
            "Canvas",
            labeled: { stage in
                let canvas = stage.canvas
                canvas.beginShape()
                canvas.vertex(6, 10)
                canvas.bezierVertex(control1: Vector2(50, 4), control2: Vector2(60, 38), to: Vector2(12, 44))
                canvas.endShape(.close)
            },
            positional: { stage in
                let canvas = stage.canvas
                canvas.beginShape()
                canvas.vertex(6, 10)
                canvas.bezierVertex(50, 4, 60, 38, 12, 44)
                canvas.endShape(.close)
            })
    }

    @Test("形の中の quadraticVertex(control:to:) は quadraticVertex(4 つの数) と同じ形")
    func quadraticVertexMatches() throws {
        try agree(
            "Sketch",
            labeled: { stage in
                stage.beginShape()
                stage.vertex(6, 10)
                stage.quadraticVertex(control: Vector2(55, 7), to: Vector2(14, 42))
                stage.endShape(.close)
            },
            positional: { stage in
                stage.beginShape()
                stage.vertex(6, 10)
                stage.quadraticVertex(55, 7, 14, 42)
                stage.endShape(.close)
            })
        try agree(
            "Canvas",
            labeled: { stage in
                let canvas = stage.canvas
                canvas.beginShape()
                canvas.vertex(6, 10)
                canvas.quadraticVertex(control: Vector2(55, 7), to: Vector2(14, 42))
                canvas.endShape(.close)
            },
            positional: { stage in
                let canvas = stage.canvas
                canvas.beginShape()
                canvas.vertex(6, 10)
                canvas.quadraticVertex(55, 7, 14, 42)
                canvas.endShape(.close)
            })
    }

    @Test("始点の無い bezierVertex・quadraticVertex は、位置の形と同じく何も足さない")
    func curveWithoutStartAddsNothingAlike() throws {
        // 始点の無い曲線は足されず、残りの 3 点の三角形だけが描かれる
        try agree(
            "bezierVertex",
            labeled: { stage in
                stage.beginShape()
                stage.bezierVertex(control1: Vector2(50, 4), control2: Vector2(60, 38), to: Vector2(12, 44))
                stage.vertex(6, 10)
                stage.vertex(40, 8)
                stage.vertex(30, 40)
                stage.endShape(.close)
            },
            positional: { stage in
                stage.beginShape()
                stage.bezierVertex(50, 4, 60, 38, 12, 44)
                stage.vertex(6, 10)
                stage.vertex(40, 8)
                stage.vertex(30, 40)
                stage.endShape(.close)
            })
        try agree(
            "quadraticVertex",
            labeled: { stage in
                stage.beginShape()
                stage.quadraticVertex(control: Vector2(55, 7), to: Vector2(14, 42))
                stage.vertex(6, 10)
                stage.vertex(40, 8)
                stage.vertex(30, 40)
                stage.endShape(.close)
            },
            positional: { stage in
                stage.beginShape()
                stage.quadraticVertex(55, 7, 14, 42)
                stage.vertex(6, 10)
                stage.vertex(40, 8)
                stage.vertex(30, 40)
                stage.endShape(.close)
            })
    }

    // MARK: - vertex(_:uv:) (#3782)

    @Test("vertex(Vector2, uv:) は vertex(x, y, u, v) と同じ頂点")
    func flatVertexWithUVMatches() throws {
        // 読み取り位置の u と v は違う値にして、取り違えが貼った絵に出るようにする
        let corners: [(Vector2, Vector2)] = [
            (Vector2(6, 40), Vector2(0, 6)), (Vector2(58, 34), Vector2(8, 5)),
            (Vector2(50, 4), Vector2(7, 0)), (Vector2(10, 9), Vector2(1, 2)),
        ]
        try agree(
            "Sketch",
            labeled: { stage in
                guard let picture = Self.gradient(on: stage.canvas) else { return }
                stage.noStroke()
                stage.texture(picture)
                stage.beginShape()
                for (point, uv) in corners { stage.vertex(point, uv: uv) }
                stage.endShape(.close)
            },
            positional: { stage in
                guard let picture = Self.gradient(on: stage.canvas) else { return }
                stage.noStroke()
                stage.texture(picture)
                stage.beginShape()
                for (point, uv) in corners { stage.vertex(point.x, point.y, uv.x, uv.y) }
                stage.endShape(.close)
            })
        try agree(
            "Canvas",
            labeled: { stage in
                let canvas = stage.canvas
                guard let picture = Self.gradient(on: canvas) else { return }
                canvas.noStroke()
                canvas.texture(picture)
                canvas.beginShape()
                for (point, uv) in corners { canvas.vertex(point, uv: uv) }
                canvas.endShape(.close)
            },
            positional: { stage in
                let canvas = stage.canvas
                guard let picture = Self.gradient(on: canvas) else { return }
                canvas.noStroke()
                canvas.texture(picture)
                canvas.beginShape()
                for (point, uv) in corners { canvas.vertex(point.x, point.y, uv.x, uv.y) }
                canvas.endShape(.close)
            })
    }

    @Test("vertex(Vector3, uv:) は vertex(x, y, z, u, v) と同じ頂点")
    func solidVertexWithUVMatches() throws {
        // Issue の例 vertex(Vector3(0, 0, 0), uv: Vector2(0, 1)) を 1 つ目の頂点に含める
        let corners: [(Vector3, Vector2)] = [
            (Vector3(0, 0, 0), Vector2(0, 1)), (Vector3(58, 6, -20), Vector2(8, 2)),
            (Vector3(30, 44, -9), Vector2(3, 6)),
        ]
        try agree(
            "Sketch",
            labeled: { stage in
                guard let picture = Self.gradient(on: stage.canvas) else { return }
                stage.noStroke()
                stage.texture(picture)
                stage.beginShape(.triangles)
                for (point, uv) in corners { stage.vertex(point, uv: uv) }
                stage.endShape()
            },
            positional: { stage in
                guard let picture = Self.gradient(on: stage.canvas) else { return }
                stage.noStroke()
                stage.texture(picture)
                stage.beginShape(.triangles)
                for (point, uv) in corners { stage.vertex(point.x, point.y, point.z, uv.x, uv.y) }
                stage.endShape()
            })
        try agree(
            "Canvas",
            labeled: { stage in
                let canvas = stage.canvas
                guard let picture = Self.gradient(on: canvas) else { return }
                canvas.noStroke()
                canvas.texture(picture)
                canvas.beginShape(.triangles)
                for (point, uv) in corners { canvas.vertex(point, uv: uv) }
                canvas.endShape()
            },
            positional: { stage in
                let canvas = stage.canvas
                guard let picture = Self.gradient(on: canvas) else { return }
                canvas.noStroke()
                canvas.texture(picture)
                canvas.beginShape(.triangles)
                for (point, uv) in corners { canvas.vertex(point.x, point.y, point.z, uv.x, uv.y) }
                canvas.endShape()
            })
    }

    @Test("数でない読み取り位置は、位置の形と同じく書かれていないことになる")
    func notANumberUVIsDroppedAlike() throws {
        let corners: [(Vector2, Vector2)] = [
            (Vector2(6, 40), Vector2(Float.nan, 6)), (Vector2(58, 34), Vector2(8, 5)), (Vector2(50, 4), Vector2(7, 0)),
        ]
        try agree(
            "Sketch",
            labeled: { stage in
                guard let picture = Self.gradient(on: stage.canvas) else { return }
                stage.noStroke()
                stage.texture(picture)
                stage.beginShape()
                for (point, uv) in corners { stage.vertex(point, uv: uv) }
                stage.endShape(.close)
            },
            positional: { stage in
                guard let picture = Self.gradient(on: stage.canvas) else { return }
                stage.noStroke()
                stage.texture(picture)
                stage.beginShape()
                for (point, uv) in corners { stage.vertex(point.x, point.y, uv.x, uv.y) }
                stage.endShape(.close)
            })
    }
}
