// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation
import Testing
import simd

@testable import MokumeCore

/// `scale` で拡大した線の丸い端・丸い折れ目と、`shader()` を付けた円・弧の周は、拡大しない
/// 同じ形と同じ絵になる ([#1645])。GPU を要する。
///
/// **多角形と真円の隔たりは、画面の上で 0.25 画素以内に収まる** (`Canvas.segmentCount(forRadius:)`)。
/// 分割数を形自身の座標の半径で決めていた頃は、拡大すると保証が外れた — `scale(20)` の下の太さ 1 の
/// 折れ線は、丸い端の円板 (半径 0.5) が 3 分割の三角形になり、画面では半径 10 の三角形が出ていた。
///
/// 期待値は、**座標・寸法・太さを拡大率倍にして `scale` を掛けずに描いた同じ形**である
/// ([ADR-0039] 決定 1・[ADR-0019] 決定 4)。画面の半径が同じなら分割数も同じになるので、画素は
/// 1 つも違わない。縁は 50% の被覆 (赤 ≥ 0.5) で白黒にして比べる。
///
/// [#1645]: https://github.com/mokume-metal/mokume/issues/1645
/// [ADR-0019]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0019-drawing-verification.md
/// [ADR-0039]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0039-pixel-grid-and-edge-antialiasing.md
@Suite(
    "拡大した円板の分割数",
    .enabled(
        if: RenderDevice.isAvailable,
        "この世代のコマンド構造に対応した GPU が無い実行環境ではスキップする")
)
struct ScaledDiscTests {
    private static let size = 160

    /// 塗られた画素。縁を 50% の被覆で白黒にする。
    private struct Coverage {
        var inked: [Bool]

        subscript(x: Int, y: Int) -> Bool { inked[y * ScaledDiscTests.size + x] }

        /// 違う画素の数。
        func differing(from other: Coverage) -> Int {
            zip(inked, other.inked).filter { $0 != $1 }.count
        }

        /// 違う画素のうち `region` に入るものの数。
        func differing(from other: Coverage, where region: (Int, Int) -> Bool) -> Int {
            var count = 0
            for y in 0..<ScaledDiscTests.size {
                for x in 0..<ScaledDiscTests.size
                where region(x, y) && self[x, y] != other[x, y] {
                    count += 1
                }
            }
            return count
        }

        var count: Int { inked.filter { $0 }.count }
    }

    /// 160×160 の黒地に描く。**線の色は白** (`stroke(255)`・塗りは `body` が決める)。
    private func render(_ body: (Canvas) -> Void) throws -> Coverage {
        let size = Self.size
        let canvas = try CanvasFixture.make(gpu: RenderDevice(), width: size, height: size)
        try canvas.draw {
            canvas.background(0)
            canvas.noFill()
            canvas.stroke(255)
            body(canvas)
        }
        let pixels = try canvas.target.readPixels()
        var inked: [Bool] = []
        inked.reserveCapacity(size * size)
        for index in 0..<(size * size) { inked.append(Float(pixels.components[index * 4]) >= 0.5) }
        return Coverage(inked: inked)
    }

    /// 160×160 の黒地に描いて、赤・緑・青を別々に 50% で白黒にする。塗りと線を別の色で描いて、
    /// 重ね順まで比べるときに使う。
    private func renderChannels(_ body: (Canvas) -> Void) throws -> [Coverage] {
        let size = Self.size
        let canvas = try CanvasFixture.make(gpu: RenderDevice(), width: size, height: size)
        try canvas.draw {
            canvas.background(0)
            canvas.noFill()
            canvas.stroke(255)
            body(canvas)
        }
        let pixels = try canvas.target.readPixels()
        return (0..<3).map { channel in
            Coverage(
                inked: (0..<(size * size)).map { Float(pixels.components[$0 * 4 + channel]) >= 0.5 })
        }
    }

    /// 160×160 の黒地に描いた赤の値そのもの (線の濃さまで比べるとき)。
    private func renderRed(_ body: (Canvas) -> Void) throws -> [Float] {
        let size = Self.size
        let canvas = try CanvasFixture.make(gpu: RenderDevice(), width: size, height: size)
        try canvas.draw {
            canvas.background(0)
            canvas.noFill()
            canvas.stroke(255)
            body(canvas)
        }
        let pixels = try canvas.target.readPixels()
        return (0..<(size * size)).map { Float(pixels.components[$0 * 4]) }
    }

    /// 断片は頂点の色をそのまま返す。付けると、基本図形も三角形の経路へ落ちる。**断片を作れなければ
    /// 何も付けない** — 比べる前に `reference.count > 0` で何か出ていることを確かめるので、
    /// 空振りはそこで捕まる (基本図形が距離関数の経路で描かれても、期待値の側が違う絵になる)。
    private func shade(_ canvas: Canvas) {
        guard
            let shader = try? canvas.makeShader(
                "float4 paint(Fragment in, Values values) { return in.color; }")
        else { return }
        canvas.shader(shader)
    }

    private func polyline(_ canvas: Canvas, _ points: [SIMD2<Float>]) {
        canvas.beginShape()
        for point in points { canvas.vertex(point.x, point.y) }
        canvas.endShape()
    }

    /// 周を見る 2 つの絵。**塗りと線は別々に比べる** — 重ねると、どちらの分割が違っても
    /// 同じ円盤に見える。
    nonisolated enum Part: String, CaseIterable, CustomTestStringConvertible, Sendable {
        case fill
        case stroke

        var testDescription: String { self == .fill ? "塗り" : "線" }

        @MainActor func apply(_ canvas: Canvas, weight: Float) {
            switch self {
            case .fill:
                canvas.noStroke()
                canvas.fill(255)
            case .stroke:
                canvas.noFill()
                canvas.stroke(255)
                canvas.strokeWeight(weight)
            }
        }
    }

    // MARK: - 条件 1: 丸い端

    /// 起票時の再現 ([#1645])。端の円は中心 (40.5, 40.5)・半径 10 (線の中心は画素の中心に乗る)。
    ///
    /// **画素 (33, 33) は、この検査の物差しにならない。** 中心から 9.9 にあり、`line()` の真円は
    /// 縁で 60% の被覆を出すが、0.25 画素の保証で刻んだ 20 角形 (辺の中央までの距離 9.88) は
    /// 拡大しない折れ線でも塗らない。拡大した折れ線が三角形になっていると、もっと内側の画素まで
    /// 落ちる。そこで、拡大しない同じ折れ線との**一致**を見る。
    @Test("拡大した折れ線の丸い端は、拡大しない同じ折れ線と同じ絵になる")
    func scaledRoundCapMatchesUnscaled() throws {
        let scaled = try render { canvas in
            canvas.scale(20, 20)
            canvas.strokeWeight(1)
            polyline(canvas, [SIMD2(2, 2), SIMD2(6, 2)])
        }
        let reference = try render { canvas in
            canvas.strokeWeight(20)
            polyline(canvas, [SIMD2(40, 40), SIMD2(120, 40)])
        }
        #expect(reference.count > 0)
        #expect(scaled[34, 34], "端の円の内側 (中心から 8.5) が塗られていない")
        #expect(scaled.differing(from: reference) == 0)
    }

