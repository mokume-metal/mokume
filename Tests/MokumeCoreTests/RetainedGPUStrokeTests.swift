// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation
import Testing

@testable import MokumeCore

/// 保持した形の中の組み込み立体の線を、置くときに GPU で組む (#1756)。
///
/// 物差しは **同じ形を CPU の帯で置いた絵** (`placesRetainedStrokesOnGPU = false`、以前の経路)。
/// どの場面でも全バイトが一致することを見る。
@Suite("保持した立体の線を GPU で組む", .enabled(if: RenderDevice.isAvailable, "GPU が無い環境ではスキップ"))
struct RetainedGPUStrokeTests {
    nonisolated private static let shapes = ["sphere", "box", "cylinder", "cone", "plane", "ellipsoid", "torus"]

    /// 置き方の場面。
    enum Scene: Int, CaseIterable, Sendable {
        case origin, fractional, rotated, mirrored, nonUniform, orthographic, camera, nearCrossing,
            far, placementWeight, recordedTransform
    }

    private func solid(_ name: String, on canvas: Canvas) {
        switch name {
        case "sphere": canvas.sphere(25)
        case "box": canvas.box(50)
        case "cylinder": canvas.cylinder(25, 50)
        case "cone": canvas.cone(25, 50)
        case "plane": canvas.plane(60, 40)
        case "ellipsoid": canvas.ellipsoid(30, 20, 25)
        default: canvas.torus(25, 8)
        }
    }

    /// 描き方。
    enum Route: Sendable {
        /// 保持した形を置き、組める線を GPU で組む (この変更の経路)。
        case retainedGPU
        /// 保持した形を置き、線を CPU の帯で組む (以前の経路)。
        case retainedCPU
        /// 同じものをその場で直接描く。**保持した形の約束の物差し** — 置いた形は、同じ置き場所で
        /// 1 つずつ書いたときと同じ絵になる (`Canvas.place(_:at:)`)。
        case direct
    }

    /// 形を 3 か所に置いた絵と、GPU で組んだ線の列の数。
    private func picture(
        _ name: String, _ scene: Scene, filled: Bool, route: Route
    ) throws -> (bytes: [UInt8], strokeBatches: Int) {
        let canvas = try CanvasFixture.make(gpu: RenderDevice(), width: 160, height: 160)
        canvas.placesRetainedStrokesOnGPU = route == .retainedGPU
        var strokeBatches = 0
        try canvas.draw {
            canvas.background(.linear(red: 0, green: 0, blue: 0))
            @MainActor func record() {
                if filled { canvas.fill(.linear(red: 0.2, green: 0.3, blue: 0.5)) } else { canvas.noFill() }
                canvas.stroke(.linear(red: 1, green: 1, blue: 1))
                canvas.strokeWeight(2)
                if scene == .recordedTransform {
                    canvas.translate(3.25, -2, 4)
                    canvas.rotateZ(0.3)
                    canvas.scale(0.9, 1.1, 1)
                }
                solid(name, on: canvas)
            }
            let shape = route == .direct ? nil : canvas.createShape { record() }
            if scene == .orthographic { canvas.ortho() }
            if scene == .camera { canvas.camera(110, 75, 180, 80, 80, 0, 0, 1, 0) }
            for (index, x) in [Float(45), 80, 115].enumerated() {
                canvas.push()
                canvas.translate(x, 80, 0)
                canvas.scale(0.5, 0.5, 0.5)
                switch scene {
                case .fractional: canvas.translate(0.5, 0.25, 0)
                case .rotated:
                    canvas.rotateY(0.63 + Float(index) * 0.2)
                    canvas.rotateX(0.37)
                case .mirrored:
                    canvas.scale(-1, 1, 1)
                    canvas.rotateY(0.63)
                case .nonUniform:
                    canvas.scale(1.5, 0.7, 1.2)
                    canvas.rotateX(0.4)
                case .nearCrossing:
                    canvas.translate(0, 0, 115)
                    canvas.rotateY(0.7)
                case .far: canvas.translate(0, 0, -100)
                // 置く時点の太さは効かない (記録した太さで引く)。直接描く側は記録と同じ太さで引く
                case .placementWeight: canvas.strokeWeight(9)
                default: break
                }
                if let shape { canvas.shape(shape) } else { record() }
                canvas.pop()
            }
            canvas.closeBatch()
            strokeBatches = canvas.batches.count { $0.strokeGeometry != nil }
        }
        return (try canvas.target.encodeToImage().read().bytes, strokeBatches)
    }

