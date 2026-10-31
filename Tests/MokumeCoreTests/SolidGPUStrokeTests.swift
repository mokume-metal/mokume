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
    ///
    /// 表の宣言 (`kSolidStrokeDisc[17]`) は下限の分割数 (``Canvas/solidDiscFloorSegments``) + 1 で決め
    /// 打ちしてある。下限を変えるときは、ここと `Shapes.metal` の表、``SolidStrokeGeometry`` の円板の
    /// 片の数 (8 = 下限の半分) を揃える。
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

    /// 同じ直線に載る 2 本の辺が集まる点を持つ網は、視線をその直線に沿わせると潰れた辺が 2 本以上続く。
    /// 頂点関数は潰れた辺を対の相手をたどって何段でも引くので、骨を作る ([#2989])。
    /// 絵が CPU の帯と一致することは `StraightChainStrokeTests` が見る。
    ///
    /// [#2989]: https://github.com/mokume-metal/mokume/issues/2989
    @Test("同じ直線に載る 2 本の辺を持つ網も、GPU の骨を作る")
    func straightPairsMakeABone() throws {
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
        #expect(try SolidStrokeGeometry(net: net, gpu: RenderDevice()) != nil)
        let box = SolidEdges(SolidShape.box(width: 2, height: 2, depth: 2).make())
        #expect(try SolidStrokeGeometry(net: box, gpu: RenderDevice()) != nil)
    }

    /// 骨の片は 4 頂点で、添字 6 つが 2 枚の三角形 (0 1 2・0 2 3) に並べる。非添字で 6 頂点ずつ流すと同じ角を
    /// 2 度求める (#3246)。頂点関数 (`solidStrokeVertexMain`) は添字の値そのものを `index / 4`・`index % 4` で
    /// 読むので、添字の並びがずれると別の片・別の角を描く (絵は壊れるが、描く数は変わらない)。
    @Test("骨の片は 4 頂点で、添字は片ごとに (0 1 2)・(0 2 3) の 2 枚の三角形に並ぶ")
    func piecesDrawFromFourVerticesAndSixIndices() throws {
        let net = SolidEdges(SolidShape.box(width: 2, height: 2, depth: 2).make())
        let geometry = try #require(try SolidStrokeGeometry(net: net, gpu: RenderDevice()))
        let pieceCount = geometry.count / SolidStrokeGeometry.indicesPerPiece
        #expect(pieceCount > 0 && geometry.count == pieceCount * 6)
        // 添字は片と点の記録の後ろにあり、置き場の終わりまでにちょうど収まる
        #expect(geometry.indexByteOffset + geometry.count * 4 == geometry.buffer.length)
        let indices = (geometry.buffer.contents() + geometry.indexByteOffset).bindMemory(
            to: UInt32.self, capacity: geometry.count)
        var wrong: [Int] = []
        for piece in 0..<pieceCount {
            let first = UInt32(piece * 4)
            let expected = [first, first + 1, first + 2, first, first + 2, first + 3]
            let actual = (0..<6).map { indices[piece * 6 + $0] }
            if actual != expected { wrong.append(piece) }
        }
        #expect(wrong.isEmpty, "添字の並びが違う片: \(wrong.prefix(5))")
    }

    /// 骨を作らない配置。**直線の上で同じ側へ重なる 2 辺** (T 字の継ぎ目: 長い辺の途中に別の点が載る) は、
    /// 視線をその直線に沿わせたとき、たどる道が分かれるので、CPU の帯へ戻す。
    @Test("同じ側へ折り返す 2 本の辺を持つ網は、GPU の骨を作らない")
    func foldedStraightPairsStayOnTheCPU() throws {
        // P–Q と P–R は同じ向きに重なる (Q は P–R の途中)
        let (p, q, r) = (SIMD3<Float>(0, 0, 0), SIMD3<Float>(1, 0, 0), SIMD3<Float>(2, 0, 0))
        let (x, y) = (SIMD3<Float>(0.5, 1, 0), SIMD3<Float>(1, -1, 0))
        var points: [SolidMesh.Point] = []
        for triangle in [[p, r, x], [p, q, y]] {
            for corner in triangle {
                points.append(SolidMesh.Point(position: corner, normal: .zero, uv: .zero))
            }
        }
        let net = SolidEdges(SolidMesh(points: points))
        #expect(!net.edges.isEmpty)
        #expect(try SolidStrokeGeometry(net: net, gpu: RenderDevice()) == nil)
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

    /// 頂点関数が向きを控える腕は 8 本までで (`kSolidStrokeCachedArms`)、越えた腕は引くたびに骨の
    /// 点から引き直す (#2973)。腕が 9 本以上集まる点は、組み込みの網では球の極と円錐の頂点くらいにしか
    /// 無い。球の極は腕が全周に並んで角の形が他の腕の帯に隠れ、`matchesCPU` の絵には引き直しの誤りが
    /// 出ない。
    ///
    /// ここでは、軸を画面に沿わせて横から見た円錐 (分割 18) に太い線を引く。頂点に 18 本の腕が集まり、
    /// 底の輪へ扇に開く (画面で 180° を越える隙間が反対側に空く) ので、頂点の角の形は**扇の両端の 2 本**で
    /// 決まる。両端の腕の 1 本は 9 本目以降 (引き直す側) にあり、**引き直した腕を数え損なうと、角の形が
    /// 内側の腕で決まって頂点の尖りが変わる**。引き直しの経路を `return false` に壊す・控えの最後の
    /// 値を返すに壊すと、この検査が赤になる (どちらも他の突き合わせは緑のまま・PR に書いた)。
    /// 絵に出るのは頂点の尖りの十数画素なので、太さは 40 と太くしてある。
    @Test("腕が控えの 8 本を越える頂点の角も、従来の CPU 経路と同じ絵になる", arguments: [false, true])
    func manyArmsMatchCPU(orthographic: Bool) throws {
        var images: [DisplayImage] = []
        for gpu in [false, true] {
            let canvas = try CanvasFixture.make(gpu: RenderDevice(), width: 200, height: 200)
            let passThrough = try Self.passThrough(canvas)
            try canvas.draw {
                canvas.background(.linear(red: 0, green: 0, blue: 0))
                if !gpu { canvas.shader(passThrough) }
                if orthographic { canvas.ortho() }
                canvas.noFill()
                canvas.stroke(.linear(red: 1, green: 1, blue: 1))
                canvas.strokeWeight(40)
                canvas.translate(100, 100, 0)
                canvas.cone(60, 60, detail: 18)
                canvas.closeBatch()
                // GPU の側は線を GPU で広げ、CPU の側 (利用者の断片つき) は広げない
                let strokes = canvas.batches.compactMap(\.strokeGeometry)
                #expect(strokes.count == (gpu ? 1 : 0))
            }
            images.append(try canvas.target.encodeForDisplay())
        }
        var different = 0
        var lit = 0
        for y in 0..<200 {
            for x in 0..<200 {
                if images[0][x, y] != images[1][x, y] { different += 1 }
                if images[1][x, y] != images[1][0, 0] { lit += 1 }
            }
        }
        #expect(lit > 500, "線が描かれていない (描かれた画素 \(lit))")
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