    /// 距離関数の経路 (`line`) の丸い端と比べる (x < 40 と x ≥ 120 の両端だけを数える)。
    ///
    /// **起票時の「拡大しない折れ線と `line` の違い 8 画素以下」には、直した後もならない。**
    /// 実測 (Apple M3 Max) は次のとおりで、本文の 8 は違いの一部である:
    ///
    /// - 拡大しない折れ線と拡大しない `line` の両端の違い: **8** (起票時にも 8。0.25 画素の保証で
    ///   刻んだ 20 角形と、`line` の真円の違い)
    /// - 拡大した `line` と拡大しない `line` の両端の違い: **11** ((30, 40)・(130, 40) など、縁の被覆が
    ///   50% に近い画素)。**折れ線を含まない、`line` どうしの違い**で、`line` は距離関数の経路なので、
    ///   拡大するだけで縁の画素の丸めが揺れる (折れ線は拡大しても拡大しない折れ線と 0 画素しか違わない
    ///   — `scaledRoundCapMatchesUnscaled`)
    /// - 拡大した折れ線と拡大した `line` の両端の違い: **19 = 8 + 11** (直す前は 116)
    ///
    /// 検査はこの 3 つの実測の値で締める。折れ線の側が崩れれば 19 を越える。
    @Test("拡大した折れ線の両端は、`line()` との違いが実測の 8 + 11 を越えない")
    func scaledRoundCapStaysAsCloseToLineAsUnscaled() throws {
        let ends: (Int, Int) -> Bool = { x, _ in x < 40 || x >= 120 }
        let scaledPolyline = try render { canvas in
            canvas.scale(20, 20)
            canvas.strokeWeight(1)
            polyline(canvas, [SIMD2(2, 2), SIMD2(6, 2)])
        }
        let scaledLine = try render { canvas in
            canvas.scale(20, 20)
            canvas.strokeWeight(1)
            canvas.line(2, 2, 6, 2)
        }
        let plainPolyline = try render { canvas in
            canvas.strokeWeight(20)
            polyline(canvas, [SIMD2(40, 40), SIMD2(120, 40)])
        }
        let plainLine = try render { canvas in
            canvas.strokeWeight(20)
            canvas.line(40, 40, 120, 40)
        }
        let polygonVersusCircle = plainPolyline.differing(from: plainLine, where: ends)
        let lineJitter = scaledLine.differing(from: plainLine, where: ends)
        let measured = scaledPolyline.differing(from: scaledLine, where: ends)
        #expect(polygonVersusCircle <= 8, "拡大しない折れ線と `line` の両端の違い: \(polygonVersusCircle)")
        #expect(lineJitter <= 11, "拡大した `line` と拡大しない `line` の両端の違い: \(lineJitter)")
        #expect(measured <= 8 + 11, "拡大した折れ線と拡大した `line` の両端の違い: \(measured)")
    }

    // MARK: - 条件 2: 丸い折れ目

    @Test("拡大した折れ線の丸い折れ目は、拡大しない同じ折れ線と同じ絵になる")
    func scaledRoundJoinMatchesUnscaled() throws {
        let scaled = try render { canvas in
            canvas.scale(20, 20)
            canvas.strokeWeight(1)
            canvas.strokeJoin(.round)
            polyline(canvas, [SIMD2(2, 6), SIMD2(4, 2), SIMD2(6, 6)])
        }
        let reference = try render { canvas in
            canvas.strokeWeight(20)
            canvas.strokeJoin(.round)
            polyline(canvas, [SIMD2(40, 120), SIMD2(80, 40), SIMD2(120, 120)])
        }
        #expect(reference.count > 0)
        #expect(scaled.differing(from: reference) == 0)
    }

    // MARK: - 条件 3: 周

    @Test("拡大した断片付きの円は、拡大しない同じ円と同じ絵になる", arguments: Part.allCases)
    func scaledShadedCircleMatchesUnscaled(part: Part) throws {
        let scaled = try render { canvas in
            shade(canvas)
            part.apply(canvas, weight: 0.5)
            canvas.scale(20, 20)
            canvas.circle(4, 4, 4)
        }
        let reference = try render { canvas in
            shade(canvas)
            part.apply(canvas, weight: 10)
            canvas.circle(80, 80, 80)
        }
        #expect(reference.count > 0)
        #expect(scaled.differing(from: reference) == 0)
    }

    @Test("拡大した断片付きの円弧は、拡大しない同じ円弧と同じ絵になる", arguments: Part.allCases)
    func scaledShadedArcMatchesUnscaled(part: Part) throws {
        let scaled = try render { canvas in
            shade(canvas)
            part.apply(canvas, weight: 0.5)
            canvas.scale(20, 20)
            canvas.arc(4, 4, 4, 4, 0, Float.pi)
        }
        let reference = try render { canvas in
            shade(canvas)
            part.apply(canvas, weight: 10)
            canvas.arc(80, 80, 80, 80, 0, Float.pi)
        }
        #expect(reference.count > 0)
        #expect(scaled.differing(from: reference) == 0)
    }

    // MARK: - 条件 4: 縦横で違う拡大

    /// 分割数は大きいほうの拡大率で決まる。縦に潰した円も、横に伸ばした楕円と同じ多角形になる。
    @Test("縦横で拡大の違う断片付きの円は、同じ楕円と同じ絵になる")
    func anisotropicScaleUsesTheLargerFactor() throws {
        let scaled = try render { canvas in
            shade(canvas)
            Part.fill.apply(canvas, weight: 0)
            canvas.scale(20, 5)
            canvas.circle(4, 16, 4)
        }
        let reference = try render { canvas in
            shade(canvas)
            Part.fill.apply(canvas, weight: 0)
            canvas.ellipse(80, 80, 80, 20)
        }
        #expect(reference.count > 0)
        #expect(scaled.differing(from: reference) == 0)
    }

    // MARK: - 条件 5: 畳み

    /// 同じ寸法の円 (`circle(4, 4, 4)`) を `scale(1)` と `scale(20)` で置く。畳みの鍵が置き場所の
    /// 拡大を持たないと、2 つは 1 つの雛形 (小さいほうの 7 分割) を共有し、大きいほうが三角形に近くなる。
    @Test("拡大の違う置き場所は、同じ雛形の分割を共有しない", arguments: Part.allCases)
    func placementsWithDifferentScaleDoNotShareATemplate(part: Part) throws {
        let folded = try render { canvas in
            shade(canvas)
            // 線は、`scale(1)` で太さ 2、`scale(20)` で太さ 40 (どちらも 1 画素より太い)
            part.apply(canvas, weight: 2)
            canvas.push()
            canvas.circle(4, 4, 4)
            canvas.pop()
            canvas.push()
            canvas.scale(20, 20)
            canvas.circle(4, 4, 4)
            canvas.pop()
        }
        let reference = try render { canvas in
            shade(canvas)
            part.apply(canvas, weight: 2)
            canvas.circle(4, 4, 4)
            part.apply(canvas, weight: 40)
            canvas.circle(80, 80, 80)
        }
        #expect(reference.count > 0)
        #expect(folded.differing(from: reference) == 0)
    }

    // MARK: - 条件 6: 保持した形

    /// 保持した形は、記録するときの変換 (単位行列) で頂点まで組む。置くときの拡大で組み直さないと、
    /// 記録した 3 分割の円板がそのまま拡大される。
    @Test("保持した折れ線の丸い端は、拡大して置いても拡大しない折れ線と同じ絵になる")
    func retainedRoundCapMatchesUnscaled() throws {
        let scaled = try render { canvas in
            canvas.strokeWeight(1)
            let shape = canvas.createShape {
                polyline(canvas, [SIMD2(2, 2), SIMD2(6, 2)])
            }
            canvas.scale(20, 20)
            canvas.shape(shape)
        }
        let reference = try render { canvas in
            canvas.strokeWeight(20)
            polyline(canvas, [SIMD2(40, 40), SIMD2(120, 40)])
        }
        #expect(reference.count > 0)
        #expect(scaled[34, 34], "端の円の内側 (中心から 8.5) が塗られていない")
        #expect(scaled.differing(from: reference) == 0)
    }

    @Test("保持した折れ線の丸い折れ目は、拡大して置いても拡大しない折れ線と同じ絵になる")
    func retainedRoundJoinMatchesUnscaled() throws {
        let scaled = try render { canvas in
            canvas.strokeWeight(1)
            canvas.strokeJoin(.round)
            let shape = canvas.createShape {
                polyline(canvas, [SIMD2(2, 6), SIMD2(4, 2), SIMD2(6, 6)])
            }
            canvas.scale(20, 20)
            canvas.shape(shape)
        }
        let reference = try render { canvas in
            canvas.strokeWeight(20)
            canvas.strokeJoin(.round)
            polyline(canvas, [SIMD2(40, 120), SIMD2(80, 40), SIMD2(120, 120)])
        }
        #expect(reference.count > 0)
        #expect(scaled.differing(from: reference) == 0)
    }

