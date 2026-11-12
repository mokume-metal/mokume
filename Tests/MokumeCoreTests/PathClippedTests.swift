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
