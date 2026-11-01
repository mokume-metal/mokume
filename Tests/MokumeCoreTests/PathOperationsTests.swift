// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import CoreGraphics
import Foundation
import simd
import Testing

@testable import MokumeCore

/// 道の和・差・交わり (#3647)。値の問いは GPU が要らない。
@Suite("道の演算 (値)")
nonisolated struct PathOperationsValueTests {
    private func disc(_ x: Float, _ y: Float, _ radius: Float) -> Path {
        Path(Circle(center: [x, y], radius: radius))
    }

    private var a: Path { disc(100, 100, 50) }
    private var b: Path { disc(160, 100, 50) }

    /// 円を逆回りにした道。
    private func reversed(_ path: Path) -> Path {
        Path(
            subpaths: path.subpaths.map {
                Path.Subpath(points: $0.points.reversed(), isClosed: $0.isClosed, isCurveStep: $0.isCurveStep.reversed())
            })
    }

    private func box(_ x0: Float, _ y0: Float, _ x1: Float, _ y1: Float) -> Path {
        Path(subpaths: [
            Path.Subpath(
                points: [[x0, y0], [x1, y0], [x1, y1], [x0, y1]], isClosed: true,
                isCurveStep: [false, false, false, false])
        ])
    }

    /// 点から輪郭 (全部の辺) までの最短の距離。
    private func outlineDistance(_ point: Vector2, _ path: Path) -> Float {
        var best = Float.infinity
        let p = SIMD2<Double>(Double(point.x), Double(point.y))
        for subpath in path.subpaths {
            for (from, to) in subpath.edges() {
                let f = SIMD2<Double>(Double(from.x), Double(from.y))
                let t = SIMD2<Double>(Double(to.x), Double(to.y))
                let edge = t - f
                let length2 = edge.x * edge.x + edge.y * edge.y
                let along = length2 > 0 ? max(0, min(1, ((p - f) * edge).sum() / length2)) : 0
                let gap = p - (f + edge * along)
                best = min(best, Float((gap.x * gap.x + gap.y * gap.y).squareRoot()))
            }
        }
        return best
    }

    /// 道の外接の四角を少し広げた範囲を `count` × `count` に割った格子の点のうち、どの輪郭からも十分離れたもの。
    /// 離れ方は形の大きさと座標の大きさに比例させる (Float の丸めで内外が揺れる所を避ける)。
    private func lattice(of paths: [Path], count: Int = 41) -> [Vector2] {
        var low = SIMD2<Float>(repeating: .infinity)
        var high = SIMD2<Float>(repeating: -.infinity)
        for path in paths {
            for subpath in path.subpaths {
                for point in subpath.points {
                    low = pointwiseMin(low, point)
                    high = pointwiseMax(high, point)
                }
            }
        }
        let size = max(high.x - low.x, high.y - low.y)
        let magnitude = max(abs(low.x), abs(low.y), abs(high.x), abs(high.y))
        let clearance = size * 1e-3 + magnitude * 1e-5
        let margin = size * 0.1
        var points: [Vector2] = []
        for ix in 0..<count {
            for iy in 0..<count {
                let x = low.x - margin + (size + 2 * margin) * (Float(ix) + 0.37) / Float(count)
                let y = low.y - margin + (size + 2 * margin) * (Float(iy) + 0.61) / Float(count)
                let point = Vector2(x, y)
                if paths.allSatisfy({ outlineDistance(point, $0) > clearance }) { points.append(point) }
            }
        }
        return points
    }

    /// 和・差・交わりの内外が、入力の内外の論理演算と、格子の点で一致する。調べた内側の点の数を返す。
    @discardableResult
    private func expectSetAlgebra(_ p: Path, _ q: Path, _ label: String, count: Int = 41) -> Int {
        let union = Path.union([p, q])
        let difference = p.subtracting(q)
        let overlap = p.intersection(q)
        var inside = 0
        for point in lattice(of: [p, q], count: count) {
            let inP = p.contains(point)
            let inQ = q.contains(point)
            if inP || inQ { inside += 1 }
            #expect(union.contains(point) == (inP || inQ), "\(label) 和 \(point)")
            #expect(difference.contains(point) == (inP && !inQ), "\(label) 差 \(point)")
            #expect(overlap.contains(point) == (inP && inQ), "\(label) 交わり \(point)")
        }
        return inside
    }

    // MARK: - 完了条件 1〜3

    @Test("和: 輪郭が 1 本になり、重なりの内側の弧が残らない")
    func unionHasASingleOutline() {
        let union = Path.union([a, b])
        // 外周の弧 2 本ぶん。内側の弧が残ると 600 前後になる
        #expect(abs(union.length - 442.9) < 0.5, "長さ \(union.length)")
        #expect(union.contains([150, 100]), "重なりの内側 (元の円の輪郭が通っていた所)")
        #expect(union.contains([100, 100]) && union.contains([160, 100]))
        #expect(!union.contains([215, 100]) && !union.contains([40, 100]))
        #expect(union.subpaths.count == 1)
    }

    @Test("差: 引く円の内側は抜け、残りは内側のまま")
    func subtractingRemovesTheOtherInside() {
        let difference = a.subtracting(b)
        #expect(!difference.contains([130, 100]))
        #expect(difference.contains([70, 100]))
        #expect(!difference.contains([185, 100]), "引く側にしか無い所は出てこない")
    }

    @Test("交わり: 両方の内側だけが残る")
    func intersectionKeepsTheOverlap() {
        let overlap = a.intersection(b)
        #expect(overlap.contains([130, 100]))
        #expect(!overlap.contains([70, 100]))
        #expect(!overlap.contains([190, 100]))
    }

    // MARK: - 完了条件 4

    @Test("穴の向きが崩れない: 輪の穴は穴のままで、和に入れても塞がらない")
    func holesStayHoles() {
        let ring = disc(100, 100, 50).subtracting(disc(100, 100, 20))
        #expect(!ring.contains([100, 100]))
        #expect(ring.contains([130, 100]))
        let both = Path.union([ring, disc(200, 100, 30)])
        #expect(!both.contains([100, 100]), "穴は塞がらない")
        #expect(both.contains([130, 100]) && both.contains([200, 100]))
        // 穴が逆向きの部分道として入っている (回り数の規則で抜く形)
        #expect(ring.subpaths.count == 2)
    }

    @Test("向きの逆な道どうしの和でも、重なりが抜けない (部分道を連結して回り数で数える作りだと抜ける)")
    func oppositeOrientationsDoNotCancel() {
        let union = Path.union([a, reversed(b)])
        #expect(union.contains([130, 100]), "重なり")
        #expect(union.contains([70, 100]) && union.contains([190, 100]))
        #expect(abs(union.length - 442.9) < 0.5, "長さ \(union.length)")
    }

    // MARK: - 完了条件 5

    @Test("境界: 空・1 つ・空の道との演算・離れた交わり")
    func boundaries() {
        let empty = Path.union([])
        #expect(empty.length == 0 && !empty.contains([0, 0]) && !empty.contains([100, 100]))

        let single = Path.union([a])
        #expect(single.contains([100, 100]) && !single.contains([151, 100]))

        let minusEmpty = a.subtracting(empty)
        #expect(minusEmpty.contains([100, 100]) && !minusEmpty.contains([151, 100]))
        #expect(minusEmpty.length == a.length)

        let withEmpty = a.intersection(empty)
        #expect(withEmpty.length == 0 && !withEmpty.contains([100, 100]))
        #expect(empty.intersection(a).length == 0)
        #expect(empty.subtracting(a).length == 0)

        let far = disc(0, 0, 50).intersection(disc(300, 0, 50))
        #expect(far.length == 0 && far.subpaths.isEmpty && !far.contains([0, 0]) && !far.contains([300, 0]))

        let unionWithEmpty = Path.union([empty, a, empty])
        #expect(unionWithEmpty.contains([100, 100]) && !unionWithEmpty.contains([151, 100]))

        // 全部を引くと何も残らない
        #expect(a.subtracting(disc(100, 100, 80)).subpaths.isEmpty)
    }

    @Test("1 つだけ・空との組でも、重なる部分道は 1 つの形にまとまり、開いた部分道は閉じ、面の無い部分道は落ちる")
    func singleAndEmptyPairsAreNormalised() {
        // `createPath { }` で重なった円を 1 つの道に入れた形
        let overlapped = Path(subpaths: a.subpaths + b.subpaths)
        #expect(abs(overlapped.length - (a.length + b.length)) < 0.01, "元は輪郭が 2 本重なっている: \(overlapped.length)")
        let empty = Path.union([])
        for (label, result) in [
            ("union([p])", Path.union([overlapped])),
            ("union([p, 空])", Path.union([overlapped, empty])),
            ("union([空, p])", Path.union([empty, overlapped])),
            ("p − 空", overlapped.subtracting(empty)),
        ] {
            #expect(result.subpaths.count == 1, "\(label): \(result.subpaths.count) 本")
            #expect(abs(result.length - 442.9) < 0.5, "\(label): \(result.length)")
            #expect(result.contains([150, 100]) && result.contains([100, 100]) && !result.contains([215, 100]), "\(label)")
        }
        #expect(overlapped.intersection(empty).subpaths.isEmpty && empty.intersection(overlapped).subpaths.isEmpty)

        let open = Path(subpaths: [
            Path.Subpath(
                points: [[0, 0], [100, 0], [100, 100], [0, 100]], isClosed: false,
                isCurveStep: [false, false, false, false])
        ])
        let line = Path.Subpath(points: [[0, 0], [300, 300]], isClosed: false, isCurveStep: [false, false])
        for result in [Path.union([open]), open.subtracting(empty), Path.union([open, empty])] {
            #expect(result.subpaths.count == 1 && result.subpaths.allSatisfy { $0.isClosed })
            #expect(result.length == 400, "閉じた辺を数える: \(result.length)")
        }
        let mixed = Path(subpaths: [open.subpaths[0], line])
        #expect(Path.union([mixed]).subpaths.count == 1, "面の無い部分道は落ちる")
        #expect(Path.union([Path(subpaths: [line])]).subpaths.isEmpty)
    }

    @Test("面を持たない部分道 (点・線)・数でない座標の部分道は無視され、落ちない")
    func degenerateSubpathsAreIgnored() {
        let line = Path.Subpath(points: [[0, 0], [300, 300]], isClosed: false, isCurveStep: [false, false])
        let broken = Path.Subpath(
            points: [[.nan, 0], [10, 0], [10, 10]], isClosed: true, isCurveStep: [false, false, false])
        let noise = Path(subpaths: [line, broken])
        let union = Path.union([a, noise])
        #expect(union.contains([100, 100]) && !union.contains([200, 200]))
        #expect(abs(union.length - a.length) < 0.01, "長さ \(union.length) / \(a.length)")
        #expect(noise.intersection(a).subpaths.isEmpty)
    }

    // MARK: - 完了条件 6

    @Test("同じ入力なら、結果は同じ (Hashable)")
    func deterministic() {
        #expect(Path.union([a, b]) == Path.union([a, b]))
        #expect(Path.union([a, b]).hashValue == Path.union([a, b]).hashValue)
        #expect(a.subtracting(b) == a.subtracting(b))
        #expect(a.intersection(b) == a.intersection(b))
    }

    // MARK: - 内外の一致

    @Test("格子の点で、和・差・交わりの内外が入力の論理演算と一致する (3 つの円・向きの逆な円を含む)")
    func insideMatchesTheSetAlgebra() {
        let paths = [disc(100, 100, 50), reversed(disc(160, 100, 50)), disc(130, 160, 40)]
        let union = Path.union(paths)
        let ab = paths[0].subtracting(paths[1])
        let ac = paths[0].intersection(paths[2])
        var inside = 0
        for p in lattice(of: paths) {
            let any = paths.contains { $0.contains(p) }
            #expect(union.contains(p) == any, "和 \(p)")
            if any { inside += 1 }
            #expect(ab.contains(p) == (paths[0].contains(p) && !paths[1].contains(p)), "差 \(p)")
            #expect(ac.contains(p) == (paths[0].contains(p) && paths[2].contains(p)), "交わり \(p)")
        }
        #expect(inside > 100, "内側の点を十分に調べている: \(inside)")
    }

    @Test("形の組を変えても、格子の点で内外が論理演算と一致する (同じ形・辺を共有・接する・点で触れる・8 の字・入れ子の島・極端な座標)")
    func insideMatchesForAwkwardPairs() {
        let figureEight = Path(subpaths: [
            Path.Subpath(
                points: [[0, 0], [100, 100], [100, 0], [0, 100]], isClosed: true,
                isCurveStep: [false, false, false, false])
        ])
        let ring = disc(100, 100, 50).subtracting(disc(100, 100, 30))
        let island = Path.union([ring, disc(100, 100, 10)])
        let pairs: [(String, Path, Path)] = [
            ("同じ形", a, a),
            ("同じ形・向き逆", a, reversed(a)),
            ("向き逆が先頭", reversed(a), b),
            ("辺を共有する四角", box(0, 0, 100, 100), box(100, 0, 200, 100)),
            ("角で触れる四角", box(0, 0, 100, 100), box(100, 100, 200, 200)),
            ("接する円", disc(0, 0, 50), disc(100, 0, 50)),
            ("四角の中の四角", box(0, 0, 100, 100), box(20, 20, 60, 60)),
            ("8 の字と円", figureEight, disc(50, 50, 40)),
            ("8 の字と四角", figureEight, box(30, -10, 70, 110)),
            ("輪と島", island, disc(130, 100, 40)),
            ("島と輪", island, ring),
            ("大きな座標", disc(1e6, 1e6, 50), disc(1e6 + 60, 1e6, 50)),
            // CoreGraphics の演算は半径 1e-6 でも面積の収支が 1e-4 以内で合う (実測) ので、その 4 桁上の大きさで測る
            ("小さな形", disc(0, 0, 0.01), disc(0.006, 0, 0.01)),
        ]
        for (label, p, q) in pairs {
            let inside = expectSetAlgebra(p, q, label)
            #expect(inside > 10, "\(label): 内側の点を調べている: \(inside)")
        }
    }

    @Test("円 6 個・100 個の和も、内外が入力の論理演算と一致する。並べる順を逆にしても内外は同じ")
    func manyCircles() {
        for count in [6, 100] {
            var paths: [Path] = []
            for index in 0..<count {
                // 6 個は 1 つの輪、100 個は 10 × 10 の格子 (半径 50・間隔 30 で、どれも隣と重なる)
                if count == 6 {
                    let angle = Float(index) / 6 * 2 * .pi
                    paths.append(disc(130 + 40 * cos(angle), 100 + 40 * sin(angle), 50))
                } else {
                    paths.append(disc(Float(index % 10) * 30, Float(index / 10) * 30, 50))
                }
            }
            let union = Path.union(paths)
            let backwards = Path.union(paths.reversed())
            var inside = 0
            for p in lattice(of: paths, count: count == 6 ? 41 : 25) {
                let any = paths.contains { $0.contains(p) }
                if any { inside += 1 }
                #expect(union.contains(p) == any, "\(count) 個: \(p)")
                #expect(backwards.contains(p) == any, "\(count) 個 (逆順): \(p)")
            }
            #expect(inside > 50, "\(count) 個: 内側の点を調べている: \(inside)")
        }
    }

    @Test("a ∪ b と b ∪ a は、点列が違ってもよいが内外は同じ")
    func orderChangesPointsNotInside() {
        let ab = Path.union([a, b])
        let ba = Path.union([b, a])
        for p in lattice(of: [a, b]) { #expect(ab.contains(p) == ba.contains(p), "\(p)") }
    }

    @Test("3 つの円が 1 点で交わる・接する入力でも、畳み込みの丸めで細い欠けが出ない")
    func circlesMeetingAtOnePoint() {
        // 半径 100/√3 の 3 つの円は、正三角形の重心 (50, 28.87) をちょうど通る
        let radius = Float(100.0 / 3.0.squareRoot())
        let meeting = [disc(0, 0, radius), disc(100, 0, radius), disc(50, 86.6025, radius)]
        let tangent = [disc(0, 0, 50), disc(100, 0, 50), disc(50, 0, 50)]
        for (label, paths) in [("1 点で交わる", meeting), ("接する", tangent)] {
            let union = Path.union(paths)
            var inside = 0
            for p in lattice(of: paths, count: 61) {
                let any = paths.contains { $0.contains(p) }
                if any { inside += 1 }
                #expect(union.contains(p) == any, "\(label) \(p)")
            }
            #expect(inside > 100, "\(label): \(inside)")
        }
    }

    // MARK: - 刻みの印

    @Test("刻みの印: 交点の近くだけが角で、弧の途中の点は刻みのまま")
    func curveStepMarksSurvive() {
        let union = Path.union([a, b])
        let all = union.subpaths.flatMap { zip($0.points, $0.isCurveStep) }
        // 交点は (130, 100 ± 40)
        func nearIntersection(_ p: SIMD2<Float>) -> Bool {
            let dx = p.x - 130
            let dy = abs(p.y - 100) - 40
            return (dx * dx + dy * dy).squareRoot() < 0.1  // 刻んだ辺どうしの交点は円の交点から 0.02 ほどずれる
        }
        #expect(all.filter { !$0.1 }.count >= 2, "交点は角になる")
        for (point, isStep) in all { #expect(isStep != nearIntersection(point), "\(point) 刻み=\(isStep)") }
        #expect(all.count > 100)

        // 四角の頂点は角として引き継ぐ
        let box = Path(subpaths: [
            Path.Subpath(
                points: [[0, 0], [100, 0], [100, 100], [0, 100]], isClosed: true,
                isCurveStep: [false, false, false, false])
        ])
        let whole = box.intersection(disc(50, 50, 80))
        #expect(whole.subpaths.allSatisfy { $0.isCurveStep.allSatisfy { !$0 } }, "四角が円に収まれば、結果は四角のまま (刻みは無い)")
        let cut = box.subtracting(disc(100, 100, 40))
        let marks = cut.subpaths.flatMap { $0.isCurveStep }
        #expect(marks.contains(true) && marks.contains(false))
    }

    @Test("内側は回り数で決める: 同じ向きに重ねた周は内側のまま残り、偶奇で数えたら穴になる")
    func nonZeroWindingNotEvenOdd() {
        func square(_ low: Float, _ high: Float) -> Path.Subpath {
            Path.Subpath(
                points: [[low, low], [high, low], [high, high], [low, high]], isClosed: true,
                isCurveStep: [false, false, false, false])
        }
        let nested = Path(subpaths: [square(0, 100), square(25, 75)])
        #expect(nested.contains([50, 50]), "contains の規則: 回り数 2 は内側")
        let far = disc(300, 50, 20)
        for result in [Path.union([nested, far]), nested.subtracting(far), nested.intersection(disc(50, 50, 200))] {
            #expect(result.contains([50, 50]) && result.contains([10, 10]), "入れ子の中も内側のまま")
        }
        let hole = Path(subpaths: [square(0, 100), Path.Subpath(
            points: [[25, 25], [25, 75], [75, 75], [75, 25]], isClosed: true, isCurveStep: [false, false, false, false])])
        #expect(!Path.union([hole, far]).contains([50, 50]), "逆向きは穴のまま")
    }

    // MARK: - CoreGraphics の出力の読み取り

    private func closedCG(_ points: [SIMD2<Float>], offset: Double = 0, repeatFirst: Bool = false) -> CGPath {
        let cg = CGMutablePath()
        var list = points.map { CGPoint(x: Double($0.x) + offset, y: Double($0.y) + offset) }
        if repeatFirst { list.append(list[0]) }
        cg.addLines(between: list)
        cg.closeSubpath()
        return cg
    }

    @Test("刻みの印は、座標が丸めの範囲でずれていても引き継ぎ、入力から離れた点は角にする")
    func marksSurviveSmallShifts() {
        let circle = a.subpaths[0]
        for offset in [0, 1e-5, -3e-5] {
            let result = Path(cgPath: closedCG(circle.points, offset: offset), inputs: [a])
            #expect(result.subpaths.count == 1 && result.subpaths[0].isCurveStep.allSatisfy { $0 }, "ずれ \(offset)")
        }
        let far = Path(cgPath: closedCG(circle.points, offset: 0.5), inputs: [a])
        #expect(far.subpaths[0].isCurveStep.allSatisfy { !$0 }, "入力から 0.5 離れた点は新しい点")
        // 近くに角があれば角を取る
        let withCorner = Path(subpaths: [
            Path.Subpath(points: circle.points, isClosed: true, isCurveStep: circle.isCurveStep),
            Path.Subpath(
                points: [circle.points[0] + SIMD2(1e-4, 0), [500, 500], [500, 600]], isClosed: true,
                isCurveStep: [false, false, false]),
        ])
        let mixed = Path(cgPath: closedCG(circle.points), inputs: [withCorner])
        #expect(!mixed.subpaths[0].isCurveStep[0] && mixed.subpaths[0].isCurveStep[1])
    }

    @Test("遠い形が 1 つ混ざっても、手前の交点は角のまま残り、許容が全体の最大の座標に引きずられない")
    func farShapeDoesNotWidenTheTolerance() {
        let far = disc(1e7, 0, 10)
        let union = Path.union([a, b, far])
        let near = union.subpaths.filter { subpath in subpath.points.allSatisfy { $0.x < 1000 } }
        let all = near.flatMap { zip($0.points, $0.isCurveStep) }
        func nearIntersection(_ p: SIMD2<Float>) -> Bool {
            let dx = p.x - 130
            let dy = abs(p.y - 100) - 40
            return (dx * dx + dy * dy).squareRoot() < 0.1
        }
        #expect(all.count > 100)
        #expect(all.filter { !$0.1 }.count >= 2, "交点が角のまま残る")
        for (point, isStep) in all { #expect(isStep != nearIntersection(point), "\(point) 刻み=\(isStep)") }
    }

    @Test("閉じた後に moveTo を挟まず線が来たら、閉じた部分道の始点から続ける")
    func lineAfterCloseStartsAtTheClosedStart() {
        let cg = CGMutablePath()
        cg.addLines(between: [CGPoint(x: 0, y: 0), CGPoint(x: 100, y: 0), CGPoint(x: 100, y: 100), CGPoint(x: 0, y: 100)])
        cg.closeSubpath()
        cg.addLine(to: CGPoint(x: 50, y: 200))
        cg.addLine(to: CGPoint(x: 0, y: 200))
        cg.closeSubpath()
        let path = Path(cgPath: cg, inputs: [])
        #expect(path.subpaths.count == 2, "\(path.subpaths.count) 本")
        #expect(path.subpaths.last?.points.first == SIMD2<Float>(0, 0), "2 本目は (0, 0) から始まる")
        #expect(path.subpaths.first?.points.count == 4)
        #expect(path.contains([10, 150]) && !path.contains([100, 150]) && path.contains([50, 50]))
    }

    @Test("CoreGraphics が始点へ戻る終点を返しても、重複を落とす。点が 3 つに満たない・Float に収まらない部分道は入れない")
    func cgOutputIsCleaned() {
        let square: [SIMD2<Float>] = [[0, 0], [100, 0], [100, 100], [0, 100]]
        let repeated = Path(cgPath: closedCG(square, repeatFirst: true), inputs: [])
        #expect(repeated.subpaths.count == 1 && repeated.subpaths[0].points.count == 4)
        #expect(repeated.length == 400, "閉じる辺が長さ 0 にならない: \(repeated.length)")

        let cg = CGMutablePath()
        cg.addLines(between: [CGPoint(x: 0, y: 0), CGPoint(x: 10, y: 0)])
        cg.closeSubpath()
        cg.addLines(between: [CGPoint(x: 0, y: 0), CGPoint(x: 1e300, y: 0), CGPoint(x: 0, y: 10)])
        cg.closeSubpath()
        cg.addLines(between: [CGPoint(x: 0, y: 0), CGPoint(x: 10, y: 0), CGPoint(x: 0, y: 10)])
        cg.closeSubpath()
        let cleaned = Path(cgPath: cg, inputs: [])
        #expect(cleaned.subpaths.count == 1, "2 点の部分道と 1e300 を含む部分道は入れない: \(cleaned.subpaths.count)")
    }

    @Test("曲線の要素が来ても形を落とさず、絶対の隔たり 0.02 以下で刻む")
    func curvesAreFlattened() {
        let cg = CGMutablePath()
        cg.addEllipse(in: CGRect(x: 0, y: 0, width: 100, height: 100))
        let ellipse = Path(cgPath: cg, inputs: [])
        #expect(ellipse.subpaths.count == 1 && ellipse.subpaths[0].points.count > 16)
        #expect(ellipse.contains([50, 50]) && !ellipse.contains([-1, 50]) && !ellipse.contains([50, 101]))
        let circumference = 2 * Float.pi * 50
        #expect(abs(ellipse.length - circumference) < circumference * 5e-4, "\(ellipse.length)")
        // 曲線の端点 4 つだけが入力に無い点 (角)。刻んだ途中の点は刻みの印を持つ
        let steps = ellipse.subpaths[0].isCurveStep
        #expect(steps.filter { !$0 }.count == 4 && steps.filter { $0 }.count == steps.count - 4)
        for point in ellipse.subpaths[0].points {
            let radius = ((point.x - 50) * (point.x - 50) + (point.y - 50) * (point.y - 50)).squareRoot()
            #expect(abs(radius - 50) < 0.05, "刻んだ点は円の上にある (ベジェ自身の近似が 0.013 ほど): \(radius)")
        }
        // 2 次の曲線 (放物線の弓形)
        let quad = CGMutablePath()
        quad.move(to: CGPoint(x: 0, y: 0))
        quad.addQuadCurve(to: CGPoint(x: 100, y: 0), control: CGPoint(x: 50, y: 100))
        quad.closeSubpath()
        let arch = Path(cgPath: quad, inputs: [])
        #expect(arch.contains([50, 30]) && !arch.contains([50, 60]) && arch.contains([50, 49]))
    }

    @Test("開いた部分道も閉じた形として扱う")
    func openSubpathsAreClosed() {
        let open = Path(subpaths: [
            Path.Subpath(
                points: [[0, 0], [100, 0], [100, 100], [0, 100]], isClosed: false,
                isCurveStep: [false, false, false, false])
        ])
        let union = Path.union([open, disc(150, 50, 30)])
        #expect(union.contains([50, 50]) && union.contains([170, 50]))
        #expect(union.subpaths.allSatisfy { $0.isClosed })
    }
}

/// 和・差・交わりの結果を描いた画素 (#3647)。
@Suite(
    "道の演算 (画素)",
    .enabled(
        if: RenderDevice.isAvailable,
        "この世代のコマンド構造に対応した GPU が無い実行環境ではスキップする")
)
struct PathOperationsPictureTests {
    private let black = LinearRGBA.linear(red: 0, green: 0, blue: 0)
    private let white = LinearRGBA.linear(red: 1, green: 1, blue: 1)

    private var a: Path { Path(Circle(center: [100, 100], radius: 50)) }
    private var b: Path { Path(Circle(center: [160, 100], radius: 50)) }

    private func picture(_ body: (Canvas) -> Void) throws -> DisplayImage {
        let canvas = try CanvasFixture.make(gpu: RenderDevice(), width: 260, height: 200)
        try canvas.draw {
            canvas.background(black)
            body(canvas)
        }
        return try canvas.target.encodeForDisplay()
    }

    private func red(_ image: DisplayImage, _ x: Int, _ y: Int) -> UInt8 {
        image.bytes[(y * image.width + x) * 4]
    }

    @Test("和を線で描くと、重なりの内側に線が出ず、外周には出る。円を別々に描くと内側に線が残る")
    func unionOutline() throws {
        let image = try picture { canvas in
            canvas.noFill()
            canvas.stroke(white)
            canvas.strokeWeight(2)
            canvas.shape(Path.union([a, b]))
        }
        #expect(red(image, 150, 100) < 8, "重なりの内側: \(red(image, 150, 100))")
        #expect(red(image, 50, 100) > 200 && red(image, 210, 100) > 200, "外周")

        let separate = try picture { canvas in
            canvas.noFill()
            canvas.stroke(white)
            canvas.strokeWeight(2)
            canvas.shape(a)
            canvas.shape(b)
        }
        #expect(red(separate, 150, 100) > 200, "別々に描くと、左の円の輪郭が (150, 100) を通る")
    }

    @Test("差と交わりを塗ると、(130, 100) と (70, 100) の画素が内外と合う")
    func filledDifferenceAndIntersection() throws {
        let difference = try picture { canvas in
            canvas.noStroke()
            canvas.fill(white)
            canvas.shape(a.subtracting(b))
        }
        #expect(red(difference, 130, 100) < 8 && red(difference, 70, 100) > 247)
        let overlap = try picture { canvas in
            canvas.noStroke()
            canvas.fill(white)
            canvas.shape(a.intersection(b))
        }
        #expect(red(overlap, 130, 100) > 247 && red(overlap, 70, 100) < 8)
    }

    @Test("輪の穴は塗りでも抜けたまま")
    func ringHole() throws {
        let ring = a.subtracting(Path(Circle(center: [100, 100], radius: 20)))
        let image = try picture { canvas in
            canvas.noStroke()
            canvas.fill(white)
            canvas.shape(Path.union([ring, Path(Circle(center: [200, 100], radius: 30))]))
        }
        #expect(red(image, 100, 100) < 8 && red(image, 130, 100) > 247 && red(image, 200, 100) > 247)
    }
}

/// 結果の部分道の向き (外周と穴・島・割れた形) が、`contains` と塗りの画素で同じ内外になる (#3647)。
@Suite(
    "道の演算 (向きと塗り)",
    .enabled(
        if: RenderDevice.isAvailable,
        "この世代のコマンド構造に対応した GPU が無い実行環境ではスキップする")
)
struct PathOperationsOrientationPictureTests {
    private func disc(_ x: Float, _ y: Float, _ radius: Float) -> Path {
        Path(Circle(center: [x, y], radius: radius))
    }

    private func bar(_ x0: Float, _ x1: Float) -> Path {
        Path(subpaths: [
            Path.Subpath(
                points: [[x0, -10], [x1, -10], [x1, 210], [x0, 210]], isClosed: true,
                isCurveStep: [false, false, false, false])
        ])
    }

    @Test("島 (穴の中の小さな円)・穴が 2 つの輪・2 つに割れた差は、contains と塗りの画素が全部の格子点で一致する")
    func fillAgreesWithContains() throws {
        let ring = disc(100, 100, 80).subtracting(disc(100, 100, 50))
        let shapes: [(String, Path)] = [
            ("島", Path.union([ring, disc(100, 100, 20)])),
            ("穴が 2 つ", disc(100, 100, 80).subtracting(disc(70, 100, 20)).subtracting(disc(130, 100, 20))),
            ("2 つに割れる差", disc(100, 100, 80).subtracting(bar(90, 110))),
            ("入れ子の島が 2 重", Path.union([ring, disc(100, 100, 30).subtracting(disc(100, 100, 12))])),
        ]
        for (label, path) in shapes {
            let canvas = try CanvasFixture.make(gpu: RenderDevice(), width: 200, height: 200)
            try canvas.draw {
                canvas.background(LinearRGBA.linear(red: 0, green: 0, blue: 0))
                canvas.noStroke()
                canvas.fill(LinearRGBA.linear(red: 1, green: 1, blue: 1))
                canvas.shape(path)
            }
            let image = try canvas.target.encodeForDisplay()
            var checked = 0
            var inside = 0
            for y in stride(from: 3, to: 197, by: 4) {
                for x in stride(from: 3, to: 197, by: 4) {
                    let probe = Vector2(Float(x) + 0.5, Float(y) + 0.5)
                    // 輪郭から 2 以上離れた点だけ (縁の混ぜを避ける)
                    guard
                        path.subpaths.allSatisfy({ sub in
                            sub.edges().allSatisfy { Self.distance(probe, $0.0, $0.1) > 2 }
                        })
                    else { continue }
                    let filled = image.bytes[(y * image.width + x) * 4] > 127
                    #expect(filled == path.contains(probe), "\(label) (\(x), \(y)) 塗り=\(filled)")
                    checked += 1
                    if filled { inside += 1 }
                }
            }
            #expect(checked > 800 && inside > 100, "\(label): 調べた点 \(checked) / 塗られた点 \(inside)")
        }
    }

    private static func distance(_ p: Vector2, _ from: SIMD2<Float>, _ to: SIMD2<Float>) -> Float {
        let point = SIMD2<Float>(p.x, p.y)
        let edge = to - from
        let length2 = (edge * edge).sum()
        let along = length2 > 0 ? max(0, min(1, ((point - from) * edge).sum() / length2)) : 0
        let gap = point - (from + edge * along)
        return (gap * gap).sum().squareRoot()
    }
}
