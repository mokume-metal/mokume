// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Testing

@testable import MokumeCore

@Suite("窓の座標をキャンバスの座標へ写す")
struct SurfaceMappingTests {
    /// 960x540 のキャンバスを、縦横比の合う窓へ等倍で映したときの規則。帯は出ない。
    private let exact = SurfaceMapping(
        viewWidth: 960, viewHeight: 540,
        drawableWidth: 960, drawableHeight: 540,
        canvasWidth: 960, canvasHeight: 540)

    @Test("縦軸が反転する — 窓の左下は、キャンバスの左下 (y = 高さ) を指す")
    func flipsTheVerticalAxis() throws {
        let origin = try #require(exact.canvasPoint(x: 0, y: 0))
        #expect(origin.x == 0)
        #expect(origin.y == 540)

        let topLeft = try #require(exact.canvasPoint(x: 0, y: 540))
        #expect(topLeft.x == 0)
        #expect(topLeft.y == 0)
    }

    @Test("中央は中央へ写る")
    func centreMapsToCentre() throws {
        let point = try #require(exact.canvasPoint(x: 480, y: 270))
        #expect(point.x == 480)
        #expect(point.y == 270)
    }

    @Test("画面の倍率が上がっても、読める座標は変わらない")
    func retinaDoesNotChangeTheResult() throws {
        // 同じ大きさの窓を、倍率 2 の画面で映す。面の画素数だけが倍になる
        let retina = SurfaceMapping(
            viewWidth: 960, viewHeight: 540,
            drawableWidth: 1920, drawableHeight: 1080,
            canvasWidth: 960, canvasHeight: 540)
        let point = try #require(retina.canvasPoint(x: 300, y: 200))
        let same = try #require(exact.canvasPoint(x: 300, y: 200))
        #expect(point.x == same.x)
        #expect(point.y == same.y)
    }

    @Test("窓の大きさを変えても、読める座標は描く解像度の座標系のまま")
    func windowSizeDoesNotLeakIntoTheCoordinates() throws {
        // 描く解像度の半分で開いた窓 (既定)。縦横比は合っているので帯は出ない
        let half = SurfaceMapping(
            viewWidth: 480, viewHeight: 270,
            drawableWidth: 480, drawableHeight: 270,
            canvasWidth: 960, canvasHeight: 540)
        // 窓の中央は、窓の大きさによらずキャンバスの中央
        let centre = try #require(half.canvasPoint(x: 240, y: 135))
        #expect(centre.x == 480)
        #expect(centre.y == 270)
        // 右上の角も描く解像度で読める
        let corner = try #require(half.canvasPoint(x: 480, y: 270))
        #expect(corner.x == 960)
        #expect(corner.y == 0)
    }

    /// 16:9 のキャンバスを 2:1 の窓へ映す。左右に 100 画素ずつの帯が出る
    /// (`ViewportFitTests` の「面のほうが横長なら、左右に帯が出る」と同じ形)。
    private let banded = SurfaceMapping(
        viewWidth: 1800, viewHeight: 900,
        drawableWidth: 1800, drawableHeight: 900,
        canvasWidth: 1600, canvasHeight: 900)

    @Test("帯があっても、絵が収まった矩形の角がキャンバスの角へ写る")
    func bandsAreRemoved() throws {
        // 収まった矩形の左上の角 (窓の座標では x = 100・上端)
        let topLeft = try #require(banded.canvasPoint(x: 100, y: 900))
        #expect(abs(topLeft.x - 0) < 1e-3)
        #expect(abs(topLeft.y - 0) < 1e-3)

        // 右下の角
        let bottomRight = try #require(banded.canvasPoint(x: 1700, y: 0))
        #expect(abs(bottomRight.x - 1600) < 1e-3)
        #expect(abs(bottomRight.y - 900) < 1e-3)
    }

    @Test("帯の上は範囲外の値になる — 丸めない")
    func bandsReportOutOfRange() throws {
        // 左の帯の中 (x = 50 は収まった矩形の左端 100 より左)
        let left = try #require(banded.canvasPoint(x: 50, y: 450))
        #expect(left.x < 0)

        // 右の帯の中
        let right = try #require(banded.canvasPoint(x: 1750, y: 450))
        #expect(right.x > 1600)

        // 縦に帯が出る向きでも同じ
        let tall = SurfaceMapping(
            viewWidth: 900, viewHeight: 900,
            drawableWidth: 900, drawableHeight: 900,
            canvasWidth: 1600, canvasHeight: 900)
        let above = try #require(tall.canvasPoint(x: 450, y: 890))
        #expect(above.y < 0)
    }

    @Test("面の画素数が丸められていても、上下が同じだけずれる")
    func roundedDrawableSizeStaysSymmetric() throws {
        // 倍率 2 の画面で 400.5 点の窓を映すと、面の画素数は 801 ではなく 800 に
        // なりうる。**画面の倍率 (2) と実際の比 (800 ÷ 400.5) が食い違う**ので、
        // 反転を画素の空間で倍率のほうを使って行うと、上端が -0.5 へずれる
        let rounded = SurfaceMapping(
            viewWidth: 400.5, viewHeight: 400.5,
            drawableWidth: 800, drawableHeight: 800,
            canvasWidth: 400, canvasHeight: 400)
        let bottom = try #require(rounded.canvasPoint(x: 200.25, y: 0))
        let top = try #require(rounded.canvasPoint(x: 200.25, y: 400.5))
        // 下端が高さちょうど・上端が 0 — どちらへも寄らない
        #expect(abs(bottom.y - 400) < 1e-3)
        #expect(abs(top.y - 0) < 1e-3)
    }

    @Test("大きさが 0 のときは写さない")
    func degenerateSizesMapToNothing() {
        #expect(
            SurfaceMapping(
                viewWidth: 0, viewHeight: 540, drawableWidth: 960, drawableHeight: 540,
                canvasWidth: 960, canvasHeight: 540
            ).canvasPoint(x: 10, y: 10) == nil)
        #expect(
            SurfaceMapping(
                viewWidth: 960, viewHeight: 540, drawableWidth: 0, drawableHeight: 0,
                canvasWidth: 960, canvasHeight: 540
            ).canvasPoint(x: 10, y: 10) == nil)
        #expect(
            SurfaceMapping(
                viewWidth: 960, viewHeight: 540, drawableWidth: 960, drawableHeight: 540,
                canvasWidth: 0, canvasHeight: 0
            ).canvasPoint(x: 10, y: 10) == nil)
    }
}