    private func differingPixels(_ a: [UInt8], _ b: [UInt8]) -> Int {
        stride(from: 0, to: a.count, by: 4).count { a[$0..<($0 + 4)] != b[$0..<($0 + 4)] }
    }

    @Test(
        "保持した組み込み立体の線を GPU で組んだ絵は、同じものをその場で描いた絵と一致する",
        arguments: RetainedGPUStrokeTests.shapes, [false, true])
    func matchesDrawingInPlace(_ name: String, filled: Bool) throws {
        var differing: [String] = []
        for scene in Scene.allCases {
            let direct = try picture(name, scene, filled: filled, route: .direct)
            let gpu = try picture(name, scene, filled: filled, route: .retainedGPU)
            let cpu = try picture(name, scene, filled: filled, route: .retainedCPU)
            #expect(cpu.strokeBatches == 0, "以前の経路が GPU で組んでいる")
            #expect(gpu.strokeBatches == 3, "\(name) \(scene): GPU で組んだ列が \(gpu.strokeBatches) 本")
            let lit = stride(from: 0, to: direct.bytes.count, by: 4).count { direct.bytes[$0] > 0 }
            #expect(lit > 20, "\(name) \(scene): 物差しに線が写っていない")
            let count = differingPixels(direct.bytes, gpu.bytes)
            if count > 0 { differing.append("\(scene): \(count) 画素") }
            // 以前の経路 (CPU の帯) とも、この場面では一致する (視点を回すと縁の 1 画素が
            // 違うことがあるのは以前の経路の側で、直接描いた絵と違う — 下の検査)
            #expect(differingPixels(cpu.bytes, gpu.bytes) == 0, "\(name) \(scene): 以前の経路と違う")
        }
        #expect(differing.isEmpty, "\(name) 塗り \(filled): \(differing)")
    }

    @Test("視点を回しても、保持した線は同じものをその場で描いた絵と全フレームで一致する")
    func orbitingMatchesDrawingInPlace() throws {
        func frames(_ route: Route) throws -> [[UInt8]] {
            let canvas = try CanvasFixture.make(gpu: RenderDevice(), width: 240, height: 160)
            canvas.placesRetainedStrokesOnGPU = route == .retainedGPU
            var shapes: [Shape] = []
            var pictures: [[UInt8]] = []
            for frame in 0..<60 {
                try canvas.draw {
                    canvas.background(.linear(red: 0, green: 0, blue: 0))
                    @MainActor func record(_ index: Int) {
                        if index == 1 { canvas.fill(.linear(red: 0.15, green: 0.25, blue: 0.45)) } else { canvas.noFill() }
                        canvas.stroke(.linear(red: 1, green: 0.95, blue: 0.85))
                        canvas.strokeWeight(1.5)
                        switch index {
                        case 0: canvas.sphere(13)
                        case 1: canvas.box(22)
                        default: canvas.torus(12, 4)
                        }
                    }
                    if route != .direct, shapes.isEmpty {
                        for index in 0..<3 { shapes.append(canvas.createShape { record(index) }) }
                    }
                    let angle = Float(frame) / 60 * 2 * .pi
                    canvas.camera(120 + 130 * sin(angle), 60, 80 + 130 * cos(angle), 120, 80, 0, 0, 1, 0)
                    for index in 0..<9 {
                        canvas.push()
                        canvas.translate(Float(index % 3) * 60 + 60, Float(index / 3) * 45 + 35, 0)
                        if route == .direct { record(index % 3) } else { canvas.shape(shapes[index % 3]) }
                        canvas.pop()
                    }
                }
                pictures.append(try canvas.target.encodeToImage().read().bytes)
            }
            return pictures
        }
        let direct = try frames(.direct)
        let gpu = try frames(.retainedGPU)
        let differing = (0..<60).filter { direct[$0] != gpu[$0] }
        #expect(differing.isEmpty, "\(differing.count) フレームが直接描いた絵と違う: \(differing)")
    }