    @Test("保持した断片付きの円は、拡大して置いても拡大しない円と同じ絵になる", arguments: Part.allCases)
    func retainedShadedCircleMatchesUnscaled(part: Part) throws {
        let scaled = try render { canvas in
            shade(canvas)
            part.apply(canvas, weight: 0.5)
            let shape = canvas.createShape { canvas.circle(4, 4, 4) }
            canvas.scale(20, 20)
            canvas.shape(shape)
        }
        let reference = try render { canvas in
            shade(canvas)
            part.apply(canvas, weight: 10)
            canvas.circle(80, 80, 80)
        }
        #expect(reference.count > 0)
        #expect(scaled.differing(from: reference) == 0)
    }

    @Test("保持した断片付きの円弧は、拡大して置いても拡大しない円弧と同じ絵になる", arguments: Part.allCases)
    func retainedShadedArcMatchesUnscaled(part: Part) throws {
        let scaled = try render { canvas in
            shade(canvas)
            part.apply(canvas, weight: 0.5)
            let shape = canvas.createShape { canvas.arc(4, 4, 4, 4, 0, Float.pi) }
            canvas.scale(20, 20)
            canvas.shape(shape)
        }
        let reference = try render { canvas in
            shade(canvas)
            part.apply(canvas, weight: 10)
            canvas.arc(80, 80, 80, 80, 0, Float.pi)
        }
        #expect(reference.count > 0)
        #expect(scaled.differing(from: reference) == 0)
    }

    // MARK: - 塗りと線を重ねた絵

    /// 塗り (赤) の上に線 (白) を重ねた円。**3 色を別々に比べる**ので、塗りと線の重ね順も見る。
    /// 線は細くして (画面で太さ 2)、塗りの多角形の粗さが線の下に隠れないようにする。
    @Test("拡大した断片付きの円は、塗りと線を重ねても拡大しない同じ円と同じ絵になる")
    func scaledFilledAndStrokedCircleMatchesUnscaled() throws {
        let scaled = try renderChannels { canvas in
            shade(canvas)
            canvas.fill(255, 0, 0)
            canvas.stroke(255)
            canvas.strokeWeight(0.1)
            canvas.scale(20, 20)
            canvas.circle(4, 4, 4)
        }
        let reference = try renderChannels { canvas in
            shade(canvas)
            canvas.fill(255, 0, 0)
            canvas.stroke(255)
            canvas.strokeWeight(2)
            canvas.circle(80, 80, 80)
        }
        #expect(reference[1].count > 0, "線が出ていない")
        for channel in 0..<3 {
            #expect(scaled[channel].differing(from: reference[channel]) == 0, "チャンネル \(channel)")
        }
    }

    @Test("保持した断片付きの円は、塗りと線を重ねて拡大して置いても拡大しない円と同じ絵になる")
    func retainedFilledAndStrokedCircleMatchesUnscaled() throws {
        let scaled = try renderChannels { canvas in
            shade(canvas)
            canvas.fill(255, 0, 0)
            canvas.stroke(255)
            canvas.strokeWeight(0.1)
            let shape = canvas.createShape { canvas.circle(4, 4, 4) }
            canvas.scale(20, 20)
            canvas.shape(shape)
        }
        let reference = try renderChannels { canvas in
            shade(canvas)
            canvas.fill(255, 0, 0)
            canvas.stroke(255)
            canvas.strokeWeight(2)
            canvas.circle(80, 80, 80)
        }
        #expect(reference[1].count > 0, "線が出ていない")
        for channel in 0..<3 {
            #expect(scaled[channel].differing(from: reference[channel]) == 0, "チャンネル \(channel)")
        }
    }

    // MARK: - 保持した形の置き方

    /// 入れ子の記録 (`createShape` の中で置いた保持した形) は、外側を置くまで拡大が決まらない。
    /// 刻み直す素材を外側へ渡さないと、内側の円は記録のときの 7 分割のまま拡大される。
    @Test("入れ子に記録した保持した形も、拡大して置くと刻み直される", arguments: Part.allCases)
    func nestedRetainedShapeIsRescaledWhenPlaced(part: Part) throws {
        let scaled = try render { canvas in
            shade(canvas)
            part.apply(canvas, weight: 0.5)
            let inner = canvas.createShape { canvas.circle(4, 4, 4) }
            let outer = canvas.createShape { canvas.shape(inner) }
            canvas.scale(20, 20)
            canvas.shape(outer)
        }
        let reference = try render { canvas in
            shade(canvas)
            part.apply(canvas, weight: 10)
            canvas.circle(80, 80, 80)
        }
        #expect(reference.count > 0)
        #expect(scaled.differing(from: reference) == 0)
    }

    @Test("入れ子に記録した折れ線の丸い端も、拡大して置くと拡大しない折れ線と同じ絵になる")
    func nestedRetainedRoundCapIsRescaledWhenPlaced() throws {
        let scaled = try render { canvas in
            canvas.strokeWeight(1)
            let inner = canvas.createShape { polyline(canvas, [SIMD2(2, 2), SIMD2(6, 2)]) }
            let outer = canvas.createShape { canvas.shape(inner) }
            canvas.scale(20, 20)
            canvas.shape(outer)
        }
        let reference = try render { canvas in
            canvas.strokeWeight(20)
            polyline(canvas, [SIMD2(40, 40), SIMD2(120, 40)])
        }
        #expect(reference.count > 0)
        #expect(scaled.differing(from: reference) == 0)
    }

    @Test("組にした保持した形も、拡大して置くと刻み直される", arguments: Part.allCases)
    func groupedRetainedShapeIsRescaledWhenPlaced(part: Part) throws {
        let scaled = try render { canvas in
            shade(canvas)
            part.apply(canvas, weight: 0.5)
            let first = canvas.createShape { canvas.circle(3, 3, 2) }
            let second = canvas.createShape { canvas.circle(6, 6, 2) }
            canvas.scale(20, 20)
            canvas.shape(first + second)
        }
        let reference = try render { canvas in
            shade(canvas)
            part.apply(canvas, weight: 10)
            canvas.circle(60, 60, 40)
            canvas.circle(120, 120, 40)
        }
        #expect(reference.count > 0)
        #expect(scaled.differing(from: reference) == 0)
    }

    @Test("回して拡大して置いた保持した形も、同じ変換で直に描いた絵と同じになる", arguments: Part.allCases)
    func rotatedRetainedShapeMatchesDirect(part: Part) throws {
        func place(_ canvas: Canvas, retained: Bool) {
            shade(canvas)
            part.apply(canvas, weight: 0.5)
            let shape = retained ? canvas.createShape { canvas.circle(0, 0, 3) } : nil
            canvas.translate(80, 80)
            canvas.rotate(0.3)
            canvas.scale(20, 20)
            if let shape { canvas.shape(shape) } else { canvas.circle(0, 0, 3) }
        }
        let retained = try render { place($0, retained: true) }
        let direct = try render { place($0, retained: false) }
        #expect(direct.count > 0)
        #expect(retained.differing(from: direct) == 0)
    }

