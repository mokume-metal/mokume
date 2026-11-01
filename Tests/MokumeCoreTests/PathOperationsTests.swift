// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

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

    /// 境界から 1 以上離れた格子の点だけで、結果の内外が入力の集合演算と一致する。
    private func lattice(_ circles: [(Float, Float, Float)], check: (Vector2) -> Void) {
        for gx in stride(from: -20 as Float, through: 280, by: 7) {
            for gy in stride(from: -20 as Float, through: 220, by: 7) {
                let farFromEveryRim = circles.allSatisfy { c in
                    let distance = ((gx - c.0) * (gx - c.0) + (gy - c.1) * (gy - c.1)).squareRoot()
                    return abs(distance - c.2) > 1
                }
                if farFromEveryRim { check([gx, gy]) }
            }
        }
    }

    @Test("格子の点で、和・差・交わりの内外が入力の論理演算と一致する (3 つの円・向きの逆な円を含む)")
    func insideMatchesTheSetAlgebra() {
        let shapes: [(Float, Float, Float)] = [(100, 100, 50), (160, 100, 50), (130, 160, 40)]
        let paths = [disc(100, 100, 50), reversed(disc(160, 100, 50)), disc(130, 160, 40)]
        let union = Path.union(paths)
        let ab = paths[0].subtracting(paths[1])
        let ac = paths[0].intersection(paths[2])
        var inside = 0
        lattice(shapes) { p in
            let any = paths.contains { $0.contains(p) }
            #expect(union.contains(p) == any, "和 \(p)")
            if any { inside += 1 }
            #expect(ab.contains(p) == (paths[0].contains(p) && !paths[1].contains(p)), "差 \(p)")
            #expect(ac.contains(p) == (paths[0].contains(p) && paths[2].contains(p)), "交わり \(p)")
        }
        #expect(inside > 100, "内側の点を十分に調べている: \(inside)")
    }

    @Test("半径 50 の円 6 つと 100 個の和も、内外が入力の論理演算と一致する")
    func manyCircles() {
        var paths: [Path] = []
        var shapes: [(Float, Float, Float)] = []
        for index in 0..<6 {
            let angle = Float(index) / 6 * 2 * .pi
            let x = 130 + 40 * cos(angle)
            let y = 100 + 40 * sin(angle)
            paths.append(disc(x, y, 50))
            shapes.append((x, y, 50))
        }
        let union = Path.union(paths)
        lattice(shapes) { p in
            #expect(union.contains(p) == paths.contains { $0.contains(p) }, "\(p)")
        }
    }

    // MARK: - 刻みの印

    @Test("入力の頂点と同じ座標の点は刻みの印を引き継ぎ、交点だけが角になる")
    func curveStepMarksSurvive() {
        let union = Path.union([a, b])
        let corners = union.subpaths.flatMap { zip($0.points, $0.isCurveStep) }.filter { !$0.1 }
        #expect(corners.count == 2, "交点の 2 つだけが角: \(corners.count)")
        for (point, _) in corners {
            #expect(abs(point.x - 130) < 0.01, "交点は円の中心の中間にある: \(point)")
        }
        let total = union.subpaths.reduce(0) { $0 + $1.points.count }
        #expect(total > 100)

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
