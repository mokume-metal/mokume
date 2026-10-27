// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Testing

@testable import MokumeCore

/// 1 引数の均等スケール `scale(_:)` ([#3357])。GPU を要する。
///
/// 約束は `scale(s)` が `scale(s, s, s)` と**同じ変換**を積むこと — 縦横だけでなく奥行きも
/// 一緒に伸びる (Processing の `scale(s)` と同じ)。平面だけを描くと `scale(s, s)` と区別が
/// 付かないので、**奥行きを持つ立体で `scale(s, s)` と違う絵になる**ことも見る。
///
/// [#3357]: https://github.com/mokume-metal/mokume/issues/3357
@Suite(
    "均等スケール scale(s)",
    .enabled(
        if: RenderDevice.isAvailable,
        "この世代のコマンド構造に対応した GPU が無い実行環境ではスキップする")
)
@MainActor
struct UniformScaleTests {
    /// 検査が差し込んだ 1 枚を描くだけのスケッチ。
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
            stage.noStroke()
            stage.fill(230, 128, 64)
            body(stage)
        }
        let runtime = try SketchRuntime(sketch: stage, gpu: gpu, clock: nil, now: { 0 })
        try runtime.advance()
        return try runtime.target.readPixels().components.map(\.bitPattern)
    }

    private func differing(_ one: [UInt16], _ other: [UInt16]) -> Int {
        zip(one, other).count { $0.0 != $0.1 } + abs(one.count - other.count)
    }

    /// 平面と立体を両方描く場面。`apply` に変換を差し込む。
    private func scene(_ stage: Stage, apply: () -> Void) {
        stage.lights()
        stage.translate(32, 24, 0)
        apply()
        stage.rect(-6, -4, 12, 8)
        stage.box(10)
    }

    @Test("Sketch の scale(s) は scale(s, s, s) とビット列で一致する")
    func sketchUniformScaleDrawsWhatTheTripleDraws() throws {
        let gpu = try RenderDevice()
        let uniform = try picture(gpu) { stage in scene(stage) { stage.scale(1.7) } }
        let triple = try picture(gpu) { stage in scene(stage) { stage.scale(1.7, 1.7, 1.7) } }
        let untouched = try picture(gpu) { stage in scene(stage) {} }
        // 何も描いていなければ、同じになっても何も見ていない
        #expect(differing(uniform, untouched) > 0)
        #expect(differing(uniform, triple) == 0)
    }

    @Test("奥行きも一緒に伸びる — 立体は scale(s, s) と違う絵になる")
    func depthScalesToo() throws {
        let gpu = try RenderDevice()
        let uniform = try picture(gpu) { stage in scene(stage) { stage.scale(1.7) } }
        let flat = try picture(gpu) { stage in scene(stage) { stage.scale(1.7, 1.7) } }
        #expect(differing(uniform, flat) > 0)
    }

    @Test("平面だけを描くなら scale(s, s) と同じ絵になる")
    func planarDrawingMatchesTheTwoArgumentForm() throws {
        let gpu = try RenderDevice()
        func flat(_ stage: Stage, _ apply: () -> Void) {
            stage.translate(32, 24)
            apply()
            stage.rect(-6, -4, 12, 8)
        }
        let uniform = try picture(gpu) { stage in flat(stage) { stage.scale(2) } }
        let pair = try picture(gpu) { stage in flat(stage) { stage.scale(2, 2) } }
        #expect(differing(uniform, pair) == 0)
    }

    /// 変換を恒等へ戻してから `body` を呼び、積んだ変換を返す。
    private func stacked(on canvas: Canvas, _ body: () -> Void) -> Transform {
        canvas.resetMatrix()
        body()
        return canvas.transform
    }

    @Test("Canvas の scale(s) は、Float・Double・Int・負数・0 でも scale(s, s, s) と同じ変換を積む")
    func canvasUniformScaleStacksTheTripleTransform() throws {
        let canvas = try CanvasFixture.make(gpu: RenderDevice(), width: 16, height: 16)
        try canvas.draw {
            let asFloat: Float = 0.5
            let asDouble: Double = 0.5
            let asInt: Int = 3
            let triple = stacked(on: canvas) { canvas.scale(0.5, 0.5, 0.5) }
            #expect(triple != Transform.identity)
            #expect(stacked(on: canvas) { canvas.scale(asFloat) } == triple)
            #expect(stacked(on: canvas) { canvas.scale(asDouble) } == triple)
            #expect(stacked(on: canvas) { canvas.scale(asInt) } == stacked(on: canvas) { canvas.scale(3, 3, 3) })
            // 負数は反転、0 は潰れる。どちらも 3 つの軸に同じ値を掛けた行列になる
            #expect(stacked(on: canvas) { canvas.scale(-2) } == stacked(on: canvas) { canvas.scale(-2, -2, -2) })
            #expect(stacked(on: canvas) { canvas.scale(0) } == stacked(on: canvas) { canvas.scale(0, 0, 0) })

            // 奥行きにも掛かる (`scale(s, s)` なら z は動かない)
            let moved = stacked(on: canvas) { canvas.scale(2) }.apply(x: 1, y: 1, z: 5)
            #expect(moved == Vector3(2, 2, 10))
            let flat = stacked(on: canvas) { canvas.scale(2, 2) }.apply(x: 1, y: 1, z: 5)
            #expect(flat == Vector3(2, 2, 5))
        }
    }
}
