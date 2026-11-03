// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation
import Testing

@testable import MokumeCore

/// 平面の半透明の線は、1 つの図形 (原始形 1 つ = 外周 + 穴 + 破線の片) の線全体を型板で 1 回だけ混ぜる
/// ([#3579]・[ADR-0046])。GPU を要する。
///
/// 面は 160×160 の黒地で、線は `stroke(255, 0, 0, 128)`。1 回混ぜると線形の赤が 0.413、2 回で 0.618 に
/// なる。「重ね塗りの画素」は赤が 0.5 を超える画素とする。
///
/// [#3579]: https://github.com/mokume-metal/mokume/issues/3579
/// [ADR-0046]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0046-stroke-stencil.md
@Suite(
    "平面の線の型板",
    .enabled(
        if: RenderDevice.isAvailable,
        "この世代のコマンド構造に対応した GPU が無い実行環境ではスキップする")
)
struct FlatStrokeStencilTests {
    private let black = LinearRGBA.linear(red: 0, green: 0, blue: 0)

    /// 平面の列ごとの区間の数を持ち出す箱。
    final class Box { var counts: [Int] = [] }

    private static let once: Float = 0.413
    private static let twice: Float = 0.618

    /// 素通しの断片。組み込みの断片と同じ色を出すが、`shader()` が効くので三角形の経路へ落ちる。
    private static let passThrough = "float4 paint(Fragment in, Values values) { return in.color; }"

    /// 黒地に `noFill()` で描いて、線形の画素を読む。`sections` には、描き終えた時点の平面の列が持つ
    /// 区間の数を列ごとに入れる。
    private func render(
        shaded: Bool = false, sections: Box? = nil, _ body: (Canvas) -> Void
    ) throws -> PixelBuffer {
        let canvas = try CanvasFixture.make(gpu: RenderDevice(), width: 160, height: 160)
        var failure: (any Error)?
        try canvas.draw {
            canvas.background(black)
            canvas.noFill()
            if shaded {
                do { canvas.shader(try canvas.makeShader(Self.passThrough)) } catch { failure = error }
            }
            body(canvas)
            canvas.closeBatch()
            sections?.counts = canvas.batches.filter { $0.source == .flat }.map(\.strokeStencilSections.count)
        }
        if let failure { throw failure }
        return try canvas.target.readPixels()
    }

    private func translucent(
        shaded: Bool = false, sections: Box? = nil, _ body: (Canvas) -> Void
    ) throws -> PixelBuffer {
        try render(shaded: shaded, sections: sections) { canvas in
            canvas.stroke(255, 0, 0, 128)
            body(canvas)
        }
    }

    private func overpainted(_ pixels: PixelBuffer) -> [SIMD2<Int>] {
        var found: [SIMD2<Int>] = []
        for y in 0..<pixels.height {
            for x in 0..<pixels.width where pixels[x, y].red > 0.5 { found.append(SIMD2(x, y)) }
        }
        return found
    }

    private func painted(_ pixels: PixelBuffer) -> Set<SIMD2<Int>> {
        var found: Set<SIMD2<Int>> = []
        for y in 0..<pixels.height {
            for x in 0..<pixels.width where pixels[x, y].red > 0.05 { found.insert(SIMD2(x, y)) }
        }
        return found
    }

    /// #2209 の完了条件 1 の開いた折れ線。(80, 80) で自分と交わる。
    private static func crossingPolyline(_ canvas: Canvas) {
        canvas.strokeWeight(10)
        canvas.strokeCap(.round)
        canvas.beginShape()
        canvas.vertex(20, 20)
        canvas.vertex(140, 140)
        canvas.vertex(140, 20)
        canvas.vertex(20, 140)
        canvas.endShape()
    }

    // MARK: - 条件 1: 自己交差

    @Test("自分と交わる開いた折れ線は、交点も 1 回だけ混ぜる", arguments: [false, true])
    func selfCrossingMixesOnce(shaded: Bool) throws {
        let pixels = try translucent(shaded: shaded, Self.crossingPolyline)
        #expect(abs(pixels[80, 80].red - Self.once) <= 0.01, "交点: \(pixels[80, 80].red)")
        #expect(overpainted(pixels).isEmpty, "重ね塗り \(overpainted(pixels).count) 画素")
    }

    // MARK: - 条件 2: 別々の図形

    /// 探針の 1 点ではなく交わりの全画素を見て、消し描きの消し残しを拾う。
    @Test("別々の図形の線が交わる所は、全画素で 2 回混ぜる")
    func separateFiguresMixTwice() throws {
        let pixels = try translucent { canvas in
            canvas.strokeWeight(10)
            canvas.strokeCap(.square)
            for (a, b) in [(SIMD2<Float>(40, 80), SIMD2<Float>(120, 80)), (SIMD2(80, 40), SIMD2(80, 120))] {
                canvas.beginShape()
                canvas.vertex(a.x, a.y)
                canvas.vertex(b.x, b.y)
                canvas.endShape()
            }
        }
        var wrong: [SIMD2<Int>] = []
        for y in 76..<84 {
            for x in 76..<84 where abs(pixels[x, y].red - Self.twice) >= 0.01 { wrong.append(SIMD2(x, y)) }
        }
        #expect(wrong.isEmpty, "2 回でない交わりの画素: \(wrong)")
        #expect(abs(pixels[50, 80].red - Self.once) <= 0.01)
        #expect(abs(pixels[80, 50].red - Self.once) <= 0.01)
    }

