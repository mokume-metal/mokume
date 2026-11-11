// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Testing

@testable import MokumeCore

/// 視点と投影のラベル付きの形 ([#3778]・[#3779])。GPU を要する。
///
/// 約束は、**ラベル付きの形に位置の形と同じ値を渡すと、効いている視点 (``Canvas/currentCamera``) が
/// 1 ビットも違わない**こと。絵は視点と投影だけで決まるので、視点の値が一致すれば絵も一致する。
/// 中継の口 (`Sketch`) と `Canvas` の直の呼び出しの**両方**で見る。ラベル付きの形が値の順を
/// 取り違えても、位置の形を見る既存の検査は赤くならない。
///
/// **値はどの 2 つを入れ替えても視点が変わるもの**にした (同じ数を 2 か所に置かない)。どの組も
/// 「何も書いていない視点」と違うことを先に確かめ、何も当てない形が緑になるのを避ける。
///
/// [#3778]: https://github.com/mokume-metal/mokume/issues/3778
/// [#3779]: https://github.com/mokume-metal/mokume/issues/3779
@Suite(
    "視点と投影のラベル付きの形",
    .enabled(
        if: RenderDevice.isAvailable,
        "この世代のコマンド構造に対応した GPU が無い実行環境ではスキップする")
)
struct LabeledCameraArgumentsTests {
    final class Stage: Sketch {
        var settings: SketchSettings { SketchSettings(width: 64, height: 48) }
        var scene: (Stage) -> Void = { _ in }
        init() {}
        func draw() { scene(self) }
    }

    /// 中継の口で 1 フレームだけ書いて、書き終えたときの視点を返す。
    private func cameraThroughSketch(_ gpu: RenderDevice, _ body: @escaping (Stage) -> Void) throws -> Camera {
        let stage = Stage()
        var seen: Camera?
        stage.scene = { stage in
            body(stage)
            seen = stage.currentCamera
        }
        let runtime = try SketchRuntime(sketch: stage, gpu: gpu, clock: nil, now: { 0 })
        try runtime.advance()
        return try #require(seen)
    }

    /// `Canvas` を直に呼んで 1 フレームだけ書いて、書き終えたときの視点を返す。
    private func cameraOnCanvas(_ gpu: RenderDevice, _ body: (Canvas) -> Void) throws -> Camera {
        let canvas = try CanvasFixture.make(gpu: gpu, width: 64, height: 48)
        var seen: Camera?
        try canvas.draw {
            body(canvas)
            seen = canvas.currentCamera
        }
        return try #require(seen)
    }

    /// ラベル付きの形と位置の形が、両方の層で同じ視点を当てていること。`changes` が真なら、
    /// その視点が何も書かない視点と違うこと (形が実際に何かを当てていること) も見る。
    private func agree(
        _ name: String,
        changes: Bool = true,
        labeledSketch: @escaping (Stage) -> Void,
        positionalSketch: @escaping (Stage) -> Void,
        labeledCanvas: (Canvas) -> Void,
        positionalCanvas: (Canvas) -> Void,
        sourceLocation: SourceLocation = #_sourceLocation
    ) throws {
        let gpu = try RenderDevice()
        let untouched = try cameraOnCanvas(gpu) { _ in }

        let expectedSketch = try cameraThroughSketch(gpu, positionalSketch)
        let actualSketch = try cameraThroughSketch(gpu, labeledSketch)
        #expect(actualSketch == expectedSketch, "\(name): Sketch のラベル付きの形が位置の形と違う視点を当てた", sourceLocation: sourceLocation)

        let expectedCanvas = try cameraOnCanvas(gpu, positionalCanvas)
        let actualCanvas = try cameraOnCanvas(gpu, labeledCanvas)
        #expect(actualCanvas == expectedCanvas, "\(name): Canvas のラベル付きの形が位置の形と違う視点を当てた", sourceLocation: sourceLocation)

        if changes {
            #expect(expectedSketch != untouched, "\(name): 位置の形の視点が既定のまま — 値の選び方が効いていない", sourceLocation: sourceLocation)
            #expect(expectedCanvas != untouched, "\(name): 位置の形の視点が既定のまま — 値の選び方が効いていない", sourceLocation: sourceLocation)
        } else {
            #expect(expectedSketch == untouched, "\(name): 断られるはずの値が効いた", sourceLocation: sourceLocation)
            #expect(expectedCanvas == untouched, "\(name): 断られるはずの値が効いた", sourceLocation: sourceLocation)
        }
    }

    // MARK: - camera(eye:center:up:) (#3778)

    @Test("camera(eye:center:up:) は camera(9 つの数) と同じ視点を当てる")
    func cameraMatchesThePositionalForm() throws {
        // Issue の例。上方向の成分も 3 つとも違えて、上方向の中での取り違えも出るようにする
        try agree(
            "camera (Issue の例)",
            labeledSketch: {
                $0.camera(eye: Vector3(200, -150, 300), center: Vector3(200, 150, 0), up: Vector3(0, 1, 0))
            },
            positionalSketch: { $0.camera(200, -150, 300, 200, 150, 0, 0, 1, 0) },
            labeledCanvas: {
                $0.camera(eye: Vector3(200, -150, 300), center: Vector3(200, 150, 0), up: Vector3(0, 1, 0))
            },
            positionalCanvas: { $0.camera(200, -150, 300, 200, 150, 0, 0, 1, 0) })
        try agree(
            "camera (9 つとも違う値)",
            labeledSketch: { $0.camera(eye: Vector3(52, 6, 70), center: Vector3(30, 26, -8), up: Vector3(0.3, 1, 0.15)) },
            positionalSketch: { $0.camera(52, 6, 70, 30, 26, -8, 0.3, 1, 0.15) },
            labeledCanvas: { $0.camera(eye: Vector3(52, 6, 70), center: Vector3(30, 26, -8), up: Vector3(0.3, 1, 0.15)) },
            positionalCanvas: { $0.camera(52, 6, 70, 30, 26, -8, 0.3, 1, 0.15) })
    }

