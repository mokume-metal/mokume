// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation
import Testing
import simd

@testable import MokumeCore

/// 細い線の開いた端を、描く画素の列 (行) の境目で切る形 (``ThinEndCut``・#3745) の式。GPU は使わない。
@Suite("細い線の開いた端は、描く画素の列の境目で切る (#3745)")
nonisolated struct ThinEndCutTests {
    /// 向き `angle` の帯の、列 (行) が帯を切る長さを整数 n にした半幅 (``Canvas/widenedBand(_:along:)`` と同じ量)。
    static func half(angle: Float, drawn: Float) -> Float {
        let axis = max(abs(cos(angle)), abs(sin(angle)))
        let crossings: Float = drawn / axis <= 1 ? 1 : 2
        return crossings * axis / 2
    }

    /// 凸多角形の面積。
    static func area(_ polygon: [SIMD2<Float>]) -> Double {
        var twice = 0.0
        for index in polygon.indices {
            let (a, b) = (polygon[index], polygon[(index + 1) % polygon.count])
            twice += Double(a.x) * Double(b.y) - Double(b.x) * Double(a.y)
        }
        return abs(twice) / 2
    }

    @Test(
        "端の列の片は、主軸の境目 2 本に頂点を持つ幅 1 の平行四辺形で、面積は n になる",
        arguments: [Float(0.81), 0.3556817963340136, Float.pi / 4, 2.4, -0.3, 1.2])
    func pieceSpansOneColumn(_ angle: Float) throws {
        for drawn in [Float(0.34375), 0.9] {
            let inward = SIMD2(cos(angle), sin(angle))
            let half = Self.half(angle: angle, drawn: drawn)
            let axis = abs(inward.x) >= abs(inward.y) ? 0 : 1
            let crossings = (2 * half / abs(inward[axis])).rounded()
            for shift in stride(from: Float(0), to: 1, by: 0.125) {
                let base = SIMD2<Float>(20.25, 31.5 + shift)
                let cut = try #require(
                    ThinEndCut(end: SIMD2(0.3, -0.2), far: SIMD2(0.3, -0.2) + inward * 10, extend: 0, half: half, base: base))
                let piece = cut.piece
                // 頂点はどれも境目 (絶対座標の整数) に乗る
                for vertex in piece {
                    let absolute = vertex[cut.axis] + base[cut.axis]
                    #expect(abs(absolute - absolute.rounded()) < 1e-4, "角度 \(angle)・頂点 \(vertex)")
                }
                #expect(abs(Self.area(piece) - Double(crossings)) < 1e-3, "角度 \(angle)・面積 \(Self.area(piece))")
                // 割合は、端点から内側の境目までの長さ
                let along = cut.sign * (cut.tip[cut.axis] + base[cut.axis])
                #expect(abs(cut.fraction - (along.rounded(.down) + 1 - along)) < 1e-5)
                #expect(cut.fraction > 0 && cut.fraction <= 1)
                // 帯を切った残りは、境目から内側だけにある
                let band = [SIMD2<Float>(-50, -50), SIMD2(50, -50), SIMD2(50, 50), SIMD2(-50, 50)]
                for vertex in cut.trimmed(band) {
                    #expect(cut.sign * (vertex[cut.axis] - cut.boundary) >= -1e-5)
                }
            }
        }
    }

    @Test("1 本の帯の両端が同じ列に入るなら、1 つの片にして割合は両端の差にする")
    func shortBandMergesIntoOnePiece() throws {
        let inward = SIMD2<Float>(cos(0.5), sin(0.5))
        let half = Self.half(angle: 0.5, drawn: 0.3)
        let base = SIMD2<Float>(10.1, 0)
        let (a, b) = (SIMD2<Float>(0, 0), SIMD2<Float>(0, 0) + inward * 0.5)
        let start = try #require(ThinEndCut(end: a, far: b, extend: 0, half: half, base: base))
        let end = try #require(ThinEndCut(end: b, far: a, extend: 0, half: half, base: base, axis: start.axis))
        let one = try #require(ThinEndCut.merged(start, end))
        #expect(abs(one.fraction - inward.x * 0.5) < 1e-5)
        // 隣の列に入る長さなら 1 つにしない
        let longer = a + inward * 2
        let far = try #require(ThinEndCut(end: longer, far: a, extend: 0, half: half, base: base, axis: start.axis))
        #expect(ThinEndCut.merged(start, far) == nil)
        #expect(!start.overlaps(far))
    }
}