    /// 半透明の色を掛けて置くと、不透明の線で記録した輪郭は引いて積んだ頂点に差し替わる
    /// (`CarvedStroke`・#1829)。記録のときの分割で引いた縁をそのまま使うと、拡大した端が粗いまま残る。
    /// 刻み直した頂点は片を引いて積むので、重なった所が濃くならない。
    @Test("半透明の色を掛けて拡大して置いた保持した折れ線は、同じ色で直に描いた絵と同じになる")
    func translucentRetainedRoundCapMatchesDirect() throws {
        let alpha: Float = 128 / 255
        let tint = LinearRGBA(
            premultipliedRed: alpha, green: alpha, blue: alpha, alpha: alpha)
        let placed = try renderRed { canvas in
            canvas.strokeWeight(1)
            let shape = canvas.createShape {
                polyline(canvas, [SIMD2(2, 2), SIMD2(6, 2), SIMD2(6, 6)])
            }
            canvas.shape(shape, at: [Placement(scale: 20, fill: tint)])
        }
        let direct = try renderRed { canvas in
            canvas.stroke(255, 255, 255, 128)
            canvas.strokeWeight(20)
            polyline(canvas, [SIMD2(40, 40), SIMD2(120, 40), SIMD2(120, 120)])
        }
        #expect(direct.contains { $0 > 0.1 })
        let differing = zip(placed, direct).filter { abs($0 - $1) > 0.01 }.count
        #expect(differing == 0, "\(differing) 画素が違う")
    }

    /// 刻み直しは、分割数の組ごとに 1 度だけ。同じ大きさで置き続けても、組み直さない。
    @Test("同じ大きさで置き続ける保持した形は、刻み直しを 1 度しか払わない")
    func rescalingIsPaidOncePerSize() throws {
        let canvas = try CanvasFixture.make(gpu: RenderDevice(), width: 160, height: 160)
        var retained: Shape?
        try canvas.draw {
            canvas.background(0)
            shade(canvas)
            canvas.fill(255)
            canvas.stroke(128)
            canvas.strokeWeight(0.5)
            retained = canvas.createShape { canvas.circle(4, 4, 4) }
        }
        let shape = try #require(retained)
        func place(scale: Float, times: Int) throws {
            try canvas.draw {
                canvas.background(0)
                for index in 0..<times {
                    canvas.push()
                    canvas.translate(Float(index) * 2, 0)
                    canvas.scale(scale, scale)
                    canvas.shape(shape)
                    canvas.pop()
                }
            }
        }
        try place(scale: 20, times: 5)
        #expect(shape.thinCache.strokesRescaled == 1, "輪郭: \(shape.thinCache.strokesRescaled)")
        #expect(shape.thinCache.fillsRescaled == 1, "塗り: \(shape.thinCache.fillsRescaled)")
        // 別の大きさ (別の分割数) は、もう 1 度だけ組む
        try place(scale: 40, times: 5)
        #expect(shape.thinCache.strokesRescaled == 2)
        #expect(shape.thinCache.fillsRescaled == 2)
        // 縮めて置くと、組み直さない (記録のときより増える刻みが無い)
        try place(scale: 0.5, times: 5)
        #expect(shape.thinCache.strokesRescaled == 2)
        #expect(shape.thinCache.fillsRescaled == 2)
    }

    // MARK: - 畳みの鍵

    /// 鍵に入れるのは拡大そのものではなく整数の分割数。拡大が少し違うだけの置き場所は、分割が
    /// 同じ限り 1 つの雛形に畳まれる。
    @Test("拡大が違っても分割数が同じ置き場所は、1 つの雛形に畳まれる")
    func placementsWithTheSameSegmentsStillFold() throws {
        let scales = (0..<18).map { 1 + Float($0) * 0.002 }
        // 前提: この範囲で、周 (半径 7) も円板 (半径 1) も分割数が変わらない
        #expect(Set(scales.map { Canvas.segmentCount(forRadius: 7, scale: $0) }).count == 1)
        #expect(Set(scales.map { Canvas.segmentCount(forRadius: 1, scale: $0) }).count == 1)

        let canvas = try CanvasFixture.make(gpu: RenderDevice(), width: 160, height: 160)
        try canvas.draw {
            canvas.background(0)
            shade(canvas)
            canvas.fill(255)
            canvas.stroke(128)
            canvas.strokeWeight(2)
            for (index, scale) in scales.enumerated() {
                canvas.push()
                canvas.translate(12 + Float(index % 6) * 25, 12 + Float(index / 6) * 25)
                canvas.scale(scale, scale)
                canvas.circle(0, 0, 14)
                canvas.pop()
            }
        }
        #expect(canvas.flatVerticesInLastFrame > 0, "畳みの経路へ来ていない")
        #expect(canvas.drawCallsInLastFrame == 1, "畳んだのに列が分かれている")
        // 1 つ目を普通に置いたぶんと、雛形を積み直したぶん。18 個ぶんは組み立てない
        #expect(canvas.flatOutlinesInLastFrame == 2, "置いた数だけ周を組み立てている")
    }

    /// 円板を置かない輪郭 (丸めない矩形) は、拡大が違っても雛形を割らない。分割数が絵に出ないので、
    /// 鍵に入れると、畳めるものを畳まなくなる。
    @Test("円板を置かない輪郭の鍵は、拡大の違いで割れない")
    func placementsWithoutDiscsFoldAcrossScales() throws {
        let canvas = try CanvasFixture.make(gpu: RenderDevice(), width: 160, height: 160)
        try canvas.draw {
            canvas.background(0)
            shade(canvas)
            canvas.fill(255)
            canvas.stroke(128)
            canvas.strokeWeight(2)
            canvas.strokeJoin(.miter)
            for index in 0..<12 {
                canvas.push()
                canvas.translate(12 + Float(index % 6) * 25, 12 + Float(index / 6) * 25)
                canvas.scale(1 + Float(index) * 0.5, 1 + Float(index) * 0.5)
                canvas.rect(0, 0, 3, 3)
                canvas.pop()
            }
        }
        #expect(canvas.flatVerticesInLastFrame > 0, "畳みの経路へ来ていない")
        #expect(canvas.drawCallsInLastFrame == 1)
        #expect(canvas.flatOutlinesInLastFrame == 2, "置いた数だけ周を組み立てている")
    }

    // MARK: - 縮めた絵

    /// 縮めたときに分割を減らさない。拡大しない絵と縮めた絵は、これまでと同じ分割数のまま動かない。
    @Test("縮めた円は、拡大しない円と同じ数で刻まれる", arguments: [Float(0.5), 0.25])
    func shrunkCirclesKeepTheirSegments(scale: Float) throws {
        func vertices(scale: Float) throws -> Int {
            let canvas = try CanvasFixture.make(gpu: RenderDevice(), width: 160, height: 160)
            try canvas.draw {
                canvas.background(0)
                shade(canvas)
                canvas.fill(255)
                canvas.stroke(128)
                canvas.strokeWeight(8)
                canvas.translate(80, 80)
                canvas.scale(scale, scale)
                canvas.circle(0, 0, 120)
            }
            return canvas.flatVerticesInLastFrame
        }
        let unscaled = try vertices(scale: 1)
        #expect(unscaled > 0, "三角形の経路へ来ていない")
        #expect(try vertices(scale: scale) == unscaled)
    }

    // MARK: - 回すだけの変換 (反証 1)

