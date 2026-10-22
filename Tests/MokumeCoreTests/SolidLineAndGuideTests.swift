// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Testing
import simd

@testable import MokumeCore

/// 3 次元の `line`・`point` と、目印の格子と軸 (`debugMode()`) の絵 ([#2462])。GPU を要する。
///
/// 3 次元の `line`・`point` は `beginShape(.lines)` / `beginShape(.points)` と同じ道を通る約束
/// (ADR-0021 決定 5) なので、**同じ点を頂点で並べた絵と画素で比べる**。比べる絵が背景だけなら
/// 何も見ていないので、背景と違うことも見る。
///
/// 目印は、軸の先を ``Canvas/screenX(_:_:_:)``・``Canvas/screenY(_:_:_:)`` で面の座標へ写し、
/// その画素の色が軸の色かを見る。先そのものは端の形 (丸) の縁にかかるので、先から少し戻った所
/// (軸の長さの 9 割) を見る。
///
/// [#2462]: https://github.com/mokume-metal/mokume/issues/2462
@Suite(
    "立体の線と点・目印の格子と軸",
    .enabled(
        if: RenderDevice.isAvailable,
        "この世代のコマンド構造に対応した GPU が無い実行環境ではスキップする")
)
struct SolidLineAndGuideTests {
    private static let size = 200

    /// 面の中心の上手前から斜めに見下ろす視点 (完了条件 1 の視点)。**目を横へもずらす** — 真正面の
    /// 上からだと、下へ伸びる y の軸と手前へ伸びる z の軸が画面で同じ縦の線に重なり、手前の z が y を隠す。
    private static func lookDown(_ canvas: Canvas) {
        canvas.camera(170, -60, 220, 100, 100, 0, 0, 1, 0)
    }

    private static let black = Color.linear(red: 0, green: 0, blue: 0)

    /// 見下ろす視点で、背景を塗ってから `scene` を描いた絵。
    private func picture(_ scene: (Canvas) -> Void) throws -> DisplayImage {
        let canvas = try CanvasFixture.make(gpu: try RenderDevice(), width: Self.size, height: Self.size)
        try canvas.draw {
            canvas.background(Self.black)
            Self.lookDown(canvas)
            canvas.stroke(.display(red: 1, green: 0.7, blue: 0.35))
            canvas.strokeWeight(6)
            scene(canvas)
        }
        return try canvas.target.encodeForDisplay()
    }

    // MARK: - 3 次元の line・point (完了条件 1〜3)

    @Test("6 つの数の line は、同じ 2 点を beginShape(.lines) で引いた絵と画素が一致する")
    func solidLineMatchesVertices() throws {
        let line = try picture { $0.line(100, 100, 0, 100, 100, -200) }
        let vertices = try picture { canvas in
            canvas.beginShape(.lines)
            canvas.vertex(100, 100, 0)
            canvas.vertex(100, 100, -200)
            canvas.endShape()
        }
        let blank = try picture { _ in }
        #expect(line != blank, "6 つの数の line が何も描いていない")
        #expect(line == vertices)
    }

    @Test("3 つの数の point は、同じ点を beginShape(.points) で置いた絵と画素が一致する")
    func solidPointMatchesVertices() throws {
        let point = try picture { $0.point(100, 100, -50) }
        let vertices = try picture { canvas in
            canvas.beginShape(.points)
            canvas.vertex(100, 100, -50)
            canvas.endShape()
        }
        let blank = try picture { _ in }
        #expect(point != blank, "3 つの数の point が何も描いていない")
        #expect(point == vertices)
    }

    /// 受け口は `some ScalarConvertible` で、`Int`・`Double` の変数をそのまま渡せる (完了条件 2 の追記)。
    /// 組み上がることそのものが検査で、絵は `Float` で渡したものと同じになる。
    @Test("Int・Double の変数をそのまま渡せ、Float で渡した絵と同じになる")
    func takesAnyScalar() throws {
        let floats = try picture { canvas in
            canvas.line(Float(100), Float(100), Float(0), Float(100), Float(100), Float(-200))
            canvas.point(Float(60), Float(100), Float(-50))
        }
        let mixed = try picture { canvas in
            let z = 0.0
            let depth = -50
            canvas.line(100, 100, z, 100, 100, -200)
            canvas.point(60, 100, depth)
        }
        #expect(mixed == floats)
    }