/// 開いた端を列の境目で切った細い線の光の量と、切るかどうかの選び方 (#3745)。
@Suite(
    "開いた端を列の境目で切った細い線は、置く位置によらず太さぶんの濃さで出る (#3745)",
    .enabled(
        if: RenderDevice.isAvailable,
        "この世代のコマンド構造に対応した GPU が無い実行環境ではスキップする")
)
struct ThinEndCutRenderTests {
    static let size = 128

    private static func makeCanvas(density: Float) throws -> Canvas {
        let gpu = try RenderDevice()
        let output = try RenderTarget(gpu: gpu, width: size, height: size)
        return try Canvas(output: output, gpu: gpu, pixelDensity: density, upscale: .spatial)
    }

    private static func light(_ canvas: Canvas) throws -> Double {
        let pixels = try canvas.target.readPixels()
        var total = 0.0
        for y in 0..<pixels.height {
            for x in 0..<pixels.width { total += Double(pixels[x, y].red) }
        }
        return total
    }

    /// 細かく刻んだ一直線の折れ線の置き方 (平面か立体か・端の形・角度・細かさ)。
    struct Subdivided: Sendable, CustomTestStringConvertible {
        let solid: Bool
        let cap: StrokeCap
        let angle: Float
        let density: Float
        var testDescription: String { "\(solid ? "立体" : "平面")・\(cap)・角度 \(angle)・細かさ \(density)" }
    }

    nonisolated static let subdivided: [Subdivided] = [false, true].flatMap { solid in
        [StrokeCap.square, .project, .round].flatMap { cap in
            [(Float(0.81), Float(0.34375)), (0.3556817963340136, 0.390625), (.pi / 4, 0.25)].map {
                Subdivided(solid: solid, cap: cap, angle: $0.0, density: $0.1)
            }
        }
    }

    /// 長さ 40 の一直線を 0.25 刻みの点で並べた開いた線を、`row` の置き方・端の形 `cap`・縦のずらし `dy` で描いた光の量。
    private static func subdividedLight(
        _ row: Subdivided, cap: StrokeCap, dy: Float, canvas: Canvas, shader: Shader
    ) throws -> Double {
        try canvas.draw {
            canvas.background(0)
            canvas.noFill()
            canvas.stroke(255)
            canvas.strokeWeight(1)
            canvas.strokeCap(cap)
            if !row.solid { canvas.shader(shader) }
            canvas.translate(64, 64 + dy)
            canvas.rotate(row.angle)
            canvas.beginShape()
            for index in 0...160 {
                let x = -20 + Float(index) * 0.25
                if row.solid { canvas.vertex(x, 0, 0) } else { canvas.vertex(x, 0) }
            }
            canvas.endShape()
        }
        return try light(canvas)
    }

    /// 端の形 `cap` の両端の面積 (描く画素で太さ `drawn` のとき)。**切り方の式 (``ThinEndCut/extent(of:weight:)``) から
    /// 作らない** — 延ばす長さを誤っても期待が一緒に動かないように、端の形の定義から書く。`.project` は太さの半分ずつ
    /// 延ばした長方形 2 つ、`.round` は直径が太さの半円 2 つ (#3748)。
    static func endArea(_ cap: StrokeCap, drawn: Double) -> Double {
        switch cap {
        case .square: 0
        case .project: drawn * drawn
        case .round: Double.pi * drawn * drawn / 4
        }
    }

