// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Testing

@testable import MokumeCore

/// 光のラベル付きの形 ([#3780])。GPU を要する。
///
/// 約束は、**ラベル付きの形に位置の形と同じ値を渡すと、置かれた光 (``Canvas/activeLights``) が
/// 1 ビットも違わない**こと。光の陰影は置かれた光の値だけで決まるので、値が一致すれば絵も一致する。
/// 中継の口 (`Sketch`) と `Canvas` の直の呼び出しの**両方**で見る。
///
/// **値は成分がどれも違うもの**にして、成分の取り違えが光の値に出るようにした。光を置く前に変換を
/// 積んでおき、位置と向きが変換を受ける道も同じであることを見る。位置の形が実際に光を置いている
/// こと (光の数が 1 つ増えていること) も先に確かめる。
///
/// [#3780]: https://github.com/mokume-metal/mokume/issues/3780
@Suite(
    "光のラベル付きの形",
    .enabled(
        if: RenderDevice.isAvailable,
        "この世代のコマンド構造に対応した GPU が無い実行環境ではスキップする")
)
struct LabeledLightArgumentsTests {
    final class Stage: Sketch {
        var settings: SketchSettings { SketchSettings(width: 64, height: 48) }
        var scene: (Stage) -> Void = { _ in }
        init() {}
        func draw() { scene(self) }
    }

    /// 置かれた光を、比べられる形 (光ごとに 3 つの 4 成分の値) にしたもの。
    private typealias Placed = [[SIMD4<Float>]]

    private static func placed(_ canvas: Canvas) -> Placed {
        canvas.activeLights.map { [$0.colorAndKind, $0.position, $0.directionAndCone] }
    }

    /// 光の位置と向きが変換を受けることも比べるため、光の前に積む変換。
    private static func moved(_ canvas: Canvas) {
        canvas.translate(7, -3, 11)
        canvas.rotateY(0.4)
    }

    /// 中継の口で 1 フレームだけ書いて、書き終えたときの光を返す。
    private func lightsThroughSketch(_ gpu: RenderDevice, _ body: @escaping (Stage) -> Void) throws -> Placed {
        let stage = Stage()
        var seen: Placed?
        stage.scene = { stage in
            Self.moved(stage.canvas)
            body(stage)
            seen = Self.placed(stage.canvas)
        }
        let runtime = try SketchRuntime(sketch: stage, gpu: gpu, clock: nil, now: { 0 })
        try runtime.advance()
        return try #require(seen)
    }

    /// `Canvas` を直に呼んで 1 フレームだけ書いて、書き終えたときの光を返す。
    private func lightsOnCanvas(_ gpu: RenderDevice, _ body: (Canvas) -> Void) throws -> Placed {
        let canvas = try CanvasFixture.make(gpu: gpu, width: 64, height: 48)
        var seen: Placed?
        try canvas.draw {
            Self.moved(canvas)
            body(canvas)
            seen = Self.placed(canvas)
        }
        return try #require(seen)
    }

    /// ラベル付きの形と位置の形が、両方の層で同じ光を置いていること。`placesOne` が真なら光が 1 つ
    /// 置かれていること、偽なら両方の形とも光を置かないこと (断られること) も見る。
    private func agree(
        _ name: String,
        placesOne: Bool = true,
        labeledSketch: @escaping (Stage) -> Void,
        positionalSketch: @escaping (Stage) -> Void,
        labeledCanvas: (Canvas) -> Void,
        positionalCanvas: (Canvas) -> Void,
        sourceLocation: SourceLocation = #_sourceLocation
    ) throws {
        let gpu = try RenderDevice()

        let expectedSketch = try lightsThroughSketch(gpu, positionalSketch)
        let actualSketch = try lightsThroughSketch(gpu, labeledSketch)
        #expect(actualSketch == expectedSketch, "\(name): Sketch のラベル付きの形が位置の形と違う光を置いた", sourceLocation: sourceLocation)

        let expectedCanvas = try lightsOnCanvas(gpu, positionalCanvas)
        let actualCanvas = try lightsOnCanvas(gpu, labeledCanvas)
        #expect(actualCanvas == expectedCanvas, "\(name): Canvas のラベル付きの形が位置の形と違う光を置いた", sourceLocation: sourceLocation)

        let count = placesOne ? 1 : 0
        #expect(expectedSketch.count == count, "\(name): 位置の形 (Sketch) の光が \(expectedSketch.count) 個", sourceLocation: sourceLocation)
        #expect(expectedCanvas.count == count, "\(name): 位置の形 (Canvas) の光が \(expectedCanvas.count) 個", sourceLocation: sourceLocation)
    }

    private let warm = LinearRGBA.linear(red: 0.9, green: 0.6, blue: 0.3)

    // MARK: - directionalLight(color:direction:)

    @Test("directionalLight(color:direction:) は directionalLight(色, x, y, z) と同じ光を置く")
    func directionalMatchesThePositionalForm() throws {
        let warm = warm
        try agree(
            "directionalLight",
            labeledSketch: { $0.directionalLight(color: warm, direction: Vector3(0.3, 1, -0.6)) },
            positionalSketch: { $0.directionalLight(warm, 0.3, 1, -0.6) },
            labeledCanvas: { $0.directionalLight(color: warm, direction: Vector3(0.3, 1, -0.6)) },
            positionalCanvas: { $0.directionalLight(warm, 0.3, 1, -0.6) })
    }

