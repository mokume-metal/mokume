// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation
import Testing
import simd

@testable import MokumeCore

/// 細い塗りの広げ方を CPU の組み直しから頂点段へ移した畳み ([#2208]) の検査。GPU を要する。
///
/// 畳んだ置き場所は片を頂点にせず、置き場所ごとの記述 (``Canvas/ThinFillRecord``) を渡して頂点段が
/// 片の角を組む。**絵は動かさない** — 移さない形 (``Canvas/expandsThinFillsInVertexStage`` を偽にした、
/// CPU が置き場所ごとに片を組み直す形) と同じ画素で出ることを、形の種別ごとに見る。
///
/// [#2208]: https://github.com/mokume-metal/mokume/issues/2208
@Suite(
    "細い塗りの頂点段での広げ方",
    .enabled(
        if: RenderDevice.isAvailable,
        "この世代のコマンド構造に対応した GPU が無い実行環境ではスキップする")
)
struct ThinFillVertexStageTests {
    private static let size = 128

    private static func makeCanvas(density: Float) throws -> Canvas {
        let gpu = try RenderDevice()
        let output = try RenderTarget(gpu: gpu, width: size, height: size)
        return try Canvas(output: output, gpu: gpu, pixelDensity: density, upscale: .spatial)
    }

    private static let plain = "float4 paint(Fragment in, Values values) { return in.color; }"

    // MARK: - 畳まれる

    /// 場面 S: 細かさ 1・全部違う角度の `ellipse(0, 0, 40, 0.5)`。
    @Test("回転が全部違う細い楕円 (長い) は、1 つの雛形に畳まれる")
    func rotatedLongEllipsesFoldIntoOneTemplate() throws {
        let canvas = try Self.makeCanvas(density: 1)
        let shader = try canvas.makeShader(Self.plain)
        let count = 40
        try canvas.draw {
            canvas.background(0)
            canvas.noStroke()
            canvas.fill(255)
            canvas.shader(shader)
            for index in 0..<count {
                canvas.pushMatrix()
                canvas.translate(64, 64)
                canvas.rotate(Float(index) * 0.137 + 0.01)
                canvas.ellipse(0, 0, 40, 0.5)
                canvas.popMatrix()
            }
            // 1 つ目は畳む相手を待って置き、2 つ目から雛形を開いて置き場所を足す
            #expect(canvas.openFlat != nil, "細い楕円が畳まれない")
            #expect(canvas.flatInstances.count == count + 1, "置き場所: \(canvas.flatInstances.count)")
            #expect(canvas.thinFillInstances.count == count, "記述: \(canvas.thinFillInstances.count)")
            #expect(canvas.openFlat?.key.thinFillCapacity == Canvas.thinEllipseSliceLimit)
        }
    }

    /// 場面 R: 細かさ 0.5・全部違う回転の `rect(-20, -0.5, 40, 1)`。
    @Test("回転が全部違う細い rect は、1 つの雛形に畳まれる")
    func rotatedRectsFoldIntoOneTemplate() throws {
        let canvas = try Self.makeCanvas(density: 0.5)
        let shader = try canvas.makeShader(Self.plain)
        let count = 40
        try canvas.draw {
            canvas.background(0)
            canvas.noStroke()
            canvas.fill(255)
            canvas.shader(shader)
            for index in 0..<count {
                canvas.pushMatrix()
                canvas.translate(64, 64)
                canvas.rotate(Float(index) * 0.113 + 0.02)
                canvas.rect(-20, -0.5, 40, 1)
                canvas.popMatrix()
            }
            #expect(canvas.openFlat != nil, "細い rect が畳まれない")
            #expect(canvas.flatInstances.count == count + 1, "置き場所: \(canvas.flatInstances.count)")
            #expect(canvas.thinFillInstances.count == count)
            #expect(canvas.openFlat?.key.thinFillCapacity == 1)
        }
    }

