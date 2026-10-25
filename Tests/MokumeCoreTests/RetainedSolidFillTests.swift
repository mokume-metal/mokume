// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation
import Testing

@testable import MokumeCore

/// 保持した立体の塗りを GPU の置き場に持って使い回す (#2791)。
///
/// 物差しは **置き場を持たない従来の経路** (`retainsShapeSolids = false`・置くたびに溜め場へ積む) で、
/// どの場面でも、2 つの経路の絵が全バイトで一致することを見る。置き場に持てない場面 (透ける色・絵を貼った形・
/// 線を含む区間) は、持たずに従来の経路で描くことも見る。
@Suite("保持した立体の塗りの置き場", .enabled(if: RenderDevice.isAvailable, "GPU が無い環境ではスキップ"))
struct RetainedSolidFillTests {
    private func makeCanvas(retaining: Bool = true) throws -> Canvas {
        let canvas = try CanvasFixture.make(gpu: RenderDevice(), width: 96, height: 96)
        canvas.retainsShapeSolids = retaining
        // 検査の形は小さいので、下限は外す (下限そのものは専用の検査が見る)
        canvas.retainedSolidThreshold = 0
        return canvas
    }

    /// 4 色に塗り分けた絵。
    private func quadrants(_ canvas: Canvas) throws -> Image {
        let image = try canvas.createImage(8, 8)
        for y in 0..<8 {
            for x in 0..<8 {
                image.set(
                    x, y,
                    x < 4
                        ? (y < 4 ? .linear(red: 1, green: 0, blue: 0) : .linear(red: 0, green: 0, blue: 1))
                        : (y < 4 ? .linear(red: 0, green: 1, blue: 0) : .linear(red: 1, green: 1, blue: 1)))
            }
        }
        return image
    }

    /// 場面。
    enum Scene: String, CaseIterable, Sendable {
        /// 球を 2 か所に置く (添字なし)。
        case sphere
        /// 番号で指した四角を、回して置く (添字あり)。
        case indexedQuad
        /// 鏡映して置く (表の巻き方が変わる)。
        case mirrored
        /// 混ぜ方の違う 2 区間の形を、2 つの置き場所で置く (置き場所ごとに区間を一巡する)。重ねる混ぜ方の区間は
        /// 裏面が絵に出うるので置き場に持たず、もう一方の区間だけを持つ。
        case multiRun
        /// 違う形を 3 つ置く。
        case multiShape
        /// 記録のとき断片と値を載せた形。置く前に生きている断片の値を変える (断片は裏面が絵に出うるので置き場に持たない)。
        case shaderValues
        /// 同じ奥行きの 2 枚を、記録した順に重ねる。
        case sameDepth
        /// 影を落とし、床で受ける。動かない。
        case shadowStatic
        /// 影を落とし、置き場所を回す。
        case shadowMoving
        /// 影を落とす形を置いた後で画素を読み (途中の描き切り)、その後に床を置く。
        case shadowAfterFlush
        /// 透ける色で置く (置き場に持たない)。
        case translucentTint
        /// 絵を貼った形 (置き場に持たない)。
        case textured
        /// 線を含む形 (置き場に持たない)。
        case stroked

        /// 置き場に持てる場面か。
        var retains: Bool {
            switch self {
            case .translucentTint, .textured, .stroked, .shaderValues: false
            default: true
            }
        }
        /// 溜め場に即時の立体 (組み込みの形) を置かない場面。置き場に持った後の溜め場が空になる。
        var hasOnlyRetained: Bool {
            switch self {
            case .sphere, .indexedQuad, .mirrored, .multiShape, .sameDepth: true
            default: false
            }
        }
    }

    private struct Outcome {
        var pictures: [[UInt8]]
        var staged: [Int]
        var draws: [Int]
        var made: Int
        var bakesEncoded: Int
        var bakesReused: Int
    }

