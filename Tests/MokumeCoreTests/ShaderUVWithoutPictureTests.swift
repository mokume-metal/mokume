// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Testing
import simd

@testable import MokumeCore

/// 貼る絵の無い形に当てた利用者の断片が、形の読み取り位置 (`in.uv`) を受け取ることの検査 ([#3797])。GPU を要する。
///
/// ## 正解は「白い 1×1 の絵を貼った絵」
///
/// 決定 (#3797 の案 A) は「断片を当てた形には、貼る絵が無くても、白い 1×1 の絵を `texture()` で貼ったときと同じ
/// 読み取り位置を届ける」だった。白い絵を貼る形はいまでも書ける回り道なので、**それを正解に使い、画素の完全一致で
/// 見る**。読み取り位置そのものの値 (囲みの箱・メッシュ) は ``TextureTests`` が貼る絵の側で見ている。
///
/// ほかに見るのは、目には判定できない性質である:
///
/// - 線を引いたまま当てても、塗りと輪郭が同じ面を読み、形ごとに列が割れない (費用の約束)
/// - 勾配の塗り・断片を外した形・字・画像・置く側の断片は、読み取り位置も読む面も変わらない
///
/// [#3797]: https://github.com/mokume-metal/mokume/issues/3797
@Suite(
    "貼る絵の無い形に当てた断片の読み取り位置",
    .enabled(
        if: RenderDevice.isAvailable,
        "この世代のコマンド構造に対応した GPU が無い実行環境ではスキップする")
)
struct ShaderUVWithoutPictureTests {
    private static let size = 96
    private let black = LinearRGBA.linear(red: 0, green: 0, blue: 0)
    private let white = LinearRGBA.linear(red: 1, green: 1, blue: 1)
    private let red = LinearRGBA.linear(red: 1, green: 0, blue: 0)

    /// 読み取り位置と読んだ値を色にする断片。**`in.uv` が 1 点に固定されていれば、形は一色になる。**
    /// `in.texel` も色に入れるので、白い 1×1 と焼き場の白い区画の読み違いも画素に出る。
    private static let probe = """
        float4 paint(Fragment in, Values values) {
            return float4(fract(in.uv * 5.0), in.texel.g, 1.0) * in.color.a;
        }
        """

    private func makeCanvas() throws -> Canvas {
        try CanvasFixture.make(gpu: RenderDevice(), width: Self.size, height: Self.size)
    }

    private func makeWhite(_ canvas: Canvas) throws -> Image {
        let image = try canvas.createImage(1, 1)
        image.set(0, 0, white)
        return image
    }

    /// 置く形。平面の名指しの図形・弧の閉じ方・自分で並べた形・細い塗り・保持した形・立体を一通り持つ。
    enum Figure: String, CaseIterable, CustomTestStringConvertible {
        case rect, roundedRect, circle, ellipse
        case arcDefault, arcPie, arcChord, arcOpen
        case quad, triangle, concave, partlyWritten, thinEllipse, retained
        case box, sphere, cylinder, cone, torus, ellipsoid, plane

        var testDescription: String { rawValue }

        var isSolid: Bool {
            switch self {
            case .box, .sphere, .cylinder, .cone, .torus, .ellipsoid, .plane: true
            default: false
            }
        }