    /// 同じ楕円は、置き場所の拡大で描く画素での長さが違っても (片の数が 1 から上限まで変わっても)、
    /// 1 つの雛形に畳まれる。使わない片は頂点段が潰す。
    @Test("長さが拡大で変わる細い楕円は、片の数によらず 1 つの雛形に畳まれる")
    func ellipsesOfAnyLengthFoldIntoOneTemplate() throws {
        let canvas = try Self.makeCanvas(density: 1)
        let shader = try canvas.makeShader(Self.plain)
        try canvas.draw {
            canvas.background(0)
            canvas.noStroke()
            canvas.fill(255)
            canvas.shader(shader)
            for index in 0..<12 {
                canvas.pushMatrix()
                canvas.translate(64, 64)
                canvas.rotate(Float(index) * 0.3)
                // 長さ 6〜60 画素 (短い楕円・長い楕円・片の数の上限)
                let scale = 0.15 + Float(index) * 0.13
                canvas.scale(scale, scale)
                canvas.ellipse(0, 0, 40, 0.5)
                canvas.popMatrix()
            }
            #expect(canvas.thinFillInstances.count == 12, "記述: \(canvas.thinFillInstances.count)")
            #expect(canvas.openFlat?.key.thinFillCapacity == Canvas.thinEllipseSliceLimit)
        }
    }

    // MARK: - 画素が動かない

    /// 細い塗りを 1 つずつ変えながら置いた絵を、頂点段で広げる畳みと、CPU で組み直す畳みで描いて比べる。
    private func picture(
        density: Float, expands: Bool, texture: Bool = false, scene: (Canvas) -> Void
    ) throws -> PixelBuffer {
        let canvas = try Self.makeCanvas(density: density)
        canvas.expandsThinFillsInVertexStage = expands
        let shader = try canvas.makeShader(Self.plain)
        var image: Image?
        if texture {
            let made = try canvas.createImage(8, 8)
            for y in 0..<8 {
                for x in 0..<8 {
                    made.set(
                        x, y,
                        .linear(red: Float(x) / 7, green: Float(y) / 7, blue: Float((x + y) % 2)))
                }
            }
            image = made
        }
        try canvas.draw {
            canvas.background(0)
            canvas.noStroke()
            canvas.fill(255)
            if let image {
                canvas.texture(image)
            } else {
                canvas.shader(shader)
            }
            scene(canvas)
        }
        return try canvas.target.readPixels()
    }

