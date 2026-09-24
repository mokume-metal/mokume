// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation
import Testing
import simd

@testable import MokumeCore

/// 画素の格子の約束 ([ADR-0039]) と、立体と平面の幾何の一致 ([ADR-0021] 決定 1) の検査。
/// GPU を要する。
///
/// **縁の中間値は見ない。** 経路によって縁の AA の掛け方が違う (距離関数の経路は解析的な
/// 被覆率、三角形の経路は無し) のは約束の内であり、比べたいのは**どこを覆ったか**だけで
/// ある。だから絵を「被覆 50% 以上の画素の集合」と「線形の被覆で重みを付けた重心」に
/// 畳んでから比べる (ADR-0039 決定 1)。
///
/// [ADR-0039]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0039-pixel-grid-and-edge-antialiasing.md
/// [ADR-0021]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0021-solid-space-and-frame-assembly.md
@Suite(
    "画素の格子",
    .enabled(
        if: RenderDevice.isAvailable,
        "この世代のコマンド構造に対応した GPU が無い実行環境ではスキップする")
)
struct PixelGridTests {
    private let black = LinearRGBA.linear(red: 0, green: 0, blue: 0)
    private let white = LinearRGBA.linear(red: 1, green: 1, blue: 1)

    /// 重心の差の許容 (画素)。半画素のずれを確実に捕まえ、三角形のラスタライズの
    /// 量子化 (縁に沿った 1 画素の出入り) は通す幅。
    private let centroidTolerance = 0.05

    /// 絵を幾何として読んだもの。
    private struct Coverage {
        /// 被覆 50% 以上の画素か (行優先)。
        let mask: [Bool]
        /// 線形の被覆で重みを付けた重心。画素 i の中心を i + 0.5 とする連続の座標。
        let centroid: SIMD2<Double>

        init(_ pixels: PixelBuffer) {
            var mask = [Bool](repeating: false, count: pixels.width * pixels.height)
            var weight = 0.0
            var sum = SIMD2<Double>(0, 0)
            for y in 0..<pixels.height {
                for x in 0..<pixels.width {
                    // 白を黒に置いているので、赤の成分がそのまま被覆である
                    let value = Double(pixels.components[(y * pixels.width + x) * 4])
                    mask[y * pixels.width + x] = value >= 0.5
                    weight += value
                    sum += value * SIMD2(Double(x) + 0.5, Double(y) + 0.5)
                }
            }
            self.mask = mask
            self.centroid = weight > 0 ? sum / weight : SIMD2(-1, -1)
        }

        func differingPixels(from other: Coverage) -> Int {
            zip(mask, other.mask).filter { $0 != $1 }.count
        }
    }

    private func coverage(
        width: Int = 64, height: Int = 64, _ body: (Canvas) throws -> Void
    ) throws -> Coverage {
        let canvas = try CanvasFixture.make(gpu: RenderDevice(), width: width, height: height)
        var failure: (any Error)?
        try canvas.draw {
            canvas.background(black)
            canvas.fill(white)
            canvas.stroke(white)
            do { try body(canvas) } catch { failure = error }
        }
        if let failure { throw failure }
        return Coverage(try canvas.target.readPixels())
    }

