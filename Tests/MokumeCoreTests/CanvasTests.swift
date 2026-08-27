// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation
import Testing

@testable import MokumeCore

/// 2D 描画の検査。GPU を要する。
///
/// 見るのは**書き出した絵の画素**で、内部の頂点ではない。頂点を数えても
/// 「指定した場所に指定した色で出たか」は分からない。
@Suite(
    "2D 描画",
    .enabled(
        if: RenderDevice.isAvailable,
        "この世代のコマンド構造に対応した GPU が無い実行環境ではスキップする")
)
struct CanvasTests {
    private let black = LinearRGBA.opaque(red: 0, green: 0, blue: 0)
    private let white = LinearRGBA.opaque(red: 1, green: 1, blue: 1)

    private func makeCanvas(width: Int = 64, height: Int = 64) throws -> Canvas {
        let gpu = try RenderDevice()
        let target = try RenderTarget(gpu: gpu, width: width, height: height)
        return try Canvas(target: target, gpu: gpu)
    }

    private func pixels(of canvas: Canvas) throws -> DisplayImage {
        try canvas.target.encodeForDisplay()
    }

    // MARK: - 背景

    @Test("背景は面全体を塗る")
    func backgroundCoversEverything() throws {
        let canvas = try makeCanvas(width: 8, height: 8)
        try canvas.draw { canvas.background(.display(red: 1, green: 0, blue: 0)) }

        let image = try pixels(of: canvas)
        for y in 0..<8 {
            for x in 0..<8 {
                #expect(image[x, y] == (255, 0, 0, 255))
            }
        }
    }

    @Test("背景はそれまでに積んだ図形を消す")
    func backgroundWipesShapesDrawnBefore() throws {
        let canvas = try makeCanvas(width: 8, height: 8)
        try canvas.draw {
            canvas.fill(white)
            canvas.rect(0, 0, 8, 8)
            canvas.background(black)
        }

        #expect(try pixels(of: canvas)[4, 4] == (0, 0, 0, 255))
    }

    // MARK: - 図形

    @Test("矩形は指定した場所に、指定した大きさで出る")
    func rectangleLandsWhereItWasAsked() throws {
        let canvas = try makeCanvas()
        try canvas.draw {
            canvas.background(black)
            canvas.fill(white)
            canvas.rect(10, 20, 4, 8)
        }

        let image = try pixels(of: canvas)
        // 内側の 4x8 が塗られている
        for y in 20..<28 {
            for x in 10..<14 {
                #expect(image[x, y].red == 255, "(\(x), \(y)) が塗られていない")
            }
        }
        // 1 画素外は塗られていない
        #expect(image[9, 24].red == 0)
        #expect(image[14, 24].red == 0)
        #expect(image[12, 19].red == 0)
        #expect(image[12, 28].red == 0)
    }

    @Test("円は中心が指定した場所で、直径ぶんの広がりを持つ")
    func circleIsCenteredWhereItWasAsked() throws {
        let canvas = try makeCanvas()
        try canvas.draw {
            canvas.background(black)
            canvas.fill(white)
            canvas.circle(32, 32, 20)
        }

        let image = try pixels(of: canvas)
        #expect(image[32, 32].red == 255)
        // 半径 10 の内側と外側
        #expect(image[32 + 8, 32].red == 255)
        #expect(image[32, 32 - 8].red == 255)
        #expect(image[32 + 12, 32].red == 0)
        #expect(image[32, 32 + 12].red == 0)
    }

    @Test("太さ 1 の線は、整数の座標では 1 画素に収まる")
    func hairlineCoversExactlyOneColumn() throws {
        // 座標の約束のうち、半画素のずらしが効いているかを見る唯一の検査。
        // ずらしが無いと、隣の列が塗られるか 2 列にまたがる。
        let canvas = try makeCanvas()
        try canvas.draw {
            canvas.background(black)
            canvas.stroke(white)
            canvas.strokeWeight(1)
            canvas.line(10, 0, 10, 64)
        }

        let image = try pixels(of: canvas)
        #expect(image[10, 32].red == 255, "指定した列が塗られていない")
        #expect(image[9, 32].red == 0, "左隣まで塗られている")
        #expect(image[11, 32].red == 0, "右隣まで塗られている")
    }

