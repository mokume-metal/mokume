// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation
import Testing
import simd

@testable import MokumeCore

/// 円弧の閉じ方 (`ArcMode`) を**距離関数の経路**で描いた形が、真の幾何と合うか ([#2428])。GPU を要する。
///
/// 開いた弧の帯 (端の形 3 通り)・弦で結んだ形・扇を、`FormInstance` の 1 つの置き場所で描く。検査は
/// 形を CPU の 64 bit で定義し直し (弧を細かい折れ線にして、そこまでの距離と、最近点が端かで決める)、
/// 画素ごとに 8x8 の標本で被覆を数えて、描いた絵の赤成分 (白を黒に置いたので被覆そのもの) と比べる。
/// **形の定義は断片と別に書く** — 断片の式を写すと、式の誤りまで写る。
///
/// [#2428]: https://github.com/mokume-metal/mokume/issues/2428
@Suite(
    "円弧の閉じ方の形 (距離関数)",
    .enabled(
        if: RenderDevice.isAvailable,
        "この世代のコマンド構造に対応した GPU が無い実行環境ではスキップする")
)
struct ArcClosureShapeTests {
    private let black = LinearRGBA.linear(red: 0, green: 0, blue: 0)
    private let white = LinearRGBA.linear(red: 1, green: 1, blue: 1)

    nonisolated struct Arc: CustomTestStringConvertible, Sendable {
        let name: String
        let radii: SIMD2<Double>
        let start: Double
        let sweep: Double
        var testDescription: String { name }

        static let all = [
            Arc(name: "円・浅い弧", radii: SIMD2(30, 30), start: 0.5, sweep: 0.7),
            Arc(name: "円・半円", radii: SIMD2(30, 30), start: 1.0, sweep: .pi),
            Arc(name: "円・大きい弧", radii: SIMD2(30, 30), start: 2.0, sweep: 4.4),
            Arc(name: "楕円・浅い弧", radii: SIMD2(34, 18), start: 0.3, sweep: 1.0),
            Arc(name: "楕円・大きい弧", radii: SIMD2(34, 18), start: 4.0, sweep: 3.9),
        ]

        /// 角が 60° 未満で尖っているのに、既定の太さ (1) の輪郭の穴は 1 画素より十分に太い弧 (穴の半径が画素の 3 つ分
        /// 以上)。尖りの先の画素を標本で数える枝 (弦で結んだ形は `mokume_chordApex`・扇は `mokume_sectorApex`) の対象。
        /// 弓形の角は掃引の半分、扇の中心の角は掃引そのもの。
        static let sharpCornered: [(Arc, Style)] = [
            (Arc(name: "円・尖った弓形", radii: SIMD2(100, 100), start: 0.4, sweep: 1.0), Style(mode: .chord, cap: .round)),
            (Arc(name: "楕円・尖った弓形", radii: SIMD2(100, 70), start: 3.6, sweep: 0.9), Style(mode: .chord, cap: .round)),
            (Arc(name: "円・尖った扇", radii: SIMD2(100, 100), start: 0.4, sweep: 0.5), Style(mode: .pie, cap: .round)),
        ]
    }

    nonisolated struct SharpCase: CustomTestStringConvertible, Sendable {
        let arc: Arc
        let style: Style
        var testDescription: String { "\(arc.name)・\(style)" }
    }

    /// 閉じ方と端の形の組。端の形は開いた弧の帯 (`standard`・`open`) にしか効かない。
    nonisolated struct Style: CustomTestStringConvertible, Sendable {
        let mode: ArcMode?
        let cap: StrokeCap
        var testDescription: String { "\(mode.map { "\($0)" } ?? "既定")・\(cap)" }

        static let strokes: [Style] = [
            Style(mode: nil, cap: .round), Style(mode: nil, cap: .square), Style(mode: nil, cap: .project),
            Style(mode: .open, cap: .round), Style(mode: .open, cap: .square), Style(mode: .open, cap: .project),
            Style(mode: .pie, cap: .round), Style(mode: .chord, cap: .round),
        ]
    }

    // MARK: - 形の定義 (64 bit・断片と別)

