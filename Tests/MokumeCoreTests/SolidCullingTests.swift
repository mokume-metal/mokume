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
        // 作っておいた視点 (`setCamera`) は投影の値を検めずに通るので、横 ÷ 縦の比が負の
        // 透視も届く。判定は実際に使う行列から出す
        #expect(
            try frontFacing { canvas in
                var camera = canvas.currentCamera
                camera.projection = .perspective(
                    fieldOfView: Float.pi / 3, aspect: -1, near: 5, far: 600)
                canvas.setCamera(camera)
            } == [.counterClockwise])
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
}
