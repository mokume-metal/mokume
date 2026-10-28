// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Testing

@testable import MokumeCore

/// 描画・変換の口に `Vector2` / `Vector3` を直に渡す口 ([#3360])。GPU を要する。
///
/// 約束は、**ベクトルで渡した絵・変換が、成分を取り出して数で渡したものと 1 ビットも違わない**こと。
/// 中継の口 (`Sketch`) と `Canvas` の直の呼び出しの**両方**で見る。ベクトルの口が `x` と `y` を
/// 取り違えても、`Canvas` の数の口を見る既存の検査は赤くならないので、ここで絵を突き合わせる。
///
/// **値は x と y (と z) がどれも違うもの**にして、成分の取り違えが絵に出るようにした。何も描かない口が
/// 緑になるのを避けるため、どの組も「何も描いていない絵」と違うことを先に確かめる。
///
/// [#3360]: https://github.com/mokume-metal/mokume/issues/3360
@Suite(
    "Vector2 / Vector3 を受ける描画・変換の口",
    .enabled(
        if: RenderDevice.isAvailable,
        "この世代のコマンド構造に対応した GPU が無い実行環境ではスキップする")
)
struct VectorArgumentsTests {
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

    /// ベクトルで渡した場面と、数で渡した場面が同じ絵で、何かを描いていること。
    private func agree(
        _ name: String,
        vector: @escaping (Stage) -> Void,
        scalar: @escaping (Stage) -> Void,
        sourceLocation: SourceLocation = #_sourceLocation
    ) throws {
        let gpu = try RenderDevice()
        let blank = try picture(gpu) { _ in }
        let expected = try picture(gpu, scalar)
        let actual = try picture(gpu, vector)
        #expect(differing(expected, blank) > 0, "\(name): 数で描いた絵が空", sourceLocation: sourceLocation)
        let count = differing(actual, expected)
        #expect(count == 0, "\(name): ベクトルの口の絵が数の口と \(count) 成分違う", sourceLocation: sourceLocation)
    }

    // MARK: - 中継の口 (Sketch)

    @Test("circle(Vector2, d) は circle(x, y, d) と同じ絵")
    func circleThroughSketch() throws {
        let center = Vector2(40, 17)
        try agree(
            "circle", vector: { $0.circle(center, 22) }, scalar: { $0.circle(40, 17, 22) })
    }

    @Test("point(Vector2)・point(Vector3) は数の口と同じ絵")
    func pointThroughSketch() throws {
        try agree("point2", vector: { $0.point(Vector2(40, 17)) }, scalar: { $0.point(40, 17) })
        try agree(
            "point3",
            vector: { $0.point(Vector3(40, 17, -30)) },
            scalar: { $0.point(40, 17, -30) })
    }

    @Test("line(Vector2, Vector2)・line(Vector3, Vector3) は数の口と同じ絵")
    func lineThroughSketch() throws {
        try agree(
            "line2",
            vector: { $0.line(Vector2(6, 38), Vector2(58, 9)) },
            scalar: { $0.line(6, 38, 58, 9) })
        try agree(
            "line3",
            vector: { $0.line(Vector3(6, 38, 0), Vector3(58, 9, -20)) },
            scalar: { $0.line(6, 38, 0, 58, 9, -20) })
    }

    @Test("translate(Vector2)・translate(Vector3) は数の口と同じ変換")
    func translateThroughSketch() throws {
        try agree(
            "translate2",
            vector: { stage in
                stage.translate(Vector2(30, 11))
                stage.rect(0, 0, 14, 9)
            },
            scalar: { stage in
                stage.translate(30, 11)
                stage.rect(0, 0, 14, 9)
            })
        try agree(
            "translate3",
            vector: { stage in
                stage.lights()
                stage.translate(Vector3(30, 11, -25))
                stage.box(12, 8, 6)
            },
            scalar: { stage in
                stage.lights()
                stage.translate(30, 11, -25)
                stage.box(12, 8, 6)
            })
    }

