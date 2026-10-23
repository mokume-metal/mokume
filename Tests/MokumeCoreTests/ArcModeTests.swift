// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation
import Testing

@testable import MokumeCore

/// 円弧の閉じ方 (`ArcMode`) の検査 ([#2428])。GPU を要する。
///
/// 引数に渡さない `arc` は、**塗りが扇・輪郭が開いた弧** (Processing・p5.js の既定と同じ) で、
/// 輪郭が中心へ半径を引かない。`.pie` は塗りも輪郭も扇 (変更前の既定と同じ絵)、`.chord` は弧の両端を
/// 弦で結んだ形、`.open` は輪郭を閉じず塗りだけが弦で結んだ形になる。
///
/// 経路は 2 つある。**距離関数の経路** (既定) と、**三角形の経路** (`shader()` を付ける)。どちらでも
/// 同じ場所に同じ色が載ることを見る。
///
/// [#2428]: https://github.com/mokume-metal/mokume/issues/2428
@Suite(
    "円弧の閉じ方",
    .enabled(
        if: RenderDevice.isAvailable,
        "この世代のコマンド構造に対応した GPU が無い実行環境ではスキップする")
)
struct ArcModeTests {
    private let black = LinearRGBA.linear(red: 0, green: 0, blue: 0)
    private let white = LinearRGBA.linear(red: 1, green: 1, blue: 1)

    enum Route: CaseIterable, CustomStringConvertible {
        case distanceField
        case triangles
        var description: String { self == .distanceField ? "距離関数の経路" : "三角形の経路" }
    }

    private func makeCanvas() throws -> Canvas {
        try CanvasFixture.make(gpu: RenderDevice(), width: 128, height: 128)
    }

    /// 黒地に描いて、出力段を通した画素を返す。三角形の経路は、組み込みの色を返すだけの断片を付けて作る。
    private func picture(_ route: Route, _ body: (Canvas) -> Void) throws -> DisplayImage {
        let canvas = try makeCanvas()
        var failure: (any Error)?
        try canvas.draw {
            canvas.background(black)
            if route == .triangles {
                do {
                    canvas.shader(
                        try canvas.makeShader(
                            "float4 paint(Fragment in, Values values) { return in.color; }"))
                } catch { failure = error }
            }
            body(canvas)
        }
        if let failure { throw failure }
        return try canvas.target.encodeForDisplay()
    }

    private func isWhite(_ image: DisplayImage, _ x: Int, _ y: Int) -> Bool { image[x, y].red > 200 }
    private func isBlack(_ image: DisplayImage, _ x: Int, _ y: Int) -> Bool { image[x, y].red < 40 }

    // MARK: - 既定の輪郭は開いた弧

    /// 完了条件 1。下半分の弧 (0…π) で、中心 (64, 64) も半径の途中 (84, 64) も輪郭の外にある。
    /// 変更前は、2 点とも扇の枠 (中心から弧の端へ引いた直径) の帯に入って白が載った。
    @Test("引数なしの輪郭は開いた弧で、中心にも半径の途中にも載らず、弧の上に載る", arguments: Route.allCases)
    func defaultOutlineIsAnOpenArc(_ route: Route) throws {
        let image = try picture(route) { canvas in
            canvas.noFill()
            canvas.stroke(white)
            canvas.strokeWeight(8)
            canvas.arc(64, 64, 80, 80, 0, Float.pi)
        }
        #expect(isBlack(image, 64, 64), "\(route): 中心に輪郭が載っている")
        #expect(isBlack(image, 84, 64), "\(route): 半径の途中に輪郭が載っている")
        #expect(isWhite(image, 64, 104), "\(route): 弧の上に輪郭が無い")
        #expect(isWhite(image, 28, 82), "\(route): 弧の上 (左寄り) に輪郭が無い")
    }

    /// 完了条件 2。塗りだけの絵は、`.pie` と引数なしで 1 ビットも違わない (扇のまま)。
    @Test("引数なしの塗りは扇のままで、塗りだけなら `.pie` と同じ絵になる", arguments: Route.allCases)
    func defaultFillIsAPie(_ route: Route) throws {
        func fillOnly(_ mode: ArcMode?) throws -> DisplayImage {
            try picture(route) { canvas in
                canvas.noStroke()
                canvas.fill(white)
                if let mode { canvas.arc(64, 64, 80, 80, 0.4, 4.2, mode) } else { canvas.arc(64, 64, 80, 80, 0.4, 4.2) }
            }
        }
        let byDefault = try fillOnly(nil)
        #expect(byDefault.bytes == (try fillOnly(.pie)).bytes)
        #expect(isWhite(byDefault, 64, 64), "中心が塗られていない")
        #expect(isBlack(byDefault, 100, 40), "欠けた側が塗られている")
    }

