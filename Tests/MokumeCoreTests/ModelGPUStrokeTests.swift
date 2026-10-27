// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation
import MokumeTestSupport
import Testing
import simd

@testable import MokumeCore

/// 読み込んだモデルの稜線を GPU で広げる (#2907)。
///
/// 物差しは **骨を持たない経路** (``Canvas/modelStrokeGeometries`` の予算 0 — 骨は作らず、線は CPU の帯で
/// 組む。以前のモデルの経路と同じ) で、どの場面でも 2 つの経路の絵が全バイトで一致することを見る。
@Suite("モデルの稜線の骨", .enabled(if: RenderDevice.isAvailable, "GPU が無い環境ではスキップ"))
struct ModelGPUStrokeTests {
    /// 検査に使うモデルを書いた場所。**内容から名前を決める**ので、並行する検査が同じ場所へ同じ中身を書く (場所はプロセスごと)。
    private static let directory = TestScratch.path("mokume-model-stroke-fixtures", isDirectory: true)

    private static func written(_ text: String, as name: String) -> String {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(name)
        try? text.write(to: url, atomically: true, encoding: .utf8)
        return url.path
    }

    /// 波打つ格子 (開いた端を持つ板)。**どの辺も折れている** — 高さに格子ごとの揺らぎを足してあるので、
    /// 隣り合う 2 枚が同じ平面に載らず、全部の辺が稜線になる。**点の位置 (横と縦) も決まった揺らぎで
    /// ずらす** — 揃った格子は同じ直線に載る 2 辺を偶然に持ちやすい (点が 5 万を超えると、ほぼ必ず持つ)。
    /// 骨は鎖も引ける (#2989・`StraightChainStrokeTests`) ので、揃った格子も骨を作るが、ここでは揺らした格子で
    /// 鎖の無い網の経路を見る。
    static func wavyGrid(_ cells: Int) -> String {
        // 決まった乱数 (線形合同法)。検査が実行ごとに違う網を作らない
        var state: UInt32 = 0x1234_5678
        func jitter() -> Float {
            state = state &* 1_664_525 &+ 1_013_904_223
            return Float(state >> 8) / Float(1 << 24) - 0.5
        }
        let step = 2 / Float(cells)
        var lines: [String] = []
        for row in 0...cells {
            for column in 0...cells {
                let x = Float(column) * step - 1 + jitter() * step * 0.6
                let y = Float(row) * step - 1 + jitter() * step * 0.6
                let z = 0.25 * sin(x * 5.3 + y * 2.1) + 0.08 * jitter()
                lines.append("v \(x) \(y) \(z)")
            }
        }
        let stride = cells + 1
        for row in 0..<cells {
            for column in 0..<cells {
                let a = row * stride + column + 1
                let (b, c, d) = (a + 1, a + stride, a + stride + 1)
                lines.append("f \(a) \(b) \(d)")
                lines.append("f \(a) \(d) \(c)")
            }
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// 緯度経度の球 (閉じたモデル)。極は 1 点に潰れず、小さな多角形で閉じる。
    static func sphere(rings: Int, segments: Int) -> String {
        var lines: [String] = ["v 0 1 0"]
        for ring in 1..<rings {
            let polar = Float.pi * Float(ring) / Float(rings)
            for segment in 0..<segments {
                let azimuth = 2 * Float.pi * Float(segment) / Float(segments)
                lines.append("v \(sin(polar) * cos(azimuth)) \(cos(polar)) \(sin(polar) * sin(azimuth))")
            }
        }
        lines.append("v 0 -1 0")
        let last = lines.count
        func index(_ ring: Int, _ segment: Int) -> Int { 2 + (ring - 1) * segments + segment % segments }
        for segment in 0..<segments {
            lines.append("f 1 \(index(1, segment + 1)) \(index(1, segment))")
        }
        for ring in 1..<(rings - 1) {
            for segment in 0..<segments {
                let (a, b) = (index(ring, segment), index(ring, segment + 1))
                let (c, d) = (index(ring + 1, segment), index(ring + 1, segment + 1))
                lines.append("f \(a) \(b) \(d)")
                lines.append("f \(a) \(d) \(c)")
            }
        }
        for segment in 0..<segments {
            lines.append("f \(last) \(index(rings - 1, segment)) \(index(rings - 1, segment + 1))")
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// 検査のモデル。
    enum Subject: String, CaseIterable, Sendable {
        /// 閉じた四角錐。底は同じ平面の 2 枚。
        case pyramid
        /// 閉じた球。
        case sphere
        /// 開いた端を持つ板 (全部の辺が折れている)。
        case wavySheet
        /// 向きを書いた角と書かない角が混ざる (#2342)。三角形が 2 枚、離れて置いてある。
        case mixedNormals

        var path: String {
            switch self {
            case .pyramid: ModelFixture.pyramid
            case .sphere: ModelGPUStrokeTests.written(ModelGPUStrokeTests.sphere(rings: 9, segments: 14), as: "sphere.obj")
            case .wavySheet: ModelGPUStrokeTests.written(ModelGPUStrokeTests.wavyGrid(7), as: "wavy-sheet.obj")
            case .mixedNormals:
                ModelGPUStrokeTests.written(
                    ModelTests.mixedNormalsVertices + "\nf 4//1 5//1 6//1\nf 1//2 2 3\n", as: "mixed-normals.obj")
            }
        }
    }

    /// 置き方。
    enum Placement: String, CaseIterable, Sendable {
        /// 整えた (最長の辺を面の半分に合わせる) モデルを回して置く。
        case normalized
        /// 整えずに、元の寸法を拡大して置く。
        case raw
        /// x を鏡映して置く (表の巻き方が変わる)。
        case mirrored
        /// 軸ごとに違う倍率で置く。
        case nonUniform
    }

    private struct Rendered {
        var bytes: [UInt8]
        var strokeBatches: Int
        var drawn: Int
    }

    /// 場面を 3 フレーム描く。`accelerated` が偽なら骨を持たない (予算 0)。
    private func render(_ subject: Subject, _ placement: Placement, accelerated: Bool) throws -> [Rendered] {
        let canvas = try CanvasFixture.make(gpu: RenderDevice(), width: 200, height: 200)
        if !accelerated { canvas.modelStrokeGeometries.budget = 0 }
        let model = try canvas.loadModel(subject.path, normalize: placement != .raw)
        var frames: [Rendered] = []
        for frame in 0..<3 {
            var strokeBatches = 0
            try canvas.draw {
                canvas.background(.linear(red: 0.02, green: 0.02, blue: 0.03))
                canvas.lights()
                canvas.fill(.linear(red: 0.9, green: 0.6, blue: 0.3))
                canvas.stroke(.linear(red: 1, green: 1, blue: 1))
                canvas.strokeWeight(2)
                canvas.translate(100, 100, 0)
                canvas.rotateX(0.45 + Float(frame) * 0.2)
                canvas.rotateY(0.7)
                let size: Float = placement == .raw ? 60 : 0.8
                switch placement {
                case .mirrored: canvas.scale(-size, size, size)
                case .nonUniform: canvas.scale(size * 1.3, size * 0.8, size * 1.1)
                default: canvas.scale(size, size, size)
                }
                canvas.model(model)
                canvas.closeBatch()
                strokeBatches = canvas.batches.count { $0.strokeGeometry != nil }
            }
            let bytes = try canvas.target.encodeForDisplay().bytes
            let drawn = stride(from: 0, to: bytes.count, by: 4).filter {
                bytes[$0] > 40 || bytes[$0 + 1] > 40 || bytes[$0 + 2] > 40
            }.count
            frames.append(Rendered(bytes: bytes, strokeBatches: strokeBatches, drawn: drawn))
        }
        return frames
    }

    @Test(
        "骨で広げても、CPU の帯で組んだときと同じ絵になる", arguments: Subject.allCases, Placement.allCases)
    func matchesTheCPUBands(subject: Subject, placement: Placement) throws {
        let reference = try render(subject, placement, accelerated: false)
        let accelerated = try render(subject, placement, accelerated: true)
        #expect(reference.allSatisfy { $0.strokeBatches == 0 }, "物差しが骨を使っている")
        #expect(
            accelerated.allSatisfy { $0.strokeBatches == 1 },
            "骨を使っていない: \(accelerated.map(\.strokeBatches))")
        #expect(reference[0].drawn > 200, "物差しにモデルが写っていない (\(reference[0].drawn) 画素)")
        for frame in 0..<3 {
            let differing = stride(from: 0, to: reference[frame].bytes.count, by: 4).filter {
                reference[frame].bytes[$0..<($0 + 4)] != accelerated[frame].bytes[$0..<($0 + 4)]
            }.count
            #expect(differing == 0, "\(frame) 枚目で \(differing) 画素が違う")
        }
    }

    /// 同じ側へ折り返す 2 辺が集まる網は骨を作らず、CPU の帯へ戻る (``SolidStrokeGeometry/init(net:gpu:byteLimit:)``)。
    /// **戻ったことを控える** — 骨の作りかけを毎フレーム繰り返さない。
    @Test("骨を作れないモデルは CPU の帯へ戻り、同じ絵を保ち、作りかけを繰り返さない")
    func refusedModelsStayOnTheCPU() throws {
        // 三角形 (P, R, X) の長い辺 P–R の途中に点 Q が載り、別の三角形 (P, Q, Y) の辺 P–Q が重なる (T 字の継ぎ目)
        let path = Self.written(
            "v 0 0 0\nv 1 0 0\nv 2 0 0\nv 0.5 1 0\nv 1 -1 0\nf 1 3 4\nf 1 2 5\n", as: "folded-straight.obj")
        let canvas = try CanvasFixture.make(gpu: RenderDevice(), width: 120, height: 120)
        let model = try canvas.loadModel(path, normalize: false)
        var pictures: [[UInt8]] = []
        for _ in 0..<3 {
            try canvas.draw {
                canvas.background(.linear(red: 0, green: 0, blue: 0))
                canvas.stroke(.linear(red: 1, green: 1, blue: 1))
                canvas.strokeWeight(2)
                canvas.translate(40, 60, 0)
                canvas.rotateY(0.5)
                canvas.scale(25, 25, 25)
                canvas.model(model)
                canvas.closeBatch()
                #expect(canvas.batches.allSatisfy { $0.strokeGeometry == nil })
            }
            pictures.append(try canvas.target.encodeForDisplay().bytes)
        }
        // 控えたのは 1 度きり (戻った記録)。骨は 1 つも持たない
        #expect(canvas.modelStrokeGeometries.made == 1)
        #expect(canvas.modelStrokeGeometries.total < 1024)
        #expect(pictures[0] == pictures[1] && pictures[1] == pictures[2])
        #expect(pictures[0].contains { $0 > 100 }, "線が写っていない")
    }

    /// 骨の大きさが予算の半分を超えるモデルは骨を持たない (塗りの置き場と同じ・#1749)。境目を挟んで見る。
    @Test("骨が予算の半分を超えるモデルだけが、CPU の帯へ戻る")
    func budgetHalfIsTheBoundary() throws {
        func bone(budget: Int?) throws -> (strokeBatches: Int, boneBytes: Int) {
            let canvas = try CanvasFixture.make(gpu: RenderDevice(), width: 120, height: 120)
            if let budget { canvas.modelStrokeGeometries.budget = budget }
            let model = try canvas.loadModel(Subject.sphere.path)
            var batches = 0
            try canvas.draw {
                canvas.noFill()
                canvas.stroke(.linear(red: 1, green: 1, blue: 1))
                canvas.translate(60, 60, 0)
                canvas.model(model)
                canvas.closeBatch()
                batches = canvas.batches.count { $0.strokeGeometry != nil }
            }
            return (batches, canvas.modelStrokeGeometries.total - 256)
        }
        let (baseline, bytes) = try bone(budget: nil)
        #expect(baseline == 1)
        #expect(bytes > 0)
        // 半分ちょうどは持つ。1 バイト足りなければ持たない
        #expect(try bone(budget: bytes * 2).strokeBatches == 1)
        #expect(try bone(budget: bytes * 2 - 2).strokeBatches == 0)
        #expect(try bone(budget: 0).strokeBatches == 0)
    }

    /// 半透明の線・既定以外の折れ目・利用者の断片・貼る絵のある線は、モデルでも従来の経路を通る (#1738 の範囲)。
    enum Fallback: String, CaseIterable, Sendable {
        case translucent, roundJoin, shader, picture, additive
    }

    @Test("モデルでも、骨で組めない線は CPU の帯のまま引く", arguments: Fallback.allCases)
    func otherStylesStayOnTheCPUBands(_ fallback: Fallback) throws {
        let canvas = try CanvasFixture.make(gpu: RenderDevice(), width: 100, height: 100)
        let model = try canvas.loadModel(ModelFixture.pyramid)
        let shader = try canvas.makeShader("float4 paint(Fragment in, Values values) { return in.color; }")
        let picture = try canvas.createImage(4, 4)
        try canvas.draw {
            canvas.noFill()
            switch fallback {
            case .translucent: canvas.stroke(.init(straightRed: 1, green: 0, blue: 0, alpha: 0.5))
            case .roundJoin:
                canvas.stroke(.linear(red: 1, green: 0, blue: 0))
                canvas.strokeJoin(.round)
            case .shader:
                canvas.stroke(.linear(red: 1, green: 0, blue: 0))
                canvas.shader(shader)
            case .picture:
                canvas.stroke(.linear(red: 1, green: 0, blue: 0))
                canvas.texture(picture)
            case .additive:
                canvas.stroke(.linear(red: 1, green: 0, blue: 0))
                canvas.blendMode(.add)
            }
            canvas.translate(50, 50, 0)
            canvas.scale(0.4, 0.4, 0.4)
            canvas.model(model)
            canvas.closeBatch()
            #expect(canvas.batches.allSatisfy { $0.strokeGeometry == nil })
        }
        #expect(canvas.modelStrokeGeometries.made == 0)
    }

    @Test("控えから追い出された骨も、先の列が読み終えるまで生きる")
    func evictedBoneStaysReadable() throws {
        let text = Self.sphere(rings: 9, segments: 14)
        let paths = (0..<3).map { Self.written(text, as: "sphere-copy-\($0).obj") }
        // 骨 1 つの大きさ。予算をその 2 倍にすると、1 つずつは持てて (半分以内)、3 つ目で 1 つ目が出る
        let probe = try CanvasFixture.make(gpu: RenderDevice(), width: 120, height: 120)
        let probed = try probe.loadModel(paths[0])
        try probe.draw {
            probe.noFill()
            probe.model(probed)
        }
        let bone = probe.modelStrokeGeometries.total - 256
        #expect(bone > 0)
        let canvas = try CanvasFixture.make(gpu: RenderDevice(), width: 120, height: 120)
        canvas.modelStrokeGeometries.budget = bone * 2 + 512
        let models = try paths.map { try canvas.loadModel($0) }
        try canvas.draw {
            canvas.background(.linear(red: 0, green: 0, blue: 0))
            canvas.noFill()
            canvas.stroke(.linear(red: 1, green: 1, blue: 1))
            canvas.translate(60, 60, 0)
            canvas.scale(0.4, 0.4, 0.4)
            for model in models { canvas.model(model) }
            canvas.closeBatch()
            #expect(canvas.batches.count { $0.strokeGeometry != nil } == 3)
        }
        #expect(canvas.modelStrokeGeometries.count == 2, "1 つ目が追い出されていない")
        #expect(try canvas.target.encodeForDisplay().bytes.contains { $0 > 100 })
    }
}