    /// - Parameters:
    ///   - allowedDifferingPixels: 白黒にした集合の食い違いを何画素まで許すか
    ///   - tolerance: 重心の差の許容 (画素)
    private func expectSameGeometry(
        _ a: Coverage, _ b: Coverage, _ what: String,
        allowedDifferingPixels: Int = 0, tolerance: Double? = nil,
        sourceLocation: SourceLocation = #_sourceLocation
    ) {
        let tolerance = tolerance ?? centroidTolerance
        let differing = a.differingPixels(from: b)
        #expect(
            differing <= allowedDifferingPixels,
            "\(what): 被覆 50% で白黒にした画素の集合が \(differing) 画素違う", sourceLocation: sourceLocation)
        #expect(
            abs(a.centroid.x - b.centroid.x) < tolerance
                && abs(a.centroid.y - b.centroid.y) < tolerance,
            "\(what): 重心が違う (\(a.centroid) / \(b.centroid))", sourceLocation: sourceLocation)
    }

    /// 置き方の組。回転と、小数の座標を混ぜる — 軸に沿って整数に置いた形は、
    /// ラスタライザの境界の規則で偶然そろってしまい、半画素のずれを隠す (#905)。
    nonisolated struct Placement: CustomTestStringConvertible, Sendable {
        let x: Float
        let y: Float
        let angle: Float
        var testDescription: String { "(\(x), \(y)) を \(angle) rad" }

        /// 重心まで比べるか。
        ///
        /// **軸に沿った縁を小数の座標に置いた組は、白黒の集合だけで見る。** AA の無い
        /// 三角形では縁が画素の境目へ丸められ、重心が最大 0.5 画素動く — 幾何の不一致では
        /// なく量子化である。半画素のずれは集合の食い違いとして出る (main では 40 画素)。
        var comparesCentroid: Bool { angle != 0 }

        static let all = [
            Placement(x: 32, y: 32, angle: 0.3),
            Placement(x: 31.3, y: 32.6, angle: 1.1),
            Placement(x: 32.4, y: 31.8, angle: 0),
        ]
    }

    // MARK: - 立体と平面 (ADR-0021 決定 1)

    @Test("奥行き 0 の面と平面の矩形は、回しても小数に置いても同じ場所を覆う", arguments: Placement.all)
    func planeAndRectCoverTheSamePlace(_ placement: Placement) throws {
        let solid = try coverage { canvas in
            canvas.noStroke()
            canvas.translate(placement.x, placement.y, 0)
            canvas.rotateZ(placement.angle)
            canvas.plane(30, 20)
        }
        let flat = try coverage { canvas in
            canvas.noStroke()
            canvas.translate(placement.x, placement.y)
            canvas.rotate(placement.angle)
            canvas.rect(-15, -10, 30, 20)
        }
        expectSameGeometry(
            solid, flat, "plane と rect", tolerance: placement.comparesCentroid ? nil : .infinity)
    }

    @Test("立体の輪郭と平面の輪郭は、奥行き 0 で同じ場所に乗る", arguments: Placement.all)
    func solidAndFlatOutlinesCoverTheSamePlace(_ placement: Placement) throws {
        // 頂点を座標で渡す。変換の積み方の違いではなく、輪郭の置き方だけを比べるため
        let corners: [SIMD2<Float>] = [SIMD2(-15, -10), SIMD2(15, -10), SIMD2(15, 10), SIMD2(-15, 10)]
        let placed = corners.map { corner in
            SIMD2(
                placement.x + corner.x * cos(placement.angle) - corner.y * sin(placement.angle),
                placement.y + corner.x * sin(placement.angle) + corner.y * cos(placement.angle))
        }
        for weight: Float in [1, 2, 3] {
            let solid = try coverage { canvas in
                canvas.noFill()
                canvas.strokeWeight(weight)
                canvas.beginShape()
                for point in placed { canvas.vertex(point.x, point.y, 0) }
                canvas.endShape(.close)
            }
            let flat = try coverage { canvas in
                canvas.noFill()
                canvas.strokeWeight(weight)
                canvas.beginShape()
                for point in placed { canvas.vertex(point.x, point.y) }
                canvas.endShape(.close)
            }
            expectSameGeometry(solid, flat, "太さ \(weight) の立体の輪郭と平面の輪郭")
        }
    }

    // MARK: - 経路をまたぐ (ADR-0039 決定 2)

    @Test("絵を貼っても、矩形の覆う場所は変わらない", arguments: Placement.all)
    func texturingDoesNotMoveTheRect(_ placement: Placement) throws {
        func rect(on canvas: Canvas) {
            canvas.noStroke()
            canvas.translate(placement.x, placement.y)
            canvas.rotate(placement.angle)
            canvas.rect(-15, -10, 30, 20)
        }
        let plain = try coverage { rect(on: $0) }
        let textured = try coverage { canvas in
            let sheet = try canvas.createImage(2, 2)
            sheet.fill(white)
            canvas.texture(sheet)
            rect(on: canvas)
        }
        expectSameGeometry(
            plain, textured, "rect と絵を貼った rect",
            tolerance: placement.comparesCentroid ? nil : .infinity)
    }

    @Test("線は、断片を付けて三角形で描いても同じ場所に乗る", arguments: Placement.all)
    func linesStayPutAcrossRoutes(_ placement: Placement) throws {
        // 太さ 1 はここで比べない。覆う画素が少なすぎて、数式の縁と AA の無い三角形を
        // この物差しで比べると、置き方が揃っていても重心が 0.25 画素揺れる (main で実測)。
        // 太さ 1 の置き方は `strokesSitOnPixelCenters` が経路ごとに直接固定する
        for weight: Float in [2, 3] {
            func line(on canvas: Canvas) {
                // 端点は切りっぱなしにする。丸い端点は、距離関数の経路では式、三角形の経路では
                // 多角形の近似になり、置き方と無関係に数画素違う
                canvas.strokeCap(.square)
                canvas.strokeWeight(weight)
                canvas.translate(placement.x, placement.y)
                canvas.rotate(placement.angle)
                canvas.line(-26, -8, 26, 8)
            }
            let form = try coverage { line(on: $0) }
            let triangles = try coverage { canvas in
                canvas.shader(try canvas.makeShader("float4 paint(Fragment in, Values values) { return in.color; }"))
                line(on: canvas)
            }
            // **細い線だけ許容を広げる。** 覆う画素が少ないので、AA の無い三角形の量子化で
            // 重心が 0.1〜0.15 画素揺れ、被覆がちょうど 50% 付近の画素が 1〜2 個入れ替わる
            // (置き方が揃っている main で実測)。半画素のずれは両方向に 0.5 動くので、
            // この幅でも確実に捕まえる
            expectSameGeometry(
                form, triangles, "太さ \(weight) の線", allowedDifferingPixels: 3, tolerance: 0.25)
        }
    }

    /// 楕円の扇の始まりと終わりの角。掃引が π 未満・π 超・一周近くの組と、始まりが
    /// 軸に乗らない組を混ぜる — 始まりが 0 の組は、始まりの辺が中心から見た角でも
    /// 媒介変数の角でも同じ向きなので、終わりの辺しか確かめない。
    nonisolated struct ArcSpan: CustomTestStringConvertible, Sendable {
        let start: Float
        let stop: Float
        var testDescription: String { "\(start)…\(stop) rad" }

        static let all = [
            ArcSpan(start: 0, stop: .pi / 4),
            ArcSpan(start: 5, stop: 5.8),
            ArcSpan(start: -7, stop: -6.2),
            ArcSpan(start: 0.4, stop: 0.4 + .pi * 1.1),
            ArcSpan(start: -2, stop: 1.5),
            ArcSpan(start: 0.3, stop: 0.3 + 2 * .pi - 0.05),
        ]
    }

    @Test(
        "楕円の扇は、断片を付けて三角形で描いても同じ場所を覆う",
        arguments: Placement.all, ArcSpan.all)
    func ellipticArcsStayPutAcrossRoutes(_ placement: Placement, _ span: ArcSpan) throws {
        // 三角形の経路は弧の点 (rx·cos t, ry·sin t) を並べた多角形で、角を媒介変数の角と
        // して扱う。距離関数の経路が内外を中心から見た角で決めると、楕円でだけ切り口が
        // 別の向きへずれる (#1448。円では 2 つの角が一致するので表に出ない)
        func arc(on canvas: Canvas) {
            canvas.noStroke()
            canvas.translate(placement.x, placement.y)
            canvas.rotate(placement.angle)
            canvas.arc(0, 0, 60, 24, span.start, span.stop)
        }
        let form = try coverage { arc(on: $0) }
        let triangles = try coverage { canvas in
            canvas.shader(try canvas.makeShader("float4 paint(Fragment in, Values values) { return in.color; }"))
            arc(on: canvas)
        }
        // **許容は、楕円そのものが経路の間で違う幅に取る。** 三角形の経路は弧を弦で近似し
        // (弦は弧の内側へ最大 0.25 画素入る)、同じ置き方で一周の楕円を描いても 7〜16 画素が
        // 入れ替わる。扇は直した後で 0〜15 画素、内外を中心から見た角で決めていた頃は
        // 33〜160 画素 (いちばん少ないのは一周近くの組) 違った (どれも実測)。重心は、覆う
        // 画素の少ない細い扇で AA の無い三角形の量子化が 0.16 画素まで揺らす (直した後に
        // 実測) ので、細い線と同じ幅まで許す
        expectSameGeometry(
            form, triangles, "楕円の扇 \(span.testDescription)", allowedDifferingPixels: 20,
            tolerance: placement.comparesCentroid ? 0.25 : .infinity)
    }

    /// 輪郭を引く扇。円と楕円、掃引が π 未満の組と π 超の組 (中心が凹の角になる) を
    /// 混ぜる。
    nonisolated struct StrokedPie: CustomTestStringConvertible, Sendable {
        let width: Float
        let height: Float
        let start: Float
        let stop: Float
        var testDescription: String { "\(width)×\(height) の \(start)…\(stop) rad" }

        static let all = [
            StrokedPie(width: 40, height: 40, start: 0.3, stop: 2.2),
            StrokedPie(width: 40, height: 40, start: 0.3, stop: 0.3 + 1.4 * .pi),
            StrokedPie(width: 46, height: 26, start: 5, stop: 6.2),
            StrokedPie(width: 46, height: 26, start: -2, stop: 1.5),
        ]
    }

    @Test(
        "輪郭つきの扇は、断片を付けて三角形で描いても、折れ目の形によらず同じ場所を覆う",
        arguments: Placement.all, StrokedPie.all)
    func strokedPiesStayPutAcrossRoutes(_ placement: Placement, _ pie: StrokedPie) throws {
        // 扇の 3 つの角 (中心と弧の両端) を、距離関数の経路は `strokeJoin` によらず真の距離で
        // 丸く出す。三角形の経路もそこを円板で埋める (#1486) — かつては `miter` / `bevel` で
        // 軸に沿った正方形を置き、`shader()` を足しただけで角の形が変わっていた
        var differing: [StrokeJoin: Int] = [:]
        for join in [StrokeJoin.round, .miter, .bevel] {
            func arc(on canvas: Canvas) {
                canvas.noFill()
                canvas.strokeWeight(10)
                canvas.strokeJoin(join)
                canvas.translate(placement.x, placement.y)
                canvas.rotate(placement.angle)
                canvas.arc(0, 0, pie.width, pie.height, pie.start, pie.stop)
            }
            let form = try coverage { arc(on: $0) }
            let triangles = try coverage { canvas in
                canvas.shader(try canvas.makeShader("float4 paint(Fragment in, Values values) { return in.color; }"))
                arc(on: canvas)
            }
            // **許容は `strokeJoin` によらず 1 つにし、`round` の組の実測で決める。** 三角形の
            // 経路は弧を弦で近似するので、帯の内縁と外縁の両方で画素が入れ替わる — 同じ置き方で
            // 同じ大きさの一周の輪郭を描いても 39〜70 画素違う。扇の `round` の組は 9〜40 画素
            // (楕円の組は 11〜30 で、円より多くはない)、重心は回した組で 0.15 画素まで揺れた
            // (どれも実測。#1486 の前後で変わらない)。角に正方形を置いていた頃の `miter` /
            // `bevel` の組は 28〜51 画素で、この許容だけでは捕まえきれない — 下の数の一致が見る
            expectSameGeometry(
                form, triangles, "\(join) の扇 \(pie.testDescription)",
                allowedDifferingPixels: 45,
                tolerance: placement.comparesCentroid ? 0.25 : .infinity)
            differing[join] = form.differingPixels(from: triangles)
        }
        // **`miter` / `bevel` の食い違いが `round` と同じ数であること。** 距離関数の経路は
        // `strokeJoin` を読まないので、三角形の経路が角を円板で埋めていれば 3 通りの絵は
        // 同じになり、食い違いも同じ数になる。角に正方形を置くと、その分だけ増える
        #expect(differing[.miter] == differing[.round], "miter と round で食い違いの数が違う")
        #expect(differing[.bevel] == differing[.round], "bevel と round で食い違いの数が違う")
    }

    /// 輪郭を引く矩形。横長・縦長と、辺が太さより短いものを混ぜる — 辺が短いと、
    /// 角を埋める形が向かいの角の側まで届く。
    nonisolated struct StrokedRect: CustomTestStringConvertible, Sendable {
        let width: Float
        let height: Float
        var testDescription: String { "\(width)×\(height)" }

        static let all = [
            StrokedRect(width: 34, height: 20),
            StrokedRect(width: 14, height: 36),
            StrokedRect(width: 2, height: 24),
        ]
    }

    @Test(
        "輪郭つきの矩形は、断片を付けて三角形で描いても、折れ目の形ごとに同じ場所を覆う",
        arguments: Placement.all, StrokedRect.all)
    func strokedRectsStayPutAcrossRoutes(_ placement: Placement, _ box: StrokedRect) throws {
        // 距離関数の経路は `bevel` の角を、角から太さの半分だけ離れた 45° の線で削ぐ。
        // 三角形の経路も矩形の角ではそこを同じ線で削ぐ (#1506) — かつては `miter` と同じ
        // 正方形で埋め、`shader()` を足しただけで削いだ角が尖っていた
        var differing: [StrokeJoin: Int] = [:]
        for join in [StrokeJoin.round, .miter, .bevel] {
            func rect(on canvas: Canvas) {
                canvas.noFill()
                canvas.strokeWeight(10)
                canvas.strokeJoin(join)
                canvas.translate(placement.x, placement.y)
                canvas.rotate(placement.angle)
                canvas.rect(-box.width / 2, -box.height / 2, box.width, box.height)
            }
            let form = try coverage { rect(on: $0) }
            let triangles = try coverage { canvas in
                canvas.shader(try canvas.makeShader("float4 paint(Fragment in, Values values) { return in.color; }"))
                rect(on: canvas)
            }
            // **許容は `strokeJoin` によらず 1 つにし、`miter` / `round` の組の実測で決める。**
            // 距離関数の経路の `miter` は箱、三角形の経路は帯と正方形の和で、同じ形になる —
            // 食い違いは 0〜2 画素。`round` は円板を多角形で近似するので 3〜10 画素違う。
            // 重心は回した組で `miter` / `round` が 0.034 画素まで、削いだ角を直した後の
            // `bevel` が 0.071 画素まで揺れた (辺 2 の矩形。削ぐ線の上の AA の有無による
            // 量子化) ので、0.1 まで許す。角に正方形を置いていた頃の `bevel` の組は 15〜18 画素
            // 違い、重心はほとんど動かなかった (正方形は角に対して対称なので) — 下の数の一致が
            // 直に捕まえる (どれも実測)
            expectSameGeometry(
                form, triangles, "\(join) の矩形 \(box.testDescription)",
                allowedDifferingPixels: 10,
                tolerance: placement.comparesCentroid ? 0.1 : .infinity)
            differing[join] = form.differingPixels(from: triangles)
        }
        // **`bevel` の食い違いが `miter` と同じ数であること。** どちらの経路も直角の角を
        // 同じ多角形 (尖らせれば箱の角、削げば 45° の線で落とした角) で出すので、食い違いは
        // 縁の量子化だけで、角の形によらない。削ぐ角を正方形で埋めると、その分だけ増える
        #expect(differing[.bevel] == differing[.miter], "bevel と miter で食い違いの数が違う")
    }

    // MARK: - 塗りと輪郭の継ぎ目

    @Test("塗りと輪郭が接する所で、下地が漏れない", arguments: [Float(1), 2, 3])
    func fillAndStrokeLeaveNoSeam(_ weight: Float) throws {
        // 白い塗りに白い輪郭。塗りの中心は画素の角、帯の中心は画面で半画素寄る
        // (ADR-0039 決定 2) ので、2 つは片側で接する。**塗り ∪ 帯に丸ごと入る画素**は
        // 真っ白でなければならない — 被覆率を無関係な重なりとして掛けると、接する側で
        // 下地が透ける (太さ 1 で最悪 25%・太さ 2 で 12% 暗くなった)
        var worst = 0.0
        var total = 0.0
        var counted = 0
        for index in 0..<6 {
            let center = SIMD2<Float>(24 + Float(index) * 0.15, 24 + Float(index) * 0.11)
            let radius = 10.3 + Float(index) * 0.37
            let canvas = try CanvasFixture.make(gpu: RenderDevice(), width: 48, height: 48)
            try canvas.draw {
                canvas.background(black)
                canvas.fill(white)
                canvas.stroke(white)
                canvas.strokeWeight(weight)
                canvas.circle(center.x, center.y, radius * 2)
            }
            let pixels = try canvas.target.readPixels()
            let fill = SIMD2<Double>(Double(center.x), Double(center.y))
            let band = fill + 0.5
            for y in 0..<48 {
                for x in 0..<48 {
                    // 画素の四角を 5x5 の標本で見て、全部が塗りか帯に入っているか
                    var inside = true
                    for j in 0..<5 where inside {
                        for k in 0..<5 {
                            let point = SIMD2(Double(x) + Double(k) * 0.25, Double(y) + Double(j) * 0.25)
                            let inFill = simd_length(point - fill) <= Double(radius)
                            let inBand = abs(simd_length(point - band) - Double(radius)) <= Double(weight) / 2
                            if !(inFill || inBand) { inside = false; break }
                        }
                    }
                    guard inside else { continue }
                    let leak = 1 - Double(pixels.components[(y * 48 + x) * 4])
                    worst = max(worst, leak)
                    total += leak
                    counted += 1
                }
            }
        }
        // 太さ 1 は帯が 1 画素幅しか無く、縁が平行とみなせない曲がり目で 6% ほど残る
        // (直す前の main の円も同じ程度に残していた)
        #expect(worst < (weight < 1.5 ? 0.08 : 0.02), "継ぎ目で下地が漏れる: 最悪 \(worst)")
        #expect(total / Double(counted) < 0.001, "継ぎ目で下地が漏れる: 平均 \(total / Double(counted))")
    }

    @Test("塗りを足しても、輪郭で塗り切られる画素は輪郭の色のまま")
    func fillNeverCoversTheStroke() throws {
        // 形の経路は塗りと輪郭を 1 つの断片で重ねる。輪郭の位置の出し方や重ね方を
        // 変えたとき、**輪郭だけで描けば塗り切られる画素**が、塗りを足した絵でも輪郭の色の
        // ままであることを見る。扇形の直線の辺で、塗りの距離場から輪郭をずらす近似の向きを
        // 取り違え、塗りと輪郭を両方持つ扇形からだけ直線の辺の輪郭が消えていた (#1174)
        let red = LinearRGBA.linear(red: 1, green: 0, blue: 0)
        let shapes: [(String, (Canvas) -> Void)] = [
            ("rect", { $0.rect(-14, -9, 28, 18) }),
            ("ellipse", { $0.ellipse(0, 0, 30, 20) }),
            ("arc 0…1.25π", { $0.arc(0, 0, 36, 36, 0, .pi * 1.25) }),
            ("arc 0.4…1.1π", { $0.arc(0, 0, 36, 30, 0.4, .pi * 1.1) }),
            ("arc 1…2.6", { $0.arc(0, 0, 32, 32, 1, 2.6) }),
        ]
        for (name, shape) in shapes {
            for angle: Float in [0, 0.35] {
                // 太さ 1 は小数の位置や回転で 1 画素も塗り切らないことがあり、比べる画素が残らない
                for weight: Float in [2, 3] {
                    func picture(fills: Bool) throws -> PixelBuffer {
                        let canvas = try CanvasFixture.make(gpu: RenderDevice(), width: 64, height: 64)
                        try canvas.draw {
                            canvas.background(black)
                            canvas.fill(red)
                            canvas.stroke(white)
                            canvas.strokeWeight(weight)
                            if !fills { canvas.noFill() }
                            canvas.translate(32.3, 31.6)
                            canvas.rotate(angle)
                            shape(canvas)
                        }
                        return try canvas.target.readPixels()
                    }
                    let strokeOnly = try picture(fills: false)
                    let both = try picture(fills: true)
                    var covered = 0
                    var weakest: Float = 1
                    for index in stride(from: 0, to: strokeOnly.components.count, by: 4)
                    where strokeOnly.components[index + 1] >= 1 {
                        // 輪郭だけで塗り切られた画素 (緑が 1)。塗りを足した絵でも白のまま
                        covered += 1
                        weakest = min(weakest, Float(both.components[index + 1]))
                    }
                    // **帯の縁の数 % は許す。** 塗りと輪郭を両方持つ楕円は、輪郭の距離場を塗りから
                    // 1 次の近似でずらすので (`mokume_shifted`)、曲がりのきつい所で帯の縁の画素の
                    // 被覆率が数 % 違う。取り違えは輪郭が塗りに置き換わる (緑が半分以下になる)
                    #expect(covered > 0, "\(name): 輪郭が 1 画素も塗り切られていない")
                    #expect(
                        weakest >= 0.9,
                        "\(name) (\(angle) rad・太さ \(weight)): 塗りが輪郭を覆った (輪郭の緑が \(weakest) まで落ちた)")
                }
            }
        }
    }

    // MARK: - 約束そのもの

    @Test("塗りの縁は、整数の座標で画素の境目に乗る")
    func fillsSitOnPixelCorners() throws {
        // 整数の中心・整数の直径の円は、画素の角を中心に左右上下が対称に塗られる
        let circle = try coverage(width: 48, height: 48) { canvas in
            canvas.noStroke()
            canvas.circle(24, 24, 20)
        }
        #expect(abs(circle.centroid.x - 24) < 0.01 && abs(circle.centroid.y - 24) < 0.01, "\(circle.centroid)")

        // 三角形で描く多角形。軸に沿って整数に置くと、ラスタライザの境界の規則で偶然
        // そろってずれを隠すので、(24, 24) の周りに 90° 回しても重なる 36 角形を少し回して置く
        let polygon = try coverage(width: 48, height: 48) { canvas in
            canvas.noStroke()
            canvas.beginShape()
            for index in 0..<36 {
                let angle = 0.1 + Float(index) * 2 * .pi / 36
                canvas.vertex(24 + 10.3 * cos(angle), 24 + 10.3 * sin(angle))
            }
            canvas.endShape(.close)
        }
        #expect(abs(polygon.centroid.x - 24) < 0.01 && abs(polygon.centroid.y - 24) < 0.01, "\(polygon.centroid)")
    }

    @Test("線の中心は、整数の座標で画素の中心に乗る")
    func strokesSitOnPixelCenters() throws {
        let line = try coverage(width: 48, height: 48) { canvas in
            canvas.strokeWeight(1)
            canvas.line(10, 4, 10, 44)
        }
        #expect(abs(line.centroid.x - 10.5) < 0.01, "\(line.centroid)")

        // 同じ線を、断片を付けて三角形の経路で描く
        let triangles = try coverage(width: 48, height: 48) { canvas in
            canvas.shader(try canvas.makeShader("float4 paint(Fragment in, Values values) { return in.color; }"))
            canvas.strokeCap(.square)
            canvas.strokeWeight(1)
            canvas.line(10, 4, 10, 44)
        }
        #expect(abs(triangles.centroid.x - 10.5) < 0.01, "\(triangles.centroid)")

        let outline = try coverage(width: 48, height: 48) { canvas in
            canvas.noFill()
            canvas.strokeWeight(1)
            canvas.beginShape()
            canvas.vertex(14, 14)
            canvas.vertex(34, 14)
            canvas.vertex(34, 30)
            canvas.vertex(14, 30)
            canvas.endShape(.close)
        }
        #expect(abs(outline.centroid.x - 24.5) < 0.01 && abs(outline.centroid.y - 22.5) < 0.01, "\(outline.centroid)")
    }
}
