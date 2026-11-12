// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation
import simd
import Testing

@testable import MokumeCore

/// 線を形で切る `clipped(to:)` (#3649)。値の問いは GPU が要らない。
@Suite("線を形で切る clipped (値)")
nonisolated struct PathClippedValueTests {
    private func disc(_ x: Float, _ y: Float, _ radius: Float) -> Path {
        Path(Circle(center: [x, y], radius: radius))
    }

    private var a: Path { disc(100, 100, 50) }
    private var b: Path { disc(160, 100, 50) }

    /// 開いた線分 1 本の道。
    private func segment(_ from: Vector2, _ to: Vector2) -> Path {
        Path(subpaths: [
            Path.Subpath(points: [from.simd, to.simd], isClosed: false, isCurveStep: [false, false])
        ])
    }

    private func near(_ point: Vector2, _ expected: Vector2, within tolerance: Float = 0.05) -> Bool {
        let dx = point.x - expected.x
        let dy = point.y - expected.y
        return (dx * dx + dy * dy).squareRoot() <= tolerance
    }

    /// 完了条件 1。`a` の内側にある `b` の弧は 106.26° で、長さは 50 × 1.8546 = 92.73。
    @Test("切った線の端点は形の縁に乗り、元の向きのまま 1 片で返る")
    func endpointsLieOnTheEdge() {
        let clipped = b.clipped(to: a)
        #expect(clipped.subpaths.count == 1)
        #expect(clipped.subpaths.allSatisfy { !$0.isClosed })
        #expect(abs(clipped.length - 92.7) < 0.5, "length = \(clipped.length)")
        // `b` は右端 (210, 100) から角度の増える向きに回るので、(130, 140) を先に通る
        #expect(near(clipped.point(at: 0), [130, 140]), "point(at: 0) = \(clipped.point(at: 0))")
        #expect(near(clipped.point(at: 1), [130, 60]), "point(at: 1) = \(clipped.point(at: 1))")
        // 残った点は全部 `a` の内側か縁の上
        for point in clipped.subpaths.flatMap(\.points) {
            #expect(simd_distance(SIMD2<Double>(point), [100, 100]) <= 50.05, "\(point)")
        }
    }

    /// 完了条件 1 の推奨案: 閉じた部分道の始点 (`a` の (150, 100)) が相手の内側にあっても、2 片に割れない。
    @Test("閉じた部分道の始点が内側にあっても 1 片で返る")
    func startInsideStaysOnePiece() {
        let clipped = a.clipped(to: b)
        #expect(clipped.subpaths.count == 1)
        #expect(abs(clipped.length - 92.7) < 0.5, "length = \(clipped.length)")
        // `a` は (130, 60) で `b` に入り、始点 (150, 100) を過ぎて (130, 140) で出る
        #expect(near(clipped.point(at: 0), [130, 60]), "point(at: 0) = \(clipped.point(at: 0))")
        #expect(near(clipped.point(at: 1), [130, 140]), "point(at: 1) = \(clipped.point(at: 1))")
    }

    /// 完了条件 2。
    @Test("境界: 空の相手は空・全部が内側なら長さは元と同じ・全部が外側なら長さ 0")
    func boundaries() {
        #expect(b.clipped(to: Path()).subpaths.isEmpty)
        #expect(Path().clipped(to: a).subpaths.isEmpty)

        let inner = disc(100, 100, 10)
        let kept = inner.clipped(to: a)
        #expect(abs(kept.length - inner.length) < 1e-3, "length = \(kept.length) / 元 \(inner.length)")
        // 全部が内側の閉じた部分道は閉じたまま
        #expect(kept.subpaths.count == 1 && kept.subpaths[0].isClosed)

        let outer = disc(400, 100, 10).clipped(to: a)
        #expect(outer.length == 0)
        #expect(outer.subpaths.isEmpty)
    }

    @Test("開いた線分は閉じずに切り、向きを保つ。2 点の片も残る")
    func openSegments() {
        let forward = segment([0, 100], [300, 100]).clipped(to: a)
        #expect(forward.subpaths.count == 1)
        #expect(forward.subpaths[0].points.count == 2 && !forward.subpaths[0].isClosed)
        #expect(near(forward.point(at: 0), [50, 100]) && near(forward.point(at: 1), [150, 100]))

        let backward = segment([300, 100], [0, 100]).clipped(to: a)
        #expect(near(backward.point(at: 0), [150, 100]) && near(backward.point(at: 1), [50, 100]))

        // 外へ出て戻る折れ線は、内側の 2 片に分かれる
        let wiggle = Path(subpaths: [
            Path.Subpath(
                points: [[100, 100], [200, 100], [200, 120], [100, 120]], isClosed: false,
                isCurveStep: [false, false, false, false])
        ]).clipped(to: a)
        #expect(wiggle.subpaths.count == 2)
        #expect(abs(wiggle.length - (50 + Float(sqrt(2100.0)))) < 0.1, "length = \(wiggle.length)")
    }

    /// 相手の内側は `contains` と同じ回り数の規則。同じ向きに重ねた 2 つの円は、重なり (回り数 2) も内側。
    @Test("相手の内側は回り数が 0 でない所 (偶奇ではない)")
    func nonZeroWindingNotEvenOdd() {
        let overlapped = Path(subpaths: a.subpaths + b.subpaths)
        let clipped = segment([0, 100], [300, 100]).clipped(to: overlapped)
        #expect(clipped.subpaths.count == 1)
        #expect(abs(clipped.length - 160) < 0.1, "length = \(clipped.length)")
    }

    @Test("線にならない部分道 (点 1 つ・数でない座標) は入れない")
    func degenerateSubpathsAreIgnored() {
        let lonely = Path(subpaths: [Path.Subpath(points: [[100, 100]], isClosed: false, isCurveStep: [false])])
        #expect(lonely.clipped(to: a).subpaths.isEmpty)
        let broken = Path(subpaths: [
            Path.Subpath(points: [[0, 100], [.nan, 100]], isClosed: false, isCurveStep: [false, false])
        ])
        let mixed = Path(subpaths: broken.subpaths + segment([0, 90], [300, 90]).subpaths)
        let clipped = mixed.clipped(to: a)
        #expect(clipped.subpaths.count == 1)
        #expect(clipped.subpaths.allSatisfy { $0.points.allSatisfy { $0.x.isFinite && $0.y.isFinite } })
    }

    @Test("刻みの印: 円の弧の途中は刻みのまま、縁で切った端点は角")
    func curveStepMarks() {
        let clipped = b.clipped(to: a)
        let marks = clipped.subpaths[0].isCurveStep
        #expect(marks.first == false && marks.last == false)
        #expect(marks.dropFirst().dropLast().allSatisfy { $0 })
        // 全部が内側の円は全部が刻み
        #expect(disc(100, 100, 10).clipped(to: a).subpaths[0].isCurveStep.allSatisfy { $0 })
    }

    /// 作例の斜線: 線の束を雲の中だけに切ると、残った点は全部が雲の内側か縁の上にある。
    @Test("斜線の束を切ると、残った点は全部が形の内側か縁の上")
    func hatchStaysInside() {
        let hatch = Path(
            subpaths: stride(from: Float(-200), to: 400, by: 8).map { x in
                Path.Subpath(points: [[x, 0], [x + 200, 200]], isClosed: false, isCurveStep: [false, false])
            })
        let clipped = hatch.clipped(to: a)
        #expect(!clipped.subpaths.isEmpty)
        for point in clipped.subpaths.flatMap(\.points) {
            #expect(simd_distance(SIMD2<Double>(point), [100, 100]) <= 50.05, "\(point)")
        }
    }

    /// 開いた折れ線 (点 3 つ以上)。CoreGraphics の `lineIntersection` は、この形で最後の辺を落としたり外側の片を
    /// 返したりした (macOS 27.0.1 で確かめた)。
    private func polyline(_ points: [SIMD2<Float>]) -> Path {
        Path(subpaths: [
            Path.Subpath(points: points, isClosed: false, isCurveStep: Array(repeating: false, count: points.count))
        ])
    }

    @Test("開いた折れ線が全部内側なら、開いたまま・長さも端点も元と同じで返る")
    func openPolylineFullyInside() {
        let clipped = polyline([[80, 90], [120, 90], [120, 110], [80, 110]]).clipped(to: a)
        #expect(clipped.subpaths.count == 1)
        #expect(clipped.subpaths.allSatisfy { !$0.isClosed })
        #expect(abs(clipped.length - 100) < 1e-3, "length = \(clipped.length)")
        #expect(near(clipped.point(at: 0), [80, 90]) && near(clipped.point(at: 1), [80, 110]))
    }

    /// `a` の縁は y = 90 で x = 100 - √2400 = 51.01。
    @Test("外から入って内側で終わる折れ線は、内側の部分だけを元の向きで残す")
    func openPolylineEndingInside() {
        let clipped = polyline([[0, 90], [80, 90], [80, 110]]).clipped(to: a)
        let edge = 100 - Float(sqrt(2400.0))
        #expect(clipped.subpaths.count == 1)
        #expect(abs(clipped.length - (80 - edge + 20)) < 0.05, "length = \(clipped.length)")
        #expect(near(clipped.point(at: 0), [edge, 90]), "point(at: 0) = \(clipped.point(at: 0))")
        #expect(near(clipped.point(at: 1), [80, 110]), "point(at: 1) = \(clipped.point(at: 1))")
    }

    @Test("縁に接するだけの線 (頂点に触れる直線・頂点で折れ返す折れ線・四角の角) は空の道")
    func touchingLinesAreEmpty() {
        // `a` は右端 (150, 100) を頂点に持つ
        #expect(segment([150, 0], [150, 200]).clipped(to: a).subpaths.isEmpty)
        #expect(polyline([[200, 50], [150, 100], [200, 150]]).clipped(to: a).subpaths.isEmpty)
        let square = Path(subpaths: [
            Path.Subpath(
                points: [[0, 0], [100, 0], [100, 100], [0, 100]], isClosed: true, isCurveStep: [false, false, false, false])
        ])
        #expect(segment([-50, 50], [50, -50]).clipped(to: square).subpaths.isEmpty)
        #expect(polyline([[-50, 50], [0, 0], [-50, -50]]).clipped(to: square).subpaths.isEmpty)
        // 尖った頂点の先をかすめる線: 内側の区間はあるが、幅 (1.5e-6 ほど) が x = 100 の Float の刻み (7.6e-6) より
        // 狭く、両端が同じ点に丸まる。長さ 0 の片は残さない
        let spike = Path(subpaths: [
            Path.Subpath(
                points: [[90, 0], [110, 0], [100, 100.0000076]], isClosed: true, isCurveStep: [false, false, false])
        ])
        #expect(spike.contains([100, 99.99]))
        #expect(segment([0, 100], [200, 100]).clipped(to: spike).subpaths.isEmpty)
    }

    /// 縁の上をなぞる線は、`contains` が辺の上の点に答えるのと同じく、辺によって残ったり消えたりする。
    @Test("縁の上をなぞる線: 四角の上の辺 (y = 0) は残り、下の辺 (y = 100) は消える")
    func linesAlongTheEdge() {
        let square = Path(subpaths: [
            Path.Subpath(
                points: [[0, 0], [100, 0], [100, 100], [0, 100]], isClosed: true, isCurveStep: [false, false, false, false])
        ])
        let top = segment([20, 0], [80, 0]).clipped(to: square)
        let bottom = segment([20, 100], [80, 100]).clipped(to: square)
        #expect(abs(top.length - 60) < 1e-3, "上の辺 \(top.length)")
        #expect(bottom.subpaths.isEmpty, "下の辺 \(bottom.length)")
        // `contains` も同じ答え
        #expect(square.contains([50, 0]) && !square.contains([50, 100]))
    }

    /// 2 本の線分は (100, 100) で交わる。それぞれ `a` の中の長さは直径の 100。
    @Test("自分自身と交わる線も、辺ごとに内側の部分を残す")
    func selfCrossingLine() {
        let clipped = polyline([[0, 80], [200, 120], [200, 80], [0, 120]]).clipped(to: a)
        #expect(clipped.subpaths.count == 2)
        #expect(abs(clipped.length - 200) < 0.1, "length = \(clipped.length)")
    }

    @Test("穴のある相手: 穴の中 (回り数 0) は外側")
    func holeIsOutside() {
        let hole = Path(
            subpaths: disc(100, 100, 20).subpaths.map {
                Path.Subpath(points: $0.points.reversed(), isClosed: true, isCurveStep: $0.isCurveStep)
            })
        let ring = Path(subpaths: a.subpaths + hole.subpaths)
        let clipped = segment([0, 100], [200, 100]).clipped(to: ring)
        #expect(clipped.subpaths.count == 2)
        #expect(abs(clipped.length - 60) < 0.1, "length = \(clipped.length)")
        #expect(near(clipped.point(at: 0), [50, 100]) && near(clipped.point(at: 1), [150, 100]))
    }

    @Test("曲線の線を切っても、残った点は曲線の上に乗る")
    func curvedLineStaysOnTheCurve() {
        // `b` の半周 ((210, 100) から (160, 150) を通って (110, 100) まで) を開いた弧にして、x ≥ 150 の四角で切る
        let arc = Path(subpaths: b.subpaths.map {
            Path.Subpath(points: Array($0.points[0...56]), isClosed: false, isCurveStep: Array($0.isCurveStep[0...56]))
        })
        let box = Path(subpaths: [
            Path.Subpath(
                points: [[150, 90], [250, 90], [250, 200], [150, 200]], isClosed: true,
                isCurveStep: [false, false, false, false])
        ])
        let clipped = arc.clipped(to: box)
        #expect(clipped.subpaths.count == 1)
        for point in clipped.subpaths.flatMap(\.points) {
            let distance = simd_distance(SIMD2<Double>(point), [160, 100])
            #expect(distance <= 50.001 && distance >= 49.97, "\(point) は中心から \(distance)")
        }
        // 始点は弧の始まり、終点は x = 150 で切った所 (150, 100 + √2400)
        #expect(near(clipped.point(at: 0), [210, 100]))
        #expect(near(clipped.point(at: 1), [150, 100 + Float(sqrt(2400.0))]), "\(clipped.point(at: 1))")
    }

    @Test("相手の数でない座標を持つ部分道は落ちる (残りの部分道だけで切る)")
    func nonFiniteRegionSubpathsAreDropped() {
        // 線 (y = 100) をまたぐ三角形の 1 点が数でない
        let broken = Path.Subpath(
            points: [[300, 50], [.nan, 150], [350, 150]], isClosed: true, isCurveStep: [false, false, false])
        let withBroken = Path(subpaths: a.subpaths + [broken])
        let line = segment([0, 100], [400, 100])
        #expect(line.clipped(to: withBroken) == line.clipped(to: a))
        // `contains` は数でない点の部分道も有限の辺だけで数えるので、ここでは内側と答える (説明文で名乗るずれ)
        #expect(withBroken.contains([310, 100]))
        #expect(line.clipped(to: withBroken).subpaths.allSatisfy { $0.points.allSatisfy { $0.x < 200 } })
    }

    @Test("別の部分道の片は、端点が同じ所にあっても繋がない")
    func separateSubpathsAreNotJoined() {
        let first = segment([0, 90], [80, 90]).subpaths
        let second = segment([80, 90], [200, 90]).subpaths
        let clipped = Path(subpaths: first + second).clipped(to: a)
        #expect(clipped.subpaths.count == 2)
    }

    @Test("始点で割れた片を繋ぐのは、閉じた部分道の始点と終わりが両方内側のときだけ")
    func joiningAcrossTheStart() {
        let head = Path.ClipPiece(points: [[0, 0], [1, 0]], isCurveStep: [false, true])
        let middle = Path.ClipPiece(points: [[2, 0], [3, 0]], isCurveStep: [false, false])
        let tail = Path.ClipPiece(points: [[5, 0], [0, 0]], isCurveStep: [false, false])
        let joined = Path.joinedAcrossStart([head, middle, tail], isClosed: true, startsInside: true, endsInside: true)
        #expect(joined.count == 2)
        #expect(joined.last?.points == [[5, 0], [0, 0], [1, 0]])
        #expect(joined.last?.isCurveStep == [false, false, true])
        // 開いた線の両端が内側でも繋がない
        #expect(Path.joinedAcrossStart([head, tail], isClosed: false, startsInside: true, endsInside: true).count == 2)
        // 始点が外側なら繋がない
        #expect(Path.joinedAcrossStart([head, tail], isClosed: true, startsInside: false, endsInside: true).count == 2)
    }

    /// 四角 (0, 0)–(100, 100)。点は `[[0, 0], [100, 0], [100, 100], [0, 100]]` の順。
    private var square: Path { closed([[0, 0], [100, 0], [100, 100], [0, 100]]) }

    private func closed(_ points: [SIMD2<Float>]) -> Path {
        Path(subpaths: [
            Path.Subpath(points: points, isClosed: true, isCurveStep: Array(repeating: false, count: points.count))
        ])
    }

    /// 相手の内側の回り数が -1 でも内側 (回り数が正の所だけを内側にしない)。
    @Test("逆回りの相手 (回り数 -1) の内側も残る")
    func reversedRegionIsInside() {
        let reversed = closed([[0, 0], [0, 100], [100, 100], [100, 0]])
        let clipped = segment([-50, 50], [150, 50]).clipped(to: reversed)
        #expect(clipped.subpaths.count == 1)
        #expect(abs(clipped.length - 100) < 1e-3, "length = \(clipped.length)")
        #expect(clipped.subpaths.first?.points == [[0, 50], [100, 50]])
    }

    /// 縁に乗る線は `contains` が縁の点に返す答えのとおり: 四角なら x の小さい側の縦の辺と y の小さい側の横の辺が
    /// 残り、反対側の 2 辺は消える。
    @Test("縁に乗る線: 四角を自分自身で切ると、残る 2 辺を繋いだ開いた L 字の 1 片になる")
    func squareClippedToItself() {
        let clipped = square.clipped(to: square)
        #expect(clipped.subpaths.count == 1)
        #expect(clipped.subpaths.first?.isClosed == false)
        // 左の辺 (0, 100)→(0, 0) と上の辺 (0, 0)→(100, 0) が、始点の前後で繋がる
        #expect(clipped.subpaths.first?.points == [[0, 100], [0, 0], [100, 0]])
        #expect(abs(clipped.length - 200) < 1e-3, "length = \(clipped.length)")
        // 逆回りの四角を相手にしても、残る辺は同じ (左の辺と上の辺)
        let reversed = closed([[0, 0], [0, 100], [100, 100], [100, 0]])
        #expect(square.clipped(to: reversed).subpaths.first?.points == [[0, 100], [0, 0], [100, 0]])
        // 内側の三角形が右の辺 (x = 100) を共有すると、その辺が消えて開いた 1 片になる (長さは斜めの 2 辺の 2 × 50√2)
        let sharing = closed([[100, 0], [100, 100], [50, 50]]).clipped(to: square)
        #expect(sharing.subpaths.count == 1 && sharing.subpaths.first?.isClosed == false)
        #expect(sharing.subpaths.first?.points == [[100, 100], [50, 50], [100, 0]])
        #expect(abs(sharing.length - 100 * Float(2.0.squareRoot())) < 1e-3, "length = \(sharing.length)")
        // 説明文の勧め: 少し内側へ寄せた四角は、閉じたまま全部が残る
        let inset = closed([[0.5, 0.5], [99.5, 0.5], [99.5, 99.5], [0.5, 99.5]]).clipped(to: square)
        #expect(inset.subpaths.count == 1 && inset.subpaths.first?.isClosed == true)
        #expect(abs(inset.length - 396) < 1e-3, "length = \(inset.length)")
    }

    /// 閉じた道が四角の右の辺 (x = 100) を 4 回出入りし、始点 (10, 50) は内側。入る点は (100, 60)・(100, 80)・
    /// (10, 100) の順で、最後の (10, 100) から始まる片が始点をまたいで最初の片と繋がる。
    @Test("片の順: 元の道を辿って片が始まる位置の順。始点をまたいで繋いだ片は最後")
    func pieceOrderFollowsTheEntries() {
        let comb = closed([
            [10, 50], [150, 50], [150, 60], [60, 60], [60, 70], [150, 70], [150, 80], [50, 80], [50, 120], [10, 120],
        ])
        let clipped = comb.clipped(to: square)
        #expect(clipped.subpaths.map(\.points) == [
            [[100, 60], [60, 60], [60, 70], [100, 70]],
            [[100, 80], [50, 80], [50, 100]],
            [[10, 100], [10, 50], [100, 50]],
        ])
        #expect(abs(clipped.length - 300) < 1e-3, "length = \(clipped.length)")
    }

    @Test("相手の頂点 (四角の角) を通って外から中へ入る線は、角から始まる 1 片")
    func lineEnteringThroughAVertex() {
        let clipped = segment([-50, -50], [50, 50]).clipped(to: square)
        #expect(clipped.subpaths.map(\.points) == [[[0, 0], [50, 50]]])
        #expect(abs(clipped.length - 50 * Float(2.0.squareRoot())) < 1e-3, "length = \(clipped.length)")
    }

    /// 原点が中心の円は、左端の頂点の y が -4.4e-6 ほどで、ほかの座標 (50 前後) と桁が混ざる。その頂点を通って
    /// 45° で入る線の内側は、円の弦 2 × 50 × cos 45° = 70.71 (折れ線の円なので 0.05 まで許す)。
    @Test("桁の混ざる頂点 (原点の円の左端) を通って入る線も、頂点から始まる 1 片")
    func lineEnteringThroughATinyCoordinateVertex() {
        let circle = disc(0, 0, 50)
        let points = circle.subpaths[0].points
        let vertex = points[points.count / 2]
        #expect(vertex.x == -50 && vertex.y != 0 && abs(vertex.y) < 1e-5, "\(vertex)")
        let clipped = segment(Vector2(vertex - [50, 50]), Vector2(vertex + [100, 100])).clipped(to: circle)
        #expect(clipped.subpaths.count == 1)
        #expect(abs(clipped.length - 50 * Float(2.0.squareRoot())) < 0.05, "length = \(clipped.length)")
        #expect(near(clipped.point(at: 0), Vector2(vertex), within: 1e-3), "point(at: 0) = \(clipped.point(at: 0))")
    }

    @Test("内側から縁に 1 点で触れる閉じた道は、閉じたまま返る")
    func closedPathTouchingTheEdgeStaysClosed() {
        // 下の辺 (y = 100。縁に乗る線なら消える側) に頂点 (50, 100) で触れる三角形
        let triangle = closed([[50, 100], [20, 50], [80, 50]])
        let clipped = triangle.clipped(to: square)
        #expect(clipped.subpaths.count == 1 && clipped.subpaths.first?.isClosed == true)
        #expect(abs(clipped.length - triangle.length) < 1e-3, "length = \(clipped.length) / 元 \(triangle.length)")
    }

    @Test("閉じた道の始点がちょうど縁の上: 始点から内側へ入る片が 1 つ")
    func closedPathStartingOnTheEdge() {
        // 始点 (100, 20) は右の辺の上。内側を (70, 50) を通って (100, 80) まで進み、外を回って戻る
        let diamond = closed([[100, 20], [70, 50], [100, 80], [130, 50]])
        let clipped = diamond.clipped(to: square)
        #expect(clipped.subpaths.map(\.points) == [[[100, 20], [70, 50], [100, 80]]])
        #expect(clipped.subpaths.first?.isClosed == false)
        #expect(abs(clipped.length - 60 * Float(2.0.squareRoot())) < 1e-3, "length = \(clipped.length)")
    }

    @Test("縁と一部だけ重なる線: 残る側の辺 (y = 0) では重なった所が残り、消える側の辺 (y = 100) では消える")
    func linePartlyAlongTheEdge() {
        let top = segment([-50, 0], [50, 0]).clipped(to: square)
        #expect(top.subpaths.map(\.points) == [[[0, 0], [50, 0]]])
        #expect(segment([-50, 100], [50, 100]).clipped(to: square).subpaths.isEmpty)
    }

    @Test("座標が 1e6 級の形でも、縁の上で切る")
    func largeCoordinates() {
        let far = closed([[1e6, 1e6], [1e6 + 1000, 1e6], [1e6 + 1000, 1e6 + 1000], [1e6, 1e6 + 1000]])
        let clipped = segment([1e6 - 500, 1e6 + 500], [1e6 + 1500, 1e6 + 500]).clipped(to: far)
        let expected: [[SIMD2<Float>]] = [[[1_000_000, 1_000_500], [1_001_000, 1_000_500]]]
        #expect(clipped.subpaths.map(\.points) == expected)
    }

    @Test("同じ点が続く (長さ 0 の辺を持つ) 線と相手も切れる")
    func repeatedPoints() {
        let clipped = polyline([[-50, 50], [50, 50], [50, 50], [150, 50]]).clipped(to: square)
        #expect(clipped.subpaths.map(\.points) == [[[0, 50], [50, 50], [100, 50]]])
        let doubled = closed([[0, 0], [0, 0], [100, 0], [100, 100], [0, 100], [0, 100]])
        let across = segment([-50, 50], [150, 50]).clipped(to: doubled)
        #expect(across.subpaths.map(\.points) == [[[0, 50], [100, 50]]])
    }

    /// 相手の頂点をちょうど通る線と、Float の数刻みだけ脇を通る線を種から作り、線を細かく刻んだ点を `contains` に
    /// 問った長さと比べる。刻みの粗さの分 (縁をまたぐ所ごとに 2 刻み) を許す。
    @Test("生成: 相手の頂点を通る・かすめる線の長さは、刻んだ点を contains に問った長さと合う")
    func linesThroughVerticesMatchTheSampledReference() {
        var random = RandomSource(seed: 3649)
        let shapes = [
            disc(0, 0, 50),
            closed((0..<7).map { i in
                let angle = 0.3 + Double(i) / 7 * 2 * .pi
                return SIMD2<Float>(Float(123.4 + 80 * cos(angle)), Float(-56.7 + 80 * sin(angle)))
            }),
        ]
        for shape in shapes {
            let vertices = shape.subpaths[0].points
            for _ in 0..<150 {
                var through = vertices[Int.random(in: 0..<vertices.count, using: &random)]
                let nudge = Int32.random(in: -3...3, using: &random)
                through.y = Float(bitPattern: UInt32(bitPattern: Int32(bitPattern: through.y.bitPattern) &+ nudge))
                let angle = Double.random(in: 0..<(2 * .pi), using: &random)
                let direction = SIMD2<Double>(cos(angle), sin(angle))
                let from = SIMD2<Float>(SIMD2<Double>(through) - direction * Double.random(in: 30...300, using: &random))
                let to = SIMD2<Float>(SIMD2<Double>(through) + direction * Double.random(in: 30...300, using: &random))
                let steps = 400
                let length = Double(simd_distance(from, to))
                var expected = 0.0
                var transitions = 0
                var previous: Bool?
                for step in 0..<steps {
                    let t = (Double(step) + 0.5) / Double(steps)
                    let point = SIMD2<Double>(from) + (SIMD2<Double>(to) - SIMD2<Double>(from)) * t
                    let inside = shape.contains(Vector2(Float(point.x), Float(point.y)))
                    if inside { expected += length / Double(steps) }
                    if let previous, previous != inside { transitions += 1 }
                    previous = inside
                }
                let allowed = length / Double(steps) * Double(2 * transitions + 2)
                let got = Double(segment(Vector2(from), Vector2(to)).clipped(to: shape).length)
                #expect(abs(got - expected) <= allowed, "from \(from) to \(to): \(got) / 刻んだ長さ \(expected)")
            }
        }
    }
}

