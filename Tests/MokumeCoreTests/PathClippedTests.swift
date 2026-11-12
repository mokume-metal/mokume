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
