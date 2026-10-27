// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation
import MokumeTestSupport
import Testing
import simd

@testable import MokumeCore

/// 同じ直線に載る辺の鎖を持つ網も、GPU で広げる ([#2989](https://github.com/mokume-metal/mokume/issues/2989))。
///
/// 稜線の網に、同じ直線に載る 2 辺が集まる点 (`ridge` の真ん中・平らな格子の周・揃えた格子の変曲線) があると、
/// 視線をその直線に沿わせたとき、潰れた辺が 2 本以上続いて 3 点以上が画面の 1 点に重なる。頂点関数は
/// 潰れた辺を対の相手をたどって何段でも引き、CPU の帯と同じ形を置く。
///
/// 物差しは **骨を持たない経路** (``Canvas/modelStrokeGeometries`` の予算 0 — 線は CPU の帯で組む) で、どの
/// 場面でも 2 つの経路の絵が全バイトで一致することを見る。**視線を直線に沿わせた場面を含む** — 平行投影で
/// 軸に沿って見る・目を直線の上に置く。
@Suite("同じ直線に載る辺の鎖", .enabled(if: RenderDevice.isAvailable, "GPU が無い環境ではスキップ"))
struct StraightChainStrokeTests {
    /// 検体を書く置き場。プロセスごとに 1 つ (他のセッションと分け持つと、後始末が他方の検体を消す・#3298)。
    private static let fixtures = TestScratch.path("mokume-straight-chain-fixtures", isDirectory: true)

    private static func written(_ text: String, as name: String) -> String {
        let url = fixtures.appendingPathComponent(name)
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? text.write(to: url, atomically: true, encoding: .utf8)
        return url.path
    }

