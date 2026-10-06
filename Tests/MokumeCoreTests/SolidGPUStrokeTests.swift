// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation
import Testing
import simd

@testable import MokumeCore

@Suite("GPU で広げる稜線", .enabled(if: RenderDevice.isAvailable, "GPU が無い環境ではスキップ"))
struct SolidGPUStrokeTests {
    /// 色をそのまま返す利用者の断片。線を GPU で広げる条件から外す (`gpuStrokeStyleAllows`) だけで、
    /// 絵は変えない。同じ `miter` の線を、GPU の骨と CPU の帯の 2 経路で描き比べるのに使う。
    private static func passThrough(_ canvas: Canvas) throws -> Shader {
        try canvas.makeShader("float4 paint(Fragment in, Values values) { return in.color; }")
    }

    /// GPU の骨の円板 (`Shapes.metal` の `kSolidStrokeDisc`) は、CPU の円板の下限の分割数 (16) の
    /// 周の点 (``Canvas/solidDiscFloorUnits``) を書き写して持つ (#1893)。三角関数は GPU と CPU で丸めが
    /// 違うので、値で持たないと同じ角の点がずれる。書き写しがビットで一致することを見る。16 で足りない
    /// 太さの丸い端は骨を使わない (#2011・`SolidDiscSegmentTests.gpuAndCPUAgreeOnThickRoundEnds`)。
    @Test("GPU の円板の周の点は、CPU の円板の周の点とビットで一致する")
    func discUnitsMatchTheCPU() throws {
        let source = try RenderDevice().shaders.bundledShaderSource(named: "Shapes")
        let table = try #require(source.range(of: "kSolidStrokeDisc[17] = {"))
        let end = try #require(source.range(of: "};", range: table.upperBound..<source.endIndex))
        let body = source[table.upperBound..<end.lowerBound]
        var units: [SIMD2<Float>] = []
        for line in body.split(separator: "\n") {
            guard let open = line.range(of: "float2("), let close = line.range(of: ")") else { continue }
            let parts = line[open.upperBound..<close.lowerBound].split(separator: ",").compactMap {
                Float($0.trimmingCharacters(in: .whitespaces))
            }
            if parts.count == 2 { units.append(SIMD2(parts[0], parts[1])) }
        }
        #expect(units.count == Canvas.solidDiscFloorUnits.count)
        #expect(
            units.map { [$0.x.bitPattern, $0.y.bitPattern] }
                == Canvas.solidDiscFloorUnits.map { [$0.x.bitPattern, $0.y.bitPattern] })
    }

    /// 同じ直線に載る 2 本の辺が集まる点を持つ網は、視線をその直線に沿わせると潰れた辺が 2 本
    /// 続く。GPU の頂点関数は潰れた辺の先を 1 段しか引かないので、骨を作らずに CPU の骨へ戻す。
    @Test("同じ直線に載る 2 本の辺を持つ網は、GPU の骨を作らない")
    func straightPairsStayOnTheCPU() throws {
        // 直線 a–m–b を稜にして、折れた 2 枚ずつで挟む (稜線は a–m と m–b の 2 本に分かれる)
        let (a, m, b) = (SIMD3<Float>(0, 0, 0), SIMD3<Float>(1, 0, 0), SIMD3<Float>(2, 0, 0))
        let (up, side) = (SIMD3<Float>(1, 1, 0), SIMD3<Float>(1, 0, 1))
        var points: [SolidMesh.Point] = []
        for triangle in [[a, m, up], [m, b, up], [m, a, side], [b, m, side], [a, up, side], [up, b, side]] {
            for corner in triangle {
                points.append(SolidMesh.Point(position: corner, normal: .zero, uv: .zero))
            }
        }
        let net = SolidEdges(SolidMesh(points: points))
        #expect(!net.edges.isEmpty)
        #expect(try SolidStrokeGeometry(net: net, gpu: RenderDevice()) == nil)
        let box = SolidEdges(SolidShape.box(width: 2, height: 2, depth: 2).make())
        #expect(try SolidStrokeGeometry(net: box, gpu: RenderDevice()) != nil)
    }

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
            let passThrough = try Self.passThrough(canvas)
            try canvas.draw {
                canvas.background(.linear(red: 0, green: 0, blue: 0))
                // どちらも miter。CPU の側は色をそのまま返す利用者の断片で従来の経路へ移す
                // (`gpuStrokeStyleAllows`)。網の角は miter と bevel で形が違う (#1889)
                if !gpu { canvas.shader(passThrough) }
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
            let passThrough = try Self.passThrough(canvas)
            // 立体だけを、CPU の側では利用者の断片に通す (平面の rect は断片を通すと三角形の
            // 経路へ移って縁が変わる)
            func box(_ size: Float) {
                if !gpu { canvas.shader(passThrough) }
                canvas.box(size)
                if !gpu { canvas.resetShader() }
            }
            try canvas.draw {
                canvas.background(.linear(red: 0, green: 0, blue: 0))
                canvas.stroke(.linear(red: 0.9, green: 0.1, blue: 0.3))
                canvas.noFill()
                canvas.translate(100, 100, 0)
                box(80)
                canvas.loadPixels()
                canvas.fill(.init(straightRed: 0, green: 0.5, blue: 1, alpha: 0.5))
                canvas.rect(-25, -25, 50, 50)
                canvas.rotateY(0.6)
                box(65)
                canvas.ortho()
                canvas.translate(15, 12, 20)
                box(45)
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
        let passThrough = try Self.passThrough(canvas)
        for accelerated in [false, true] {
            try canvas.draw {
                canvas.background(.linear(red: 0, green: 0, blue: 0))
                if !accelerated { canvas.shader(passThrough) }
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
