// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation
import Testing

@testable import MokumeCore

/// 角を丸める 5 引数の `rect(a, b, c, d, r)` の検査 ([#2757])。GPU を要する。
///
/// 見るのは書き出した絵の画素。**半径を無視する (4 引数と同じ形にする) と赤になる**ことを、
/// 仕上げる前に確かめてある。そのほか「半径を短い辺の半分へ締めない」「輪郭の内縁を箱のままに
/// する」「`strokeJoin` を角の丸い周にも読む」を壊しても赤になる。
///
/// [#2757]: https://github.com/mokume-metal/mokume/issues/2757
@Suite(
    "角を丸めた rect",
    .enabled(
        if: RenderDevice.isAvailable,
        "この世代のコマンド構造に対応した GPU が無い実行環境ではスキップする")
)
struct RoundedRectTests {
    private let black = Color.linear(red: 0, green: 0, blue: 0)
    private let white = Color.linear(red: 1, green: 1, blue: 1)

    private func makeCanvas(width: Int = 96, height: Int = 64) throws -> Canvas {
        try CanvasFixture.make(gpu: RenderDevice(), width: width, height: height)
    }

    /// 黒地に白で塗って、出力段を通した画素を返す。
    private func picture(
        width: Int = 96, height: Int = 64, _ body: (Canvas) -> Void
    ) throws -> (image: DisplayImage, canvas: Canvas) {
        let canvas = try makeCanvas(width: width, height: height)
        try canvas.draw {
            canvas.background(black)
            canvas.fill(white)
            canvas.noStroke()
            body(canvas)
        }
        return (try canvas.target.encodeForDisplay(), canvas)
    }

    private let blackPixel = (UInt8(0), UInt8(0), UInt8(0), UInt8(255))
    private let whitePixel = (UInt8(255), UInt8(255), UInt8(255), UInt8(255))

    // MARK: - 完了条件 1: 角が丸まる

    /// 完了条件 1 の 3 つの画素。**変更前は 5 引数の `rect` が組み上がらない。** 半径を無視する
    /// (半径 0 で描く) と、隅の画素 (410, 310) が塗られて赤になる。
    @Test("rect(410, 310, 140, 36, 10) は隅が下地のまま、左の辺の中ほどと隅から半径ぶん内側が塗られる")
    func cornerIsRoundedByTheRadius() throws {
        let (image, _) = try picture(width: 560, height: 360) { canvas in
            canvas.rect(410, 310, 140, 36, 10)
        }
        #expect(image[410, 310] == blackPixel, "隅の画素が塗られている (半径が効いていない)")
        #expect(image[411, 328] == whitePixel, "左の辺の中ほどが塗られていない")
        #expect(image[420, 320] == whitePixel, "隅から半径ぶん内側が塗られていない")
        // 4 つの隅とも同じに丸まる
        #expect(image[549, 310] == blackPixel)
        #expect(image[410, 345] == blackPixel)
        #expect(image[549, 345] == blackPixel)
        // 辺の中ほどは外へ出ない
        #expect(image[409, 328] == blackPixel)
        #expect(image[480, 309] == blackPixel)
        #expect(image[480, 346] == blackPixel)
    }

    @Test("角の弧の上の画素は、縁だけが中間の濃さで出る")
    func arcPixelIsPartiallyCovered() throws {
        // 角の中心 (25, 25)・半径 15 の弧が、斜め 45° で (14.39, 14.39) を通る
        let (image, _) = try picture { canvas in
            canvas.rect(10, 10, 40, 40, 15)
        }
        let edge = image[14, 14]
        #expect(edge.red > 20 && edge.red < 250, "弧の上の画素が中間の濃さで出ていない: \(edge)")
        #expect(image[12, 12] == blackPixel, "弧の外側が塗られている")
        #expect(image[17, 17] == whitePixel, "弧の内側が塗られていない")
    }

    // MARK: - 完了条件 2・3: 締めと値の検め

    /// 半径が短い辺の半分を越えれば、短い辺の半分に締める。締めなければ、縮めた箱の半幅が負になって
    /// 形が崩れる。
    @Test("半径は短い辺の半分に締める。rect(0, 0, 100, 40, 100) は両端が半円になる")
    func radiusIsClampedToHalfTheShorterSide() throws {
        let clamped = try picture(width: 100, height: 40) { $0.rect(0, 0, 100, 40, 100) }.image
        let exact = try picture(width: 100, height: 40) { $0.rect(0, 0, 100, 40, 20) }.image
        #expect(clamped == exact, "締めた半径 (高さの半分) と同じ絵にならない")
        // 両端が半円: 左端の上下は下地、中ほどは塗り、半円の内側 (中心から 17.5) は塗り
        #expect(clamped[0, 0] == blackPixel)
        #expect(clamped[0, 39] == blackPixel)
        #expect(clamped[99, 0] == blackPixel)
        #expect(clamped[99, 39] == blackPixel)
        #expect(clamped[2, 20] == whitePixel)
        #expect(clamped[50, 0] == whitePixel, "上の辺の真ん中は塗られる")
        #expect(clamped[1, 10] == blackPixel, "半円の外側 (中心から 20.8) が塗られている")
    }