    @Test("camera(eye:center:up:) は、位置の形と同じく投影を残す")
    func cameraKeepsTheProjection() throws {
        try agree(
            "camera の後の投影",
            labeledSketch: {
                $0.ortho(-40, 40, 30, -30, 5, 900)
                $0.camera(eye: Vector3(52, 6, 70), center: Vector3(30, 26, -8), up: Vector3(0.3, 1, 0.15))
            },
            positionalSketch: {
                $0.ortho(-40, 40, 30, -30, 5, 900)
                $0.camera(52, 6, 70, 30, 26, -8, 0.3, 1, 0.15)
            },
            labeledCanvas: {
                $0.ortho(-40, 40, 30, -30, 5, 900)
                $0.camera(eye: Vector3(52, 6, 70), center: Vector3(30, 26, -8), up: Vector3(0.3, 1, 0.15))
            },
            positionalCanvas: {
                $0.ortho(-40, 40, 30, -30, 5, 900)
                $0.camera(52, 6, 70, 30, 26, -8, 0.3, 1, 0.15)
            })
    }

    @Test("見る位置と見ている先が同じ視点は、位置の形と同じく断られる")
    func degenerateCameraIsRefusedAlike() throws {
        let point = Vector3(10, 20, 30)
        try agree(
            "camera (退化)",
            changes: false,
            labeledSketch: { $0.camera(eye: point, center: point, up: Vector3(0, 1, 0)) },
            positionalSketch: { $0.camera(10, 20, 30, 10, 20, 30, 0, 1, 0) },
            labeledCanvas: { $0.camera(eye: point, center: point, up: Vector3(0, 1, 0)) },
            positionalCanvas: { $0.camera(10, 20, 30, 10, 20, 30, 0, 1, 0) })
    }

    // MARK: - perspective(fieldOfView:aspect:near:far:) (#3779)

    @Test("perspective(fieldOfView:aspect:near:far:) は perspective(4 つの数) と同じ投影を当てる")
    func perspectiveMatchesThePositionalForm() throws {
        // Issue の例
        try agree(
            "perspective (Issue の例)",
            labeledSketch: { $0.perspective(fieldOfView: Float.pi / 3, aspect: Float(4) / 3, near: 26, far: 300) },
            positionalSketch: { $0.perspective(Float.pi / 3, Float(4) / 3, 26, 300) },
            labeledCanvas: { $0.perspective(fieldOfView: Float.pi / 3, aspect: Float(4) / 3, near: 26, far: 300) },
            positionalCanvas: { $0.perspective(Float.pi / 3, Float(4) / 3, 26, 300) })
        // 整数と Double も、位置の形と同じに受ける
        try agree(
            "perspective (Int と Double)",
            labeledSketch: { $0.perspective(fieldOfView: 1.6, aspect: 2, near: 26, far: 2600) },
            positionalSketch: { $0.perspective(1.6, 2, 26, 2600) },
            labeledCanvas: { $0.perspective(fieldOfView: 1.6, aspect: 2, near: 26, far: 2600) },
            positionalCanvas: { $0.perspective(1.6, 2, 26, 2600) })
    }

    @Test("画角が 0 の透視投影は、位置の形と同じく断られる")
    func degeneratePerspectiveIsRefusedAlike() throws {
        try agree(
            "perspective (画角 0)",
            changes: false,
            labeledSketch: { $0.perspective(fieldOfView: 0, aspect: 1.5, near: 26, far: 300) },
            positionalSketch: { $0.perspective(0, 1.5, 26, 300) },
            labeledCanvas: { $0.perspective(fieldOfView: 0, aspect: 1.5, near: 26, far: 300) },
            positionalCanvas: { $0.perspective(0, 1.5, 26, 300) })
    }

    // MARK: - ortho(left:right:bottom:top:near:far:) (#3779)

    @Test("ortho(left:right:bottom:top:near:far:) は ortho(6 つの数) と同じ投影を当てる")
    func orthoMatchesThePositionalForm() throws {
        // Issue の例。6 つとも違う値なので、どの 2 つの取り違えも投影に出る
        try agree(
            "ortho (Issue の例)",
            labeledSketch: { $0.ortho(left: -300, right: 300, bottom: 225, top: -225, near: 60, far: 2600) },
            positionalSketch: { $0.ortho(-300, 300, 225, -225, 60, 2600) },
            labeledCanvas: { $0.ortho(left: -300, right: 300, bottom: 225, top: -225, near: 60, far: 2600) },
            positionalCanvas: { $0.ortho(-300, 300, 225, -225, 60, 2600) })
    }

    @Test("左右の端が同じ平行投影は、位置の形と同じく断られる")
    func degenerateOrthoIsRefusedAlike() throws {
        try agree(
            "ortho (幅 0)",
            changes: false,
            labeledSketch: { $0.ortho(left: 40, right: 40, bottom: 30, top: -30, near: 5, far: 900) },
            positionalSketch: { $0.ortho(40, 40, 30, -30, 5, 900) },
            labeledCanvas: { $0.ortho(left: 40, right: 40, bottom: 30, top: -30, near: 5, far: 900) },
            positionalCanvas: { $0.ortho(40, 40, 30, -30, 5, 900) })
    }
}
