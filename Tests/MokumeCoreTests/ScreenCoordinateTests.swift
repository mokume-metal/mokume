// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation
import Testing
import simd

@testable import MokumeCore

/// 面の座標と空間の座標を行き来する道の検査 (#314)。GPU を要する。
///
/// 前向きは**書き出した絵の画素**と突き合わせる。行列どうしを比べても「実際に描かれる
/// 場所を返しているか」は分からず、投影や半画素のずらしを片方だけ間違えたときに
/// 両方とも同じだけ間違ってしまうためである。
@Suite(
    "面と空間の座標",
    .enabled(
        if: RenderDevice.isAvailable,
        "この世代のコマンド構造に対応した GPU が無い実行環境ではスキップする")
)
struct ScreenCoordinateTests {
    private let black = LinearRGBA.linear(red: 0, green: 0, blue: 0)
    private let red = LinearRGBA.display(red: 1, green: 0, blue: 0)

    private func makeCanvas(width: Int = 256, height: Int = 256) throws -> Canvas {
        let gpu = try RenderDevice()
        let target = try RenderTarget(gpu: gpu, width: width, height: height)
        return try Canvas(target: target, gpu: gpu)
    }

    /// 塗られた画素の重心。**位置が絵に出ているか**を数で言うための物差し
    /// (``CameraTests`` と同じ測り方)。
    private func centroid(of image: DisplayImage) -> (x: Float, y: Float)? {
        var sumX: Float = 0
        var sumY: Float = 0
        var count = 0
        for y in 0..<image.height {
            for x in 0..<image.width where image[x, y].red > 40 {
                sumX += Float(x)
                sumY += Float(y)
                count += 1
            }
        }
        guard count > 0 else { return nil }
        return (sumX / Float(count), sumY / Float(count))
    }