    /// 画素 (0 が左上) の座標で形を持つ。弧は細かい折れ線で、**最近点の問い**に答える。
    private struct Reference {
        let center: SIMD2<Double>
        let radii: SIMD2<Double>
        let start: Double
        let sweep: Double
        let halfWeight: Double
        let cap: StrokeCap
        let mode: ArcMode?
        let arc: [SIMD2<Double>]

        init(
            center: SIMD2<Double>, arc spec: Arc, halfWeight: Double, cap: StrokeCap, mode: ArcMode?
        ) {
            self.center = center
            self.radii = spec.radii
            self.start = spec.start
            self.sweep = spec.sweep
            self.halfWeight = halfWeight
            self.cap = cap
            self.mode = mode
            let count = 160
            self.arc = (0...count).map { index in
                let t = spec.start + spec.sweep * Double(index) / Double(count)
                return SIMD2(spec.radii.x * cos(t), spec.radii.y * sin(t))
            }
        }

        /// 塗りの内側か (中心を原点にした座標)。
        func fills(_ p: SIMD2<Double>) -> Bool {
            let u = SIMD2(p.x / radii.x, p.y / radii.y)
            guard simd_length_squared(u) < 1 else { return false }
            switch mode {
            case .chord?, .open?:
                let middle = start + sweep / 2
                return u.x * cos(middle) + u.y * sin(middle) >= cos(sweep / 2)
            default:
                var delta = (atan2(u.y, u.x) - start).truncatingRemainder(dividingBy: 2 * .pi)
                if delta < 0 { delta += 2 * .pi }
                return delta <= sweep
            }
        }

        /// 線分 `a`→`b` への距離と、最近点の位置 (0…1)。
        private static func nearest(
            _ p: SIMD2<Double>, _ a: SIMD2<Double>, _ b: SIMD2<Double>
        ) -> (distance: Double, t: Double) {
            let along = b - a
            let t = min(max(simd_dot(p - a, along) / max(simd_dot(along, along), 1e-300), 0), 1)
            return (simd_distance(p, a + along * t), t)
        }

        /// 折れ線 (閉じていれば最後と最初も結ぶ) への距離。`atEnd` は、最近点が開いた折れ線の端か。
        private static func distance(
            _ p: SIMD2<Double>, _ points: [SIMD2<Double>], closed: Bool
        ) -> (distance: Double, atEnd: Bool) {
            var best = Double.infinity
            var atEnd = false
            let last = closed ? points.count : points.count - 1
            for index in 0..<last {
                let (d, t) = nearest(p, points[index], points[(index + 1) % points.count])
                if d < best {
                    best = d
                    atEnd = !closed && ((index == 0 && t == 0) || (index == last - 1 && t == 1))
                }
            }
            return (best, atEnd)
        }

        /// 輪郭の中心線 (折れ線) までの距離と、最近点が開いた折れ線の端か。扇と弦は閉じた折れ線で、端は無い。
        private func centerline(_ p: SIMD2<Double>) -> (distance: Double, atEnd: Bool) {
            switch mode {
            case .pie?: return Self.distance(p, [.zero] + arc, closed: true)
            case .chord?: return Self.distance(p, arc, closed: true)
            default: return Self.distance(p, arc, closed: false)
            }
        }

        /// 輪郭の帯の内側か (中心を原点にした座標)。
        func strokes(_ p: SIMD2<Double>) -> Bool {
            let (d, atEnd) = centerline(p)
            switch mode {
            case .pie?, .chord?:
                return d <= halfWeight
            default:
                guard d <= halfWeight || cap == .project else { return false }
                switch cap {
                case .round:
                    return d <= halfWeight
                case .square:
                    return d <= halfWeight && !atEnd
                case .project:
                    if d <= halfWeight && !atEnd { return true }
                    // 端から接線の向きに半分の太さだけ出る長方形 (幅は太さ)
                    for end in [0, arc.count - 1] {
                        let neighbour = end == 0 ? arc[1] : arc[arc.count - 2]
                        let outward = simd_normalize(arc[end] - neighbour)
                        let normal = SIMD2(-outward.y, outward.x)
                        let relative = p - arc[end]
                        let along = simd_dot(relative, outward)
                        if along >= 0, along <= halfWeight, abs(simd_dot(relative, normal)) <= halfWeight {
                            return true
                        }
                    }
                    return false
                }
            }
        }

