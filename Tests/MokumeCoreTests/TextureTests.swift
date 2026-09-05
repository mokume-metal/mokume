// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Testing
import simd

@testable import MokumeCore

/// 焼いた絵を面に貼る口の検査。GPU を要する。
///
/// ## 何をどこで見るか
///
/// 貼れているかの判定は目が担う ([ADR-0019] 決定 1)。ここが見るのは**目には
/// 判定できない性質**である:
///
/// - 貼っていないときの頂点が、貼る口が無かった頃と**同一**であること
///   (絵は変わらないので、絵からは判定できない)
/// - 貼る絵が**塗りにしか効かない**こと (輪郭・字・周囲は焼き場を読み続ける)。
///   列の読む面を数えるので、色の似た絵に紛れない
/// - 組み込みの形が持つ読み取り位置が 0…1 に収まり、継ぎ目が 1 で閉じること
///
/// 貼った絵が正しい向きで出ることだけは画素で見る — 上下が逆でも「貼れてはいる」
/// ので、構造からは判定できないためである。
///
/// [ADR-0019]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0019-drawing-verification.md
@Suite(
    "貼る絵",
    .enabled(
        if: RenderDevice.isAvailable,
        "この世代のコマンド構造に対応した GPU が無い実行環境ではスキップする")
)
struct TextureTests {
    private let black = LinearRGBA.linear(red: 0, green: 0, blue: 0)
    private let white = LinearRGBA.linear(red: 1, green: 1, blue: 1)
    private let red = LinearRGBA.display(red: 1, green: 0, blue: 0)

    private func makeCanvas(width: Int = 64, height: Int = 64) throws -> Canvas {
        try CanvasFixture.make(gpu: RenderDevice(), width: width, height: height)
    }

    private func pixels(of canvas: Canvas) throws -> DisplayImage {
        try canvas.target.encodeForDisplay()
    }

    /// 4 つの区画をそれぞれ 1 色で塗った絵。**どの隅がどこへ行ったかが読める。**
    ///
    /// 左上 赤 / 右上 緑 / 左下 青 / 右下 白。
    private func makeQuadrants(_ canvas: Canvas, size: Int = 16) throws -> Image {
        let image = try canvas.createImage(size, size)
        let half = size / 2
        for y in 0..<size {
            for x in 0..<size {
                let color: LinearRGBA =
                    switch (x < half, y < half) {
                    case (true, true): .display(red: 1, green: 0, blue: 0)
                    case (false, true): .display(red: 0, green: 1, blue: 0)
                    case (true, false): .display(red: 0, green: 0, blue: 1)
                    case (false, false): .display(red: 1, green: 1, blue: 1)
                    }
                image.set(x, y, color)
            }
        }
        return image
    }

    // MARK: - 貼っていないときは何も変わらない

    @Test("貼る絵を束ねていなければ、頂点は 1 つも変わらない")
    func withoutATextureTheVerticesAreUnchanged() throws {
        func trace(bindingThenClearing: Bool) throws -> ([ShapeVertex], [SolidVertex]) {
            let canvas = try makeCanvas()
            var flat: [ShapeVertex] = []
            var solid: [SolidVertex] = []
            try canvas.draw {
                if bindingThenClearing {
                    let image = try? self.makeQuadrants(canvas)
                    if let image { canvas.texture(image) }
                    canvas.noTexture()
                }
                canvas.fill(self.red)
                canvas.stroke(self.white)
                // 四角形は三角形の経路で積まれる (矩形は距離関数で描くので頂点を持たない — #752)
                canvas.quad(4, 4, 24, 4, 24, 16, 4, 16)
                canvas.push()
                canvas.translate(32, 32, 0)
                canvas.box(10)
                canvas.pop()
                flat = canvas.vertices
                solid = canvas.solidVertices
            }
            return (flat, solid)
        }

        let plain = try trace(bindingThenClearing: false)
        let cleared = try trace(bindingThenClearing: true)

        // **束ねて外した後も、束ねたことが無いのと 1 ビットも変わらない**
        #expect(plain.0.count == cleared.0.count)
        #expect(plain.1.count == cleared.1.count)
        #expect(zip(plain.0, cleared.0).allSatisfy { $0.uv == $1.uv })
        #expect(zip(plain.1, cleared.1).allSatisfy { $0.uv == $1.uv })
        // 焼き場の白い区画を指したままであること (立体も平面も同じ 1 点)
        #expect(plain.1.allSatisfy { $0.uv == plain.0[0].uv })
    }

    // MARK: - 効く先