    /// 曲線の刻みのように、端の線分が描く画素の 1 列より短い開いた線 (第 34 波の反証の指摘)。長さ 40 の一直線を
    /// 0.25 刻みの点で並べると、端の列には短い線分が何本も入る。端の列の片を先に積むので、後の帯が列に入っても
    /// 列の光の量は割合のとおりになる。期待は帯 `40 × 太さ` と両端の面積 (``endArea(_:drawn:)``) の和 (描く画素)。
    @Test("端の線分が 1 列より短い開いた線も、置く位置によらず太さぶんの濃さで出る", arguments: subdivided)
    func subdividedLinesKeepTheirWeight(_ row: Subdivided) throws {
        let canvas = try Self.makeCanvas(density: row.density)
        let shader = try canvas.makeShader("float4 paint(Fragment in, Values values) { return in.color; }")
        let drawn = Double(row.density)
        let expected = 40 * drawn * Double(row.density) + Self.endArea(row.cap, drawn: drawn)
        var broken: [String] = []
        for step in 0..<12 {
            let dy = Float(step) * 0.25
            let measured = try Self.subdividedLight(row, cap: row.cap, dy: dy, canvas: canvas, shader: shader)
            if abs(measured - expected) > 0.1 * expected {
                broken.append("dy \(dy): 光の量 \(measured) (期待 \(expected))")
            }
        }
        #expect(broken.isEmpty, "\(row.testDescription): \(broken.joined(separator: " / "))")
    }

    /// **端の光の量は、端の形の面積ぶん**。同じ置き方の四角い端の線との差を、両端の面積 (``endArea(_:drawn:)``) の
    /// ±10% で見る (#3748)。線全体の ±10% では、長さ 40 の線の端の延長を誤っても (細かさ 0.25 で端の面積は全体の 2%)
    /// 見えないので、端の量だけを取り出して比べる。列の境目で切った線は置く位置によらず光の量が合う (誤差は全体の
    /// 0.1% 以下) ので、差は端の面積に近い。
    @Test(
        "端の光の量は、同じ線の四角い端との差で見て、端の形の面積ぶんになる (#3748)",
        arguments: subdivided.filter { $0.cap != .square })
    func capsAddTheirArea(_ row: Subdivided) throws {
        let canvas = try Self.makeCanvas(density: row.density)
        let shader = try canvas.makeShader("float4 paint(Fragment in, Values values) { return in.color; }")
        let expected = Self.endArea(row.cap, drawn: Double(row.density))
        var broken: [String] = []
        for step in 0..<12 {
            let dy = Float(step) * 0.25
            let capped = try Self.subdividedLight(row, cap: row.cap, dy: dy, canvas: canvas, shader: shader)
            let flat = try Self.subdividedLight(row, cap: .square, dy: dy, canvas: canvas, shader: shader)
            if abs(capped - flat - expected) > 0.1 * expected {
                broken.append("dy \(dy): 端の光の量 \(capped - flat) (期待 \(expected))")
            }
        }
        #expect(broken.isEmpty, "\(row.testDescription): \(broken.joined(separator: " / "))")
    }

