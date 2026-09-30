// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Metal
import Testing

@testable import MokumeCore

/// 色を半精度の面へ移す関所 (``HalfSurface``) の検査 ([#1691])。
///
/// **同じ色を面へ置く経路は、どれも同じ値を面に残す。** 図形の経路 (断片の出力) は上限を
/// 越えた有限の成分を ±65504 で止める。塗り直し (clear 色) と CPU の書き込みがそれを ±inf に
/// していたので、その上の不透明な図形が NaN (inf × 0) になって黒く抜けた。
///
/// [#1691]: https://github.com/mokume-metal/mokume/issues/1691
@Suite("半精度の面へ移す関所")
struct HalfSurfaceTests {
    /// 完了条件 3。**非有限の値はそのまま通す** — 図形の経路 (断片の出力) と同じ扱いである。
    @Test(
        "有限の成分は ±65504 で止まり、非有限の成分はそのまま通る",
        arguments: [
            (Float(70000), Float(65504)),
            (-70000, -65504),
            (65519, 65504),
            (65504, 65504),
            (1e9, 65504),
            (0.25, 0.25),
            (.infinity, .infinity),
            (-.infinity, -.infinity),
        ])
    func finiteComponentsStopAtTheLargestHalf(_ given: Float, _ expected: Float) {
        let color = LinearRGBA(premultipliedRed: given, green: given, blue: given, alpha: given)
        let texel = HalfSurface.texel(color)
        let clear = HalfSurface.clearColor(color)
        for lane in 0..<4 { #expect(Float(texel[lane]) == expected, "画素の成分 \(lane)") }
        for component in [clear.red, clear.green, clear.blue, clear.alpha] {
            #expect(component == Double(expected), "clear 色")
        }
    }

    /// 完了条件 3 の後段。**数でない値を数に化けさせない** — `min` / `max` の書き順によっては
    /// NaN が 65504 に化ける (ADR-0033 決定 3 の改訂が不透明度について名指しした罠)。
    @Test("数でない成分は、数でないまま通る")
    func notANumberStaysNotANumber() {
        let color = LinearRGBA(premultipliedRed: .nan, green: .nan, blue: .nan, alpha: .nan)
        let texel = HalfSurface.texel(color)
        let clear = HalfSurface.clearColor(color)
        for lane in 0..<4 { #expect(texel[lane].isNaN, "画素の成分 \(lane)") }
        for component in [clear.red, clear.green, clear.blue, clear.alpha] {
            #expect(component.isNaN, "clear 色")
        }
    }

    /// 完了条件 4。締めるのは面へ移す所だけで、色の値そのものは締めない (ADR-0033 決定 6)。
    @Test("白を越える明るさの色の値は、締められずに残る")
    func colorValuesAreNotBounded() {
        #expect(abs(red(color(40000)) - 40000) < 1)
        #expect(color(40000).red > 65504)
    }

    /// 反証の指摘 1。**有限の数で書いた色は、`Float` の段でも有限のまま作業空間へ入る** —
    /// 2.4 乗が `Float` の最大を越えても、原色の行列の 0 の係数と掛かって NaN にならない。
    @Test("Float の最大を越える明るさで書いた色も、成分は有限のまま")
    func colorsBeyondTheLargestFloatStayFinite() {
        for value: Float in [3.1e18, 4e18, .greatestFiniteMagnitude] {
            let written = color(value)
            for component in [written.red, written.green, written.blue, written.alpha] {
                #expect(component.isFinite, "color(\(value))")
            }
        }
    }
}

/// 範囲の口を図形の経路と比べる検査と、起票の再現 ([#1691] の完了条件 1・2)。GPU を要する。
///
/// [#1691]: https://github.com/mokume-metal/mokume/issues/1691
@Suite(
    "半精度の面へ色を置く経路",
    .enabled(
        if: RenderDevice.isAvailable,
        "この世代のコマンド構造に対応した GPU が無い実行環境ではスキップする")
)
struct HalfSurfaceRouteTests {
    private static let side = 8

    /// 面へ置く色。**成分が半精度の上限を越える色を主に並べる。**
    nonisolated enum Sample: String, CaseIterable, CustomTestStringConvertible, Sendable {
        case white = "color(255)"
        case belowTheEdge = "color(27300)"
        case aboveTheEdge = "color(27400)"
        case overbright = "color(40000)"
        case huge = "color(1e9)"
        case beyondTheLargestFloat = "color(4e18)"
        case translucent = "color(40000, 128)"
        case negative = ".linear(-70000, -70000, -70000)"
        case mixed = ".linear(70000, 0.5, 0)"

        var testDescription: String { rawValue }

        @MainActor var color: LinearRGBA {
            switch self {
            case .white: MokumeCore.color(255)
            case .belowTheEdge: MokumeCore.color(27300)
            case .aboveTheEdge: MokumeCore.color(27400)
            case .overbright: MokumeCore.color(40000)
            case .huge: MokumeCore.color(1e9)
            case .beyondTheLargestFloat: MokumeCore.color(4e18)
            case .translucent: MokumeCore.color(40000, 128)
            case .negative: .linear(red: -70000, green: -70000, blue: -70000)
            case .mixed: .linear(red: 70000, green: 0.5, blue: 0)
            }
        }
    }

    /// 色を面へ置く口。**口を足したら、ここへ 1 行足す** — 同じ性質が引数の直積で回る。
    nonisolated enum Route: String, CaseIterable, CustomTestStringConvertible, Sendable {
        case background = "background(c)"
        case graphicsBackground = "描き場所の background(c)"
        case targetFill = "RenderTarget.fill(with: c)"
        case set = "set(x, y, c)"
        case pixelsSubscript = "pixels[x, y] = c"
        case pixelsFill = "pixels.fill(c)"
        case imageSet = "Image.set(x, y, c)"
        case imageFill = "Image.fill(c)"

        var testDescription: String { rawValue }
    }

    private func makeCanvas() throws -> Canvas {
        try CanvasFixture.make(gpu: RenderDevice(), width: Self.side, height: Self.side)
    }

    /// 比べる基準 (完了条件 1 の (a))。面いっぱいの図形を置き換えで塗る — 断片の出力の経路。
    private func drawnByShape(_ color: LinearRGBA) throws -> LinearRGBA {
        let canvas = try makeCanvas()
        try canvas.draw {
            canvas.blendMode(.replace)
            canvas.noStroke()
            canvas.fill(color)
            canvas.rect(0, 0, Self.side, Self.side)
        }
        return try canvas.target.readPixels()[4, 4]
    }

    /// 口を通して色を置き、面の値を読む。絵 (`Image`) の口では、本体へ `image` で置いた後の
    /// 本体の値も返す。
    private func written(
        _ color: LinearRGBA, through route: Route
    ) throws -> (surface: LinearRGBA, placed: LinearRGBA?) {
        let canvas = try makeCanvas()
        switch route {
        case .background:
            try canvas.draw { canvas.background(color) }
            return (try canvas.target.readPixels()[4, 4], nil)
        case .graphicsBackground:
            let layer = try canvas.createGraphics(Self.side, Self.side)
            layer.beginDraw()
            layer.background(color)
            layer.endDraw()
            return (try layer.target.readPixels()[4, 4], nil)
        case .targetFill:
            try canvas.target.fill(with: color)
            return (try canvas.target.readPixels()[4, 4], nil)
        case .set:
            try canvas.draw { canvas.set(4, 4, color) }
            return (try canvas.target.readPixels()[4, 4], nil)
        case .pixelsSubscript:
            try canvas.draw { canvas.pixels[4, 4] = color }
            return (try canvas.target.readPixels()[4, 4], nil)
        case .pixelsFill:
            try canvas.draw { canvas.pixels.fill(color) }
            return (try canvas.target.readPixels()[4, 4], nil)
        case .imageSet, .imageFill:
            let image = try canvas.createImage(Self.side, Self.side)
            if route == .imageSet {
                for y in 0..<Self.side {
                    for x in 0..<Self.side { image.set(x, y, color) }
                }
            } else {
                image.fill(color)
            }
            try canvas.draw {
                canvas.background(.linear(red: 0, green: 0, blue: 0))
                canvas.image(image, 0, 0)
            }
            return (image.get(4, 4), try canvas.target.readPixels()[4, 4])
        }
    }

    /// 完了条件 1。
    ///
    /// **成分の一致は、半精度の隣り合う 2 つの目盛りまでを一致とみなす。** 断片の出力が面へ書くときの
    /// 丸めは最寄りとは限らず、目盛りの途中にある値は下の目盛りへ落ちることがある (#911)。
    /// `color(27300)` の線形の値は、clear 色と CPU では最寄りの 65440、図形の経路では 1 つ下の 65408
    /// になった (Apple M3 Max)。この差は上限の扱いとは関係が無く、直す前からある。
    /// ±65504 と ±inf・NaN はこの幅では取り違えない (``isAdjacentHalf(_:_:)``)。
    @Test(
        "どの口で面へ置いても、面いっぱいの図形を置き換えで塗った面と同じ値になる",
        arguments: Route.allCases, Sample.allCases)
    func everyRouteLeavesWhatTheShapeRouteLeaves(_ route: Route, _ sample: Sample) throws {
        let expected = try drawnByShape(sample.color)
        let (surface, placed) = try written(sample.color, through: route)
        let context = "\(route.rawValue) に \(sample.rawValue)"

        for (lane, (got, want)) in zip(components(surface), components(expected)).enumerated() {
            #expect(got.isFinite, "\(context) の成分 \(lane) が \(got)")
            #expect(isAdjacentHalf(got, want), "\(context) の成分 \(lane): \(got) / 図形の経路 \(want)")
        }
        if let placed {
            for (lane, got) in components(placed).enumerated() {
                #expect(got.isFinite, "\(context) を image で置いた本体の成分 \(lane) が \(got)")
            }
        }
    }

    /// 起票の再現で敷く下地。
    nonisolated enum Ground: String, CaseIterable, CustomTestStringConvertible, Sendable {
        case gray = "background(40000)"
        case negative = "background(.linear(-70000, -70000, -70000))"

        var testDescription: String { rawValue }

        @MainActor func paint(_ canvas: Canvas) {
            switch self {
            case .gray: canvas.background(40000)
            case .negative: canvas.background(.linear(red: -70000, green: -70000, blue: -70000))
            }
        }
    }

    /// 完了条件 2。起票の再現 (probes の `backgroundOverflow`)。
    @Test(
        "白を越える明るさの下地の上でも、不透明な矩形は白い下地の上と同じ色になる",
        arguments: Ground.allCases)
    func opaqueShapeCoversAnOverbrightGround(_ ground: Ground) throws {
        let bright = try reproduce(ground.paint)
        let white = try reproduce { $0.background(255) }
        var differing = 0
        for y in 10..<30 {
            for x in 10..<30 {
                let (p, q) = (bright[x, y], white[x, y])
                let gap = max(
                    abs(p.red - q.red), abs(p.green - q.green), abs(p.blue - q.blue),
                    abs(p.alpha - q.alpha))
                if !(gap <= 0.004) { differing += 1 }
            }
        }
        let (a, b) = (bright[20, 20], white[20, 20])
        #expect(
            differing == 0,
            "\(ground.rawValue) の上の不透明な矩形の \(differing) / 400 画素が background(255) の上と違う ((20, 20): \(a) / \(b))"
        )
    }

    /// 完了条件 2 の後段。下地を読む混ぜ方でも、白を越える明るさの下地から NaN が出ない。
    @Test(
        "白を越える明るさの下地に、下地を読む混ぜ方で半透明の色を重ねても有限である",
        arguments: [BlendMode.difference, .multiply, .subtract, .exclusion])
    func readingBlendsOverAnOverbrightGroundStayFinite(_ mode: BlendMode) throws {
        let canvas = try CanvasFixture.make(gpu: RenderDevice(), width: 40, height: 40)
        try canvas.draw {
            canvas.background(40000)
            canvas.noStroke()
            canvas.blendMode(mode)
            canvas.fill(255, 0, 0, 128)
            canvas.rect(10, 10, 20, 20)
        }
        let pixel = try canvas.target.readPixels()[20, 20]
        for (lane, got) in components(pixel).enumerated() {
            #expect(got.isFinite, "\(mode) で重ねた画素の成分 \(lane) が \(got)")
        }
    }

    /// 起票の再現と同じ絵 (40×40)。
    private func reproduce(_ ground: (Canvas) -> Void) throws -> PixelBuffer {
        let canvas = try CanvasFixture.make(gpu: RenderDevice(), width: 40, height: 40)
        try canvas.draw {
            ground(canvas)
            canvas.noStroke()
            canvas.fill(40, 90, 230)
            canvas.rect(10, 10, 20, 20)
        }
        return try canvas.target.readPixels()
    }

    private func components(_ color: LinearRGBA) -> [Float] {
        [color.red, color.green, color.blue, color.alpha]
    }

    /// 同じ値か、半精度の隣り合う目盛りか。**どちらかが有限でなければ一致とみなさない** —
    /// 65504 の 1 つ上の目盛りは +inf なので、隣を許すだけでは +inf を通してしまう。
    private func isAdjacentHalf(_ got: Float, _ want: Float) -> Bool {
        guard got.isFinite, want.isFinite else { return false }
        let half = Float16(want)
        return [want, Float(half.nextUp), Float(half.nextDown)].contains(got)
    }
}
