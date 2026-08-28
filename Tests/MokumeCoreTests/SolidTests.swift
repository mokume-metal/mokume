// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation
import Testing

@testable import MokumeCore

/// 立体を置いたときに何が起きるかの検査。GPU を要する。
///
/// 見るのは**書き出した絵の画素**である。光がまだ無いので立体は塗り 1 色で出る —
/// つまり「そこに出たか」「どちらが手前か」は画素の色で判定できる。
@Suite(
    "立体",
    .enabled(
        if: RenderDevice.isAvailable,
        "この世代のコマンド構造に対応した GPU が無い実行環境ではスキップする")
)
struct SolidTests {
    private let black = LinearRGBA.opaque(red: 0, green: 0, blue: 0)
    private let red = LinearRGBA.display(red: 1, green: 0, blue: 0)
    private let green = LinearRGBA.display(red: 0, green: 1, blue: 0)
    private let blue = LinearRGBA.display(red: 0, green: 0, blue: 1)

    private func makeCanvas(width: Int = 64, height: Int = 64) throws -> Canvas {
        let gpu = try RenderDevice()
        let target = try RenderTarget(gpu: gpu, width: width, height: height)
        return try Canvas(target: target, gpu: gpu)
    }

    private func pixels(of canvas: Canvas) throws -> DisplayImage {
        try canvas.target.encodeForDisplay()
    }

    // MARK: - 平面との一致

    @Test("奥行き 0 に置いた面は、同じ座標に描いた矩形とぴったり重なる")
    func planeAtZeroDepthMatchesRect() throws {
        // ADR-0021 決定 1 の要件。既定の視点はこれが成り立つ距離に置いてある
        let solid = try makeCanvas()
        try solid.draw {
            solid.background(black)
            solid.fill(red)
            solid.push()
            solid.translate(32, 32, 0)
            solid.plane(30, 20)
            solid.pop()
        }

        let flat = try makeCanvas()
        try flat.draw {
            flat.background(black)
            flat.fill(red)
            // 立体にはまだ線が無いので、矩形の線も止めて塗りだけで比べる
            flat.noStroke()
            flat.rect(32 - 15, 32 - 10, 30, 20)
        }

        let fromSolid = try pixels(of: solid)
        let fromFlat = try pixels(of: flat)
        #expect(fromSolid.bytes == fromFlat.bytes)
    }

    // MARK: - 奥行き

    @Test("手前に置いた立体が、奥の立体を隠す")
    func nearerSolidHidesFartherOne() throws {
        let canvas = try makeCanvas()
        try canvas.draw {
            canvas.background(black)
            // 先に手前 (奥行きが正 = 見ている側) の赤、あとから奥の緑を置く。
            // **描いた順ではなく奥行きで決まる**ことを見る
            canvas.fill(red)
            canvas.push()
            canvas.translate(32, 32, 20)
            canvas.plane(30, 30)
            canvas.pop()

            canvas.fill(green)
            canvas.push()
            canvas.translate(32, 32, -20)
            canvas.plane(30, 30)
            canvas.pop()
        }

        let image = try pixels(of: canvas)
        #expect(image[32, 32] == (255, 0, 0, 255))
    }

    @Test("奥に置いた立体は、あとから置いても手前のものを隠さない")
    func fartherSolidStaysBehind() throws {
        let canvas = try makeCanvas()
        try canvas.draw {
            canvas.background(black)
            canvas.fill(green)
            canvas.push()
            canvas.translate(32, 32, -20)
            canvas.plane(30, 30)
            canvas.pop()

            canvas.fill(red)
            canvas.push()
            canvas.translate(32, 32, 20)
            canvas.plane(30, 30)
            canvas.pop()
        }

        #expect(try pixels(of: canvas)[32, 32] == (255, 0, 0, 255))
    }

    // MARK: - 平面と立体の重ね順

    @Test("あとから置いた平面は、立体の手前に出る")
    func flatDrawnAfterSolidComesInFront() throws {
        let canvas = try makeCanvas()
        try canvas.draw {
            canvas.background(black)
            canvas.fill(red)
            canvas.push()
            canvas.translate(32, 32, 0)
            canvas.box(40)
            canvas.pop()

            canvas.fill(blue)
            canvas.rect(24, 24, 16, 16)
        }

        #expect(try pixels(of: canvas)[32, 32] == (0, 0, 255, 255))
    }