    @Test("束ねると塗りの列だけが絵の面を読み、輪郭の列は焼き場のまま")
    func onlyFillsReadThePastedImage() throws {
        let canvas = try makeCanvas()
        var readsImage: [Bool] = []
        try canvas.draw {
            let image = try? self.makeQuadrants(canvas)
            guard let image else { return }
            canvas.texture(image)
            canvas.fill(self.white)
            canvas.stroke(self.red)
            canvas.strokeWeight(4)
            canvas.rect(8, 8, 32, 32)
            canvas.closeBatch()
            readsImage = canvas.batches.map { $0.run.texture === image.texture }
        }

        // 塗りと輪郭で列が分かれ、**先に置いた塗りだけ**が絵を読む
        #expect(readsImage == [true, false])
    }

    @Test("字には貼られない")
    func textIsNeverPasted() throws {
        let canvas = try makeCanvas()
        var readsImage: [Bool] = []
        try canvas.draw {
            let image = try? self.makeQuadrants(canvas)
            guard let image else { return }
            canvas.texture(image)
            canvas.fill(self.white)
            canvas.textSize(12)
            canvas.text("あ", 4, 20)
            canvas.closeBatch()
            readsImage = canvas.batches.map { $0.run.texture === image.texture }
        }
        #expect(!readsImage.isEmpty)
        #expect(readsImage.allSatisfy { !$0 })
    }

    @Test("周囲そのものには貼られない")
    func theSurroundingsAreNeverPasted() throws {
        let canvas = try makeCanvas()
        var readsImage: [Bool] = []
        try canvas.draw {
            let image = try? self.makeQuadrants(canvas)
            guard let image else { return }
            canvas.texture(image)
            // 周囲そのものを出すのは「背景として描く」ほう
            canvas.background(Surroundings.sky)
            canvas.closeBatch()
            readsImage = canvas.batches.map { $0.run.texture === image.texture }
        }
        #expect(!readsImage.isEmpty)
        #expect(readsImage.allSatisfy { !$0 })
    }

    // MARK: - 寿命

    @Test("貼る絵は積める")
    func thePastedImageIsPartOfTheStyle() throws {
        let canvas = try makeCanvas()
        try canvas.draw {
            let image = try? self.makeQuadrants(canvas)
            guard let image else { return }
            canvas.push()
            canvas.texture(image)
            #expect(canvas.currentPicture?.texture === image.texture)
            canvas.pop()
            #expect(canvas.currentPicture == nil)

            canvas.texture(image)
            canvas.noTexture()
            #expect(canvas.currentPicture == nil)
        }
    }

    // MARK: - 組み込みの形が持つ読み取り位置

    @Test(
        "組み込みの形の読み取り位置は 0…1 に収まる",
        arguments: [
            SolidShape.box(width: 20, height: 30, depth: 40),
            .plane(width: 20, height: 30),
            .sphere(radius: 10, detail: 12),
            .cylinder(radius: 10, height: 20, detail: 12),
            .cone(radius: 10, height: 20, detail: 12),
            .torus(ringRadius: 10, tubeRadius: 3, detail: 12),
        ])
    func builtInShapesStayInsideTheImage(_ shape: SolidShape) throws {
        let mesh = shape.make()
        #expect(!mesh.points.isEmpty)
        for point in mesh.points {
            #expect(point.uv.x >= 0 && point.uv.x <= 1)
            #expect(point.uv.y >= 0 && point.uv.y <= 1)
        }
        // **端まで使う。** 縮こまっていると、貼った絵の一部しか出ない
        #expect(mesh.points.contains { $0.uv.x >= 0.999 })
        #expect(mesh.points.contains { $0.uv.y >= 0.999 })
    }

    @Test("箱は 6 面それぞれに 1 枚ずつ収める")
    func aBoxCarriesOneImagePerFace() throws {
        let mesh = SolidShape.box(width: 20, height: 20, depth: 20).make()
        // 6 面 × 2 枚 × 3 点
        #expect(mesh.points.count == 36)
        for face in 0..<6 {
            let corners = Set(
                mesh.points[(face * 6)..<(face * 6 + 6)].map { SIMD2($0.uv.x, $0.uv.y) })
            #expect(corners == [SIMD2(0, 0), SIMD2(0, 1), SIMD2(1, 1), SIMD2(1, 0)])
        }
    }

    @Test("球の継ぎ目は 0 ではなく 1 で閉じる")
    func theSphereSeamClosesAtOne() throws {
        let mesh = SolidShape.sphere(radius: 10, detail: 8).make()
        // 一周の最後の帯が 0 へ戻ると、その 1 枚だけに絵の全部が押し込まれる
        #expect(mesh.points.contains { $0.uv.x == 1 })
    }

