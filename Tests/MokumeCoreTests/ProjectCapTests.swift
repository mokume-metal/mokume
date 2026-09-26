// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation
import Testing

@testable import MokumeCore

/// `strokeCap(.project)` の端の形を、描く経路をまたいで比べる ([#1535])。GPU を要する。
///
/// 距離関数の経路 (`line`) は、端を**線の向きに沿って**太さの半分だけ延ばす。三角形の
/// 経路 (`beginShape(.lines)`・`shader()` を付けた `line`・開いた折れ線・立体の経路) も
/// 同じ形を出す — かつては端点に**形の座標の軸に沿った正方形**を置き、斜めの線では
/// 端が菱形に張り出していた。
///
/// ## 物差し
///
/// 面はどれも 160×160・黒地に白の線で、**線形の**赤 (= 被覆) を読む。「強い差」は 2 枚の
/// 赤の差が 0.55 を超える画素の数である — 片方の経路が縁を半分だけ塗り (約 0.5)、もう
/// 片方が 0 か 1 で塗る違いは縁の AA の差 ([ADR-0039] 決定 1) なので数えない。
///
/// [#1535]: https://github.com/mokume-metal/mokume/issues/1535
/// [ADR-0039]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0039-pixel-grid-and-edge-antialiasing.md
@Suite(
    "四角く出っ張らせる端の経路",
    .enabled(
        if: RenderDevice.isAvailable,
        "この世代のコマンド構造に対応した GPU が無い実行環境ではスキップする")
)
struct ProjectCapTests {
    private let black = LinearRGBA.linear(red: 0, green: 0, blue: 0)
    private let white = LinearRGBA.linear(red: 1, green: 1, blue: 1)

    /// 線形の赤を読める形にしたもの。
    private struct Picture {
        let pixels: PixelBuffer

        subscript(x: Int, y: Int) -> Float {
            Float(pixels.components[(y * pixels.width + x) * 4])
        }

        /// 赤の差が 0.55 を超える画素の数。
        func strongDifference(from other: Picture) -> Int {
            var count = 0
            for index in stride(from: 0, to: pixels.components.count, by: 4) {
                let difference = Float(pixels.components[index]) - Float(other.pixels.components[index])
                if abs(difference) > 0.55 { count += 1 }
            }
            return count
        }

        /// 塗られた (赤が 0.5 以上の) 画素の数。空振りを捕まえるため。
        var inked: Int {
            stride(from: 0, to: pixels.components.count, by: 4).filter {
                pixels.components[$0] >= 0.5
            }.count
        }
    }

    private func render(_ body: (Canvas) throws -> Void) throws -> Picture {
        let canvas = try CanvasFixture.make(gpu: RenderDevice(), width: 160, height: 160)
        var failure: (any Error)?
        try canvas.draw {
            canvas.background(black)
            canvas.noFill()
            canvas.stroke(white)
            canvas.strokeCap(.project)
            do { try body(canvas) } catch { failure = error }
        }
        if let failure { throw failure }
        return Picture(pixels: try canvas.target.readPixels())
    }

    /// 頂点の色をそのまま返す断片。付けると三角形の経路へ落ちる。
    private func passThrough(_ canvas: Canvas) throws -> Shader {
        try canvas.makeShader("float4 paint(Fragment in, Values values) { return in.color; }")
    }

    // MARK: - 斜めの線 (直す前は食い違う)

    @Test("頂点で並べた 45° の線も、端は線の向きに沿って太さの半分だけ延びる")
    func diagonalLinesFromVerticesProjectAlongTheLine() throws {
        let form = try render { canvas in
            canvas.strokeWeight(20)
            canvas.line(40, 40, 120, 120)
        }
        let vertices = try render { canvas in
            canvas.strokeWeight(20)
            canvas.beginShape(.lines)
            canvas.vertex(40, 40)
            canvas.vertex(120, 120)
            canvas.endShape()
        }
        #expect(vertices.inked > 0)
        #expect(form.strongDifference(from: vertices) == 0, "line と .lines で端の形が違う")
        // (31, 31) は線の向きに 12.7 はみ出した所 (延びるのは 10 まで)
        #expect(vertices[31, 31] < 0.5, "軸に沿った正方形の角が出ている")
        // (27, 40) は線の向きに沿って延びた端の角の内側
        #expect(vertices[27, 40] >= 0.5, "線の向きに沿った端の角が欠けている")
    }