    private func indexedQuad(_ canvas: Canvas) -> Shape {
        canvas.createShape {
            canvas.noStroke()
            canvas.fill(.linear(red: 0.9, green: 0.4, blue: 0.2))
            canvas.beginShape(.triangles)
            for point in [(-18, -18), (18, -18), (-18, 18), (18, 18)] as [(Float, Float)] {
                canvas.vertex(point.0, point.1, 0)
            }
            // 添字の読み始めが 1 つずれると、四角の半分が欠ける並びにしてある
            for number in [0, 1, 2, 1, 3, 2] { canvas.index(number) }
            canvas.endShape()
        }
    }

    /// 場面を 4 フレーム回し、フレームごとの絵を返す。
    private func play(_ scene: Scene, retaining: Bool) throws -> Outcome {
        let canvas = try makeCanvas(retaining: retaining)
        let ball = canvas.createShape {
            canvas.noStroke()
            canvas.fill(.linear(red: 0.9, green: 0.7, blue: 0.4))
            canvas.sphere(18, detail: 16)
        }
        var shapes: [Shape] = [ball]
        let picture = try quadrants(canvas)
        switch scene {
        case .indexedQuad:
            shapes = [indexedQuad(canvas)]
            #expect(shapes[0].solidIndices.count == 6 && shapes[0].runs.allSatisfy(\.isIndexed), "添字を持つ形になっていない")
        case .multiRun:
            shapes = [
                canvas.createShape {
                    canvas.noStroke()
                    canvas.fill(.linear(red: 0.8, green: 0.5, blue: 0.3))
                    canvas.sphere(16, detail: 16)
                    canvas.blendMode(.add)
                    canvas.fill(.linear(red: 0.1, green: 0.3, blue: 0.6))
                    canvas.translate(12, 0, 0)
                    canvas.sphere(12, detail: 16)
                    canvas.blendMode(.blend)
                }
            ]
        case .multiShape:
            shapes = [
                ball,
                canvas.createShape {
                    canvas.noStroke()
                    canvas.fill(.linear(red: 0.3, green: 0.8, blue: 0.4))
                    canvas.box(22)
                },
                canvas.createShape {
                    canvas.noStroke()
                    canvas.fill(.linear(red: 0.4, green: 0.4, blue: 0.9))
                    canvas.sphere(14, detail: 8)
                },
            ]
        case .shaderValues:
            let shader = try canvas.makeShader(
                "float4 paint(Fragment in, Values values) { return float4(values.level, 0.3, 0.2, 1); }",
                values: ["level": 0.7])
            canvas.shader(shader)
            shapes = [
                canvas.createShape {
                    canvas.noStroke()
                    canvas.fill(.linear(red: 1, green: 1, blue: 1))
                    canvas.sphere(18, detail: 16)
                }
            ]
            canvas.resetShader()
            // 記録した値は形に焼き付く。置く前に生きている値を変えても、形の絵は変わらない
            shader.set("level", 0.1)
        case .sameDepth:
            shapes = [
                canvas.createShape {
                    canvas.noStroke()
                    canvas.fill(.linear(red: 1, green: 0, blue: 0))
                    canvas.plane(40, 40)
                },
                canvas.createShape {
                    canvas.noStroke()
                    canvas.fill(.linear(red: 0, green: 0, blue: 1))
                    canvas.plane(24, 24)
                },
            ]
        case .textured:
            shapes = [
                canvas.createShape {
                    canvas.noStroke()
                    canvas.texture(picture)
                    canvas.sphere(18, detail: 16)
                    canvas.noTexture()
                }
            ]
        case .stroked:
            shapes = [
                canvas.createShape {
                    canvas.stroke(.linear(red: 0.2, green: 0.9, blue: 1))
                    canvas.strokeWeight(2)
                    canvas.fill(.linear(red: 0.9, green: 0.5, blue: 0.2))
                    canvas.box(26)
                }
            ]
        default:
            break
        }

        var pictures: [[UInt8]] = []
        var staged: [Int] = []
        var draws: [Int] = []
        for frame in 0..<4 {
            try canvas.draw {
                canvas.background(.linear(red: 0.02, green: 0.02, blue: 0.03))
                canvas.camera(48, 48, 150, 48, 48, 0, 0, 1, 0)
                canvas.lights()
                canvas.noStroke()
                canvas.fill(.linear(red: 0.9, green: 0.7, blue: 0.4))
                switch scene {
                case .sphere, .textured, .stroked:
                    for x in [Float(30), 66] {
                        canvas.push(); canvas.translate(x, 48, 0); canvas.rotateY(0.5)
                        canvas.shape(shapes[0]); canvas.pop()
                    }
                case .indexedQuad:
                    canvas.shape(
                        shapes[0],
                        at: [Placement(x: 30, y: 48), Placement(x: 66, y: 48, rotation: Vector3(0, 0.6, 0))])
                case .mirrored:
                    canvas.push(); canvas.translate(30, 48, 0); canvas.shape(ball); canvas.pop()
                    canvas.push(); canvas.translate(66, 48, 0); canvas.scale(-1, 1, 1)
                    canvas.shape(ball); canvas.pop()
                case .multiRun:
                    canvas.shape(shapes[0], at: [Placement(x: 28, y: 48), Placement(x: 64, y: 48)])
                case .multiShape:
                    canvas.shape(shapes[0], 22, 30)
                    canvas.shape(shapes[1], 52, 48)
                    canvas.shape(shapes[2], 70, 70)
                case .shaderValues:
                    canvas.shape(shapes[0], 48, 48)
                case .sameDepth:
                    canvas.shape(shapes[0], 48, 48)
                    canvas.shape(shapes[1], 52, 52)
                case .shadowStatic, .shadowMoving, .shadowAfterFlush:
                    canvas.directionalLight(.linear(red: 0.8, green: 0.8, blue: 0.8), -0.6, 0.6, -0.5)
                    canvas.shadows(true)
                    canvas.castShadow(true)
                    canvas.push()
                    canvas.translate(48, 40, 0)
                    if scene == .shadowMoving { canvas.rotateY(0.3 + Float(frame) * 0.4) }
                    canvas.shape(ball)
                    canvas.pop()
                    if scene == .shadowAfterFlush { _ = canvas.get(0, 0) }
                    canvas.castShadow(false)
                    canvas.push(); canvas.translate(48, 48, -30); canvas.plane(90, 90); canvas.pop()
                case .translucentTint:
                    canvas.shape(
                        shapes[0],
                        at: [
                            Placement(
                                x: 30, y: 48,
                                fill: LinearRGBA(premultipliedRed: 0.45, green: 0.35, blue: 0.2, alpha: 0.5)),
                            Placement(x: 66, y: 48),
                        ])
                }
                staged.append(canvas.solidVertices.count)
            }
            draws.append(canvas.drawCallsInLastFrame)
            pictures.append(try canvas.target.encodeForDisplay().bytes)
        }
        return Outcome(
            pictures: pictures, staged: staged, draws: draws, made: canvas.modelFills.made,
            bakesEncoded: canvas.shadowBakesEncoded, bakesReused: canvas.shadowBakesReused)
    }