    /// 保持した形の控えの鍵 (#3745 の決定 A)。開いた四角い端を持つ輪郭は、副画素の位相が変わると組み直し、描く画素で
    /// 整数だけずれた置き場所 (同じ位相) では組み直さない。閉じた輪郭は位相で組み直さない。丸い端 (既定) は
    /// 位相を鍵に含めない (#3864・``retainedRoundEndsReuseAcrossPhases()``)。
    ///
    /// どの位相でも、その場で引いた同じ線と画素ごとに同じ絵になる。違う位相の片を使い回すと、線全体の光の量は
    /// 変わらない (片はどれも主軸に幅 1 か整数の幅なので、平行移動しても拾う中心の数が同じ) が、端の画素の濃さが
    /// 置いた位相の割合と食い違い、切り口の頂点も境目 (整数の座標) から外れる。
    @Test(
        "開いた端の保持した形は、位相ごとに組み直して控え、どの位相でもその場で引いた線と同じ絵になる",
        arguments: [StrokeCap.square])
    func retainedOpenEndsAreKeyedByPhase(_ cap: StrokeCap) throws {
        // 細かさ 0.25 なら、ずらしを 1/8 刻みで選ぶと描く画素の位相がちょうど表せる (同じ位相の比べが丸めで割れない)
        let density: Float = 0.25
        let canvas = try Self.makeCanvas(density: density)
        var line: Shape?
        var ring: Shape?
        try canvas.draw {
            canvas.noFill()
            canvas.stroke(255)
            canvas.strokeWeight(1)
            canvas.strokeCap(cap)
            line = canvas.createShape {
                canvas.beginShape()
                canvas.vertex(-20, 0)
                canvas.vertex(20, 0)
                canvas.endShape()
            }
            ring = canvas.createShape {
                canvas.beginShape()
                canvas.vertex(-20, -10)
                canvas.vertex(20, -10)
                canvas.vertex(20, 10)
                canvas.vertex(-20, 10)
                canvas.endShape(.close)
            }
        }
        let (open, closed) = (try #require(line), try #require(ring))
        let shader = try canvas.makeShader("float4 paint(Fragment in, Values values) { return in.color; }")
        // 出す画素 1 / 細かさ は描く画素 1 つ (同じ位相)
        let pixel = 1 / density
        func place(_ shape: Shape, dy: Float) throws -> (pixels: PixelBuffer, rebuilt: Int) {
            let before = canvas.thinStrokesRebuilt
            try canvas.draw {
                canvas.background(0)
                canvas.translate(64, 64 + dy)
                canvas.rotate(0.81)
                canvas.shape(shape)
            }
            return (try canvas.target.readPixels(), canvas.thinStrokesRebuilt - before)
        }
        /// 同じ置き方でその場で引いた線 (三角形の経路)。控えた片が正しい位相のものなら、同じ片になる
        func direct(dy: Float) throws -> PixelBuffer {
            try canvas.draw {
                canvas.background(0)
                canvas.noFill()
                canvas.stroke(255)
                canvas.strokeWeight(1)
                canvas.strokeCap(cap)
                canvas.shader(shader)
                canvas.translate(64, 64 + dy)
                canvas.rotate(0.81)
                canvas.beginShape()
                canvas.vertex(-20, 0)
                canvas.vertex(20, 0)
                canvas.endShape()
            }
            return try canvas.target.readPixels()
        }
        // 帯は縦寄り (0.81 rad) なので、行の位相を 1/4 ずつ回す。同じ位相へ戻る置き場所も挟む
        var broken: [String] = []
        for dy in [Float(0), 1, 2, 3, pixel, 1 + 2 * pixel, 1.5, 0.5, 2.5, 0] {
            let placed = try place(open, dy: dy).pixels
            let reference = try direct(dy: dy)
            var worst: Float = 0
            for y in 0..<reference.height {
                for x in 0..<reference.width { worst = max(worst, abs(placed[x, y].red - reference[x, y].red)) }
            }
            // 8 bit の 2 段まで (被覆を運ぶ値の丸め)
            if worst > 2 / 255 { broken.append("dy \(dy): 画素の差 \(worst)") }
        }
        #expect(broken.isEmpty, "\(cap): \(broken.joined(separator: " / "))")
        // 新しい位相は組み直し、同じ位相は控えを使う
        #expect(try place(open, dy: 0.125).rebuilt == 1)
        #expect(try place(open, dy: 0.125 + pixel).rebuilt == 0)
        #expect(try place(open, dy: 0.125).rebuilt == 0)
        // 閉じた輪郭は、位相を変えても組み直さない (最初の 1 度だけ)
        _ = try place(closed, dy: 0)
        #expect(try place(closed, dy: 0.37).rebuilt == 0)
    }

    /// 丸い端の保持した形の、控えの使い回しの実測 (#3864)。`points` は開いた線の頂点 (出す画素)。
    /// 置き場所 (`placements` の x・y のずらしと向き `angle`) ごとに置き、組み直しの回数と、その場で引いた線との光の量の比を返す。
    private static func roundRetained(
        _ points: [SIMD2<Float>], density: Float, placements: [(dx: Float, dy: Float, angle: Float)]
    ) throws -> (rebuilt: Int, worstRatio: Double) {
        let canvas = try makeCanvas(density: density)
        var line: Shape?
        try canvas.draw {
            canvas.noFill()
            canvas.stroke(255)
            canvas.strokeWeight(1)
            canvas.strokeCap(.round)
            line = canvas.createShape {
                canvas.beginShape()
                for point in points { canvas.vertex(point.x, point.y) }
                canvas.endShape()
            }
        }
        let shape = try #require(line)
        let shader = try canvas.makeShader("float4 paint(Fragment in, Values values) { return in.color; }")
        func total(_ pixels: PixelBuffer) -> Double {
            var sum = 0.0
            for y in 0..<pixels.height { for x in 0..<pixels.width { sum += Double(pixels[x, y].red) } }
            return sum
        }
        var rebuilt = 0
        var worst = 1.0
        for (dx, dy, angle) in placements {
            let before = canvas.thinStrokesRebuilt
            try canvas.draw {
                canvas.background(0)
                canvas.translate(64 + dx, 64 + dy)
                canvas.rotate(angle)
                canvas.shape(shape)
            }
            rebuilt += canvas.thinStrokesRebuilt - before
            let placed = total(try canvas.target.readPixels())
            try canvas.draw {
                canvas.background(0)
                canvas.noFill()
                canvas.stroke(255)
                canvas.strokeWeight(1)
                canvas.strokeCap(.round)
                canvas.shader(shader)
                canvas.translate(64 + dx, 64 + dy)
                canvas.rotate(angle)
                canvas.beginShape()
                for point in points { canvas.vertex(point.x, point.y) }
                canvas.endShape()
            }
            let ratio = placed / total(try canvas.target.readPixels())
            if abs(ratio - 1) > abs(worst - 1) { worst = ratio }
        }
        return (rebuilt, worst)
    }

    /// 丸い端の保持した形は、十分に長ければ位相の違う置き場所でも控えた片を使い回す (#3864)。#3748 の決定 A は丸い端も
    /// 位相ごとに組み直したが、#3859 の決定 (光の量の許容 ±25%) の下で戻した。平らな延長の片は平行移動しても面積が
    /// 変わらないので、光の量はその場で引いた線と、直線で 0.5%・折れ線で 3% 以内で変わらない (測った値は ±0.1% と ×0.984。許容の ±25% とは別)。代償: 端の
    /// 画素の濃さは、その場で引いた線と最大 0.2 ほど違う (片を作った位相の列の境目で切ったままなので)。
    @Test("丸い端の保持した形は、位相・向きが変わっても組み直さず、光の量はその場で引いた線と変わらない (#3864)", arguments: [false, true])
    func retainedRoundEndsReuseAcrossPhases(bent: Bool) throws {
        // 描く画素で長さ 40 (``ThinStrokeRecipe/phaseFreeMinimumLength`` 以上)
        let placements: [(dx: Float, dy: Float, angle: Float)] = [
            (0, 0, 0.81), (0.125, 0.5, 0.81), (0.5, 1.5, 0.81), (1.375, 2.375, 0.81), (0.3, 3.1, 0.81), (0.125, 0.5, 0.81),
            (0.2, 0.7, 0.3), (0.9, 0.1, 1.2), (0.45, 0.45, 2.4),
        ]
        let points: [SIMD2<Float>] = bent ? [SIMD2(-40, 0), SIMD2(0, 10), SIMD2(40, 0)] : [SIMD2(-40, 0), SIMD2(40, 0)]
        let (rebuilt, worst) = try Self.roundRetained(points, density: 0.5, placements: placements)
        // 向きが違う置き場所 (2x2 が違う) は組み直す。向き 4 通りで 4 回、同じ向きの位相違いでは組み直さない
        #expect(rebuilt == 4, "組み直した回数: \(rebuilt)")
        // 測った値: 直線は ±0.1%、折れ線は ×0.984 (端を切るかどうかの判定が位相で変わる分)。許容の ±25% とは別に、これを越えたら知らせる
        #expect(abs(worst - 1) <= (bent ? 0.03 : 0.005), "光の量の比 \(worst)")
    }

    /// 短い丸い端の線 (描く画素で ``ThinStrokeRecipe/phaseFreeMinimumLength`` より短い) と、両端が近い線 (描く画素で
    /// ``ThinStrokeRecipe/phaseFreeMinimumGap`` より近い) は、位相ごとに組み直す (#3864)。端を切るかどうか (端の列の中で
    /// 曲がるか・両端の片が重なるか) が位相で変わり、控えを使い回すと短い折れ線の光の量がその場で組んだ値の ×1.26〜×1.30 になった。
    @Test(
        "短い丸い端の線と両端が近い線は、位相が変わると組み直す (#3864)",
        arguments: [
            // 描く画素で長さ 3 ほどの折れ線
            [SIMD2<Float>(-3, 0), SIMD2(0, 0.75), SIMD2(3, 0)],
            // 長さは足りるが、両端が描く画素で 1 しか離れていない開いた周
            [SIMD2<Float>(-10, 2), SIMD2(-10, 10), SIMD2(10, 10), SIMD2(10, -10), SIMD2(-10, -10), SIMD2(-10, 0)],
        ])
    func retainedShortRoundEndsRebuildByPhase(points: [SIMD2<Float>]) throws {
        let placements: [(dx: Float, dy: Float, angle: Float)] = [(0, 0, 0.81), (0.125, 0.5, 0.81), (0.5, 1.5, 0.81)]
        let (rebuilt, _) = try Self.roundRetained(points, density: 0.5, placements: placements)
        #expect(rebuilt == 3, "組み直した回数: \(rebuilt)")
    }

    /// 切るかどうかの選び方 (平面)。端点の重なる開いた周 (A → B → C → A) は、両端の列の片が同じ列を 2 度数えるので
    /// 切らない (第 34 波の反証の指摘)。置き場所の位相が分からない組み方 (畳む雛形) も切らない。丸い端は、面積の等しい
    /// 平らな延長 (太さ × π / 8) で切る (#3748)。
    @Test("平面の線は、端点の重なる開いた周・位相の分からない組み方では端を切らず、丸い端は面積の等しい延長で切る")
    func planeEndsAreCutOnlyWhereTheyCanBe() throws {
        let canvas = try Self.makeCanvas(density: 0.5)
        // translate(64, 64.3) の後に rotate(0.81)
        let (cosine, sine) = (cos(Float(0.81)), sin(Float(0.81)))
        let matrix = simd_float4x4(
            SIMD4(cosine, sine, 0, 0), SIMD4(-sine, cosine, 0, 0), SIMD4(0, 0, 1, 0), SIMD4(64, 64.3, 0, 1))
        func ends(
            _ points: [SIMD2<Float>], cap: StrokeCap, snapped: Bool = true, dash: Bool = false
        ) throws -> Canvas.ThinEnds {
            var outline = Canvas.Outline(points: points, isClosed: false, fills: false)
            outline.isDashPiece = dash
            let thin = try #require(canvas.thinOutline(outline, weight: 1, placedBy: matrix, snapped: snapped))
            canvas.strokeCap(cap)
            var drawn: [SIMD2<Float>] = []
            for point in points { drawn.append(thin.linear * point) }
            return canvas.thinEnds(drawn, outline: outline, thin: thin, offset: .zero)
        }
        let (a, b, c) = (SIMD2<Float>(-20, 0), SIMD2<Float>(20, 0), SIMD2<Float>(0, 25))
        let apart = try ends([a, b, c], cap: .square)
        #expect(apart.startCut != nil && apart.endCut != nil)
        let touching = try ends([a, b, c, a], cap: .square)
        #expect(touching.startCut == nil && touching.endCut == nil)
        // 丸い端は、四角い端の端点から `.project` の延長 (太さの半分) の π / 4 倍 (太さ × π / 8) だけ外で切る
        let round = try ends([a, b, c], cap: .round)
        let project = try ends([a, b, c], cap: .project)
        for (square, rounded, projected) in [
            (apart.startCut, round.startCut, project.startCut), (apart.endCut, round.endCut, project.endCut),
        ] {
            let (flat, tip, far) = (try #require(square), try #require(rounded), try #require(projected))
            #expect(abs(simd_length(tip.tip - flat.tip) / simd_length(far.tip - flat.tip) - .pi / 4) < 1e-4)
        }
        let unsnapped = try ends([a, b, c], cap: .project, snapped: false)
        #expect(unsnapped.startCut == nil && unsnapped.endCut == nil)
        // 破線の片は切らない (隣の片の端の列の片と型板で食い合う・#3745 の反証 1)
        let dash = try ends([a, b, c], cap: .square, dash: true)
        #expect(dash.startCut == nil && dash.endCut == nil)
        // 端の線分が 1 列より短く、列の中で曲がる線は、その端を切らない (#3745 の反証 3)。曲がらない側の端は切る
        let bent = try ends([a, a + SIMD2(0.4, 0), a + SIMD2(0.4, 30), b], cap: .square)
        #expect(bent.startCut == nil && bent.endCut != nil)
        canvas.strokeCap(.round)
    }

    /// 切るかどうかの選び方 (立体)。辺が 1 本だけ来る点が端で、端点の重なる開いた周は切らない (第 34 波の反証の指摘)。
    /// 画面で潰れた辺を持つ点 (同じ位置の点を続けた周の端) も端にしない。
    @Test("立体の線は、端点の重なる開いた周と画面で潰れた端の辺では端を切らない")
    func solidEndsAreCutOnlyWhereTheyCanBe() throws {
        let canvas = try Self.makeCanvas(density: 0.5)
        let thin = try #require(canvas.solidThinBand(weight: 1))
        let camera = StrokeCamera(canvas.currentCamera, width: canvas.width, height: canvas.height)
        func cuts(
            _ points: [SIMD3<Float>], edges given: [(Int, Int)]? = nil, cap: StrokeCap = .square
        ) -> SolidEndCuts {
            var edges: [(Int, Int)] = []
            for index in 0..<(points.count - 1) { edges.append((index, index + 1)) }
            canvas.strokeCap(cap)
            defer { canvas.strokeCap(.round) }
            return canvas.solidEndCuts(world: points, edges: given ?? edges, curveSteps: [], thin: thin, camera: camera)
        }
        func pieces(_ points: [SIMD3<Float>]) -> Int { cuts(points).pieces.count }
        let (a, b, c) = (SIMD3<Float>(40, 50, 0), SIMD3<Float>(90, 70, 0), SIMD3<Float>(60, 100, 0))
        #expect(pieces([a, b, c]) == 2)
        #expect(pieces([a, b, c, a]) == 0)
        // 丸い端も切る (面積の等しい平らな延長・#3748)
        #expect(cuts([a, b, c], cap: .round).pieces.count == 2)
        // 同じ位置の点を続けた端は、画面で潰れた辺を持つので端にならない (向こうの端だけ切る)
        #expect(pieces([a, a, b, c]) == 1)
        // 2 点の短い線で両端が同じ列なら、1 つの片
        #expect(pieces([a, a + SIMD3(0.3, 0.1, 0)]) == 1)
        // 端の辺が 1 列より短く、列の中で曲がる線は、その端を切らない (#3745 の反証 3)
        #expect(pieces([a, a + SIMD3(0.3, 0, 0), a + SIMD3(0.3, 30, 0), b]) == 1)
        // 1 つにまとめた短い辺の端が別の端と重なれば、相方も一緒に切らない (#3745 の反証 2)。相方の端の帯だけ
        // 境目で切ると、短い辺が消える
        let netted = cuts(
            [a, a + SIMD3(0.3, 0.1, 0), a + SIMD3(0.6, 0, 0), SIMD3(80, 60, 0)], edges: [(0, 1), (2, 3)])
        #expect(netted.cuts[0] == nil && netted.cuts[1] == nil && netted.cuts[2] == nil)
        // 離れた端 (点 3) だけを切る
        #expect(netted.pieces.map(\.point) == [3])
        // 開いた端の多い網でも、別の辺の端どうしで重なる片は 1 つも残さない (#3748 の反証 7)。重なりは x の下端で
        // 並べて近い相手だけと比べるので、並びで間に別の端が挟まる組も見落とさないことを、狭い所に短い辺を密に
        // 置いた網で見る
        var state: UInt64 = 0x3748
        func next() -> Float {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Float(state >> 40) / Float(1 << 24)
        }
        var crowd: [SIMD3<Float>] = []
        var crowdEdges: [(Int, Int)] = []
        for index in 0..<300 {
            let start = SIMD3(40 + next() * 40, 40 + next() * 40, 0)
            let angle = next() * 2 * .pi
            crowd.append(start)
            crowd.append(start + SIMD3(cos(angle), sin(angle), 0) * (2 + next() * 6))
            crowdEdges.append((2 * index, 2 * index + 1))
        }
        let crowded = cuts(crowd, edges: crowdEdges, cap: .round)
        #expect(!crowded.pieces.isEmpty)
        var overlapping = 0
        for (one, first) in crowded.pieces.enumerated() {
            for second in crowded.pieces[(one + 1)...] where second.edge != first.edge {
                guard let box = first.cut.box, let other = second.cut.box else { continue }
                if ThinEndCut.overlap(box, other) { overlapping += 1 }
            }
        }
        #expect(overlapping == 0, "重なったまま残った片の組 \(overlapping)")
    }
}