        /// 塗りと輪郭の和集合の被覆。4x4 の標本で、塗りは寄せず、輪郭は画面で半画素寄せて評価する。塗りと輪郭が
        /// 重なる画素の面積 (扇の塗りに食い込む端など) を、真の和集合で数える。
        func unionCoverage(x: Int, y: Int) -> Double {
            let base = SIMD2(Double(x), Double(y)) - center
            let n = 4
            var inside = 0
            for j in 0..<n {
                for i in 0..<n {
                    let at = base + SIMD2((Double(i) + 0.5) / Double(n), (Double(j) + 0.5) / Double(n))
                    if fills(at) || strokes(at - SIMD2(0.5, 0.5)) { inside += 1 }
                }
            }
            return Double(inside) / Double(n * n)
        }

        /// 画素 `(x, y)` の被覆。8x8 の標本。**輪郭は画面で半画素寄せて評価する** (ADR-0039 決定 2)。
        func coverage(x: Int, y: Int, stroke: Bool) -> Double {
            let shift = stroke ? SIMD2(0.5, 0.5) : .zero
            let base = SIMD2(Double(x), Double(y)) - center - shift
            let member: (SIMD2<Double>) -> Bool = stroke ? strokes : fills
            if stroke {
                // 帯から 2 画素以上離れた画素と、帯の中で端からも離れた画素は、標本を取らずに答える
                let middle = base + SIMD2(0.5, 0.5)
                let (d, _) = centerline(middle)
                let slack = cap == .project ? 2 * halfWeight : 0
                if d > halfWeight + slack + 1.5 { return 0 }
                let nearEnd = [arc[0], arc[arc.count - 1]].contains { simd_distance($0, middle) < halfWeight + 3 }
                if d < halfWeight - 1.5, !nearEnd { return 1 }
            }
            let n = 8
            var inside = 0
            for j in 0..<n {
                for i in 0..<n {
                    let at = base + SIMD2((Double(i) + 0.5) / Double(n), (Double(j) + 0.5) / Double(n))
                    if member(at) { inside += 1 }
                }
            }
            return Double(inside) / Double(n * n)
        }
    }

    // MARK: - 比べる

    private struct Measured {
        var worst = 0.0
        var worstAt = ""
        var sumSquares = 0.0
        var edgePixels = 0
        var rootMeanSquare: Double { edgePixels > 0 ? (sumSquares / Double(edgePixels)).squareRoot() : 0 }
    }

