// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation
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
    private static func written(_ text: String, as name: String) -> String {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("mokume-straight-chain-fixtures", isDirectory: true)
            .appendingPathComponent(name)
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

    /// #3165: 折り返す 2 本の向きが**理屈では等しく、丸めで 1 ビットずれうる**配置。視点の位置を、浮動小数点の
    /// 刻み (2^-17) の何倍かだけ辺の直線からずらすと、2 本の腕の向きは等しい・ほんの少し違う・食い違うを行き来する。
    /// GPU がどの場合も CPU の帯と同じ向きの決定を下す (内積・外積・正規化の丸めが CPU と同じ) ことを、平行投影と
    /// 透視、ずらす軸 (縦・奥行き) の全部で見る。一つでも食い違う視点があれば、食い違った視点を名指しする。
    @Test("折り返す 2 本の向きが丸めでずれうる視点でも、骨で広げて CPU の帯と同じ絵になる")
    func nearlyFoldedTipsMatchTheCPUBands() throws {
        let path = Subject.foldedTriangle.path
        var differing: [String] = []
        for perspective in [false, true] {
            for axis in 0..<2 {
                for step in 0..<40 {
                    let offset = Float(step) * 7.62939453125e-6
                    func picture(accelerated: Bool) throws -> [UInt8] {
                        let canvas = try CanvasFixture.make(gpu: RenderDevice(), width: 160, height: 160)
                        if !accelerated { canvas.modelStrokeGeometries.budget = 0 }
                        let model = try canvas.loadModel(path, normalize: false)
                        try canvas.draw {
                            canvas.background(.linear(red: 0.02, green: 0.02, blue: 0.03))
                            canvas.noFill()
                            canvas.stroke(.linear(red: 1, green: 1, blue: 1))
                            canvas.strokeWeight(12)
                            if axis == 0 {
                                canvas.camera(280, 80 + offset, 0, 80, 80, 0, 0, 1, 0)
                            } else {
                                canvas.camera(280, 80, offset, 80, 80, 0, 0, 1, 0)
                            }
                            if !perspective { canvas.ortho() }
                            canvas.translate(80, 80, 0)
                            canvas.scale(40, 40, 40)
                            canvas.model(model)
                            canvas.closeBatch()
                        }
                        return try canvas.target.encodeForDisplay().bytes
                    }
                    if try picture(accelerated: false) != picture(accelerated: true) {
                        differing.append("\(perspective ? "透視" : "平行")・軸 \(axis)・ずれ \(offset)")
                    }
                }
            }
        }
        #expect(differing.isEmpty, "CPU の帯と違う視点: \(differing)")
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
