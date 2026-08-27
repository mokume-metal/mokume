// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Metal
import Testing

@testable import MokumeCore

/// 画面へ差し出す経路の検査。GPU を要する。
///
/// 窓そのものは機械で検められないが、**行き先だけを差し替えれば同じ経路が通る**ので、
/// 収まり方は画素で確かめられる。
@Suite(
    "画面への収まり",
    .enabled(
        if: RenderDevice.isAvailable,
        "この世代のコマンド構造に対応した GPU が無い実行環境ではスキップする")
)
struct FramePresenterTests {
    /// 描いた絵を、指定した大きさの面へ収めて読み出す。
    private func presented(
        content: (width: Int, height: Int),
        into surface: (width: Int, height: Int)
    ) throws -> PixelBuffer {
        let gpu = try RenderDevice()
        let source = try RenderTarget(gpu: gpu, width: content.width, height: content.height)
        try source.fill(with: .opaque(red: 1, green: 1, blue: 1))

        let destination = try RenderTarget(
            gpu: gpu, width: surface.width, height: surface.height)
        let presenter = try FramePresenter(gpu: gpu, pixelFormat: RenderTarget.pixelFormat)
        try presenter.draw(source, into: destination.texture)
        return try destination.readPixels()
    }

    @Test("縦横比が一致していれば、面いっぱいに絵が出る")
    func matchingAspectFillsEverything() throws {
        let pixels = try presented(content: (32, 16), into: (64, 32))
        #expect(pixels[0, 0].red == 1)
        #expect(pixels[63, 31].red == 1)
        #expect(pixels[32, 16].red == 1)
    }

    @Test("面のほうが横長なら、左右が黒帯になる")
    func widerSurfaceGetsBlackSideBands() throws {
        // 2:1 の絵を 4:1 の面へ。絵は中央の半分に収まる
        let pixels = try presented(content: (32, 16), into: (128, 32))
        #expect(pixels[2, 16].red == 0, "左が帯になっていない")
        #expect(pixels[125, 16].red == 0, "右が帯になっていない")
        #expect(pixels[64, 16].red == 1, "中央に絵が出ていない")
        #expect(pixels[64, 2].red == 1, "上端まで広がっていない")
        #expect(pixels[64, 29].red == 1, "下端まで広がっていない")
    }

    @Test("面のほうが縦長なら、上下が黒帯になる")
    func tallerSurfaceGetsBlackTopAndBottomBands() throws {
        let pixels = try presented(content: (32, 16), into: (32, 64))
        #expect(pixels[16, 2].red == 0, "上が帯になっていない")
        #expect(pixels[16, 61].red == 0, "下が帯になっていない")
        #expect(pixels[16, 32].red == 1, "中央に絵が出ていない")
        #expect(pixels[1, 32].red == 1, "左端まで広がっていない")
        #expect(pixels[30, 32].red == 1, "右端まで広がっていない")
    }

    @Test("面の大きさが変わっても、絵の解像度は変わらない")
    func contentResolutionIsIndependentOfTheSurface() throws {
        let gpu = try RenderDevice()
        let source = try RenderTarget(gpu: gpu, width: 32, height: 16)
        try source.fill(with: .opaque(red: 1, green: 1, blue: 1))
        let presenter = try FramePresenter(gpu: gpu, pixelFormat: RenderTarget.pixelFormat)

        for size in [(64, 64), (256, 32), (17, 200)] {
            let destination = try RenderTarget(gpu: gpu, width: size.0, height: size.1)
            try presenter.draw(source, into: destination.texture)
            // 描いた側は一度も作り直されない
            #expect(source.width == 32)
            #expect(source.height == 16)
        }
    }
}
