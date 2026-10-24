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

        /// - Parameter channel: 被覆として読む成分 (0 が赤・2 が青)
        init(_ pixels: PixelBuffer, channel: Int = 0) {
            var mask = [Bool](repeating: false, count: pixels.width * pixels.height)
            var weight = 0.0
            var sum = SIMD2<Double>(0, 0)
            for y in 0..<pixels.height {
                for x in 0..<pixels.width {
                    // 白を黒に置いているので、赤の成分がそのまま被覆である
                    let value = Double(pixels.components[(y * pixels.width + x) * 4 + channel])
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

    /// 継ぎ目の漏れを数える地・塗り・輪郭 (どれも灰の線形の値)。
    ///
    /// **地が、塗りだけ・重なり・帯だけに丸ごと入る画素の色 (3 つ) の外にあるように選ぶ。**
    /// 塗り ∪ 帯に丸ごと入る画素は、4 つの面積の和の読み (ADR-0039 決定 5) ではその 3 色の
    /// 面積の重みつきの平均で、地は混ざらない。黒地に白では、加算の重なりは 2・差と除外の
    /// 重なりは 0 (白と白が打ち消す)・比較暗と乗算はどこも 0 になり、地との差が読めない
    /// 混ぜ方がある。線形でない 6 つは 3 色が 1 つに揃うように、加算と減算は 3 色の範囲の
    /// 外に地が来るように選んだ:
    ///
    /// | 混ぜ方 | 地 | 塗り・輪郭 | 塗りだけ / 重なり / 帯だけ |
    /// | --- | --- | --- | --- |
    /// | 重ねる・比較明・スクリーン | 0 | 1 | 1 / 1 / 1 |
    /// | 加算 | 0 | 1 | 1 / 2 / 1 |
    /// | 減算 | 1 | 0.5 | 0.5 / 0 / 0.5 |
    /// | 比較暗・乗算 | 1 | 0 | 0 / 0 / 0 |
    /// | 差 | 1 | 2/3 | 1/3 / 1/3 / 1/3 |
    /// | 除外 | 0 | 0.5 | 0.5 / 0.5 / 0.5 |
    private func seamPalette(_ mode: BlendMode) -> (ground: Float, ink: Float) {
        switch mode {
        case .blend, .add, .lightest, .screen, .replace: return (0, 1)
        case .subtract: return (1, 0.5)
        case .darkest, .multiply: return (1, 0)
        case .difference: return (1, 2.0 / 3)
        case .exclusion: return (0, 0.5)
        }
    }

    @Test(
        "塗りと輪郭が接する所で、下地が漏れない",
        arguments: [
            BlendMode.blend, .add, .subtract, .lightest, .darkest,
            .difference, .exclusion, .multiply, .screen,
        ],
        [Float(1), 2, 3])
    func fillAndStrokeLeaveNoSeam(_ mode: BlendMode, _ weight: Float) throws {
        // 塗りと輪郭が同じ色の円。塗りの中心は画素の角、帯の中心は画面で半画素寄る
        // (ADR-0039 決定 2) ので、2 つは片側で接する。**塗り ∪ 帯に丸ごと入る画素**に
        // 地が混ざってはならない — 被覆率を無関係な重なりとして掛けると、接する側で
        // 下地が透ける (重ねる混ぜ方の太さ 1 で最悪 25%・太さ 2 で 12% 暗くなった)。
        // 下地を読む混ぜ方も同じ (塗りと輪郭を別々に下地と混ぜていた頃は、比較明の
        // 太さ 1 で最悪 24%・太さ 2 で 12% 暗くなった・#1818)
        let (groundValue, inkValue) = seamPalette(mode)
        let ground = LinearRGBA.linear(red: groundValue, green: groundValue, blue: groundValue)
        let ink = LinearRGBA.linear(red: inkValue, green: inkValue, blue: inkValue)
        // 塗りだけ・重なり・帯だけに丸ごと入る画素の色は、太い輪郭の矩形を塗り → 輪郭の順に
        // 分けて描いて読む (式を写さない)。漏れは、画素の値が 3 色の範囲から地の側へ
        // はみ出した分を、範囲の端から地までの距離で割ったもの
        let whole: [Float] = try {
            let canvas = try CanvasFixture.make(gpu: RenderDevice(), width: 48, height: 48)
            try canvas.draw {
                canvas.background(ground)
                canvas.blendMode(mode)
                canvas.strokeWeight(16)
                canvas.fill(ink)
                canvas.noStroke()
                canvas.rect(8, 8, 32, 32)
                canvas.noFill()
                canvas.stroke(ink)
                canvas.rect(8, 8, 32, 32)
            }
            let pixels = try canvas.target.readPixels()
            // 帯は x = 0.5〜16.5、塗りは x = 8〜40
            return [pixels[24, 24].red, pixels[12, 24].red, pixels[4, 24].red]
        }()
        let (low, high) = (Double(whole.min() ?? 0), Double(whole.max() ?? 0))
        let groundLevel = Double(groundValue)
        #expect(groundLevel < low || groundLevel > high, "\(mode): 地が 3 色の範囲の中にある (\(whole))")
        func leak(_ value: Double) -> Double {
            groundLevel < low
                ? max(0, low - value) / (low - groundLevel)
                : max(0, value - high) / (groundLevel - high)
        }
        var worst = 0.0
        var total = 0.0
        var counted = 0
        for index in 0..<6 {
            let center = SIMD2<Float>(24 + Float(index) * 0.15, 24 + Float(index) * 0.11)
            let radius = 10.3 + Float(index) * 0.37
            let canvas = try CanvasFixture.make(gpu: RenderDevice(), width: 48, height: 48)
            try canvas.draw {
                canvas.background(ground)
                canvas.blendMode(mode)
                canvas.fill(ink)
                canvas.stroke(ink)
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
                    let leaked = leak(Double(pixels.components[(y * 48 + x) * 4]))
                    worst = max(worst, leaked)
                    total += leaked
                    counted += 1
                }
            }
        }
        // 太さ 1 は帯が 1 画素幅しか無く、縁が平行とみなせない曲がり目で 4% ほど残る
        // (2026-10-06 の実測で、どの混ぜ方も最悪 3.5〜3.6%)。太さ 2 以上は 0.05% 以下で、
        // 上限は 1% に取る — 塗りと輪郭を別々に下地と混ぜていた頃の差 (`.difference`) は
        // 太さ 2 で 1.98% で、2% の上限では直す前も緑だった (#1818)
        #expect(worst < (weight < 1.5 ? 0.08 : 0.01), "\(mode): 継ぎ目で下地が漏れる: 最悪 \(worst)")
        #expect(
            total / Double(counted) < 0.001, "\(mode): 継ぎ目で下地が漏れる: 平均 \(total / Double(counted))")
    }

    // MARK: - 1 画素より細い塗りと、潰れた帯の穴 (#2186)

    /// 細い塗りや潰れた帯の穴を持つ `rect` と楕円。和集合を**真の幾何**で数えるための形。
    ///
    /// 和集合を描いた絵 (塗りだけ・輪郭だけを細かい面に描いたもの) から取らないのは、輪郭だけの
    /// 絵そのものが同じ口で欠けるからである — 欠けた帯は和集合から外れ、漏れが数えられない。
    nonisolated struct SeamShape: CustomTestStringConvertible, Sendable {
        let name: String
        let isEllipse: Bool
        /// rect は半幅・半高、楕円は 2 つの半径 (形自身の座標)
        let half: SIMD2<Double>
        let weight: Float
        /// 扇 (`arc`) の開始角と掃引 (媒介変数の角・#2747)。nil なら扇ではない。扇は `isEllipse` も真にする
        /// (半径は `half`)。輪郭だけの帯を数える (塗りの内外は数えない)
        var arc: SIMD2<Double>?
        var testDescription: String { "\(name)・太さ \(weight)" }

        @MainActor func draw(on canvas: Canvas) {
            let size = SIMD2<Float>(Float(half.x * 2), Float(half.y * 2))
            if let arc {
                // 扇の周の帯 (中心の角・2 本の半径・穴) を見る形。閉じ方を渡さない既定は開いた弧の帯で、
                // こうした部分を持たない (弦で結んだ形と開いた弧は `ArcClosureShapeTests` が見る・#2428)
                canvas.arc(0, 0, size.x, size.y, Float(arc.x), Float(arc.x + arc.y), .pie)
            } else if isEllipse {
                canvas.ellipse(0, 0, size.x, size.y)
            } else {
                canvas.rect(-size.x / 2, -size.y / 2, size.x, size.y)
            }
        }

        /// 輪郭 (扇なら周の 2 本の半径と弧、楕円なら周) までの距離 (符号なし)。`rect` は持たない。
        func boundaryDistance() -> ((SIMD2<Double>) -> Double)? {
            if let arc {
                return PixelGridTests.makeArcBoundaryDistance(radii: half, start: arc.x, sweep: arc.y)
            }
            guard isEllipse else { return nil }
            let radii = half
            return { abs(PixelGridTests.ellipseDistance($0, radii)) }
        }

        func inFill(_ p: SIMD2<Double>) -> Bool {
            if let arc { return PixelGridTests.sectorContains(p, radii: half, start: arc.x, sweep: arc.y) }
            if isEllipse {
                let q = p / half
                return simd_dot(q, q) <= 1
            }
            return abs(p.x) <= half.x && abs(p.y) <= half.y
        }

        /// 帯 (外縁の内で内縁の外) に入るか。`q` は輪郭の位置 (画面で半画素寄せた所) での座標。
        /// 角は `miter` (既定)。
        func inBand(_ q: SIMD2<Double>) -> Bool {
            let halfWeight = Double(weight) / 2
            if isEllipse { return abs(PixelGridTests.ellipseDistance(q, half)) <= halfWeight }
            guard abs(q.x) <= half.x + halfWeight, abs(q.y) <= half.y + halfWeight else { return false }
            let hole = half - halfWeight
            return hole.x <= 0 || hole.y <= 0 || abs(q.x) >= hole.x || abs(q.y) >= hole.y
        }
    }

    /// 点 `p` が楕円の扇 (中心を含む) の内か。**扇の内外は、中心から弧の端へ向かう 2 本の半直線で
    /// 決める** (角は媒介変数の角・`mokume_arcRegionField` の説明)。
    nonisolated static func sectorContains(
        _ p: SIMD2<Double>, radii: SIMD2<Double>, start: Double, sweep: Double
    ) -> Bool {
        let q = p / radii
        guard simd_dot(q, q) <= 1 else { return false }
        let end = start + sweep
        let end1 = radii * SIMD2(cos(start), sin(start))
        let end2 = radii * SIMD2(cos(end), sin(end))
        let side1 = simd_dot(p, SIMD2(end1.y, -end1.x))
        let side2 = simd_dot(p, SIMD2(-end2.y, end2.x))
        return sweep <= .pi ? (side1 <= 0 && side2 <= 0) : (side1 <= 0 || side2 <= 0)
    }

    /// 扇の周 (中心から弧の両端への 2 本の線分と弧) までの距離 (符号なし) を返す関数を作る (#2747)。
    /// 円の扇は閉じた式で、楕円の扇は媒介変数の点列で最も近い点を探し、その前後で三分探索して詰める。
    /// 楕円の距離場の近似 (`mokume_ellipseField`) とは独立に、帯の内外を決めるために使う。
    nonisolated static func makeArcBoundaryDistance(
        radii: SIMD2<Double>, start: Double, sweep: Double
    ) -> (SIMD2<Double>) -> Double {
        let end = start + sweep
        let end1 = radii * SIMD2(cos(start), sin(start))
        let end2 = radii * SIMD2(cos(end), sin(end))
        func segment(_ p: SIMD2<Double>, _ end: SIMD2<Double>) -> Double {
            let along = max(0, min(1, simd_dot(p, end) / max(simd_dot(end, end), 1e-12)))
            return simd_length(p - end * along)
        }
        if radii.x == radii.y {
            let radius = radii.x
            return { p in
                let around = (atan2(p.y, p.x) - start).truncatingRemainder(dividingBy: 2 * .pi)
                let angle = around < 0 ? around + 2 * .pi : around
                let arc = angle <= sweep
                    ? abs(simd_length(p) - radius)
                    : min(simd_distance(p, end1), simd_distance(p, end2))
                return min(arc, segment(p, end1), segment(p, end2))
            }
        }
        let count = 512
        let points = (0...count).map { index -> SIMD2<Double> in
            let t = start + sweep * Double(index) / Double(count)
            return radii * SIMD2(cos(t), sin(t))
        }
        return { p in
            var nearest = 0
            var best = Double.infinity
            for (index, point) in points.enumerated() {
                let d = simd_distance_squared(p, point)
                if d < best {
                    best = d
                    nearest = index
                }
            }
            func distance(_ t: Double) -> Double { simd_distance(p, radii * SIMD2(cos(t), sin(t))) }
            var low = start + sweep * Double(max(0, nearest - 1)) / Double(count)
            var high = start + sweep * Double(min(count, nearest + 1)) / Double(count)
            for _ in 0..<30 {
                let a = low + (high - low) / 3
                let b = high - (high - low) / 3
                if distance(a) < distance(b) { high = b } else { low = a }
            }
            return min(distance((low + high) / 2), segment(p, end1), segment(p, end2))
        }
    }

    /// 点から楕円の縁までの符号つきの距離 (内で負)。**真の距離**を二分法で解く
    /// (D. Eberly, "Distance from a Point to an Ellipse")。距離関数の経路の楕円は近似の距離場
    /// (`mokume_ellipseField`) なので、それと独立に和集合を決めるために使う。
    nonisolated static func ellipseDistance(_ point: SIMD2<Double>, _ radii: SIMD2<Double>) -> Double {
        // 長いほうを x に揃え、第 1 象限へ折る
        var p = SIMD2(abs(point.x), abs(point.y))
        var r = radii
        if r.x < r.y {
            p = SIMD2(p.y, p.x)
            r = SIMD2(r.y, r.x)
        }
        let inside = (p.x / r.x) * (p.x / r.x) + (p.y / r.y) * (p.y / r.y) <= 1
        let distance: Double
        if p.y > 0 && p.x > 0 {
            let z = p / r
            let ratio = (r.x / r.y) * (r.x / r.y)
            let n0 = ratio * z.x
            var low = z.y - 1
            var high = inside ? 0 : sqrt(n0 * n0 + z.y * z.y) - 1
            var s = 0.0
            for _ in 0..<80 {
                s = (low + high) / 2
                let g = (n0 / (s + ratio)) * (n0 / (s + ratio)) + (z.y / (s + 1)) * (z.y / (s + 1)) - 1
                if g > 0 { low = s } else { high = s }
            }
            let nearest = SIMD2(ratio * p.x / (s + ratio), p.y / (s + 1))
            distance = simd_length(nearest - p)
        } else if p.y > 0 {
            // 短い軸の上。いちばん近いのは短い軸の端
            distance = abs(p.y - r.y)
        } else if r.x * p.x < r.x * r.x - r.y * r.y {
            // 長い軸の上で、縮閉線の尖りより中心の側。いちばん近いのは軸の外の点
            let x0 = r.x * p.x / (r.x * r.x - r.y * r.y)
            distance = simd_length(SIMD2(r.x * x0 - p.x, r.y * sqrt(max(0, 1 - x0 * x0))))
        } else {
            distance = abs(p.x - r.x)
        }
        return inside ? -distance : distance
    }

    /// #2186 の本文の 4 通りの置き方 (48×48 の面の中心からのずれと回転)。
    private static let seamPlacements: [SIMD3<Float>] = [
        SIMD3(0.15, 0.11, 0), SIMD3(0.3, -0.38, 0.35), SIMD3(-0.29, 0.44, 1.1), SIMD3(0.52, 0.27, 2.3),
    ]

    /// 塗り ∪ 帯に丸ごと入る画素の漏れ (最悪・平均・数えた画素)。
    ///
    /// 画素は四角を 1/8 画素だけ広げた所を 9x9 の標本と、4 辺を 201 点ずつ見て、全部が塗りか帯に
    /// 入っているかで決める (細い形は帯の幅も 1〜2 画素なので、5x5 の標本では隙間を取り逃す。
    /// 9x9 だけでも、尖った細い穴の端が標本の間をすり抜け、穴の掛かる画素を丸ごと覆われると
    /// 数えた)。漏れの読み方は
    /// `fillAndStrokeLeaveNoSeam` と同じで、画素の値が「塗りだけ・重なり・帯だけ」の 3 色の範囲から
    /// 地の側へはみ出した分を、範囲の端から地までの距離で割ったもの。
    private func seamLeaks(
        _ shape: SeamShape, _ mode: BlendMode, fills: Bool, canvasSize: Int, center: SIMD2<Float>
    ) throws -> (
        worst: Double, total: Double, counted: Int, where: String, worstExcess: Double, excessAt: String
    ) {
        let (groundValue, inkValue) = seamPalette(mode)
        let ground = LinearRGBA.linear(red: groundValue, green: groundValue, blue: groundValue)
        let ink = LinearRGBA.linear(red: inkValue, green: inkValue, blue: inkValue)
        let whole: [Float] = try {
            let canvas = try CanvasFixture.make(gpu: RenderDevice(), width: 48, height: 48)
            try canvas.draw {
                canvas.background(ground)
                canvas.blendMode(mode)
                canvas.strokeWeight(16)
                canvas.fill(ink)
                canvas.noStroke()
                canvas.rect(8, 8, 32, 32)
                canvas.noFill()
                canvas.stroke(ink)
                canvas.rect(8, 8, 32, 32)
            }
            let pixels = try canvas.target.readPixels()
            return [pixels[24, 24].red, pixels[12, 24].red, pixels[4, 24].red]
        }()
        // 塗りを持たない形は帯だけの色だけで読む
        let range = fills ? whole : [whole[2]]
        let (low, high) = (Double(range.min() ?? 0), Double(range.max() ?? 0))
        let groundLevel = Double(groundValue)
        #expect(groundLevel < low || groundLevel > high, "\(mode): 地が 3 色の範囲の中にある (\(whole))")
        func leak(_ value: Double) -> Double {
            groundLevel < low
                ? max(0, low - value) / (low - groundLevel)
                : max(0, value - high) / (groundLevel - high)
        }
        var worst = 0.0
        var worstAt = ""
        var total = 0.0
        var counted = 0
        // 帯の外 (穴の中も) に丸ごと入る画素に、帯が滲み出た分 (#2742)。帯に丸ごと入る画素の欠けと
        // 対になる。楕円の帯だけ、画素の中心が帯の縁から 0.9 画素より外にある画素 (1/8 画素広げた
        // 四角は中心から 0.9 画素の内に収まる) を数える
        var worstExcess = 0.0
        var excessAt = ""
        func excess(_ value: Double) -> Double {
            groundLevel < low
                ? max(0, value - groundLevel) / (low - groundLevel)
                : max(0, groundLevel - value) / (groundLevel - high)
        }
        let halfWeight = Double(shape.weight) / 2
        let boundary = shape.boundaryDistance()
        for placement in Self.seamPlacements {
            let origin = SIMD2<Double>(Double(center.x + placement.x), Double(center.y + placement.y))
            let angle = Double(placement.z)
            let canvas = try CanvasFixture.make(gpu: RenderDevice(), width: canvasSize, height: canvasSize)
            try canvas.draw {
                canvas.background(ground)
                canvas.blendMode(mode)
                canvas.fill(ink)
                canvas.stroke(ink)
                if !fills { canvas.noFill() }
                canvas.strokeWeight(shape.weight)
                canvas.translate(Float(origin.x), Float(origin.y))
                canvas.rotate(Float(angle))
                shape.draw(on: canvas)
            }
            let pixels = try canvas.target.readPixels()
            // 画面 → 形自身の座標 (回転の逆)。帯は画面で半画素寄る (ADR-0039 決定 2)
            let (c, s) = (cos(angle), sin(angle))
            func local(_ point: SIMD2<Double>) -> SIMD2<Double> {
                let d = point - origin
                return SIMD2(c * d.x + s * d.y, -s * d.x + c * d.y)
            }
            let shift = local(origin + 0.5)
            // 塗りに入る点では帯の距離を解かない (楕円の真の距離は点ごとに二分法を回す・#3010)
            func covered(_ point: SIMD2<Double>) -> Bool {
                let p = local(point)
                if fills && shape.inFill(p) { return true }
                let q = p - shift
                return boundary.map { $0(q) <= halfWeight } ?? shape.inBand(q)
            }
            let reach = max(shape.half.x, shape.half.y) + halfWeight + 2
            let lowest = max(0, Int(min(origin.x, origin.y) - reach))
            let highest = min(canvasSize, Int(max(origin.x, origin.y) + reach) + 1)
            for y in lowest..<highest {
                for x in lowest..<highest {
                    // 画素の中心から帯の縁までの距離が 0.9 画素より離れていれば、1/8 画素広げた四角
                    // (中心から 0.9 画素の内に収まる) は丸ごと帯の中か外で、標本を見なくてよい。
                    // 丸ごと帯の中なら塗りの有無によらず覆われる。帯の外は塗りが覆いうるので、塗りの
                    // 無い形だけで決める (#3010)
                    let centerDistance = boundary.map {
                        $0(local(SIMD2(Double(x) + 0.5, Double(y) + 0.5)) - shift)
                    }
                    var inside = true
                    var decided = false
                    if let centerDistance {
                        if centerDistance <= halfWeight - 0.9 {
                            decided = true
                        } else if !fills, centerDistance > halfWeight + 0.9 {
                            inside = false
                            decided = true
                        }
                    }
                    if !decided {
                        for j in 0..<9 where inside {
                            for k in 0..<9 {
                                let point = SIMD2(
                                    Double(x) - 0.125 + Double(k) * 1.25 / 8,
                                    Double(y) - 0.125 + Double(j) * 1.25 / 8)
                                if !covered(point) { inside = false; break }
                            }
                        }
                        // 9x9 の標本の間をすり抜ける細い穴の端を、4 辺を 201 点ずつ見て拾う
                        if inside {
                            edges: for t in 0...200 {
                                let u = -0.125 + Double(t) * 1.25 / 200
                                for point in [
                                    SIMD2(Double(x) + u, Double(y) - 0.125), SIMD2(Double(x) + u, Double(y) + 1.125),
                                    SIMD2(Double(x) - 0.125, Double(y) + u), SIMD2(Double(x) + 1.125, Double(y) + u),
                                ] where !covered(point) {
                                    inside = false
                                    break edges
                                }
                            }
                        }
                    }
                    if !inside, let centerDistance, !fills {
                        let away = abs(centerDistance - halfWeight)
                        if away > 0.9 {
                            let extra = excess(Double(pixels.components[(y * canvasSize + x) * 4]))
                            if extra > worstExcess {
                                worstExcess = extra
                                excessAt = "(\(x), \(y)) を \(placement) で"
                            }
                        }
                    }
                    guard inside else { continue }
                    let leaked = leak(Double(pixels.components[(y * canvasSize + x) * 4]))
                    if leaked > worst {
                        worst = leaked
                        worstAt = "(\(x), \(y)) を \(placement) で"
                    }
                    total += leaked
                    counted += 1
                }
            }
        }
        return (worst, total, counted, worstAt, worstExcess, excessAt)
    }

    /// 1 画素より細い塗りに輪郭を付けた形 (#2186 の完了条件 1)。
    nonisolated static let thinFillShapes: [SeamShape] = [
        SeamShape(name: "rect(-0.3, -10, 0.6, 20)", isEllipse: false, half: SIMD2(0.3, 10), weight: 1),
        SeamShape(name: "ellipse(0, 0, 0.7, 20)", isEllipse: true, half: SIMD2(0.35, 10), weight: 1),
    ]

    /// 1 画素より細い塗りと輪郭を両方持つ形も、継ぎ目で下地を漏らさない ([#2186])。
    ///
    /// 細い塗り (`isThinFill`) は両縁を見る積で数えるが、帯の内縁は縁 1 本の距離場のままだった。
    /// 太さが塗りの幅を越えると帯の穴は潰れて「どこにも無い」はずなのに、`rect` は負の半幅が
    /// 縁の渡し (1 画素) の内に残って内縁の被覆が 0 にならず、楕円は近似の距離場が長軸の近くで
    /// 先端までの距離を返して内縁が画素を丸ごと覆い、帯が欠けた。直す前は `.blend` の
    /// `ellipse(0, 0, 0.7, 20)` で太さ 1・2 とも最悪 31.7% (本文の測り方)。上限は
    /// `fillAndStrokeLeaveNoSeam` と同じ。
    ///
    /// [#2186]: https://github.com/mokume-metal/mokume/issues/2186
    @Test(
        "1 画素より細い塗りと輪郭が接する所で、下地が漏れない",
        arguments: [
            BlendMode.blend, .add, .subtract, .lightest, .darkest,
            .difference, .exclusion, .multiply, .screen,
        ],
        [Float(1), 2])
    func thinFillAndStrokeLeaveNoSeam(_ mode: BlendMode, _ weight: Float) throws {
        for base in Self.thinFillShapes {
            let shape = SeamShape(name: base.name, isEllipse: base.isEllipse, half: base.half, weight: weight)
            let measured = try seamLeaks(shape, mode, fills: true, canvasSize: 48, center: SIMD2(24, 24))
            #expect(measured.counted > 0, "\(mode)・\(shape): 丸ごと覆われる画素が無い")
            #expect(
                measured.worst < (weight < 1.5 ? 0.08 : 0.01),
                "\(mode)・\(shape): 継ぎ目で下地が漏れる: 最悪 \(measured.worst) \(measured.where)")
            #expect(
                measured.total / Double(max(measured.counted, 1)) < 0.001,
                "\(mode)・\(shape): 継ぎ目で下地が漏れる: 平均 \(measured.total / Double(max(measured.counted, 1)))")
        }
    }

    /// 帯の穴が潰れる・1 画素より細い形 (#2186 の完了条件 2)。面の大きさと中心も持つ。
    nonisolated static let collapsedHoleShapes: [(shape: SeamShape, canvasSize: Int)] = [
        (SeamShape(name: "rect(-0.3, -10, 0.6, 20)", isEllipse: false, half: SIMD2(0.3, 10), weight: 1), 48),
        (SeamShape(name: "rect(-0.3, -10, 0.6, 20)", isEllipse: false, half: SIMD2(0.3, 10), weight: 2), 48),
        (SeamShape(name: "ellipse(0, 0, 0.7, 20)", isEllipse: true, half: SIMD2(0.35, 10), weight: 1), 48),
        (SeamShape(name: "ellipse(0, 0, 0.7, 20)", isEllipse: true, half: SIMD2(0.35, 10), weight: 2), 48),
        (SeamShape(name: "rect(-0.75, -10, 1.5, 20)", isEllipse: false, half: SIMD2(0.75, 10), weight: 2), 48),
        // #1562 の形
        (SeamShape(name: "ellipse(0, 0, 100, 6)", isEllipse: true, half: SIMD2(50, 3), weight: 20), 160),
    ]

    /// 太さが形より太く帯の穴が潰れた形も、輪郭だけで帯を欠かさない ([#2186])。
    ///
    /// 輪郭の帯は「外縁の内で内縁の外」で、線幅が形より太いと内縁はどこにも無い (被覆 0)。
    /// 内縁を縁 1 本の距離場で数えると、穴が潰れたことを見られない — `rect(-0.3, -10, 0.6, 20)`・
    /// 太さ 1 は内縁の半幅が −0.2 で帯の中心の画素に被覆が残り、楕円は近似の距離場が長軸の上で
    /// 先端までの距離を返すので、内縁が長軸の近くを丸ごと覆って帯が抜けた。輪郭だけの帯は
    /// 混ぜ方によらず同じ被覆で混ぜるので、`.blend` で数える。
    ///
    /// [#2186]: https://github.com/mokume-metal/mokume/issues/2186
    @Test(
        "太さが形より太く帯の穴が潰れても、輪郭だけの帯は欠けない",
        arguments: PixelGridTests.collapsedHoleShapes.indices)
    func collapsedHoleLeavesNoGapInTheBand(_ index: Int) throws {
        let (shape, size) = Self.collapsedHoleShapes[index]
        let center = SIMD2<Float>(Float(size) / 2, Float(size) / 2)
        let measured = try seamLeaks(shape, .blend, fills: false, canvasSize: size, center: center)
        #expect(measured.counted > 0, "\(shape): 帯に丸ごと入る画素が無い")
        #expect(
            measured.worst < (shape.weight < 1.5 ? 0.08 : 0.01),
            "\(shape): 帯が欠ける: 最悪 \(measured.worst) \(measured.where)")
        #expect(
            measured.total / Double(max(measured.counted, 1)) < 0.001,
            "\(shape): 帯が欠ける: 平均 \(measured.total / Double(max(measured.counted, 1)))")
    }

    /// 帯の穴が潰れてはいないが 1 画素より細い、細長い楕円。
    nonisolated static let thinHoleShapes: [SeamShape] = [
        SeamShape(name: "ellipse(0, 0, 40, 2.4)", isEllipse: true, half: SIMD2(20, 1.2), weight: 2),
        SeamShape(name: "ellipse(0, 0, 60, 1.6)", isEllipse: true, half: SIMD2(30, 0.8), weight: 1.2),
    ]

    /// 帯の穴が 1 画素より細い細長い楕円も、輪郭だけの帯を欠かさない ([#2186])。
    ///
    /// 縁 1 本の距離場は細い穴の向こう側の縁を見られない。細長い楕円では、近似の距離場
    /// (`mokume_ellipseField`) が長軸の上で先端までの距離を返すので、穴が実際の端 (長軸の上で縁
    /// から太さの半分だけ離れる所) を越えて先端の近くまで伸び、帯が丸ごと抜けていた。細い穴は
    /// 長軸に沿った穴の半幅で数える (`mokume_thinEllipseHoleCoverage`)。
    ///
    /// [#2186]: https://github.com/mokume-metal/mokume/issues/2186
    @Test(
        "帯の穴が 1 画素より細い細長い楕円も、輪郭だけの帯は欠けない",
        arguments: PixelGridTests.thinHoleShapes)
    func thinHoleLeavesNoGapInTheBand(_ shape: SeamShape) throws {
        let measured = try seamLeaks(shape, .blend, fills: false, canvasSize: 64, center: SIMD2(32, 32))
        #expect(measured.counted > 0, "\(shape): 帯に丸ごと入る画素が無い")
        // 上限は太さによらず最悪 1%・平均 0.1% (継ぎ目の検査の太さ 2 以上と同じ)。直す前は
        // 長軸の近くで帯が丸ごと抜けた (最悪 100%)。かつて 9x9 の標本だけで丸ごと覆われる画素を
        // 決めていた頃は、尖った穴の端の画素を数えて 3.6%・6.6% が残って見えた
        #expect(measured.worst < 0.01, "\(shape): 帯が欠ける: 最悪 \(measured.worst) \(measured.where)")
        #expect(
            measured.total / Double(max(measured.counted, 1)) < 0.001,
            "\(shape): 帯が欠ける: 平均 \(measured.total / Double(max(measured.counted, 1)))")
    }

    // MARK: - 細長い楕円の帯の内縁・外縁 (#2742)

    /// 太さの半分が長い軸の端の曲率半径 (`短半径² / 長半径`) を越える細長い楕円。穴は 1 画素以上
    /// ある太さを選ぶ (穴が 1 画素より細い枝は #2186 が数える)。
    nonisolated static let elongatedRingShapes: [SeamShape] = [
        // 本文の 2 つ
        SeamShape(name: "ellipse(0, 0, 100, 6)", isEllipse: true, half: SIMD2(50, 3), weight: 4),
        SeamShape(name: "ellipse(0, 0, 84, 26)", isEllipse: true, half: SIMD2(42, 13), weight: 7),
        // 帯が丸ごと抜けていた形 (2026-10-15 のコメント)
        SeamShape(name: "ellipse(0, 0, 84, 26)", isEllipse: true, half: SIMD2(42, 13), weight: 14),
        SeamShape(name: "ellipse(0, 0, 40, 10)", isEllipse: true, half: SIMD2(20, 5), weight: 6),
        SeamShape(name: "ellipse(0, 0, 30, 6)", isEllipse: true, half: SIMD2(15, 3), weight: 4),
        // 太さ 5.0 は穴の幅がちょうど 1 で #2186 の細い穴の枝に入らず、帯が丸ごと抜けていた
        SeamShape(name: "ellipse(0, 0, 100, 6)", isEllipse: true, half: SIMD2(50, 3), weight: 5),
        // 縦長 (長い向きが y)
        SeamShape(name: "ellipse(0, 0, 26, 84)", isEllipse: true, half: SIMD2(13, 42), weight: 7),
    ]

    /// 細長い楕円の帯の内縁・外縁は、真の幾何から 1% の内に収まる ([#2742])。
    ///
    /// 楕円の近似の距離場 (`mokume_ellipseField`) は、縁から離れると真の距離からずれる。太さの半分が
    /// 長い軸の端の曲率半径を越える細長い楕円では、長軸の上で先端までの距離を返し、内縁が実際の穴の
    /// 端より先まで伸びて帯が丸ごと抜けた。帯に丸ごと入る画素の欠け (`seamLeaks` の worst) と、
    /// 帯の外 (穴の中も) に丸ごと入る画素への滲み (worstExcess) の両方を、上限 1% で見る。
    /// 輪郭だけの帯は混ぜ方によらず同じ被覆で混ぜるので `.blend` で数える。
    ///
    /// [#2742]: https://github.com/mokume-metal/mokume/issues/2742
    @Test(
        "細長い楕円の輪郭の帯は、内縁も外縁も真の幾何から 1% の内に収まる",
        arguments: PixelGridTests.elongatedRingShapes)
    func elongatedEllipseRingFollowsTheTrueGeometry(_ shape: SeamShape) throws {
        let measured = try seamLeaks(shape, .blend, fills: false, canvasSize: 160, center: SIMD2(80, 80))
        #expect(measured.counted > 0, "\(shape): 帯に丸ごと入る画素が無い")
        #expect(measured.worst < 0.01, "\(shape): 帯が欠ける: 最悪 \(measured.worst) \(measured.where)")
        #expect(
            measured.total / Double(max(measured.counted, 1)) < 0.001,
            "\(shape): 帯が欠ける: 平均 \(measured.total / Double(max(measured.counted, 1)))")
        #expect(
            measured.worstExcess < 0.01,
            "\(shape): 帯の外へ滲む: 最悪 \(measured.worstExcess) \(measured.excessAt)")
    }

    /// 太さを動かしても、#2186 の細い穴の枝の境目で帯が跳ばない ([#2742])。
    ///
    /// `ellipse(0, 0, 100, 6)` は太さ 5.0 で穴の幅がちょうど 1 画素になる。穴の幅が 1 画素より細い枝
    /// (両縁を見る積) と、それ以上の枝 (距離場) が、境目の両側で同じ帯を出す。太さ 5.0 で 100%
    /// 欠け、5.02 で 0 だった。
    ///
    /// [#2742]: https://github.com/mokume-metal/mokume/issues/2742
    @Test(
        "太さを動かしても、細い穴の枝の境目で帯が欠けない",
        arguments: [Float(4.5), 4.9, 4.98, 5, 5.01, 5.02, 5.05, 5.1, 5.5])
    func elongatedEllipseRingDoesNotJumpAtTheThinHoleBoundary(_ weight: Float) throws {
        let shape = SeamShape(
            name: "ellipse(0, 0, 100, 6)", isEllipse: true, half: SIMD2(50, 3), weight: weight)
        let measured = try seamLeaks(shape, .blend, fills: false, canvasSize: 160, center: SIMD2(80, 80))
        #expect(measured.counted > 0, "\(shape): 帯に丸ごと入る画素が無い")
        #expect(measured.worst < 0.01, "\(shape): 帯が欠ける: 最悪 \(measured.worst) \(measured.where)")
        #expect(
            measured.worstExcess < 0.01,
            "\(shape): 帯の外へ滲む: 最悪 \(measured.worstExcess) \(measured.excessAt)")
    }

    /// 塗りのある細長い楕円も、帯の抜けた所に塗りの色が出ない ([#2742])。
    ///
    /// 塗りと輪郭を重ねる断片 (`.blend`) と、下地を読んで 4 つの面積に分ける断片 (`.difference`)
    /// の両方で、塗り ∪ 帯に丸ごと入る画素に下地が透けない。
    ///
    /// [#2742]: https://github.com/mokume-metal/mokume/issues/2742
    @Test(
        "塗りのある細長い楕円も、輪郭の帯が欠けない",
        arguments: [BlendMode.blend, .difference],
        PixelGridTests.elongatedRingShapes.indices)
    func elongatedEllipseWithFillLeavesNoSeam(_ mode: BlendMode, _ index: Int) throws {
        let shape = Self.elongatedRingShapes[index]
        let measured = try seamLeaks(shape, mode, fills: true, canvasSize: 160, center: SIMD2(80, 80))
        #expect(measured.counted > 0, "\(mode)・\(shape): 丸ごと覆われる画素が無い")
        #expect(
            measured.worst < 0.01, "\(mode)・\(shape): 継ぎ目で下地が漏れる: 最悪 \(measured.worst) \(measured.where)")
    }

    // MARK: - 扇の帯の穴が潰れている・細いとき (#2747)

    /// 帯の穴が潰れた扇。面の大きさも持つ。
    nonisolated static let collapsedArcShapes: [(shape: SeamShape, canvasSize: Int)] = [
        // 本文の 2 つ。1 つめは #2742 と同じ根 (楕円の近似の距離場) も踏む — 扇の外縁は太さの半分 10
        // だけ離れた所で、近似の距離場は短半径 3 の端を大きく外す
        (SeamShape(
            name: "arc(0, 0, 100, 6, −π/2, π/2)", isEllipse: true, half: SIMD2(50, 3), weight: 20,
            arc: SIMD2(-.pi / 2, .pi)), 160),
        (SeamShape(
            name: "arc(0, 0, 20, 20, 0, π)", isEllipse: true, half: SIMD2(10, 10), weight: 10.4,
            arc: SIMD2(0, .pi)), 48),
        // 掃引が π より小さい・大きい扇。内接円の半径 (`半径 · sin(掃引 / 2) / (1 + sin(掃引 / 2))`・
        // π 以上は半径の半分) より少し太い
        (SeamShape(
            name: "arc(0, 0, 40, 40, 0, π/2)", isEllipse: true, half: SIMD2(20, 20), weight: 17,
            arc: SIMD2(0, .pi / 2)), 80),
        (SeamShape(
            name: "arc(0, 0, 40, 40, 0, 1.5π)", isEllipse: true, half: SIMD2(20, 20), weight: 20.4,
            arc: SIMD2(0, 1.5 * .pi)), 80),
        // 楕円の扇。内接円の半径は短半径以下
        (SeamShape(
            name: "arc(0, 0, 80, 20, 0, π)", isEllipse: true, half: SIMD2(40, 10), weight: 22,
            arc: SIMD2(0, .pi)), 112),
    ]

    /// 扇の帯の穴が潰れていても、輪郭だけの帯は欠けず、帯の外へ滲まない ([#2747])。
    ///
    /// 扇の内縁は、帯の穴が潰れていても縁 1 本の式 (`ring − 太さの半分`) のままだった。穴が潰れている
    /// (扇の内接円の半径が太さの半分以下) と、内縁は「どこにも無い」はずなのに、被覆が縁の渡し (1 画素)
    /// の内に残って帯が欠ける (`arc(0, 0, 20, 20, 0, π)`・太さ 10.4 で 18.8%)。細長い楕円の扇は、
    /// 近似の距離場が長軸の上で先端までの距離を返すので、内縁が長軸に沿って帯を丸ごと抜く (#2186 の
    /// `ellipse(80, 80, 100, 6)` と同じ形)。
    ///
    /// [#2747]: https://github.com/mokume-metal/mokume/issues/2747
    @Test(
        "扇の帯の穴が潰れても、輪郭だけの帯は欠けず滲まない",
        arguments: PixelGridTests.collapsedArcShapes.indices)
    func collapsedArcHoleLeavesNoGapInTheBand(_ index: Int) throws {
        let (shape, size) = Self.collapsedArcShapes[index]
        let center = SIMD2<Float>(Float(size) / 2, Float(size) / 2)
        let measured = try seamLeaks(shape, .blend, fills: false, canvasSize: size, center: center)
        #expect(measured.counted > 0, "\(shape): 帯に丸ごと入る画素が無い")
        #expect(measured.worst < 0.01, "\(shape): 帯が欠ける: 最悪 \(measured.worst) \(measured.where)")
        #expect(
            measured.total / Double(max(measured.counted, 1)) < 0.001,
            "\(shape): 帯が欠ける: 平均 \(measured.total / Double(max(measured.counted, 1)))")
        #expect(
            measured.worstExcess < 0.01,
            "\(shape): 帯の外へ滲む: 最悪 \(measured.worstExcess) \(measured.excessAt)")
    }

    /// 帯の穴が潰れてはいないが 1 画素より細い扇 (円の扇。内接円の半径が式で出る)。
    nonisolated static let thinArcHoleShapes: [(shape: SeamShape, canvasSize: Int)] = [
        // 半円の内接円の半径は 10。太さの半分 9.6・9.75 は穴の半径 0.4・0.25 (穴の幅が 1 画素に届かない)
        (SeamShape(
            name: "arc(0, 0, 40, 40, 0, π)", isEllipse: true, half: SIMD2(20, 20), weight: 19.2,
            arc: SIMD2(0, .pi)), 64),
        (SeamShape(
            name: "arc(0, 0, 40, 40, 0, π)", isEllipse: true, half: SIMD2(20, 20), weight: 19.5,
            arc: SIMD2(0, .pi)), 64),
        // 四半円の内接円の半径は 20 · sin(π/4) / (1 + sin(π/4)) = 8.28
        (SeamShape(
            name: "arc(0, 0, 40, 40, 0, π/2)", isEllipse: true, half: SIMD2(20, 20), weight: 16,
            arc: SIMD2(0, .pi / 2)), 64),
        (SeamShape(
            name: "arc(0, 0, 40, 40, 0, 1.5π)", isEllipse: true, half: SIMD2(20, 20), weight: 19.5,
            arc: SIMD2(0, 1.5 * .pi)), 64),
    ]

    /// 帯の穴が 1 画素より細い扇も、輪郭だけの帯を欠かさず、帯の外へ滲まない ([#2747])。
    ///
    /// 縁 1 本の距離場は細い穴の向こう側の縁を見られず、穴の面積より大きく数える (#2186 の `rect` と
    /// 楕円と同じ口)。扇は、穴の半径の上限 (`内接円の半径 − 太さの半分`) から両縁を見る上限
    /// (`2 · 穴の半径 / 画素あたりの距離`) を出して、内縁の被覆を抑える。
    ///
    /// [#2747]: https://github.com/mokume-metal/mokume/issues/2747
    @Test(
        "帯の穴が 1 画素より細い扇も、輪郭だけの帯は欠けず滲まない",
        arguments: PixelGridTests.thinArcHoleShapes.indices)
    func thinArcHoleLeavesNoGapInTheBand(_ index: Int) throws {
        let (shape, size) = Self.thinArcHoleShapes[index]
        let center = SIMD2<Float>(Float(size) / 2, Float(size) / 2)
        let measured = try seamLeaks(shape, .blend, fills: false, canvasSize: size, center: center)
        #expect(measured.counted > 0, "\(shape): 帯に丸ごと入る画素が無い")
        #expect(measured.worst < 0.01, "\(shape): 帯が欠ける: 最悪 \(measured.worst) \(measured.where)")
        #expect(
            measured.worstExcess < 0.01,
            "\(shape): 帯の外へ滲む: 最悪 \(measured.worstExcess) \(measured.excessAt)")
    }

    /// 楕円の扇で、穴の大きさが内接円の半径の上限と実際の間にある形 ([#2747])。
    ///
    /// 細い穴の判定が内接円の半径の**上限**だけだと、楕円の扇は上限が実際の 1.7〜2 倍に緩く、本当は細い
    /// 穴を太いと外す (`arc(0, 0, 100, 60, 0, π)`・太さ 30.1 で帯が最悪 45% 欠けた)。内接円の半径の下限
    /// (`短半径 · 円の扇の比`) からも測り、穴が細いかもしれない扇は標本で数える。
    ///
    /// [#2747]: https://github.com/mokume-metal/mokume/issues/2747
    nonisolated static let ellipticArcHoleShapes: [(shape: SeamShape, canvasSize: Int)] =
        [27.0, 29, 30, 30.1, 31, 32, 34].map { weight in
            (SeamShape(
                name: "arc(0, 0, 100, 60, 0, π)", isEllipse: true, half: SIMD2(50, 30), weight: Float(weight),
                arc: SIMD2(0, .pi)), 160)
        }

    @Test(
        "楕円の扇の穴が内接円の半径の上限と下限の間にあっても、輪郭だけの帯は欠けず滲まない",
        arguments: PixelGridTests.ellipticArcHoleShapes.indices)
    func ellipticArcHoleBetweenItsBoundsLeavesNoGap(_ index: Int) throws {
        let (shape, size) = Self.ellipticArcHoleShapes[index]
        let center = SIMD2<Float>(Float(size) / 2, Float(size) / 2)
        let measured = try seamLeaks(shape, .blend, fills: false, canvasSize: size, center: center)
        #expect(measured.counted > 0, "\(shape): 帯に丸ごと入る画素が無い")
        #expect(measured.worst < 0.01, "\(shape): 帯が欠ける: 最悪 \(measured.worst) \(measured.where)")
        #expect(
            measured.worstExcess < 0.01,
            "\(shape): 帯の外へ滲む: 最悪 \(measured.worstExcess) \(measured.excessAt)")
    }

    /// 掃引の狭い扇。中心の側の穴の角が尖る ([#2747])。
    ///
    /// 扇の中心の角 (掃引 θ) は、内側へ太さの半分だけ縮めても同じ角度の尖りになる。縁 1 本の距離場は、
    /// 尖りの先で距離が小さいまま長く残り、尖りから離れた画素まで被覆が残る (`arc(0, 0, 400, 400, …, 0.1)`・
    /// 太さ 10 で、穴は太い (半径 4.5) のに尖りの先の画素が 52% 欠けた)。尖りの先の画素は標本で数える。
    ///
    /// [#2747]: https://github.com/mokume-metal/mokume/issues/2747
    nonisolated static let narrowArcShapes: [(shape: SeamShape, canvasSize: Int)] = [
        (SeamShape(
            name: "arc(0, 0, 400, 400, 0.3, 0.4)", isEllipse: true, half: SIMD2(200, 200), weight: 10,
            arc: SIMD2(0.3, 0.1)), 460),
        (SeamShape(
            name: "arc(0, 0, 120, 120, 0.3, 0.4)", isEllipse: true, half: SIMD2(60, 60), weight: 3,
            arc: SIMD2(0.3, 0.1)), 160),
        (SeamShape(
            name: "arc(0, 0, 120, 120, 0.3, 0.6)", isEllipse: true, half: SIMD2(60, 60), weight: 8,
            arc: SIMD2(0.3, 0.3)), 160),
        (SeamShape(
            name: "arc(0, 0, 120, 120, 0.3, 0.9)", isEllipse: true, half: SIMD2(60, 60), weight: 12,
            arc: SIMD2(0.3, 0.6)), 160),
    ]

    @Test(
        "掃引の狭い扇の、尖った穴の端の近くでも、輪郭だけの帯は欠けず滲まない",
        arguments: PixelGridTests.narrowArcShapes.indices)
    func narrowArcHoleTipLeavesNoGapInTheBand(_ index: Int) throws {
        let (shape, size) = Self.narrowArcShapes[index]
        let center = SIMD2<Float>(Float(size) / 2, Float(size) / 2)
        let measured = try seamLeaks(shape, .blend, fills: false, canvasSize: size, center: center)
        #expect(measured.counted > 0, "\(shape): 帯に丸ごと入る画素が無い")
        #expect(measured.worst < 0.01, "\(shape): 帯が欠ける: 最悪 \(measured.worst) \(measured.where)")
        #expect(
            measured.worstExcess < 0.01,
            "\(shape): 帯の外へ滲む: 最悪 \(measured.worstExcess) \(measured.excessAt)")
    }

    /// 楕円の扇で、弧の最近点が扇の内外の判定と食い違う形 ([#2914])。
    ///
    /// 扇の内外は中心から弧の端への 2 本の半直線で決める (媒介変数の空間・#1448) が、輪郭の弧への距離は
    /// 楕円の法線で測る。楕円では法線の向きが中心から見た向きとずれるので、**扇の内でも、楕円全体への
    /// 最近点が弧の角の範囲の外にあり** (範囲の外の弧まで距離を測って帯が外へ滲む: `arc(0, 0, 80, 20, 0.3, 2.9)`・
    /// 太さ 22 で最大 67%)、**扇の外でも、最近点が範囲の内にある** (弧が最も近いのに線分への距離を返して帯が
    /// 欠ける)。円は一致するので起きない。穴が潰れた太い輪郭と、穴の細い輪郭の両方を掃く
    /// (縦横比 4:1・10:1・3:1 の楕円 × 開始角 × 掃引)。
    ///
    /// [#2914]: https://github.com/mokume-metal/mokume/issues/2914
    nonisolated static let ellipticArcNearestPointShapes: [(shape: SeamShape, canvasSize: Int)] = ([
        // Issue の症状の形そのもの: `arc(0, 0, 80, 20, 0.3, 2.9)` (掃引 2.6)・太さ 22
        (40, 10, 0.3, 2.6, 22),
        // 掃引 2.9 (`arc(0, 0, 80, 20, 0.3, 3.2)`)
        (40, 10, 0.3, 2.9, 22),
        // 太い輪郭 (穴が潰れる)・掃引が π 以下と越える・開始角を回す
        (40, 10, 3.8, 1.5, 22),
        (40, 10, 5.2, 3.14, 22),
        (50, 5, 3.8, 1.5, 11),
        (50, 5, 1.2, 4.2, 11),
        // 穴が残る細めの輪郭: 扇の外で帯が欠ける向き
        (40, 10, 0.0, 0.6, 8),
        (60, 20, 3.8, 1.5, 16),
    ] as [(Double, Double, Double, Double, Double)]).map { (a, b, start, sweep, weight) in
        (SeamShape(
            name: "arc(0, 0, \(Int(2 * a)), \(Int(2 * b)), \(Float(start)), \(Float(start + sweep)))", isEllipse: true,
            half: SIMD2(a, b), weight: Float(weight), arc: SIMD2(start, sweep)), 160)
    }

    @Test(
        "楕円の扇の弧の最近点が扇の内外の判定と食い違っても、輪郭だけの帯は欠けず滲まない",
        arguments: PixelGridTests.ellipticArcNearestPointShapes.indices)
    func ellipticArcNearestPointLeavesNoGapOrBleed(_ index: Int) throws {
        let (shape, size) = Self.ellipticArcNearestPointShapes[index]
        let center = SIMD2<Float>(Float(size) / 2, Float(size) / 2)
        let measured = try seamLeaks(shape, .blend, fills: false, canvasSize: size, center: center)
        #expect(measured.counted > 0, "\(shape): 帯に丸ごと入る画素が無い")
        #expect(measured.worst < 0.01, "\(shape): 帯が欠ける: 最悪 \(measured.worst) \(measured.where)")
        #expect(
            measured.worstExcess < 0.01,
            "\(shape): 帯の外へ滲む: 最悪 \(measured.worstExcess) \(measured.excessAt)")
    }

    /// 近似の距離場 (`exact` でない枝) の扇でも、輪郭の帯の縁の被覆が真の幾何から外れない ([#2914])。
    ///
    /// 近似の距離場の勾配は中心から見た向き (`p / 半径²`) で、扇の内外 (`inWedge`) と同じ向きになる。
    /// 弧を候補に入れるかを勾配だけで決めると、真の距離の枝に当てた直しが近似の枝には効かず、輪郭の帯の
    /// 縁 (弧から太さの半分離れた所) が弧の端の近くで 0.1 画素ほどずれる。既定の太さ 1 の扇は、半径比
    /// 2:1 でも近似の枝で描かれる (`mokume_needsExactRing` は近似の距離値のずれしか見ない)。`seamLeaks` は
    /// 帯に丸ごと入る画素しか見ず、太さ 1 では 1 つも無いので、帯の縁の画素の被覆を、真の距離から出した
    /// 期待値と比べる。
    ///
    /// [#2914]: https://github.com/mokume-metal/mokume/issues/2914
    private func arcBandEdgeError(_ shape: SeamShape) throws -> (worst: Double, at: String) {
        let halfWeight = Double(shape.weight) / 2
        let boundary = try #require(shape.boundaryDistance())
        var worst = 0.0
        var at = ""
        // 弧の候補が取り違えられる所は弧の端の近くの細い帯なので、置き方を 24 通り (半画素の位置と回転を
        // ずらして) 振る。見るのは弧の端から 8 画素以内の画素だけ
        let arc = try #require(shape.arc)
        let arcEnds: [SIMD2<Double>] = [arc.x, arc.x + arc.y].map { (t: Double) -> SIMD2<Double> in
            SIMD2<Double>(shape.half.x * cos(t), shape.half.y * sin(t))
        }
        let placements: [SIMD3<Float>] = (0..<24).map { (i: Int) -> SIMD3<Float> in
            let x = (Double(i) * 0.618034).truncatingRemainder(dividingBy: 1) - 0.5
            let y = (Double(i) * 0.414214).truncatingRemainder(dividingBy: 1) - 0.5
            return SIMD3<Float>(Float(x), Float(y), Float(Double(i) * 0.263))
        }
        for placement in placements {
            let origin = SIMD2<Double>(Double(80 + placement.x), Double(80 + placement.y))
            let angle = Double(placement.z)
            let canvas = try CanvasFixture.make(gpu: RenderDevice(), width: 160, height: 160)
            try canvas.draw {
                canvas.background(black)
                canvas.noFill()
                canvas.stroke(white)
                canvas.strokeWeight(shape.weight)
                canvas.translate(Float(origin.x), Float(origin.y))
                canvas.rotate(Float(angle))
                shape.draw(on: canvas)
            }
            let pixels = try canvas.target.readPixels()
            let (c, s) = (cos(angle), sin(angle))
            func local(_ point: SIMD2<Double>) -> SIMD2<Double> {
                let d = point - origin
                return SIMD2(c * d.x + s * d.y, -s * d.x + c * d.y)
            }
            let shift = local(origin + 0.5)
            for y in 10..<150 {
                for x in 10..<150 {
                    let center = local(SIMD2(Double(x) + 0.5, Double(y) + 0.5)) - shift
                    // 帯の縁から 1 画素の内だけ見る。期待する被覆は、真の距離 (64 bit) と、その画面での勾配
                    // (中心差分) から、縁 1 本ごとに「半平面と画素の正方形の重なりの面積」を取り、外縁の面積 −
                    // 内縁の面積とした値 — 描く側の被覆の式 (`mokume_pixelCdf` の差・#2991) と同じ形で、
                    // 距離の値と弧の候補の取り違えだけを見る。画素の真の面積とは、縁を直線とみなす分だけ違う
                    guard arcEnds.contains(where: { simd_distance($0, center) <= 8 }) else { continue }
                    let distance = boundary(center)
                    guard abs(distance - halfWeight) <= 1 else { continue }
                    // 中心の角 (2 本の半径が交わる先) は、描く側が画素の中を標本で数える (`mokume_sectorApex`) ので、
                    // 縁の渡しの式の期待値では測れない。この検査が見るのは弧の候補の取り違えなので外す
                    guard simd_length(center) > 4 else { continue }
                    // 画面の勾配 (画素あたりの距離の増え方)。距離は形自身の座標で測るので、画面の点から写して差分を取る
                    func distanceAt(_ point: SIMD2<Double>) -> Double { boundary(local(point) - shift) }
                    let here = SIMD2(Double(x) + 0.5, Double(y) + 0.5)
                    // 距離は弧からの**符号なしの**距離で、弧の上に折れ目がある。中心差分は折れ目で 0 になるので、
                    // 前後の片側差分の大きいほうを取る (成分の符号は面積に効かない)
                    let step = 1e-3
                    func slope(_ axis: SIMD2<Double>) -> Double {
                        let here0 = distanceAt(here)
                        return max(
                            abs(distanceAt(here + axis * step) - here0),
                            abs(here0 - distanceAt(here - axis * step))) / step
                    }
                    let gradient = SIMD2(slope(SIMD2(1, 0)), slope(SIMD2(0, 1)))
                    let truth = max(
                        0,
                        Self.halfPlaneArea(distance - halfWeight, gradient)
                            - Self.halfPlaneArea(distance + halfWeight, gradient))
                    let error = abs(Double(pixels[x, y].red) - truth)
                    if error > worst {
                        worst = error
                        at = "(\(x), \(y)) を \(placement) で 画素 \(pixels[x, y].red) 期待 \(truth)"
                    }
                }
            }
        }
        return (worst, at)
    }

    /// 半平面 `c + g · d ≤ 0` と、画素の正方形 [−0.5, 0.5]² の重なりの面積 (`mokume_pixelCdf` の写し・
    /// 64 bit・#2991)。
    nonisolated static func halfPlaneArea(_ c: Double, _ g: SIMD2<Double>) -> Double {
        let hi = max(abs(g.x), abs(g.y)), lo = min(abs(g.x), abs(g.y))
        if hi < 1e-12 { return c > 0 ? 0 : 1 }
        let s = 0.5 * (hi + lo), u = abs(c)
        if u >= s { return c > 0 ? 0 : 1 }
        // 軸に沿う縁 (短辺 0) は、幅 hi の線形の渡し
        if lo <= 1e-9 * hi { return min(1, max(0, 0.5 - c / hi)) }
        let k = 0.5 * (hi - lo), ramp = s - u
        let tail = u >= k ? ramp * ramp / (2 * lo * hi) : 0.5 - u / hi
        return c > 0 ? tail : 1 - tail
    }

    nonisolated static let approximateArcEdgeShapes: [SeamShape] = ([
        // 半径比 2:1・太さ 1 (既定の太さ)。弧の端の近くで、近似の枝の勾配だけでは弧の候補がずれる
        (50, 25, 5.4, 0.8, 1),
        (50, 25, 0.8, 3.4, 1),
        (25, 12.5, 5.4, 1.6, 1),
        (25, 12.5, 0.8, 3.4, 1),
        // 円の扇 (勾配が中心から見た向きと一致する)。この検査の物差しが円で外れないことの対照
        (30, 30, 5.4, 0.8, 1),
    ] as [(Double, Double, Double, Double, Double)]).map { (a, b, start, sweep, weight) in
        SeamShape(
            name: "arc(0, 0, \(Float(2 * a)), \(Float(2 * b)), \(Float(start)), \(Float(start + sweep)))",
            isEllipse: true, half: SIMD2(a, b), weight: Float(weight), arc: SIMD2(start, sweep))
    }

    @Test(
        "近似の距離場の楕円の扇でも、輪郭の帯の縁の被覆が真の距離の期待値から 5% の内に収まる",
        arguments: PixelGridTests.approximateArcEdgeShapes)
    func approximateArcBandEdgeFollowsTheTrueGeometry(_ shape: SeamShape) throws {
        let measured = try arcBandEdgeError(shape)
        #expect(measured.worst < 0.05, "\(shape): 帯の縁の被覆が外れる: 最悪 \(measured.worst) \(measured.at)")
    }

    /// 穴の端 (長軸の端から離れた尖りの先) の近くの画素で、帯の被覆が真の幾何の面積 (画素を 16x16 の
    /// 標本で数える) からどれだけ外れるか (最悪)。**穴を含む画素の部分被覆**を見る — `seamLeaks` は
    /// 帯に丸ごと入る画素と丸ごと外の画素しか見ない。
    private func tipCoverageError(_ shape: SeamShape) throws -> (worst: Double, at: String) {
        let halfWeight = Double(shape.weight) / 2
        let hole = shape.half.x > shape.half.y
            ? sqrt(shape.half.x * shape.half.x - shape.half.y * shape.half.y)
                * sqrt(max(0, 1 - (halfWeight / shape.half.y) * (halfWeight / shape.half.y)))
            : 0
        var worst = 0.0
        var at = ""
        for placement in Self.seamPlacements {
            let origin = SIMD2<Double>(Double(80 + placement.x), Double(80 + placement.y))
            let angle = Double(placement.z)
            let canvas = try CanvasFixture.make(gpu: RenderDevice(), width: 160, height: 160)
            try canvas.draw {
                canvas.background(black)
                canvas.noFill()
                canvas.stroke(white)
                canvas.strokeWeight(shape.weight)
                canvas.translate(Float(origin.x), Float(origin.y))
                canvas.rotate(Float(angle))
                shape.draw(on: canvas)
            }
            let pixels = try canvas.target.readPixels()
            let (c, s) = (cos(angle), sin(angle))
            func local(_ point: SIMD2<Double>) -> SIMD2<Double> {
                let d = point - origin
                return SIMD2(c * d.x + s * d.y, -s * d.x + c * d.y)
            }
            let shift = local(origin + 0.5)
            for y in 10..<150 {
                for x in 10..<150 {
                    let center = local(SIMD2(Double(x) + 0.5, Double(y) + 0.5)) - shift
                    // 穴の端の近く (長軸の向きに端から 4 画素以内・短軸の向きに帯の内)
                    guard abs(abs(center.x) - hole) <= 6, abs(center.y) <= halfWeight + 1 else { continue }
                    var covered = 0
                    for j in 0..<16 {
                        for k in 0..<16 {
                            let point = SIMD2(Double(x) + (Double(k) + 0.5) / 16, Double(y) + (Double(j) + 0.5) / 16)
                            if abs(Self.ellipseDistance(local(point) - shift, shape.half)) <= halfWeight { covered += 1 }
                        }
                    }
                    let truth = Double(covered) / 256
                    let error = abs(Double(pixels[x, y].red) - truth)
                    if error > worst {
                        worst = error
                        at = "(\(x), \(y)) を \(placement) で 画素 \(pixels[x, y].red) 真の面積 \(truth)"
                    }
                }
            }
        }
        return (worst, at)
    }

    /// 穴の尖りの先の画素でも、帯の部分被覆が真の幾何の面積から 7% の内に収まる ([#2742])。
    ///
    /// `seamLeaks` は帯に丸ごと入る画素と丸ごと外の画素だけを 1% で見る。穴を含む画素の部分被覆は、
    /// 縁 1 本の値も両縁を見る積 (長方形で数える) も穴を過大に数え、尖りの先で帯が 0.15〜0.22 薄く出た
    /// (`ellipse(0, 0, 40, 10)`・太さ 6)。穴の端に近い画素は穴の面積を標本で数え直す
    /// (`mokume_ellipseHoleSampled`・8×8 の標本なので 1 標本 = 1.6% の粗さが残る)。直した後の最悪は 6.6% (`ellipse(0, 0, 100, 6)`・太さ 5)。
    ///
    /// [#2742]: https://github.com/mokume-metal/mokume/issues/2742
    @Test(
        "穴の尖りの先の画素の部分被覆が、真の面積から 7% の内に収まる",
        arguments: [
            SeamShape(name: "ellipse(0, 0, 100, 6)", isEllipse: true, half: SIMD2(50, 3), weight: 4),
            SeamShape(name: "ellipse(0, 0, 100, 6)", isEllipse: true, half: SIMD2(50, 3), weight: 5),
            SeamShape(name: "ellipse(0, 0, 40, 10)", isEllipse: true, half: SIMD2(20, 5), weight: 6),
            SeamShape(name: "ellipse(0, 0, 30, 6)", isEllipse: true, half: SIMD2(15, 3), weight: 4),
            SeamShape(name: "ellipse(0, 0, 84, 26)", isEllipse: true, half: SIMD2(42, 13), weight: 14),
        ])
    func ellipseHoleTipKeepsItsPartialCoverage(_ shape: SeamShape) throws {
        let measured = try tipCoverageError(shape)
        #expect(measured.worst < 0.07, "\(shape): 尖りの先の部分被覆が外れる: 最悪 \(measured.worst) \(measured.at)")
    }

    /// ほぼ円の楕円に太い輪郭を付けても、長軸の上の帯は真の距離のとおりに出る ([#2742])。
    ///
    /// 真の距離の解き方 (`mokume_ellipseExactField`) は、短半径 / 長半径が 1 に近いと `m` が小さく、
    /// 内の点の根が出発点 (`zy`) よりずっと右にあって 16 回で収まらなかった (`a = 100, b = 99.9, h = 37.8`
    /// の長軸の上の行で距離が 9.8 外れた)。長軸を通る 3 行の画素の値を、真の距離から出した帯の被覆
    /// (縁 1 本ずつを 1 画素幅で渡す・`max(0, 外縁の被覆 − 内縁の被覆)`) と比べる。真の距離の枝に入る形
    /// (`mayNeedExactRing`) を選ぶ。
    ///
    /// [#2742]: https://github.com/mokume-metal/mokume/issues/2742
    @Test(
        "ほぼ円の楕円の太い輪郭は、長軸の上の帯が真の距離のとおりに出る",
        arguments: [0.99, 0.995, 0.999])
    func nearCircleEllipseKeepsTheBandOnItsLongAxis(_ ratio: Double) throws {
        let radii = SIMD2(100.0, 100.0 * ratio)
        let halfWeight = 0.378 * radii.y
        let form = FormInstance(
            kind: .ellipse, linear: SIMD4(1, 0, 0, 1), offset: .zero, half: SIMD2(Float(radii.x), Float(radii.y)),
            halfWeight: Float(halfWeight), fill: .zero, stroke: SIMD4(1, 1, 1, 1), fills: false, strokes: true,
            cap: .round, join: .miter)
        #expect(form.mayNeedExactRing(unitsPerDrawnPixel: SIMD2(1, 1)), "ratio \(ratio): 真の距離の枝に入らない形は検査にならない")
        let size = 320
        let canvas = try CanvasFixture.make(gpu: RenderDevice(), width: size, height: size)
        try canvas.draw {
            canvas.background(black)
            canvas.noFill()
            canvas.stroke(white)
            canvas.strokeWeight(Float(2 * halfWeight))
            canvas.ellipse(160, 160, Float(2 * radii.x), Float(2 * radii.y))
        }
        let pixels = try canvas.target.readPixels()
        func ramp(_ distance: Double) -> Double { min(1, max(0, 0.5 - distance)) }
        var worst = 0.0
        var at = ""
        for y in 159...161 {
            for x in 40...280 {
                // 整数の座標の楕円の帯は、画面で半画素寄る (中心の画素の角が原点)
                let q = SIMD2(Double(x) - 160, Double(y) - 160)
                let d = PixelGridTests.ellipseDistance(q, radii)
                let expected = max(0, ramp(d - halfWeight) - ramp(d + halfWeight))
                let error = abs(Double(pixels[x, y].red) - expected)
                if error > worst {
                    worst = error
                    at = "(\(x), \(y)) 画素 \(pixels[x, y].red) 期待 \(expected)"
                }
            }
        }
        #expect(worst < 0.02, "ratio \(ratio): 長軸の上の帯が真の距離から外れる: 最悪 \(worst) \(at)")
    }

    /// 帯の穴が 1 画素より細い `rect` の輪郭は、帯の面積ぶんの光を出す ([#2186])。
    ///
    /// 細い穴が画素の中に収まると、縁 1 本の距離場は穴を `0.5 + 穴の半幅` と数え、実際の穴
    /// (穴の幅) より大きく引く。帯に丸ごと入る画素は欠けないので漏れとしては数えられず、光の
    /// 総量で見る。軸に沿った `rect` は縁の被覆が箱フィルタと一致するので、総量は帯の面積に
    /// 角の画素ぶんの差だけで一致する。穴 (幅 0.4) の中心を画素の中心に置く — 縁 1 本では
    /// 1 行あたり 0.3、38 行で 11 ほど足りなくなる。
    ///
    /// [#2186]: https://github.com/mokume-metal/mokume/issues/2186
    @Test("帯の穴が 1 画素より細い rect の輪郭は、帯の面積ぶんの光を出す")
    func thinHoleRectKeepsItsLight() throws {
        let canvas = try CanvasFixture.make(gpu: RenderDevice(), width: 48, height: 64)
        try canvas.draw {
            canvas.background(black)
            canvas.noFill()
            canvas.stroke(white)
            canvas.strokeWeight(2)
            // 帯の中心は (11, 24.2) から画面で半画素寄って (11.5, 24.7)。穴は x = 11.3〜11.7
            canvas.rect(9.8, 4.2, 2.4, 40)
        }
        let pixels = try canvas.target.readPixels()
        var light = 0.0
        for index in stride(from: 0, to: pixels.components.count, by: 4) {
            light += Double(pixels.components[index])
        }
        // 外縁 4.4 × 42 から、穴 0.4 × 38 を引いた面積
        let area = 4.4 * 42 - 0.4 * 38
        #expect(abs(light - area) < 1, "帯の光が \(light) (帯の面積 \(area))")
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
                    // **1 段 (1/255) の揺れだけを許す。** 塗りと輪郭を両方持つ楕円も、輪郭の距離場は
                    // 輪郭だけの楕円と同じ形になる (曲がりのきつい内縁は式を輪郭の位置で解き直し、
                    // 近似でずらすのは誤差が 1/255 に収まる楕円だけ・`mokume_canShiftRing`・#1820)。
                    // 塗りが輪郭を覆うと、輪郭の緑が半分以下になる
                    #expect(covered > 0, "\(name): 輪郭が 1 画素も塗り切られていない")
                    #expect(
                        weakest >= 1 - 1.0 / 255,
                        "\(name) (\(angle) rad・太さ \(weight)): 塗りが輪郭を覆った (輪郭の緑が \(weakest) まで落ちた)")
                }
            }
        }
    }

    /// 下地を読む混ぜ方でも、塗りと輪郭を両方持つ形の**塗り**は、三角形の経路と同じ場所を覆う
    /// ([#1643])。
    ///
    /// 三角形の経路は塗りと輪郭を別々の三角形として混ぜるので、輪郭の帯の下にも塗りが残る。
    /// 距離関数の経路は、継ぎ目の割り戻しを下地を読む断片にも掛けていた頃、不透明な輪郭の帯の
    /// 内側半分で塗りを消していた。黒地に青の塗り・赤の輪郭を置き、青の成分だけを読む。ここで
    /// 回す 5 つの混ぜ方は、黒地に置いた青を赤が変えない (`.subtract` / `.darkest` / `.multiply`
    /// は黒地で青が残らないので外す) ので、青の成分がそのまま塗りの被覆になる。
    ///
    /// [#1643]: https://github.com/mokume-metal/mokume/issues/1643
    @Test(
        "下地を読む混ぜ方でも、輪郭の帯の下の塗りは三角形の経路と同じ場所を覆う",
        arguments: Placement.all,
        [BlendMode.add, .lightest, .screen, .difference, .exclusion])
    func compositeFillsStayPutUnderTheStroke(_ placement: Placement, _ mode: BlendMode) throws {
        let blue = LinearRGBA.linear(red: 0, green: 0, blue: 1)
        let red = LinearRGBA.linear(red: 1, green: 0, blue: 0)
        let shapes: [(String, (Canvas) -> Void)] = [
            ("rect", { $0.rect(-14, -9, 28, 18) }),
            ("ellipse", { $0.ellipse(0, 0, 36, 22) }),
            ("arc", { $0.arc(0, 0, 40, 40, 0.4, .pi * 1.5) }),
        ]
        for (name, shape) in shapes {
            func fillCoverage(triangles: Bool) throws -> Coverage {
                let canvas = try CanvasFixture.make(gpu: RenderDevice(), width: 64, height: 64)
                var failure: (any Error)?
                try canvas.draw {
                    canvas.background(black)
                    canvas.blendMode(mode)
                    canvas.fill(blue)
                    canvas.stroke(red)
                    canvas.strokeWeight(6)
                    if triangles {
                        do {
                            canvas.shader(
                                try canvas.makeShader("float4 paint(Fragment in, Values values) { return in.color; }"))
                        } catch { failure = error }
                    }
                    canvas.translate(placement.x, placement.y)
                    canvas.rotate(placement.angle)
                    shape(canvas)
                }
                if let failure { throw failure }
                return Coverage(try canvas.target.readPixels(), channel: 2)
            }
            // 許容は塗りの縁の量子化の幅 (三角形は AA を持たず、楕円と扇は弧を弦で近似する)。
            // 直した後は矩形 0・楕円 10〜11・扇 17〜23 画素違う。帯の内側半分で塗りを消して
            // いた頃は、帯 (太さ 6) の内側 3 画素の輪が丸ごと抜けて 197〜280 画素違い、重心も
            // ずれた (どれも実測)
            expectSameGeometry(
                try fillCoverage(triangles: false), try fillCoverage(triangles: true),
                "\(mode)・\(name) の塗り", allowedDifferingPixels: 30,
                tolerance: placement.comparesCentroid ? 0.1 : .infinity)
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