        /// 原点を中心に、差し渡し 24 ほどで置く。
        func place(on canvas: Canvas) {
            switch self {
            case .rect: canvas.rect(-12, -10, 24, 20)
            case .roundedRect: canvas.rect(-12, -10, 24, 20, 5)
            case .circle: canvas.circle(0, 0, 24)
            case .ellipse: canvas.ellipse(0, 0, 28, 18)
            case .arcDefault: canvas.arc(0, 0, 26, 26, 0.3, 4.5)
            case .arcPie: canvas.arc(0, 0, 26, 26, 0.3, 4.5, .pie)
            case .arcChord: canvas.arc(0, 0, 26, 26, 0.3, 4.5, .chord)
            case .arcOpen: canvas.arc(0, 0, 26, 26, 0.3, 4.5, .open)
            case .quad: canvas.quad(-12, -8, 10, -12, 12, 10, -8, 12)
            case .triangle: canvas.triangle(-12, 10, 0, -12, 12, 10)
            case .concave:
                // 凹んだ星形。三角形に割る経路を通る
                canvas.beginShape()
                for index in 0..<10 {
                    let angle = Float(index) * .pi / 5
                    let radius: Float = index % 2 == 0 ? 13 : 6
                    canvas.vertex(radius * cos(angle), radius * sin(angle))
                }
                canvas.endShape(.close)
            case .partlyWritten:
                // 2 点だけ読み取り位置を書く。書かなかった点は形の囲みの箱から決まる
                canvas.beginShape()
                canvas.vertex(-12, -12, 0, 0)
                canvas.vertex(12, -12)
                canvas.vertex(12, 12, 1, 1)
                canvas.vertex(-12, 12)
                canvas.endShape(.close)
            case .thinEllipse: canvas.ellipse(0, 0, 40, 0.5)
            case .retained:
                // 記録した時点の断片と貼る絵で焼き、置く
                canvas.shape(canvas.createShape { canvas.circle(0, 0, 24) })
            case .box: canvas.box(18)
            case .sphere: canvas.sphere(13)
            case .cylinder: canvas.cylinder(10, 20)
            case .cone: canvas.cone(10, 20)
            case .torus: canvas.torus(10, 4)
            case .ellipsoid: canvas.ellipsoid(14, 10, 8)
            case .plane: canvas.plane(24, 18)
            }
        }
    }

    enum Outline: CaseIterable, CustomTestStringConvertible {
        case none, thin, thick
        var testDescription: String {
            switch self {
            case .none: "線なし"
            case .thin: "線 1"
            case .thick: "線 4"
            }
        }
    }

    /// 置き場所。2 つ目からは畳みに入る (#424)。回転と倍率を変えて、置き場所ごとの箱の取り方も見る。
    private static let placements: [(x: Float, y: Float, turn: Float, scale: Float)] = [
        (24, 24, 0, 1), (72, 26, 0.4, 0.8), (48, 70, 1.1, 1.3),
    ]

    private func render(
        _ figure: Figure, outline: Outline, placed count: Int, pastingWhite: Bool
    ) throws -> DisplayImage {
        let canvas = try makeCanvas()
        let shader = try canvas.makeShader(Self.probe)
        try canvas.draw {
            canvas.background(self.black)
            canvas.fill(self.white)
            switch outline {
            case .none: canvas.noStroke()
            case .thin:
                canvas.stroke(self.red)
                canvas.strokeWeight(1)
            case .thick:
                canvas.stroke(self.red)
                canvas.strokeWeight(4)
            }
            if pastingWhite, let image = creating({ try self.makeWhite(canvas) }) { canvas.texture(image) }
            canvas.shader(shader)
            for placement in Self.placements.prefix(count) {
                canvas.push()
                if figure.isSolid {
                    canvas.translate(placement.x, placement.y, 0)
                    canvas.rotateX(0.5 + placement.turn)
                    canvas.rotateY(0.6 + placement.turn)
                } else {
                    canvas.translate(placement.x, placement.y)
                    canvas.rotate(placement.turn)
                }
                canvas.scale(placement.scale)
                figure.place(on: canvas)
                canvas.pop()
            }
        }
        return try canvas.target.encodeForDisplay()
    }

    // MARK: - 白い絵を貼ったときと同じ絵