    @Test("輪郭の付いた引数なしの扇は、塗りが扇のまま、中心の側に輪郭の半径が出ない", arguments: Route.allCases)
    func defaultKeepsTheFanFillUnderTheOpenOutline(_ route: Route) throws {
        let image = try picture(route) { canvas in
            canvas.fill(.display(red: 0, green: 0, blue: 1))
            canvas.stroke(.display(red: 1, green: 0, blue: 0))
            canvas.strokeWeight(6)
            canvas.arc(64, 64, 80, 80, Float.pi * 0.25, Float.pi * 0.75)
        }
        // 扇の内側 (中心の少し下) は塗りの青。中心から弧の端への半径の途中も、輪郭の赤ではなく青
        #expect(image[64, 76].blue > 200 && image[64, 76].red < 60, "\(route): 扇の塗りが無い")
        #expect(image[50, 78].blue > 200 && image[50, 78].red < 60, "\(route): 半径の上に輪郭が載っている")
        // 弧の上は輪郭の赤
        #expect(image[64, 104].red > 200, "\(route): 弧の上に輪郭が無い")
    }

    // MARK: - 閉じ方

    /// 弧 π/4…3π/4。両端は (35.7, 92.3) と (92.3, 92.3) で、弦は y = 92.3 を水平に渡る。
    private func shortArc(_ canvas: Canvas, _ mode: ArcMode?) {
        if let mode {
            canvas.arc(64, 64, 80, 80, Float.pi * 0.25, Float.pi * 0.75, mode)
        } else {
            canvas.arc(64, 64, 80, 80, Float.pi * 0.25, Float.pi * 0.75)
        }
    }

    /// 完了条件 3: `.pie` は扇の枠で、変更前の既定と同じ。中心にも、中心から弧の端への半径にも輪郭が載る。
    @Test("`.pie` の輪郭は扇の枠 (中心と 2 本の半径が出る)", arguments: Route.allCases)
    func pieOutlineIsTheFanFrame(_ route: Route) throws {
        let image = try picture(route) { canvas in
            canvas.noFill()
            canvas.stroke(white)
            canvas.strokeWeight(6)
            shortArc(canvas, .pie)
        }
        #expect(isWhite(image, 64, 64), "\(route): 中心に輪郭が無い")
        #expect(isWhite(image, 50, 78), "\(route): 半径の上に輪郭が無い")
        #expect(isWhite(image, 64, 104), "\(route): 弧の上に輪郭が無い")
        #expect(isBlack(image, 64, 92), "\(route): 弦の位置に輪郭が載っている")
    }

    @Test("`.chord` の輪郭は弦で閉じた形で、中心へ半径を引かない", arguments: Route.allCases)
    func chordOutlineClosesWithAChord(_ route: Route) throws {
        let image = try picture(route) { canvas in
            canvas.noFill()
            canvas.stroke(white)
            canvas.strokeWeight(6)
            shortArc(canvas, .chord)
        }
        #expect(isWhite(image, 64, 92), "\(route): 弦の上に輪郭が無い")
        #expect(isWhite(image, 64, 104), "\(route): 弧の上に輪郭が無い")
        #expect(isBlack(image, 64, 64), "\(route): 中心に輪郭が載っている")
        #expect(isBlack(image, 50, 78), "\(route): 半径の上に輪郭が載っている")
    }

    @Test("`.chord` の塗りは、弧と弦に挟まれた形だけを塗る", arguments: Route.allCases)
    func chordFillIsTheSegment(_ route: Route) throws {
        let image = try picture(route) { canvas in
            canvas.noStroke()
            canvas.fill(white)
            shortArc(canvas, .chord)
        }
        #expect(isWhite(image, 64, 98), "\(route): 弦と弧の間が塗られていない")
        #expect(isBlack(image, 64, 80), "\(route): 弦の上 (扇の側) が塗られている")
        #expect(isBlack(image, 64, 64), "\(route): 中心が塗られている")
    }