    // MARK: - 自分で書く読み取り位置

    @Test("書いた読み取り位置は絵の画素として読まれる")
    func writtenCoordinatesAreReadAsPixels() throws {
        let canvas = try makeCanvas()
        var written: [SIMD2<Float>] = []
        try canvas.draw {
            guard let image = try? self.makeQuadrants(canvas, size: 16) else { return }
            canvas.texture(image)
            canvas.fill(self.white)
            canvas.noStroke()
            canvas.beginShape()
            canvas.vertex(0, 0, 0, 0, 0)
            canvas.vertex(20, 0, 0, 16, 0)
            canvas.vertex(20, 20, 0, 16, 16)
            canvas.endShape(.close)
            written = canvas.solidVertices.map(\.uv)
        }
        // 16 画素の絵に 16 を書けば、面の端 (1.0) を指す
        #expect(written.contains(SIMD2(0, 0)))
        #expect(written.contains(SIMD2(1, 0)))
        #expect(written.contains(SIMD2(1, 1)))
    }

    @Test("書かなかった頂点は形の囲みの箱から決まる")
    func unwrittenVerticesFallBackToTheBoundingBox() throws {
        let canvas = try makeCanvas()
        var written: [SIMD2<Float>] = []
        try canvas.draw {
            guard let image = try? self.makeQuadrants(canvas) else { return }
            canvas.texture(image)
            canvas.fill(self.white)
            canvas.noStroke()
            canvas.beginShape()
            canvas.vertex(10, 10)
            canvas.vertex(30, 10)
            canvas.vertex(30, 50)
            canvas.vertex(10, 50)
            canvas.endShape(.close)
            canvas.closeBatch()
            written = canvas.vertices.map(\.uv)
        }
        // 囲みの箱の四隅がそのまま絵の四隅になる
        #expect(written.contains(SIMD2(0, 0)))
        #expect(written.contains(SIMD2(1, 0)))
        #expect(written.contains(SIMD2(1, 1)))
        #expect(written.contains(SIMD2(0, 1)))
    }

    // MARK: - 向き

    @Test("貼った絵は上下も左右も逆にならない")
    func thePastedImageKeepsItsOrientation() throws {
        let canvas = try makeCanvas()
        let size = 40
        try canvas.draw {
            canvas.background(self.black)
            guard let image = try? self.makeQuadrants(canvas) else { return }
            canvas.texture(image)
            canvas.fill(self.white)
            canvas.noStroke()
            canvas.push()
            canvas.translate(32, 32, 0)
            canvas.plane(Float(size), Float(size))
            canvas.pop()
        }

        // 面の中心が (32, 32)。四隅の区画の真ん中を見る
        let drawn = try pixels(of: canvas)
        #expect(drawn[22, 22] == (255, 0, 0, 255))  // 左上 赤
        #expect(drawn[42, 22] == (0, 255, 0, 255))  // 右上 緑
        #expect(drawn[22, 42] == (0, 0, 255, 255))  // 左下 青
        #expect(drawn[42, 42] == (255, 255, 255, 255))  // 右下 白
    }

    @Test("平面の図形にも同じ向きで貼られる")
    func flatShapesArePastedTheSameWay() throws {
        let canvas = try makeCanvas()
        try canvas.draw {
            canvas.background(self.black)
            guard let image = try? self.makeQuadrants(canvas) else { return }
            canvas.texture(image)
            canvas.fill(self.white)
            canvas.noStroke()
            canvas.rect(12, 12, 40, 40)
        }

        let drawn = try pixels(of: canvas)
        #expect(drawn[22, 22] == (255, 0, 0, 255))
        #expect(drawn[42, 22] == (0, 255, 0, 255))
        #expect(drawn[22, 42] == (0, 0, 255, 255))
        #expect(drawn[42, 42] == (255, 255, 255, 255))
    }

    @Test("塗りが色掛けになる")
    func theFillTintsThePastedImage() throws {
        let canvas = try makeCanvas()
        try canvas.draw {
            canvas.background(self.black)
            guard let image = try? self.makeQuadrants(canvas) else { return }
            canvas.texture(image)
            // 右下の区画は白なので、掛けた色がそのまま出る
            canvas.fill(self.red)
            canvas.noStroke()
            canvas.rect(12, 12, 40, 40)
        }

        let drawn = try pixels(of: canvas)
        #expect(drawn[42, 42] == (255, 0, 0, 255))
        // 緑の区画に赤を掛ければ黒になる
        #expect(drawn[42, 22] == (0, 0, 0, 255))
    }
}