    /// - Parameter tolerance: 違ってよい成分の数。**貼る絵の読み取り位置は、片の角の足し算の最後の桁が
    ///   頂点段 (融合した積和) と CPU でずれると、最近傍で読む 8×8 の絵の継ぎ目の画素が 1 つ振れる**。
    ///   形の位置を比べる場面は 0 のまま。
    private func expectSame(
        _ name: String, density: Float = 1, texture: Bool = false, tolerance: Int = 0,
        scene: (Canvas) -> Void
    ) throws {
        let cpu = try picture(density: density, expands: false, texture: texture, scene: scene)
        let gpu = try picture(density: density, expands: true, texture: texture, scene: scene)
        var differing = 0
        var lit = 0
        for index in cpu.components.indices {
            if cpu.components[index] != gpu.components[index] { differing += 1 }
            if cpu.components[index] > 0 { lit += 1 }
        }
        #expect(lit > 0, "\(name): 絵が空")
        #expect(
            differing <= tolerance, "\(name): 画素の成分が \(differing) 個違う (点いている成分 \(lit))")
    }

    /// 置き場所ごとに回転と倍率を変える。**形の寸法は 1 つの場面で同じ** — 寸法が違うと別の雛形になり、
    /// 畳まれない (``Canvas/FlatKey/form``)。
    private func scatter(
        _ canvas: Canvas, count: Int = 30, spin: Float = 0.21, scale: (Int) -> (Float, Float) = { _ in (1, 1) },
        draw: () -> Void
    ) {
        for index in 0..<count {
            canvas.pushMatrix()
            canvas.translate(20 + Float(index % 6) * 17, 20 + Float(index / 6) * 17)
            canvas.rotate(Float(index) * spin + 0.03)
            let (sx, sy) = scale(index)
            canvas.scale(sx, sy)
            draw()
            canvas.popMatrix()
        }
    }

    @Test("細長い楕円 (回転・縦横の倍率が違う) は、CPU で組み直す畳みと画素が同じ")
    func longEllipsesKeepTheirPixels() throws {
        try expectSame("長い楕円") { canvas in
            scatter(
                canvas, scale: { (1 + Float($0 % 3) * 0.2, 1 + Float($0 % 4) * 0.1) }
            ) { canvas.ellipse(0, 0, 26, 0.5) }
            #expect(!canvas.expandsThinFillsInVertexStage || canvas.thinFillInstances.count == 30, "畳まれていない")
        }
    }

    @Test("短い楕円・小さい円・細長い rect は、CPU で組み直す畳みと画素が同じ")
    func shortAndSmallShapesKeepTheirPixels() throws {
        try expectSame("短い楕円") { canvas in
            scatter(canvas, spin: 0.37, scale: { (0.5 + Float($0 % 7) * 0.15, 1) }) {
                canvas.ellipse(0, 0, 8, 0.4)
            }
            #expect(!canvas.expandsThinFillsInVertexStage || canvas.thinFillInstances.count == 30, "畳まれていない")
        }
        try expectSame("小さい円") { canvas in
            scatter(canvas, spin: 0.5, scale: { (0.3 + Float($0 % 5) * 0.13, 1) }) {
                canvas.circle(0, 0, 1)
            }
            #expect(!canvas.expandsThinFillsInVertexStage || canvas.thinFillInstances.count == 30, "畳まれていない")
        }
        try expectSame("細長い rect") { canvas in
            scatter(canvas, spin: 0.29, scale: { (1 + Float($0 % 3) * 0.1, 1) }) {
                canvas.rect(-12, -0.4, 24, 0.8)
            }
            #expect(!canvas.expandsThinFillsInVertexStage || canvas.thinFillInstances.count == 30, "畳まれていない")
        }
        try expectSame("短い rect") { canvas in
            scatter(canvas, spin: 0.33, scale: { (1 + Float($0 % 4) * 0.2, 1) }) {
                canvas.rect(-3, -0.4, 6, 0.8)
            }
            #expect(!canvas.expandsThinFillsInVertexStage || canvas.thinFillInstances.count == 30, "畳まれていない")
        }
    }

    @Test("細かさ 0.5 の細い塗りも、CPU で組み直す畳みと画素が同じ")
    func halfDensityKeepsItsPixels() throws {
        try expectSame("細かさ 0.5 の rect", density: 0.5) { canvas in
            scatter(canvas, spin: 0.23) { canvas.rect(-14, -0.5, 28, 1) }
            #expect(!canvas.expandsThinFillsInVertexStage || canvas.thinFillInstances.count == 30, "畳まれていない")
        }
        try expectSame("細かさ 0.5 の楕円", density: 0.5) { canvas in
            scatter(canvas, spin: 0.23) { canvas.ellipse(0, 0, 28, 0.8) }
            #expect(!canvas.expandsThinFillsInVertexStage || canvas.thinFillInstances.count == 30, "畳まれていない")
        }
    }

    @Test("貼る絵の細い塗りも、読み取り位置まで CPU で組み直す畳みと画素が同じ")
    func texturedFillsKeepTheirPixels() throws {
        try expectSame("貼る絵の rect", texture: true) { canvas in
            scatter(canvas, spin: 0.27) { canvas.rect(-10, -0.5, 20, 1) }
        }
        try expectSame("貼る絵の楕円", texture: true, tolerance: 8) { canvas in
            scatter(canvas, spin: 0.27) { canvas.ellipse(0, 0, 20, 0.7) }
        }
    }

    // MARK: - 記述

    /// 記述から出した片が、頂点段の式と同じ約束 (片の数・被覆の上限・使わない片の 0) を守ること。
    @Test("記述の被覆の表は、使わない片が 0 で、片の数が上限を越えない")
    func recordsStayWithinTheirCapacity() throws {
        let named = Canvas.Outline.NamedFill(isEllipse: true, center: .zero, half: SIMD2(6, 0.25))
        for angle in stride(from: Float(0), to: 3.2, by: 0.3) {
            let c = cos(angle)
            let s = sin(angle)
            let linear = simd_float2x2(SIMD2(c, s), SIMD2(-s, c))
            let record = try #require(Canvas.thinFillRecord(named, by: linear))
            #expect(record.pieceCount <= Canvas.ThinFillRecord.capacity(isEllipse: true))
            #expect(record.pieces().count <= record.pieceCount)
            #expect(record.pieces().allSatisfy { $0.coverage > 0 && $0.coverage <= 1.0001 })
        }
    }
}
