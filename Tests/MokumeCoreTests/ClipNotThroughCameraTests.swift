// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Testing

@testable import MokumeCore

/// **視点を決めた下でも、`clip(x, y, w, h)`・`clip { }` は視点を通らず、面の上の範囲で切る** ([#3841]・ADR-0021 決定 1 の
/// 改訂 2026-11-07)。GPU を要する。
///
/// 2D の図形は視点 (`camera`・`perspective` など) と変換の奥行きを通る ([#3830]) が、切り抜きは通らない。
/// 呼んだ時点の変換の x・y を面の座標として読む (手本の P3D の `clip()` も画面の範囲を切る)。ここはその振る舞いを、
/// 斜めの視点 (#3830 の画素の表と同じ) の下で固定する。切り抜きを置いた後に `camera()` で視点を戻してから面全体を塗るので、
/// 白く残る画素は切り抜きの範囲そのものになる。切り抜きを視点に通すように変えると、範囲が斜めに写って外接の箱が動く。
///
/// [#3841]: https://github.com/mokume-metal/mokume/issues/3841
/// [#3830]: https://github.com/mokume-metal/mokume/issues/3830
@Suite(
    "視点の下の切り抜きは、視点を通らず面の上の範囲で切る",
    .enabled(
        if: RenderDevice.isAvailable,
        "この世代のコマンド構造に対応した GPU が無い実行環境ではスキップする")
)
struct ClipNotThroughCameraTests {
    /// 面 320×240 で、黒の下地に `body` が切り抜きを置いた後、視点を戻して面全体を白で塗ったもの。
    private func drawn(_ body: (Canvas) -> Void) throws -> PixelBuffer {
        let gpu = try RenderDevice()
        let canvas = try CanvasFixture.make(gpu: gpu, width: 320, height: 240)
        try canvas.draw {
            canvas.background(0)
            canvas.noStroke()
            canvas.fill(255)
            canvas.camera(400, 40, 300, 160, 120, 0, 0, 1, 0)
            body(canvas)
            canvas.camera()
            canvas.rect(0, 0, 320, 240)
        }
        return try canvas.target.readPixels()
    }

    /// 白い画素の外接 (両端を含む) と、白い画素の数。
    private func whiteBox(_ pixels: PixelBuffer) -> (x: ClosedRange<Int>, y: ClosedRange<Int>, count: Int)? {
        var (left, right, top, bottom, count) = (Int.max, Int.min, Int.max, Int.min, 0)
        for y in 0..<pixels.height {
            for x in 0..<pixels.width where pixels[x, y].red > 0.5 {
                left = min(left, x)
                right = max(right, x)
                top = min(top, y)
                bottom = max(bottom, y)
                count += 1
            }
        }
        guard left <= right else { return nil }
        return (left...right, top...bottom, count)
    }

    @Test("camera(...) の下の clip(100, 60, 60, 60) は、面の (100, 60)〜(160, 120) の内側の画素だけを通す")
    func rectClipStaysOnTheSurface() throws {
        let pixels = try drawn { $0.clip(100, 60, 60, 60) }
        let box = try #require(whiteBox(pixels))
        #expect(box.x == 100...159 && box.y == 60...119, "切り抜きの範囲が視点に通されて動いた: \(box)")
        #expect(box.count == 60 * 60, "範囲の内側が一様に白く、外は下地のまま (\(box.count) 画素)")
    }

    @Test("camera(...) の下の clip { rect(100, 60, 60, 60) } も、同じ面の範囲を通す")
    func shapeClipStaysOnTheSurface() throws {
        let pixels = try drawn { canvas in
            canvas.clip { canvas.rect(100, 60, 60, 60) }
        }
        let box = try #require(whiteBox(pixels))
        #expect(box.x == 100...159 && box.y == 60...119, "切り抜きの範囲が視点に通されて動いた: \(box)")
        #expect(box.count == 60 * 60, "範囲の内側が一様に白く、外は下地のまま (\(box.count) 画素)")
    }

    @Test("同じ視点の下の rect(100, 60, 60, 60) は視点を通って動く (切り抜きとの食い違いを固定する)")
    func theRectItselfMovesThroughTheCamera() throws {
        let gpu = try RenderDevice()
        let canvas = try CanvasFixture.make(gpu: gpu, width: 320, height: 240)
        try canvas.draw {
            canvas.background(0)
            canvas.noStroke()
            canvas.fill(255)
            canvas.camera(400, 40, 300, 160, 120, 0, 0, 1, 0)
            canvas.rect(100, 60, 60, 60)
        }
        let box = try #require(whiteBox(try canvas.target.readPixels()))
        #expect(box.x != 100...159 || box.y != 60...119, "視点の下の rect が面の上と同じ位置にある")
    }
}
