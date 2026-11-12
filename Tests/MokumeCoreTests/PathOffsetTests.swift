// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation
import Testing

@testable import MokumeCore

/// 道を太らせる・縮める `offset(by:)` (#3648)。値の問いは GPU が要らない。
@Suite("道を太らせる offset (値)")
nonisolated struct PathOffsetValueTests {
    private var circle: Path { Path(Circle(center: [0, 0], radius: 50)) }

    /// 角が (130, 60) と (130, 140) のレンズ。
    private var lens: Path {
        Path(Circle(center: [100, 100], radius: 50)).intersection(Path(Circle(center: [160, 100], radius: 50)))
    }

    /// 完了条件 1。
    @Test("太らせる: 半径 50 の円を 10 太らせると、輪郭は中心から 60 を通り、長さは 2π × 60 前後")
    func growing() {
        let grown = circle.offset(by: 10)
        #expect(grown.contains([59, 0]))
        #expect(!grown.contains([61, 0]))
        #expect(grown.contains([0, -59]) && !grown.contains([0, -61]))
        #expect(abs(grown.length - 2 * Float.pi * 60) < 0.5, "length = \(grown.length)")
        // 元の内側は全部残る
        #expect(grown.contains([0, 0]) && grown.contains([49, 0]))
    }

    /// 完了条件 2。
    @Test("縮める: 10 縮めると輪郭は中心から 40 を通り、半径以上縮めると空の道")
    func shrinking() {
        let shrunk = circle.offset(by: -10)
        #expect(shrunk.contains([39, 0]))
        #expect(!shrunk.contains([41, 0]))
        #expect(shrunk.contains([0, 0]))
        #expect(abs(shrunk.length - 2 * Float.pi * 40) < 0.5, "length = \(shrunk.length)")
        let gone = circle.offset(by: -60)
        #expect(gone.length == 0)
        #expect(gone.subpaths.isEmpty)
        #expect(!gone.contains([0, 0]))
    }

    /// 完了条件 3。角を尖らせる (miter) と、先端が角から 10 / sin(角の半分) まで伸びて (130, 48) が内側になる。
    @Test("角を丸める: レンズの角の外は、角から 10 の弧になり、尖って延びない")
    func cornersAreRounded() {
        let grown = lens.offset(by: 10)
        #expect(grown.contains([130, 52]), "角から 8")
        #expect(!grown.contains([130, 48]), "角から 12")
        #expect(grown.contains([130, 148]), "下の角から 8")
        #expect(!grown.contains([130, 152]), "下の角から 12")
    }

    /// 完了条件 5 の `offset` の行。
    @Test("境界: 0 と、数でない値・無限の値は元の道をそのまま返す。空の道は空のまま")
    func boundaries() {
        #expect(circle.offset(by: 0) == circle)
        #expect(lens.offset(by: 0) == lens)
        for bad: Float in [.nan, .infinity, -.infinity] {
            #expect(circle.offset(by: bad) == circle, "\(bad)")
        }
        #expect(Path().offset(by: 10).subpaths.isEmpty)
        #expect(Path().offset(by: -10).subpaths.isEmpty)
        // Int・Double もそのまま受ける
        #expect(circle.offset(by: 10).contains([59, 0]))
        #expect(circle.offset(by: Double(-10)).contains([39, 0]))
    }

    @Test("開いた部分道も閉じた形として太らせる")
    func openSubpathsAreClosed() {
        let open = Path(subpaths: [
            Path.Subpath(
                points: [[0, 0], [100, 0], [100, 100], [0, 100]], isClosed: false,
                isCurveStep: [false, false, false, false])
        ])
        let grown = open.offset(by: 5)
        // 閉じる辺 (0, 100)→(0, 0) の外側 5 以内も内側になる
        #expect(grown.contains([-4, 50]))
        #expect(!grown.contains([-6, 50]))
        #expect(grown.contains([50, 50]))
    }

    /// 太らせた輪郭は滑らかなので、点は刻みの印を持つ。縮めた輪郭が交わって尖る所 (新しくできた点) だけが角。
    @Test("刻みの印: 円を太らせた輪郭は全部が刻み、四角を縮めた角は角のまま")
    func curveStepMarks() {
        let grown = circle.offset(by: 10)
        #expect(grown.subpaths.allSatisfy { $0.isCurveStep.allSatisfy { $0 } })
        let square = Path(subpaths: [
            Path.Subpath(
                points: [[0, 0], [100, 0], [100, 100], [0, 100]], isClosed: true,
                isCurveStep: [false, false, false, false])
        ])
        let shrunk = square.offset(by: -10)
        #expect(shrunk.contains([11, 11]) && !shrunk.contains([9, 50]))
        // 縮めた四角の 4 隅 (10, 10)… は尖った角で、刻みでない
        var corners = 0
        for subpath in shrunk.subpaths {
            for (point, isStep) in zip(subpath.points, subpath.isCurveStep)
            where (abs(point.x - 10) < 0.01 || abs(point.x - 90) < 0.01)
                && (abs(point.y - 10) < 0.01 || abs(point.y - 90) < 0.01)
            {
                #expect(!isStep, "\(point)")
                corners += 1
            }
        }
        #expect(corners == 4)
    }
}