    @Test("`.open` の輪郭は閉じず、塗りは弦で結んだ形になる (扇ではない)", arguments: Route.allCases)
    func openLeavesTheOutlineOpenAndFillsTheSegment(_ route: Route) throws {
        let outline = try picture(route) { canvas in
            canvas.noFill()
            canvas.stroke(white)
            canvas.strokeWeight(6)
            shortArc(canvas, .open)
        }
        #expect(isWhite(outline, 64, 104), "\(route): 弧の上に輪郭が無い")
        #expect(isBlack(outline, 64, 92), "\(route): 弦の位置に輪郭が載っている (閉じている)")
        #expect(isBlack(outline, 64, 64), "\(route): 中心に輪郭が載っている")

        let fill = try picture(route) { canvas in
            canvas.noStroke()
            canvas.fill(white)
            shortArc(canvas, .open)
        }
        #expect(isWhite(fill, 64, 98), "\(route): 弦と弧の間が塗られていない")
        #expect(isBlack(fill, 64, 80), "\(route): 手本の `OPEN` の塗りは弦で閉じた形で、扇ではない")
    }

    /// 一周は、どの閉じ方でも楕円と同じ (中心から端への半径も弦も出ない)。
    @Test("一周の円弧は、どの閉じ方でも楕円と同じ絵になる", arguments: Route.allCases)
    func aFullTurnIsAnEllipse(_ route: Route) throws {
        func draw(_ body: @escaping (Canvas) -> Void) throws -> DisplayImage {
            try picture(route) { canvas in
                canvas.fill(.display(red: 0, green: 0, blue: 1))
                canvas.stroke(.display(red: 1, green: 0, blue: 0))
                canvas.strokeWeight(5)
                body(canvas)
            }
        }
        let reference = try draw { $0.ellipse(64, 64, 80, 80) }
        for mode in [nil, .open, .chord, .pie] as [ArcMode?] {
            let image = try draw { canvas in
                if let mode { canvas.arc(64, 64, 80, 80, 0, 2 * Float.pi, mode) } else { canvas.arc(64, 64, 80, 80, 0, 2 * Float.pi) }
            }
            #expect(image.bytes == reference.bytes, "\(route): \(String(describing: mode)) が楕円と違う")
        }
    }

    // MARK: - 開いた弧の端・破線

    /// 開いた弧の輪郭の端には、`strokeCap` の端の形が付く。弧 0…π/2 の始まりは (94, 64) で、接線は
    /// 縦 (画面の下向きへ進む)。始まりの外側 (上) へ太さの半分だけはみ出すのは `.project` だけ。
    @Test("開いた弧の端は、端の形に従う", arguments: Route.allCases)
    func openArcEndsFollowTheStrokeCap(_ route: Route) throws {
        func render(_ cap: StrokeCap) throws -> DisplayImage {
            try picture(route) { canvas in
                canvas.noFill()
                canvas.stroke(white)
                canvas.strokeWeight(12)
                canvas.strokeCap(cap)
                canvas.arc(64, 64, 60, 60, 0, Float.pi / 2)
            }
        }
        let butt = try render(.square)
        let project = try render(.project)
        // 始まり (94, 64) の上 (画面の上向き) 4 画素
        #expect(isBlack(butt, 94, 60), "長さちょうどで切る端がはみ出している")
        #expect(isWhite(project, 94, 60), "はみ出す端がはみ出していない")
        // 弧そのものの上は、どちらも白
        #expect(isWhite(butt, 94, 70) && isWhite(project, 94, 70))
    }

    @Test("開いた弧の輪郭は、破線にもできる", arguments: Route.allCases)
    func openArcCanBeDashed(_ route: Route) throws {
        func painted(dash: Bool) throws -> Int {
            let image = try picture(route) { canvas in
                canvas.noFill()
                canvas.stroke(white)
                canvas.strokeWeight(4)
                canvas.strokeCap(.square)
                if dash { canvas.strokeDash(6, 6) }
                canvas.arc(64, 64, 100, 100, 0, Float.pi)
            }
            var count = 0
            for y in 0..<128 { for x in 0..<128 where image[x, y].red > 128 { count += 1 } }
            return count
        }
        let solid = try painted(dash: false)
        let dashed = try painted(dash: true)
        #expect(dashed > 0)
        #expect(dashed < solid * 3 / 4, "破線が実線と同じだけ塗っている (\(dashed) / \(solid))")
    }

    // MARK: - 距離関数の経路: 縁の AA・1 つの断片・1 列 (#2428)

