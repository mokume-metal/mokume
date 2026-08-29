// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Testing

@testable import MokumeCore

/// GPU を要する検査。
///
/// 描画の土台を組み立てられない実行環境ではスキップし、**スキップしたことが出力に
/// 現れる**ようにする。見ていない検査を緑にしないためで、CI がその状態なら
/// 「CI では見ていない」と分かる。
@Suite(
    "オフスクリーンの描画先",
    .enabled(
        if: RenderDevice.isAvailable,
        "この世代のコマンド構造に対応した GPU が無い実行環境ではスキップする")
)
struct RenderTargetTests {
    @Test("塗った色が、そのまま読み出せる")
    func fillRoundTripsThroughTheWorkingSpace() throws {
        let gpu = try RenderDevice()
        let target = try RenderTarget(gpu: gpu, width: 8, height: 4)

        let color = LinearRGBA.opaque(red: 0.25, green: 0.5, blue: 0.75)
        try target.fill(with: color)

        let pixels = try target.readPixels()
        #expect(pixels.width == 8)
        #expect(pixels.height == 4)
        // 半精度浮動小数で往復するので、0.25 / 0.5 / 0.75 のように 2 進で表せる値は
        // 完全に一致する。一致しない値を選ぶと、検査が精度の話にすり替わる。
        #expect(pixels[0, 0] == color)
        #expect(pixels[7, 3] == color)
    }

    @Test("表示できる範囲を超えた明るさが、読み出しまで残る")
    func keepsBrightnessBeyondTheDisplayableRange() throws {
        let gpu = try RenderDevice()
        let target = try RenderTarget(gpu: gpu, width: 2, height: 2)

        // 半精度浮動小数の描画先を選んだ理由そのもの (ADR-0011 決定 2)。
        // 8 bit の描画先ならここで 1.0 に潰れる。
        try target.fill(with: .opaque(red: 4, green: 2, blue: 1))

        let pixels = try target.readPixels()
        #expect(pixels[0, 0].red == 4)
        #expect(pixels[1, 1].green == 2)
    }

    @Test("塗り直さなければ、前の内容の上に残る")
    func keepsPreviousContentsWhenNotCleared() throws {
        let gpu = try RenderDevice()
        let target = try RenderTarget(gpu: gpu, width: 2, height: 2)

        try target.fill(with: .opaque(red: 1, green: 0, blue: 0))
        // 塗り直さないパスを 1 本流しても内容は変わらない
        let commands = try gpu.beginCommands()
        let encoder = try #require(
            commands.makeRenderCommandEncoder(descriptor: target.makeRenderPass(clearColor: nil)))
        encoder.endEncoding()
        try gpu.commitAndWait(commands)

        #expect(try target.readPixels()[0, 0] == LinearRGBA.opaque(red: 1, green: 0, blue: 0))
    }

    @Test("描画先は、置き場だけでなくテクスチャも常駐の集合に入る")
    func targetTextureJoinsTheResidencySet() throws {
        let gpu = try RenderDevice()
        let target = try RenderTarget(gpu: gpu, width: 4, height: 4)

        // **置き場が入っているだけでは足りない。** 置き場とその上に載せたテクスチャは
        // 別の allocation として数えられるので、テクスチャを通し忘れると検証レイヤが
        // 「どの residency set にも入っていない」と言う ([#351])。絵は普段どおり出て
        // しまうため、**絵ではなく常駐の集合そのものを問う**。
        //
        // [#351]: https://github.com/mokume-metal/mokume/issues/351
        #expect(gpu.residencySet.containsAllocation(target.storage), "置き場が常駐していない")
        #expect(gpu.residencySet.containsAllocation(target.texture), "描画先のテクスチャが常駐していない")
        #expect(
            gpu.residencySet.containsAllocation(target.depthTexture),
            "奥行きの面が常駐していない")
    }

    @Test("大きさが 0 以下の描画先は作れない", arguments: [(0, 4), (4, 0), (-1, 4)])
    func rejectsNonPositiveSizes(size: (width: Int, height: Int)) throws {
        let gpu = try RenderDevice()
        #expect(throws: RenderFailure.invalidSize(width: size.width, height: size.height)) {
            _ = try RenderTarget(gpu: gpu, width: size.width, height: size.height)
        }
    }
}