    @Test(
        "断片だけを当てた形は、白い 1×1 の絵を貼ってから当てた形と同じ画素になる",
        arguments: Figure.allCases, Outline.allCases)
    func shaderAloneMatchesPastingWhite(_ figure: Figure, outline: Outline) throws {
        for count in [1, Self.placements.count] {
            let alone = try render(figure, outline: outline, placed: count, pastingWhite: false)
            let pasted = try render(figure, outline: outline, placed: count, pastingWhite: true)
            #expect(alone == pasted, "置き場所 \(count) つで画素が食い違った")
            // **読み取り位置が形の中で動いている。** 1 点に固定されていれば、塗りは数色にしかならない。
            // 見るのは線なしのときだけ — 太い線は細い楕円や球の網目の塗りを覆い隠す
            guard outline == .none else { continue }
            var colours = Set<UInt32>()
            for offset in stride(from: 0, to: alone.bytes.count, by: 4) {
                let pixel = alone.bytes[offset..<offset + 4].reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
                colours.insert(pixel)
            }
            #expect(colours.count > 12, "色が \(colours.count) 種類しかない (読み取り位置が動いていない)")
        }
    }

    // MARK: - 費用の約束

    @Test("線を引いたまま断片を当てても、塗りと輪郭が同じ面を読み、形ごとに列が割れない")
    func outlinesShareTheFillSurface() throws {
        let canvas = try makeCanvas()
        let shader = try canvas.makeShader(Self.probe)
        var batchCount = 0
        var folded = 0
        var readsBlank: [Bool] = []
        try canvas.draw {
            canvas.background(self.black)
            canvas.fill(self.white)
            canvas.stroke(self.red)
            canvas.shader(shader)
            for index in 0..<3 {
                canvas.circle(16 + Float(index) * 30, 20, 20)
            }
            for index in 0..<3 {
                canvas.rect(6 + Float(index) * 30, 60, 20, 20)
            }
            folded = canvas.flatInstances.count
            canvas.closeBatch()
            batchCount = canvas.batches.count
            let blank = canvas.blankPicture?.texture
            readsBlank = canvas.batches.map { $0.run.texture.texture === blank }
        }
        // 塗りと輪郭が別の面を読めば、形ごとに列が閉じて 12 列になる
        #expect(batchCount <= 2, "列: \(batchCount)")
        // 線を引いた形も雛形に畳まれる (円 3 つ・四角 3 つの置き場所と雛形)。塗りが絵を読むときの「絵と輪郭は
        // 畳まない」に掛かると、ほとんど畳まれない
        #expect(folded == 7, "畳んだ置き場所: \(folded)")
        #expect(!readsBlank.isEmpty && readsBlank.allSatisfy { $0 }, "白い 1×1 を読まない列がある: \(readsBlank)")
    }

    // MARK: - 変わらないもの

    @Test("勾配の塗りは読み取り位置を持たず、焼き場を読む")
    func gradientFillsAreUnchanged() throws {
        let canvas = try makeCanvas()
        var flat: [ShapeVertex] = []
        var solid: [SolidVertex] = []
        var readsAtlas: [Bool] = []
        try canvas.draw {
            canvas.fill(.linearGradient((self.black, 0), (self.white, 1), from: [0, 0], to: [96, 0]))
            canvas.stroke(self.red)
            canvas.quad(4, 4, 40, 4, 40, 30, 4, 30)
            canvas.beginShape()
            canvas.vertex(50, 4)
            canvas.vertex(90, 10)
            canvas.vertex(70, 40)
            canvas.endShape(.close)
            canvas.push()
            canvas.translate(48, 70, 0)
            canvas.box(16)
            canvas.pop()
            flat = canvas.vertices
            solid = canvas.solidVertices
            canvas.closeBatch()
            readsAtlas = canvas.batches.map { $0.run.texture.texture === canvas.atlas.texture }
        }
        let whiteUV = canvas.whiteUV
        #expect(!flat.isEmpty && flat.allSatisfy { $0.uv == whiteUV })
        #expect(!solid.isEmpty && solid.allSatisfy { $0.uv == whiteUV })
        #expect(readsAtlas.allSatisfy { $0 }, "焼き場を読まない列がある: \(readsAtlas)")
    }