    /// 横と縦を揃えた格子 (x・y は −1…1)。高さは `height(x, y)`。
    static func grid(_ cells: Int, height: (Float, Float) -> Float) -> String {
        let step = 2 / Float(cells)
        var lines: [String] = []
        for row in 0...cells {
            for column in 0...cells {
                let (x, y) = (Float(column) * step - 1, Float(row) * step - 1)
                lines.append("v \(x) \(y) \(height(x, y))")
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

    /// 櫛。x 軸に載る点 `p0…p(teeth)` を、辺で順に結び、隣り合う 2 点ごとに 1 枚の三角形 (`p(i)`・`p(i+1)`・歯の先
    /// `q(i)`) を付ける。歯の先は x 軸の周りに `angles[i]` の向きへ伸びる。**x 軸に沿って見ると、軸の点が画面の 1 点に
    /// 重なり、群の腕は歯ごとに違う向きになる。** 群の形を置くのは視線に最も近い軸の端で、両端の向きを持つ歯が
    /// 反対の端にあれば、形は軸を端まで何段もたどらないと決まらない。
    static func comb(angles: [Float]) -> String {
        var lines: [String] = []
        for index in 0...angles.count { lines.append("v \(Float(index) * 0.3 - 0.75) 0 0") }
        for (tooth, angle) in angles.enumerated() {
            lines.append("v \(Float(tooth) * 0.3 - 0.6) \(0.8 * cos(angle)) \(0.8 * sin(angle))")
        }
        for tooth in 0..<angles.count {
            lines.append("f \(tooth + 1) \(tooth + 2) \(angles.count + 2 + tooth)")
        }
        return lines.joined(separator: "\n") + "\n"
    }

    enum Subject: String, CaseIterable, Sendable {
        /// x 軸に載る 3 点を結ぶ稜を持つ閉じた形 (`ModelFixture.ridge`)。
        case ridge
        /// 平らな格子。周だけが稜線で、周の点は一直線に並ぶ。
        case flatGrid
        /// 横と縦を揃え、高さだけ波打たせた格子 (変曲線の近くで、隣り合う 2 辺がほぼ一直線に並ぶ)。
        case waveGrid
        /// 軸の点が 6 つ並び、歯ごとに違う向きの腕を持つ櫛。両端の向き (0 と 2.2 ラジアン) の歯は軸の左の端にある。
        case comb
        /// 同じ櫛の左右を入れ替えたもの (両端の向きの歯が軸の右の端にある)。
        case combMirrored
        /// 平らな 4 枚の三角形が、頂点だけで接する板 (z = 0)。x 軸に載る 3 点 c・P・P2 の端の c は辺が 2 本だけで、
        /// 相手の辺の先 (P・A) はどちらも辺が 3 本以上ある。**同じ半平面に載る腕はどれも画面で同じ向き**
        /// になるので、群の腕は 1 本と数え、端の円板を置く。
        case plate
        /// 三角形 1 枚 P(−0.6, 0, 0)・Q(0.6, 0, 0)・R(0, 0.7, 0.5)。x 軸に沿って見ると P・Q が画面の 1 点に
        /// 重なり、R の 2 辺は画面で同じ向きへ折り返す (#3165)。
        case foldedTriangle

        var path: String {
            switch self {
            case .ridge: ModelFixture.ridge
            case .flatGrid: StraightChainStrokeTests.written(StraightChainStrokeTests.grid(6) { _, _ in 0 }, as: "flat-grid.obj")
            case .waveGrid:
                StraightChainStrokeTests.written(
                    StraightChainStrokeTests.grid(12) { x, y in 0.25 * sin(x * 5.3 + y * 2.1) }, as: "wave-grid.obj")
            case .plate:
                StraightChainStrokeTests.written(
                    """
                    v 0 0 0
                    v 1 0 0
                    v 0 1 0
                    v 2 0 0
                    v 1.5 1 0
                    v -0.5 1.5 0
                    v 0.5 1.5 0
                    v 0.8 1.2 0
                    v 1.2 1.6 0
                    f 1 2 3
                    f 2 4 5
                    f 3 6 7
                    f 2 8 9

                    """, as: "plate.obj")
            case .foldedTriangle:
                StraightChainStrokeTests.written(
                    "v -0.6 0 0\nv 0.6 0 0\nv 0 0.7 0.5\nf 1 2 3\n", as: "folded-triangle.obj")
            case .comb:
                StraightChainStrokeTests.written(
                    StraightChainStrokeTests.comb(angles: [0.0, 2.2, 1.0, 1.1, 1.2]), as: "comb.obj")
            case .combMirrored:
                StraightChainStrokeTests.written(
                    StraightChainStrokeTests.comb(angles: [1.2, 1.1, 1.0, 2.2, 0.0]), as: "comb-mirrored.obj")
            }
        }
    }

    /// 視点。**軸に沿った 4 つは、視線が格子や稜の直線に沿う** (潰れた辺が何本も続く)。
    enum View: String, CaseIterable, Sendable {
        case oblique
        case orthoAlongX
        /// x 軸の負の側から見る (群の形を置く端が、軸の反対の端になる)
        case orthoFromMinusX
        case orthoAlongY
        /// 目を x 軸の上に置いた透視 (x 軸に載る辺だけが潰れる)
        case perspectiveOnXAxis
        case perspectiveOnYAxis

        func apply(_ canvas: Canvas) {
            switch self {
            case .oblique:
                canvas.translate(80, 80, 0)
                canvas.rotateX(0.45)
                canvas.rotateY(0.7)
            case .orthoAlongX:
                canvas.camera(280, 80, 0, 80, 80, 0, 0, 1, 0)
                canvas.ortho()
                canvas.translate(80, 80, 0)
            case .orthoFromMinusX:
                canvas.camera(-120, 80, 0, 80, 80, 0, 0, 1, 0)
                canvas.ortho()
                canvas.translate(80, 80, 0)
            case .orthoAlongY:
                canvas.camera(80, 280, 0, 80, 80, 0, 0, 0, 1)
                canvas.ortho()
                canvas.translate(80, 80, 0)
            case .perspectiveOnXAxis:
                canvas.camera(280, 80, 0, 80, 80, 0, 0, 1, 0)
                canvas.translate(80, 80, 0)
            case .perspectiveOnYAxis:
                canvas.camera(80, 280, 0, 80, 80, 0, 0, 0, 1)
                canvas.translate(80, 80, 0)
            }
            canvas.scale(40, 40, 40)
        }
    }

    private struct Rendered {
        var bytes: [UInt8]
        var strokeBatches: Int
        var drawn: Int
    }

    private func render(
        _ path: String, _ view: View, cap: StrokeCap, weight: Float, accelerated: Bool
    ) throws -> Rendered {
        let canvas = try CanvasFixture.make(gpu: RenderDevice(), width: 160, height: 160)
        if !accelerated { canvas.modelStrokeGeometries.budget = 0 }
        let model = try canvas.loadModel(path, normalize: false)
        var strokeBatches = 0
        try canvas.draw {
            canvas.background(.linear(red: 0.02, green: 0.02, blue: 0.03))
            canvas.noFill()
            canvas.stroke(.linear(red: 1, green: 1, blue: 1))
            canvas.strokeWeight(weight)
            canvas.strokeCap(cap)
            view.apply(canvas)
            canvas.model(model)
            canvas.closeBatch()
            strokeBatches = canvas.batches.count { $0.strokeGeometry != nil }
        }
        let bytes = try canvas.target.encodeForDisplay().bytes
        let drawn = stride(from: 0, to: bytes.count, by: 4).filter { bytes[$0] > 40 }.count
        return Rendered(bytes: bytes, strokeBatches: strokeBatches, drawn: drawn)
    }

    /// 視点と端の形の組。
    nonisolated struct Variant: Sendable, CustomStringConvertible {
        var view: View
        var cap: StrokeCap
        var description: String { "\(view.rawValue)・\(cap)" }

        nonisolated static let all: [Variant] = View.allCases.flatMap { view in
            [StrokeCap.round, .square, .project].map { Variant(view: view, cap: $0) }
        }
    }

    @Test("同じ直線に載る辺の鎖も、骨で広げて CPU の帯と同じ絵になる", arguments: Subject.allCases, Variant.all)
    func matchesTheCPUBands(subject: Subject, variant: Variant) throws {
        let (view, cap) = (variant.view, variant.cap)
        let reference = try render(subject.path, view, cap: cap, weight: 16, accelerated: false)
        let accelerated = try render(subject.path, view, cap: cap, weight: 16, accelerated: true)
        #expect(reference.strokeBatches == 0, "物差しが骨を使っている")
        #expect(accelerated.strokeBatches == 1, "骨を作れていない (CPU の帯へ戻った)")
        #expect(reference.drawn > 30, "線が写っていない (\(reference.drawn) 画素)")
        let differing = stride(from: 0, to: reference.bytes.count, by: 4).filter { offset in
            return reference.bytes[offset..<(offset + 4)] != accelerated.bytes[offset..<(offset + 4)]
        }.count
        #expect(differing == 0, "\(differing) 画素が違う")
    }

    /// #3165: 同じ側へ折り返す 2 辺 (辺 2 本が画面で同じ向きへ折り返す点) の先端の端の形。三角形 P・Q・R を平行投影で
    /// 辺 P–Q に沿って見ると、R の 2 辺は画面で同じ向きに折り返す。CPU の帯は折り返しの先に太さの半分の √2 倍だけ延ばした
    /// 長方形を置くが、GPU の骨は置けず (腕の向きが 1 ビット食い違い、縁が同じ側へ揃った)、端の形 3 種とも 17 画素違った。
    /// 太さは Issue の再現と同じ 5 (`matchesTheCPUBands` は 16)。
    @Test("同じ側へ折り返す 2 辺の先端も、骨で広げて CPU の帯と同じ絵になる", arguments: [StrokeCap.round, .square, .project])
    func aTipFoldingBackMatchesTheCPUBands(cap: StrokeCap) throws {
        let path = Subject.foldedTriangle.path
        let reference = try render(path, .orthoAlongX, cap: cap, weight: 5, accelerated: false)
        let accelerated = try render(path, .orthoAlongX, cap: cap, weight: 5, accelerated: true)
        #expect(reference.strokeBatches == 0, "物差しが骨を使っている")
        #expect(accelerated.strokeBatches == 1, "骨を作れていない (CPU の帯へ戻った)")
        #expect(reference.drawn > 30, "線が写っていない (\(reference.drawn) 画素)")
        let differing = stride(from: 0, to: reference.bytes.count, by: 4).filter {
            reference.bytes[$0..<($0 + 4)] != accelerated.bytes[$0..<($0 + 4)]
        }.count
        #expect(differing == 0, "\(differing) 画素が違う")
    }

    /// 折り返す先端 R の 2 本の腕 (R→P と R→Q) の、CPU が求める向きどうしの関係。
    enum ArmRelation: String, Sendable {
        /// 値が等しい (折り返しの先に長方形を置く)
        case equal
        /// 理屈では等しく、丸めで最終ビットだけ違う (どちら回りかの判定が丸めで決まる)
        case nearlyEqual
        /// はっきり違う
        case apart
    }

    /// 三角形 P・Q・R を描いた絵と、骨を使ったか・CPU が求めた R の 2 本の腕の関係。`placing` が視点と置き方を決める。
    private func foldedTrianglePicture(
        accelerated: Bool, perspective: Bool, weight: Float, placing: (Canvas) -> Void
    ) throws -> (bytes: [UInt8], strokeBatches: Int, relation: ArmRelation?) {
        let canvas = try CanvasFixture.make(gpu: RenderDevice(), width: 160, height: 160)
        if !accelerated { canvas.modelStrokeGeometries.budget = 0 }
        let model = try canvas.loadModel(Subject.foldedTriangle.path, normalize: false)
        var strokeBatches = 0
        var relation: ArmRelation?
        try canvas.draw {
            canvas.background(.linear(red: 0.02, green: 0.02, blue: 0.03))
            canvas.noFill()
            canvas.stroke(.linear(red: 1, green: 1, blue: 1))
            canvas.strokeWeight(weight)
            placing(canvas)
            if !perspective { canvas.ortho() }
            canvas.scale(40, 40, 40)
            canvas.model(model)
            canvas.closeBatch()
            strokeBatches = canvas.batches.count { $0.strokeGeometry != nil }
            // CPU が求める R の 2 本の腕 (形自身の座標の P・Q・R を、置いた後の世界へ移して測る)
            let matrix = canvas.transform.matrix
            func world(_ x: Float, _ y: Float, _ z: Float) -> SIMD3<Float> {
                let moved = matrix * SIMD4(x, y, z, 1)
                return SIMD3(moved.x, moved.y, moved.z)
            }
            let camera = StrokeCamera(canvas.currentCamera, width: 160, height: 160)
            let (p, q, r) = (world(-0.6, 0, 0), world(0.6, 0, 0), world(0, 0.7, 0.5))
            if let toP = camera.screenNormal(r, p), let toQ = camera.screenNormal(r, q) {
                if toP == toQ {
                    relation = .equal
                } else {
                    relation = length(toP - toQ) < 1e-3 ? .nearlyEqual : .apart
                }
            }
        }
        return (try canvas.target.encodeForDisplay().bytes, strokeBatches, relation)
    }

    /// #3165: 折り返す 2 本の向きが**理屈では等しく、丸めで 1 ビットずれうる**配置を掃く。GPU がどの視点でも CPU の帯と
    /// 同じ向きの決定を下す (内積・外積・正規化・位置の丸めが CPU と同じ) ことを、全バイトの一致で見る。
    ///
    /// - 軸に揃えた視点: 視点を浮動小数点の刻み (2^-17) の何倍かだけ辺の直線からずらす (平行投影と透視・縦と奥行き)
    /// - 軸に揃えない視点: 三角形を非整数の角度で回して置き、視点を回した辺の延長に置く。行列の成分も座標も
    ///   2 のべきの分数にならないので、積の 1 つ 1 つが丸められる
    ///
    /// **検査の前提も見る** — どの視点でも骨を使って描いたこと、線が写っていること、そして腕の関係が偏らないこと
    /// (値が等しい・最終ビットだけ違う・はっきり違うの全部が起きている)。
    @Test("折り返す 2 本の向きが丸めでずれうる視点でも、骨で広げて CPU の帯と同じ絵になる")
    func nearlyFoldedTipsMatchTheCPUBands() throws {
        var differing: [String] = []
        var relations: [ArmRelation: Int] = [:]
        var checked = 0
        func compare(
            _ name: String, perspective: Bool, tolerating tolerance: Int = 0,
            placing: @escaping (Canvas) -> Void
        ) throws {
            let reference = try foldedTrianglePicture(
                accelerated: false, perspective: perspective, weight: 12, placing: placing)
            let accelerated = try foldedTrianglePicture(
                accelerated: true, perspective: perspective, weight: 12, placing: placing)
            checked += 1
            #expect(reference.strokeBatches == 0, "\(name): 物差しが骨を使っている")
            #expect(accelerated.strokeBatches == 1, "\(name): 骨を作れていない (CPU の帯へ戻った)")
            let drawn = stride(from: 0, to: reference.bytes.count, by: 4).filter { reference.bytes[$0] > 40 }.count
            #expect(drawn > 100, "\(name): 線が写っていない (\(drawn) 画素)")
            if let relation = reference.relation { relations[relation, default: 0] += 1 }
            let pixels = stride(from: 0, to: reference.bytes.count, by: 4).filter {
                reference.bytes[$0..<($0 + 4)] != accelerated.bytes[$0..<($0 + 4)]
            }.count
            if pixels > tolerance { differing.append("\(name) (\(pixels) 画素)") }
        }
        for perspective in [false, true] {
            for axis in 0..<2 {
                for step in 0..<40 {
                    let offset = Float(step) * 7.62939453125e-6
                    try compare("\(perspective ? "透視" : "平行")・軸 \(axis)・ずれ \(offset)", perspective: perspective) {
                        canvas in
                        if axis == 0 {
                            canvas.camera(280, 80 + offset, 0, 80, 80, 0, 0, 1, 0)
                        } else {
                            canvas.camera(280, 80, offset, 80, 80, 0, 0, 1, 0)
                        }
                        canvas.translate(80, 80, 0)
                    }
                }
            }
        }
        // 辺の延長から離れた視点 (折り返さず、P–Q は潰れない)。腕の向きがはっきり違う場合も混ぜる
        for perspective in [false, true] {
            for step in 1...6 {
                let offset = Float(step) * 3.7
                try compare("\(perspective ? "透視" : "平行")・離れた視点 \(offset)", perspective: perspective) { canvas in
                    canvas.camera(280, 80 + offset, 0, 80, 80, 0, 0, 1, 0)
                    canvas.translate(80, 80, 0)
                }
            }
        }
        for perspective in [false, true] {
            for step in 0..<48 {
                let yaw = 0.1 + Float(step) * 0.137
                let roll = 0.3 + Float(step) * 0.071
                // 回した置き方では、帯の頂点の位置が CPU と 1 ulp 違い、辺の画素が 1 つ入れ替わることがある
                // (向きの決定の食い違いは太さ 12 で 100 画素を超える)。許すのは 4 画素まで
                try compare(
                    "\(perspective ? "透視" : "平行")・回した辺・角 \(yaw)", perspective: perspective, tolerating: 4
                ) { canvas in
                    // 辺 P–Q (形の x 軸) は回した後 (cos yaw, 0, −sin yaw)。視点はその延長の上に置く
                    let direction = SIMD3<Float>(RuntimeMath.cos(yaw), 0, -RuntimeMath.sin(yaw)) * 200
                    canvas.camera(80 + direction.x, 80, direction.z, 80, 80, 0, 0, 1, 0)
                    canvas.translate(80, 80, 0)
                    canvas.rotateY(yaw)
                    canvas.rotateX(roll)
                }
            }
        }
        #expect(differing.isEmpty, "CPU の帯と違う視点 (\(differing.count) / \(checked)): \(differing.prefix(8))")
        // 偏りが無いこと: 腕の関係が 3 つとも、掃いた視点の中に何度か起きている
        for relation in [ArmRelation.equal, .nearlyEqual, .apart] {
            #expect((relations[relation] ?? 0) >= 4, "腕の関係 \(relation.rawValue) が足りない: \(relations)")
        }
    }

    /// 完了条件 1: 100,352 三角形の、横と縦を揃えた格子も骨を作る (点が数万を超えると、変曲線の近くの辺が
    /// 偶然に同じ直線へ並ぶ)。
    @Test("横と縦を揃えた大きな格子も、骨を作って GPU で広げる")
    func aLargeAlignedGridMakesABone() throws {
        let path = Self.written(
            Self.grid(224) { x, y in 0.25 * sin(x * 5.3 + y * 2.1) }, as: "wave-grid-224.obj")
        let canvas = try CanvasFixture.make(gpu: RenderDevice(), width: 160, height: 160)
        let model = try canvas.loadModel(path, normalize: false)
        var strokeBatches = 0
        try canvas.draw {
            canvas.background(.linear(red: 0, green: 0, blue: 0))
            canvas.noFill()
            canvas.stroke(.linear(red: 1, green: 1, blue: 1))
            View.oblique.apply(canvas)
            canvas.model(model)
            canvas.closeBatch()
            strokeBatches = canvas.batches.count { $0.strokeGeometry != nil }
        }
        #expect(strokeBatches == 1, "骨を作れていない (CPU の帯へ戻った)")
    }
}
