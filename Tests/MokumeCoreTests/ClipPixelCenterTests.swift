// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Testing

@testable import MokumeCore

/// **切り抜きは、画素の中心が矩形の内 (縁の上を含む) にある画素を通す** ([#1641])。GPU を要する。
///
/// かつては矩形を覚える時点で出す画素の整数へ切り捨て (細かさ 1 で左右とも左へ寄る)、細かさ
/// 1 未満では描く画素へ写すときにさらに外向きへ丸めていた (矩形の外の画素まで満濃度で描く)。
/// 細かさを変えても切り抜く場所が揃うことは ``DensityInvarianceTests`` の切り抜きの行が見る。
/// ここは Issue の完了条件の具体例を 1 つずつ確かめる。
///
/// [#1641]: https://github.com/mokume-metal/mokume/issues/1641
@Suite(
    "切り抜きは画素の中心の規則で丸める",
    .enabled(
        if: RenderDevice.isAvailable,
        "この世代のコマンド構造に対応した GPU が無い実行環境ではスキップする")
)
struct ClipPixelCenterTests {
    /// 出す大きさ 100×40 の面に、`body` を描いた描く面 (`Canvas.target`)。
    private func drawn(density: Float, _ body: (Canvas) -> Void) throws -> PixelBuffer {
        let gpu = try RenderDevice()
        let output = try RenderTarget(gpu: gpu, width: 100, height: 40)
        let canvas = try Canvas(output: output, gpu: gpu, pixelDensity: density, upscale: .spatial)
        try canvas.draw {
            canvas.background(0)
            canvas.noStroke()
            canvas.fill(255)
            body(canvas)
        }
        return try canvas.target.readPixels()
    }

    /// 真ん中の行で、白く塗られた描く画素の範囲 (両端を含む)。
    private func whiteColumns(_ pixels: PixelBuffer) -> ClosedRange<Int>? {
        let row = pixels.height / 2
        let whites = (0..<pixels.width).filter { pixels[$0, row].red > 0.5 }
        guard let first = whites.first, let last = whites.last else { return nil }
        #expect(whites.count == last - first + 1, "白い画素が途切れている: \(whites)")
        return first...last
    }

    @Test("細かさ 1 の clip(10.9, 0, 10, 40) は、画素 11…20 を通す (完了条件 1)")
    func fractionalLeftEdgeFollowsThePixelCenters() throws {
        let pixels = try drawn(density: 1) { canvas in
            canvas.clip(10.9, 0, 10, 40)
            canvas.rect(0, 0, 100, 40)
        }
        #expect(whiteColumns(pixels) == 11...20)
    }

    /// 覆う割合がちょうど半分の列 10・50 と行 10・50 も残る (#1647 の `clipFraction`)。
    @Test("同じ矩形で切り抜いた rect は、切り抜かない rect とバイト一致する (完了条件 2)")
    func clippingToTheSameRectangleRemovesNothing() throws {
        let size = 64
        func render(clipped: Bool) throws -> PixelBuffer {
            let gpu = try RenderDevice()
            let canvas = try CanvasFixture.make(gpu: gpu, width: size, height: size)
            try canvas.draw {
                canvas.background(0)
                canvas.noStroke()
                canvas.fill(255)
                if clipped { canvas.clip(10.5, 10.5, 40, 40) }
                canvas.rect(10.5, 10.5, 40, 40)
                if clipped { canvas.noClip() }
            }
            return try canvas.target.readPixels()
        }
        let clipped = try render(clipped: true)
        let plain = try render(clipped: false)
        #expect(clipped == plain)
        #expect(plain[10, 30].red > 0.4 && plain[50, 30].red > 0.4, "縁の列が半分の濃さで塗られている前提")
    }

    @Test("細かさ 0.5 の clip(51.5, 0, 20, 40) は、描く画素 26…35 を通す (完了条件 3)")
    func halfDensityMapsTheRectangleBeforeRounding() throws {
        let pixels = try drawn(density: 0.5) { canvas in
            canvas.clip(51.5, 0, 20, 40)
            canvas.rect(0, 0, 100, 40)
        }
        #expect(whiteColumns(pixels) == 26...35)
    }

    /// 台帳の `clip` を使う行 (整数の座標) が動かないことの、描く画素での裏付け。
    @Test(
        "整数の座標の切り抜きは、細かさ 1 と 0.5 でこれまでと同じ画素を通す (完了条件 5)",
        arguments: [
            (Float(1), Float(20), Float(30), 20...49),
            (Float(0.5), Float(51), Float(20), 25...35),
            (Float(0.5), Float(20), Float(30), 10...24),
        ])
    func integerRectanglesKeepTheirPixels(
        _ density: Float, _ x: Float, _ width: Float, _ expected: ClosedRange<Int>
    ) throws {
        let pixels = try drawn(density: density) { canvas in
            canvas.clip(x, 0, width, 40)
            canvas.rect(0, 0, 100, 40)
        }
        #expect(whiteColumns(pixels) == expected)
    }

    @Test("幅 0 の切り抜きは、縁の上の画素も通さない")
    func emptyRectanglePassesNothing() throws {
        let pixels = try drawn(density: 1) { canvas in
            canvas.clip(10.5, 0, 0, 40)
            canvas.rect(0, 0, 100, 40)
        }
        #expect(whiteColumns(pixels) == nil)
    }
}