    private func differing(_ a: [UInt8], _ b: [UInt8]) -> Int {
        stride(from: 0, to: a.count, by: 4).filter { a[$0..<($0 + 4)] != b[$0..<($0 + 4)] }.count
    }

    @Test("置き場に持っても、持たないときと同じ絵・同じ描く回数になる", arguments: Scene.allCases)
    func retainingDrawsTheSamePicture(_ scene: Scene) throws {
        let reference = try play(scene, retaining: false)
        let retained = try play(scene, retaining: true)
        // 物差しに形が写っていること (背景以外の画素)
        let drawn = stride(from: 0, to: reference.pictures[0].count, by: 4).filter {
            reference.pictures[0][$0] > 40 || reference.pictures[0][$0 + 1] > 40
                || reference.pictures[0][$0 + 2] > 40
        }.count
        #expect(drawn > 50, "物差しに形が写っていない — 比べる前提が崩れている (\(drawn) 画素)")
        for frame in 0..<4 {
            let count = differing(reference.pictures[frame], retained.pictures[frame])
            #expect(count == 0, "\(scene.rawValue): \(frame) 枚目で \(count) 画素が違う")
        }
        #expect(retained.draws == reference.draws, "\(scene.rawValue): 描く回数が違う \(retained.draws) / \(reference.draws)")
        #expect(reference.made == 0)
        if scene.retains {
            #expect(retained.made >= 1, "\(scene.rawValue): 置き場に持てていない")
            if scene.hasOnlyRetained {
                #expect(retained.staged[1...].allSatisfy { $0 == 0 }, "\(scene.rawValue): 溜め場へ積んでいる \(retained.staged)")
            }
        } else {
            #expect(retained.made == 0, "\(scene.rawValue): 持てない場面で置き場を作っている")
            #expect(retained.staged.allSatisfy { $0 > 0 })
        }
    }