    /// 円板の半径が、分割数の境目の直下 (相対 3e-5) に乗っているとき、単精度の誤差で拡大率が 1 を
    /// わずかに (1.7e-4 まで) 越えると、`scale` を掛けず `rotate` だけの絵で、丸い端と曲線の継ぎ目が
    /// 別の数に刻まれる。5 分割と 6 分割の境目は半径 `0.25 / (1 − cos(π/5)) = 1.30902` で、その直下の
    /// 半径 (太さ 2.61798) を使う。
    ///
    /// 太さ 1 (既定) は使わない。半径 0.5 は 3 分割と 4 分割の境目だが、太さ 1 を回すだけでも、
    /// 最小の特異値が単精度の誤差で 1 を割り (`thinnestDrawnWeight`)、約 22% の角度で細い線の補いが
    /// 立って頂点の数が変わる — この検査が見たい分割数の変化と混ざる。
    @Test("回すだけの変換では、どの角度でも丸い端と曲線の継ぎ目の分割数は変わらない")
    func rotationDoesNotChangeTheSegments() throws {
        let canvas = try CanvasFixture.make(gpu: RenderDevice(), width: 160, height: 160)
        func vertices(angle: Float) throws -> Int {
            try canvas.draw {
                canvas.background(0)
                canvas.noFill()
                canvas.stroke(255)
                canvas.strokeWeight(2.61798)
                canvas.translate(80, 80)
                canvas.rotate(angle)
                polyline(canvas, [SIMD2(-20, 0), SIMD2(0, 10), SIMD2(20, 0)])
                canvas.beginShape()
                canvas.vertex(-30, -30)
                canvas.bezierVertex(-10, -50, 10, -10, 30, -30)
                canvas.endShape()
            }
            return canvas.flatVerticesInLastFrame
        }
        let unrotated = try vertices(angle: 0)
        #expect(unrotated > 0)
        var changed: [Float] = []
        for step in 0..<720 {
            let angle = Float(step) * (2 * .pi / 720)
            if try vertices(angle: angle) != unrotated { changed.append(angle) }
        }
        #expect(changed.isEmpty, "分割数が変わった角度 \(changed.count) 個: \(changed.prefix(5))")
    }

    @Test("回すだけで置いた保持した形は、刻み直されない")
    func rotatedRetainedShapeIsNeverRescaled() throws {
        let canvas = try CanvasFixture.make(gpu: RenderDevice(), width: 160, height: 160)
        var retained: Shape?
        try canvas.draw {
            canvas.background(0)
            shade(canvas)
            canvas.fill(255)
            canvas.stroke(128)
            canvas.strokeWeight(2.61798)  // 分割数の境目の直下 (上の検査と同じ)
            retained = canvas.createShape {
                canvas.circle(0, 0, 40)
                polyline(canvas, [SIMD2(-20, 0), SIMD2(0, 10), SIMD2(20, 0)])
            }
        }
        let shape = try #require(retained)
        for step in 0..<400 {
            try canvas.draw {
                canvas.background(0)
                canvas.translate(80, 80)
                canvas.rotate(Float(step) * (2 * .pi / 400))
                canvas.shape(shape)
            }
        }
        #expect(shape.thinCache.strokesRescaled == 0, "輪郭: \(shape.thinCache.strokesRescaled)")
        #expect(shape.thinCache.fillsRescaled == 0, "塗り: \(shape.thinCache.fillsRescaled)")
    }

    // MARK: - 不透明の線の積み方 (反証 3)

    /// 不透明の線は、片を重ねたまま積む (`strokeOverlapsShow`)。引いて積むと、不透明の絵も縁から
    /// 1/1000 画素ほどの所に中心が乗る画素が入れ替わりうる。保持した形を拡大して置いて刻み直すときも、
    /// 記録したときの積み方のまま組み直すので、同じ拡大で直に描いた絵と、**縁の画素の値まで**一致する。
    @Test("拡大して置いた不透明の保持した折れ線は、直に描いた絵と縁の画素の値まで同じになる")
    func opaqueRetainedPolylinesMatchDirectToTheEdge() throws {
        func build(_ canvas: Canvas) {
            canvas.stroke(255)
            canvas.strokeWeight(1)
            canvas.strokeJoin(.round)
            polyline(canvas, [SIMD2(0.3, 0.2), SIMD2(4.1, 0.7), SIMD2(5.2, 3.9), SIMD2(1.7, 5.3)])
            canvas.beginShape()
            canvas.vertex(0.4, 6.1)
            canvas.bezierVertex(2.2, 4.3, 4.6, 8.9, 6.3, 6.7)
            canvas.endShape()
            canvas.strokeJoin(.miter)
            polyline(canvas, [SIMD2(7.1, 0.4), SIMD2(7.9, 2.3), SIMD2(6.6, 2.9)])
        }
        func transform(_ canvas: Canvas) {
            canvas.translate(31, 17)
            canvas.rotate(0.37)
            canvas.scale(12.3, 12.3)
        }
        let placed = try renderRed { canvas in
            canvas.strokeWeight(1)
            let shape = canvas.createShape { build(canvas) }
            transform(canvas)
            canvas.shape(shape)
        }
        let direct = try renderRed { canvas in
            transform(canvas)
            build(canvas)
        }
        #expect(direct.contains { $0 > 0.5 })
        let differing = zip(placed, direct).filter { $0 != $1 }.count
        #expect(differing == 0, "\(differing) 画素の値が違う")
    }

    // MARK: - 畳みが割れる並び (反証 7)

