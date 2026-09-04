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
        let gpu = try RenderDevice()
        let target = try RenderTarget(gpu: gpu, width: width, height: height)
        return try Canvas(target: target, gpu: gpu)
    }

    /// 1 フレームの中で置いたものを列に閉じ、その列の捨て方を返す。
    private func cullModes(_ body: (Canvas) throws -> Void) throws -> [MTLCullMode] {
        let canvas = try makeCanvas()
        var modes: [MTLCullMode] = []
        try canvas.draw {
            canvas.noStroke()
            try? body(canvas)
            canvas.closeBatch()
            modes = canvas.batches.filter { $0.source == .solid }.map(\.cullMode)
        }
        return modes
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
}