    @Test("影の焼き直しを省く判定は、置き場に持っても持たなくても同じに効く",
        arguments: [Scene.shadowStatic, .shadowMoving, .shadowAfterFlush])
    func shadowReuseIsUnchanged(_ scene: Scene) throws {
        let reference = try play(scene, retaining: false)
        let retained = try play(scene, retaining: true)
        // 置き場に持った瞬間 (2 フレーム目) は、頂点で取っていた指紋が形の見分けで取る指紋に替わるので、
        // 1 度だけ焼き直す。それ以降は、持たない経路と同じ回数だけ焼き、同じ回数だけ使い回す
        let promotion = scene == .shadowMoving ? 0 : 1
        #expect(reference.bakesEncoded == (scene == .shadowMoving ? 4 : 1))
        #expect(retained.bakesEncoded == reference.bakesEncoded + promotion, "焼き直しの回数が違う")
        #expect(
            retained.bakesEncoded + retained.bakesReused == reference.bakesEncoded + reference.bakesReused,
            "焼き付けを問われた回数が違う")
    }

    @Test("別の形に差し替えたら、影を焼き直す (形の見分けが指紋に効く)")
    func swappingTheShapeRebakesTheShadow() throws {
        let canvas = try makeCanvas()
        let small = canvas.createShape {
            canvas.noStroke(); canvas.fill(255); canvas.sphere(10, detail: 16)
        }
        let large = canvas.createShape {
            canvas.noStroke(); canvas.fill(255); canvas.sphere(20, detail: 16)
        }
        func frame(_ shape: Shape) throws {
            try canvas.draw {
                canvas.background(0)
                canvas.lights()
                canvas.directionalLight(.linear(red: 0.8, green: 0.8, blue: 0.8), -0.6, 0.6, -0.5)
                canvas.shadows(true)
                canvas.shape(shape, 48, 40)
                canvas.castShadow(false)
                canvas.push(); canvas.translate(48, 48, -30); canvas.plane(90, 90); canvas.pop()
            }
        }
        // 置き場に持つ 2 フレーム目に、頂点で取っていた指紋が形の見分けで取る指紋に替わって 1 度焼き直す
        for _ in 0..<3 { try frame(small) }
        #expect(canvas.shadowBakesEncoded == 2)
        try frame(small)
        #expect(canvas.shadowBakesEncoded == 2, "動かない場面で影を焼き直している")
        // 別の形に替えると焼き直す。初めて置いた回 (頂点で取る) と、置き場に持った回 (見分けで取る) の 2 回
        try frame(large)
        #expect(canvas.shadowBakesEncoded == 3, "別の形に替えたのに影を焼き直していない")
        try frame(large)
        #expect(canvas.shadowBakesEncoded == 4)
        try frame(large)
        #expect(canvas.shadowBakesEncoded == 4)
    }

    @Test("指紋は同じ形の別の区間を見分け、持ち越すときの取り出し方によらない")
    func theDigestSeparatesRunsAndIgnoresHowTheBatchIsTaken() throws {
        let canvas = try makeCanvas()
        let ball = canvas.createShape {
            canvas.noStroke(); canvas.fill(255); canvas.sphere(16, detail: 16)
        }
        // 設定が同じで位置だけが違う 2 区間 (作り手が畳まなかった形)。球の三角形を半分ずつに割る
        var first = ball.runs[0]
        first.count = first.count / 2
        var second = first
        second.start = first.count
        let shape = Shape(vertices: [], solidVertices: ball.solidVertices, runs: [first, second])
        var digests: [UInt64] = []
        var kept: [UInt64] = []
        var sources: Set<Canvas.SolidSource> = []
        for frame in 0..<3 {
            try canvas.draw {
                canvas.shape(shape, 48, 48)
                canvas.closeBatch()
                if frame == 2 {
                    #expect(canvas.batches.count == 2)
                    for batch in canvas.batches {
                        sources.insert(batch.solidSource ?? .freeform)
                        digests.append(canvas.casterDigest(canvas.compact(batch, forDigest: true))!)
                        kept.append(canvas.casterDigest(canvas.compact(batch))!)
                    }
                }
            }
        }
        #expect(sources == [.retainedGeometry(id: shape.solidGeometryID)], "同じ形の 2 区間が置き場から読まれていない")
        #expect(digests.count == 2 && digests[0] != digests[1], "区間が違うのに指紋が同じ")
        #expect(digests == kept, "取り出し方で指紋が変わる (区切りの回と終わりの回で食い違う)")
    }

    @Test("毎フレーム組み直す形には、置き場を作らない")
    func aShapeRebuiltEveryFrameIsNotRetained() throws {
        let canvas = try makeCanvas()
        for _ in 0..<5 {
            let fresh = canvas.createShape {
                canvas.noStroke(); canvas.fill(255); canvas.sphere(18, detail: 16)
            }
            try canvas.draw { canvas.shape(fresh, 48, 48) }
        }
        #expect(canvas.modelFills.made == 0)
    }

    @Test("下限に満たない形には、置き場を作らない")
    func aShapeBelowTheThresholdIsNotRetained() throws {
        let canvas = try makeCanvas()
        canvas.retainedSolidThreshold = 1 << 30
        let ball = canvas.createShape {
            canvas.noStroke(); canvas.fill(255); canvas.sphere(18, detail: 16)
        }
        for _ in 0..<4 { try canvas.draw { canvas.shape(ball, 48, 48) } }
        #expect(canvas.modelFills.made == 0)
    }

    @Test("1 つで予算の半分を超える形は持たず、溜め場で描く")
    func anOversizedShapeIsNotRetained() throws {
        let canvas = try makeCanvas()
        canvas.modelFills.budget = 1_000
        let ball = canvas.createShape {
            canvas.noStroke(); canvas.fill(255); canvas.sphere(18, detail: 16)
        }
        for _ in 0..<4 {
            try canvas.draw {
                canvas.shape(ball, 48, 48)
                #expect(!canvas.solidVertices.isEmpty, "持たないのに溜め場へも積んでいない")
            }
        }
        #expect(canvas.modelFills.made == 0)
    }

    @Test("控えから追い出した置き場も、先に積んだ列が読み終わるまで生きる")
    func anEvictedFillStaysReadableForTheOpenFrame() throws {
        func shapes(_ canvas: Canvas) -> [Shape] {
            [(12, 0.9), (14, 0.5), (16, 0.2)].map { radius, red in
                canvas.createShape {
                    canvas.noStroke()
                    canvas.fill(.linear(red: Float(red), green: 0.6, blue: 0.3))
                    canvas.sphere(Float(radius), detail: 8)
                }
            }
        }
        var pictures: [[UInt8]] = []
        var made = 0
        var count = 0
        for retaining in [false, true] {
            let canvas = try makeCanvas(retaining: retaining)
            let balls = shapes(canvas)
            // 球 1 つは頂点 192 個 = 18,432 バイト (重さは + 256)。予算をその 2 倍強にすると、どれも
            // 「1 つで予算の半分以下」で持たれるが、3 つ目を入れると 1 つ目が外れる
            canvas.modelFills.budget = 2 * (192 * MemoryLayout<SolidVertex>.stride + 256) + 10
            for _ in 0..<3 {
                try canvas.draw {
                    canvas.background(.linear(red: 0, green: 0, blue: 0))
                    canvas.lights()
                    canvas.shape(balls[0], 28, 48)
                    canvas.shape(balls[1], 48, 48)
                    canvas.shape(balls[2], 68, 48)
                    canvas.shape(balls[0], 48, 20)
                }
            }
            pictures.append(try canvas.target.encodeForDisplay().bytes)
            if retaining { made = canvas.modelFills.made; count = canvas.modelFills.count }
        }
        #expect(made >= 4, "追い出しが起きていない (作った数 \(made))")
        #expect(count == 2)
        #expect(differing(pictures[0], pictures[1]) == 0)
    }

    @Test("同じ形を 2 つの Canvas に置いても、それぞれの置き場から同じ絵になる")
    func theSameShapeOnTwoCanvases() throws {
        let gpu = try RenderDevice()
        func make(retaining: Bool) throws -> Canvas {
            let canvas = try CanvasFixture.make(gpu: gpu, width: 96, height: 96)
            canvas.retainsShapeSolids = retaining
            canvas.retainedSolidThreshold = 0
            return canvas
        }
        let owner = try make(retaining: true)
        let ball = owner.createShape {
            owner.noStroke(); owner.fill(.linear(red: 0.9, green: 0.7, blue: 0.4)); owner.sphere(18, detail: 16)
        }
        var pictures: [[UInt8]] = []
        var made: [Int] = []
        for canvas in [owner, try make(retaining: true), try make(retaining: false)] {
            for _ in 0..<3 {
                try canvas.draw {
                    canvas.background(.linear(red: 0, green: 0, blue: 0))
                    canvas.lights()
                    canvas.shape(ball, 48, 48)
                }
            }
            pictures.append(try canvas.target.encodeForDisplay().bytes)
            made.append(canvas.modelFills.made)
        }
        #expect(made == [1, 1, 0], "置き場は Canvas ごとに持つ: \(made)")
        #expect(differing(pictures[0], pictures[2]) == 0)
        #expect(differing(pictures[1], pictures[2]) == 0)
    }

    @Test("何フレーム描いても、常駐する資源の数は増え続けない")
    func residencyStaysFlat() throws {
        let canvas = try makeCanvas()
        let ball = canvas.createShape {
            canvas.noStroke(); canvas.fill(255); canvas.sphere(18, detail: 16)
        }
        func frame() throws { try canvas.draw { canvas.shape(ball, 48, 48) } }
        for _ in 0..<4 { try frame() }
        try canvas.gpu.settle()
        let warmed = canvas.gpu.residencySet.allocationCount
        for _ in 0..<12 { try frame() }
        try canvas.gpu.settle()
        #expect(canvas.gpu.residencySet.allocationCount == warmed)
    }
}