    // MARK: - 条件 3: 原始形 1 つ

    /// 丸い端は破線の両側へ太さの半分ずつはみ出す。間隔 (4) が太さ (10) より狭いので、隣の片に食い込む。
    @Test("破線の点どうしの食い込みは 1 回だけ混ぜる", arguments: [false, true])
    func bitingDashesMixOnce(rect: Bool) throws {
        let pixels = try translucent { canvas in
            canvas.strokeWeight(10)
            canvas.strokeCap(.round)
            canvas.strokeDash(12, 4)
            if rect {
                canvas.rect(30, 30, 100, 100)
            } else {
                canvas.beginShape()
                canvas.vertex(20, 80)
                canvas.vertex(140, 80)
                canvas.endShape()
            }
        }
        #expect(!painted(pixels).isEmpty)
        #expect(overpainted(pixels).isEmpty, "重ね塗り \(overpainted(pixels).count) 画素")
    }

    /// 穴の周が外周の線に太さより近いので、2 本の線の帯が重なる。
    @Test("外周と穴の線が接する所は 1 回だけ混ぜる")
    func outerAndHoleMixOnce() throws {
        let pixels = try translucent { canvas in
            canvas.strokeWeight(10)
            canvas.beginShape()
            canvas.vertex(30, 30)
            canvas.vertex(130, 30)
            canvas.vertex(130, 130)
            canvas.vertex(30, 130)
            canvas.beginContour()
            canvas.vertex(36, 36)
            canvas.vertex(36, 124)
            canvas.vertex(124, 124)
            canvas.vertex(124, 36)
            canvas.endContour()
            canvas.endShape(.close)
        }
        #expect(abs(pixels[33, 80].red - Self.once) <= 0.01, "外周と穴の間: \(pixels[33, 80].red)")
        #expect(overpainted(pixels).isEmpty, "重ね塗り \(overpainted(pixels).count) 画素")
    }

    /// 1 つの `beginShape(.quads)` の四角は 1 枚ずつ別の図形。辺の交わる 4 点 (砂時計) 2 枚を横にずらして
    /// 重ね、1 枚目の右の辺と 2 枚目の斜めの辺が交わる (100, 70) を見る。どちらの枚の交点からも太さより離れている。
    @Test("1 つの beginShape(.quads) の四角 2 枚は別々の図形で、重なりを 2 回混ぜる")
    func quadsOfOneShapeStaySeparate() throws {
        let sections = Box()
        let pixels = try translucent(sections: sections) { canvas in
            canvas.strokeWeight(6)
            canvas.beginShape(.quads)
            for shift in [Float(0), 30] {
                canvas.vertex(20 + shift, 20)
                canvas.vertex(100 + shift, 100)
                canvas.vertex(100 + shift, 20)
                canvas.vertex(20 + shift, 100)
            }
            canvas.endShape()
        }
        #expect(abs(pixels[100, 70].red - Self.twice) <= 0.01, "2 枚の重なり: \(pixels[100, 70].red)")
        #expect(abs(pixels[60, 60].red - Self.once) <= 0.01, "1 枚目の交点: \(pixels[60, 60].red)")
        #expect(abs(pixels[90, 60].red - Self.once) <= 0.01, "2 枚目の交点: \(pixels[90, 60].red)")
        #expect(sections.counts == [2], "区間: \(sections.counts)")
    }

    // MARK: - 条件 4・5: 型板に載せる線と載せない線

    /// 不透明の線は重ねても同じ色なので型板を通さない (描く呼び出しを増やさない)。
    @Test("不透明の線は区間を持たない")
    func opaqueStrokesTakeNoSection() throws {
        let sections = Box()
        _ = try render(sections: sections) { canvas in
            canvas.stroke(255, 0, 0)
            Self.crossingPolyline(canvas)
        }
        #expect(sections.counts == [0], "区間: \(sections.counts)")
    }

    /// 被覆 1 の `.replace` の線は、片を重ねても同じ値を書くので型板に載せない (#3579 の条件 5 の差し替え・
    /// 2026-11-03)。塗る画素は不透明の線と同じ集合で、色は一様。
    @Test("置き換えの線は区間を持たず、塗る画素は不透明の線と同じ")
    func replaceStrokesTakeNoSection() throws {
        let sections = Box()
        let replaced = try translucent(sections: sections) { canvas in
            canvas.blendMode(.replace)
            Self.crossingPolyline(canvas)
        }
        let opaque = try render { canvas in
            canvas.stroke(255, 0, 0)
            Self.crossingPolyline(canvas)
        }
        #expect(sections.counts == [0], "区間: \(sections.counts)")
        #expect(painted(replaced) == painted(opaque))
        #expect(abs(replaced[80, 80].red - replaced[30, 30].red) < 0.002)
    }