    @Test("断片を当てて外した形は、当てたことの無い形と頂点も列も 1 ビットも変わらない")
    func resettingTheShaderLeavesNoTrace() throws {
        func trace(applyingThenResetting: Bool) throws -> ([ShapeVertex], [SolidVertex], Int) {
            let canvas = try makeCanvas()
            let shader = try canvas.makeShader(Self.probe)
            var flat: [ShapeVertex] = []
            var solid: [SolidVertex] = []
            var batches = 0
            try canvas.draw {
                if applyingThenResetting {
                    canvas.shader(shader)
                    canvas.resetShader()
                }
                canvas.fill(self.red)
                canvas.stroke(self.white)
                canvas.quad(4, 4, 24, 4, 24, 16, 4, 16)
                canvas.push()
                canvas.translate(48, 48, 0)
                canvas.box(10)
                canvas.pop()
                flat = canvas.vertices
                solid = canvas.solidVertices
                canvas.closeBatch()
                batches = canvas.batches.count
            }
            return (flat, solid, batches)
        }

        let plain = try trace(applyingThenResetting: false)
        let reset = try trace(applyingThenResetting: true)
        #expect(plain.0.count == reset.0.count)
        #expect(plain.1.count == reset.1.count)
        #expect(zip(plain.0, reset.0).allSatisfy { $0.uv == $1.uv })
        #expect(zip(plain.1, reset.1).allSatisfy { $0.uv == $1.uv })
        #expect(plain.2 == reset.2)
    }

    @Test("断片を当てても、字は字形を、画像は絵を読む")
    func textAndImagesKeepTheirSurfaces() throws {
        let canvas = try makeCanvas()
        let shader = try canvas.makeShader(Self.probe)
        var readsAtlas = false
        var readsImage = false
        try canvas.draw {
            canvas.shader(shader)
            canvas.fill(self.white)
            canvas.text("A", 10, 30)
            canvas.closeBatch()
            readsAtlas = canvas.batches.last?.run.texture.texture === canvas.atlas.texture
            guard let image = creating({ try self.makeWhite(canvas) }) else { return }
            canvas.image(image, 40, 40, 20, 20)
            canvas.closeBatch()
            readsImage = canvas.batches.last?.run.texture.texture === image.texture
        }
        #expect(readsAtlas, "字が焼き場を読まない")
        #expect(readsImage, "画像が自分の絵を読まない")
    }

    @Test("断片なしで記録した形は、置く側で断片を当てても読み取り位置を持たない")
    func placingSideShaderDoesNotReachRecordedShapes() throws {
        let canvas = try makeCanvas()
        let shader = try canvas.makeShader(Self.probe)
        var recorded: Shape?
        var flat: [ShapeVertex] = []
        try canvas.draw {
            canvas.noStroke()
            canvas.fill(self.white)
            recorded = canvas.createShape { canvas.quad(-10, -10, 10, -10, 10, 10, -10, 10) }
            canvas.shader(shader)
            if let recorded { canvas.shape(recorded, 48, 48) }
            flat = canvas.vertices
        }
        let whiteUV = canvas.whiteUV
        #expect(!flat.isEmpty && flat.allSatisfy { $0.uv == whiteUV })
    }

    @Test("断片を当てて作った粒の板は、板の 0…1 を読み取り位置に持つ")
    func particleBoardsCarryTheirPlaneCoordinates() throws {
        let canvas = try makeCanvas()
        let shader = try canvas.makeShader(Self.probe)
        var shaded: Particles?
        var plain: Particles?
        try canvas.draw {
            plain = creating({ try canvas.makeParticles(count: 4) })
            canvas.shader(shader)
            shaded = creating({ try canvas.makeParticles(count: 4) })
        }
        let whiteUV = canvas.whiteUV
        let board = try #require(shaded).quad.solidVertices.map(\.uv)
        #expect(Set(board.map(\.x)) == [0, 1] && Set(board.map(\.y)) == [0, 1], "板の読み取り位置: \(board)")
        #expect(try #require(plain).quad.solidVertices.allSatisfy { $0.uv == whiteUV })
    }
}