    @Test("先に置いた平面は、あとから置いた立体に隠れる")
    func flatDrawnBeforeSolidGoesBehind() throws {
        let canvas = try makeCanvas()
        try canvas.draw {
            canvas.background(black)
            canvas.fill(blue)
            canvas.rect(24, 24, 16, 16)

            canvas.fill(red)
            canvas.push()
            canvas.translate(32, 32, 0)
            canvas.box(40)
            canvas.pop()
        }

        #expect(try pixels(of: canvas)[32, 32] == (255, 0, 0, 255))
    }

    @Test("平面は奥行きを書かないので、そのあとの立体の前後関係を汚さない")
    func flatDoesNotWriteDepth() throws {
        let canvas = try makeCanvas()
        try canvas.draw {
            canvas.background(black)
            // 手前に平面を敷いてから、奥・手前の順に立体を置く。平面が奥行きを
            // 書いていたら、あとの立体は 1 つも出ない
            canvas.fill(blue)
            canvas.rect(0, 0, 64, 64)

            canvas.fill(green)
            canvas.push()
            canvas.translate(32, 32, -20)
            canvas.plane(30, 30)
            canvas.pop()

            canvas.fill(red)
            canvas.push()
            canvas.translate(32, 32, 20)
            canvas.plane(30, 30)
            canvas.pop()
        }

        #expect(try pixels(of: canvas)[32, 32] == (255, 0, 0, 255))
    }

    // MARK: - 塗り

    @Test("塗りを止めているときは何も置かない")
    func noFillPlacesNothing() throws {
        let canvas = try makeCanvas()
        try canvas.draw {
            canvas.background(black)
            canvas.noFill()
            canvas.push()
            canvas.translate(32, 32, 0)
            canvas.box(40)
            canvas.pop()
        }

        #expect(try pixels(of: canvas)[32, 32] == (0, 0, 0, 255))
    }

    @Test("立体は置いた時点の塗りで描かれる")
    func solidUsesFillAtPlacementTime() throws {
        let canvas = try makeCanvas()
        try canvas.draw {
            canvas.background(black)
            canvas.fill(red)
            canvas.push()
            canvas.translate(20, 32, 0)
            canvas.plane(16, 16)
            canvas.pop()

            canvas.fill(green)
            canvas.push()
            canvas.translate(44, 32, 0)
            canvas.plane(16, 16)
            canvas.pop()
        }

        let image = try pixels(of: canvas)
        #expect(image[20, 32] == (255, 0, 0, 255))
        #expect(image[44, 32] == (0, 255, 0, 255))
    }

    // MARK: - 作り直さない

    @Test("同じ寸法の立体を毎フレーム置いても、組み立ては 1 回だけ")
    func sameSizeSolidIsBuiltOnce() throws {
        let canvas = try makeCanvas()
        for _ in 0..<5 {
            try canvas.draw {
                canvas.background(black)
                canvas.fill(red)
                canvas.push()
                canvas.translate(32, 32, 0)
                canvas.box(20)
                canvas.sphere(10)
                canvas.pop()
            }
        }

        // 箱と球で 2 つ。フレーム数によらない
        #expect(canvas.solidMeshesBuilt == 2)
    }

    @Test("寸法が変われば組み立て直す")
    func differentSizeBuildsAgain() throws {
        let canvas = try makeCanvas()
        try canvas.draw {
            canvas.fill(red)
            canvas.box(20)
            canvas.box(30)
        }

        #expect(canvas.solidMeshesBuilt == 2)
    }

    // MARK: - 置けない寸法

    @Test(
        "数でない寸法・無限・負の寸法では何も置かず、使い回しの表も汚さない",
        arguments: [Float.nan, .infinity, -1])
    func badSizesPlaceNothing(_ size: Float) throws {
        let canvas = try makeCanvas()
        try canvas.draw {
            canvas.background(black)
            canvas.fill(red)
            canvas.push()
            canvas.translate(32, 32, 0)
            canvas.box(size)
            canvas.sphere(size)
            canvas.plane(size, size)
            canvas.cylinder(size, size)
            canvas.cone(size, size)
            canvas.torus(size, size)
            canvas.pop()
        }

        #expect(canvas.solidMeshesBuilt == 0)
        #expect(try pixels(of: canvas)[32, 32] == (0, 0, 0, 255))
    }
}
