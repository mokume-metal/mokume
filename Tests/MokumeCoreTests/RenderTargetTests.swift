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

        let color = LinearRGBA.linear(red: 0.25, green: 0.5, blue: 0.75)
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
        try target.fill(with: .linear(red: 4, green: 2, blue: 1))

        let pixels = try target.readPixels()
        #expect(pixels[0, 0].red == 4)
        #expect(pixels[1, 1].green == 2)
    }

    @Test("塗り直さなければ、前の内容の上に残る")
    func keepsPreviousContentsWhenNotCleared() throws {
        let gpu = try RenderDevice()
        let target = try RenderTarget(gpu: gpu, width: 2, height: 2)

        try target.fill(with: .linear(red: 1, green: 0, blue: 0))
        // 塗り直さないパスを 1 本流しても内容は変わらない
        let commands = try gpu.beginCommands()
        let encoder = try #require(
            commands.makeRenderCommandEncoder(descriptor: target.makeRenderPass(clearColor: nil)))
        encoder.endEncoding()
        try gpu.commitAndWait(commands)

        #expect(try target.readPixels()[0, 0] == LinearRGBA.linear(red: 1, green: 0, blue: 0))
    }

    /// 完了条件「`RenderTarget.texture` が `.private`」(#753)。
    ///
    /// **置き場の上に載せたテクスチャではない**ことも見る。`.shared` の置き場に載せた
    /// リニアなテクスチャには GPU のロスレス圧縮も並べ替えも効かず、画素を読まない
    /// スケッチまで帯域を払っていた。
    @Test("描画先は .private の通常テクスチャで、置き場の上には載っていない")
    func targetTextureIsPrivateAndNotBufferBacked() throws {
        let gpu = try RenderDevice()
        let target = try RenderTarget(gpu: gpu, width: 8, height: 4)
        #expect(target.texture.storageMode == .private)
        #expect(target.texture.buffer == nil, "描画先が置き場の上に載っている")
        #expect(target.depthTexture.storageMode == .private)
    }

    @Test("描画先は、置き場だけでなくテクスチャも常駐の集合に入る")
    func targetTextureJoinsTheResidencySet() throws {
        let gpu = try RenderDevice()
        let target = try RenderTarget(gpu: gpu, width: 4, height: 4)

        // 常駐から漏れたテクスチャは、検証レイヤが「どの residency set にも入っていない」
        // と言う ([#351])。絵は普段どおり出てしまうため、**絵ではなく常駐の集合そのものを
        // 問う**。画素の写しは頼まれてから作られるので、頼んでから見る。
        //
        // [#351]: https://github.com/mokume-metal/mokume/issues/351
        #expect(gpu.residencySet.containsAllocation(target.texture), "描画先のテクスチャが常駐していない")
        #expect(
            gpu.residencySet.containsAllocation(target.depthTexture),
            "奥行きの面が常駐していない")
        _ = try target.readPixels()
        let mirror = try #require(target.pixelMirror)
        #expect(gpu.residencySet.containsAllocation(mirror.storage), "画素の写しが常駐していない")
    }

    /// GPU 専用の面の初期値は未定義なので、作った時点で塗っておく (#753)。
    ///
    /// 塗り直しを頼まずに描き足す最初のフレーム (周囲を背景に置く絵) がここを読む。
    /// 台帳の `surroundings` は、これが無いと実際に動いた。
    @Test("作った直後の描画先は透明な黒")
    func aFreshTargetStartsTransparentBlack() throws {
        let gpu = try RenderDevice()
        let target = try RenderTarget(gpu: gpu, width: 8, height: 4)
        let pixels = try target.readPixels()
        for y in 0..<4 {
            for x in 0..<8 { #expect(pixels[x, y] == .transparent, "(\(x), \(y))") }
        }
    }

    /// 完了条件「読まないスケッチは 1 バイトも払わない」(#753)。
    @Test("画素を頼まれない描画先は写しを持たず、頼まれたら 1 度だけ作る")
    func pixelMirrorIsMadeOnlyWhenAskedAndOnlyOnce() throws {
        let gpu = try RenderDevice()
        let target = try RenderTarget(gpu: gpu, width: 8, height: 4)
        try target.fill(with: .linear(red: 1, green: 0, blue: 0))
        try target.fill(with: .linear(red: 0, green: 1, blue: 0))
        #expect(target.pixelMirror == nil, "画素を読んでいないのに写しがある")
        #expect(target.pixelMirrorsMade == 0)

        #expect(try target.readPixels()[0, 0] == LinearRGBA.linear(red: 0, green: 1, blue: 0))
        #expect(target.pixelMirrorsMade == 1)
        #expect(target.pixelReadbacksEncoded == 1)

        // 同じ絵をもう一度読んでも、写しは作り直さず、読み戻しも積み直さない
        _ = try target.readPixels()
        #expect(target.pixelMirrorsMade == 1)
        #expect(target.pixelReadbacksEncoded == 1, "GPU に新しい仕事が無いのに読み戻している")

        // 絵が変わったら読み戻す
        try target.fill(with: .linear(red: 0, green: 0, blue: 1))
        #expect(try target.readPixels()[7, 3] == LinearRGBA.linear(red: 0, green: 0, blue: 1))
        #expect(target.pixelReadbacksEncoded == 2)
        #expect(target.pixelMirrorsMade == 1)
    }

    @Test("大きさが 0 以下の描画先は作れない", arguments: [(0, 4), (4, 0), (-1, 4)])
    func rejectsNonPositiveSizes(size: (width: Int, height: Int)) throws {
        let gpu = try RenderDevice()
        #expect(throws: RenderFailure.invalidSize(width: size.width, height: size.height)) {
            _ = try RenderTarget(gpu: gpu, width: size.width, height: size.height)
        }
    }

    /// **この検査が見ているのは「落ちないこと」である** ([#885])。
    ///
    /// 上限を超えた descriptor に Metal は `nil` を返さず、検証層がアサーションで
    /// プロセスを終了させる。だから守りが無いと `#expect(throws:)` は失敗ではなく
    /// **SIGABRT で検査プロセスごと消える** — `try?` でも捕まらない。返ってきて
    /// この行を評価できること自体が、確かめたいことの半分である。
    ///
    /// [#885]: https://github.com/mokume-metal/mokume/issues/885
    @Test(
        "上限を超えた描画先は、落ちずに失敗として返る",
        arguments: [
            (RenderDevice.maxTextureSide + 1, 4),
            (4, RenderDevice.maxTextureSide + 1),
            (20000, 20000),
        ])
    func rejectsSizesBeyondTheLimit(size: (width: Int, height: Int)) throws {
        let gpu = try RenderDevice()
        #expect(throws: RenderFailure.invalidSize(width: size.width, height: size.height)) {
            _ = try RenderTarget(gpu: gpu, width: size.width, height: size.height)
        }
    }

    /// **境界を 1 つ内側で切っていないこと。**
    ///
    /// 軸ごとに細長く見るのは、正方形の 16384² が色だけで 2 GiB・奥行きと合わせて
    /// 3 GiB になるためである。上限は軸ごとに効くので、1 軸ずつで確かめられる。
    @Test(
        "上限ちょうどの描画先は作れる",
        arguments: [
            (RenderDevice.maxTextureSide, 1),
            (1, RenderDevice.maxTextureSide),
        ])
    func acceptsSizesAtTheLimit(size: (width: Int, height: Int)) throws {
        let gpu = try RenderDevice()
        let target = try RenderTarget(gpu: gpu, width: size.width, height: size.height)
        #expect(target.width == size.width)
        #expect(target.height == size.height)
    }
}
