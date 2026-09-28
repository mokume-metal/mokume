// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Testing

@testable import MokumeCore

@Suite("GPU で広げる稜線", .enabled(if: RenderDevice.isAvailable, "GPU が無い環境ではスキップ"))
struct SolidGPUStrokeTests {
    @Test("同じ球は列をまたいで頂点と骨を共用する")
    func sharedGeometry() throws {
        let canvas = try CanvasFixture.make(gpu: RenderDevice(), width: 200, height: 200)
        var sizes: [Int] = []
        for count in [10, 100] {
            try canvas.draw {
                canvas.background(.linear(red: 0, green: 0, blue: 0))
                for index in 0..<count {
                    canvas.push()
                    canvas.translate(Float(index % 10) * 18 + 10, Float(index / 10) * 18 + 10, 0)
                    canvas.sphere(7)
                    canvas.pop()
                }
                canvas.closeBatch()
                sizes.append(canvas.solidVertices.count)
                let strokes = canvas.batches.compactMap(\.strokeGeometry)
                #expect(strokes.count == count)
                #expect(Set(strokes.map { ObjectIdentifier($0) }).count == 1)
            }
        }
        #expect(sizes[0] == sizes[1])
        #expect(canvas.solidStrokeGeometry.made == 1)
        #expect(canvas.solidMeshRanges.isEmpty)
        #expect(MemoryLayout<SolidStrokePlacement>.stride <= Canvas.valuesStride)
    }

    @Test("帯と角は従来の CPU 経路と同じ絵になる", arguments: [false, true], [false, true])
    func matchesCPU(orthographic: Bool, mirror: Bool) throws {
        var images: [DisplayImage] = []
        for gpu in [false, true] {
            let canvas = try CanvasFixture.make(gpu: RenderDevice(), width: 200, height: 200)
            try canvas.draw {
                canvas.background(.linear(red: 0, green: 0, blue: 0))
                // miter と bevel の網の角はどちらも正方形。bevel は従来経路に残る。
                canvas.strokeJoin(gpu ? .miter : .bevel)
                if orthographic { canvas.ortho() }
                canvas.stroke(.linear(red: 1, green: 1, blue: 1))
                canvas.strokeWeight(3)
                canvas.translate(100, 100, 0)
                canvas.rotateX(0.45)
                canvas.rotateY(0.7)
                canvas.scale(mirror ? -1.2 : 1.2, 0.8, 1.1)
                canvas.sphere(55)
            }
            images.append(try canvas.target.encodeForDisplay())
        }
        var different = 0
        for y in 0..<200 {
            for x in 0..<200 {
                if images[0][x, y] != images[1][x, y] { different += 1 }
            }
        }
        #expect(different == 0, "GPU と CPU で異なる画素: \(different)")
    }
    @Test("線だけ・半透明の塗り・平面の挿入と途中の読み出しを並べ替えない")
    func orderAndFlush() throws {
        var pictures: [[UInt8]] = []
        for gpu in [false, true] {
            let canvas = try CanvasFixture.make(gpu: RenderDevice(), width: 200, height: 200)
            try canvas.draw {
                canvas.background(.linear(red: 0, green: 0, blue: 0))
                canvas.strokeJoin(gpu ? .miter : .bevel)
                canvas.stroke(.linear(red: 0.9, green: 0.1, blue: 0.3))
                canvas.noFill()
                canvas.translate(100, 100, 0)
                canvas.box(80)
                canvas.loadPixels()
                canvas.fill(.init(straightRed: 0, green: 0.5, blue: 1, alpha: 0.5))
                canvas.rect(-25, -25, 50, 50)
                canvas.rotateY(0.6)
                canvas.box(65)
                canvas.ortho()
                canvas.translate(15, 12, 20)
                canvas.box(45)
            }
            pictures.append(try canvas.target.encodeForDisplay().bytes)
        }
        #expect(pictures[0] == pictures[1])
    }

    @Test("半透明・丸い角・利用者断片・記録は従来経路に残る")
    func fallback() throws {
        let canvas = try CanvasFixture.make(gpu: RenderDevice(), width: 100, height: 100)
        let shader = try canvas.makeShader(
            "float4 paint(Fragment in, Values values) { return in.color; }")
        try canvas.draw {
            canvas.noFill()
            canvas.stroke(.init(straightRed: 1, green: 0, blue: 0, alpha: 0.5))
            canvas.box(20)
            canvas.stroke(.linear(red: 1, green: 0, blue: 0))
            canvas.strokeJoin(.round)
            canvas.sphere(20)
            canvas.strokeJoin(.miter)
            canvas.shader(shader)
            canvas.box(25)
            canvas.resetShader()
            _ = canvas.createShape { canvas.box(30) }
            canvas.closeBatch()
            #expect(canvas.batches.allSatisfy { $0.strokeGeometry == nil })
            #expect(canvas.solidStrokeGeometry.made == 0)
        }
    }

    @Test("GPU の帯の影は同じ視点なら再利用し、視点が変われば焼き直す")
    func shadowCamera() throws {
        let canvas = try CanvasFixture.make(gpu: RenderDevice(), width: 200, height: 200)
        for offset: Float in [0, 0, 15] {
            try canvas.draw {
                canvas.background(.linear(red: 0, green: 0, blue: 0))
                canvas.camera(100 + offset, 100, 200, 100, 100, 0, 0, 1, 0)
                canvas.directionalLight(.linear(red: 1, green: 1, blue: 1), 0, 0, -1)
                canvas.shadows(true)
                canvas.shadowDetail(128)
                canvas.noFill()
                canvas.stroke(.linear(red: 1, green: 1, blue: 1))
                canvas.translate(100, 100, 0)
                canvas.box(60)
            }
        }
        #expect(canvas.shadowBakesEncoded == 2)
        #expect(canvas.shadowBakesReused == 1)
    }

    @Test("半径を毎枚変えても GPU の骨は1つで、追い出した骨も先の列が読める")
    func movingRadiiAndEviction() throws {
        let canvas = try CanvasFixture.make(gpu: RenderDevice(), width: 200, height: 200)
        for frame in 0..<4 {
            try canvas.draw {
                canvas.translate(100, 100, 0)
                for index in 0..<10 { canvas.sphere(20 + frame * 10 + index) }
            }
        }
        #expect(canvas.solidStrokeGeometry.made == 1)
        canvas.solidStrokeGeometry.budget = 1
        var expected: [UInt8] = []
        for accelerated in [false, true] {
            try canvas.draw {
                canvas.background(.linear(red: 0, green: 0, blue: 0))
                canvas.strokeJoin(accelerated ? .miter : .bevel)
                canvas.noFill()
                canvas.translate(100, 100, 0)
                canvas.box(80)
                canvas.rotateY(0.7)
                canvas.sphere(50)
                canvas.box(50)
            }
            let bytes = try canvas.target.encodeForDisplay().bytes
            if accelerated { #expect(bytes == expected) } else { expected = bytes }
        }
        #expect(canvas.solidStrokeGeometry.count == 1)
    }

}