    /// 4 つの数の `line` と 2 つの数の `point` は平面の図形のままで、視点を通らない (完了条件 3)。
    /// 見下ろしても、視点を当てない絵と同じになる。
    @Test("4 つの数の line・2 つの数の point は、視点を動かしても絵が変わらない")
    func flatLineAndPointIgnoreTheCamera() throws {
        func flat(lookingDown: Bool) throws -> DisplayImage {
            let canvas = try CanvasFixture.make(gpu: try RenderDevice(), width: Self.size, height: Self.size)
            try canvas.draw {
                canvas.background(Self.black)
                if lookingDown { Self.lookDown(canvas) }
                canvas.stroke(.display(red: 1, green: 0.7, blue: 0.35))
                canvas.strokeWeight(6)
                canvas.line(40, 40, 160, 120)
                canvas.point(60, 150)
            }
            return try canvas.target.encodeForDisplay()
        }
        #expect(try flat(lookingDown: true) == flat(lookingDown: false))
    }

    /// 開いたままの形の途中で 3 次元の `line` を書いても、開いた形を捨てない (2 次元の `line` と揃える)。
    @Test("開いた形の途中で書いても、その形を捨てずに続けられる")
    func keepsAnOpenShape() throws {
        let canvas = try CanvasFixture.make(gpu: try RenderDevice(), width: Self.size, height: Self.size)
        var left = SIMD2<Float>.zero
        var right = SIMD2<Float>.zero
        try canvas.draw {
            canvas.background(Self.black)
            Self.lookDown(canvas)
            canvas.stroke(.linear(red: 1, green: 1, blue: 1))
            canvas.strokeWeight(6)
            canvas.beginShape(.lines)
            canvas.vertex(60, 100, 0)
            canvas.line(140, 100, 0, 140, 100, -200)
            canvas.vertex(60, 100, -200)
            canvas.endShape()
            left = SIMD2(canvas.screenX(60, 100, -100), canvas.screenY(60, 100, -100))
            right = SIMD2(canvas.screenX(140, 100, -100), canvas.screenY(140, 100, -100))
        }
        #expect(!canvas.warnings.hasWarned(.shapeBegunWhileOpen), "3 次元の line が開いた形を捨てた")
        let image = try canvas.target.encodeForDisplay()
        // 開いた形の 2 点を結ぶ線 (左) も、間に書いた line (右) も描かれている
        #expect(image[Int(left.x), Int(left.y)].red > 128, "開いた形の線が描かれていない")
        #expect(image[Int(right.x), Int(right.y)].red > 128, "間に書いた line が描かれていない")
    }

    // MARK: - 目印の格子と軸 (完了条件 4・5)

    /// 目印の絵と、見下ろす視点での中心と 3 本の軸の先 (の 9 割) の面の座標。
    private struct Guides {
        let image: DisplayImage
        let center: SIMD2<Float>
        let tips: [(axis: String, at: SIMD2<Float>)]
        /// 格子の中心線の -x の側で、格子の線と交わらない点。
        let gridSample: SIMD2<Float>

        func pixel(_ at: SIMD2<Float>) -> (red: UInt8, green: UInt8, blue: UInt8, alpha: UInt8) {
            image[Int(at.x), Int(at.y)]
        }

        func brightest(around at: SIMD2<Float>) -> (red: UInt8, green: UInt8, blue: UInt8, alpha: UInt8) {
            var best = pixel(at)
            for dy in -1...1 {
                for dx in -1...1 {
                    let candidate = image[Int(at.x) + dx, Int(at.y) + dy]
                    if Int(candidate.red) + Int(candidate.green) + Int(candidate.blue)
                        > Int(best.red) + Int(best.green) + Int(best.blue)
                    {
                        best = candidate
                    }
                }
            }
            return best
        }
    }

    private func guides(_ write: (Canvas) -> Void) throws -> Guides {
        let canvas = try CanvasFixture.make(gpu: try RenderDevice(), width: Self.size, height: Self.size)
        var center = SIMD2<Float>.zero
        var tips: [(String, SIMD2<Float>)] = []
        var gridSample = SIMD2<Float>.zero
        try canvas.draw {
            canvas.background(Self.black)
            Self.lookDown(canvas)
            write(canvas)
            let origin = canvas.debugGuideCenter
            let reach = canvas.debugAxisLength * 0.9
            center = SIMD2(canvas.screenX(origin.x, origin.y, origin.z), canvas.screenY(origin.x, origin.y, origin.z))
            for (name, direction) in [("x", SIMD3<Float>(1, 0, 0)), ("y", SIMD3(0, 1, 0)), ("z", SIMD3(0, 0, 1))] {
                let tip = origin + direction * reach
                tips.append((name, SIMD2(canvas.screenX(tip.x, tip.y, tip.z), canvas.screenY(tip.x, tip.y, tip.z))))
            }
            // 格子の 1 目の 1.5 倍だけ -x へ (1 目と 2 目の線の間)
            let step = min(canvas.width, canvas.height) / Float(Canvas.DebugGuides.gridDivisions)
            let onGrid = origin - SIMD3(step * 1.5, 0, 0)
            gridSample = SIMD2(canvas.screenX(onGrid.x, onGrid.y, onGrid.z), canvas.screenY(onGrid.x, onGrid.y, onGrid.z))
        }
        return Guides(
            image: try canvas.target.encodeForDisplay(), center: center, tips: tips, gridSample: gridSample)
    }

