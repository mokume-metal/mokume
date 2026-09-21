// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation
import Testing
import simd

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
    private let black = LinearRGBA.linear(red: 0, green: 0, blue: 0)
    // 目印の色は作業空間の原色 (`.linear`) で書く。この検査の主題は色の入口ではなく、
    // 純色のまま 255 / 0 に出るので期待値をそのまま書ける (入口は ColorSurfaceTests が見る — #911)
    private let red = LinearRGBA.linear(red: 1, green: 0, blue: 0)
    private let green = LinearRGBA.linear(red: 0, green: 1, blue: 0)
    private let blue = LinearRGBA.linear(red: 0, green: 0, blue: 1)

    private func makeCanvas(width: Int = 64, height: Int = 64) throws -> Canvas {
        try CanvasFixture.make(gpu: RenderDevice(), width: width, height: height)
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
            // 塗りだけで比べるので、面にも矩形にも線を置かない
            solid.noStroke()
            solid.push()
            solid.translate(32, 32, 0)
            solid.plane(30, 20)
            solid.pop()
        }

        let flat = try makeCanvas()
        try flat.draw {
            flat.background(black)
            flat.fill(red)
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

    // MARK: - 塗り直し

    @Test("面を塗り直すと、それより前に置いた立体は出ない")
    func backgroundClearsSolidsPlacedBefore() throws {
        // 面全体を塗り直すのだから、下に隠れるものは平面も立体も残らない
        let canvas = try makeCanvas()
        try canvas.draw {
            canvas.noStroke()
            canvas.fill(red)
            canvas.push()
            canvas.translate(16, 32, 0)
            canvas.sphere(12)
            canvas.pop()

            canvas.background(black)

            canvas.fill(green)
            canvas.push()
            canvas.translate(48, 32, 0)
            canvas.sphere(12)
            canvas.pop()
        }

        let image = try pixels(of: canvas)
        #expect(image[16, 32] == (0, 0, 0, 255))
        #expect(image[48, 32] == (0, 255, 0, 255))
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
            canvas.ellipsoid(size, size, size)
            canvas.plane(size, size)
            canvas.cylinder(size, size)
            canvas.cone(size, size)
            canvas.torus(size, size)
            canvas.pop()
        }

        #expect(canvas.solidMeshesBuilt == 0)
        #expect(try pixels(of: canvas)[32, 32] == (0, 0, 0, 255))
    }

    // MARK: - 楕円体 (#849)

    @Test("楕円体を置いても、置き場所の変換は汚れない")
    func ellipsoidLeavesTheTransformAlone() throws {
        // **これが `push` / `scale` / `sphere` / `pop` との違いである。** あちらは
        // 変換そのものを動かすので、挟み忘れると後続まで伸びる。楕円体は形の側が
        // 半径を持つので、置いても変換は動かない
        let canvas = try makeCanvas()
        var before = matrix_identity_float4x4
        var after = matrix_identity_float4x4
        try canvas.draw {
            canvas.background(black)
            canvas.noStroke()
            canvas.translate(32, 32, 0)
            before = canvas.transform.matrix
            canvas.fill(red)
            canvas.ellipsoid(12, 6, 9)
            after = canvas.transform.matrix
        }
        #expect(before == after)
    }

    @Test("楕円体のあとに置いた立体は歪まない")
    func aSolidPlacedAfterAnEllipsoidIsNotScaled() throws {
        // 上の言明を**絵の側から**も見る。半径が後続へ漏れていれば、右の球が歪む
        func render(placingAnEllipsoid: Bool) throws -> DisplayImage {
            let canvas = try makeCanvas()
            try canvas.draw {
                canvas.background(black)
                canvas.noStroke()
                if placingAnEllipsoid {
                    canvas.fill(green)
                    canvas.push()
                    canvas.translate(16, 32, 0)
                    canvas.ellipsoid(6, 14, 6)
                    canvas.pop()
                }
                canvas.fill(red)
                canvas.push()
                canvas.translate(46, 32, 0)
                canvas.sphere(12)
                canvas.pop()
            }
            return try pixels(of: canvas)
        }

        let withEllipsoid = try render(placingAnEllipsoid: true)
        let without = try render(placingAnEllipsoid: false)
        // 楕円体を置いた左半分は当然違う。**右半分だけ**を突き合わせる
        for y in 0..<64 {
            for x in 32..<64 {
                #expect(withEllipsoid[x, y] == without[x, y], "(\(x), \(y)) で右の球が動いた")
            }
        }
    }

    @Test("楕円体は、push / scale / sphere / pop と同じ絵になる")
    func ellipsoidMatchesAScaledSphere() throws {
        // **光を当てるのが要点。** 塗り 1 色だと輪郭しか見ないので、面の向きの式を
        // 間違えても通ってしまう。光を当てて初めて、向きが絵に出る
        func render(_ body: (Canvas) -> Void) throws -> DisplayImage {
            let canvas = try makeCanvas()
            try canvas.draw {
                canvas.background(black)
                canvas.noStroke()
                canvas.ambientLight(.linear(red: 0.15, green: 0.15, blue: 0.15))
                canvas.directionalLight(
                    .linear(red: 1, green: 1, blue: 1), 0.6, -0.5, -0.6)
                canvas.fill(.linear(red: 0.9, green: 0.5, blue: 0.3))
                canvas.push()
                canvas.translate(32, 32, 0)
                canvas.rotateX(0.5)
                canvas.rotateY(0.4)
                body(canvas)
                canvas.pop()
            }
            return try pixels(of: canvas)
        }

        let mine = try render { $0.ellipsoid(20, 10, 14) }
        let scaled = try render {
            $0.push()
            $0.scale(20, 10, 14)
            $0.sphere(1)
            $0.pop()
        }

        // **ビット一致は求めない。** 点の位置はこちらが `方向 * 半径` を直に取るのに
        // 対し、あちらは半径 1 の点へ行列を掛ける。面の向きも、こちらは余因子を
        // 正規化し、あちらは逆転置 (`Transform.normalMatrix`) を通る。どちらも
        // 同じ値を指すが、丸めの順が違うので最下位ビットは揃わない
        var worst = 0
        var differing = 0
        for index in stride(from: 0, to: mine.bytes.count, by: 1) {
            let gap = abs(Int(mine.bytes[index]) - Int(scaled.bytes[index]))
            if gap > 0 { differing += 1 }
            worst = max(worst, gap)
        }
        #expect(worst <= 8, "画素の差が大きすぎる (最大 \(worst))")
        // 縁の 1 画素が両者で違う向きに丸まることはあるが、面の中まで違えば式が違う
        #expect(differing * 100 / mine.bytes.count <= 5, "違う画素が多すぎる")
    }

    // MARK: - 投入されなかった描き切り (#1183)

    /// **組み立ての後で投げた途中の描き切りを「このフレームで描き切った」と数えない。**
    /// 数えると次の描き切りが続きのフレームとして奥行きを読むが、このフレームでは一度も
    /// 消されていない — 読むのは前のフレームが残した奥行きで、奥の立体がそれに隠れる
    /// ([#1183])。
    ///
    /// 前のフレームは途中の描き切りで手前の奥行きを残し、次のフレームは塗り直さずに
    /// 最初の途中の描き切りを投げさせる (形の置き場を伸ばし、その取り直しの待ちで投げる)。
    ///
    /// [#1183]: https://github.com/mokume-metal/mokume/issues/1183
    @Test("組み立ての後で投げた途中の描き切りの次は、前のフレームの奥行きを読まない")
    func aMidFrameFlushThatThrowsDoesNotCountAsAPass() throws {
        let canvas = try makeCanvas()
        try canvas.draw {
            canvas.background(black)
            // 形の置き場を 1 度取らせる。面の外に置くので絵には出ない
            canvas.rect(1000, 1000, 1, 1)
            canvas.fill(red)
            canvas.push()
            canvas.translate(32, 32, 20)
            canvas.plane(30, 30)
            canvas.pop()
            // 手前の奥行きを残させる
            canvas.loadPixels()
        }

        try canvas.draw {
            for index in 0..<5000 { canvas.rect(1000 + index % 16, 1000, 1, 1) }
            canvas.gpu.failSettleForTesting = .timedOut(seconds: RenderDevice.waitLimitSeconds)
            canvas.loadPixels()
            canvas.gpu.failSettleForTesting = nil

            canvas.fill(green)
            canvas.push()
            canvas.translate(32, 32, -20)
            canvas.plane(30, 30)
            canvas.pop()
        }
        #expect(
            try pixels(of: canvas)[32, 32] == (0, 255, 0, 255),
            "消していない奥行きを読み、前のフレームの手前の面に隠れた")
    }
}
