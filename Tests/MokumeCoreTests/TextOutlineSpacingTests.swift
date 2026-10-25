// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation
import Testing
import simd

@testable import MokumeCore

/// 輪郭の点を等間隔に取り直す計算 (`Canvas.resample(_:spacing:)`)。GPU を使わない ([#2447])。
///
/// **点の間隔は、周の長さを均等に割った値になる。** 長方形のように周の長さが手で書ける形で、
/// 割る数・間隔・点が元の線の上にあることを突き合わせる。
///
/// [#2447]: https://github.com/mokume-metal/mokume/issues/2447
@Suite("輪郭の点の取り直し")
struct TextOutlineResampleTests {
    /// 100 × 20 の長方形 (周の長さ 240)。`I` の縦画のように、辺の途中に点が無い形。
    private let rectangle: [SIMD2<Float>] = [
        SIMD2(10, 10), SIMD2(110, 10), SIMD2(110, 30), SIMD2(10, 30),
    ]

    /// 閉じた周の隣り合う点の距離 (最後の点から最初の点へ戻る間を含む)。
    private func gaps(_ points: [SIMD2<Float>]) -> [Float] {
        points.indices.map { simd_length(points[($0 + 1) % points.count] - points[$0]) }
    }

    @Test("周の長さを均等に割る: 240 を 6 で割った 40 点、どの間隔も 6")
    func splitsThePerimeterEvenly() {
        let (points, capped) = Canvas.resample(rectangle, spacing: 6)
        #expect(!capped)
        #expect(points.count == 40)
        // 角の間の辺の上では、点の距離は割った値そのもの。角をまたぐ 1 つ (30 と 10 の継ぎ目) だけが
        // 弦になって短くなりうるが、6 を越えることはない
        #expect(gaps(points).allSatisfy { $0 <= 6 + 1e-4 })
        #expect(gaps(points).filter { abs($0 - 6) < 1e-4 }.count >= 36)
        // 始点は元の周の最初の点
        #expect(points[0] == rectangle[0])
    }

    @Test("割り切れないときは切り上げて、間隔が spacing を越えない")
    func roundsTheCountUp() {
        // 240 / 7 = 34.28… → 35 点、間隔は 240 / 35
        let (points, _) = Canvas.resample(rectangle, spacing: 7)
        #expect(points.count == 35)
        #expect(gaps(points).allSatisfy { $0 <= 7 + 1e-4 })
    }

    @Test("取り直した点は、元の折れ線の上にある")
    func pointsStayOnTheOriginalLine() {
        let (points, _) = Canvas.resample(rectangle, spacing: 5)
        for point in points {
            let onTop = abs(point.y - 10) < 1e-3 && (10...110).contains(point.x)
            let onBottom = abs(point.y - 30) < 1e-3 && (10...110).contains(point.x)
            let onLeft = abs(point.x - 10) < 1e-3 && (10...30).contains(point.y)
            let onRight = abs(point.x - 110) < 1e-3 && (10...30).contains(point.y)
            #expect(onTop || onBottom || onLeft || onRight, "線の上にない点 \(point)")
        }
    }

    @Test("周の長さより大きい spacing でも、3 点を返して周は潰れない")
    func aHugeSpacingKeepsThreePoints() {
        let (points, capped) = Canvas.resample(rectangle, spacing: 1e6)
        #expect(!capped)
        #expect(points.count == 3)
        #expect(Set(points.map { [$0.x, $0.y] }).count == 3, "3 点が別々の場所にある")
    }

    @Test("同じ入力からは、いつも同じ点")
    func isDeterministic() {
        #expect(Canvas.resample(rectangle, spacing: 3.3).points == Canvas.resample(rectangle, spacing: 3.3).points)
    }

    @Test("極端に小さい spacing は、点の数を上限に抑えて知らせる印を返す")
    func aTinySpacingIsCapped() {
        let (points, capped) = Canvas.resample(rectangle, spacing: 1e-9)
        #expect(capped)
        #expect(points.count == Canvas.mostPointsPerContour)
    }

    @Test("点が 1 か所に潰れた周や無限の座標を含む周は、取り直さずそのまま返す")
    func degenerateRingsAreLeftAlone() {
        let collapsed = Array(repeating: SIMD2<Float>(5, 5), count: 4)
        #expect(Canvas.resample(collapsed, spacing: 2).points == collapsed)
        let unbounded: [SIMD2<Float>] = [SIMD2(0, 0), SIMD2(.infinity, 0), SIMD2(0, 10)]
        #expect(Canvas.resample(unbounded, spacing: 2).points == unbounded)
    }
}

