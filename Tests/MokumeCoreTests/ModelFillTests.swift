// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation
import Testing

@testable import MokumeCore

/// 読み込んだモデルの塗りの頂点を GPU の置き場に持って使い回す (#1749)。
///
/// 物差しは **置き場を持たない経路** (予算 0 — 1 つで予算の半分を超えるモデルは持たない) で、
/// 以前と同じく頂点を毎フレーム溜め場へ詰めて写す。どの場面でも、2 つの経路の絵が全バイトで
/// 一致することを見る。
@Suite("モデルの塗りの置き場", .enabled(if: RenderDevice.isAvailable, "GPU が無い環境ではスキップ"))
struct ModelFillTests {
    private func makeCanvas() throws -> Canvas {
        try CanvasFixture.make(gpu: RenderDevice(), width: 96, height: 96)
    }

    /// 4 色に塗り分けた絵。貼った位置の取り違えが色で分かる。
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

    /// 頂点を傾けた四角錐。頂点の数は ``ModelFixture/pyramid`` と同じで、形だけが違う。
    private static let leaningPyramid: String = {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("mokume-fill-leaning-pyramid.obj")
        let text = ModelFixture.pyramidText.replacingOccurrences(
            of: "v 0.0 1.6 0.0", with: "v 0.9 1.6 0.9")
        try? text.write(to: url, atomically: true, encoding: .utf8)
        return url.path
    }()

    /// 置き方の場面。
    enum Scene: String, CaseIterable, Sendable {
        /// 光を当てて 2 か所に置く。
        case lit
        /// 書かれた展開で絵を貼る。
        case textured
        /// 鏡映して置く (表の巻き方が変わる)。
        case mirrored
        /// 影を落とし、床で受ける。
        case shadow
        /// 組み込みの立体と交互に置き、途中で画素を読んで描き切る。
        case interleavedWithFlush
        /// フレームごとに視点を動かす。
        case movingCamera
    }

    /// 場面を 3 フレーム回し、フレームごとの絵を返す。`retaining` が偽なら置き場を持たない。
    private func frames(_ scene: Scene, retaining: Bool) throws -> [[UInt8]] {
        let canvas = try makeCanvas()
        if !retaining { canvas.modelFills.budget = 0 }
        let pyramid = try canvas.loadModel(ModelFixture.pyramid)
        let unwrapped = try canvas.loadModel(ModelFixture.unwrapped)
        let picture = try quadrants(canvas)
        var pictures: [[UInt8]] = []
        for frame in 0..<3 {
            try canvas.draw {
                canvas.background(.linear(red: 0.02, green: 0.02, blue: 0.03))
                if scene == .movingCamera {
                    canvas.camera(48 + Float(frame) * 12, 30, 140, 48, 48, 0, 0, 1, 0)
                }
                canvas.lights()
                canvas.noStroke()
                canvas.fill(.linear(red: 0.9, green: 0.7, blue: 0.4))
                if scene == .shadow {
                    canvas.directionalLight(.linear(red: 0.8, green: 0.8, blue: 0.8), -0.6, 0.6, -0.5)
                    canvas.shadows(true)
                    canvas.push()
                    canvas.translate(48, 48, -30)
                    canvas.plane(90, 90)
                    canvas.pop()
                }
                for (index, x) in [Float(28), 68].enumerated() {
                    canvas.push()
                    canvas.translate(x, 48, 0)
                    canvas.rotateY(0.4 + Float(frame) * 0.3)
                    canvas.scale(0.4, 0.4, 0.4)
                    if scene == .mirrored && index == 1 { canvas.scale(-1, 1, 1) }
                    switch scene {
                    case .textured:
                        canvas.texture(picture)
                        canvas.model(unwrapped)
                        canvas.noTexture()
                    default:
                        canvas.model(pyramid)
                    }
                    canvas.pop()
                    if scene == .interleavedWithFlush {
                        canvas.push()
                        canvas.translate(x, 20, 0)
                        canvas.box(10)
                        canvas.pop()
                        // 途中で画素を読むと、そこまでを描き切る
                        if index == 0 { _ = canvas.get(0, 0) }
                    }
                }
            }
            pictures.append(try canvas.target.encodeForDisplay().bytes)
        }
        return pictures
    }

    @Test("置き場を持っても、持たないときと同じ絵になる", arguments: Scene.allCases)
    func retainingDrawsTheSamePicture(_ scene: Scene) throws {
        let reference = try frames(scene, retaining: false)
        let retained = try frames(scene, retaining: true)
        // 物差しに形が写っていること (不透明度の桁は背景で常に 255 なので見ない)
        let drawn = stride(from: 0, to: reference[0].count, by: 4).filter {
            reference[0][$0] > 40 || reference[0][$0 + 1] > 40 || reference[0][$0 + 2] > 40
        }.count
        #expect(drawn > 50, "物差しにモデルが写っていない — 比べる前提が崩れている (\(drawn) 画素)")
        for frame in 0..<3 {
            let differing = stride(from: 0, to: reference[frame].count, by: 4).filter {
                reference[frame][$0..<($0 + 4)] != retained[frame][$0..<($0 + 4)]
            }.count
            #expect(differing == 0, "\(frame) 枚目で \(differing) 画素が違う")
        }
    }