    @Test("線の太さは指定した画素数になる")
    func strokeWeightWidensTheLine() throws {
        let canvas = try makeCanvas()
        try canvas.draw {
            canvas.background(black)
            canvas.stroke(white)
            canvas.strokeWeight(4)
            canvas.line(20, 0, 20, 64)
        }

        let image = try pixels(of: canvas)
        let painted = (0..<64).filter { image[$0, 32].red == 255 }
        #expect(painted == [18, 19, 20, 21])
    }

    // MARK: - 変換

    @Test("平行移動は図形をずらす")
    func translateMovesShapes() throws {
        let canvas = try makeCanvas()
        try canvas.draw {
            canvas.background(black)
            canvas.fill(white)
            canvas.translate(10, 5)
            canvas.rect(0, 0, 4, 4)
        }

        let image = try pixels(of: canvas)
        #expect(image[10, 5].red == 255)
        #expect(image[13, 8].red == 255)
        #expect(image[0, 0].red == 0)
    }

    @Test("拡大は図形を伸ばす")
    func scaleStretchesShapes() throws {
        let canvas = try makeCanvas()
        try canvas.draw {
            canvas.background(black)
            canvas.fill(white)
            canvas.scale(4, 1)
            canvas.rect(2, 10, 2, 4)
        }

        let image = try pixels(of: canvas)
        // x は 4 倍されて 8…15、y は変わらず 10…13
        #expect(image[8, 11].red == 255)
        #expect(image[15, 11].red == 255)
        #expect(image[16, 11].red == 0)
        #expect(image[8, 14].red == 0)
    }

    @Test("積んだ変換へ戻せる")
    func pushAndPopRestoreTheTransform() throws {
        let canvas = try makeCanvas()
        try canvas.draw {
            canvas.background(black)
            canvas.fill(white)
            canvas.push()
            canvas.translate(30, 30)
            canvas.rect(0, 0, 4, 4)
            canvas.pop()
            // 戻したので、次の矩形は原点に出る
            canvas.rect(0, 0, 4, 4)
        }

        let image = try pixels(of: canvas)
        #expect(image[31, 31].red == 255)
        #expect(image[1, 1].red == 255)
    }

    @Test("積んでいないのに戻しても壊れない")
    func popWithoutPushIsHarmless() throws {
        let canvas = try makeCanvas(width: 8, height: 8)
        try canvas.draw {
            canvas.background(black)
            canvas.pop()
            canvas.fill(white)
            canvas.rect(0, 0, 8, 8)
        }
        #expect(try pixels(of: canvas)[4, 4].red == 255)
    }

    // MARK: - 色

    @Test("見た目で指定した色が、そのまま出る")
    func displayColorSurvivesTheRoundTrip() throws {
        // 入口で線形へ戻し、出口で同じ変換を掛けるので、往復すれば元の見た目に戻る
        // (ADR-0011 決定 3 の入口と出口が対になっていることの確認)。
        //
        // **ぴたりとは戻らない。** 途中の作業空間は半精度浮動小数なので、線形へ
        // 落として戻す間に最下位の桁が動く。8 bit にした後の許容を 1 段に取るのは
        // そのため — ここを 0 段にすると、精度の話でしか落ちない検査になる。
        let canvas = try makeCanvas(width: 4, height: 4)
        try canvas.draw {
            canvas.background(.display(red: 0.25, green: 0.5, blue: 0.75))
        }

        let pixel = try pixels(of: canvas)[0, 0]
        #expect(abs(Int(pixel.red) - 64) <= 1)
        #expect(abs(Int(pixel.green) - 128) <= 1)
        #expect(abs(Int(pixel.blue) - 191) <= 1)
        #expect(pixel.alpha == 255)
    }

    @Test("半透明の図形は下の色と混ざる")
    func translucentShapesBlendWithWhatIsBelow() throws {
        let canvas = try makeCanvas(width: 8, height: 8)
        try canvas.draw {
            canvas.background(black)
            canvas.fill(LinearRGBA(straightRed: 1, green: 1, blue: 1, alpha: 0.5))
            canvas.rect(0, 0, 8, 8)
        }

        // 線形で 0.5 の灰色 → 出力段を経て 188
        #expect(try pixels(of: canvas)[4, 4] == (188, 188, 188, 255))
    }
}