    // MARK: - 1 つの領域として引ける輪郭

    /// 矩形・楕円・弧は引き算で既に線全体が 1 回になるので、型板に載せずに引き算のまま積む。畳める形は
    /// 雛形が引き算で積むので、1 つ目を直に描くときも同じ積み方でないと、畳むかどうかで頂点の数と縁の
    /// 画素が変わる (`FlatInstancingTests`)。
    @Test("断片の効いた矩形と円は区間を持たず、角も刻みの継ぎ目も 1 回だけ混ぜる")
    func oneRegionOutlinesStayCarved() throws {
        let sections = Box()
        let pixels = try translucent(shaded: true, sections: sections) { canvas in
            canvas.strokeWeight(10)
            canvas.rect(20, 20, 40, 40)
            canvas.circle(110, 110, 50)
        }
        #expect(sections.counts.allSatisfy { $0 == 0 }, "区間: \(sections.counts)")
        #expect(abs(pixels[20, 40].red - Self.once) <= 0.01)
        #expect(overpainted(pixels).isEmpty, "重ね塗り \(overpainted(pixels).count) 画素")
    }

    /// 1 つの領域の輪郭も、破線なら片どうしが食い込むので型板に載る。
    @Test("破線の矩形は区間を持つ")
    func dashedRectTakesASection() throws {
        let sections = Box()
        _ = try translucent(shaded: true, sections: sections) { canvas in
            canvas.strokeWeight(10)
            canvas.strokeDash(12, 4)
            canvas.rect(20, 20, 100, 100)
        }
        #expect(sections.counts == [1], "区間: \(sections.counts)")
    }

    // MARK: - 細い線 (#1948)

    /// 細かさ 0.5 の面に描いて、描く画素 (80×80) を読む。既定の `strokeWeight(1)` は描く画素で 0.5 の細い線に
    /// なり、描く画素 1 つの太さへ広げて被覆を掛ける (#1637)。
    private func renderThin(
        shaded: Bool = false, sections: Box, _ body: (Canvas) -> Void
    ) throws -> PixelBuffer {
        let gpu = try RenderDevice()
        let output = try RenderTarget(gpu: gpu, width: 160, height: 160)
        let canvas = try Canvas(output: output, gpu: gpu, pixelDensity: 0.5, upscale: .spatial)
        let shader = shaded ? try canvas.makeShader(Self.passThrough) : nil
        try canvas.draw {
            canvas.background(black)
            canvas.noFill()
            canvas.strokeWeight(1)
            if let shader { canvas.shader(shader) }
            body(canvas)
            canvas.closeBatch()
            sections.counts = canvas.batches.filter { $0.source == .flat }.map(\.strokeStencilSections.count)
        }
        return try canvas.target.readPixels()
    }

    /// 赤の値の種類 (0.002 刻みに丸める)。塗られていない画素は数えない。
    private func redLevels(_ pixels: PixelBuffer) -> Set<Int> {
        var levels: Set<Int> = []
        for y in 0..<pixels.height {
            for x in 0..<pixels.width where pixels[x, y].red > 0.02 {
                levels.insert(Int((pixels[x, y].red / 0.002).rounded()))
            }
        }
        return levels
    }

    /// 細い片は被覆 1 未満なので、不透明の色でも重なると濃くなる。帯はどれも同じ太さで同じ被覆を持つので、
    /// 1 回だけ混ぜれば塗られた画素はどれも同じ値になる。交点が 2 回混ざると、そこだけ値が上がる。
    @Test("細い線は色によらず区間に入り、自己交差も 1 回だけ混ぜる", arguments: [Float(255), 128])
    func thinSelfCrossingMixesOnce(alpha: Float) throws {
        let sections = Box()
        let pixels = try renderThin(sections: sections) { canvas in
            canvas.stroke(255, 0, 0, alpha)
            canvas.beginShape()
            canvas.vertex(20, 20)
            canvas.vertex(140, 140)
            canvas.vertex(140, 20)
            canvas.vertex(20, 140)
            canvas.endShape()
        }
        #expect(sections.counts == [1], "区間: \(sections.counts)")
        let levels = redLevels(pixels)
        #expect(levels.count == 1, "塗られた画素の値: \(levels.sorted().map { Float($0) * 0.002 })")
    }

    /// 細い線でも、1 つの領域として引ける輪郭は引き算のまま (畳む雛形と揃える)。
    @Test("細い線の rect は区間を持たない")
    func thinRectStaysCarved() throws {
        let sections = Box()
        let pixels = try renderThin(shaded: true, sections: sections) { canvas in
            canvas.stroke(255, 0, 0)
            canvas.rect(20, 20, 100, 100)
        }
        #expect(sections.counts.allSatisfy { $0 == 0 }, "区間: \(sections.counts)")
        #expect(redLevels(pixels).count >= 1)
    }
}
