// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Testing
import simd

@testable import MokumeCore

/// 画面で重なる点に置く形の決め方 (``Canvas/screenCorner(arms:origins:isEnd:join:cap:)``・#1903 の
/// 決定)。GPU を要さない。絵で確かめる検査は `PolylineJoinTests` の #1889・#1893 の節にある。
@Suite("画面で重なる点に置く形")
struct ScreenCornerTests {
    private func corner(
        _ arms: [SIMD2<Float>], origins: [Int]? = nil, isEnd: Bool = false, join: StrokeJoin = .miter,
        cap: StrokeCap = .round
    ) -> Canvas.ScreenCorner {
        Canvas.screenCorner(
            arms: arms, origins: origins ?? Array(repeating: 0, count: arms.count), isEnd: isEnd,
            join: join, cap: cap)
    }

    private static let diagonal = simd_normalize(SIMD2<Float>(-3, 4))

    @Test("3 本の腕の間に 180° を越える所があれば、その間を挟む 2 本の折れ目になる")
    func threeArmsWithAWideGapMeetAtTheirOuterPair() {
        // 0°・90°・126.87° — 126.87° から 0° へ戻る間が 233.13° ある
        #expect(corner([SIMD2(1, 0), SIMD2(0, 1), Self.diagonal]) == .rim(0, 2))
        // 並び順によらず、同じ 2 本を選ぶ
        #expect(corner([Self.diagonal, SIMD2(1, 0), SIMD2(0, 1)]) == .rim(1, 0))
    }

    @Test("どの間も 180° 以下なら何も置かない。ちょうど 180° の間も置かない")
    func noGapWiderThanAHalfTurnPlacesNothing() {
        // 0°・120°・240°
        let third = SIMD2<Float>(-0.5, 0.8660254)
        #expect(corner([SIMD2(1, 0), third, SIMD2(-0.5, -0.8660254)]) == .nothing)
        // 0°・90°・180° — 180° から 0° へ戻る間がちょうど 180°
        #expect(corner([SIMD2(1, 0), SIMD2(0, 1), SIMD2(-1, 0)]) == .nothing)
    }

    @Test("別の点から出た同じ向きの腕は 1 本と数え、端の形になる", arguments: [StrokeCap.round, .square, .project])
    func equalArmsFromDifferentPointsCountOnce(_ cap: StrokeCap) {
        let expected: Canvas.ScreenCorner =
            switch cap {
            case .round: .disc
            case .square: .nothing
            case .project: .endSquare(0)
            }
        #expect(corner([SIMD2(0, 1), SIMD2(0, 1)], origins: [0, 1], cap: cap) == expected)
    }

    @Test("同じ点が自分の 2 本の腕を同じ向きへ折り返す角は、#1644 のまま 2 本の折れ目になる")
    func aFoldAtOnePointKeepsBothArms() {
        #expect(corner([SIMD2(0, 1), SIMD2(0, 1)], origins: [0, 0]) == .rim(0, 1))
    }

    @Test("正面から見た箱の角は、重なる 4 本の腕を 2 本と数えて #1644 の折れ目になる")
    func aFrontalBoxCornerCountsTwoArms() {
        // 手前の角から右と下、奥の角からも右と下
        let arms = [SIMD2<Float>(1, 0), SIMD2(0, 1), SIMD2(1, 0), SIMD2(0, 1)]
        #expect(corner(arms, origins: [0, 0, 1, 1]) == .rim(0, 1))
    }

    @Test("腕の無い点は向きの無い点になる。線の端を含めば端の形に従う")
    func aPointWithoutArmsHasNoDirection() {
        #expect(corner([]) == .square)
        #expect(corner([], isEnd: true, cap: .square) == .square)
        #expect(corner([], isEnd: true, cap: .round) == .disc)
    }

    @Test("丸い折れ目は円板のまま。線の端だけが端の形に従う")
    func roundJoinsStayDiscs() {
        #expect(corner([SIMD2(1, 0), SIMD2(0, 1), Self.diagonal], join: .round) == .disc)
        #expect(corner([SIMD2(0, 1), SIMD2(0, 1)], origins: [0, 1], join: .round, cap: .square) == .disc)
        #expect(corner([SIMD2(0, 1)], isEnd: true, join: .round, cap: .square) == .nothing)
    }

    @Test("同じ平面に載る 4 点だけが、腕を 1 本と数えうる")
    func onlyCoplanarArmsMayMeetAsOneBand() {
        let (a, b, c) = (SIMD3<Float>(-40, 0, 0), SIMD3<Float>(0, 0, 0), SIMD3<Float>(0, 0, -60))
        #expect(Canvas.mayMeetAsOneBand(a, b, c, SIMD3(-40, 0, -60)))
        // 同じ平面でも、腕が逆の側へ向かえば 1 本にならない
        #expect(!Canvas.mayMeetAsOneBand(a, b, c, SIMD3(40, 0, -60)))
        #expect(!Canvas.mayMeetAsOneBand(a, b, c, SIMD3(-40, 5, -60)))
    }
}