    // MARK: - pointLight(color:position:)

    @Test("pointLight(color:position:) は pointLight(色, x, y, z) と同じ光を置く")
    func pointMatchesThePositionalForm() throws {
        let warm = warm
        try agree(
            "pointLight",
            labeledSketch: { $0.pointLight(color: warm, position: Vector3(20, 14, 40)) },
            positionalSketch: { $0.pointLight(warm, 20, 14, 40) },
            labeledCanvas: { $0.pointLight(color: warm, position: Vector3(20, 14, 40)) },
            positionalCanvas: { $0.pointLight(warm, 20, 14, 40) })
    }

    @Test("Issue の例: pointLight(color: color(255, 200, 150), position:) は 0–255 の数で置く形と同じ光")
    func pointMatchesTheNumericColorForm() throws {
        try agree(
            "pointLight (0–255 の色)",
            labeledSketch: { $0.pointLight(color: color(255, 200, 150), position: Vector3(200, 100, 80)) },
            positionalSketch: { $0.pointLight(255, 200, 150, 200, 100, 80) },
            labeledCanvas: { $0.pointLight(color: color(255, 200, 150), position: Vector3(200, 100, 80)) },
            positionalCanvas: { $0.pointLight(255, 200, 150, 200, 100, 80) })
    }

    // MARK: - spotLight(color:position:direction:angle:)

    @Test("spotLight(color:position:direction:angle:) は spotLight(色, 6 つの数, angle:) と同じ光を置く")
    func spotMatchesThePositionalForm() throws {
        let warm = warm
        try agree(
            "spotLight",
            labeledSketch: {
                $0.spotLight(color: warm, position: Vector3(20, 14, 40), direction: Vector3(0.3, 0.2, -1), angle: 0.45)
            },
            positionalSketch: { $0.spotLight(warm, 20, 14, 40, 0.3, 0.2, -1, angle: 0.45) },
            labeledCanvas: {
                $0.spotLight(color: warm, position: Vector3(20, 14, 40), direction: Vector3(0.3, 0.2, -1), angle: 0.45)
            },
            positionalCanvas: { $0.spotLight(warm, 20, 14, 40, 0.3, 0.2, -1, angle: 0.45) })
    }

    @Test("angle: を省いた spotLight は、angle: .pi / 6 を渡したときと同じ光を置く")
    func spotDefaultAngleIsPiOverSix() throws {
        let warm = warm
        try agree(
            "spotLight (angle を省く)",
            labeledSketch: { $0.spotLight(color: warm, position: Vector3(20, 14, 40), direction: Vector3(0.3, 0.2, -1)) },
            positionalSketch: { $0.spotLight(warm, 20, 14, 40, 0.3, 0.2, -1, angle: Float.pi / 6) },
            labeledCanvas: { $0.spotLight(color: warm, position: Vector3(20, 14, 40), direction: Vector3(0.3, 0.2, -1)) },
            positionalCanvas: { $0.spotLight(warm, 20, 14, 40, 0.3, 0.2, -1, angle: Float.pi / 6) })
    }

    @Test("範囲の外の angle は、位置の形と同じく π/2 へ丸めて置く")
    func spotWideAngleIsRoundedAlike() throws {
        let warm = warm
        try agree(
            "spotLight (angle 3)",
            labeledSketch: {
                $0.spotLight(color: warm, position: Vector3(20, 14, 40), direction: Vector3(0.3, 0.2, -1), angle: 3)
            },
            positionalSketch: { $0.spotLight(warm, 20, 14, 40, 0.3, 0.2, -1, angle: 3) },
            labeledCanvas: {
                $0.spotLight(color: warm, position: Vector3(20, 14, 40), direction: Vector3(0.3, 0.2, -1), angle: 3)
            },
            positionalCanvas: { $0.spotLight(warm, 20, 14, 40, 0.3, 0.2, -1, angle: 3) })
    }

    @Test("数でない色の光は、位置の形と同じく置かれない")
    func notANumberColorIsRefusedAlike() throws {
        let broken = LinearRGBA.linear(red: .nan, green: 0.5, blue: 0.5)
        try agree(
            "pointLight (数でない色)",
            placesOne: false,
            labeledSketch: { $0.pointLight(color: broken, position: Vector3(20, 14, 40)) },
            positionalSketch: { $0.pointLight(broken, 20, 14, 40) },
            labeledCanvas: { $0.pointLight(color: broken, position: Vector3(20, 14, 40)) },
            positionalCanvas: { $0.pointLight(broken, 20, 14, 40) })
        try agree(
            "spotLight (数でない色)",
            placesOne: false,
            labeledSketch: { $0.spotLight(color: broken, position: Vector3(20, 14, 40), direction: Vector3(0, 0, -1)) },
            positionalSketch: { $0.spotLight(broken, 20, 14, 40, 0, 0, -1) },
            labeledCanvas: { $0.spotLight(color: broken, position: Vector3(20, 14, 40), direction: Vector3(0, 0, -1)) },
            positionalCanvas: { $0.spotLight(broken, 20, 14, 40, 0, 0, -1) })
    }
}