    @Test("同じ形を何か所に置いても、骨は 1 つで、CPU の線の頂点は積まない")
    func sharesOneGeometryAndSkipsTheBakedBands() throws {
        let canvas = try CanvasFixture.make(gpu: RenderDevice(), width: 160, height: 160)
        try canvas.draw {
            let shape = canvas.createShape {
                canvas.noFill()
                canvas.stroke(.linear(red: 1, green: 1, blue: 1))
                canvas.sphere(10)
            }
            #expect(shape.gpuStrokes.count == 1)
            for index in 0..<30 {
                canvas.push()
                canvas.translate(Float(index % 6) * 25 + 15, Float(index / 6) * 25 + 15, 0)
                canvas.shape(shape)
                canvas.pop()
            }
            canvas.closeBatch()
            #expect(canvas.batches.count { $0.strokeGeometry != nil } == 30)
            // 線だけの形なので、焼いた頂点は 1 つも積まない
            #expect(canvas.solidVertices.isEmpty)
        }
        #expect(canvas.solidStrokeGeometry.made == 1)
    }

    /// GPU で組めない置き方・記録は、CPU の帯のまま置く。
    enum Fallback: String, CaseIterable, Sendable {
        /// 置き場所の色で線が透ける。
        case translucentTint
        /// 記録した線が透ける。
        case translucentStroke
        /// 丸い継ぎ目。
        case roundJoin
        /// 利用者の断片。
        case shader
        /// 加算で混ぜる。
        case additive
        /// 記録の中で置き直す (入れ子)。外側の形を置くとき、内側の線は CPU で組む。
        case nested
    }

    @Test("GPU で組めない線は、CPU の帯のまま置き、絵も変わらない", arguments: Fallback.allCases)
    func fallsBackToTheCPUBands(_ fallback: Fallback) throws {
        func render(gpu: Bool) throws -> (bytes: [UInt8], strokeBatches: Int, gpuStrokes: Int) {
            let canvas = try CanvasFixture.make(gpu: RenderDevice(), width: 120, height: 120)
            canvas.placesRetainedStrokesOnGPU = gpu
            let shader = try canvas.makeShader(
                "float4 paint(Fragment in, Values values) { return in.color * 0.5; }")
            var strokeBatches = 0
            var recorded = 0
            try canvas.draw {
                canvas.background(.linear(red: 0, green: 0, blue: 0))
                @MainActor func record() -> Shape {
                    canvas.createShape {
                        canvas.noFill()
                        canvas.stroke(
                            fallback == .translucentStroke
                                ? .init(straightRed: 1, green: 1, blue: 1, alpha: 0.5)
                                : .linear(red: 1, green: 1, blue: 1))
                        canvas.strokeWeight(3)
                        if fallback == .roundJoin { canvas.strokeJoin(.round) }
                        if fallback == .shader { canvas.shader(shader) }
                        if fallback == .additive { canvas.blendMode(.add) }
                        canvas.box(40)
                    }
                }
                let inner = record()
                let shape =
                    fallback == .nested
                    ? canvas.createShape {
                        canvas.rotateY(0.4)
                        canvas.shape(inner)
                    } : inner
                recorded = shape.gpuStrokes.count
                canvas.translate(60, 60, 0)
                canvas.rotateX(0.5)
                if fallback == .translucentTint {
                    canvas.shape(
                        shape,
                        at: [Placement(x: 0, y: 0, fill: .init(straightRed: 1, green: 1, blue: 1, alpha: 0.5))])
                } else {
                    canvas.shape(shape)
                }
                canvas.closeBatch()
                strokeBatches = canvas.batches.count { $0.strokeGeometry != nil }
            }
            return (try canvas.target.encodeToImage().read().bytes, strokeBatches, recorded)
        }
        let reference = try render(gpu: false)
        let placed = try render(gpu: true)
        #expect(placed.strokeBatches == 0, "\(fallback) を GPU で組んだ")
        if fallback == .translucentTint {
            // 記録の時点では組める (置き場所の色で外れる)
            #expect(placed.gpuStrokes == 1)
        } else {
            #expect(placed.gpuStrokes == 0, "\(fallback) を GPU で組める線として記録した")
        }
        #expect(placed.bytes == reference.bytes)
    }