    @Test("毎フレーム置いても、塗りの頂点を詰めるのは 1 度きりで、溜め場へは積まない")
    func packsOnceAndLeavesTheStagingEmpty() throws {
        let canvas = try makeCanvas()
        let model = try canvas.loadModel(ModelFixture.pyramid)
        for _ in 0..<5 {
            try canvas.draw {
                canvas.noStroke()
                for x in [Float(30), 66] {
                    canvas.push()
                    canvas.translate(x, 48, 0)
                    canvas.model(model)
                    canvas.pop()
                }
                #expect(canvas.solidVertices.isEmpty, "モデルの頂点を溜め場へ積んでいる")
            }
            // 同じモデルは 1 本の列にまとまる (置き場所だけが増える)
            #expect(canvas.drawCallsInLastFrame == 1)
        }
        #expect(canvas.modelFills.made == 1)
        #expect(canvas.modelFills.count == 1)
    }

    @Test("何フレーム描いても、常駐する資源の数は増え続けない")
    func residencyStaysFlat() throws {
        let canvas = try makeCanvas()
        let model = try canvas.loadModel(ModelFixture.pyramid)
        func frame() throws {
            try canvas.draw {
                canvas.translate(48, 48, 0)
                canvas.model(model)
            }
        }
        for _ in 0..<4 { try frame() }
        try canvas.gpu.settle()
        let warmed = canvas.gpu.residencySet.allocationCount
        for _ in 0..<12 { try frame() }
        try canvas.gpu.settle()
        #expect(canvas.gpu.residencySet.allocationCount == warmed)
    }

    @Test("影の焼き直しを省く判定は、置き場を持っても持たなくても同じに効く")
    func shadowReuseIsUnchanged() throws {
        func counts(retaining: Bool) throws -> (encoded: Int, reused: Int) {
            let canvas = try makeCanvas()
            if !retaining { canvas.modelFills.budget = 0 }
            let model = try canvas.loadModel(ModelFixture.pyramid)
            for _ in 0..<4 {
                try canvas.draw {
                    canvas.directionalLight(.linear(red: 1, green: 1, blue: 1), -0.6, 0.6, -0.5)
                    canvas.shadows(true)
                    canvas.translate(48, 48, 0)
                    canvas.model(model)
                }
            }
            return (canvas.shadowBakesEncoded, canvas.shadowBakesReused)
        }
        let retained = try counts(retaining: true)
        #expect(retained.encoded == 1, "動かない場面で影を焼き直している")
        #expect(retained.reused == 3)
        let reference = try counts(retaining: false)
        #expect(retained.encoded == reference.encoded)
        #expect(retained.reused == reference.reused)
    }

    @Test("控えから追い出した置き場も、先に積んだ列が読み終わるまで生きる")
    func anEvictedFillStaysReadableForTheOpenFrame() throws {
        var pictures: [[UInt8]] = []
        for retaining in [false, true] {
            let canvas = try makeCanvas()
            let pyramid = try canvas.loadModel(ModelFixture.pyramid)
            let unwrapped = try canvas.loadModel(Self.leaningPyramid)
            // 四角錐はどちらも頂点 18 個 = 1,728 バイト (重さは + 256)。予算をその 2 倍にすると、
            // どちらも「1 つで予算の半分以下」で持たれるが、2 つ目を入れると 1 つ目が外れる
            canvas.modelFills.budget = retaining ? 2 * 18 * MemoryLayout<SolidVertex>.stride : 0
            try canvas.draw {
                canvas.background(.linear(red: 0, green: 0, blue: 0))
                canvas.lights()
                canvas.noStroke()
                canvas.push(); canvas.translate(30, 48, 0); canvas.model(pyramid); canvas.pop()
                canvas.push(); canvas.translate(66, 48, 0); canvas.model(unwrapped); canvas.pop()
                canvas.push(); canvas.translate(48, 20, 0); canvas.model(pyramid); canvas.pop()
            }
            if retaining { #expect(canvas.modelFills.made == 3, "追い出しが起きていない") }
            pictures.append(try canvas.target.encodeForDisplay().bytes)
        }
        #expect(pictures[0] == pictures[1])
    }

    @Test("1 つで予算の半分を超えるモデルは持たず、溜め場で描く")
    func anOversizedModelIsNotRetained() throws {
        let canvas = try makeCanvas()
        let model = try canvas.loadModel(ModelFixture.pyramid)
        // 四角錐の頂点は 18 個 = 1,728 バイト。予算の半分をそれより小さくする
        canvas.modelFills.budget = 1_000
        try canvas.draw {
            canvas.translate(48, 48, 0)
            canvas.model(model)
            #expect(!canvas.solidVertices.isEmpty, "持たないのに溜め場へも積んでいない")
        }
        #expect(canvas.modelFills.made == 0)
    }
}