/// `textOutline(_:_:_:spacing:)` を、面の上で通す ([#2447])。
///
/// 書体は版が変わりにくい `Helvetica` にして、`I` (縦画だけの字) と `o` (外周と穴) を見る。
/// 字形の寸法には頼らず、**約束 (隣り合う点の距離・周の並び・省いたときの同一・知らせ)** を見る。
///
/// [#2447]: https://github.com/mokume-metal/mokume/issues/2447
@Suite(
    "textOutline の spacing",
    .enabled(
        if: RenderDevice.isAvailable,
        "この世代のコマンド構造に対応した GPU が無い実行環境ではスキップする")
)
struct TextOutlineSpacingTests {
    private func makeCanvas() throws -> Canvas {
        let canvas = try CanvasFixture.make(gpu: RenderDevice(), width: 160, height: 96)
        canvas.textFont("Helvetica")
        canvas.textSize(200)
        return canvas
    }

    private func gaps(_ points: [SIMD2<Float>]) -> [Float] {
        points.indices.map { simd_length(points[($0 + 1) % points.count] - points[$0]) }
    }

    @Test("縦画の周に、角だけでなく辺の途中にも点が並び、隣り合う点が spacing 以下になる")
    func straightEdgesGetPoints() throws {
        let canvas = try makeCanvas()
        let corners = canvas.textOutline("HI", 40, 220)
        let spaced = canvas.textOutline("HI", 40, 220, spacing: 6)
        #expect(spaced.count == corners.count, "周の数は変わらない")
        for (plain, even) in zip(corners, spaced) {
            #expect(even.points.count > plain.points.count, "辺の途中にも点がある")
            // 最後の点から最初の点へ戻る間も含めて、どの間隔も 6 画素以下
            let widest = gaps(even.outline).max() ?? 0
            #expect(widest <= 6 + 1e-3, "間隔 \(widest) が 6 を越えた")
        }
    }

    @Test("周の並びと穴の区別は、spacing を付けても変わらない")
    func orderAndHolesAreKept() throws {
        let canvas = try makeCanvas()
        let plain = canvas.textOutline("oIo", 20, 200)
        let spaced = canvas.textOutline("oIo", 20, 200, spacing: 8)
        #expect(spaced.map(\.isHole) == plain.map(\.isHole))
        #expect(spaced.contains { $0.isHole }, "検査の前提: 穴を持つ字がある")
        // 字ごとに外周が先・穴が後 (`o` は外周、穴の順)
        #expect(spaced.first?.isHole == false)
        // 送りは同じ — 取り直した周の外接は、元の周の外接とほぼ重なる
        for (plain, even) in zip(plain, spaced) {
            let a = plain.points, b = even.points
            #expect(abs(a.map(\.x).min()! - b.map(\.x).min()!) < 8)
            #expect(abs(a.map(\.x).max()! - b.map(\.x).max()!) < 8)
        }
    }

    @Test("同じ入力からは、いつも同じ点が返る")
    func isDeterministic() throws {
        let canvas = try makeCanvas()
        #expect(canvas.textOutline("mokume", 10, 200, spacing: 5) == canvas.textOutline("mokume", 10, 200, spacing: 5))
    }

    @Test("0 以下・数でない値・無限の spacing は、1 度だけ知らせて折れ目の点を返す", arguments: [Float(0), -4, .nan, .infinity, -.infinity])
    func anUnusableSpacingFallsBackToCorners(spacing: Float) throws {
        let canvas = try makeCanvas()
        let corners = canvas.textOutline("HI", 40, 220)
        #expect(!canvas.warnings.hasWarned(.invalidTextOutlineSpacing))
        #expect(canvas.textOutline("HI", 40, 220, spacing: spacing) == corners)
        let first = try #require(canvas.warnings.message(for: .invalidTextOutlineSpacing))
        #expect(first.contains("textOutline()") && first.contains("spacing"))
        // 2 度目は言い直さない (別の悪い値でも文面は最初のまま)
        #expect(canvas.textOutline("HI", 40, 220, spacing: -1) == corners)
        #expect(canvas.warnings.message(for: .invalidTextOutlineSpacing) == first)
    }

    @Test("使える spacing では知らせない")
    func aUsableSpacingIsSilent() throws {
        let canvas = try makeCanvas()
        _ = canvas.textOutline("HI", 40, 220, spacing: 6)
        #expect(!canvas.warnings.hasWarned(.invalidTextOutlineSpacing))
    }

    @Test("極端に小さい spacing は、周の点を上限に抑えて 1 度だけ知らせる")
    func aTinySpacingIsCapped() throws {
        let canvas = try makeCanvas()
        let spaced = canvas.textOutline("I", 40, 220, spacing: 1e-9)
        #expect(spaced.allSatisfy { $0.points.count == Canvas.mostPointsPerContour })
        #expect(canvas.warnings.hasWarned(.invalidTextOutlineSpacing))
    }

    @Test("空の文字列・空白だけは空のまま")
    func nothingToOutlineStaysEmpty() throws {
        let canvas = try makeCanvas()
        #expect(canvas.textOutline("", 0, 0, spacing: 5).isEmpty)
        #expect(canvas.textOutline("   ", 0, 0, spacing: 5).isEmpty)
    }
}