/// 切った線と、道の破線を描いた画素 (#3649・#2432 の条件 2)。
@Suite(
    "線を形で切る clipped (画素)",
    .enabled(
        if: RenderDevice.isAvailable,
        "この世代のコマンド構造に対応した GPU が無い実行環境ではスキップする")
)
struct PathClippedPictureTests {
    private let black = LinearRGBA.linear(red: 0, green: 0, blue: 0)
    private let white = LinearRGBA.linear(red: 1, green: 1, blue: 1)

    private func picture(_ body: (Canvas) -> Void) throws -> DisplayImage {
        let canvas = try CanvasFixture.make(gpu: RenderDevice(), width: 220, height: 200)
        try canvas.draw {
            canvas.background(black)
            body(canvas)
        }
        return try canvas.target.encodeForDisplay()
    }

    private func red(_ image: DisplayImage, _ x: Int, _ y: Int) -> UInt8 {
        image.bytes[(y * image.width + x) * 4]
    }

    /// #2432 の条件 2: 道の破線は `strokeDash` のもとで `shape(path)` に引かせる。
    @Test("strokeDash(10, 10) のもとで createPath の線を描くと、x = 5 は塗られ x = 15 は下地のまま")
    func pathLineIsDashedByStrokeDash() throws {
        let image = try picture { canvas in
            canvas.noFill()
            canvas.stroke(white)
            canvas.strokeWeight(3)
            canvas.strokeDash(10, 10)
            let line = canvas.createPath {
                canvas.beginShape()
                canvas.vertex(0, 50)
                canvas.vertex(100, 50)
                canvas.endShape()
            }
            canvas.shape(line)
        }
        #expect(red(image, 5, 50) > 127, "x = 5: \(red(image, 5, 50))")
        #expect(red(image, 15, 50) < 8, "x = 15: \(red(image, 15, 50))")
    }

    /// 完了条件 3 の画素: 斜線を円の中だけに切って描くと、円の外に線が出ない。
    @Test("円で切った斜線は円の内側だけに引かれる")
    func hatchIsDrawnOnlyInside() throws {
        let hatch = Path(
            subpaths: stride(from: Float(-200), to: 400, by: 8).map { x in
                Path.Subpath(points: [[x, 0], [x + 200, 200]], isClosed: false, isCurveStep: [false, false])
            })
        let image = try picture { canvas in
            canvas.noFill()
            canvas.stroke(white)
            canvas.strokeWeight(2)
            canvas.shape(hatch.clipped(to: Path(Circle(center: [100, 100], radius: 50))))
        }
        var inside = 0
        var outside = 0
        for y in 0..<image.height {
            for x in 0..<image.width where red(image, x, y) > 127 {
                let distance = ((Float(x) + 0.5 - 100) * (Float(x) + 0.5 - 100) + (Float(y) + 0.5 - 100) * (Float(y) + 0.5 - 100))
                    .squareRoot()
                if distance <= 52 { inside += 1 } else { outside += 1 }
            }
        }
        #expect(inside > 500, "内側 \(inside)")
        #expect(outside == 0, "外側 \(outside)")
    }
}