    /// 印を 1 つ置いて、その中心が**実際に出た場所**と、`screenX` / `screenY` が言う
    /// 場所を比べる。置き方は呼ぶ側が渡す。
    ///
    /// **印は球にする。** 面や箱だと、傾いた置き方のとき近い側が大きく写り、塗られた
    /// 画素の重心が中心の像から近い側へ寄る — 実装が正しくても半画素を超えてずれるので、
    /// 物差しとして使えない。球は回しても形が変わらないので、そのずれが出ない
    /// (透視で残るのは半径と距離の比の 2 乗ぶんで、この置き方では 0.1 画素に満たない)。
    private func expectCenterMatchesPixels(
        of canvas: Canvas, _ comment: Comment, radius: Float = 12,
        sourceLocation: SourceLocation = #_sourceLocation,
        place: () -> Void
    ) throws {
        var told = SIMD2<Float>.zero
        try canvas.draw {
            canvas.background(black)
            canvas.fill(red)
            canvas.push()
            place()
            canvas.sphere(radius)
            told = SIMD2(canvas.screenX(0, 0, 0), canvas.screenY(0, 0, 0))
            canvas.pop()
        }

        // 面の座標の整数は**画素の中心**に乗る (``Canvas/makeProjection`` の半画素の
        // ずらし)。だから画素の番号の平均は、そのまま面の座標として比べられる。
        // 許す幅は半画素より狭く取る — そのずらしを落とした実装をここで捕まえるため
        let drawn = try #require(
            centroid(of: canvas.target.encodeForDisplay()), comment, sourceLocation: sourceLocation)
        #expect(abs(drawn.x - told.x) < 0.4, comment, sourceLocation: sourceLocation)
        #expect(abs(drawn.y - told.y) < 0.4, comment, sourceLocation: sourceLocation)
    }

    // MARK: - 前向き (空間 → 画面)

    @Test("奥行きを持つ点の面の上の位置が、実際に描かれた画素と一致する")
    func forwardMatchesDrawnPixels() throws {
        let canvas = try makeCanvas()
        try expectCenterMatchesPixels(of: canvas, "既定の視点で、置いた場所とずれている") {
            canvas.translate(80, 176, -120)
        }
    }

    @Test("変換を積んだ状態でも、面の上の位置が実際の画素と一致する")
    func forwardMatchesDrawnPixelsWithStackedTransforms() throws {
        let canvas = try makeCanvas()
        try expectCenterMatchesPixels(of: canvas, "積んだ変換のどれかが読み落とされている") {
            canvas.translate(60, 80, 40)
            canvas.rotateY(0.6)
            canvas.rotateX(-0.3)
            canvas.scale(1.5, 1.5, 1.5)
            canvas.translate(24, 8, 0)
        }
    }

    @Test("視点を変えた状態でも、面の上の位置が実際の画素と一致する")
    func forwardMatchesDrawnPixelsFromAnotherCamera() throws {
        let canvas = try makeCanvas()
        // 遠くから見るので、絵に出る大きさが残るよう印を大きく取る
        try expectCenterMatchesPixels(
            of: canvas, "斜めから見た視点が読まれていない", radius: 30
        ) {
            canvas.camera(360, -80, 400, 128, 128, 0, 0, 1, 0)
            canvas.translate(100, 140, -60)
        }
    }

    @Test("平行投影でも、面の上の位置が実際の画素と一致する")
    func forwardMatchesDrawnPixelsInOrthographic() throws {
        let canvas = try makeCanvas()
        try expectCenterMatchesPixels(of: canvas, "平行投影の範囲の取り方が読まれていない") {
            canvas.ortho()
            canvas.translate(90, 160, -280)
        }
    }

    @Test("奥行きの値は、手前ほど小さい")
    func depthGrowsWithDistance() throws {
        let canvas = try makeCanvas()
        try canvas.draw {
            let near = canvas.screenZ(128, 128, 120)
            let far = canvas.screenZ(128, 128, -200)
            #expect(near < far)
            #expect(near > 0 && far < 1)
        }
    }

    // MARK: - 平面の形と食い違わない

    @Test("奥行き 0 の点は、奥行きを渡さない形と同じ場所を指す")
    func depthZeroMatchesTheFlatForm() throws {
        let canvas = try makeCanvas()
        try canvas.draw {
            canvas.translate(20, 10)
            canvas.scale(2, 3)
            // ADR-0021 決定 1 の「奥行き 0 の面は平面の図形と重なる」が、
            // 座標を引く道でも成り立つ
            #expect(abs(canvas.screenX(5, 5, 0) - canvas.screenX(5, 5)) < 0.01)
            #expect(abs(canvas.screenY(5, 5, 0) - canvas.screenY(5, 5)) < 0.01)
        }
    }

    @Test("奥行きを渡さない形は、視点を変えても値が変わらない")
    func flatFormIgnoresTheCamera() throws {
        let canvas = try makeCanvas()
        try canvas.draw {
            canvas.translate(20, 10)
            let before = SIMD2(canvas.screenX(5, 5), canvas.screenY(5, 5))
            canvas.camera(360, -80, 400, 128, 128, 0, 0, 1, 0)
            canvas.ortho()
            #expect(canvas.screenX(5, 5) == before.x)
            #expect(canvas.screenY(5, 5) == before.y)
        }
    }

    // MARK: - 後ろ向き (画面 → 空間)

    @Test("面の位置と奥行きから戻すと、元の点へ帰る")
    func roundTripReturnsTheOriginalPoint() throws {
        let canvas = try makeCanvas()
        let points: [SIMD3<Float>] = [
            SIMD3(128, 128, 0), SIMD3(20, 200, 80), SIMD3(240, 40, -180),
        ]

        /// 置き方を 1 つ試す。前向きで面へ落とし、後ろ向きで戻して元と比べる。
        func expectRoundTrip(_ comment: Comment, setUp: () -> Void) throws {
            try canvas.draw {
                canvas.push()
                setUp()
                for point in points {
                    let told = SIMD3(
                        canvas.screenX(point.x, point.y, point.z),
                        canvas.screenY(point.x, point.y, point.z),
                        canvas.screenZ(point.x, point.y, point.z))
                    let back = canvas.spacePosition(
                        screenX: told.x, screenY: told.y, depth: told.z)
                    #expect(length(back - point) < 0.05, comment)
                }
                canvas.pop()
            }
        }

        try expectRoundTrip("既定の視点で往復が閉じない") {}
        try expectRoundTrip("平行投影で往復が閉じない") { canvas.ortho() }
        try expectRoundTrip("視点を変えると往復が閉じない") {
            canvas.camera(360, -80, 400, 128, 128, 0, 0, 1, 0)
        }
        try expectRoundTrip("変換を積むと往復が閉じない") {
            canvas.translate(60, 80, 40)
            canvas.rotateY(0.6)
            canvas.scale(1.5, 1.5, 1.5)
        }
        try expectRoundTrip("平行投影と変換を重ねると往復が閉じない") {
            canvas.ortho()
            canvas.translate(60, 80, 40)
            canvas.rotateX(0.4)
        }
    }

    @Test("戻した点は、いまの変換の中の座標で返る")
    func backwardReturnsCoordinatesInsideTheCurrentTransform() throws {
        let canvas = try makeCanvas()
        try canvas.draw {
            let told = SIMD3(
                canvas.screenX(128, 128, 0), canvas.screenY(128, 128, 0),
                canvas.screenZ(128, 128, 0))
            canvas.push()
            canvas.translate(128, 128, 0)
            // 変換の中では、同じ面の位置が変換の原点 (0, 0, 0) として返る
            let back = canvas.spacePosition(screenX: told.x, screenY: told.y, depth: told.z)
            #expect(length(back) < 0.05)
            canvas.pop()
        }
    }

    // MARK: - 落ちない (ADR-0020 決定 5)

    @Test("潰れた変換の下でも落ちず、空が返る")
    func collapsedTransformReturnsEmpty() throws {
        let canvas = try makeCanvas()
        try canvas.draw {
            canvas.scale(0, 0)
            #expect(canvas.spacePosition(screenX: 10, screenY: 20, depth: 0.5) == .zero)
        }
    }

    @Test("数として置けない値を渡しても落ちず、空が返る")
    func unusableNumbersReturnEmpty() throws {
        let canvas = try makeCanvas()
        try canvas.draw {
            #expect(canvas.screenX(.nan, 0, 0) == 0)
            #expect(canvas.screenY(0, .infinity, 0) == 0)
            #expect(canvas.screenZ(0, 0, .nan) == 0)
            #expect(canvas.spacePosition(screenX: .nan, screenY: 0, depth: 0) == .zero)
        }
    }

    @Test("数としては置けるが行列で溢れる値でも落ちず、空が返る")
    func overflowingNumbersReturnEmpty() throws {
        // 入力そのものは有限なので入口では見分けられない。行列を通した先で溢れる
        let canvas = try makeCanvas()
        try canvas.draw {
            #expect(canvas.screenX(.greatestFiniteMagnitude, 0, 0) == 0)
            #expect(canvas.screenY(0, .greatestFiniteMagnitude, 0) == 0)
        }
    }
}

/// 走っていないときの読み取り。**GPU を要さない** — 面が無い状態を見るための検査だから。
@Suite("走っていないときの座標")
struct ScreenCoordinateWithoutRuntimeTests {

    private final class Silent: Sketch {
        init() {}
    }

    @Test("走っていないときに座標を読んでも落ちず、空が返る")
    func readingCoordinatesWhileNothingRunsDoesNotStop() {
        // 初期化の中や後片付けの後から呼ばれうる。読み取りは決して落ちない
        // (ADR-0020 決定 5)
        #expect(runningSketch == nil)
        let sketch = Silent()
        #expect(sketch.screenX(10, 20) == 0)
        #expect(sketch.screenY(10, 20) == 0)
        #expect(sketch.screenX(10, 20, 30) == 0)
        #expect(sketch.screenY(10, 20, 30) == 0)
        #expect(sketch.screenZ(10, 20, 30) == 0)
        #expect(sketch.spacePosition(screenX: 10, screenY: 20, depth: 0.5) == .zero)
    }
}