    @Test("不透明な置き場所の色は、GPU で組んだ線にも CPU の帯と同じく掛かる")
    func opaqueTintsReachTheGPUStrokes() throws {
        func render(gpu: Bool) throws -> (bytes: [UInt8], strokeBatches: Int) {
            let canvas = try CanvasFixture.make(gpu: RenderDevice(), width: 120, height: 120)
            canvas.placesRetainedStrokesOnGPU = gpu
            var strokeBatches = 0
            try canvas.draw {
                canvas.background(.linear(red: 0, green: 0, blue: 0))
                let shape = canvas.createShape {
                    canvas.fill(.linear(red: 0.5, green: 0.5, blue: 0.5))
                    canvas.stroke(.linear(red: 0.9, green: 0.8, blue: 0.7))
                    canvas.strokeWeight(3)
                    canvas.box(30)
                }
                canvas.rotateX(0.4)
                canvas.shape(
                    shape,
                    at: [
                        Placement(x: 35, y: 60, fill: .linear(red: 1, green: 0.2, blue: 0.1)),
                        Placement(x: 85, y: 60, fill: .linear(red: 0.1, green: 0.6, blue: 1)),
                    ])
                canvas.closeBatch()
                strokeBatches = canvas.batches.count { $0.strokeGeometry != nil }
            }
            return (try canvas.target.encodeToImage().read().bytes, strokeBatches)
        }
        let reference = try render(gpu: false)
        let placed = try render(gpu: true)
        #expect(placed.strokeBatches == 2)
        #expect(placed.bytes == reference.bytes)
    }

    @Test("組にした形の線も GPU で組み、組まない形と同じ絵になる")
    func groupsCarryTheGPUStrokes() throws {
        func render(gpu: Bool) throws -> (bytes: [UInt8], strokeBatches: Int) {
            let canvas = try CanvasFixture.make(gpu: RenderDevice(), width: 120, height: 120)
            canvas.placesRetainedStrokesOnGPU = gpu
            var strokeBatches = 0
            try canvas.draw {
                canvas.background(.linear(red: 0, green: 0, blue: 0))
                let box = canvas.createShape {
                    canvas.fill(.linear(red: 0.2, green: 0.4, blue: 0.3))
                    canvas.stroke(.linear(red: 1, green: 1, blue: 1))
                    canvas.box(30)
                }
                let sphere = canvas.createShape {
                    canvas.noFill()
                    canvas.stroke(.linear(red: 1, green: 0.8, blue: 0.2))
                    canvas.translate(20, 0, 0)
                    canvas.sphere(12)
                }
                canvas.translate(50, 60, 0)
                canvas.rotateY(0.5)
                canvas.shape(Shape.group([box, sphere]))
                canvas.closeBatch()
                strokeBatches = canvas.batches.count { $0.strokeGeometry != nil }
            }
            return (try canvas.target.encodeToImage().read().bytes, strokeBatches)
        }
        let reference = try render(gpu: false)
        let placed = try render(gpu: true)
        #expect(placed.strokeBatches == 2)
        #expect(placed.bytes == reference.bytes)
    }