    @Test("断片を付けて三角形で描いた斜めの線も、端の形は変わらない")
    func shadedDiagonalLineKeepsItsCap() throws {
        func line(on canvas: Canvas) {
            canvas.strokeWeight(16)
            canvas.line(30, 50, 130, 110)
        }
        let form = try render { line(on: $0) }
        let shaded = try render { canvas in
            canvas.shader(try passThrough(canvas))
            line(on: canvas)
        }
        #expect(shaded.inked > 0)
        #expect(form.strongDifference(from: shaded) == 0, "shader() を足しただけで端の形が変わる")
        // 始点 (30, 50) に軸に沿った正方形を置くと出る 2 つの角
        #expect(shaded[23, 43] < 0.5, "軸に沿った正方形の角 (23, 43) が出ている")
        #expect(shaded[23, 57] < 0.5, "軸に沿った正方形の角 (23, 57) が出ている")
    }

    @Test("開いた折れ線の端も、平面と立体のどちらでも線の向きに沿う", arguments: [false, true])
    func openPolylineEndsFollowTheLine(_ solid: Bool) throws {
        let picture = try render { canvas in
            canvas.strokeWeight(20)
            canvas.beginShape()
            for (x, y) in [(Float(40), Float(40)), (120, 120), (140, 60)] {
                if solid { canvas.vertex(x, y, 0) } else { canvas.vertex(x, y) }
            }
            canvas.endShape()
        }
        let route = solid ? "立体" : "平面"
        #expect(picture.inked > 0)
        #expect(picture[31, 31] < 0.5, "\(route): 始点の端に軸に沿った正方形の角が出ている")
        #expect(picture[27, 40] >= 0.5, "\(route): 始点の端の角が欠けている")
    }

    @Test("立体の経路で並べた 45° の線も、平面の line と同じ端になる")
    func solidLinesProjectAlongTheLine() throws {
        let form = try render { canvas in
            canvas.strokeWeight(20)
            canvas.line(40, 40, 120, 120)
        }
        let solid = try render { canvas in
            canvas.strokeWeight(20)
            canvas.beginShape(.lines)
            canvas.vertex(40, 40, 0)
            canvas.vertex(120, 120, 0)
            canvas.endShape()
        }
        #expect(solid.inked > 0)
        #expect(form.strongDifference(from: solid) == 0, "立体の .lines と line で端の形が違う")
    }

    // MARK: - 変わらないもの (直す前から緑)

    @Test("回して傾けた水平な線と、水平な線は、直す前から経路をまたいで一致する")
    func axisAlignedLinesAlreadyAgree() throws {
        func pair(_ place: (Canvas) -> Void, _ from: SIMD2<Float>, _ to: SIMD2<Float>) throws
            -> (Picture, Picture)
        {
            let form = try render { canvas in
                canvas.strokeWeight(20)
                place(canvas)
                canvas.line(from.x, from.y, to.x, to.y)
            }
            let vertices = try render { canvas in
                canvas.strokeWeight(20)
                place(canvas)
                canvas.beginShape(.lines)
                canvas.vertex(from.x, from.y)
                canvas.vertex(to.x, to.y)
                canvas.endShape()
            }
            return (form, vertices)
        }
        let (turnedForm, turnedVertices) = try pair(
            { $0.translate(80, 80); $0.rotate(Float.pi / 4) }, SIMD2(-56, 0), SIMD2(56, 0))
        #expect(turnedVertices.inked > 0)
        #expect(turnedForm.strongDifference(from: turnedVertices) == 0, "回した水平な線")
        let (flatForm, flatVertices) = try pair({ _ in }, SIMD2(40, 80), SIMD2(120, 80))
        #expect(flatForm.strongDifference(from: flatVertices) == 0, "水平な線")
    }

    @Test("端を切りっぱなしにした斜めの線は、断片の有無で形が変わらない")
    func squareCapIgnoresTheRoute() throws {
        func line(on canvas: Canvas) {
            canvas.strokeCap(.square)
            canvas.strokeWeight(16)
            canvas.line(30, 50, 130, 110)
        }
        let form = try render { line(on: $0) }
        let shaded = try render { canvas in
            canvas.shader(try passThrough(canvas))
            line(on: canvas)
        }
        #expect(shaded.inked > 0)
        #expect(form.strongDifference(from: shaded) == 0)
    }

    /// 点には向きが無いので、四角い端の点は軸に沿った正方形のまま (#1535 の範囲の外)。
    @Test(
        "四角い端の点は、軸に沿った正方形のまま",
        arguments: [StrokeCap.project, .square], [false, true])
    func squarePointsStayAxisAligned(_ cap: StrokeCap, _ shaded: Bool) throws {
        let picture = try render { canvas in
            if shaded { canvas.shader(try passThrough(canvas)) }
            canvas.strokeCap(cap)
            canvas.strokeWeight(20)
            canvas.point(80, 80)
        }
        // 正方形は中心から ±10。角の近く (中心から 9, 9) は塗られ、辺の外 (12, 0) は塗られない
        #expect(picture[71, 71] >= 0.5, "正方形の角が欠けている")
        #expect(picture[88, 88] >= 0.5, "正方形の角が欠けている")
        #expect(picture[92, 80] < 0.5, "正方形の外が塗られている")
    }
}