    /// 描いた絵と定義の食い違い。絵が 0 でも 1 でもない画素と、定義が 0 でも 1 でもない画素だけを数える
    /// (中身の画素は食い違えば最悪値に出る)。
    ///
    /// - Parameters:
    ///   - scale: 描く前に掛ける拡大。形の座標を `1 / scale` にして描くので、画素に出る大きさは変わらない。
    ///     縮めて (`0.05`) も拡げて (`400`) も、画素の幾何は同じ定義と合うはず。
    ///   - union: 塗りと輪郭を両方持たせ、和集合の被覆と比べる (`stroke` は読まない)。
    private func measure(
        _ spec: Arc, style: Style, weight: Float, stroke: Bool, size: Int = 96, scale: Float = 1,
        union: Bool = false
    ) throws -> Measured {
        let canvas = try CanvasFixture.make(gpu: RenderDevice(), width: size, height: size)
        let placed = SIMD2<Float>(Float(size) / 2 + 0.37, Float(size) / 2 - 0.39)
        try canvas.draw {
            canvas.background(black)
            canvas.translate(placed.x, placed.y)
            canvas.scale(scale, scale)
            if union {
                canvas.fill(white)
                canvas.stroke(white)
                canvas.strokeWeight(weight / scale)
                canvas.strokeCap(style.cap)
            } else if stroke {
                canvas.noFill()
                canvas.stroke(white)
                canvas.strokeWeight(weight / scale)
                canvas.strokeCap(style.cap)
            } else {
                canvas.noStroke()
                canvas.fill(white)
            }
            // 座標の読み方は既定の中心 + 幅と高さ。置き場所は translate で決める
            let (x, y) = (Float(0), Float(0))
            let (w, h) = (2 * Float(spec.radii.x) / scale, 2 * Float(spec.radii.y) / scale)
            let (a, b) = (Float(spec.start), Float(spec.start + spec.sweep))
            if let mode = style.mode {
                canvas.arc(x, y, w, h, a, b, mode)
            } else {
                canvas.arc(x, y, w, h, a, b)
            }
        }
        let pixels = try canvas.target.readPixels()
        let reference = Reference(
            center: SIMD2(Double(placed.x), Double(placed.y)), arc: spec,
            halfWeight: Double(weight) / 2, cap: style.cap, mode: style.mode)
        var measured = Measured()
        // 形の箱 (輪郭と端の張り出しの分だけ広げる) の中だけを数える
        let reach = max(spec.radii.x, spec.radii.y) + Double(weight) + 2
        let low = SIMD2(Int(Double(placed.x) - reach), Int(Double(placed.y) - reach))
        let high = SIMD2(Int(Double(placed.x) + reach) + 1, Int(Double(placed.y) + reach) + 1)
        for y in max(low.y, 0)..<min(high.y, size) {
            for x in max(low.x, 0)..<min(high.x, size) {
                let drawn = Double(pixels[x, y].red)
                // 定義は標本の数えなので、まず絵が 0 / 1 の画素は軽く済ませる
                let expected =
                    union ? reference.unionCoverage(x: x, y: y) : reference.coverage(x: x, y: y, stroke: stroke)
                let error = abs(drawn - expected)
                if drawn > 0.002 && drawn < 0.998 || expected > 0.002 && expected < 0.998 {
                    measured.edgePixels += 1
                    measured.sumSquares += error * error
                }
                if error > measured.worst {
                    measured.worst = error
                    measured.worstAt = "(\(x), \(y)) 描いた \(drawn) 定義 \(expected)"
                }
            }
        }
        return measured
    }

