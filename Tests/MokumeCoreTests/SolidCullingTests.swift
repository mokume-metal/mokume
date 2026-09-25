// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Metal
import Testing

@testable import MokumeCore

/// 立体の列が、裏面を捨てる列と両面を描く列に正しく分かれることの検査。GPU を要する。
///
/// 見るのは**列の属性**である。裏面を捨てても閉じた形の絵は 1 画素も動かないので、
/// 絵からは「捨てているか」を判定できない — 捨ててはいけない列で捨てたときだけ絵が
/// 変わる (片面の面が裏から消える・半透明の奥が抜ける)。だから正しさは列の値で見て、
/// 絵が動かないことは代表シーンの台帳 (``SceneLedgerTests``) に任せる
/// ([#756](https://github.com/mokume-metal/mokume/issues/756))。
@Suite(
    "立体の背面カリング",
    .enabled(
        if: RenderDevice.isAvailable,
        "この世代のコマンド構造に対応した GPU が無い実行環境ではスキップする")
)
struct SolidCullingTests {
    private func makeCanvas(width: Int = 64, height: Int = 64) throws -> Canvas {
        try CanvasFixture.make(gpu: RenderDevice(), width: width, height: height)
    }

    /// 1 フレームの中で置いたものを列に閉じ、その列の捨て方を返す。
    private func cullModes(_ body: (Canvas) throws -> Void) throws -> [MTLCullMode] {
        try solidBatches(body).map(\.cullMode)
    }

    /// 1 フレームの中で置いたものを列に閉じ、立体の列を返す。
    private func solidBatches(_ body: (Canvas) throws -> Void) throws -> [Canvas.Batch] {
        let canvas = try makeCanvas()
        var solids: [Canvas.Batch] = []
        try canvas.draw {
            canvas.noStroke()
            try? body(canvas)
            canvas.closeBatch()
            solids = canvas.batches.filter { $0.source == .solid }
        }
        return solids
    }

    // MARK: - 捨てる列

    @Test("閉じた組み込みの形の、不透明な列は裏面を捨てる", arguments: [
        SolidShape.box(width: 20, height: 20, depth: 20),
        .sphere(radius: 10, detail: 24),
        .cylinder(radius: 10, height: 20, detail: 24),
        .cone(radius: 10, height: 20, detail: 24),
        .torus(ringRadius: 10, tubeRadius: 3, detail: 24),
    ])
    func opaqueClosedMeshesCullBackFaces(_ shape: SolidShape) throws {
        let modes = try cullModes { canvas in
            canvas.fill(.linear(red: 1, green: 0.5, blue: 0))
            canvas.place(shape)
        }
        #expect(modes == [.back])
    }

    @Test("同じ形を何個置いても、列は 1 つで裏面を捨てる")
    func manyInstancesShareOneCulledBatch() throws {
        let modes = try cullModes { canvas in
            canvas.fill(.linear(red: 1, green: 0.5, blue: 0))
            for index in 0..<8 {
                canvas.push()
                canvas.translate(Float(index) * 6, 0, 0)
                canvas.sphere(4)
                canvas.pop()
            }
        }
        #expect(modes == [.back])
    }

    // MARK: - 鏡映した置き場所 (#1446)

    /// 置き場所の鏡映。**奇数本の軸を裏返すと巻き方が裏返り**、偶数本なら回転と同じで
    /// 裏返らない。
    struct Mirroring: Sendable, CustomTestStringConvertible {
        var x: Float
        var y: Float
        var z: Float
        var testDescription: String { "scale(\(x), \(y), \(z))" }
    }

    @Test(
        "鏡映した置き場所だけの列は、表の巻き方が裏返り、裏面は捨てたまま",
        arguments: [
            Mirroring(x: -1, y: 1, z: 1), Mirroring(x: 1, y: -1, z: 1),
            Mirroring(x: 1, y: 1, z: -1), Mirroring(x: -1, y: -1, z: -1),
        ])
    func mirroredPlacementsReverseTheFrontFace(_ mirror: Mirroring) throws {
        // 巻き方が裏返ったまま `.back` で捨てると、手前の面が捨てられて奥の面だけが写る
        // (#1446 の事象)。両面にして逃げずに、表の巻き方を裏返して `.back` のまま捨てる
        let solids = try solidBatches { canvas in
            canvas.fill(.linear(red: 1, green: 0.5, blue: 0))
            canvas.scale(mirror.x, mirror.y, mirror.z)
            canvas.box(20)
        }
        #expect(solids.map(\.frontFacing) == [.counterClockwise])
        #expect(solids.map(\.cullMode) == [.back])
    }