    @Test("無限の半径は短い辺の半分に締め、注意しない")
    func infiniteRadiusClampsWithoutWarning() throws {
        let infinite = try picture(width: 100, height: 40) { $0.rect(0, 0, 100, 40, Float.infinity) }
        let exact = try picture(width: 100, height: 40) { $0.rect(0, 0, 100, 40, 20) }.image
        #expect(infinite.image == exact)
        #expect(!infinite.canvas.warnings.hasWarned(.badCornerRadius))
    }

    /// 負・数でない値は 0 として、角を丸めずに描く。知らせるのは 1 度だけで、文面は口の名前と
    /// 受け取れる範囲・渡した値・使った値を名乗る。
    @Test("負の半径・数でない半径は 0 として角を丸めずに描き、1 度だけ知らせる", arguments: [-3, -Float.infinity, .nan] as [Float])
    func badRadiusFallsBackToSquareCorners(_ radius: Float) throws {
        let plain = try picture { $0.rect(10, 10, 40, 30) }.image
        let canvas = try makeCanvas()
        try canvas.draw {
            canvas.background(black)
            canvas.fill(white)
            canvas.noStroke()
            canvas.rect(10, 10, 40, 30, radius)
            canvas.rect(60, 10, 20, 20, -7)  // 2 度目は言わない
        }
        let image = try canvas.target.encodeForDisplay()
        #expect(image[10, 10] == whitePixel, "角が丸まっている")
        let message = try #require(canvas.warnings.message(for: .badCornerRadius))
        #expect(
            message == "rect(): the corner radius takes 0 or more, but \(radius) was passed, so 0 was used")
        // 角を丸めない 4 引数と同じ絵 (1 つ目の矩形だけを比べる)
        for y in 10..<40 {
            for x in 10..<50 { #expect(image[x, y] == plain[x, y]) }
        }
    }

    @Test("範囲の中の半径 (0 を含む) では注意しない", arguments: [0, 5, 1000] as [Float])
    func admittedRadiusSaysNothing(_ radius: Float) throws {
        let (_, canvas) = try picture { $0.rect(10, 10, 40, 30, radius) }
        #expect(!canvas.warnings.hasWarned(.badCornerRadius))
    }