    /// 置き場所ごとに拡大がばらつく描き方 (粒ごとに大きさを変える) は、鍵が交互に変わって畳みが
    /// 割れる。割れる側が設計どおりで、絵は拡大しない対照と同じに描かれ、雛形を作り直す仕事が
    /// 置いた数を越えて増えない。
    @Test("拡大が交互に来る置き場所も、絵が拡大しない対照と同じで、周の組み立ては置いた数を越えない")
    func alternatingScalesDrawCorrectlyAndDoNotMultiplyTemplates() throws {
        let count = 24
        func place(_ index: Int) -> (x: Float, y: Float, big: Bool) {
            (14 + Float(index % 6) * 26, 14 + Float(index / 6) * 26, index.isMultiple(of: 2))
        }
        // 大・小・大・小。大きいほうは 3 倍
        let canvas = try CanvasFixture.make(gpu: RenderDevice(), width: 160, height: 160)
        try canvas.draw {
            canvas.background(0)
            shade(canvas)
            canvas.fill(255, 0, 0)
            canvas.stroke(255)
            canvas.strokeWeight(2)
            for index in 0..<count {
                let spot = place(index)
                canvas.push()
                canvas.translate(spot.x, spot.y)
                if spot.big { canvas.scale(3, 3) }
                canvas.circle(0, 0, 6)
                canvas.pop()
            }
        }
        let pixels = try canvas.target.readPixels()
        let folded = (0..<3).map { channel in
            Coverage(
                inked: (0..<(160 * 160)).map { Float(pixels.components[$0 * 4 + channel]) >= 0.5 })
        }
        #expect(canvas.flatVerticesInLastFrame > 0, "三角形の経路へ来ていない")
        // 組み立てた周は、置いた数ちょうど (1 つ置くたびに 1 度。雛形を作り直して増やさない)
        #expect(
            canvas.flatOutlinesInLastFrame == count,
            "周を \(canvas.flatOutlinesInLastFrame) 回組み立てた (置いたのは \(count) 個)")
        let reference = try renderChannels { canvas in
            shade(canvas)
            canvas.fill(255, 0, 0)
            canvas.stroke(255)
            for index in 0..<count {
                let spot = place(index)
                canvas.strokeWeight(spot.big ? 6 : 2)
                canvas.circle(spot.x, spot.y, spot.big ? 18 : 6)
            }
        }
        #expect(reference[1].count > 0)
        for channel in 0..<3 {
            #expect(folded[channel].differing(from: reference[channel]) == 0, "チャンネル \(channel)")
        }
    }

    // MARK: - 桁違いの拡大 (反証 2)

    /// 拡大が桁違いに大きいときは、いちばん細かい側 (上限 1024) へ倒す。単精度で 2 乗があふれて
    /// 拡大率が 1 に化けると、いちばん粗い多角形になる。
    @Test("桁違いの拡大の円は、いちばん細かい側 (上限 1024 分割) で刻まれる")
    func enormousScaleSplitsAsFinelyAsPossible() throws {
        let canvas = try CanvasFixture.make(gpu: RenderDevice(), width: 160, height: 160)
        try canvas.draw {
            canvas.background(0)
            shade(canvas)
            canvas.noStroke()
            canvas.fill(255)
            canvas.scale(9e9, 9e9)
            canvas.circle(0, 0, 2)
        }
        // 塗りは扇で、分割 1 つにつき三角形 1 つ (頂点 3 つ)。一周の点の数は 1024 か、数え方の端数で 1025
        let vertices = canvas.flatVerticesInLastFrame
        #expect(vertices >= 3 * 1024 && vertices <= 3 * 1025, "頂点 \(vertices) 個")
    }

    // MARK: - 円板を置くかの規則 (反証 6)

    /// 鍵・組み直しの素材・骨が、円板を置くかを別々に決めると、ずれた日に鍵の分割数 0 (置かない) が
    /// 円板を置く輪郭へ来て、円板が黙って消える。**規則を骨に数えさせて突き合わせる** — 点の数・
    /// 閉じているか・刻みの点の位置・端と折れ目の形の全部の組で、規則が「置かない」と言うとき、骨も
    /// 1 つも置かない。
    @Test("円板を置くかの規則は、骨 (strokeRing) が実際に円板を置く点と一致する")
    func discRuleMatchesTheSkeleton() throws {
        let canvas = try CanvasFixture.make(gpu: RenderDevice(), width: 16, height: 16)
        var mismatches: [String] = []
        func placed(count: Int, closed: Bool, steps: [Bool], coincident: Bool = false) -> Bool {
            var discs = 0
            canvas.strokeRing(
                count: count, isClosed: closed, curveSteps: steps,
                samePlace: { _, _ in coincident }, endSquare: { _, _ in }, band: { _, _ in },
                disc: { _ in discs += 1 }, square: { _ in }, corner: { _, _, _ in })
            return discs > 0
        }
        for cap in [StrokeCap.round, .square, .project] {
            for join in [StrokeJoin.round, .miter, .bevel] {
                canvas.strokeCap(cap)
                canvas.strokeJoin(join)
                for count in 1...5 {
                    for closed in [false, true] {
                        for pattern in 0..<(1 << count) {
                            let steps = (0..<count).map { pattern & (1 << $0) != 0 }
                            let outline = Canvas.Outline(
                                points: (0..<count).map { SIMD2(Float($0), Float($0 * $0 % 3)) },
                                isClosed: closed, curveSteps: steps)
                            let rule = outline.placesDiscs(cap: cap, join: join)
                            let actual = placed(count: count, closed: closed, steps: steps)
                            if rule != actual {
                                mismatches.append(
                                    "\(cap) \(join) 点\(count) 閉\(closed) 刻み\(steps) 規則\(rule) 骨\(actual)")
                            }
                            // 同じ位置の点が並ぶときも、規則が「置かない」なら骨も置かない
                            if !rule, placed(count: count, closed: closed, steps: steps, coincident: true) {
                                mismatches.append("同じ位置の点で規則より多く置く: \(cap) \(join) 点\(count)")
                            }
                        }
                    }
                }
                // 畳みの鍵が持つ周の形 (矩形・楕円・弧) の規則も、同じ骨と突き合わせる
                let forms: [(Canvas.FlatForm, Int, [Bool])] = [
                    (.rect(width: 4, height: 3), 4, [false, false, false, false]),
                    (.ellipse(radiusX: 2, radiusY: 2), 8, Array(repeating: true, count: 8)),
                    (.arc(radiusX: 2, radiusY: 2, start: 0, sweep: 3), 6, Array(repeating: true, count: 6)),
                ]
                for (form, count, steps) in forms {
                    let rule = form.placesDiscs(cap: cap, join: join)
                    let actual = placed(count: count, closed: true, steps: steps)
                    if rule != actual { mismatches.append("\(form) \(cap) \(join) 規則\(rule) 骨\(actual)") }
                }
            }
        }
        #expect(mismatches.isEmpty, "規則と骨がずれた \(mismatches.count) 件: \(mismatches.prefix(3))")
    }

    // MARK: - 刻み直した頂点の控え (反証 4)

    /// 刻み直した頂点の控えは、形 1 つにつき頂点の総量で切る。輪郭の数に上限が無いので、輪郭ごとの
    /// 件数では切れず、拡大を連続して変える形 (ズーム) は輪郭の数 × 変えた回数の配列を溜めうる。
    @Test("刻み直した頂点の控えは、頂点の総量の上限を越えず、古いものから捨てる")
    func rescaledCacheStaysWithinItsBudget() throws {
        let canvas = try CanvasFixture.make(gpu: RenderDevice(), width: 160, height: 160)
        var retained: Shape?
        try canvas.draw {
            canvas.background(0)
            shade(canvas)
            canvas.fill(255)
            canvas.stroke(128)
            canvas.strokeWeight(0.5)
            retained = canvas.createShape {
                for index in 0..<6 { canvas.circle(Float(index) * 3, 0, 2) }
            }
        }
        let shape = try #require(retained)
        let budget = 4_000
        shape.thinCache.scaledBudget = budget
        var largest = 0
        func place(scale: Float) throws {
            try canvas.draw {
                canvas.background(0)
                canvas.scale(scale, scale)
                canvas.shape(shape)
            }
            largest = max(largest, shape.thinCache.scaledVertexTotal)
        }
        // 拡大を変え続ける (ズーム)。どの回でも、控えている頂点の数は予算に収まる
        let scales = (0..<60).map { 2 + Float($0) * 0.7 }
        for scale in scales { try place(scale: scale) }
        #expect(largest <= budget, "控えた頂点は最大 \(largest) 個 (予算 \(budget))")
        #expect(shape.thinCache.scaledVertexTotal > 0)
        // 古いものは捨てられている — 最初の拡大へ戻ると、組み直す
        let before = shape.thinCache.strokesRescaled
        try place(scale: scales[0])
        #expect(shape.thinCache.strokesRescaled > before, "古い控えが残っている")
        // 予算を広げれば、同じ拡大へ戻っても組み直さない
        shape.thinCache.scaledBudget = ThinStrokeCache.defaultScaledBudget
        try place(scale: scales[0])
        let settled = shape.thinCache.strokesRescaled
        try place(scale: scales[0])
        #expect(shape.thinCache.strokesRescaled == settled)
    }

    // MARK: - 記録のときと同じ積み方 (反証 3)

    /// 組み直しは、積む関数そのものを通して、頂点を溜め場ではなく受け皿へ受ける。**拡大しないとき
    /// (記録のときと同じ分割)、記録した頂点と 1 ビットも違わない** — 違えば、その関数の外に式が
    /// 写っている。
    @Test("記録のときと同じ積み方で組み直した頂点は、記録した頂点と 1 ビットも違わない")
    func stackedRebuildEqualsTheRecordedVertices() throws {
        let canvas = try CanvasFixture.make(gpu: RenderDevice(), width: 160, height: 160)
        var retained: Shape?
        try canvas.draw {
            canvas.background(0)
            canvas.stroke(255)
            canvas.strokeWeight(1.3)
            // 絵を貼った矩形は三角形の経路で、不透明の線は重ねたまま積まれ、矩形の角の削ぎも通る
            let picture = try? canvas.createImage(1, 1)
            retained = canvas.createShape {
                for cap in [StrokeCap.round, .square, .project] {
                    for join in [StrokeJoin.round, .miter, .bevel] {
                        canvas.strokeCap(cap)
                        canvas.strokeJoin(join)
                        polyline(canvas, [SIMD2(0, 0), SIMD2(4.3, 0.7), SIMD2(5, 4), SIMD2(1, 5.3)])
                        canvas.beginShape()
                        canvas.vertex(0, 6)
                        canvas.bezierVertex(2, 4, 5, 9, 7, 6)
                        canvas.endShape(.close)
                        if let picture {
                            canvas.texture(picture)
                            canvas.rect(8, 0, 4, 3)
                            canvas.noTexture()
                        }
                    }
                }
                // 点 1 つ・同じ位置が続く点
                canvas.strokeCap(.round)
                canvas.point(3, 3)
                polyline(canvas, [SIMD2(1, 1), SIMD2(1, 1), SIMD2(3, 2)])
            }
        }
        let shape = try #require(retained)
        var checked = 0
        var unequal: [Int] = []
        for (index, range) in shape.strokeRanges.enumerated() {
            guard let recipe = range.thin, !recipe.recordedCarved else { continue }
            checked += 1
            let rebuilt = canvas.stackedVertices(
                recipe.outline, recipe: recipe, discSegments: recipe.discSegments)
            let recorded = Array(shape.vertices[range.range])
            let same =
                rebuilt.count == recorded.count
                && zip(rebuilt, recorded).allSatisfy {
                    $0.position == $1.position && $0.uv == $1.uv && $0.color == $1.color
                }
            if !same { unequal.append(index) }
        }
        #expect(checked >= 20, "重ねたまま積んだ輪郭が \(checked) 本しか見つからない")
        #expect(unequal.isEmpty, "記録と違う輪郭 \(unequal.count) 本: \(unequal.prefix(5))")
    }

    /// 不透明の保持した形を拡大して置いた絵は、同じ変換で直に描いた絵と、**画素の値まで**同じ
    /// (引いて積むと、縁から 1/1000 画素ほどの所の画素が入れ替わる)。線の位置・太さ・拡大・向き・
    /// 折れ目の形を変えた 400 通りで見る。
    @Test("不透明の保持した折れ線は、拡大して回して置いても、直に描いた絵と画素の値まで同じ")
    func opaqueRetainedPolylinesMatchDirectOverManyShapes() throws {
        let canvas = try CanvasFixture.make(gpu: RenderDevice(), width: 160, height: 160)
        var state: UInt64 = 12345
        func next() -> Float {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return Float((state >> 40) & 0xFFFFFF) / Float(0x1000000)
        }
        func red(_ body: () -> Void) throws -> [Float] {
            try canvas.draw {
                canvas.background(0)
                canvas.noFill()
                canvas.stroke(255)
                body()
            }
            let pixels = try canvas.target.readPixels()
            return (0..<(160 * 160)).map { Float(pixels.components[$0 * 4]) }
        }
        var differingCases: [Int] = []
        for index in 0..<400 {
            let integer = index % 3 == 0
            var points: [SIMD2<Float>] = []
            for _ in 0..<(2 + Int(next() * 4)) {
                let x = next() * 8
                let y = next() * 8
                points.append(integer ? SIMD2(x.rounded(), y.rounded()) : SIMD2(x, y))
            }
            let weight: Float = integer ? 1 : 0.4 + next() * 1.4
            let scale = 2 + next() * 18
            let angle = index % 2 == 0 ? 0 : next() * 6.28
            let join: StrokeJoin = index % 4 == 0 ? .round : (index % 4 == 1 ? .miter : .bevel)
            func build() {
                canvas.strokeWeight(weight)
                canvas.strokeJoin(join)
                canvas.beginShape()
                for point in points { canvas.vertex(point.x, point.y) }
                canvas.endShape()
            }
            func place() {
                canvas.translate(20, 20)
                canvas.rotate(angle)
                canvas.scale(scale, scale)
            }
            let placed = try red {
                canvas.strokeWeight(weight)
                canvas.strokeJoin(join)
                let shape = canvas.createShape { build() }
                place()
                canvas.shape(shape)
            }
            let direct = try red {
                place()
                build()
            }
            if zip(placed, direct).contains(where: { $0 != $1 }) { differingCases.append(index) }
        }
        #expect(differingCases.isEmpty, "画素の値が違う \(differingCases.count) 通り: \(differingCases.prefix(8))")
    }

    // MARK: - 細かさ

    /// 分割数の物差しは出す画素で、`pixelDensity` を含まない。細かさを下げても、同じ形は同じ数で
    /// 刻まれる (細かさによらない約束・#1686)。
    @Test("細かさを下げても、円と円板の分割数は変わらない")
    func densityDoesNotChangeTheSegments() throws {
        func vertices(density: Float) throws -> Int {
            let gpu = try RenderDevice()
            let output = try RenderTarget(gpu: gpu, width: 128, height: 128)
            let canvas = try Canvas(
                output: output, gpu: gpu, pixelDensity: density, upscale: .spatial)
            try canvas.draw {
                canvas.background(0)
                shade(canvas)
                canvas.fill(255)
                canvas.stroke(128)
                canvas.strokeWeight(1)
                canvas.scale(10, 10)
                canvas.circle(6, 6, 4)
            }
            return canvas.flatVerticesInLastFrame
        }
        let full = try vertices(density: 1)
        #expect(full > 0)
        #expect(try vertices(density: 0.5) == full)
    }
}