@Suite("保持した形の立体の見分け")
struct ShapeGeometryIDTests {
    @Test("別々に組んだ形は別の見分けを持ち、値の複製は同じ見分けを持つ")
    func shapesBuiltSeparatelyDiffer() {
        let a = Shape(vertices: [], runs: [])
        let b = Shape(vertices: [], runs: [])
        let copy = a
        #expect(a.solidGeometryID != b.solidGeometryID)
        #expect(copy.solidGeometryID == a.solidGeometryID)
        let grouped = Shape.group([a, b])
        let sum = a + b
        let ids = [a, b, grouped, sum, Shape.empty].map(\.solidGeometryID)
        #expect(Set(ids).count == ids.count, "別の形が同じ見分けを持つ: \(ids)")
        #expect(grouped.solidGeometryID != sum.solidGeometryID)
    }

    @Test("見分けは、どの隔離から同時に採っても重ならない")
    func idsAreUniqueAcrossConcurrentCallers() async {
        let batches = await withTaskGroup(of: [Int].self) { group in
            for _ in 0..<8 {
                group.addTask { (0..<500).map { _ in Shape.nextSolidGeometryID() } }
            }
            var all: [[Int]] = []
            for await ids in group { all.append(ids) }
            return all
        }
        let flat = batches.flatMap { $0 }
        #expect(flat.count == 4000)
        #expect(Set(flat).count == flat.count, "見分けが重なった")
    }
}
