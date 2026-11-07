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

    /// 細い片は被覆 1 未満なので、不透明の色でも重なると濃くなる。交点 (80, 80) で交わる 2 本はどちらも 45° の
    /// 帯で同じ被覆を持つので、1 回だけ混ぜれば交点も帯 1 本ぶんの値を越えない。2 回混ざると、そこだけ
    /// 値が上がる。縦の帯は被覆が違う (帯ごとの被覆は向きで決まる・#2172) ので、比べるのは 45° の帯の値。
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
        // 45° の帯 1 本ぶんの値: 交点と縦の帯から離れた所 (描く画素の x < 30) の明るさの最大
        var band: Float = 0
        var brightest: Float = 0
        for y in 0..<pixels.height {
            for x in 0..<pixels.width {
                brightest = max(brightest, pixels[x, y].red)
                if x < 30 { band = max(band, pixels[x, y].red) }
            }
        }
        #expect(band > 0.02)
        #expect(brightest <= band + 0.004, "帯 \(band)・いちばん明るい画素 \(brightest)")
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

    // MARK: - 畳んだ雛形の細い輪郭 (#3733)

    /// 細い輪郭の矩形を、回さずに 1 つと 45° に回して 1 つ置く。雛形は回さない 1 つ目の向きで組まれ、2 つ目は
    /// 雛形から置かれて頂点段で広げ直す。
    private static func rotatedRects(
        _ canvas: Canvas, quads: Bool, turns: (Float, Float) = (0, Float.pi / 4)
    ) {
        for (center, turn) in [(SIMD2<Float>(40, 40), turns.0), (SIMD2<Float>(110, 100), turns.1)] {
            canvas.pushMatrix()
            canvas.translate(center.x, center.y)
            canvas.rotate(turn)
            if quads {
                canvas.quad(-20, -10, 20, -10, 20, 10, -20, 10)
            } else {
                canvas.rect(-20, -10, 40, 20)
            }
            canvas.popMatrix()
        }
    }

    /// 雛形の片は、置き場所ごとに組み直しても重ならない。半透明の色で描いて、矩形ごとに、塗られた画素が 1 回ぶんの
    /// 値を越えない (回さない矩形と 45° の矩形は被覆が違う — 帯の被覆は向きで決まる・#2172)。描く画素 (80×80) の
    /// x < 38 が 1 つ目、それより右が 2 つ目。
    ///
    /// 帯の端の列は、角を越えて延ばしたぶんを打ち消すため被覆が下がる (#3788・``Canvas/thinRectPiece(corners:crossings:coverage:piece:vertex:)``)
    /// ので、値は 1 つではない。重なれば `a + a(1 − a)` のように帯の値を越えるので、いちばん多い値 (帯の値) が
    /// 最大であることを見る。
    @Test("畳んだ回した細い rect の輪郭は、半透明の色でも角を重ねて混ぜない")
    func foldedRotatedThinRectMixesOnce() throws {
        let sections = Box()
        let pixels = try renderThin(shaded: true, sections: sections) { canvas in
            canvas.stroke(255, 0, 0, 128)
            Self.rotatedRects(canvas, quads: false)
        }
        for (name, columns) in [("回さない 1 つ目", 0..<38), ("45° の 2 つ目 (雛形)", 38..<pixels.width)] {
            var levels: [Int: Int] = [:]
            for y in 0..<pixels.height {
                for x in columns where pixels[x, y].red > 0.01 {
                    levels[Int((pixels[x, y].red / 0.002).rounded()), default: 0] += 1
                }
            }
            let band = levels.max { $0.value < $1.value }?.key
            #expect(
                band != nil && band == levels.keys.max(),
                "\(name) の塗られた画素の値と数: \(levels.sorted { $0.key < $1.key }.map { (Float($0.key) * 0.002, $0.value) })")
        }
    }

    /// 幾何の等しい図形は、呼び方 (畳む `rect` / 畳まない `quad`) によらず同じ光の量で出る。雛形は 1 つ目の向きで
    /// 組まれるので、1 つ目を回さない組 (2 つ目で n = 2 側へ広げ直す) と、1 つ目を回した組 (2 つ目で回さない向き・
    /// 別の角度へ広げ直す) の両方を見る。
    @Test(
        "畳んだ回した細い rect の輪郭と、同じ 4 点の quad の輪郭は同じ光の量で出る",
        arguments: [(Float(0), Float.pi / 4), (Float.pi / 4, Float(0)), (Float.pi / 4, Float(0.3))] as [(Float, Float)])
    func foldedRotatedThinRectMatchesQuad(first: Float, second: Float) throws {
        func light(_ quads: Bool) throws -> Float {
            let pixels = try renderThin(shaded: true, sections: Box()) { canvas in
                canvas.stroke(255, 0, 0)
                Self.rotatedRects(canvas, quads: quads, turns: (first, second))
            }
            var sum: Float = 0
            for y in 0..<pixels.height { for x in 0..<pixels.width { sum += pixels[x, y].red } }
            return sum
        }
        let (rects, quads) = (try light(false), try light(true))
        #expect(quads > 0)
        #expect(abs(rects - quads) <= quads * 0.01, "rect \(rects)・quad \(quads)")
    }

    /// 矩形以外の畳める形 (楕円・円・弧) は向きごとに畳む (#3733)。同じ向きで 2 つ置くと 2 つ目は雛形から置かれ、
    /// 1 つだけ直に置いた同じ円と同じ光の量で出る。違う向きの 2 つ目は別の雛形になる。
    @Test("回した細い輪郭の円は、畳んだ 2 つ目も直に置いた 1 つ目と同じ光の量で出て、違う向きでは別の雛形になる")
    func foldedRotatedThinCircleMatchesDirect() throws {
        func light(_ body: (Canvas) -> Void) throws -> (Float, Int) {
            let gpu = try RenderDevice()
            let output = try RenderTarget(gpu: gpu, width: 160, height: 160)
            let canvas = try Canvas(output: output, gpu: gpu, pixelDensity: 0.5, upscale: .spatial)
            let shader = try canvas.makeShader(Self.passThrough)
            var instances = 0
            try canvas.draw {
                canvas.background(black)
                canvas.noFill()
                canvas.strokeWeight(1)
                canvas.stroke(255, 0, 0)
                canvas.shader(shader)
                body(canvas)
                instances = canvas.flatInstances.count
            }
            let pixels = try canvas.target.readPixels()
            var sum: Float = 0
            for y in 0..<pixels.height { for x in 0..<pixels.width { sum += pixels[x, y].red } }
            return (sum, instances)
        }
        func circle(_ canvas: Canvas, _ x: Float, _ turn: Float) {
            canvas.pushMatrix()
            canvas.translate(x, 80)
            canvas.rotate(turn)
            canvas.ellipse(0, 0, 50, 30)
            canvas.popMatrix()
        }
        // 置き場所の並びは、何も動かさない置き場所 (添字 0) から始まる。直に置いた回の数を基準にする
        let (direct, baseInstances) = try light { circle($0, 110, 0.7) }
        let (folded, foldedInstances) = try light { canvas in
            circle(canvas, 400, 0.7)  // 面の外の 1 つ目
            circle(canvas, 110, 0.7)
        }
        let (_, turnedInstances) = try light { canvas in
            circle(canvas, 40, 0.7)
            circle(canvas, 110, 0.3)
        }
        #expect(foldedInstances == baseInstances + 2, "同じ向きの 2 つ目が畳まれていない: \(foldedInstances)")
        #expect(turnedInstances == baseInstances, "違う向きの 2 つ目が同じ雛形に畳まれた: \(turnedInstances)")
        #expect(direct > 0)
        #expect(abs(folded - direct) <= direct * 0.01, "畳んだ \(folded)・直に置いた \(direct)")
    }

    // MARK: - 保持した形と道 (#3580)

    /// 置き場所で掛ける半透明の白。不透明度は `stroke(255, 0, 0, 128)` と同じ 128/255。
    private static let veil: LinearRGBA = {
        let alpha = Float(128) / 255
        return LinearRGBA(premultipliedRed: alpha, green: alpha, blue: alpha, alpha: alpha)
    }()

    /// 形を前のフレームで組み (`build`)、黒地へ置き場所を渡して置く。
    private func placed(
        sections: Box? = nil, _ build: (Canvas) -> Shape, at placements: [Placement]
    ) throws -> PixelBuffer {
        let canvas = try CanvasFixture.make(gpu: RenderDevice(), width: 160, height: 160)
        var shape = Shape.empty
        try canvas.draw { shape = build(canvas) }
        try canvas.draw {
            canvas.background(black)
            canvas.shape(shape, at: placements)
            canvas.closeBatch()
            sections?.counts = canvas.batches.filter { $0.source == .flat }.map(\.strokeStencilSections.count)
        }
        return try canvas.target.readPixels()
    }

    /// 自分と交わる折れ線を記録した形。`translucent` なら半透明の赤、そうでなければ不透明の赤で記録する。
    private static func crossingShape(_ canvas: Canvas, translucent: Bool) -> Shape {
        canvas.createShape {
            canvas.noFill()
            if translucent { canvas.stroke(255, 0, 0, 128) } else { canvas.stroke(255, 0, 0) }
            crossingPolyline(canvas)
        }
    }

    /// 半透明で記録した形を置くときも、不透明で記録して置き場所で半透明の色を掛けるときも、自己交差は 1 回。
    @Test("保持した形の自分と交わる折れ線は、交点も 1 回だけ混ぜる", arguments: [false, true])
    func retainedSelfCrossingMixesOnce(tinted: Bool) throws {
        let sections = Box()
        let pixels = try placed(
            sections: sections, { Self.crossingShape($0, translucent: !tinted) },
            at: [Placement(fill: tinted ? Self.veil : nil)])
        #expect(abs(pixels[80, 80].red - Self.once) <= 0.01, "交点: \(pixels[80, 80].red)")
        #expect(overpainted(pixels).isEmpty, "重ね塗り \(overpainted(pixels).count) 画素")
        #expect(sections.counts == [1], "区間: \(sections.counts)")
    }

    /// 同じ形を 2 か所に置くと別々の図形で、2 つ目の 3 本目の辺が 1 つ目の 1 本目の辺と (95, 95) で交わる所は
    /// 2 回混ぜる。入れ子に記録した形 (外側の記録へ置き直した線) も、置くときに 1 回になる。
    @Test("保持した形を 2 か所に置くと重なりは 2 回、入れ子に記録しても交点は 1 回")
    func retainedPlacementsStaySeparateFigures() throws {
        let twice = try placed(
            { Self.crossingShape($0, translucent: true) }, at: [Placement(), Placement(x: 30)])
        #expect(abs(twice[95, 95].red - Self.twice) <= 0.01, "2 つの置き場所の重なり: \(twice[95, 95].red)")
        #expect(abs(twice[80, 80].red - Self.once) <= 0.01, "1 つ目の交点: \(twice[80, 80].red)")
        let nested = try placed(
            { canvas in
                let inner = Self.crossingShape(canvas, translucent: true)
                return canvas.createShape { canvas.shape(inner) }
            }, at: [Placement()])
        #expect(abs(nested[80, 80].red - Self.once) <= 0.01, "入れ子の交点: \(nested[80, 80].red)")
        #expect(overpainted(nested).isEmpty, "入れ子の重ね塗り \(overpainted(nested).count) 画素")
    }

    /// 置いた後に細くなる保持した形も、細い片の重なりを型板で 1 回にする (段 5 と同じ)。
    @Test("縮めて置いて細くなった保持した形の自己交差も 1 回だけ混ぜる")
    func retainedThinSelfCrossingMixesOnce() throws {
        let sections = Box()
        let pixels = try placed(
            sections: sections,
            { canvas in
                canvas.createShape {
                    canvas.noFill()
                    canvas.stroke(255, 0, 0)
                    canvas.strokeWeight(1)
                    canvas.beginShape()
                    canvas.vertex(20, 20)
                    canvas.vertex(140, 140)
                    canvas.vertex(140, 20)
                    canvas.vertex(20, 140)
                    canvas.endShape()
                }
            }, at: [Placement(scale: 0.5)])
        #expect(sections.counts == [1], "区間: \(sections.counts)")
        // 45° の帯 1 本ぶんの値と比べる (``thinSelfCrossingMixesOnce`` と同じ見方。縮めた交点は (40, 40))
        var band: Float = 0
        var brightest: Float = 0
        for y in 0..<pixels.height {
            for x in 0..<pixels.width {
                brightest = max(brightest, pixels[x, y].red)
                if x < 30 { band = max(band, pixels[x, y].red) }
            }
        }
        #expect(band > 0.02)
        #expect(brightest <= band + 0.004, "帯 \(band)・いちばん明るい画素 \(brightest)")
    }

    /// 道 (`Path`) の線は、部分道をまとめて 1 つの図形 (2026-11-04 の決定)。2 つの部分道が交わる所は 1 回、別々の
    /// 道どうしは 2 回。
    @Test("道の部分道どうしの交わりは 1 回、別々の道どうしは 2 回")
    func pathSubpathsFormOneFigure() throws {
        func cross(_ canvas: Canvas) -> Path {
            canvas.createPath {
                canvas.beginShape()
                canvas.vertex(40, 80)
                canvas.vertex(120, 80)
                canvas.endShape()
                canvas.beginShape()
                canvas.vertex(80, 40)
                canvas.vertex(80, 120)
                canvas.endShape()
            }
        }
        let one = try translucent { canvas in
            canvas.strokeWeight(10)
            canvas.strokeCap(.square)
            canvas.shape(cross(canvas))
        }
        #expect(abs(one[80, 80].red - Self.once) <= 0.01, "部分道の交わり: \(one[80, 80].red)")
        #expect(overpainted(one).isEmpty, "重ね塗り \(overpainted(one).count) 画素")
        let two = try translucent { canvas in
            canvas.strokeWeight(10)
            canvas.strokeCap(.square)
            canvas.shape(cross(canvas))
            canvas.shape(cross(canvas), 30, 0)
        }
        // 2 つ目の縦の線 (x = 110) が 1 つ目の横の線 (y = 80) と交わる所
        #expect(abs(two[110, 80].red - Self.twice) <= 0.01, "別々の道の交わり: \(two[110, 80].red)")
    }

    /// 一様でない拡大で一部の輪郭だけが細くなっても、図形を割らない (その場で描くときと同じく、輪郭が 1 つでも
    /// 型板に入るなら図形全体を 1 つの区間にする・#3580 の反証)。縦に 1/20 へ潰して置くと、横の部分道は細く
    /// (被覆を持つ片に組み直され)、縦の部分道は太いまま。横の部分道を 2 本重ねても、間に縦の部分道が挟まって
    /// いても 1 回だけ混ぜる。
    @Test("一部の輪郭だけが細くなる置き方でも、図形全体を 1 つの区間に入れる")
    func partlyThinFigureStaysOneSection() throws {
        func recorded(repeats: Bool) -> (Canvas) -> Shape {
            { canvas in
                let path = canvas.createPath {
                    canvas.beginShape()
                    canvas.vertex(20, 80)
                    canvas.vertex(140, 80)
                    canvas.endShape()
                    canvas.beginShape()
                    canvas.vertex(100, 20)
                    canvas.vertex(100, 140)
                    canvas.endShape()
                    if repeats {
                        canvas.beginShape()
                        canvas.vertex(20, 80)
                        canvas.vertex(140, 80)
                        canvas.endShape()
                    }
                }
                return canvas.createShape {
                    canvas.noFill()
                    canvas.stroke(255, 0, 0)
                    canvas.strokeWeight(10)
                    canvas.strokeCap(.square)
                    canvas.shape(path)
                }
            }
        }
        let squash = [Placement(y: 76, scale: Vector3(1, 0.05, 1))]
        let single = try placed(recorded(repeats: false), at: squash)
        let sections = Box()
        let doubled = try placed(sections: sections, recorded(repeats: true), at: squash)
        #expect(sections.counts.reduce(0, +) == 1, "区間: \(sections.counts)")
        var lit = 0
        for y in 77...83 {
            for x in 30..<80 {
                if single[x, y].red > 0.01 { lit += 1 }
                #expect(
                    abs(doubled[x, y].red - single[x, y].red) <= 0.002,
                    "(\(x), \(y)): 重ねた \(doubled[x, y].red)・1 本 \(single[x, y].red)")
            }
        }
        #expect(lit > 0, "細い横の部分道が描かれていない")
    }

    /// 畳んだ雛形は引き算のまま (型板の外)。1 つの図形の中は 1 回、重なる 2 つの図形どうしは 2 回。
    @Test("畳んだ雛形の半透明の線は、1 つの中は 1 回、重なる 2 つは 2 回")
    func foldedTemplateMixesOncePerFigure() throws {
        let sections = Box()
        let pixels = try translucent(shaded: true, sections: sections) { canvas in
            canvas.strokeWeight(10)
            canvas.rect(30, 30, 60, 60)
            canvas.rect(60, 60, 60, 60)
        }
        #expect(sections.counts.allSatisfy { $0 == 0 }, "区間: \(sections.counts)")
        #expect(abs(pixels[30, 30].red - Self.once) <= 0.01, "角: \(pixels[30, 30].red)")
        // 1 つ目の右の辺 (x = 90) と 2 つ目の上の辺 (y = 60) の交わり
        #expect(abs(pixels[90, 60].red - Self.twice) <= 0.01, "2 つの重なり: \(pixels[90, 60].red)")
    }
}
