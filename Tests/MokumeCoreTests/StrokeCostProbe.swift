// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation
import Testing

@testable import MokumeCore

/// #1889 条件 7 の計測 (一時的な計測器。コミットしない)。
@Suite("線の費用の計測", .enabled(if: RenderDevice.isAvailable && !isDebugBuild, "release だけ"))
struct StrokeCostProbe {
    private func frameTimes(
        _ canvas: Canvas, frames: Int = 200, _ body: () -> Void
    ) throws -> (median: Double, p95: Double, min: Double) {
        for _ in 0..<12 {
            try canvas.draw(body)
            _ = try canvas.target.readPixels()
        }
        var times: [Double] = []
        for _ in 0..<frames {
            let started = DispatchTime.now().uptimeNanoseconds
            try canvas.draw(body)
            _ = try canvas.target.readPixels()
            times.append(Double(DispatchTime.now().uptimeNanoseconds - started) / 1e6)
        }
        times.sort()
        return (times[times.count / 2], times[Int(Double(times.count) * 0.95)], times[0])
    }

    @Test("費用")
    func cost() throws {
        let canvas = try CanvasFixture.make(gpu: RenderDevice(), width: 800, height: 800)
        func spheres(_ count: Int, stroke: @escaping (Canvas) -> Void) -> () -> Void {
            {
                canvas.background(0)
                canvas.noFill()
                stroke(canvas)
                for index in 0..<count {
                    canvas.push()
                    canvas.translate(Float(index % 20) * 40 + 20, Float(index / 20) * 40 + 20, 0)
                    canvas.rotateX(0.4 + Float(index) * 0.01)
                    canvas.rotateY(0.7)
                    canvas.sphere(18)
                    canvas.pop()
                }
            }
        }
        func boxes(_ count: Int, stroke: @escaping (Canvas) -> Void) -> () -> Void {
            {
                canvas.background(0)
                canvas.noFill()
                stroke(canvas)
                for index in 0..<count {
                    canvas.push()
                    canvas.translate(Float(index % 20) * 40 + 20, Float(index / 20) * 40 + 20, 0)
                    canvas.rotateX(0.4 + Float(index) * 0.01)
                    canvas.rotateY(0.7)
                    canvas.box(22)
                    canvas.pop()
                }
            }
        }
        // 平らな四角の周 1000 個を記録した形 (端と折れ目を振る)
        func squares(_ style: (Canvas) -> Void) -> Shape {
            var shape = Shape.empty
            try? canvas.draw {
                canvas.noFill()
                canvas.stroke(255)
                canvas.strokeWeight(3)
                style(canvas)
                shape = canvas.createShape {
                    for index in 0..<1000 {
                        let x = Float(index % 40) * 20 + 10
                        let y = Float(index / 40) * 30 + 10
                        canvas.beginShape()
                        canvas.vertex(x - 6, y - 6, 0)
                        canvas.vertex(x + 6, y - 6, 0)
                        canvas.vertex(x + 6, y + 6, 0)
                        canvas.vertex(x - 6, y + 6, 0)
                        canvas.endShape(.close)
                    }
                }
                // 線のスタイルはフレームを越えるので、既定へ戻す
                canvas.strokeWeight(1)
                canvas.strokeJoin(.miter)
                canvas.strokeCap(.round)
            }
            return shape
        }
        let squaresDefault = squares { _ in }
        let squaresSquareCap = squares { $0.strokeCap(.square) }
        let squaresRoundJoin = squares { $0.strokeJoin(.round) }
        func placing(_ shape: Shape) -> () -> Void {
            {
                canvas.background(0)
                canvas.translate(0, 0, 0)
                canvas.rotateX(0.2)
                canvas.shape(shape)
            }
        }
        let scenes: [(String, () -> Void)] = [
            ("球 400・既定の線 (GPU)", spheres(400) { $0.stroke(255) }),
            ("球 400・太さ 6 (GPU)", spheres(400) { $0.stroke(255); $0.strokeWeight(6) }),
            ("球 400・線なし", spheres(400) { $0.noStroke() }),
            ("箱 400・太さ 6 (GPU)", boxes(400) { $0.stroke(255); $0.strokeWeight(6) }),
            ("球 100・半透明 (CPU)", spheres(100) { $0.stroke(255, 250) }),
            ("箱 400・半透明 (CPU)", boxes(400) { $0.stroke(255, 250); $0.strokeWeight(6) }),
            ("四角の周 1000 を置く・端 round・折れ目 miter", placing(squaresDefault)),
            ("四角の周 1000 を置く・端 square・折れ目 miter", placing(squaresSquareCap)),
            ("四角の周 1000 を置く・折れ目 round", placing(squaresRoundJoin)),
        ]
        for (name, body) in scenes {
            let time = try frameTimes(canvas, body)
            print("COST \(name): 中央値 \(String(format: "%.3f", time.median)) ms / p95 \(String(format: "%.3f", time.p95)) ms / 最小 \(String(format: "%.3f", time.min)) ms")
        }
        // 保持した形の記録 (頂点の数・部品の数・部品の大きさ)
        var recorded: [(String, Shape)] = []
        try canvas.draw {
            canvas.stroke(255, 250)
            canvas.noFill()
            recorded.append(("記録した球 (半透明)", canvas.createShape { canvas.sphere(50) }))
            recorded.append(("記録した箱 (半透明)", canvas.createShape { canvas.box(80) }))
            canvas.stroke(255)
            recorded.append(("記録した球 (不透明)", canvas.createShape { canvas.sphere(50) }))
            recorded.append(("記録した plane (不透明)", canvas.createShape { canvas.plane(80, 80) }))
            recorded.append(("記録した平らな四角の周 (端 round)", canvas.createShape {
                canvas.beginShape()
                canvas.vertex(-40, -40, 0)
                canvas.vertex(40, -40, 0)
                canvas.vertex(40, 40, 0)
                canvas.vertex(-40, 40, 0)
                canvas.endShape(.close)
            }))
        }
        recorded.append(("記録した平らな四角の周 1000 (端 round)", squaresDefault))
        for (name, shape) in recorded {
            print(
                "COST \(name): vertexCount \(shape.vertexCount) / 部品 \(shape.solidStrokes.count) / "
                    + "頂点 \(MemoryLayout<SolidVertex>.stride) B・部品 \(MemoryLayout<SolidStrokePiece>.stride) B / "
                    + "合計 \(shape.solidVertices.count * MemoryLayout<SolidVertex>.stride + shape.solidStrokes.count * MemoryLayout<SolidStrokePiece>.stride) B")
        }
        // GPU の骨
        try canvas.draw {
            canvas.stroke(255)
            canvas.sphere(18)
            canvas.box(22)
            canvas.closeBatch()
            for geometry in canvas.batches.compactMap(\.strokeGeometry) {
                print("COST 骨: 頂点 \(geometry.count) / 置き場 \(geometry.buffer.length) B")
            }
        }
    }
}
