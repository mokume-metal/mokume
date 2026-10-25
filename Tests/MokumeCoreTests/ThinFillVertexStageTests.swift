// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation
import Metal
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
            #expect(canvas.thinFillSpans.count == count, "記述: \(canvas.thinFillSpans.count)")
            // 長さ 40 は、刻みの端の丸めで 40〜41 片の区間 (40 か 48)
            #expect([40, 48].contains(canvas.openFlat?.key.thinFillCapacity ?? 0))
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
            #expect(canvas.thinFillSpans.count == count)
            #expect(canvas.openFlat?.key.thinFillCapacity == 1)
        }
    }

    /// 長さ `length` (描く画素) の細い楕円を、回転を変えて 1 つ置く。
    private func placeEllipse(_ canvas: Canvas, length: Float, at index: Int) {
        canvas.pushMatrix()
        canvas.translate(64, 64)
        canvas.rotate(Float(index) * 0.3)
        canvas.scale(length / 40, length / 40)
        canvas.ellipse(0, 0, 40, 0.5)
        canvas.popMatrix()
    }

    /// 片の数の区間は 1・10・64 の 3 つで、**雛形は区間が上がるときだけ開き直す**。小さい区間の置き場所は
    /// 大きい区間の雛形に受ける (使わない片は頂点段が潰す)。
    @Test("片の数の区間が下がる並びは、1 つの雛形に畳まれる")
    func descendingLengthsFoldIntoOneTemplate() throws {
        let canvas = try Self.makeCanvas(density: 1)
        let shader = try canvas.makeShader(Self.plain)
        try canvas.draw {
            canvas.background(0)
            canvas.noStroke()
            canvas.fill(255)
            canvas.shader(shader)
            // 長さ 60 (64 の区間)・30 (64)・6 (10 の区間)・0.4 (1 の区間) を、大きいほうから
            for (index, length) in [Float(60), 50, 40, 30, 20, 6, 5, 4, 0.4, 0.3].enumerated() {
                placeEllipse(canvas, length: length, at: index)
            }
            #expect(canvas.thinFillSpans.count == 10, "記述: \(canvas.thinFillSpans.count)")
            #expect(canvas.openFlat?.key.thinFillCapacity == Canvas.thinEllipseSliceLimit)
        }
    }

    @Test("区間が上がるときだけ雛形が開き直り、上がった後は交互に置いても割れない")
    func regionsSplitOnlyWhenRising() throws {
        let canvas = try Self.makeCanvas(density: 1)
        let shader = try canvas.makeShader(Self.plain)
        try canvas.draw {
            canvas.background(0)
            canvas.noStroke()
            canvas.fill(255)
            canvas.shader(shader)
            // 小さい区間を 3 つずつ、大きい区間へ上がりながら: 区間ごとに 1 度開くだけ
            for (index, length) in [Float(0.4), 0.3, 0.2, 6, 5, 4, 50, 40, 30].enumerated() {
                placeEllipse(canvas, length: length, at: index)
            }
            #expect(canvas.thinFillSpans.count == 9, "記述: \(canvas.thinFillSpans.count)")
            // 長さ 50 は 56 片の区間。後の 40・30 は同じ雛形に受ける
            #expect(canvas.openFlat?.key.thinFillCapacity == 56)
            // 上がった後は、小さい区間と大きい区間が交互に来ても割れない
            let before = canvas.outlinesAssembledThisFrame
            for index in 0..<12 {
                placeEllipse(canvas, length: index % 2 == 0 ? 55 : 0.5, at: index)
            }
            #expect(canvas.outlinesAssembledThisFrame == before, "交互の置き場所で雛形が割れた")
            #expect(canvas.thinFillSpans.count == 21)
        }
    }

    /// 1 画素より小さい円や短い楕円は、置き場所ごとに 64 片ぶん (384 頂点) の頂点関数を回さない。
    @Test("小さい円・短い楕円の雛形は、それぞれ 1 片・10 片ぶんの頂点だけを持つ")
    func smallShapesTemplatesStayCompact() throws {
        for (length, pieces) in [(Float(0.4), 1), (6, 10), (14, 16), (39.5, 40), (63.5, 64)] {
            let canvas = try Self.makeCanvas(density: 1)
            let shader = try canvas.makeShader(Self.plain)
            try canvas.draw {
                canvas.background(0)
                canvas.noStroke()
                canvas.fill(255)
                canvas.shader(shader)
                let before = canvas.vertices.count
                for index in 0..<20 { placeEllipse(canvas, length: length, at: index) }
                #expect(canvas.thinFillSpans.count == 20)
                #expect(
                    canvas.vertices.count - before == pieces * 6,
                    "長さ \(length): 頂点 \(canvas.vertices.count - before)")
                #expect(canvas.openFlat?.key.thinFillCapacity == pieces)
            }
        }
    }

    /// 向きと寸法が同じ置き場所は記述も同じ。続けて置くあいだは求め直さない。
    @Test("向きと寸法が同じ置き場所は、細い塗りの記述を求め直さない")
    func sameOrientationReusesTheRecord() throws {
        let canvas = try Self.makeCanvas(density: 1)
        let shader = try canvas.makeShader(Self.plain)
        try canvas.draw {
            canvas.background(0)
            canvas.noStroke()
            canvas.fill(255)
            canvas.shader(shader)
            let before = canvas.thinFillRecordsBuilt
            for index in 0..<30 {
                canvas.pushMatrix()
                canvas.translate(10 + Float(index) * 3, 40)
                canvas.ellipse(0, 0, 8, 0.4)
                canvas.popMatrix()
            }
            #expect(canvas.thinFillRecordsBuilt - before == 1, "求めた数: \(canvas.thinFillRecordsBuilt - before)")
            #expect(canvas.thinFillSpans.count == 30)
            // 同じ記述は足し直さず、30 の置き場所が 1 つの記述を指す
            #expect(canvas.thinFillRecords.count == 1, "記述の数: \(canvas.thinFillRecords.count)")
            // 向きが変われば求め直す (最初の置き場所は回転 0 で、直前と同じ向きなので控えが効く)
            let rotating = canvas.thinFillRecordsBuilt
            for index in 0..<30 {
                canvas.pushMatrix()
                canvas.translate(10 + Float(index) * 3, 80)
                canvas.rotate(Float(index) * 0.2)
                canvas.ellipse(0, 0, 8, 0.4)
                canvas.popMatrix()
            }
            #expect(canvas.thinFillRecordsBuilt - rotating == 29)
        }
    }

    /// 置き場所の記述の並びは「先頭と数」で引く。塗りは 1 つの記述だが、並びは複数の記述を持てる形である。
    @Test("置き場所の記述は、先頭と数で引ける並びで足される")
    func spansIndexTheirRecords() throws {
        let canvas = try Self.makeCanvas(density: 1)
        let shader = try canvas.makeShader(Self.plain)
        try canvas.draw {
            canvas.background(0)
            canvas.noStroke()
            canvas.fill(255)
            canvas.shader(shader)
            for index in 0..<5 { placeEllipse(canvas, length: 40, at: index) }
            #expect(canvas.thinFillSpans.count == 5)
            #expect(canvas.thinFillRecords.count == 5)
            for (index, span) in canvas.thinFillSpans.enumerated() {
                #expect(span.first == UInt32(index) && span.count == 1)
            }
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

    /// **許容は 0** — 片の角の積和は頂点段と CPU で `fma` の順を固定しているので、1 成分も違わない。
    private func expectSame(
        _ name: String, density: Float = 1, texture: Bool = false,
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
            differing == 0, "\(name): 画素の成分が \(differing) 個違う (点いている成分 \(lit))")
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
            #expect(!canvas.expandsThinFillsInVertexStage || canvas.thinFillSpans.count == 30, "畳まれていない")
        }
    }

    @Test("短い楕円・小さい円・細長い rect は、CPU で組み直す畳みと画素が同じ")
    func shortAndSmallShapesKeepTheirPixels() throws {
        try expectSame("短い楕円") { canvas in
            scatter(canvas, spin: 0.37, scale: { (0.5 + Float($0 % 7) * 0.15, 1) }) {
                canvas.ellipse(0, 0, 8, 0.4)
            }
            #expect(!canvas.expandsThinFillsInVertexStage || canvas.thinFillSpans.count == 30, "畳まれていない")
        }
        try expectSame("小さい円") { canvas in
            scatter(canvas, spin: 0.5, scale: { (0.3 + Float($0 % 5) * 0.13, 1) }) {
                canvas.circle(0, 0, 1)
            }
            #expect(!canvas.expandsThinFillsInVertexStage || canvas.thinFillSpans.count == 30, "畳まれていない")
        }
        try expectSame("細長い rect") { canvas in
            scatter(canvas, spin: 0.29, scale: { (1 + Float($0 % 3) * 0.1, 1) }) {
                canvas.rect(-12, -0.4, 24, 0.8)
            }
            #expect(!canvas.expandsThinFillsInVertexStage || canvas.thinFillSpans.count == 30, "畳まれていない")
        }
        try expectSame("短い rect") { canvas in
            scatter(canvas, spin: 0.33, scale: { (1 + Float($0 % 4) * 0.2, 1) }) {
                canvas.rect(-3, -0.4, 6, 0.8)
            }
            #expect(!canvas.expandsThinFillsInVertexStage || canvas.thinFillSpans.count == 30, "畳まれていない")
        }
    }

    @Test("細かさ 0.5 の細い塗りも、CPU で組み直す畳みと画素が同じ")
    func halfDensityKeepsItsPixels() throws {
        try expectSame("細かさ 0.5 の rect", density: 0.5) { canvas in
            scatter(canvas, spin: 0.23) { canvas.rect(-14, -0.5, 28, 1) }
            #expect(!canvas.expandsThinFillsInVertexStage || canvas.thinFillSpans.count == 30, "畳まれていない")
        }
        try expectSame("細かさ 0.5 の楕円", density: 0.5) { canvas in
            scatter(canvas, spin: 0.23) { canvas.ellipse(0, 0, 28, 0.8) }
            #expect(!canvas.expandsThinFillsInVertexStage || canvas.thinFillSpans.count == 30, "畳まれていない")
        }
    }

    @Test("貼る絵の細い塗りも、読み取り位置まで CPU で組み直す畳みと画素が同じ")
    func texturedFillsKeepTheirPixels() throws {
        try expectSame("貼る絵の rect", texture: true) { canvas in
            scatter(canvas, spin: 0.27) { canvas.rect(-10, -0.5, 20, 1) }
        }
        try expectSame("貼る絵の楕円", texture: true) { canvas in
            scatter(canvas, spin: 0.27) { canvas.ellipse(0, 0, 20, 0.7) }
        }
    }

    // MARK: - 変換・置き方の幅

    /// 置き場所ごとに `transform` で変換を替えて、`draw` を 30 回置く。
    private func place(
        _ canvas: Canvas, count: Int = 30, transform: (Canvas, Int) -> Void, draw: () -> Void
    ) {
        for index in 0..<count {
            canvas.pushMatrix()
            canvas.translate(16 + Float(index % 6) * 19, 16 + Float(index / 6) * 19)
            transform(canvas, index)
            draw()
            canvas.popMatrix()
        }
    }

    @Test("負の倍率・鏡映で置いた細い塗りも、CPU で組み直す畳みと画素が同じ")
    func mirroredPlacementsKeepTheirPixels() throws {
        for (name, flip) in [
            ("x を反転", { (c: Canvas, i: Int) in c.scale(-1, 1); c.rotate(Float(i) * 0.31) }),
            ("y を反転", { (c: Canvas, i: Int) in c.scale(1, -1); c.rotate(Float(i) * 0.31) }),
            ("負の一様な倍率", { (c: Canvas, i: Int) in c.rotate(Float(i) * 0.31); c.scale(-0.8, -0.8) }),
            ("反転と縦横違いの倍率", { (c: Canvas, i: Int) in c.scale(-1.3, 0.7); c.rotate(Float(i) * 0.31) }),
        ] {
            try expectSame("鏡映の長い楕円 (\(name))") { canvas in
                place(canvas, transform: flip) { canvas.ellipse(0, 0, 24, 0.5) }
                #expect(!canvas.expandsThinFillsInVertexStage || canvas.thinFillSpans.count == 30, "畳まれていない")
            }
            try expectSame("鏡映の短い楕円 (\(name))", texture: true) { canvas in
                place(canvas, transform: flip) { canvas.ellipse(0, 0, 8, 0.4) }
            }
            try expectSame("鏡映の rect (\(name))") { canvas in
                place(canvas, transform: flip) { canvas.rect(-10, -0.4, 20, 0.8) }
            }
        }
    }

    @Test("極端な回転と剪断で置いた細い塗りも、CPU で組み直す畳みと画素が同じ")
    func shearedPlacementsKeepTheirPixels() throws {
        let shears: [(String, (Canvas, Int) -> Void)] = [
            ("x の剪断", { c, i in c.rotate(Float(i) * 0.41); c.shearX(1.2) }),
            ("y の剪断", { c, i in c.shearY(-0.9); c.rotate(Float(i) * 0.41) }),
            ("回した後の縦横違いの倍率", { c, i in c.rotate(Float(i) * 0.53 + 0.7); c.scale(3, 0.2) }),
            ("ほぼ潰れた変換", { c, i in c.rotate(Float(i) * 0.19); c.scale(1, 0.02) }),
        ]
        for (name, shear) in shears {
            try expectSame("剪断の長い楕円 (\(name))") { canvas in
                place(canvas, transform: shear) { canvas.ellipse(0, 0, 26, 0.5) }
            }
            try expectSame("剪断の rect (\(name))") { canvas in
                place(canvas, transform: shear) { canvas.rect(-12, -0.4, 24, 0.8) }
            }
            try expectSame("剪断の貼る絵の rect (\(name))", texture: true) { canvas in
                place(canvas, transform: shear) { canvas.rect(-6, -0.4, 12, 0.8) }
            }
        }
    }

    @Test("細い塗りと輪郭が同じ雛形にあっても、CPU で組み直す畳みと画素が同じ")
    func fillAndStrokeShareATemplate() throws {
        try expectSame("細い塗り + 輪郭の楕円") { canvas in
            canvas.stroke(255, 0, 0)
            canvas.strokeWeight(2)
            place(canvas, transform: { c, i in c.rotate(Float(i) * 0.27) }) {
                canvas.ellipse(0, 0, 26, 0.5)
            }
            #expect(!canvas.expandsThinFillsInVertexStage || canvas.thinFillSpans.count == 30, "畳まれていない")
        }
        try expectSame("細い塗り + 輪郭の rect") { canvas in
            canvas.stroke(0, 255, 0)
            canvas.strokeWeight(1.5)
            place(canvas, transform: { c, i in c.rotate(Float(i) * 0.27) }) {
                canvas.rect(-12, -0.4, 24, 0.8)
            }
        }
    }

    /// 貼る絵と輪郭を同時に持つ図形と、破線の輪郭を持つ図形は畳まない (線の経路の決定を待つ・決定 2a)。
    /// 頂点段の広げ方は当たらず、直す前と同じ CPU の経路のままである。
    @Test("貼る絵と輪郭、破線の輪郭を持つ細い塗りは畳まず、頂点段の広げ方は当たらない")
    func strokedTexturedAndDashedFillsStayOnTheCPURoute() throws {
        try expectSame("貼る絵 + 輪郭", texture: true) { canvas in
            canvas.stroke(255, 0, 0)
            canvas.strokeWeight(2)
            place(canvas, transform: { c, i in c.rotate(Float(i) * 0.27) }) {
                canvas.ellipse(0, 0, 26, 0.5)
            }
            #expect(canvas.thinFillSpans.isEmpty, "貼る絵と輪郭の図形が畳まれた")
        }
        try expectSame("破線の輪郭") { canvas in
            canvas.stroke(255, 0, 0)
            canvas.strokeWeight(2)
            canvas.strokeDash(4, 3)
            place(canvas, transform: { c, i in c.rotate(Float(i) * 0.27) }) {
                canvas.ellipse(0, 0, 26, 0.5)
            }
            #expect(canvas.thinFillSpans.isEmpty, "破線の輪郭の図形が畳まれた")
        }
    }

    @Test("一周の arc は楕円と同じに畳み、扇は畳まない")
    func fullTurnArcsFoldAndFansDoNot() throws {
        try expectSame("一周の arc") { canvas in
            place(canvas, transform: { c, i in c.rotate(Float(i) * 0.27) }) {
                canvas.arc(0, 0, 26, 0.5, 0, 2 * Float.pi)
            }
            #expect(!canvas.expandsThinFillsInVertexStage || canvas.thinFillSpans.count == 30, "畳まれていない")
        }
        try expectSame("扇") { canvas in
            place(canvas, transform: { c, i in c.rotate(Float(i) * 0.27) }) {
                canvas.arc(0, 0, 26, 0.5, 0, Float.pi)
            }
            #expect(canvas.thinFillSpans.isEmpty, "扇が頂点段で広げられた")
        }
    }

    @Test("置き場所の上限で雛形を開き直しても、CPU で組み直す畳みと画素が同じ")
    func reopeningAtTheInstanceLimitKeepsPixels() throws {
        try expectSame("上限 7 で開き直す") { canvas in
            canvas.instanceCapacity = 7
            place(canvas, transform: { c, i in c.rotate(Float(i) * 0.27) }) {
                canvas.ellipse(0, 0, 26, 0.5)
            }
            #expect(!canvas.expandsThinFillsInVertexStage || canvas.thinFillSpans.count == 30, "畳まれていない")
            // 6 つの雛形に割れて、どれも自分の記述の先頭を指している
            if canvas.expandsThinFillsInVertexStage {
                let starts = canvas.batches.map(\.thinFillStart).filter { $0 > 0 }
                #expect(starts == starts.sorted() && Set(starts).count == starts.count)
            }
        }
    }

    @Test("畳む細い塗りと畳まない細い塗り、細くない塗りが混ざっても、画素が同じ")
    func foldedAndUnfoldedFillsMix() throws {
        try expectSame("畳む細い楕円と細くない同じ楕円") { canvas in
            place(
                canvas,
                transform: { c, i in
                    c.rotate(Float(i) * 0.27)
                    if i % 3 == 0 { c.scale(1, 14) }
                }
            ) { canvas.ellipse(0, 0, 26, 0.5) }
        }
        try expectSame("畳む細い楕円と寸法がばらばらで畳まない細い楕円") { canvas in
            var index = 0
            place(
                canvas, transform: { c, i in c.rotate(Float(i) * 0.27) }
            ) {
                index += 1
                // 3 つに 1 つは寸法が違い、別の鍵になって畳まれない
                canvas.ellipse(0, 0, index % 3 == 0 ? 20 + Float(index) : 26, 0.5)
            }
        }
    }

    /// 置き場所の位置 (anchor) が 0 でない場面。CPU が畳まずに置くときは周の中心へ位置を足してから変換し、
    /// 畳んだ雛形は位置を変換の後で足すので、頂点段が同じ順で置かないと丸めが別になる。ほかの場面は
    /// `translate` の後に原点で描くので位置が 0 で、この差が見えない。
    @Test("置き場所の位置が 0 でない細い塗りも、CPU で組み直す畳みと画素が同じ")
    func offsetPlacementsKeepTheirPixels() throws {
        try expectSame("原点以外の楕円") { canvas in
            place(canvas, transform: { c, i in c.rotate(Float(i) * 0.27) }) {
                canvas.ellipse(11.3, 5.7, 26, 0.5)
            }
            #expect(!canvas.expandsThinFillsInVertexStage || canvas.thinFillSpans.count == 30, "畳まれていない")
        }
        try expectSame("原点以外の短い楕円", texture: true) { canvas in
            place(canvas, transform: { c, i in c.rotate(Float(i) * 0.37); c.scale(0.6 + Float(i % 5) * 0.2, 1) }) {
                canvas.ellipse(7.7, 3.1, 8, 0.4)
            }
        }
        try expectSame("原点以外の rect") { canvas in
            place(canvas, transform: { c, i in c.rotate(Float(i) * 0.31) }) {
                canvas.rect(3.1, 5.7, 24, 0.8)
            }
        }
        try expectSame("原点以外の貼る絵の rect と鏡映", texture: true) { canvas in
            place(canvas, transform: { c, i in c.scale(-1, 1); c.rotate(Float(i) * 0.29) }) {
                canvas.rect(-9.3, 4.9, 20, 0.6)
            }
        }
        try expectSame("原点以外の細かさ 0.5", density: 0.5) { canvas in
            place(canvas, transform: { c, i in c.rotate(Float(i) * 0.23) }) {
                canvas.ellipse(10.1, -6.3, 28, 0.8)
            }
        }
        // translate なしで回す (平行移動が 0 で、位置だけが変換に載る)
        try expectSame("translate なしの回転") { canvas in
            for index in 0..<30 {
                canvas.pushMatrix()
                canvas.translate(2, 2)
                canvas.rotate(Float(index) * 0.05)
                canvas.ellipse(37.3 + Float(index), 11.7 + Float(index) * 2, 26, 0.5)
                canvas.popMatrix()
            }
        }
    }

    // MARK: - 角丸の rect (#3170)

    /// 場面 R の角丸版: 細かさ 0.5・全部違う回転の `rect(-20, -0.5, 40, 1, 0.4)` を 10,000 個。
    @Test("回転が全部違う細い角丸 rect は、1 つの雛形に畳まれる")
    func rotatedRoundedRectsFoldIntoOneTemplate() throws {
        let canvas = try Self.makeCanvas(density: 0.5)
        let shader = try canvas.makeShader(Self.plain)
        let count = 10_000
        try canvas.draw {
            canvas.background(0)
            canvas.noStroke()
            canvas.fill(255)
            canvas.shader(shader)
            for index in 0..<count {
                canvas.pushMatrix()
                canvas.translate(64, 64)
                canvas.rotate(Float(index) * 0.113 + 0.02)
                canvas.rect(-20, -0.5, 40, 1, 0.4)
                canvas.popMatrix()
            }
            #expect(canvas.openFlat != nil, "細い角丸 rect が畳まれない")
            #expect(canvas.flatInstances.count == count + 1, "置き場所: \(canvas.flatInstances.count)")
            #expect(canvas.thinFillSpans.count == count, "記述: \(canvas.thinFillSpans.count)")
            #expect(canvas.openFlat?.key.thinFillCapacity == 1)
            // 周は雛形の 1 回だけ (置き場所ごとに組み直さない)
            #expect(canvas.outlinesAssembledThisFrame < 10, "周を組んだ数: \(canvas.outlinesAssembledThisFrame)")
        }
    }

    /// 畳まずに置く道 (角丸の周を作って直に `draw(_:)` へ渡す。畳む前の `rect` が通っていた道) と、
    /// 畳んで置いた絵を比べる。**許容は 0。**
    private func expectSameAsUnfolded(
        _ name: String, density: Float = 1, texture: Bool = false, stroke: Bool = false,
        size: (width: Float, height: Float, radius: Float), spin: Float = 0.21,
        scale: (Int) -> (Float, Float) = { _ in (1, 1) }
    ) throws {
        func picture(folding: Bool) throws -> PixelBuffer {
            try self.picture(density: density, expands: true, texture: texture) { canvas in
                if stroke {
                    canvas.stroke(200)
                    canvas.strokeWeight(0.7)
                }
                self.scatter(canvas, spin: spin, scale: scale) {
                    let (w, h) = (size.width, size.height)
                    if folding {
                        canvas.rect(-w / 2, -h / 2, w, h, size.radius)
                        return
                    }
                    let radius = min(size.radius, w / 2, h / 2)
                    let segments = Canvas.segmentCount(
                        forRadius: radius, scale: Canvas.splitScale(of: canvas.transform.matrix))
                    canvas.draw(
                        Canvas.roundedRectOutline(width: w, height: h, radius: radius, segments: segments)
                            .moved(by: SIMD2(-w / 2, -h / 2)))
                }
                if folding {
                    #expect(canvas.openFlat != nil, "\(name): 畳まれていない")
                }
            }
        }
        let unfolded = try picture(folding: false)
        let folded = try picture(folding: true)
        var differing = 0
        var lit = 0
        for index in unfolded.components.indices {
            if unfolded.components[index] != folded.components[index] { differing += 1 }
            if unfolded.components[index] > 0 { lit += 1 }
        }
        #expect(lit > 0, "\(name): 絵が空")
        #expect(differing == 0, "\(name): 畳まずに置いた絵と画素の成分が \(differing) 個違う (点いている成分 \(lit))")
    }

    @Test("畳んだ角丸 rect は、畳まずに置いた絵と画素が同じ")
    func roundedRectsKeepTheirPixelsWhenFolded() throws {
        try expectSameAsUnfolded("細い角丸 rect", size: (28, 0.8, 0.3))
        try expectSameAsUnfolded(
            "倍率の違う細い角丸 rect", size: (28, 0.8, 0.3), scale: { (1 + Float($0 % 3) * 0.2, 1 + Float($0 % 4) * 0.1) })
        try expectSameAsUnfolded("細かさ 0.5 の細い角丸 rect", density: 0.5, size: (28, 1, 0.4), spin: 0.23)
        try expectSameAsUnfolded("貼る絵の細い角丸 rect", texture: true, size: (20, 1, 0.4), spin: 0.27)
        // 細くない角丸 rect (周を刻む数が鍵に入る)・半径が短い辺の半分に締まる rect・輪郭つき
        try expectSameAsUnfolded("細くない角丸 rect", size: (16, 10, 3), spin: 0.3)
        try expectSameAsUnfolded("半径が締まる角丸 rect", size: (16, 10, 100), spin: 0.3)
        try expectSameAsUnfolded("輪郭つきの細い角丸 rect", stroke: true, size: (28, 0.8, 0.3), spin: 0.3)
        try expectSameAsUnfolded("輪郭つきの細くない角丸 rect", stroke: true, size: (16, 10, 3), spin: 0.3)
        try expectSameAsUnfolded("貼る絵の細くない角丸 rect", texture: true, size: (16, 10, 3), spin: 0.27)
    }

    @Test("角丸 rect の細い塗りは、CPU で組み直す畳みと画素が同じ")
    func roundedRectFillsKeepTheirPixels() throws {
        try expectSame("細い角丸 rect") { canvas in
            scatter(canvas, spin: 0.29, scale: { (1 + Float($0 % 3) * 0.1, 1) }) {
                canvas.rect(-12, -0.4, 24, 0.8, 0.3)
            }
            #expect(!canvas.expandsThinFillsInVertexStage || canvas.thinFillSpans.count == 30, "畳まれていない")
        }
        try expectSame("貼る絵の細い角丸 rect", texture: true) { canvas in
            scatter(canvas, spin: 0.27) { canvas.rect(-10, -0.5, 20, 1, 0.4) }
        }
    }

    @Test("角丸 rect は、半径の違う置き場所が別の雛形になり、角丸でない rect とも混ざらない")
    func roundedRectsKeepTheirOwnTemplates() throws {
        let canvas = try Self.makeCanvas(density: 1)
        let shader = try canvas.makeShader(Self.plain)
        try canvas.draw {
            canvas.background(0)
            canvas.noStroke()
            canvas.fill(255)
            canvas.shader(shader)
            var keys: [Canvas.FlatKey] = []
            for radius in [Float(0.2), 0.3, 0] {
                // 1 つ目は畳む相手を待って置き、2 つ目から雛形を開く
                for _ in 0..<3 { canvas.rect(10, 10, 28, 0.8, radius) }
                if let key = canvas.openFlat?.key { keys.append(key) }
            }
            // 半径 0.2・0.3 の角丸と、角丸でない rect (半径 0) は、それぞれ別の雛形の鍵
            #expect(keys.count == 3, "雛形の鍵の数: \(keys.count)")
            if keys.count == 3 {
                #expect(keys[0].form == .roundedRect(width: 28, height: 0.8, radius: 0.2))
                #expect(keys[1].form == .roundedRect(width: 28, height: 0.8, radius: 0.3))
                #expect(keys[2].form == .rect(width: 28, height: 0.8))
            }
        }
    }

    @Test("極端な寸法の細い塗りは、有限でない記述を作らない")
    func extremeSizesNeverMakeNonFiniteRecords() {
        let big: [Float] = [1e30, 1e37, 1.6e38, 1.75e38, 2e38, 3e38, Float.greatestFiniteMagnitude]
        let thin: [Float] = [0.2, 1e-30, 1e-38]
        let linears: [simd_float2x2] = [
            matrix_identity_float2x2, simd_float2x2(SIMD2(0.866, 0.5), SIMD2(-0.5, 0.866)),
            simd_float2x2(SIMD2(1e-20, 0), SIMD2(0, 1e-20)), simd_float2x2(SIMD2(1e20, 0), SIMD2(0, 1e-20)),
        ]
        for length in big {
            for width in thin {
                for linear in linears {
                    for named in [
                        Canvas.Outline.NamedFill(
                            isEllipse: false, center: SIMD2(length, width), half: SIMD2(length, width)),
                        Canvas.Outline.NamedFill(
                            isEllipse: true, center: .zero, half: SIMD2(length, width)),
                        Canvas.Outline.NamedFill(
                            isEllipse: false, center: .zero, half: SIMD2(width, length)),
                    ] {
                        guard let record = Canvas.thinFillRecord(named, by: linear) else { continue }
                        #expect(record.isFinite, "\(named) \(linear)")
                        #expect(
                            record.pieces().allSatisfy {
                                $0.coverage.isFinite && $0.corners.0.x.isFinite && $0.corners.2.y.isFinite
                            }, "\(named) \(linear)")
                    }
                }
            }
        }
    }

    /// 片の角の積和の順 (頂点段と同じ `fma` の順) を、別に書いた式と 1 ビットずつ突き合わせる。
    /// **GPU の側の順は画素の検査では見えない場合がある** (コンパイラが偶然同じ融合をする) ので、CPU の
    /// 式を `Shapes.metal` の `mokume_thinFillCorner` と同じ順に固定していることを、ここで押さえる。
    @Test("CPU の片の角は、頂点段と同じ fma の順で出る")
    func cornersUseTheFusedOrder() throws {
        var seed: UInt64 = 7
        func next() -> Float {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            return Float((seed >> 33) & 0xFFFFFF) / Float(0xFFFFFF)
        }
        var checked = 0
        for _ in 0..<400 {
            let angle = next() * 6.2831853
            let (c, s) = (cos(angle), sin(angle))
            let stretch = 0.5 + next() * 3
            let linear = simd_float2x2(SIMD2(c, s) * stretch, SIMD2(-s, c) * (0.2 + next()))
            let named = Canvas.Outline.NamedFill(
                isEllipse: true, center: SIMD2(next() * 9, next() * 9), half: SIMD2(5 + next() * 30, 0.05 + next() * 0.3))
            guard let record = Canvas.thinFillRecord(named, by: linear) else { continue }
            let pieces = record.pieces()
            let axis = SIMD2(record.centerAxis.z, record.centerAxis.w)
            let across = SIMD2(record.acrossSlopeSide.x, record.acrossSlopeSide.y)
            let (slope, side) = (record.acrossSlopeSide.z, record.acrossSlopeSide.w)
            let inverseX = SIMD2(record.inverse.x, record.inverse.y)
            let inverseY = SIMD2(record.inverse.z, record.inverse.w)
            let center = SIMD2(record.centerAxis.x, record.centerAxis.y)
            let (origin, span, divisor) = (record.layout.x, record.layout.y, record.layout.z)
            // 先頭の片の 2 つ目の角: along = origin + span * 1 / divisor、offset = -side
            guard let first = pieces.first, record.coverageMode.x == 1 else { continue }
            let to = origin + span * Float(1) / divisor
            var shift = -side
            shift.addProduct(slope, to)
            var drawn = axis * to
            drawn.addProduct(across, SIMD2(repeating: shift))
            var moved = inverseX * drawn.x
            moved.addProduct(inverseY, SIMD2(repeating: drawn.y))
            let expected = center + moved
            #expect(first.corners.1 == expected, "\(first.corners.1) != \(expected)")
            checked += 1
        }
        #expect(checked > 300)
    }

    // MARK: - 頂点段の出力を読み戻す

    /// 頂点関数が呼ぶ片の角 (`mokume_thinFillCorner`) と置き場所への移し (`mokume_thinFillPlace`) を、
    /// Shapes.metal の原文に足した計算の入口から呼び、出力を読み戻して CPU の式と **1 ビットずつ**
    /// 突き合わせる。画素の比べでは 1 ulp の差は赤にならない (縁や継ぎ目の画素が振れたときだけ見える)。
    /// 置き場所の位置 (anchor) が 0 でない場面と、鏡映・剪断・大きな平行移動を含む。
    @Test("頂点段の片の角と置き場所への移しは、CPU の式と 1 ビットも違わない")
    func vertexStageCornersMatchTheCPUBitForBit() throws {
        let gpu = try RenderDevice()
        let shapes = try gpu.shaders.bundledShaderSource(named: "Shapes")
        let probe = """

        kernel void probeThinFill(
            constant ThinFillRecord *records [[buffer(0)]], constant ThinFillSpan *spans [[buffer(1)]],
            constant float4 *linears [[buffer(2)]], constant float2 *inputs [[buffer(3)]],
            device float2 *corners [[buffer(4)]], device float2 *placed [[buffer(5)]],
            uint id [[thread_position_in_grid]])
        {
            ThinFillSpan span = spans[0];
            float2 corner = mokume_thinFillCorner(records[span.first], span.anchor, inputs[id].x, inputs[id].y);
            corners[id] = corner;
            placed[id] = mokume_thinFillPlace(linears[0], span.translation, corner);
        }
        """
        let library = try gpu.shaders.makeShapeLibrary(named: "ThinFillProbe", body: shapes + probe)
        let function = try #require(library.makeFunction(name: "probeThinFill"))
        let pipeline = try gpu.device.makeComputePipelineState(function: function)
        let queue = try #require(gpu.device.makeCommandQueue())

        var seed: UInt64 = 99
        func next() -> Float {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            return Float((seed >> 33) & 0xFFFFFF) / Float(0xFFFFFF)
        }
        func buffer<T>(_ values: [T]) throws -> any MTLBuffer {
            try #require(
                values.withUnsafeBytes {
                    gpu.device.makeBuffer(bytes: $0.baseAddress!, length: $0.count, options: .storageModeShared)
                })
        }
        var compared = 0
        for round in 0..<300 {
            let angle = next() * 6.2831853
            let (c, s) = (cos(angle), sin(angle))
            let stretch: Float = 0.4 + next() * 3
            let flip: Float = round % 4 == 0 ? -1 : 1
            let shear = round % 5 == 0 ? (next() - 0.5) * 2 : 0
            let linear = simd_float2x2(
                SIMD2(c, s) * stretch, SIMD2(-s + shear * c, c + shear * s) * flip * (0.15 + next()))
            let named = Canvas.Outline.NamedFill(
                isEllipse: round % 3 != 0, center: SIMD2(next() * 9, next() * 9),
                half: SIMD2(2 + next() * 30, 0.05 + next() * 0.4))
            guard let record = Canvas.thinFillRecord(named, by: linear) else { continue }
            let anchor = round % 2 == 0 ? SIMD2(37.3, 11.7) : SIMD2(next() * 300 - 150, next() * 300 - 150)
            let translation = SIMD2(next() * 600 - 300, next() * 600 - 300)
            let placement = SIMD4(linear.columns.0.x, linear.columns.0.y, linear.columns.1.x, linear.columns.1.y)
            let inputs = (0..<64).map { _ in SIMD2(next() * 70 - 35, next() * 2 - 1) }
            let span = Canvas.ThinFillSpan(first: 0, count: 1, anchor: anchor, translation: translation)
            let cornerBuffer = try #require(
                gpu.device.makeBuffer(length: 64 * MemoryLayout<SIMD2<Float>>.stride, options: .storageModeShared))
            let placedBuffer = try #require(
                gpu.device.makeBuffer(length: 64 * MemoryLayout<SIMD2<Float>>.stride, options: .storageModeShared))
            let commands = try #require(queue.makeCommandBuffer())
            let encoder = try #require(commands.makeComputeCommandEncoder())
            encoder.setComputePipelineState(pipeline)
            encoder.setBuffer(try buffer([record]), offset: 0, index: 0)
            encoder.setBuffer(try buffer([span]), offset: 0, index: 1)
            encoder.setBuffer(try buffer([placement]), offset: 0, index: 2)
            encoder.setBuffer(try buffer(inputs), offset: 0, index: 3)
            encoder.setBuffer(cornerBuffer, offset: 0, index: 4)
            encoder.setBuffer(placedBuffer, offset: 0, index: 5)
            encoder.dispatchThreads(
                MTLSize(width: 64, height: 1, depth: 1), threadsPerThreadgroup: MTLSize(width: 64, height: 1, depth: 1))
            encoder.endEncoding()
            commands.commit()
            commands.waitUntilCompleted()
            let corners = Array(
                UnsafeBufferPointer(
                    start: cornerBuffer.contents().bindMemory(to: SIMD2<Float>.self, capacity: 64), count: 64))
            let placed = Array(
                UnsafeBufferPointer(
                    start: placedBuffer.contents().bindMemory(to: SIMD2<Float>.self, capacity: 64), count: 64))
            // `Transform.placed` と同じ行列の積 (列 2 本と平行移動だけを持つ 4x4)
            let matrix = simd_float4x4(
                SIMD4(linear.columns.0.x, linear.columns.0.y, 0, 0), SIMD4(linear.columns.1.x, linear.columns.1.y, 0, 0),
                SIMD4(0, 0, 1, 0), SIMD4(translation.x, translation.y, 0, 1))
            for (index, input) in inputs.enumerated() {
                let expected = record.corner(anchor: anchor, along: input.x, offset: input.y)
                #expect(corners[index] == expected, "角 \(index): GPU \(corners[index]) CPU \(expected)")
                let moved = matrix * SIMD4<Float>(expected.x, expected.y, 0, 1)
                #expect(
                    placed[index] == SIMD2(moved.x, moved.y),
                    "置き場所 \(index): GPU \(placed[index]) CPU \(SIMD2(moved.x, moved.y))")
                compared += 1
            }
        }
        #expect(compared > 10_000)
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
            #expect(record.pieceCount <= Canvas.ThinFillRecord.capacity(forPieces: record.pieceCount))
            #expect(record.pieces().count <= record.pieceCount)
            #expect(record.pieces().allSatisfy { $0.coverage > 0 && $0.coverage <= 1.0001 })
        }
    }
}