/// 分割数を決める拡大率と、拡大した半径の分割数 ([#1645])。GPU は要らない。
///
/// [#1645]: https://github.com/mokume-metal/mokume/issues/1645
@Suite("拡大した円の分割数の式")
struct ScaledSegmentFormulaTests {
    private func matrix(_ build: (inout Transform) -> Void) -> simd_float4x4 {
        var transform = Transform.identity
        build(&transform)
        return transform.matrix
    }

    @Test("拡大率は、行列の 2x2 の最大の特異値")
    func splitScaleIsTheLargestSingularValue() {
        #expect(Canvas.splitScale(of: matrix { _ in }) == 1)
        #expect(abs(Canvas.splitScale(of: matrix { $0.scale(x: 20, y: 20) }) - 20) < 1e-3)
        // 縦横で違う拡大は、大きいほう
        #expect(abs(Canvas.splitScale(of: matrix { $0.scale(x: 20, y: 5) }) - 20) < 1e-3)
        #expect(abs(Canvas.splitScale(of: matrix { $0.scale(x: 3, y: 40) }) - 40) < 1e-3)
        // 回しても変わらない
        let turned = matrix {
            $0.rotate(by: 0.7)
            $0.scale(x: 20, y: 5)
        }
        #expect(abs(Canvas.splitScale(of: turned) - 20) < 1e-3)
        // 平行移動は効かない。回すだけでも伸びない
        #expect(abs(Canvas.splitScale(of: matrix { $0.translate(x: 500, y: -300) }) - 1) < 1e-6)
        #expect(abs(Canvas.splitScale(of: matrix { $0.rotate(by: 0.7) }) - 1) < 1e-5)
    }

    @Test("縮めても、拡大率は 1 のまま (分割を減らさない)")
    func splitScaleNeverFallsBelowOne() {
        #expect(Canvas.splitScale(of: matrix { $0.scale(x: 0.25, y: 0.25) }) == 1)
        #expect(Canvas.splitScale(of: matrix { $0.scale(x: 0, y: 0) }) == 1)
        // 一方だけ縮めても、伸びるほうで決まる
        #expect(abs(Canvas.splitScale(of: matrix { $0.scale(x: 6, y: 0.1) }) - 6) < 1e-3)
    }

    @Test("数でない・無限の変換は 1 に倒す")
    func splitScaleIgnoresNonFiniteMatrices() {
        #expect(Canvas.splitScale(of: matrix { $0.scale(x: .nan, y: 2) }) == 1)
        #expect(Canvas.splitScale(of: matrix { $0.scale(x: .infinity, y: 2) }) == 1)
    }

