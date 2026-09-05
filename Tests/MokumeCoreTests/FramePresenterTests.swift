// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Metal
import QuartzCore
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
        try source.fill(with: .linear(red: 1, green: 1, blue: 1))

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
        try source.fill(with: .linear(red: 1, green: 1, blue: 1))
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

/// 画面へ出すかどうかの判定。
///
/// **GPU も窓も要らない。** 窓の状態は機械で作れないが、判定だけを純粋関数に切り出して
/// あるので、条件の組み合わせはここで固定できる。
@Suite("画面へ出すかどうか")
struct PresentDecisionTests {
    @Test("窓が見えていれば出す")
    func presentsWhileVisible() {
        #expect(FramePresenter.shouldPresent(windowIsVisible: true, hasPresented: true))
    }

    @Test("窓が見えていなければ出さない")
    func skipsWhileHidden() {
        #expect(!FramePresenter.shouldPresent(windowIsVisible: false, hasPresented: true))
    }

    /// 見えているかの判定は窓が出てから更新されるので、それを待たずに描き終える
    /// スケッチ (1 枚しか描かないもの) が永久に何も表示しないことになる。
    @Test("まだ 1 枚も出していなければ、見えていなくても出す")
    func alwaysPresentsTheFirstFrame() {
        #expect(FramePresenter.shouldPresent(windowIsVisible: false, hasPresented: false))
    }
}

/// 差し出す面の常駐。GPU を要する。
///
/// 検証レイヤは、コマンドが触るテクスチャが常駐の集合に入っていることを要求する。
/// 差し出す面は**絵には出ない性質**なので (通し忘れても絵は普段どおり出る)、#351 の
/// `RenderTargetTests` と同じく**絵ではなく常駐の集合そのものを問う**。
///
/// [#357](https://github.com/mokume-metal/mokume/issues/357)
@Suite(
    "差し出す面の常駐",
    .enabled(
        if: RenderDevice.isAvailable,
        "この世代のコマンド構造に対応した GPU が無い実行環境ではスキップする")
)
struct DrawableResidencyTests {
    /// 面へ差し出す一式。行き先の面だけを外から動かせるようにして返す。
    private func makeSession(surface: Int) throws -> (
        gpu: RenderDevice, source: RenderTarget, presenter: FramePresenter, layer: CAMetalLayer
    ) {
        let gpu = try RenderDevice()
        let source = try RenderTarget(gpu: gpu, width: 32, height: 32)
        try source.fill(with: .linear(red: 1, green: 1, blue: 1))
        let presenter = try FramePresenter(gpu: gpu, pixelFormat: RenderTarget.pixelFormat)
        return (gpu, source, presenter, SurfaceFixture.make(gpu.device, size: surface))
    }

    @Test("差し出した面は常駐の集合に入る")
    func presentedDrawableJoinsTheResidencySet() throws {
        let (gpu, source, presenter, layer) = try makeSession(surface: 64)

        let presented = try presenter.present(source, to: layer)
        try #require(presented, "面を取れていない — この検査は何も見ていない")

        let allocations = gpu.drawableResidency.allAllocations
        #expect(!allocations.isEmpty, "差し出した面が常駐していない")
        #expect(
            allocations.allSatisfy { ($0 as? any MTLTexture)?.width == 64 },
            "いま差し出している面と別の大きさのものが残っている")
    }

    @Test("フレームを重ねても常駐の集合は膨らまない")
    func residencyStaysBoundedAcrossFrames() throws {
        let (gpu, source, presenter, layer) = try makeSession(surface: 64)

        for _ in 0..<120 { try presenter.present(source, to: layer) }

        // 面の環は Metal 側が持っていて、大きさが同じ限り有界である。**入れ直しても
        // 数が増えないこと**をここで固定する (集合なので冪等・実測では 2 種類)
        #expect(
            gpu.drawableResidency.allocationCount <= layer.maximumDrawableCount,
            "面の環より多くの面が常駐している")
    }

    @Test("面の大きさを変えても常駐の集合は膨らまない")
    func residencyStaysBoundedAcrossResizes() throws {
        let (gpu, source, presenter, layer) = try makeSession(surface: 200)

        for step in 0..<60 {
            layer.drawableSize = CGSize(width: 200 + step * 8, height: 200)
            for _ in 0..<4 { try presenter.present(source, to: layer) }
        }

        // **ここが本番。** 大きさが変わると面の環ごと作り直されるので、古い面を畳まないと
        // 積み上がる — 畳まない実装では 120 件・85.2 MiB が常駐したままになった (#357)
        #expect(
            gpu.drawableResidency.allocationCount <= layer.maximumDrawableCount,
            "作り直される前の面が常駐に残り続けている")
    }
}
