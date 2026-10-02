// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Testing

@testable import MokumeCore

/// 裏面が絵に出うる立体の奥の面が、形の向きによらず絵に出ることの検査。GPU を要する。
///
/// 両面で描く列 (``Canvas/Batch/cullMode`` が `.none`) も奥行きを書くので、1 回で描くと、
/// 先に積まれた手前の面が後の奥の面を捨てる。奥の面が出るかが三角形を積んだ順 (形の向き)
/// で変わっていた ([#1549](https://github.com/mokume-metal/mokume/issues/1549)・
/// [#1565](https://github.com/mokume-metal/mokume/issues/1565))。見るのは**向きの組**で、
/// 形の直前 (いちばん内側) に `rotateY(π)` を入れた絵と入れない絵である。形は `rotateY(π)`
/// について対称なので、同じ絵になるはずである。
///
/// 画素は線形の値で読む。「違う画素」はどれかの成分の差が 0.02 を超える画素である。
/// 半透明は `fill(…, 128)` で、1 層が 0.502、2 層 (奥の面が透ける) が 0.752 になる。
@Suite(
    "両面で描く立体の奥の面",
    .enabled(
        if: RenderDevice.isAvailable,
        "この世代のコマンド構造に対応した GPU が無い実行環境ではスキップする")
)
struct SolidBackFaceOrderTests {
    private static let size = 160
    private static let center: Float = 80
    /// 2 層ぶん (奥の面が透ける) の半透明の白。
    private static let twoLayers: Float = 0.752

    private func makeCanvas() throws -> Canvas {
        try CanvasFixture.make(gpu: RenderDevice(), width: Self.size, height: Self.size)
    }

    /// 黒地に `noStroke()` で描いた 1 フレームの画素。
    private func render(_ body: (Canvas) throws -> Void) throws -> PixelBuffer {
        let canvas = try makeCanvas()
        try canvas.draw {
            canvas.background(.linear(red: 0, green: 0, blue: 0))
            canvas.noStroke()
            try? body(canvas)
        }
        return try canvas.target.readPixels()
    }

    /// どれかの成分の差が 0.02 を超える画素の数。
    private func differingPixels(_ a: PixelBuffer, _ b: PixelBuffer) -> Int {
        var count = 0
        for y in 0..<a.height {
            for x in 0..<a.width {
                let (p, q) = (a[x, y], b[x, y])
                if abs(p.red - q.red) > 0.02 || abs(p.green - q.green) > 0.02
                    || abs(p.blue - q.blue) > 0.02 || abs(p.alpha - q.alpha) > 0.02
                {
                    count += 1
                }
            }
        }
        return count
    }

    /// 面の中心から `radius` 画素以内の画素の位置。
    private func disc(radius: Int) -> [(x: Int, y: Int)] {
        var points: [(x: Int, y: Int)] = []
        let c = Int(Self.center)
        for y in (c - radius)...(c + radius) {
            for x in (c - radius)...(c + radius)
            where (x - c) * (x - c) + (y - c) * (y - c) <= radius * radius {
                points.append((x, y))
            }
        }
        return points
    }

    /// 向きの組を描く。`place` は `turned` が真なら形の直前に `rotateY(π)` を入れる。
    private func orientationPair(
        _ place: @escaping (Canvas, Bool) throws -> Void
    ) throws -> (plain: PixelBuffer, turned: PixelBuffer) {
        (try render { try place($0, false) }, try render { try place($0, true) })
    }

    /// 閉じた組み込みの形。外側の回転は Issue の表と同じで、`rotateY(π)` はその内側に入れる。
    enum Form: String, CaseIterable, Sendable, CustomTestStringConvertible {
        case sphere, box, cylinder, cone, ellipsoid, torus

        var testDescription: String { rawValue }

        func place(on canvas: Canvas, turned: Bool) {
            canvas.push()
            canvas.translate(SolidBackFaceOrderTests.center, SolidBackFaceOrderTests.center, 0)
            switch self {
            case .box:
                canvas.rotateX(0.4)
                canvas.rotateZ(0.3)
            case .cylinder, .cone: canvas.rotateX(0.5)
            case .torus: canvas.rotateX(0.8)
            case .sphere, .ellipsoid: break
            }
            if turned { canvas.rotateY(Float.pi) }
            switch self {
            case .sphere: canvas.sphere(40)
            case .box: canvas.box(60)
            case .cylinder: canvas.cylinder(30, 60)
            case .cone: canvas.cone(30, 60)
            case .ellipsoid: canvas.ellipsoid(50, 30, 20)
            case .torus: canvas.torus(40, 12)
            }
            canvas.pop()
        }
    }