    @Test("拡大しない分割数は、拡大率 1 の式と 1 ビットも違わない")
    func unitScaleKeepsTheFormula() {
        for radius in [Float(0.1), 0.5, 1, 6, 20, 400, 20_000, 1e9, .nan, .infinity] {
            #expect(
                Canvas.segmentCount(forRadius: radius, scale: 1)
                    == Canvas.segmentCount(forRadius: radius))
        }
    }

    @Test("拡大した後の半径で分割数を決める")
    func segmentCountFollowsTheDrawnRadius() {
        // 起票時の再現: 半径 0.5 の円板は、拡大しなければ 3 分割。20 倍で半径 10 の円と同じ
        #expect(Canvas.segmentCount(forRadius: 0.5) == 3)
        #expect(Canvas.segmentCount(forRadius: 0.5, scale: 20) == Canvas.segmentCount(forRadius: 10))
        #expect(Canvas.segmentCount(forRadius: 2, scale: 20) == Canvas.segmentCount(forRadius: 40))
        for scale in [Float(1.5), 3, 20, 100] {
            #expect(
                Canvas.segmentCount(forRadius: 3, scale: scale)
                    == Canvas.segmentCount(forRadius: 3 * scale))
        }
    }

    @Test("拡大が桁違いでも、上限で頭打ちにする。数でない値は式に任せる")
    func scaledSegmentCountIsBounded() {
        #expect(Canvas.segmentCount(forRadius: 1, scale: 1e30) == 1024)
        // 半径 × 拡大が単精度に収まらないときも、細かい側へ倒す
        #expect(Canvas.segmentCount(forRadius: 1e30, scale: 1e30) == 1024)
        #expect(Canvas.segmentCount(forRadius: .nan, scale: 20) == 3)
        #expect(Canvas.segmentCount(forRadius: .infinity, scale: 20) == 3)
        #expect(Canvas.segmentCount(forRadius: 4, scale: .nan) == 3)
    }

    @Test("弧の点の数は、拡大した半径の分割数で決まる")
    func arcOffsetsFollowTheScale() {
        // 点の数は、半径を画面の大きさにした円と同じ (数え方の端数は、どちらにも同じに出る)
        func count(_ radiusX: Float, _ radiusY: Float, scale: Float = 1) -> Int {
            Canvas.arcOffsets(
                radiusX: radiusX, radiusY: radiusY, from: 0, sweep: 2 * .pi, scale: scale
            ).count
        }
        let unit = Canvas.arcOffsets(radiusX: 0.5, radiusY: 0.5, from: 0, sweep: 2 * .pi, scale: 1)
        let formula = Canvas.arcOffsets(
            radiusX: 0.5, radiusY: 0.5, from: 0, sweep: 2 * .pi,
            fullTurn: Canvas.segmentCount(forRadius: 0.5))
        #expect(unit == formula)
        #expect(count(0.5, 0.5, scale: 20) == count(10, 10))
        #expect(count(0.5, 0.5, scale: 20) > unit.count)
        // 楕円は大きいほうの軸で決まる
        #expect(count(2, 0.5, scale: 10) == count(20, 5))
        // 点は形自身の座標のまま (拡大は分割数にだけ効く)
        let scaled = Canvas.arcOffsets(
            radiusX: 0.5, radiusY: 0.5, from: 0, sweep: 2 * .pi, scale: 20)
        #expect(scaled.allSatisfy { simd_length($0) < 0.5 + 1e-5 })
    }

    // MARK: - 単精度の誤差と桁あふれ (反証 1・2)

    private func rotated(_ angle: Float) -> simd_float4x4 { matrix { $0.rotate(by: angle) } }

    /// 回すだけ・映すだけの変換は、どの角度でも長さを保つ。ところが単精度の行列は成分が
    /// 丸められるので、2x2 の最大の特異値は 1 ± 1e-7 ほどになる (かつては、約 4.9% の角度で拡大率が
    /// 1 を越え、`trace²/4 − det²` の打ち消しで最大 1.00017 まで膨らんだ)。
    @Test("回すだけ・映すだけの変換は、どの角度・どの合成でも拡大率がちょうど 1")
    func rotationsAndReflectionsNeverEnlarge() {
        var enlarged: [String] = []
        func check(_ label: @autoclosure () -> String, _ matrix: simd_float4x4) {
            let scale = Canvas.splitScale(of: matrix)
            if scale != 1 { enlarged.append("\(label()) → \(scale)") }
        }
        // 1 つの角度
        for step in 0..<6284 { check("rotate(\(step))", rotated(Float(step) * 0.001)) }
        // 2 つの回転の合成・平行移動と鏡映を挟んだ合成
        for first in 0..<157 {
            for second in 0..<157 {
                let a = Float(first) * 0.04
                let b = Float(second) * 0.04
                check("rotate(\(a)); rotate(\(b))", matrix { $0.rotate(by: a); $0.rotate(by: b) })
                check(
                    "translate; rotate(\(a)); scale(-1, 1); rotate(\(b))",
                    matrix {
                        $0.translate(x: 80, y: 80)
                        $0.rotate(by: a)
                        $0.scale(x: -1, y: 1)
                        $0.rotate(by: b)
                    })
            }
        }
        // 小さい回転を 1000 回重ねる (誤差が積もる)
        var chain = Transform.identity
        for _ in 0..<1000 { chain.rotate(by: 0.00628) }
        check("rotate(0.00628) × 1000", chain.matrix)
        #expect(enlarged.isEmpty, "拡大率が 1 でない変換 \(enlarged.count) 個: \(enlarged.prefix(3))")
    }

    @Test("回すだけの変換の分割数は、どの半径でも拡大しないときと同じ")
    func rotationKeepsTheSegmentCount() {
        // 半径 0.5 は、3 分割と 4 分割の境目 (`π / acos(1 − 0.25 / r)` がちょうど 3)
        var changed: [String] = []
        for step in 0..<6284 {
            let scale = Canvas.splitScale(of: rotated(Float(step) * 0.001))
            for radius in [Float(0.5), 0.25, 1, 1.309, 6, 7.338, 10, 53_000] {
                if Canvas.segmentCount(forRadius: radius, scale: scale)
                    != Canvas.segmentCount(forRadius: radius)
                {
                    changed.append("半径 \(radius)・角度 \(Float(step) * 0.001)")
                }
            }
        }
        #expect(changed.isEmpty, "分割数が変わった \(changed.count) 件: \(changed.prefix(3))")
    }

    @Test("誤差の幅の内側は 1 に丸め、本当の拡大は丸めない")
    func splitScaleSnapsOnlyInsideTheRoundingBand() {
        #expect(Canvas.splitScaleTolerance == 1e-3)
        // 幅の内側 (単精度の誤差が積もっても届く範囲) は、ちょうど 1
        #expect(Canvas.splitScale(of: matrix { $0.scale(x: 1.0005, y: 1.0005) }) == 1)
        // 幅の外は、拡大したぶんを返す
        let enlarged = Canvas.splitScale(of: matrix { $0.scale(x: 1.01, y: 1.01) })
        #expect(abs(enlarged - 1.01) < 1e-5)
        #expect(abs(Canvas.splitScale(of: matrix { $0.scale(x: 1, y: 1.002) }) - 1.002) < 1e-5)
    }

    /// 2 乗が単精度の範囲を越えても、拡大率を 1 へ倒さない。分割数は桁違いの拡大で、いちばん
    /// 細かい側 (上限 1024) へ倒れる。
    @Test("桁違いの拡大も、拡大率が 1 に化けず、いちばん細かい側へ倒れる")
    func hugeScalesStayHuge() {
        for scale in [Float(9e9), 1e10, 1e20, 1e30, 3e38] {
            let found = Canvas.splitScale(of: matrix { $0.scale(x: scale, y: scale) })
            #expect(abs(found / scale - 1) < 1e-5, "scale(\(scale)) → \(found)")
            #expect(Canvas.segmentCount(forRadius: 1, scale: found) == 1024, "scale(\(scale))")
        }
        // 一方の軸だけが大きいとき
        let stretched = Canvas.splitScale(of: matrix { $0.scale(x: 1e10, y: 0.001) })
        #expect(abs(stretched / 1e10 - 1) < 1e-5)
        // 単精度に収まらない大きさ (成分 3e38 が 2 つ並ぶ列 → 4.2e38) は、単精度の最大で止める
        var columns = matrix_identity_float4x4
        columns.columns.0 = SIMD4(3e38, 3e38, 0, 0)
        let clamped = Canvas.splitScale(of: columns)
        #expect(clamped == Float.greatestFiniteMagnitude)
        #expect(Canvas.segmentCount(forRadius: 1, scale: clamped) == 1024)
    }
}