    @Test(
        "太い輪郭は、閉じ方と端の形ごとに、真の幾何と画素の被覆が合う",
        arguments: Arc.all, Style.strokes)
    func thickStrokeMatchesTheGeometry(_ spec: Arc, _ style: Style) throws {
        let measured = try measure(spec, style: style, weight: 7, stroke: true)
        #expect(
            measured.worst < 0.4,
            "\(spec) \(style): 最悪 \(measured.worst) \(measured.worstAt) 縁の二乗平均 \(measured.rootMeanSquare)")
        #expect(
            measured.rootMeanSquare < 0.06,
            "\(spec) \(style): 縁の二乗平均 \(measured.rootMeanSquare) (最悪 \(measured.worst) \(measured.worstAt))")
    }

    @Test(
        "角が尖った弓形・扇の輪郭は、穴が太くても、角の先まで真の幾何と画素の被覆が合う",
        arguments: Arc.sharpCornered.map { SharpCase(arc: $0.0, style: $0.1) })
    func sharpCornerStrokeMatchesTheGeometry(_ sharp: SharpCase) throws {
        let (spec, style) = (sharp.arc, sharp.style)
        let measured = try measure(spec, style: style, weight: 1, stroke: true, size: 240)
        #expect(
            measured.worst < 0.15,
            "\(spec) \(style): 最悪 \(measured.worst) \(measured.worstAt) 縁の二乗平均 \(measured.rootMeanSquare)")
        #expect(
            measured.rootMeanSquare < 0.06,
            "\(spec) \(style): 縁の二乗平均 \(measured.rootMeanSquare) (最悪 \(measured.worst) \(measured.worstAt))")
    }

    @Test(
        "細い輪郭 (1 画素未満) も、閉じ方と端の形ごとに、真の幾何と画素の被覆が合う",
        arguments: Arc.all, Style.strokes)
    func thinStrokeMatchesTheGeometry(_ spec: Arc, _ style: Style) throws {
        let measured = try measure(spec, style: style, weight: 0.6, stroke: true)
        #expect(
            measured.worst < 0.4,
            "\(spec) \(style): 最悪 \(measured.worst) \(measured.worstAt) 縁の二乗平均 \(measured.rootMeanSquare)")
        #expect(
            measured.rootMeanSquare < 0.12,
            "\(spec) \(style): 縁の二乗平均 \(measured.rootMeanSquare) (最悪 \(measured.worst) \(measured.worstAt))")
    }

    @Test(
        "塗りは、扇か弦で結んだ形になり、真の幾何と画素の被覆が合う",
        arguments: Arc.all, [nil, .pie, .chord, .open] as [ArcMode?])
    func fillMatchesTheGeometry(_ spec: Arc, _ mode: ArcMode?) throws {
        let measured = try measure(spec, style: Style(mode: mode, cap: .round), weight: 1, stroke: false)
        #expect(
            measured.worst < 0.4,
            "\(spec) \(String(describing: mode)): 最悪 \(measured.worst) \(measured.worstAt)")
        // 塗りは細い枝を持たない (1 画素より細い弓形は縁 1 本で数えるので数割多く出る・
        // `Sketch.fill` の説明の「約束の外」)。浅い弧の弦で結んだ形が最も外れる
        #expect(
            measured.rootMeanSquare < 0.08,
            "\(spec) \(String(describing: mode)): 縁の二乗平均 \(measured.rootMeanSquare)")
    }

    // MARK: - 画素の大きさに従う守り・和集合

    /// 端の形の守り (開いた弧の帯の切り口を使う範囲) は、形の座標の定数でなく画素の大きさで測る (#2428 の反証)。
    /// 縮めて描く (`scale(0.05)`) と角の画素が圏外になって切り口が効かず、拡げて描く (`scale(400)`) と守りが
    /// 一度も効かず遠い画素に切り口が及ぶ。どちらも画素の幾何は同じなので、同じ定義と合う。
    @Test(
        "端の形のある開いた弧の帯は、縮めて描いても拡げて描いても、真の幾何と画素の被覆が合う",
        arguments: [Float(0.05), 400],
        [Arc.all[1], Arc.all[3]])
    func capGuardFollowsThePixelSize(_ scale: Float, _ spec: Arc) throws {
        for cap in [StrokeCap.square, .project] {
            let style = Style(mode: .open, cap: cap)
            let measured = try measure(spec, style: style, weight: 7, stroke: true, scale: scale)
            #expect(
                measured.worst < 0.4,
                "\(spec) \(style) 拡大 \(scale): 最悪 \(measured.worst) \(measured.worstAt) 縁の二乗平均 \(measured.rootMeanSquare)")
            #expect(
                measured.rootMeanSquare < 0.06,
                "\(spec) \(style) 拡大 \(scale): 縁の二乗平均 \(measured.rootMeanSquare) (最悪 \(measured.worst) \(measured.worstAt))")
        }
    }

    /// project の端の長方形は、帯との和集合で数える (足し算だと、重なる所の縁の画素が過大になる)。ほぼ一周の弧で
    /// 隙間が太さより狭いと、両端の長方形どうしが重なる。
    @Test(
        "ほぼ一周の弧の project の端は、重なる長方形も和集合で数える",
        arguments: [0.14, 0.3], [nil, .open] as [ArcMode?])
    func nearlyFullTurnProjectCountsTheUnion(_ gap: Double, _ mode: ArcMode?) throws {
        let spec = Arc(name: "円・ほぼ一周 (隙間 \(gap))", radii: SIMD2(30, 30), start: 0.3, sweep: 2 * .pi - gap)
        let style = Style(mode: mode, cap: .project)
        let measured = try measure(spec, style: style, weight: 7, stroke: true)
        #expect(
            measured.worst < 0.3,
            "\(spec) \(style): 最悪 \(measured.worst) \(measured.worstAt) 縁の二乗平均 \(measured.rootMeanSquare)")
        #expect(
            measured.rootMeanSquare < 0.05,
            "\(spec) \(style): 縁の二乗平均 \(measured.rootMeanSquare) (最悪 \(measured.worst) \(measured.worstAt))")
    }

    /// 楕円の弧では、端の接線が半径と直交しないので、project の長方形が既定の扇の塗りに食い込む。塗りと輪郭の
    /// 重なりは、塗りと輪郭を足した被覆でなく、真の和集合の被覆と合う。
    @Test(
        "楕円の弧の project の端は、扇の塗りに食い込んでも、塗りと輪郭の和集合の被覆と合う",
        arguments: [Arc.all[3], Arc.all[4], Arc(name: "楕円・扁平な弧", radii: SIMD2(36, 12), start: 0.2, sweep: 2.0)])
    func ellipticalProjectEndsOverlapTheFill(_ spec: Arc) throws {
        let style = Style(mode: nil, cap: .project)
        let measured = try measure(spec, style: style, weight: 7, stroke: true, union: true)
        #expect(
            measured.worst < 0.4,
            "\(spec) \(style): 最悪 \(measured.worst) \(measured.worstAt) 縁の二乗平均 \(measured.rootMeanSquare)")
        #expect(
            measured.rootMeanSquare < 0.06,
            "\(spec) \(style): 縁の二乗平均 \(measured.rootMeanSquare) (最悪 \(measured.worst) \(measured.worstAt))")
    }

    /// 同じ幾何を、`scale` で縮めて・拡げて描いた絵の赤成分 (形の座標を `1 / scale` にするので、画素に出る大きさは同じ)。
    private func render(_ spec: Arc, cap: StrokeCap, weight: Float, scale: Float) throws -> [Float] {
        let size = 96
        let canvas = try CanvasFixture.make(gpu: RenderDevice(), width: size, height: size)
        try canvas.draw {
            canvas.background(black)
            canvas.translate(Float(size) / 2 + 0.37, Float(size) / 2 - 0.39)
            canvas.scale(scale, scale)
            canvas.noFill()
            canvas.stroke(white)
            canvas.strokeWeight(weight / scale)
            canvas.strokeCap(cap)
            canvas.arc(
                0, 0, 2 * Float(spec.radii.x) / scale, 2 * Float(spec.radii.y) / scale,
                Float(spec.start), Float(spec.start + spec.sweep), .open)
        }
        let pixels = try canvas.target.readPixels()
        var out: [Float] = []
        out.reserveCapacity(size * size)
        for y in 0..<size {
            for x in 0..<size { out.append(Float(pixels[x, y].red)) }
        }
        return out
    }

    /// 端の切り口を使う範囲 (端の近く) は、画素の大きさで測る。形の座標の定数 (かつては太さの半分 + 2) だと、
    /// 縮めて描くと角の画素が圏外になり、拡げて描くと守りが一度も効かない。同じ幾何は、縮めても拡げても、拡大 1 と
    /// 同じ絵になる (長い軸と短い軸の差が大きい楕円は、端の法線の直線が弧の反対側へも伸びる)。
    ///
    /// **旧い式でもこの組では差が出なかった** — 守りが効く画素 (切り口の外側で最近点が弧の中) は、
    /// 帯の縁の半画素に数画素あるだけで、被覆の差は 0.001 に収まる。画素の大きさで測る直しは、定数の次元を
    /// 揃える (形の座標の長さを画素の長さと混ぜない) もので、絵が変わることを示す組は見つかっていない。
    @Test("端の形のある開いた弧の帯は、縮めても拡げても、拡大しない絵と同じになる", arguments: [Float(0.05), 400])
    func capGuardIsScaleInvariant(_ scale: Float) throws {
        let arcs = [
            Arc(name: "細長い楕円・大きい弧", radii: SIMD2(40, 10), start: 0.2, sweep: 4.5),
            Arc(name: "楕円・ほぼ一周", radii: SIMD2(44, 20), start: 0.1, sweep: 5.9),
            Arc(name: "扁平な楕円・半周", radii: SIMD2(44, 8), start: 2.5, sweep: 3.3),
        ]
        for spec in arcs {
            for cap in [StrokeCap.square, .project] {
                for weight in [Float(1.3), 7] {
                    let base = try render(spec, cap: cap, weight: weight, scale: 1)
                    let scaled = try render(spec, cap: cap, weight: weight, scale: scale)
                    var worst: Float = 0
                    for (a, b) in zip(base, scaled) { worst = max(worst, abs(a - b)) }
                    #expect(worst < 0.02, "\(spec) \(cap) 太さ \(weight) 拡大 \(scale): 拡大 1 との最大差 \(worst)")
                }
            }
        }
    }
}