    // MARK: - 半透明の塗り (#1549)

    @Test("半透明の球は、どちらの向きでも中心から 36 画素以内がすべて 2 層になる")
    func translucentSphereShowsItsBackEverywhere() throws {
        // 起票時: 1 層の画素が 2834 / 1226、違う画素 1940
        let pair = try orientationPair { canvas, turned in
            canvas.fill(255, 255, 255, 128)
            Form.sphere.place(on: canvas, turned: turned)
        }
        for picture in [pair.plain, pair.turned] {
            let single = disc(radius: 36).filter {
                abs(picture[$0.x, $0.y].red - Self.twoLayers) > 0.01
            }
            #expect(single.isEmpty, "奥の面が透けていない画素が \(single.count) ある")
        }
        #expect(differingPixels(pair.plain, pair.turned) == 0)
    }

    @Test("半透明の閉じた形は、向きの組で絵が変わらない", arguments: Form.allCases)
    func translucentClosedFormsDoNotDependOnOrientation(_ form: Form) throws {
        // 起票時の違う画素: box 1780・cylinder 3210・cone 1756・ellipsoid 2912・torus 5098
        let pair = try orientationPair { canvas, turned in
            canvas.fill(255, 255, 255, 128)
            form.place(on: canvas, turned: turned)
        }
        #expect(differingPixels(pair.plain, pair.turned) == 0)
        if form != .torus {
            for picture in [pair.plain, pair.turned] {
                #expect(abs(picture[80, 80].red - Self.twoLayers) <= 0.01, "(80, 80) \(picture[80, 80])")
            }
        }
    }

    @Test("光を当てても、半透明の形は向きの組で絵が変わらない", arguments: [Form.sphere, .box, .cylinder, .torus])
    func litTranslucentFormsDoNotDependOnOrientation(_ form: Form) throws {
        // 起票時の違う画素: sphere 1940・box 1780・cylinder 3210・torus 5098。奥行きを書かない
        // 案 (案 A) では 1781 / 1780 / 2523 / 4371 が残った — 混ぜる順が積んだ順のままだから
        let pair = try orientationPair { canvas, turned in
            canvas.lights()
            canvas.fill(255, 255, 255, 128)
            form.place(on: canvas, turned: turned)
        }
        #expect(differingPixels(pair.plain, pair.turned) == 0)
    }

    // MARK: - 形どうしの隠れ方は変えない (ADR-0021 決定 2)

    @Test("手前に先に置いた半透明の箱は、奥に後から置いた不透明の箱を隠したまま")
    func aTranslucentBoxStillHidesALaterBoxBehind() throws {
        let picture = try render { canvas in
            canvas.fill(255, 0, 0, 128)
            canvas.push()
            canvas.translate(70, 80, 40)
            canvas.box(40)
            canvas.pop()
            canvas.fill(0, 0, 255)
            canvas.push()
            canvas.translate(90, 80, -40)
            canvas.box(40)
            canvas.pop()
        }
        // 起票時 (0.413, 0.017, 0.009)。直すと手前の箱の奥の面が透けて赤が 2 層になる
        #expect(picture[80, 80].blue <= 0.02, "奥の青い箱が出た: \(picture[80, 80])")
    }