    @Test("debugMode() で、面の中心から x が赤・y が緑・z が青の軸が出て、y は画面の下へ向かう")
    func axesShowTheirColours() throws {
        let shown = try guides { $0.debugMode() }
        for (axis, at) in shown.tips {
            let pixel = shown.pixel(at)
            let channels = [pixel.red, pixel.green, pixel.blue]
            let wanted = ["x": 0, "y": 1, "z": 2][axis]!
            // 出力は面の色空間で量子化されるので、純色の緑も (117, 251, 76) のように他の成分を持つ。
            // 見るのは、その軸の成分が際立って大きいこと
            #expect(channels[wanted] > 150, "\(axis) の軸の先 \(at) が軸の色でない: \(pixel)")
            for (index, value) in channels.enumerated() where index != wanted {
                #expect(Int(value) + 100 < Int(channels[wanted]), "\(axis) の軸の先 \(at) が軸の色でない: \(pixel)")
            }
        }
        let yTip = try #require(shown.tips.first { $0.axis == "y" }).at
        #expect(yTip.y > shown.center.y, "y の軸の先が中心より画面の下にない (縦軸が下向きに見えない)")
        // 格子も出ている。中心線の -x の側 (格子の線と交わらない所) は灰色
        // 1 画素の細い線なので、写した点のまわり 3×3 で最も明るい画素を見る
        let grid = shown.brightest(around: shown.gridSample)
        #expect(grid.red > 30 && grid.green > 30 && grid.blue > 30, "格子の中心線が出ていない: \(grid)")
        #expect(
            max(grid.red, grid.green, grid.blue) - min(grid.red, grid.green, grid.blue) < 12,
            "格子の線が灰色でない: \(grid)")
    }

    @Test("debugMode() を書かないフレームと、後に noDebugMode() を書いたフレームでは、軸の先が背景のまま")
    func guidesAreAbsentUnlessWrittenThisFrame() throws {
        let blank = try guides { _ in }
        let cancelled = try guides { canvas in
            canvas.debugMode()
            canvas.noDebugMode()
        }
        for (axis, at) in blank.tips {
            let background = blank.pixel(at)
            #expect(background.red < 10 && background.green < 10 && background.blue < 10, "\(axis): 書かないのに出ている")
            let pixel = cancelled.pixel(at)
            #expect(pixel == background, "\(axis): noDebugMode() を後に書いたのに出ている: \(pixel)")
        }
        #expect(cancelled.image == blank.image)
    }

    @Test("debugMode() を書いたフレームの次のフレームには、書かなければ出ない")
    func guidesDoNotCarryOver() throws {
        let canvas = try CanvasFixture.make(gpu: try RenderDevice(), width: Self.size, height: Self.size)
        try canvas.draw {
            canvas.background(Self.black)
            canvas.debugMode()
        }
        #expect(!canvas.drawsDebugGuides)
        try canvas.draw { canvas.background(Self.black) }
        let plain = try CanvasFixture.make(gpu: try RenderDevice(), width: Self.size, height: Self.size)
        try plain.draw { plain.background(Self.black) }
        #expect(try canvas.target.encodeForDisplay() == plain.target.encodeForDisplay())
    }

    /// 目印は変換・スタイルを使わず、使った後に利用者の値を書き換えない。
    @Test("目印は利用者の変換と線の色を使わず、書き換えもしない")
    func guidesKeepTheUsersStateApart() throws {
        let plain = try guides { $0.debugMode() }
        let canvas = try CanvasFixture.make(gpu: try RenderDevice(), width: Self.size, height: Self.size)
        let mine = Color.linear(red: 0.2, green: 0.9, blue: 0.9)
        try canvas.draw {
            canvas.background(Self.black)
            Self.lookDown(canvas)
            canvas.debugMode()
            canvas.translate(30, 0, 0)
            canvas.stroke(mine)
            canvas.strokeWeight(9)
        }
        #expect(try canvas.target.encodeForDisplay() == plain.image, "利用者の変換か線が目印に漏れた")
        #expect(canvas.style.stroke == mine)
        #expect(canvas.style.strokeWeight == 9)
    }
}