/// 太らせた道を描いた画素 (#3648)。
@Suite(
    "道を太らせる offset (画素)",
    .enabled(
        if: RenderDevice.isAvailable,
        "この世代のコマンド構造に対応した GPU が無い実行環境ではスキップする")
)
struct PathOffsetPictureTests {
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

    /// 完了条件 1 の「描くと、輪郭が中心から 60 の所を通る」(#2432 の条件 4)。
    @Test("半径 50 の円を 10 太らせて線で描くと、輪郭は中心から 60 を通り、50 には線が無い")
    func outlinePassesAtSixty() throws {
        let image = try picture { canvas in
            canvas.noFill()
            canvas.stroke(white)
            canvas.strokeWeight(2)
            canvas.shape(Path(Circle(center: [100, 100], radius: 50)).offset(by: 10))
        }
        // 画素の格子と線の縁の丸めで 1 画素ずれうるので、中心から 60 の前後 1 画素の内に線があるかで見る
        func lit(_ points: [(Int, Int)]) -> Bool { points.contains { red(image, $0.0, $0.1) > 200 } }
        #expect(lit([(159, 100), (160, 100), (161, 100)]) && lit([(39, 100), (40, 100), (41, 100)]), "中心から 60 (横)")
        #expect(lit([(100, 159), (100, 160), (100, 161)]) && lit([(100, 39), (100, 40), (100, 41)]), "中心から 60 (縦)")
        #expect(red(image, 150, 100) < 8 && red(image, 50, 100) < 8 && red(image, 100, 100) < 8, "中心から 50 と中心")
    }

    /// 完了条件への追加 (2026-11-10): 作例の破線の縁は `strokeDash` と `shape(path.offset(by:))` で描く。
    @Test("strokeDash のもとで shape に渡した offset の輪郭は破線で引かれる")
    func dashedOutlineThroughStrokeDash() throws {
        let path = Path(Circle(center: [100, 100], radius: 50)).offset(by: 10)
        func inked(_ image: DisplayImage) -> Int {
            stride(from: 0, to: image.bytes.count, by: 4).count { image.bytes[$0] > 127 }
        }
        let solid = try picture { canvas in
            canvas.noFill()
            canvas.stroke(white)
            canvas.strokeWeight(3)
            canvas.shape(path)
        }
        let dashed = try picture { canvas in
            canvas.noFill()
            canvas.stroke(white)
            canvas.strokeWeight(3)
            canvas.strokeDash(10, 10)
            canvas.shape(path)
        }
        let solidInk = inked(solid)
        let dashedInk = inked(dashed)
        // 長さ 10・間隔 10 なので、塗られる画素はおよそ半分になる (端の形の分だけ多い)
        #expect(dashedInk > solidInk * 3 / 10 && dashedInk < solidInk * 8 / 10, "実線 \(solidInk) / 破線 \(dashedInk)")
        // 輪郭 (半径 60) の上を 1 度ずつ回ると、塗られた所と抜けた所が両方ある
        var lit = 0
        var dark = 0
        for step in 0..<360 {
            let angle = Float(step) * .pi / 180
            let x = Int((100 + 60 * cos(angle)).rounded())
            let y = Int((100 + 60 * sin(angle)).rounded())
            if red(dashed, x, y) > 127 { lit += 1 } else { dark += 1 }
        }
        #expect(lit > 60 && dark > 60, "塗られた \(lit) / 抜けた \(dark)")
    }
}
