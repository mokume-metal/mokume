// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation
import Testing
import simd

@testable import MokumeCore

/// 線の破線 `strokeDash` の検査 ([#2835])。
///
/// 見るものは 2 つ。**刻みの幾何** (``Canvas/dashPieces(of:curveSteps:by:)``) は GPU を要さず、
/// 切り口の位置・折れ目をまたぐ続き方・極端な値を点で見る。**画素** は GPU を要し、距離関数の線と
/// 三角形の線 (`shader()` が効いている間) の両方で、破線の途切れる所が下地のままであることを見る。
///
/// [#2835]: https://github.com/mokume-metal/mokume/issues/2835
struct StrokeDashGeometryTests {
    private func pieces(
        _ points: [SIMD2<Float>], _ length: Float, _ gap: Float, steps: [Bool] = [],
        closed: Bool = false
    ) throws -> [Canvas.DashPiece] {
        let result = Canvas.dashPieces(
            of: points, curveSteps: steps, isClosed: closed,
            by: StrokeDash(length: length, gap: gap))
        guard case .pieces(let pieces) = result else {
            Issue.record("刻めなかった: \(result)")
            return []
        }
        return pieces
    }

    @Test("長さ 10・間隔 10 の線は、10 の片が 20 おきに並ぶ")
    func straightLineIsCutEveryPeriod() throws {
        let result = try pieces([SIMD2(0, 50), SIMD2(100, 50)], 10, 10)
        try #require(result.count == 5)
        #expect(result[0].points == [SIMD2(0, 50), SIMD2(10, 50)])
        #expect(result[1].points == [SIMD2(20, 50), SIMD2(30, 50)])
        #expect(result[4].points == [SIMD2(80, 50), SIMD2(90, 50)])
    }

    @Test("線の最後が破線の途中なら、そこまでが 1 つの片になる")
    func lastDashIsClippedByTheEndOfTheLine() throws {
        let result = try pieces([SIMD2(0, 0), SIMD2(25, 0)], 10, 10)
        #expect(result.map(\.points) == [[SIMD2(0, 0), SIMD2(10, 0)], [SIMD2(20, 0), SIMD2(25, 0)]])
    }

    @Test("線の最後が間隔の中なら、片は増えない")
    func aLineEndingInAGapAddsNoPiece() throws {
        let result = try pieces([SIMD2(0, 0), SIMD2(15, 0)], 10, 10)
        #expect(result.map(\.points) == [[SIMD2(0, 0), SIMD2(10, 0)]])
    }

    @Test("線が破線の始まりちょうどで終わるなら、長さのない片は作らない")
    func aLineEndingWhereADashWouldStartAddsNoPiece() throws {
        let result = try pieces([SIMD2(0, 0), SIMD2(20, 0)], 10, 10)
        #expect(result.map(\.points) == [[SIMD2(0, 0), SIMD2(10, 0)]])
    }

    @Test("長さより短い線は、1 つの片のまま")
    func aShortLineIsOnePiece() throws {
        let result = try pieces([SIMD2(0, 0), SIMD2(3, 4)], 10, 10)
        #expect(result.map(\.points) == [[SIMD2(0, 0), SIMD2(3, 4)]])
    }

    @Test("破線の途中で曲がると、角を含む 1 つの片になる")
    func aDashKeepsTheCornerItCrosses() throws {
        // 長さ 30 の破線が、25 で曲がる折れ線をまたぐ。続きは曲がった先の 5
        let result = try pieces([SIMD2(10, 10), SIMD2(35, 10), SIMD2(35, 60)], 30, 20)
        try #require(result.count == 2)
        #expect(result[0].points == [SIMD2(10, 10), SIMD2(35, 10), SIMD2(35, 15)])
        // 間隔 20 の後の次の破線は、曲がった先の 25 から 50 (線は 75 で終わる)
        #expect(result[1].points == [SIMD2(35, 35), SIMD2(35, 60)])
    }

    @Test("折れ目で間隔が終わるなら、次の破線は折れ目から始まる")
    func aDashStartsAtACornerWhereTheGapEnds() throws {
        let result = try pieces([SIMD2(10, 10), SIMD2(60, 10), SIMD2(60, 60)], 30, 20)
        try #require(result.count == 2)
        #expect(result[0].points == [SIMD2(10, 10), SIMD2(40, 10)])
        #expect(result[1].points == [SIMD2(60, 10), SIMD2(60, 40)])
    }

    @Test("曲線の刻みの印は、片の中に残った元の点の分だけ持ち越す")
    func curveStepsFollowTheKeptPoints() throws {
        let points: [SIMD2<Float>] = [SIMD2(0, 0), SIMD2(10, 0), SIMD2(20, 0)]
        let result = try pieces(points, 15, 5, steps: [false, true, false])
        try #require(result.count == 1)
        #expect(result[0].points == [SIMD2(0, 0), SIMD2(10, 0), SIMD2(15, 0)])
        // 切り口 (端) は刻みではない
        #expect(result[0].curveSteps == [false, true, false])
    }