    @Test("2 本の軸を裏返した置き場所は回転と同じなので、表の巻き方は裏返らない")
    func twoMirroredAxesKeepTheFrontFace() throws {
        let solids = try solidBatches { canvas in
            canvas.fill(.linear(red: 1, green: 0.5, blue: 0))
            canvas.scale(-1, -1, 1)
            canvas.box(20)
        }
        #expect(solids.map(\.frontFacing) == [.clockwise])
        #expect(solids.map(\.cullMode) == [.back])
    }

    @Test("鏡映した置き場所と鏡映していない置き場所は、同じ列に同居しない")
    func mirroredAndUnmirroredPlacementsDoNotShareABatch() throws {
        // 表の巻き方は列ごとに 1 つしか持てない。同じ形が続いても、鏡映の符号が
        // 変わったら列を閉じる
        let solids = try solidBatches { canvas in
            canvas.fill(.linear(red: 1, green: 0.5, blue: 0))
            canvas.box(20)
            canvas.push()
            canvas.scale(-1, 1, 1)
            canvas.box(20)
            canvas.pop()
            canvas.box(20)
        }
        #expect(solids.map(\.frontFacing) == [.clockwise, .counterClockwise, .clockwise])
        #expect(solids.map(\.cullMode) == [.back, .back, .back])
    }

    @Test("保持した形を鏡映と非鏡映の置き場所へまとめて置いても、列は符号ごとに分かれる")
    func retainedPlacementsSplitByMirroring() throws {
        // 置き場所の大きさを負にすると、3 本の軸が全部裏返る (点対称 = 鏡映)
        let canvas = try makeCanvas()
        let crate = canvas.createShape {
            canvas.noStroke()
            canvas.fill(.linear(red: 1, green: 0.5, blue: 0))
            canvas.box(10)
        }
        var solids: [Canvas.Batch] = []
        try canvas.draw {
            canvas.shape(
                crate,
                at: [
                    Placement(x: 10, scale: 1), Placement(x: 30, scale: 1),
                    Placement(x: 50, scale: -1), Placement(x: 20, y: 30, scale: 1),
                ])
            canvas.closeBatch()
            solids = canvas.batches.filter { $0.source == .solid }
        }
        #expect(solids.map(\.frontFacing) == [.clockwise, .counterClockwise, .clockwise])
        #expect(solids.map(\.instanceCount) == [2, 1, 1])
    }

