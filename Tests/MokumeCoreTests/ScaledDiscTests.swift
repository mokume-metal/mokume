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

    /// 距離関数の経路 (`line`) の丸い端と比べる。縁の濃さは経路で違ってよいので、折れ線と `line` の
    /// 違いは、拡大しない折れ線と `line` の違い (起票時 8 画素) に、**`line` 自身が拡大で揺れる分**
    /// (拡大した `line` と拡大しない `line` の両端の違い) を足した数を越えないことを見る。
    /// 直す前は 116 画素で、この数を大きく越えていた。
    @Test("拡大した折れ線の両端は、`line()` との違いが拡大しない折れ線を越えない")
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
        // 縁の濃さが 50% に近い画素は、`line` が拡大するだけで塗られるかが入れ替わる
        let jitter = scaledLine.differing(from: plainLine, where: ends)
        let baseline = plainPolyline.differing(from: plainLine, where: ends) + jitter
        let measured = scaledPolyline.differing(from: scaledLine, where: ends)
        #expect(
            measured <= baseline,
            "両端の違い \(measured) 画素が、拡大しない折れ線と `line` の違い + `line` の揺れ \(baseline) 画素を越える")
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
        let unit = Canvas.arcOffsets(radiusX: 0.5, radiusY: 0.5, from: 0, sweep: 2 * .pi)
        let same = Canvas.arcOffsets(radiusX: 0.5, radiusY: 0.5, from: 0, sweep: 2 * .pi, scale: 1)
        #expect(unit == same)
        #expect(count(0.5, 0.5, scale: 20) == count(10, 10))
        #expect(count(0.5, 0.5, scale: 20) > unit.count)
        // 楕円は大きいほうの軸で決まる
        #expect(count(2, 0.5, scale: 10) == count(20, 5))
        // 点は形自身の座標のまま (拡大は分割数にだけ効く)
        let scaled = Canvas.arcOffsets(
            radiusX: 0.5, radiusY: 0.5, from: 0, sweep: 2 * .pi, scale: 20)
        #expect(scaled.allSatisfy { simd_length($0) < 0.5 + 1e-5 })
    }
}