    private func drawFrame(_ body: (Canvas) -> Void) throws -> (canvas: Canvas, pixels: PixelBuffer) {
        let canvas = try makeCanvas()
        try canvas.draw {
            canvas.background(black)
            body(canvas)
        }
        return (canvas, try canvas.target.readPixels())
    }

    /// 縁が中間値になっている画素 (被覆 5%〜95%) を数える。
    private func partialPixels(_ pixels: PixelBuffer) -> Int {
        var count = 0
        for y in 0..<pixels.height {
            for x in 0..<pixels.width {
                let value = pixels[x, y].red
                if value > 0.05 && value < 0.95 { count += 1 }
            }
        }
        return count
    }

    private func ink(_ pixels: PixelBuffer) -> Double {
        var sum = 0.0
        for y in 0..<pixels.height { for x in 0..<pixels.width { sum += Double(pixels[x, y].red) } }
        return sum
    }

    /// 反証 1: 引数なしの arc (ほぼすべての arc) の輪郭の縁が、画素の格子に丸まらず滑らかに出る。
    /// 帯の両縁に沿って中間値の画素が並ぶ — 半径 40 の半円の弧は長さ約 126、両縁で 250 画素ほど。
    @Test("開いた弧と弦の輪郭は、縁が滑らかに出る (引数なし・`.open`・`.chord`)", arguments: [nil, .open, .chord] as [ArcMode?])
    func outlineEdgesAreAntialiased(_ mode: ArcMode?) throws {
        let (_, pixels) = try drawFrame { canvas in
            canvas.noFill()
            canvas.stroke(white)
            canvas.strokeWeight(6)
            if let mode { canvas.arc(64.3, 64.6, 80, 80, 0, Float.pi, mode) } else { canvas.arc(64.3, 64.6, 80, 80, 0, Float.pi) }
        }
        #expect(partialPixels(pixels) > 200, "縁の中間値の画素が少ない (\(partialPixels(pixels)))")
    }

    /// 開いた弧の帯が覆う光の量は、帯の面積に一致し、置く位置の小数部で揺れない (縁を面積で数える約束)。
    /// 丸い端: 面積 = 太さ × 弧の長さ + 円 1 つぶん (両端の半円)。太さ 6 の太い帯と、1 画素未満の細い帯の両方。
    @Test("開いた弧の帯の光の量は、帯の面積に合い、置く位置で揺れない", arguments: [Float(6), 0.5])
    func openBandConservesLight(_ weight: Float) throws {
        let radius: Float = 36
        let length = Double(radius) * Double.pi
        let area = Double(weight) * length + Double.pi * Double(weight / 2) * Double(weight / 2)
        var measured: [Double] = []
        for offset: Float in [0, 0.25, 0.5, 0.75] {
            let (_, pixels) = try drawFrame { canvas in
                canvas.noFill()
                canvas.stroke(white)
                canvas.strokeWeight(weight)
                canvas.arc(64 + offset, 50 + offset * 0.7, 2 * radius, 2 * radius, 0, Float.pi)
            }
            measured.append(ink(pixels))
        }
        for value in measured {
            #expect(abs(value - area) / area < 0.03, "光の量 \(value) が帯の面積 \(area) と合わない")
        }
        let spread = (measured.max() ?? 0) - (measured.min() ?? 0)
        #expect(spread / area < 0.01, "置く位置で光の量が揺れる (\(measured))")
    }

    /// 反証 3: 閉じ方の違う arc を、他の図形と混ぜても 1 列・三角形無し (N 個で 1 回の描画)。
    @Test("閉じ方の違う arc を他の図形と混ぜても、1 列に収まる")
    func closuresShareOneDrawCall() throws {
        let canvas = try makeCanvas()
        try canvas.draw {
            canvas.background(black)
            for index in 0..<64 {
                let step = Float(index)
                canvas.push()
                canvas.translate(8 + step.truncatingRemainder(dividingBy: 8) * 14, 8 + (step / 8).rounded(.down) * 14)
                canvas.fill(.linear(red: step / 64, green: 0.5, blue: 1 - step / 64))
                canvas.stroke(.linear(red: 1, green: step / 64, blue: 0))
                canvas.strokeWeight(1 + step * 0.04)
                canvas.strokeCap([.round, .square, .project][index % 3])
                switch index % 6 {
                case 0: canvas.arc(0, 0, 9, 7, 0.2, 2 + step * 0.02)
                case 1: canvas.arc(0, 0, 9, 7, 0.2, 2 + step * 0.02, .pie)
                case 2: canvas.arc(0, 0, 9, 7, 0.2, 2 + step * 0.02, .chord)
                case 3: canvas.arc(0, 0, 9, 7, 0.2, 2 + step * 0.02, .open)
                case 4: canvas.circle(0, 0, 6 + step * 0.05)
                default: canvas.rect(0, 0, 6 + step * 0.05, 4)
                }
                canvas.pop()
            }
        }
        #expect(canvas.drawCallsInLastFrame == 1, "閉じ方か端の形で列が分かれている")
        #expect(canvas.flatOutlinesInLastFrame == 0, "三角形の経路で輪郭を組んでいる")
    }