    @Test("長さ 0 の破線は、切り口で 2 点が重なる片 (点) になり、間隔ごとに並ぶ")
    func zeroLengthDashesAreDots() throws {
        let result = try pieces([SIMD2(0, 0), SIMD2(30, 0)], 0, 10)
        // 0・10・20 の 3 つ。30 は線の終わりで、点を置く位置に届かないので置かない
        #expect(
            result.map(\.points)
                == [[SIMD2(0, 0), SIMD2(0, 0)], [SIMD2(10, 0), SIMD2(10, 0)], [SIMD2(20, 0), SIMD2(20, 0)]])
    }

    @Test("長さ 0 の辺が混ざっても、同じ点を 2 度積まず、模様も進まない")
    func zeroLengthEdgesAreSkipped() throws {
        let result = try pieces([SIMD2(0, 0), SIMD2(0, 0), SIMD2(30, 0)], 10, 10)
        #expect(result.map(\.points) == [[SIMD2(0, 0), SIMD2(10, 0)], [SIMD2(20, 0), SIMD2(30, 0)]])
    }

    @Test("破線が頂点ちょうどで終わっても、同じ点を 2 度積まない")
    func aDashEndingExactlyOnAVertexKeepsItOnce() throws {
        let result = try pieces([SIMD2(0, 0), SIMD2(10, 0), SIMD2(10, 20)], 10, 10)
        #expect(result.map(\.points) == [[SIMD2(0, 0), SIMD2(10, 0)], [SIMD2(10, 10), SIMD2(10, 20)]])
    }

    // MARK: - 閉じた輪郭

    private let square: [SIMD2<Float>] = [SIMD2(0, 0), SIMD2(10, 0), SIMD2(10, 10), SIMD2(0, 10)]

    @Test("閉じた輪郭は、最後の点から最初の点へ戻る辺も刻む")
    func aClosedOutlineIncludesTheClosingEdge() throws {
        // 周は 40。長さ 5・間隔 5 なら、10 おきに 4 つの片 (0・10・20・30 から 5)
        let result = try pieces(square, 5, 5, closed: true)
        #expect(
            result.map(\.points) == [
                [SIMD2(0, 0), SIMD2(5, 0)], [SIMD2(10, 0), SIMD2(10, 5)],
                [SIMD2(10, 10), SIMD2(5, 10)], [SIMD2(0, 10), SIMD2(0, 5)],
            ])
        #expect(result.allSatisfy { !$0.isClosed })
    }

    @Test("閉じた輪郭で、最後の破線が始点まで届いて続くなら、最初の破線へ繋いで 1 つの片にする")
    func theLastDashJoinsTheFirstAcrossTheStart() throws {
        // 周 40・長さ 30・間隔 5: 0…30 が破線、30…35 が間隔、35…40 は破線のまま始点へ届く
        let result = try pieces(square, 30, 5, closed: true)
        try #require(result.count == 1)
        #expect(
            result[0].points == [SIMD2(0, 5), SIMD2(0, 0), SIMD2(10, 0), SIMD2(10, 10), SIMD2(0, 10)])
    }

    @Test("繋いだ片の中では、始点は折れ目として残り、曲線の刻みの印も続く")
    func theJoinedPieceKeepsTheStartAsAVertex() throws {
        let result = try pieces(square, 30, 5, steps: [true, false, false, false], closed: true)
        try #require(result.count == 1)
        #expect(result[0].curveSteps == [false, true, false, false, false])
    }

    @Test("閉じた輪郭で、破線が一周を途切れずに覆うなら、閉じた 1 つの片になる")
    func aDashLongerThanThePerimeterIsOneClosedPiece() throws {
        let result = try pieces(square, 100, 5, closed: true)
        try #require(result.count == 1)
        #expect(result[0].isClosed)
        #expect(result[0].points == square)
    }

    @Test("最後が間隔で終わる輪郭は、最初の破線を繋がず、片は割れたまま")
    func aDashEndingExactlyAtTheStartIsNotJoined() throws {
        // 周 40・長さ 10・間隔 10: 30…40 は間隔で、20…30 の破線が最後
        let result = try pieces(square, 10, 10, closed: true)
        try #require(result.count == 2)
        #expect(result[0].points == [SIMD2(0, 0), SIMD2(10, 0)])
    }

    @Test("閉じた輪郭を、破線がちょうど周の長さで覆うなら、閉じた片にする")
    func aDashExactlyAsLongAsThePerimeterIsClosed() throws {
        let result = try pieces(square, 40, 5, closed: true)
        try #require(result.count == 1)
        #expect(result[0].isClosed)
    }

    @Test("閉じた輪郭の点線 (長さ 0) は、周に沿って間隔ごとに点が並ぶ")
    func aClosedOutlineMakesDots() throws {
        let result = try pieces(square, 0, 10, closed: true)
        #expect(
            result.map(\.points) == [
                [SIMD2(0, 0), SIMD2(0, 0)], [SIMD2(10, 0), SIMD2(10, 0)],
                [SIMD2(10, 10), SIMD2(10, 10)], [SIMD2(0, 10), SIMD2(0, 10)],
            ])
    }

    @Test("閉じた輪郭を刻む数の上限は、戻る辺も含めた周の長さで数える")
    func theClosingEdgeCountsTowardTheLimit() {
        let limit = Float(Canvas.maxDashPieces)
        let dash = StrokeDash(length: 1, gap: 1)
        // 開いた線としては上限内 (長さ limit * 2) でも、閉じて戻る辺を足すと越える
        let line: [SIMD2<Float>] = [SIMD2(0, 0), SIMD2(limit * 2, 0)]
        #expect(Canvas.dashPieces(of: line, isClosed: false, by: dash) != .tooMany)
        #expect(Canvas.dashPieces(of: line, isClosed: true, by: dash) == .tooMany)
    }

    @Test("数でない座標・無限の長さ・点が 2 つに満たない線は、刻めないと返す")
    func unsplittableInputsAreReported() {
        let dash = StrokeDash(length: 4, gap: 4)
        #expect(Canvas.dashPieces(of: [SIMD2(0, 0)], by: dash) == .unsplittable)
        #expect(Canvas.dashPieces(of: [SIMD2(0, 0), SIMD2(.nan, 1)], by: dash) == .unsplittable)
        #expect(Canvas.dashPieces(of: [SIMD2(0, 0), SIMD2(.infinity, 1)], by: dash) == .unsplittable)
        // 有限の座標でも、辺の長さが溢れる
        #expect(
            Canvas.dashPieces(of: [SIMD2(-3e38, 0), SIMD2(3e38, 0)], by: dash) == .unsplittable)
    }

    @Test("刻む数が上限を越える線は、刻まずに越えたと返す。上限ちょうどは刻む")
    func theLimitIsAnEdge() {
        let dash = StrokeDash(length: 1, gap: 1)
        let limit = Float(Canvas.maxDashPieces)
        // 周期 2 で、片の数の見積もり (長さ / 周期) が上限ちょうどの線と、1 周期だけ長い線
        #expect(Canvas.dashPieces(of: [SIMD2(0, 0), SIMD2(limit * 2, 0)], by: dash) != .tooMany)
        #expect(
            Canvas.dashPieces(of: [SIMD2(0, 0), SIMD2((limit + 1) * 2, 0)], by: dash) == .tooMany)
    }

    @Test("座標に比べて周期が極端に小さくても、止まらずに返す")
    func aTinyPeriodDoesNotLoopForever() {
        // 1e6 に 1e-3 を足しても進まない。見積もりが先に断る
        let result = Canvas.dashPieces(
            of: [SIMD2(0, 0), SIMD2(1e6, 0)], by: StrokeDash(length: 1e-3, gap: 1e-3))
        #expect(result == .tooMany)
    }

    // MARK: - 数え始める所 (#3314)

    /// 角丸の矩形の破線は、上辺の左の弧の終わり `(x + r, y)` から右へ数える。**実線の周の点の並び
    /// (右上の弧の始まりから) は動かさない。** 半径が辺の半分ちょうど (長方形の短い辺・円) でも同じ。
    @Test(
        "角丸の矩形の破線は、(x + r, y) から右へ数え始める。点の並びは動かさない",
        arguments: [
            (150, 80, 20), (150, 80, 40), (80, 80, 40), (60, 100, 30), (150, 80, 1),
        ] as [(Float, Float, Float)])
    func aRoundedRectDashStartsAtTheEndOfTheTopLeftArc(_ w: Float, _ h: Float, _ r: Float) throws {
        let origin = SIMD2<Float>(20, 20)
        let outline = Canvas.roundedRectOutline(width: w, height: h, radius: r, segments: 48)
            .moved(by: origin)
        #expect(outline.points[0] == origin + SIMD2(w - r, 0), "実線の周は右上の弧の始まりのまま")
        guard case .pieces(let pieces) = Canvas.dashPieces(of: outline, by: StrokeDash(length: 10, gap: 10))
        else {
            Issue.record("刻めなかった")
            return
        }
        // 最後の破線が始点まで届くと、最初の破線へ繋いだ 1 つの片が末尾に回る。始点を通る片を探し、
        // **始点から片の終わりまでが破線 1 つぶん (10)** であることで「ここから数え始めた」を見る
        // (始点がたまたま破線の途中の頂点でも、残りは 10 に満たない)
        let start = origin + SIMD2(r, 0)
        let piece = try #require(pieces.first { $0.points.contains(start) }, "始点を通る片が無い")
        let rest = Array(piece.points[try #require(piece.points.firstIndex(of: start))...])
        let length = zip(rest, rest.dropFirst()).reduce(Float(0)) { $0 + simd_length($1.1 - $1.0) }
        #expect(abs(length - 10) < 1e-3, "破線が (x + r, y) から始まっていない: 始点から \(length)")
        // 最初の破線は上辺を右へ進む (時計回り)
        #expect(rest[1].x > start.x)
    }
}


@Suite(
    "線の破線 (画素)",
    .enabled(
        if: RenderDevice.isAvailable,
        "この世代のコマンド構造に対応した GPU が無い実行環境ではスキップする")
)
struct StrokeDashTests {
    private let black = LinearRGBA.linear(red: 0, green: 0, blue: 0)
    private let white = LinearRGBA.linear(red: 1, green: 1, blue: 1)

    /// 線の経路。**距離関数の経路と三角形の経路の両方で、同じ約束が成り立つ** (#2835 の完了条件 3)。
    enum Route: String, CaseIterable, CustomTestStringConvertible {
        case distanceField = "距離関数"
        case triangles = "三角形"
        var testDescription: String { rawValue }
    }

    private func makeCanvas(width: Int = 128, height: Int = 100) throws -> Canvas {
        try CanvasFixture.make(gpu: RenderDevice(), width: width, height: height)
    }

    /// 黒地へ白い線を引く。**三角形の経路は、断片 (`shader()`) を付けて距離関数から外す。**
    private func picture(
        _ route: Route, width: Int = 128, height: Int = 100, _ body: (Canvas) -> Void
    ) throws -> (image: DisplayImage, canvas: Canvas) {
        let canvas = try makeCanvas(width: width, height: height)
        let plain = try canvas.makeShader("float4 paint(Fragment in, Values values) { return in.color; }")
        try canvas.draw {
            canvas.background(black)
            canvas.stroke(white)
            canvas.noFill()
            if route == .triangles { canvas.shader(plain) }
            body(canvas)
        }
        return (try canvas.target.encodeForDisplay(), canvas)
    }

    /// (x, y) のまわり 3x3 画素で、いちばん濃い赤の成分。
    ///
    /// **距離関数の経路と三角形の経路は、同じ線を半画素ずらして出す** (既存の振る舞いで、どちらの
    /// 経路でも絵として正しい)。1 画素を指して比べると経路ごとに違う値が要るので、まわりを見て
    /// 「塗られている / 下地のまま」だけを問う。調べる位置は、破線の端から 2 画素以上離す。
    private func ink(_ image: DisplayImage, _ x: Int, _ y: Int) -> UInt8 {
        var darkest: UInt8 = 0
        for dy in -1...1 {
            for dx in -1...1 { darkest = max(darkest, image[x + dx, y + dy].red) }
        }
        return darkest
    }

    private func expectInk(
        _ image: DisplayImage, _ x: Int, _ y: Int, _ note: Comment? = nil,
        sourceLocation: SourceLocation = #_sourceLocation
    ) {
        #expect(ink(image, x, y) > 0xa0, note, sourceLocation: sourceLocation)
    }

    private func expectBare(
        _ image: DisplayImage, _ x: Int, _ y: Int, _ note: Comment? = nil,
        sourceLocation: SourceLocation = #_sourceLocation
    ) {
        #expect(ink(image, x, y) == 0, note, sourceLocation: sourceLocation)
    }

    // MARK: - 完了条件 1・3

    /// 完了条件 1。**変更前は `strokeDash` が無くコンパイルできない。** 破線を無視して実線で引くと、
    /// x = 15 が塗られて赤になる。
    @Test("長さ 10・間隔 10 の線で、x = 5 は塗られ、x = 15 は下地のまま", arguments: Route.allCases)
    func gapsStayAsTheBackground(_ route: Route) throws {
        let (image, _) = try picture(route) { canvas in
            canvas.strokeWeight(2)
            canvas.strokeDash(10, 10)
            canvas.line(0, 50, 100, 50)
        }
        expectInk(image, 5, 50, "破線の中が塗られていない")
        expectBare(image, 15, 50, "間隔が塗られている (破線が効いていない)")
        expectInk(image, 25, 50, "2 つ目の破線が塗られていない")
        expectBare(image, 35, 50)
        expectInk(image, 85, 50, "最後の破線 (x = 80…90) が塗られていない")
        expectBare(image, 95, 50, "最後の間隔が塗られている")
        expectBare(image, 105, 50, "線の端の先が塗られている")
    }

    @Test("端の形を切る形にすると、破線は与えた長さで切れ、間隔はその分だけ空く", arguments: Route.allCases)
    func squareCapsCutAtTheGivenLength(_ route: Route) throws {
        let (image, _) = try picture(route) { canvas in
            canvas.strokeWeight(2)
            canvas.strokeCap(.square)
            canvas.strokeDash(10, 10)
            canvas.line(0, 50, 100, 50)
        }
        for (x, painted) in [(3, true), (8, true), (12, false), (17, false), (22, true), (28, true), (32, false)] {
            if painted { expectInk(image, x, 50, "x = \(x)") } else { expectBare(image, x, 50, "x = \(x)") }
        }
    }

    @Test("丸い端は、長さの両側へ太さの半分ずつはみ出す", arguments: Route.allCases)
    func roundCapsStickOutByHalfTheWeight(_ route: Route) throws {
        let (image, _) = try picture(route) { canvas in
            canvas.strokeWeight(6)
            canvas.strokeCap(.round)
            canvas.strokeDash(10, 20)
            canvas.line(10, 50, 100, 50)
        }
        // 破線は x = 10…20 と 40…50。丸い端は 3 画素はみ出すので、23 まで・37 からが塗られる
        expectInk(image, 21, 50, "端の丸みが出ていない")
        expectBare(image, 27, 50)
        expectBare(image, 33, 50)
        expectInk(image, 39, 50, "2 つ目の破線の手前の丸みが出ていない")
    }

    // MARK: - 完了条件 2

    @Test("実線へ戻した後の線は、破線を指定する前と同じ画素になる", arguments: Route.allCases)
    func noStrokeDashRestoresTheSolidPicture(_ route: Route) throws {
        let (solid, _) = try picture(route) { canvas in
            canvas.strokeWeight(2)
            canvas.line(0, 50, 100, 50)
        }
        let (restored, _) = try picture(route) { canvas in
            canvas.strokeWeight(2)
            canvas.strokeDash(10, 10)
            canvas.noStrokeDash()
            canvas.line(0, 50, 100, 50)
        }
        #expect(restored == solid)
    }

    @Test("間隔 0 の破線は途切れず、実線と同じ画素になる", arguments: Route.allCases)
    func aDashWithoutAGapIsSolid(_ route: Route) throws {
        let (solid, _) = try picture(route) { canvas in
            canvas.strokeWeight(2)
            canvas.line(0, 50, 100, 50)
        }
        let (gapless, canvas) = try picture(route) { canvas in
            canvas.strokeWeight(2)
            canvas.strokeDash(10, 0)
            canvas.line(0, 50, 100, 50)
        }
        #expect(gapless == solid)
        #expect(!canvas.warnings.hasWarned(.badStrokeDash), "間隔 0 は正しい指定で、名乗らない")
    }

    @Test("積んだスタイルを降ろすと、破線の指定も戻る", arguments: Route.allCases)
    func pushAndPopRestoreTheDash(_ route: Route) throws {
        let (image, canvas) = try picture(route) { canvas in
            canvas.strokeWeight(2)
            canvas.strokeDash(10, 10)
            canvas.pushStyle()
            canvas.noStrokeDash()
            canvas.line(0, 20, 100, 20)  // 積んだ間は実線
            canvas.popStyle()
            canvas.line(0, 50, 100, 50)  // 降ろすと破線に戻る
            canvas.pushStyle()
            canvas.strokeDash(4, 4)
            canvas.popStyle()
            canvas.line(0, 80, 100, 80)  // 内側で替えた破線は外へ漏れない
        }
        expectInk(image, 15, 20, "積んだ間の実線が破線になっている")
        expectBare(image, 15, 50, "降ろした後に破線が戻っていない")
        expectBare(image, 15, 80)
        expectInk(image, 25, 80, "降ろした後の破線が、内側で替えた長さ 4 のままになっている")
        #expect(canvas.style.strokeDash == StrokeDash(length: 10, gap: 10))
    }

    // MARK: - 折れ線 (開いた輪郭)

    @Test("破線は折れ目をまたいで続く", arguments: Route.allCases)
    func theDashContinuesAroundACorner(_ route: Route) throws {
        // 長さ 30・間隔 20。(10, 10) から x = 35 まで 25 進んで曲がり、下へ 50 進む。
        // 最初の破線は 5 だけ曲がった先へ続き、間隔の後の次の破線は y = 35 から
        let (image, _) = try picture(route) { canvas in
            canvas.strokeWeight(2)
            canvas.strokeCap(.square)
            canvas.strokeDash(30, 20)
            canvas.beginShape()
            canvas.vertex(10, 10)
            canvas.vertex(35, 10)
            canvas.vertex(35, 60)
            canvas.endShape()
        }
        expectInk(image, 20, 10, "最初の辺の破線")
        expectInk(image, 35, 13, "曲がった先へ続く破線")
        expectBare(image, 35, 25, "間隔")
        expectInk(image, 35, 45, "次の破線")
    }

    @Test("破線が折れ目をまたぐとき、角は同じ折れ線を実線で引いたときと同じ形で繋がる", arguments: Route.allCases)
    func aCornerInsideADashJoinsAsInASolidLine(_ route: Route) throws {
        func corner(dashed: Bool, join: StrokeJoin) throws -> DisplayImage {
            try picture(route) { canvas in
                canvas.strokeWeight(8)
                canvas.strokeCap(.square)
                canvas.strokeJoin(join)
                if dashed { canvas.strokeDash(60, 40) }
                canvas.beginShape()
                canvas.vertex(10, 20)
                canvas.vertex(50, 20)
                canvas.vertex(50, 80)
                canvas.endShape()
            }.image
        }
        // 長さ 60 の破線は、角 (50, 20) を含む 40 + 20 の所まで続く。角のまわり 16 画素四方は同じ
        for join in [StrokeJoin.miter, .bevel, .round] {
            let solid = try corner(dashed: false, join: join)
            let dashed = try corner(dashed: true, join: join)
            for y in 8...32 {
                for x in 38...62 {
                    #expect(dashed[x, y] == solid[x, y], "(\(x), \(y)) \(join)")
                }
            }
        }
    }

    @Test("beginShape(.lines) の線も、1 本ずつ破線になる", arguments: Route.allCases)
    func separateLinesAreEachDashed(_ route: Route) throws {
        let (image, _) = try picture(route) { canvas in
            canvas.strokeWeight(2)
            canvas.strokeCap(.square)
            canvas.strokeDash(10, 10)
            canvas.beginShape(.lines)
            canvas.vertex(0, 20)
            canvas.vertex(100, 20)
            canvas.vertex(5, 60)
            canvas.vertex(105, 60)
            canvas.endShape()
        }
        expectInk(image, 5, 20)
        expectBare(image, 14, 20)
        expectBare(image, 22, 60, "2 本目の模様は、2 本目の始点から数え直す")
        expectInk(image, 10, 60)
        expectInk(image, 30, 60)
    }

    @Test("曲線の開いた線も、弧の長さに沿って破線になる", arguments: Route.allCases)
    func anOpenCurveIsDashedAlongItsLength(_ route: Route) throws {
        func inked(dashed: Bool) throws -> Int {
            let (image, _) = try picture(route) { canvas in
                canvas.strokeWeight(2)
                canvas.strokeCap(.square)
                if dashed { canvas.strokeDash(10, 10) }
                canvas.beginShape()
                canvas.vertex(10, 80)
                canvas.bezierVertex(30, 0, 90, 0, 110, 80)
                canvas.endShape()
            }
            var count = 0
            for index in stride(from: 0, to: image.bytes.count, by: 4) where image.bytes[index] > 0x80 {
                count += 1
            }
            return count
        }
        let solid = try inked(dashed: false)
        let dashed = try inked(dashed: true)
        // 長さ 10・間隔 10 なので、塗られる画素は実線のおよそ半分
        #expect(dashed > solid * 35 / 100, "破線が出ていない (\(dashed) / \(solid))")
        #expect(dashed < solid * 65 / 100, "破線が刻まれていない (\(dashed) / \(solid))")
    }

    // MARK: - 長さ 0・点線

    @Test("長さ 0 の破線は、丸い端なら点線になる", arguments: Route.allCases)
    func zeroLengthDashesMakeDots(_ route: Route) throws {
        let (image, _) = try picture(route) { canvas in
            canvas.strokeWeight(4)
            canvas.strokeCap(.round)
            canvas.strokeDash(0, 10)
            canvas.line(10, 50, 100, 50)
        }
        expectInk(image, 10, 50, "点の中心")
        expectInk(image, 20, 50)
        expectBare(image, 15, 50, "点の間")
    }

    @Test("長さ 0 の破線は、端を切る形では何も出ない", arguments: Route.allCases)
    func zeroLengthDashesVanishWithSquareCaps(_ route: Route) throws {
        let (image, _) = try picture(route) { canvas in
            canvas.strokeWeight(4)
            canvas.strokeCap(.square)
            canvas.strokeDash(0, 10)
            canvas.line(10, 50, 100, 50)
        }
        // 4 バイトずつ (赤・緑・青・不透明度) のうち、色の成分がどれも 0 のまま
        let painted = image.bytes.enumerated().contains { $0.offset % 4 != 3 && $0.element != 0 }
        #expect(!painted, "何か塗られている")
    }

    // MARK: - 完了条件 5

    @Test(
        "負・数でない値・無限・両方 0 の指定は、実線で引いて 1 度名乗る",
        arguments: [
            (Float.nan, Float(4)), (Float(4), Float.nan), (Float(-1), Float(4)), (Float(4), Float(-1)),
            (Float.infinity, Float(4)), (Float(4), Float.infinity), (Float(0), Float(0)),
            (Float.greatestFiniteMagnitude, Float.greatestFiniteMagnitude),
        ], Route.allCases)
    func unusableValuesDrawSolid(_ values: (Float, Float), _ route: Route) throws {
        let (solid, _) = try picture(route) { canvas in
            canvas.strokeWeight(2)
            canvas.line(0, 50, 100, 50)
        }
        let (image, canvas) = try picture(route) { canvas in
            canvas.strokeWeight(2)
            canvas.strokeDash(10, 10)  // 直前の破線も、無効な指定で実線へ戻る
            canvas.strokeDash(values.0, values.1)
            canvas.line(0, 50, 100, 50)
        }
        #expect(image == solid)
        #expect(canvas.style.strokeDash == nil)
        let message = try #require(canvas.warnings.message(for: .badStrokeDash))
        #expect(message.hasPrefix("strokeDash():"))
    }

    @Test("無効な指定は 1 度しか名乗らない")
    func anUnusableValueIsSaidOnce() throws {
        let canvas = try makeCanvas()
        try canvas.draw {
            canvas.strokeDash(-1, 4)
            let first = canvas.warnings.message(for: .badStrokeDash)
            canvas.strokeDash(4, Float.nan)
            #expect(canvas.warnings.message(for: .badStrokeDash) == first, "2 度目の指定が文面を書き換えた")
        }
    }

    @Test("上限を越えて細かい破線は、その線を実線で引いて 1 度名乗る", arguments: Route.allCases)
    func tooFineADashDrawsSolid(_ route: Route) throws {
        let (image, canvas) = try picture(route) { canvas in
            canvas.strokeWeight(2)
            canvas.strokeDash(1, 1)
            canvas.line(0, 50, 100_000, 50)  // 刻めば 50000 片
        }
        expectInk(image, 15, 50, "実線で引いていない")
        #expect(canvas.warnings.hasWarned(.strokeDashTooFine))
        // 刻める長さの線は、そのまま破線
        let (short, shortCanvas) = try picture(route) { canvas in
            canvas.strokeWeight(2)
            canvas.strokeCap(.square)
            canvas.strokeDash(10, 10)
            canvas.line(0, 50, 100, 50)
        }
        expectBare(short, 15, 50)
        #expect(!shortCanvas.warnings.hasWarned(.strokeDashTooFine))
    }

    // MARK: - 完了条件 4

    @Test("保持した形には、組み立ての間の破線が焼き付き、外の設定は変わらない", arguments: Route.allCases)
    func retainedShapesBakeTheDash(_ route: Route) throws {
        let (image, canvas) = try picture(route) { canvas in
            canvas.strokeWeight(2)
            canvas.strokeCap(.square)
            let held = canvas.createShape {
                canvas.strokeDash(10, 10)
                canvas.beginShape()
                canvas.vertex(0, 50)
                canvas.vertex(100, 50)
                canvas.endShape()
            }
            #expect(canvas.style.strokeDash == nil, "組み立ての中の破線が外へ漏れた")
            // 置いた後に外で破線を替えても、形の線は焼き付いたまま
            canvas.strokeDash(4, 4)
            canvas.shape(held)
            canvas.noStrokeDash()
            canvas.shape(held, 0, 20)
        }
        expectInk(image, 5, 50)
        expectBare(image, 15, 50, "形に破線が焼き付いていない")
        expectInk(image, 25, 50)
        expectBare(image, 15, 70, "外の設定の替えが、焼き付いた線を変えた")
        expectInk(image, 25, 70)
        #expect(canvas.style.strokeDash == nil)
    }

    // MARK: - 描き方の独立

    @Test("破線は、太さ・端と同じく、変換の前の単位で測る", arguments: Route.allCases)
    func theDashScalesWithTheTransform(_ route: Route) throws {
        let (image, _) = try picture(route) { canvas in
            canvas.strokeWeight(1)
            canvas.strokeCap(.square)
            canvas.strokeDash(5, 5)
            canvas.scale(2, 2)
            canvas.line(0, 25, 50, 25)  // 画面では長さ 10・間隔 10 になる
        }
        expectInk(image, 5, 50)
        expectBare(image, 15, 50)
        expectInk(image, 25, 50)
    }

    // MARK: - 閉じた輪郭 (#2835 の PR2)

    /// 輪郭の図形。**距離関数の経路 (矩形・楕円・扇形) と、三角形の経路 (三角形・四角形・頂点列) の
    /// 両方を並べる。** 塗りは置かず、輪郭だけを破線で引く。
    enum Figure: String, CaseIterable, CustomTestStringConvertible {
        case rect, roundedRect, circle, ellipse, arc, triangle, quad, shape, shapeWithHole
        var testDescription: String { rawValue }

        func draw(_ canvas: Canvas) {
            switch self {
            case .rect: canvas.rect(20, 20, 60, 40)
            case .roundedRect: canvas.rect(20, 20, 60, 40, 12)
            case .circle: canvas.circle(50, 40, 60)
            case .ellipse: canvas.ellipse(50, 40, 80, 50)
            case .arc: canvas.arc(50, 50, 70, 70, 0.3, 4.4)
            case .triangle: canvas.triangle(20, 20, 80, 30, 40, 70)
            case .quad: canvas.quad(20, 20, 80, 25, 70, 70, 25, 60)
            case .shape:
                canvas.beginShape()
                canvas.vertex(20, 20)
                canvas.vertex(80, 20)
                canvas.vertex(80, 60)
                canvas.vertex(50, 75)
                canvas.vertex(20, 60)
                canvas.endShape(.close)
            case .shapeWithHole:
                canvas.beginShape()
                canvas.vertex(10, 10)
                canvas.vertex(90, 10)
                canvas.vertex(90, 70)
                canvas.vertex(10, 70)
                canvas.beginContour()
                canvas.vertex(30, 30)
                canvas.vertex(30, 50)
                canvas.vertex(70, 50)
                canvas.vertex(70, 30)
                canvas.endContour()
                canvas.endShape(.close)
            }
        }
    }

    /// 塗られた画素 (赤が半分を越える) の数。
    private func inkedCount(_ image: DisplayImage) -> Int {
        var count = 0
        for index in stride(from: 0, to: image.bytes.count, by: 4) where image.bytes[index] > 0x80 {
            count += 1
        }
        return count
    }

    @Test("どの図形の輪郭も、長さ 10・間隔 10 の破線なら、塗られる画素は実線のおよそ半分", arguments: Figure.allCases, Route.allCases)
    func everyOutlineIsDashed(_ figure: Figure, _ route: Route) throws {
        func inked(dashed: Bool) throws -> Int {
            let (image, canvas) = try picture(route) { canvas in
                canvas.strokeWeight(2)
                canvas.strokeCap(.square)
                if dashed { canvas.strokeDash(10, 10) }
                figure.draw(canvas)
            }
            #expect(!canvas.warnings.hasWarned(.strokeDashTooFine))
            return inkedCount(image)
        }
        let solid = try inked(dashed: false)
        let dashed = try inked(dashed: true)
        // 距離関数の線は縁がぼけるぶん、実線の塗られる画素が多く数えられる。下限は余裕を持たせる
        #expect(dashed > solid * 25 / 100, "破線が出ていない (\(dashed) / \(solid))")
        #expect(dashed < solid * 65 / 100, "破線が刻まれていない (\(dashed) / \(solid))")
    }

    @Test("矩形の辺は、周に沿って模様が続き、角をまたぐ破線は角の形で繋がる", arguments: Route.allCases)
    func aRectOutlineFollowsThePerimeter(_ route: Route) throws {
        // rect(20, 20, 60, 40): 周 200。長さ 10・間隔 10 なら、上の辺は d = 0…10・20…30…、右の辺は
        // d = 60 から (60…70 が破線)、下の辺は右から左へ d = 100 から、左の辺は下から上へ d = 160 から
        let (image, _) = try picture(route) { canvas in
            canvas.strokeWeight(2)
            canvas.strokeCap(.square)
            canvas.strokeDash(10, 10)
            canvas.rect(20, 20, 60, 40)
        }
        expectInk(image, 25, 20, "上の辺 d = 5")
        expectBare(image, 35, 20, "上の辺 d = 15")
        expectInk(image, 80, 25, "右の辺 d = 65")
        expectBare(image, 80, 35, "右の辺 d = 75")
        expectInk(image, 75, 60, "下の辺 d = 105")
        expectBare(image, 65, 60, "下の辺 d = 115")
        expectInk(image, 20, 55, "左の辺 d = 165")
        expectBare(image, 20, 45, "左の辺 d = 175")
    }

    @Test("始点をまたぐ破線は、角で割れずに実線のときと同じ形で繋がる", arguments: [StrokeJoin.miter, .bevel, .round], Route.allCases)
    func aDashCrossingTheStartJoinsAtTheCorner(_ join: StrokeJoin, _ route: Route) throws {
        func corner(_ length: Float) throws -> DisplayImage {
            try picture(route) { canvas in
                canvas.strokeWeight(8)
                canvas.strokeCap(.square)
                canvas.strokeJoin(join)
                canvas.strokeDash(length, 10)
                canvas.rect(20, 20, 60, 40)
            }.image
        }
        // 周 200・長さ 110・間隔 10: 120…200 の破線が、始点を越えて 0…110 へ続く。比べる相手は、
        // 周を途切れず覆う破線 (閉じた 1 つの片)。どちらも破線の片として同じ経路で引くので、
        // 角のまわりが同じ画素になれば、始点で割れずに繋がっている
        let solid = try corner(1000)
        let dashed = try corner(110)
        for y in 8...32 {
            for x in 8...32 {
                #expect(dashed[x, y] == solid[x, y], "(\(x), \(y)) \(join)")
            }
        }
    }

    @Test("破線の輪郭の内側の塗りは、輪郭を引かない図形と同じに残る", arguments: Route.allCases)
    func theFillStaysUnderADashedOutline(_ route: Route) throws {
        func filled(_ body: (Canvas) -> Void) throws -> DisplayImage {
            try picture(route) { canvas in
                canvas.fill(.linear(red: 0, green: 0, blue: 1))
                body(canvas)
            }.image
        }
        let noStroke = try filled { canvas in
            canvas.noStroke()
            canvas.rect(20, 20, 60, 40)
        }
        let dashed = try filled { canvas in
            canvas.strokeWeight(2)
            canvas.strokeCap(.square)
            canvas.strokeDash(10, 10)
            canvas.stroke(.linear(red: 1, green: 0, blue: 0))
            canvas.rect(20, 20, 60, 40)
        }
        // 中ほどは塗りのまま。輪郭の間隔 (上の辺 d = 15) のすぐ内側も塗りで、線の赤は出ない
        #expect(dashed[50, 40] == noStroke[50, 40])
        #expect(dashed[35, 24].blue > 200, "間隔の内側の塗りが欠けている")
        #expect(dashed[35, 24].red < 60)
    }

    @Test("破線の輪郭を畳まない: 破線の矩形を重ねた後、実線へ戻した同じ矩形は実線で出る", arguments: Route.allCases)
    func aDashedOutlineIsNotFoldedIntoASolidOne(_ route: Route) throws {
        let (image, _) = try picture(route) { canvas in
            canvas.strokeWeight(2)
            canvas.strokeCap(.square)
            canvas.strokeDash(10, 10)
            canvas.rect(10, 10, 30, 20)
            canvas.rect(10, 40, 30, 20)
            canvas.noStrokeDash()
            canvas.rect(10, 70, 30, 20)
            canvas.rect(60, 70, 30, 20)
        }
        expectBare(image, 25, 10, "破線の上の辺の間隔 (d = 15)")
        expectBare(image, 25, 40)
        expectInk(image, 25, 70, "実線へ戻した矩形の上の辺")
        expectInk(image, 75, 70)
    }

    // MARK: - 数え始める所 (#3314)

    /// 角丸の矩形の破線は、上辺の左の弧の終わり `(40, 20)` から右へ 15 (40…55 が塗られ、55…70 が空く)。
    /// **変更前は右上の弧の始まりから数えていて、この位置の塗り・空きが入れ替わっていた** (周 425.7・
    /// 起点から (40, 20) まで 315.7 で、30 の周期の 15.7 の位相)。
    @Test("角丸の矩形の破線は、上辺の左の弧の終わり (x + r, y) から数え始める", arguments: Route.allCases)
    func aRoundedRectDashStartsAtTheTopLeftArcEnd(_ route: Route) throws {
        let (image, _) = try picture(route, width: 200, height: 120) { canvas in
            canvas.strokeWeight(2)
            canvas.strokeCap(.square)
            canvas.strokeDash(15, 15)
            canvas.rect(20, 20, 150, 80, 20)
        }
        expectInk(image, 47, 20, "上辺の最初の破線 (x = 40…55) が塗られていない")
        expectBare(image, 62, 20, "上辺の最初の間隔 (x = 55…70) が塗られている")
        expectInk(image, 77, 20, "上辺の 2 つ目の破線 (x = 70…85)")
    }

    /// 一周の弧は、貼る絵・断片を効かせても効かせなくても、角度 0 (右の端) から時計回りに数える。
    /// 変更前は、距離関数の道は角度 0、断片の道 (三角形) は `start` (ここでは 1) から数えていた。
    @Test("一周の弧の破線は、どちらの道でも角度 0 から数え始める", arguments: Route.allCases)
    func aFullTurnArcDashStartsAtAngleZero(_ route: Route) throws {
        let (image, _) = try picture(route, width: 200, height: 200) { canvas in
            canvas.strokeWeight(2)
            canvas.strokeCap(.square)
            canvas.strokeDash(15, 15)
            canvas.arc(100, 100, 120, 120, 1, 8)
        }
        // 半径 60 の円周を、角度 0 から時計回り (画面の y は下向き) に弧の長さ d だけ進んだ点
        func point(_ length: Float) -> (Int, Int) {
            let angle = length / 60
            return (Int((100 + 60 * cos(angle)).rounded()), Int((100 + 60 * sin(angle)).rounded()))
        }
        let inside = point(7)
        let gap = point(22)
        expectInk(image, inside.0, inside.1, "最初の破線 (d = 0…15) が塗られていない")
        expectBare(image, gap.0, gap.1, "最初の間隔 (d = 15…30) が塗られている")
    }

    @Test("長さ 0 の破線は、閉じた輪郭でも丸い端なら点線になる", arguments: Route.allCases)
    func aClosedOutlineMakesDots(_ route: Route) throws {
        let (image, _) = try picture(route) { canvas in
            canvas.strokeWeight(4)
            canvas.strokeCap(.round)
            canvas.strokeDash(0, 20)
            canvas.rect(20, 20, 60, 40)
        }
        expectInk(image, 20, 20, "始点の点")
        expectInk(image, 40, 20, "d = 20 の点")
        expectBare(image, 30, 20, "点の間")
    }

    @Test("保持した形の閉じた輪郭にも、組み立ての間の破線が焼き付く", arguments: Route.allCases)
    func retainedClosedOutlinesBakeTheDash(_ route: Route) throws {
        let (image, canvas) = try picture(route) { canvas in
            canvas.strokeWeight(2)
            canvas.strokeCap(.square)
            let held = canvas.createShape {
                canvas.strokeDash(10, 10)
                canvas.rect(20, 20, 60, 40)
            }
            canvas.shape(held)
        }
        expectInk(image, 25, 20)
        expectBare(image, 35, 20, "形に破線が焼き付いていない")
        #expect(canvas.style.strokeDash == nil)
    }

    @Test("輪郭を引かない設定では、破線にしても何も変わらず、名乗りもしない", arguments: Route.allCases)
    func noStrokeIgnoresTheDash(_ route: Route) throws {
        let (plain, _) = try picture(route) { canvas in
            canvas.fill(white)
            canvas.noStroke()
            canvas.rect(20, 20, 60, 40)
        }
        let (dashed, canvas) = try picture(route) { canvas in
            canvas.fill(white)
            canvas.strokeDash(10, 10)
            canvas.noStroke()
            canvas.rect(20, 20, 60, 40)
        }
        #expect(dashed == plain)
        #expect(canvas.warnings.message(for: .strokeDashTooFine) == nil)
    }

    @Test("閉じた輪郭の刻みが上限を越えるなら、その図形を実線で引いて 1 度名乗る", arguments: Route.allCases)
    func aTooFineClosedOutlineDrawsSolid(_ route: Route) throws {
        let (image, canvas) = try picture(route) { canvas in
            canvas.strokeWeight(2)
            canvas.strokeDash(1, 1)
            canvas.rect(-10_000, 20, 20_000, 40)  // 周は 6 万。刻めば 3 万片
        }
        expectInk(image, 25, 20, "実線で引いていない")
        #expect(canvas.warnings.hasWarned(.strokeDashTooFine))
    }
}