    @Test("幅か高さが 0 以下の矩形は、半径があっても何も描かない")
    func degenerateBoxDrawsNothing() throws {
        let (image, _) = try picture { canvas in
            canvas.rect(10, 10, 0, 30, 5)
            canvas.rect(40, 10, 20, -30, 5)
        }
        for y in stride(from: 0, to: 64, by: 4) {
            for x in stride(from: 0, to: 96, by: 4) { #expect(image[x, y] == blackPixel) }
        }
    }

    // MARK: - 完了条件 4: rectMode と輪郭

    /// 同じ矩形を 4 つの読み方で書いて、どれも同じ絵になる (同じ半径で丸まる)。
    @Test("rectMode の 4 つのどれでも、同じ半径で丸まる")
    func everyRectModeRoundsAlike() throws {
        let reference = try picture { $0.rect(20, 10, 60, 40, 12) }.image
        let corners = try picture { canvas in
            canvas.rectMode(.corners)
            canvas.rect(20, 10, 80, 50, 12)
        }.image
        let center = try picture { canvas in
            canvas.rectMode(.center)
            canvas.rect(50, 30, 60, 40, 12)
        }.image
        let radius = try picture { canvas in
            canvas.rectMode(.radius)
            canvas.rect(50, 30, 30, 20, 12)
        }.image
        #expect(reference[20, 10] == blackPixel, "検査の前提: 隅が丸まっている")
        #expect(corners == reference, ".corners")
        #expect(center == reference, ".center")
        #expect(radius == reference, ".radius")
    }

    /// 輪郭の内縁が箱のままだと、弧の上 (23, 23) が穴の中に入って塗られない。外縁が箱のままだと、
    /// 隅 (20, 20) に輪郭が出る。
    @Test("輪郭は丸めた周を回る")
    func strokeFollowsTheRoundedOutline() throws {
        let canvas = try makeCanvas()
        try canvas.draw {
            canvas.background(black)
            canvas.noFill()
            canvas.stroke(white)
            canvas.strokeWeight(4)
            canvas.rect(20, 20, 60, 40, 12)
        }
        let image = try canvas.target.encodeForDisplay()
        // 周の弧は中心 (32, 32)・半径 12、帯は半径 10〜14
        #expect(image[20, 20] == blackPixel, "隅に輪郭が出ている (外縁が箱のまま)")
        #expect(image[23, 23] == whitePixel, "弧の上に輪郭が出ていない (内縁が箱のまま)")
        #expect(image[27, 27] == blackPixel, "穴の中 (中心から 6.4) が塗られている")
        #expect(image[50, 20] == whitePixel, "上の辺の上に輪郭が出ていない")
        #expect(image[50, 40] == blackPixel, "塗りが無いので中は下地のまま")
    }

    /// 太さの半分が半径以上なら、内縁 (穴) の角は直角になる。外縁は半径 `r + 太さの半分` の弧のまま。
    /// 輪郭は画面で半画素寄せて評価する (ADR-0039 決定 2) ので、太さを奇数にして帯の縁を画素の境目に乗せる。
    @Test("太さの半分が半径を越えると、輪郭の穴の角は直角で外側の角は丸い")
    func thickStrokeKeepsSquareHoleAndRoundOuterCorner() throws {
        let canvas = try makeCanvas(width: 120, height: 100)
        try canvas.draw {
            canvas.background(black)
            canvas.noFill()
            canvas.stroke(white)
            canvas.strokeWeight(21)
            canvas.rect(30, 30, 60, 50, 4)
        }
        let image = try canvas.target.encodeForDisplay()
        // 周の角の中心 (34.5, 34.5)・半径 4。外縁は半径 14.5 の弧で、(20, 20) の隅は下地
        #expect(image[20, 20] == blackPixel, "外側の角が直角になっている")
        // 穴は (41, 41) から。その隅の外 (40, 40) は帯で、内 (41, 41) は穴
        #expect(image[40, 40] == whitePixel)
        #expect(image[41, 41] == blackPixel, "穴の角が丸められて隅が塗られている")
    }

    /// 角の丸い周には折れ目が無いので、`strokeJoin` は読まない。**読むと、miter の外縁が直角に
    /// 戻り、隅 (20, 20) に輪郭が出て 3 つの絵が割れる。**
    @Test("角が丸い周では strokeJoin が効かない", arguments: [StrokeJoin.miter, .bevel, .round])
    func strokeJoinDoesNotApplyToRoundedCorners(_ join: StrokeJoin) throws {
        func outline(_ join: StrokeJoin) throws -> DisplayImage {
            let canvas = try makeCanvas()
            try canvas.draw {
                canvas.background(black)
                canvas.noFill()
                canvas.stroke(white)
                canvas.strokeWeight(6)
                canvas.strokeJoin(join)
                canvas.rect(20, 20, 60, 40, 8)
            }
            return try canvas.target.encodeForDisplay()
        }
        #expect(try outline(join) == outline(.round))
    }

    // MARK: - 完了条件 5: 4 引数の絵は変わらない

    @Test("半径 0 の 5 引数は、4 引数と 1 ビットも違わない")
    func zeroRadiusIsTheFourArgumentForm() throws {
        func scene(_ rounded: Bool) throws -> DisplayImage {
            let canvas = try makeCanvas()
            try canvas.draw {
                canvas.background(black)
                canvas.fill(white)
                canvas.stroke(.linear(red: 1, green: 0, blue: 0))
                canvas.strokeWeight(3)
                canvas.strokeJoin(.bevel)
                canvas.push()
                canvas.translate(48, 32)
                canvas.rotate(0.4)
                if rounded {
                    canvas.rect(-30, -15, 60.5, 30.25, 0)
                } else {
                    canvas.rect(-30, -15, 60.5, 30.25)
                }
                canvas.pop()
            }
            return try canvas.target.encodeForDisplay()
        }
        #expect(try scene(true) == scene(false))
    }

    // MARK: - 三角形の経路

    /// `texture()` が効いているときは距離関数の経路に入れず、円弧の刻みの周で描く。丸まる位置は
    /// 距離関数の経路と同じ。
    @Test("貼る絵がある間も角が丸まる (三角形の経路)")
    func roundsOnTheTriangleRouteToo() throws {
        let canvas = try makeCanvas(width: 160, height: 100)
        let sheet = try canvas.createImage(8, 8)
        sheet.fill(white)
        try canvas.draw {
            canvas.background(black)
            canvas.noStroke()
            canvas.texture(sheet)
            canvas.rect(10, 10, 140, 36, 10)
        }
        let image = try canvas.target.encodeForDisplay()
        #expect(image[10, 10] == blackPixel, "隅が塗られている (三角形の経路で半径が効いていない)")
        #expect(image[11, 28] == whitePixel, "左の辺の中ほどが塗られていない")
        #expect(image[20, 20] == whitePixel, "隅から半径ぶん内側が塗られていない")
        #expect(image[80, 28] == whitePixel)
    }

    @Test("半径が辺の半分ちょうどでも、三角形の経路は長さ 0 の辺を作らず両端が半円になる")
    func halfWidthRadiusOnTheTriangleRoute() throws {
        let outline = Canvas.roundedRectOutline(width: 100, height: 40, radius: 20, segments: 32)
        let points = outline.points
        for (index, point) in points.enumerated() {
            let next = points[(index + 1) % points.count]
            #expect(point != next, "長さ 0 の辺がある: \(index)")
        }
        #expect(outline.isClosed)
        #expect(outline.curveSteps.count == points.count)
        // 上の辺の両端 (20, 0) と (80, 0) が周に含まれ、角の内側 (0, 0) は含まれない
        #expect(points.contains(SIMD2(20, 0)) && points.contains(SIMD2(80, 0)))
        #expect(!points.contains(SIMD2(0, 0)))
    }
}