    @Test("半透明の置き場所と同じ列に居る不透明の形どうしも、呼び出し順で隠れたまま")
    func opaqueFormsSharingATranslucentBatchStillHide() throws {
        let picture = try render { canvas in
            canvas.fill(255, 255, 255, 128)
            canvas.push()
            canvas.translate(20, 20, 0)
            canvas.box(40)
            canvas.pop()
            canvas.fill(255)
            canvas.push()
            canvas.translate(80, 80, 40)
            canvas.box(40)
            canvas.pop()
            canvas.fill(0, 0, 255)
            canvas.push()
            canvas.translate(80, 80, -40)
            canvas.box(40)
            canvas.pop()
        }
        let pixel = picture[80, 80]
        #expect(
            abs(pixel.red - 1) <= 0.01 && abs(pixel.green - 1) <= 0.01 && abs(pixel.blue - 1) <= 0.01,
            "手前の白い箱が奥の青い箱に隠された: \(pixel)")
    }

    /// 奥 (z = −60) に青、手前 (z = 60) に赤の半透明の球。`backFirst` なら奥から置く。
    private func twoSpheres(backFirst: Bool, turned: Bool) throws -> PixelBuffer {
        try render { canvas in
            @MainActor func sphere(_ red: Int, _ blue: Int, z: Float) {
                canvas.fill(red, 0, blue, 128)
                canvas.push()
                canvas.translate(80, 80, z)
                if turned { canvas.rotateY(Float.pi) }
                canvas.sphere(40)
                canvas.pop()
            }
            if backFirst {
                sphere(0, 255, z: -60)
                sphere(255, 0, z: 60)
            } else {
                sphere(255, 0, z: 60)
                sphere(0, 255, z: -60)
            }
        }
    }

    @Test("奥から置いた 2 つの半透明の球は、どちらの向きでも正しく重なる", arguments: [false, true])
    func spheresPlacedBackToFrontBlendCorrectly(turned: Bool) throws {
        // 式の値: 赤 = 0.822 × 0.752 = 0.618、青 = 0.685 × 0.498² + 0.017 × 0.752 = 0.182。
        // 列ごとに裏 → 表の 2 回で描くと、奥の球の手前の面が手前の球の裏面に捨てられて青 0.126
        let picture = try twoSpheres(backFirst: true, turned: turned)
        var wrong: [String] = []
        for point in disc(radius: 24) {
            let pixel = picture[point.x, point.y]
            if abs(pixel.red - 0.618) > 0.01 || abs(pixel.blue - 0.182) > 0.01 {
                wrong.append("(\(point.x), \(point.y)) \(pixel)")
            }
        }
        #expect(wrong.isEmpty, "\(wrong.count) 画素が違う。最初: \(wrong.first ?? "")")
    }

    @Test("手前から置いた 2 つの半透明の球は並べ替えない (奥の青は隠れたまま)")
    func spheresPlacedFrontToBackAreNotSorted() throws {
        let picture = try twoSpheres(backFirst: false, turned: false)
        let shown = disc(radius: 24).filter { picture[$0.x, $0.y].blue > 0.02 }
        #expect(shown.isEmpty, "奥の青が \(shown.count) 画素に出た")
    }

    // MARK: - 加算・絵・保持した形・断片 (#1565)

    @Test("加算の球は、向きの組で絵が変わらず、どちらも奥の面が足される", arguments: [false, true])
    func additiveSphereDoesNotDependOnOrientation(lit: Bool) throws {
        // 起票時: (80, 86) が 0.216 / 0.432、違う画素 1940 (光の下でも 1940)
        let pair = try orientationPair { canvas, turned in
            if lit { canvas.lights() }
            canvas.blendMode(.add)
            canvas.fill(128)
            Form.sphere.place(on: canvas, turned: turned)
        }
        #expect(differingPixels(pair.plain, pair.turned) == 0)
        if !lit {
            for picture in [pair.plain, pair.turned] {
                #expect(abs(picture[80, 86].red - 0.432) <= 0.01, "(80, 86) \(picture[80, 86])")
            }
        }
    }

    @Test("半透明の絵を貼った球は、向きの組で絵が変わらない (描いた後に絵を外しても)", arguments: [false, true])
    func texturedSphereDoesNotDependOnOrientation(untexturedAfter: Bool) throws {
        // 起票時: (80, 86) が 0.500 / 0.750、違う画素 1940
        let pair = try orientationPair { canvas, turned in
            let picture = try canvas.createImage(4, 4)
            picture.fill(LinearRGBA(premultipliedRed: 0.5, green: 0.5, blue: 0.5, alpha: 0.5))
            canvas.fill(255)
            canvas.texture(picture)
            Form.sphere.place(on: canvas, turned: turned)
            // 置いた後で外しても、その形は両面で裏 → 表に描く (#1564 の見張り)
            if untexturedAfter { canvas.noTexture() }
        }
        #expect(differingPixels(pair.plain, pair.turned) == 0)
        for picture in [pair.plain, pair.turned] {
            #expect(abs(picture[80, 86].red - 0.750) <= 0.01, "(80, 86) \(picture[80, 86])")
        }
    }

    /// 保持した球を (80, 80, 0) に置く。回転は `shape()` の直前に入れる。
    private func retainedPair(
        _ record: @escaping (Canvas) -> Void
    ) throws -> (plain: PixelBuffer, turned: PixelBuffer) {
        try orientationPair { canvas, turned in
            let ball = canvas.createShape {
                canvas.noStroke()
                record(canvas)
                canvas.sphere(40)
            }
            canvas.push()
            canvas.translate(80, 80, 0)
            if turned { canvas.rotateY(Float.pi) }
            canvas.shape(ball)
            canvas.pop()
        }
    }

    @Test("保持した半透明の球は、向きの組で絵が変わらない")
    func retainedTranslucentSphereDoesNotDependOnOrientation() throws {
        // 起票時: (80, 86) が 0.502 / 0.752、違う画素 1940
        let pair = try retainedPair { $0.fill(255, 255, 255, 128) }
        #expect(differingPixels(pair.plain, pair.turned) == 0)
        for picture in [pair.plain, pair.turned] {
            #expect(abs(picture[80, 86].red - Self.twoLayers) <= 0.01, "(80, 86) \(picture[80, 86])")
        }
    }

    @Test("保持した加算の球は、向きの組で絵が変わらない")
    func retainedAdditiveSphereDoesNotDependOnOrientation() throws {
        let pair = try retainedPair { canvas in
            canvas.blendMode(.add)
            canvas.fill(128)
        }
        #expect(differingPixels(pair.plain, pair.turned) == 0)
        for picture in [pair.plain, pair.turned] {
            #expect(abs(picture[80, 86].red - 0.432) <= 0.01, "(80, 86) \(picture[80, 86])")
        }
    }

    @Test("不透明の保持した球を半透明の色で置いても、向きの組で絵が変わらない")
    func retainedSpherePlacedWithATranslucentTintDoesNotDependOnOrientation() throws {
        // 焼いた頂点は不透明でも、置き場所の色で透ける
        let pair = try orientationPair { canvas, turned in
            let ball = canvas.createShape {
                canvas.noStroke()
                canvas.fill(255)
                canvas.sphere(40)
            }
            let veil: Float = 128.0 / 255
            canvas.shape(
                ball,
                at: [
                    Placement(
                        x: 80, y: 80, rotation: SIMD3(0, turned ? Float.pi : 0, 0),
                        fill: LinearRGBA(premultipliedRed: veil, green: veil, blue: veil, alpha: veil))
                ])
        }
        #expect(differingPixels(pair.plain, pair.turned) == 0)
    }

    @Test("透明を返す断片で塗った球は、向きの組で絵が変わらない")
    func customShaderSphereDoesNotDependOnOrientation() throws {
        let pair = try orientationPair { canvas, turned in
            let veil = try canvas.makeShader(
                """
                float4 paint(Fragment in, Values values) {
                    return float4(0.5, 0.5, 0.5, 0.5);
                }
                """)
            canvas.shader(veil)
            Form.sphere.place(on: canvas, turned: turned)
        }
        #expect(differingPixels(pair.plain, pair.turned) == 0)
    }

    @Test("手前に先に置いた加算の箱は、奥に後から置いた不透明の青い箱を隠したまま")
    func anAdditiveBoxStillHidesALaterBoxBehind() throws {
        let picture = try render { canvas in
            canvas.blendMode(.add)
            canvas.fill(128)
            canvas.push()
            canvas.translate(70, 80, 40)
            canvas.box(40)
            canvas.pop()
            canvas.blendMode(.blend)
            canvas.fill(0, 0, 255)
            canvas.push()
            canvas.translate(90, 80, -40)
            canvas.box(40)
            canvas.pop()
        }
        // 加算の箱は灰色なので、奥の青が出なければ青の成分は赤の成分と同じ
        let pixel = picture[80, 80]
        #expect(abs(pixel.blue - pixel.red) <= 0.01, "奥の青い箱が出た: \(pixel)")
    }

    // MARK: - 描く回数

    @Test("裏面が絵に出うる置き場所を持たない列は、1 回で描く")
    func opaqueBatchesDrawOnce() throws {
        let canvas = try makeCanvas()
        try canvas.draw {
            canvas.noStroke()
            canvas.fill(255)
            for index in 0..<3 {
                canvas.push()
                canvas.translate(Float(40 + index * 40), 80, 0)
                canvas.sphere(15)
                canvas.pop()
            }
        }
        #expect(canvas.drawCallsInLastFrame == 1)
        #expect(canvas.drawsEncodedInLastFrame == 1)
    }

    @Test("裏面が絵に出うる置き場所を持つ列は、置き場所ごとに裏 → 表の 2 回で描く")
    func translucentBatchesDrawEachPlacementTwice() throws {
        let canvas = try makeCanvas()
        try canvas.draw {
            canvas.noStroke()
            canvas.fill(255, 255, 255, 128)
            for index in 0..<3 {
                canvas.push()
                canvas.translate(Float(40 + index * 40), 80, 0)
                canvas.sphere(15)
                canvas.pop()
            }
        }
        // 列の数は変わらない。列の中で置き場所ごとに 2 回描く
        #expect(canvas.drawCallsInLastFrame == 1)
        #expect(canvas.drawsEncodedInLastFrame == 6)
    }
}