    @Test("途中で描き切っても、ほかの形と交互に置いても、重ね順が変わらない")
    func keepsTheOrderAcrossFlushes() throws {
        func render(gpu: Bool) throws -> [UInt8] {
            let canvas = try CanvasFixture.make(gpu: RenderDevice(), width: 120, height: 120)
            canvas.placesRetainedStrokesOnGPU = gpu
            try canvas.draw {
                canvas.background(.linear(red: 0, green: 0, blue: 0))
                let shape = canvas.createShape {
                    canvas.fill(.linear(red: 0.3, green: 0.3, blue: 0.6))
                    canvas.stroke(.linear(red: 1, green: 1, blue: 1))
                    canvas.box(30)
                    canvas.translate(10, 0, 5)
                    canvas.sphere(14)
                }
                for index in 0..<3 {
                    canvas.push()
                    canvas.translate(30 + Float(index) * 30, 60, Float(index) * 4)
                    canvas.rotateY(Float(index) * 0.4)
                    canvas.shape(shape)
                    canvas.pop()
                    // 半透明の面を挟む (重ね順が変われば色が変わる)
                    canvas.fill(.init(straightRed: 1, green: 0, blue: 0, alpha: 0.3))
                    canvas.noStroke()
                    canvas.rect(20 + Float(index) * 30, 40, 20, 40)
                    if index == 1 { _ = canvas.get(0, 0) }
                }
            }
            return try canvas.target.encodeToImage().read().bytes
        }
        #expect(try render(gpu: true) == render(gpu: false))
    }

    @Test("骨を控えから追い出しても、先に積んだ列が読み終わるまで生き、同じ絵になる")
    func anEvictedGeometryStaysReadable() throws {
        var pictures: [[UInt8]] = []
        for gpu in [false, true] {
            let canvas = try CanvasFixture.make(gpu: RenderDevice(), width: 120, height: 120)
            canvas.placesRetainedStrokesOnGPU = gpu
            // 1 件も残らない予算。置くたびに骨を作り直し、前の骨は列だけが持つ
            canvas.solidStrokeGeometry.budget = 1
            try canvas.draw {
                canvas.background(.linear(red: 0, green: 0, blue: 0))
                var shape: Shape? = canvas.createShape {
                    canvas.noFill()
                    canvas.stroke(.linear(red: 1, green: 1, blue: 1))
                    canvas.box(30)
                    canvas.sphere(20)
                }
                canvas.translate(60, 60, 0)
                canvas.rotateY(0.6)
                canvas.shape(shape!)
                // 形そのものも手放す (列が持つ資源で描く)
                shape = nil
            }
            pictures.append(try canvas.target.encodeToImage().read().bytes)
        }
        #expect(pictures[0] == pictures[1])
    }

    @Test("動かない場面では、保持した線の影も焼き直さない")
    func staticShadowsAreReused() throws {
        let canvas = try CanvasFixture.make(gpu: RenderDevice(), width: 120, height: 120)
        var shape: Shape?
        for _ in 0..<4 {
            try canvas.draw {
                canvas.directionalLight(.linear(red: 1, green: 1, blue: 1), -0.6, 0.6, -0.5)
                canvas.shadows(true)
                if shape == nil {
                    shape = canvas.createShape {
                        canvas.noFill()
                        canvas.stroke(.linear(red: 1, green: 1, blue: 1))
                        canvas.strokeWeight(4)
                        canvas.box(40)
                    }
                }
                canvas.translate(60, 60, 0)
                canvas.shape(shape!)
            }
        }
        #expect(canvas.shadowBakesEncoded == 1)
        #expect(canvas.shadowBakesReused == 3)
    }
}