    @Test("上下か左右を裏返す投影は表の巻き方を裏返し、手前と奥の入れ替えは裏返さない")
    func projectionsThatFlipTheScreenReverseTheFrontFace() throws {
        // 4x4 の行列式は手前と奥を入れ替えただけでも負になる。物差しは「投影が画面の
        // 縦横を裏返すか」で、奥行きの向きは巻き方に関わらない
        func frontFacing(_ project: (Canvas) -> Void, mirrored: Bool = false) throws -> [MTLWinding] {
            try solidBatches { canvas in
                project(canvas)
                canvas.fill(.linear(red: 1, green: 0.5, blue: 0))
                if mirrored { canvas.scale(-1, 1, 1) }
                canvas.box(20)
            }.map(\.frontFacing)
        }
        #expect(try frontFacing { $0.ortho() } == [.clockwise])
        #expect(try frontFacing { $0.ortho(-32, 32, -32, 32, 5, 600) } == [.counterClockwise])
        #expect(try frontFacing { $0.ortho(32, -32, 32, -32, 5, 600) } == [.counterClockwise])
        #expect(try frontFacing { $0.ortho(32, -32, -32, 32, 5, 600) } == [.clockwise])
        #expect(try frontFacing { $0.ortho(-32, 32, 32, -32, 600, 5) } == [.clockwise])
        // 裏返す投影で鏡映した置き場所は、2 度裏返って元に戻る
        #expect(
            try frontFacing({ $0.ortho(-32, 32, -32, 32, 5, 600) }, mirrored: true) == [.clockwise])
    }

    // MARK: - 捨てない列

    @Test("平らな面は片面なので、裏面を捨てない")
    func planeKeepsBothFaces() throws {
        let modes = try cullModes { canvas in
            canvas.fill(.linear(red: 1, green: 0.5, blue: 0))
            canvas.plane(20, 20)
        }
        #expect(modes == [.none])
    }

    @Test("自分で並べた頂点の列は、裏面を捨てない")
    func freeformKeepsBothFaces() throws {
        let modes = try cullModes { canvas in
            canvas.fill(.linear(red: 1, green: 0.5, blue: 0))
            canvas.beginShape()
            canvas.vertex(-10, -10, 0)
            canvas.vertex(10, -10, 0)
            canvas.vertex(10, 10, 0)
            canvas.vertex(-10, 10, 0)
            canvas.endShape(.close)
        }
        #expect(modes == [.none])
    }

    @Test("半透明の置き場所を 1 つでも含む列は、裏面を捨てない")
    func translucentInstanceKeepsBothFaces() throws {
        // 塗りを変えても列は閉じないので、不透明と半透明が同じ列に同居する。
        // 半透明の球は奥の面が手前の面を通して見えるので、列ごと両面で描く
        let modes = try cullModes { canvas in
            canvas.fill(.linear(red: 1, green: 0.5, blue: 0))
            canvas.sphere(10)
            canvas.fill(LinearRGBA(straightRed: 1, green: 0.5, blue: 0, alpha: 0.5))
            canvas.push()
            canvas.translate(20, 0, 0)
            canvas.sphere(10)
            canvas.pop()
        }
        #expect(modes == [.none])
    }

    @Test("絵を貼った列は、裏面を捨てない")
    func texturedMeshKeepsBothFaces() throws {
        // 貼った絵に透けている画素があれば、そこから奥の面が見える
        let canvas = try makeCanvas()
        let picture = try canvas.createGraphics(8, 8)
        try picture.draw { picture.background(.linear(red: 1, green: 1, blue: 1)) }
        var modes: [MTLCullMode] = []
        try canvas.draw {
            canvas.noStroke()
            canvas.fill(.linear(red: 1, green: 1, blue: 1))
            canvas.texture(picture)
            canvas.box(20)
            canvas.closeBatch()
            modes = canvas.batches.filter { $0.source == .solid }.map(\.cullMode)
        }
        #expect(modes == [.none])
    }

    @Test("重ねる混ぜ方の列は、裏面を捨てない")
    func additiveBlendKeepsBothFaces() throws {
        // 足し合わせる混ぜ方では奥の面も色に寄与するので、捨てると絵が暗くなる
        let modes = try cullModes { canvas in
            canvas.blendMode(.add)
            canvas.fill(.linear(red: 1, green: 0.5, blue: 0))
            canvas.sphere(10)
        }
        #expect(modes == [.none])
    }

    @Test("利用者の断片で塗る列は、裏面を捨てない")
    func userShaderKeepsBothFaces() throws {
        // 断片は透明を返したり画素を捨てたりできるので、奥の面が見えうる
        let canvas = try makeCanvas()
        let shader = try canvas.makeShader(
            """
            float4 paint(Fragment in, Values values) {
                return float4(in.color.rgb, 0.5);
            }
            """)
        var modes: [MTLCullMode] = []
        try canvas.draw {
            canvas.noStroke()
            canvas.shader(shader)
            canvas.fill(.linear(red: 1, green: 0.5, blue: 0))
            canvas.sphere(10)
            canvas.closeBatch()
            modes = canvas.batches.filter { $0.source == .solid }.map(\.cullMode)
        }
        #expect(modes == [.none])
    }

    // MARK: - 置いた後で外した絵 (#1564)

    /// 形を置いた後で、貼った絵を外す口。**どちらも列を閉じない** — 列が閉じるのは、次に
    /// 形を置くとき (貼る面の切り替え) か、ほかの理由で閉じるときで、そのときスタイルには
    /// もう絵が無い。
    enum PictureRemoval: String, CaseIterable, Sendable, CustomTestStringConvertible {
        /// `noTexture()` を呼ぶ。
        case noTexture
        /// `push()` の後で貼り、`pop()` で戻す。
        case pop
        var testDescription: String { rawValue }
    }

    @Test("絵を貼った形を置いた後で絵を外しても、その列は裏面を捨てない", arguments: PictureRemoval.allCases)
    func removingThePictureAfterPlacingKeepsBothFaces(_ removal: PictureRemoval) throws {
        // 裏面を捨てるかは、形を置いたときのスタイルで決まる。後から外した絵は、既に置いた
        // 形に効かない — 効くと、透けた画素から見えるはずの奥の面が消える
        let canvas = try makeCanvas()
        let picture = try canvas.createGraphics(8, 8)
        try picture.draw { picture.background(.linear(red: 1, green: 1, blue: 1)) }
        var modes: [MTLCullMode] = []
        try canvas.draw {
            canvas.noStroke()
            canvas.fill(.linear(red: 1, green: 1, blue: 1))
            if removal == .pop { canvas.push() }
            canvas.texture(picture)
            canvas.box(20)
            switch removal {
            case .noTexture: canvas.noTexture()
            case .pop: canvas.pop()
            }
            canvas.closeBatch()
            modes = canvas.batches.filter { $0.source == .solid }.map(\.cullMode)
        }
        #expect(modes == [.none])
    }

    @Test("絵を外した後に置いた、絵の無い不透明な閉じた形は裏面を捨てる")
    func shapesPlacedAfterRemovingThePictureStillCull() throws {
        // 外した後の形は、外した後のスタイルで決まる。絵を貼った列の性質が後ろの列へ
        // 漏れていないことを見る
        let canvas = try makeCanvas()
        let picture = try canvas.createGraphics(8, 8)
        try picture.draw { picture.background(.linear(red: 1, green: 1, blue: 1)) }
        var modes: [MTLCullMode] = []
        try canvas.draw {
            canvas.noStroke()
            canvas.fill(.linear(red: 1, green: 1, blue: 1))
            canvas.texture(picture)
            canvas.box(20)
            canvas.noTexture()
            canvas.sphere(10)
            canvas.closeBatch()
            modes = canvas.batches.filter { $0.source == .solid }.map(\.cullMode)
        }
        #expect(modes == [.none, .back])
    }

    @Test("平面の列は捨て方を持たない")
    func flatBatchesAreNeverCulled() throws {
        let canvas = try makeCanvas()
        var modes: [MTLCullMode] = []
        try canvas.draw {
            canvas.fill(.linear(red: 1, green: 0.5, blue: 0))
            canvas.rect(4, 4, 20, 20)
            canvas.closeBatch()
            modes = canvas.batches.map(\.cullMode)
        }
        #expect(modes == [.none])
    }

    // MARK: - 絵

    @Test("裏面を捨てた球は、正面から見て塗りの色で埋まっている")
    func culledSphereStillFillsItsSilhouette() throws {
        // 巻き方が逆だと表が捨てられて裏だけが残り、真ん中は奥の面 (奥行きは書かれる) の
        // 色になる — 光が無いので色は同じで、ここでは「何も出ない」形の欠陥だけを見る。
        // 巻き方そのものは SolidMeshTests が見ている
        let canvas = try makeCanvas()
        try canvas.draw {
            canvas.background(.linear(red: 0, green: 0, blue: 0))
            canvas.noStroke()
            canvas.fill(.display(red: 1, green: 0, blue: 0))
            canvas.push()
            canvas.translate(32, 32, 0)
            canvas.sphere(20)
            canvas.pop()
        }
        let image = try canvas.target.encodeForDisplay()
        #expect(image[32, 32].red > 230)
        #expect(image[2, 2].red < 20)
    }

    /// 鏡映した箱と、それと同じ形になる回転の箱の組。
    ///
    /// 箱は軸ごとの鏡映で自分に重なり、鏡映は回転と入れ替えると回る向きが変わる
    /// (`S·RY(a)·RX(b) = RY(±a)·RX(±b)·S`)。だから**正しく写っていれば、2 枚は幾何的に
    /// 同じ絵**になる。
    struct MirroredBox: Sendable, CustomTestStringConvertible {
        var mirror: Mirroring
        var yaw: Float
        var pitch: Float
        var testDescription: String { "\(mirror.testDescription) ≡ rotateY(\(yaw)) rotateX(\(pitch))" }
    }

    /// Issue の再現手順の絵 (160×160)。`mirror` を掛けてから回して置いた箱。
    private func litBox(mirror: Mirroring?, yaw: Float, pitch: Float) throws -> DisplayImage {
        let canvas = try makeCanvas(width: 160, height: 160)
        try canvas.draw {
            canvas.background(20)
            canvas.noStroke()
            canvas.directionalLight(255, 255, 255, 0, 0, -1)
            canvas.fill(230, 60, 40)
            canvas.translate(80, 80, 0)
            if let mirror { canvas.scale(mirror.x, mirror.y, mirror.z) }
            canvas.rotateY(yaw)
            canvas.rotateX(pitch)
            canvas.box(70)
        }
        return try canvas.target.encodeForDisplay()
    }

    @Test(
        "鏡映した箱は、同じ形になる回転の箱と同じ絵に写る",
        arguments: [
            MirroredBox(mirror: Mirroring(x: -1, y: 1, z: 1), yaw: -0.6, pitch: 0.5),
            MirroredBox(mirror: Mirroring(x: 1, y: -1, z: 1), yaw: 0.6, pitch: -0.5),
            MirroredBox(mirror: Mirroring(x: 1, y: 1, z: -1), yaw: -0.6, pitch: -0.5),
        ])
    func aMirroredBoxLooksLikeTheEquivalentRotation(_ box: MirroredBox) throws {
        // 捨てる向きが逆だと手前の面が捨てられ、光に背を向けた奥の面だけが写る —
        // 箱が黒い影のように出る (#1446 の起票時で赤の総和が 1 桁違った)
        let mirrored = try litBox(mirror: box.mirror, yaw: 0.6, pitch: 0.5)
        let rotated = try litBox(mirror: nil, yaw: box.yaw, pitch: box.pitch)
        let difference = PictureDifference.between(mirrored, rotated)
        #expect(difference.shapePixels > 2000, "箱が写っていない (\(difference))")
        #expect(difference.fraction <= 0.02, "鏡映した箱が回転の箱と食い違う (\(difference))")
    }

    /// 透けた画素を持つ、貼る絵 (#1564 の起票時の 2 枚)。
    enum SeeThroughPicture: String, CaseIterable, Sendable, CustomTestStringConvertible {
        /// 4×4 の全画素が白・α 0.5。
        case halfTransparent
        /// 8×8 の市松で、半分の画素が α 0 の穴 (残りは白・α 1)。
        case checkerWithHoles
        var testDescription: String { rawValue }

        func make(on canvas: Canvas) throws -> Image {
            switch self {
            case .halfTransparent:
                let image = try canvas.createImage(4, 4)
                let half = LinearRGBA(straightRed: 1, green: 1, blue: 1, alpha: 0.5)
                for y in 0..<4 {
                    for x in 0..<4 { image.set(x, y, half) }
                }
                return image
            case .checkerWithHoles:
                // 作った絵は透明で始まるので、塞ぐ側だけを白で塗る
                let image = try canvas.createImage(8, 8)
                for y in 0..<8 {
                    for x in 0..<8 where (x + y).isMultiple(of: 2) {
                        image.set(x, y, .linear(red: 1, green: 1, blue: 1))
                    }
                }
                return image
            }
        }
    }

    /// #1564 の起票時の絵 (160×160): 黒地に、`picture` を貼った白い `sphere(40)` を
    /// (80, 80, 0) に置く。`turned` なら形の直前に `rotateY(π)` を入れる。
    ///
    /// `afterwards` は形を置いた後、フレームを描き切る前に打つ。
    private func picturedSphere(
        _ picture: SeeThroughPicture, turned: Bool, afterwards: (Canvas) -> Void = { _ in }
    ) throws -> PixelBuffer {
        let canvas = try makeCanvas(width: 160, height: 160)
        let image = try picture.make(on: canvas)
        try canvas.draw {
            canvas.background(.linear(red: 0, green: 0, blue: 0))
            canvas.noStroke()
            canvas.fill(.linear(red: 1, green: 1, blue: 1))
            canvas.texture(image)
            canvas.push()
            canvas.translate(80, 80, 0)
            if turned { canvas.rotateY(Float.pi) }
            canvas.sphere(40)
            canvas.pop()
            afterwards(canvas)
        }
        return try canvas.target.readPixels()
    }

    /// どれかの成分の差が 0.02 を超える画素の数。`ignoring` が真を返す画素は数えない。
    private func differingPixels(
        _ a: PixelBuffer, _ b: PixelBuffer, ignoring: (Int, Int) -> Bool = { _, _ in false }
    ) -> Int {
        var count = 0
        for y in 0..<a.height {
            for x in 0..<a.width where !ignoring(x, y) {
                let (p, q) = (a[x, y], b[x, y])
                let apart =
                    abs(p.red - q.red) > 0.02 || abs(p.green - q.green) > 0.02
                    || abs(p.blue - q.blue) > 0.02 || abs(p.alpha - q.alpha) > 0.02
                if apart { count += 1 }
            }
        }
        return count
    }

    /// α 0.5 の白を 2 層重ねた画素 (黒地の上で 0.75) の数 — 透けた画素から奥の面が見えている所。
    ///
    /// **比べる前にこれが 0 でないことを確かめる。** 見比べる 2 枚がどちらも裏面を捨てて
    /// いれば、奥の面が消えていても一致してしまう。1 層だけなら 0.5 なので、0.7 で分ける。
    private func twoLayerPixels(_ image: PixelBuffer) -> Int {
        var count = 0
        for y in 0..<image.height {
            for x in 0..<image.width where image[x, y].red > 0.7 { count += 1 }
        }
        return count
    }

    @Test(
        "絵を貼った球を置いた直後に noTexture() を呼んでも、透けた画素から奥の面が見える",
        arguments: SeeThroughPicture.allCases, [false, true])
    func removingThePictureKeepsTheFarSideVisible(_ picture: SeeThroughPicture, turned: Bool) throws {
        // 起票時は、呼ぶと裏面を捨てる列になり、透けた画素から見えていた奥の面が消えた
        // (違う画素: α 0.5 で 1734 / 3674、市松の穴で 1714 / 3641)
        let kept = try picturedSphere(picture, turned: turned)
        if picture == .halfTransparent {
            // 市松の絵は 1 層でも白 (1.0) の画素を持つので、層の数では見分けない
            try #require(twoLayerPixels(kept) > 0, "絵を貼ったままの球で、奥の面が見えていない")
        }
        let removed = try picturedSphere(picture, turned: turned) { $0.noTexture() }
        #expect(differingPixels(kept, removed) == 0)
    }

    @Test(
        "noTexture() の後に絵の無い球を置いても、先に置いた球の透けた画素から奥の面が見える",
        arguments: [false, true])
    func placingAnotherShapeAfterRemovingThePicture(turned: Bool) throws {
        // 後の球を置くと貼る面が切り替わり、そこで絵を貼った列が閉じる
        let kept = try picturedSphere(.halfTransparent, turned: turned)
        try #require(twoLayerPixels(kept) > 0, "絵を貼ったままの球で、奥の面が見えていない")
        let removed = try picturedSphere(.halfTransparent, turned: turned) { canvas in
            canvas.noTexture()
            canvas.push()
            canvas.translate(150, 150, 0)
            canvas.sphere(5)
            canvas.pop()
        }
        // 後から置いた小さな球の周りは比べない
        let nearTheSmallSphere = { (x: Int, y: Int) in abs(x - 150) <= 12 && abs(y - 150) <= 12 }
        #expect(differingPixels(kept, removed, ignoring: nearTheSmallSphere) == 0)
    }
}