    @Test("vertex(Vector2)・vertex(Vector3) は数の口と同じ形")
    func vertexThroughSketch() throws {
        let corners = [Vector2(6, 38), Vector2(58, 12), Vector2(33, 5)]
        try agree(
            "vertex2",
            vector: { stage in
                stage.beginShape()
                for corner in corners { stage.vertex(corner) }
                stage.endShape(.close)
            },
            scalar: { stage in
                stage.beginShape()
                for corner in corners { stage.vertex(corner.x, corner.y) }
                stage.endShape(.close)
            })
        try agree(
            "vertex3",
            vector: { stage in
                stage.beginShape(.lines)
                stage.vertex(Vector3(6, 38, 0))
                stage.vertex(Vector3(58, 9, -20))
                stage.endShape()
            },
            scalar: { stage in
                stage.beginShape(.lines)
                stage.vertex(6, 38, 0)
                stage.vertex(58, 9, -20)
                stage.endShape()
            })
    }

    // MARK: - Canvas の直の呼び出し

    @Test("Canvas を直に呼んでも、ベクトルの口は数の口と同じ絵")
    func canvasDirect() throws {
        try agree(
            "canvas 2D",
            vector: { stage in
                let canvas = stage.canvas
                canvas.circle(Vector2(40, 17), 22)
                canvas.point(Vector2(9, 9))
                canvas.line(Vector2(6, 38), Vector2(58, 9))
                canvas.translate(Vector2(30, 11))
                canvas.beginShape()
                canvas.vertex(Vector2(0, 0))
                canvas.vertex(Vector2(12, 3))
                canvas.vertex(Vector2(6, 10))
                canvas.endShape(.close)
            },
            scalar: { stage in
                let canvas = stage.canvas
                canvas.circle(40, 17, 22)
                canvas.point(9, 9)
                canvas.line(6, 38, 58, 9)
                canvas.translate(30, 11)
                canvas.beginShape()
                canvas.vertex(0, 0)
                canvas.vertex(12, 3)
                canvas.vertex(6, 10)
                canvas.endShape(.close)
            })
        try agree(
            "canvas 3D",
            vector: { stage in
                let canvas = stage.canvas
                canvas.lights()
                canvas.point(Vector3(9, 9, -10))
                canvas.line(Vector3(6, 38, 0), Vector3(58, 9, -20))
                canvas.translate(Vector3(30, 11, -25))
                canvas.box(12, 8, 6)
                canvas.beginShape(.lines)
                canvas.vertex(Vector3(0, 0, 0))
                canvas.vertex(Vector3(12, 3, -8))
                canvas.endShape()
            },
            scalar: { stage in
                let canvas = stage.canvas
                canvas.lights()
                canvas.point(9, 9, -10)
                canvas.line(6, 38, 0, 58, 9, -20)
                canvas.translate(30, 11, -25)
                canvas.box(12, 8, 6)
                canvas.beginShape(.lines)
                canvas.vertex(0, 0, 0)
                canvas.vertex(12, 3, -8)
                canvas.endShape()
            })
    }

    // MARK: - 距離

    @Test("dist(Vector2, Vector2)・dist(Vector3, Vector3) は成分で渡した dist と同じ値で、distance(to:) と一致する")
    func distanceOfVectors() {
        let a2 = Vector2(1, 2)
        let b2 = Vector2(4, 6)
        #expect(dist(a2, b2) == 5)
        #expect(dist(a2, b2) == dist(1, 2, 4, 6))
        #expect(dist(a2, b2) == a2.distance(to: b2))
        let a3 = Vector3(1, 2, 3)
        let b3 = Vector3(3, 5, 9)
        #expect(dist(a3, b3) == 7)
        #expect(dist(a3, b3) == dist(1, 2, 3, 3, 5, 9))
        #expect(dist(a3, b3) == a3.distance(to: b3))
        // 溢れる大きさでも同じ値
        let far = Vector3(3e19, 4e19, 12e19)
        #expect(dist(Vector3(0, 0, 0), far) == far.distance(to: Vector3(0, 0, 0)))
        #expect(dist(Vector3(0, 0, 0), far).isFinite)
        // 数でない値は関数の層の約束 (0) で、距離の値型の口 (数でない値のまま) とは別
        #expect(dist(Vector2(Float.nan, 0), Vector2(3, 4)) == 0)
    }
}