    // MARK: - 保持した形

    /// 反証 3: 保持した円弧は、どの閉じ方でも置き場所 1 つで、頂点も輪郭の区間も持たない (`createShape` の
    /// 区間が三角形に割れていない)。置くときの費用が閉じ方によらず同じになる。
    @Test("保持した円弧は、どの閉じ方も基本図形 1 つで、頂点も輪郭の区間も持たない", arguments: [nil, .open, .chord, .pie] as [ArcMode?])
    func retainedArcIsOneForm(_ mode: ArcMode?) throws {
        let canvas = try makeCanvas()
        let shape = canvas.createShape {
            canvas.fill(white)
            canvas.stroke(white)
            canvas.strokeWeight(3)
            if let mode { canvas.arc(0, 0, 40, 40, 0.3, 3.5, mode) } else { canvas.arc(0, 0, 40, 40, 0.3, 3.5) }
        }
        #expect(shape.forms.count == 1)
        #expect(shape.vertices.isEmpty)
        #expect(shape.strokeRanges.isEmpty)
    }

    /// 完了条件 (残り 5)。`createShape` の中の円弧は、閉じ方ごとの周 (``Canvas/Outline/Ring/Piece``) を
    /// 記録して、置くときの拡大で刻み直す。拡大して置いた絵が、拡大せずに直に描いた絵と同じになる。
    /// 刻み直しが閉じ方を落とすと、扇や弦の形が別の閉じ方の形で出る。
    @Test(
        "保持した円弧は、拡大して置いても、閉じ方ごとに拡大しない円弧と同じ絵になる",
        arguments: [nil, .open, .chord, .pie] as [ArcMode?], Route.allCases)
    func retainedArcMatchesDirectOne(_ mode: ArcMode?, _ route: Route) throws {
        func arc(_ canvas: Canvas, _ x: Float, _ y: Float, _ size: Float) {
            let (start, stop) = (Float.pi * 0.2, Float.pi * 1.4)
            if let mode {
                canvas.arc(x, y, size, size, start, stop, mode)
            } else {
                canvas.arc(x, y, size, size, start, stop)
            }
        }
        func style(_ canvas: Canvas, weight: Float) {
            canvas.fill(LinearRGBA.linear(red: 0.2, green: 0.2, blue: 0.2))
            canvas.stroke(white)
            canvas.strokeWeight(weight)
        }
        let retained = try picture(route) { canvas in
            style(canvas, weight: 0.5)
            let shape = canvas.createShape { arc(canvas, 4, 4, 4) }
            canvas.scale(20, 20)
            canvas.shape(shape)
        }
        let direct = try picture(route) { canvas in
            style(canvas, weight: 10)
            arc(canvas, 80, 80, 80)
        }
        let blank = try picture(route) { _ in }
        #expect(direct.bytes != blank.bytes, "\(route): 直に描いた絵が空")
        #expect(retained.bytes == direct.bytes, "\(route): 拡大して置いた絵が直に描いた絵と違う")
    }

    // MARK: - 変わらないもの

    @Test("角度が逆向きの円弧は、どの閉じ方でも何も描かない", arguments: [nil, .open, .chord, .pie] as [ArcMode?])
    func reversedArcDrawsNothing(_ mode: ArcMode?) throws {
        let blank = try picture(.distanceField) { _ in }
        let image = try picture(.distanceField) { canvas in
            canvas.fill(white)
            canvas.stroke(white)
            if let mode { canvas.arc(64, 64, 40, 40, 1, 0.5, mode) } else { canvas.arc(64, 64, 40, 40, 1, 0.5) }
        }
        #expect(image.bytes == blank.bytes)
    }
}
