// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Testing

@testable import MokumeCore

/// 出口へ配るのは、絵を組んだ投入の結末を確かめてから ([#2743])。GPU を要する。
///
/// 結末は完了の合図より遅れて届く。配る時点でまだ届いていなければ、**待たずに次のフレームへ持ち越し**、
/// その間のフレームは 2 枚目の置き場へ組む。待つのは、2 枚とも持ち越しで埋まったときと、次が来ない
/// 経路 (止め際・閉じ際・止まったスケッチの `save()`) だけである。ここが見るのは:
///
/// - 打ち切りの無い普段の経路で、フレームごとに結末を待たず、置き場が 2 枚を越えない
/// - 持ち越した絵は順を保って配られる
///
/// 打ち切ったフレームを書き出しが書かないことは `SaveFramesTests` が見る。
///
/// [#2743]: https://github.com/mokume-metal/mokume/issues/2743
@Suite(
    "出口へ配るのを持ち越す",
    .serialized,
    .enabled(if: RenderDevice.isAvailable, "GPU が無い環境ではスキップ"))
struct OutletDeferralTests {
    /// フレームごとに背景を塗るだけの軽いスケッチ。`body` を差し込んで、フレームの中で検査の
    /// 差し込みを立てる。
    final class LightSketch: Sketch {
        nonisolated(unsafe) static var declared: [any Outlet] = []
        nonisolated(unsafe) static var body: (LightSketch) -> Void = { _ in }

        var settings: SketchSettings { SketchSettings(width: 16, height: 16) }
        var plugins: [any Plugin] { [FrameSyncTests.OutletPlugin(outlets: Self.declared)] }

        func draw() {
            Self.body(self)
            background(0)
        }
    }

    private func makeRuntime(
        _ outlet: any Outlet, body: @escaping (LightSketch) -> Void = { _ in }
    ) throws -> (SketchRuntime, RenderDevice) {
        LightSketch.declared = [outlet]
        LightSketch.body = body
        let gpu = try RenderDevice()
        return (try SketchRuntime(sketch: LightSketch(), gpu: gpu), gpu)
    }

    /// **間を空けずに回す** — `mokume render` の形で、結末が配る時点でまだ届いていないことが多い
    /// (#2743 の実測では 59 回中 50 回)。持ち越しを外して届くまで待つ形に戻すと、ほぼ毎フレーム待つ。
    @Test("打ち切りの無い普段の経路では、フレームごとに結末を待たず、置き場は 2 枚を越えない")
    func theUsualPathNeitherWaitsForOutcomesNorGrowsStorage() throws {
        let outlet = FrameSyncTests.WatchingOutlet(readsBytes: false)
        let (runtime, gpu) = try makeRuntime(outlet)
        let frames = 20

        let waits = gpu.outcomeWaits
        for _ in 0..<frames { try runtime.advance() }
        let waited = gpu.outcomeWaits - waits

        // 待つのは 2 枚とも持ち越しで埋まったときだけで、それは前々のフレームの結末がまだ届いて
        // いないとき — 普段は起きない。機械が混んでいる日の揺れぶんだけ許す
        #expect(waited <= frames / 4, "\(frames) フレームで \(waited) 回、結末を待った")
        #expect(runtime.target.encodedImagesMade <= 2, "置き場を作り足している")
        #expect(runtime.target.encodePassCount == frames, "道を 1 フレームに 1 回通っていない")

        runtime.closePlugins()
        // 閉じるときに残りを配る。持ち越した絵も含めて、どの番号も 1 回ずつ順に届く
        #expect(outlet.frames.map(\.frame) == Array(1...frames))
    }

    /// 結末の知らせを遅らせ (`holdsNextOutcomeForTesting`)、持ち越しを間合いに頼らずに起こす。3 枚目の
    /// 絵は配る時点で結末が届いていないので、**待たずに**持ち越し、4 枚目は 2 枚目の置き場へ組む。結末が
    /// 届いた後のフレームで、3 枚目から順に配る。持ち越しを外して届くまで待つ形に戻すと、4 枚目で
    /// 3 枚目の結末を (縮めた上限まで) 待ち、届かなかったものとして 3 枚目を落とすので赤になる。
    @Test("結末が届く前に配ろうとした絵は、待たずに持ち越し、届いた後に順を保って配る")
    func aFrameWhoseOutcomeIsLateIsDeferredWithoutWaiting() throws {
        let outlet = FrameSyncTests.WatchingOutlet(readsBytes: false)
        let (runtime, gpu) = try makeRuntime(outlet) { sketch in
            if sketch.frameCount == 3 { sketch.canvas.gpu.holdsNextOutcomeForTesting = true }
        }
        gpu.outcomeWaitLimit = .milliseconds(50)

        // 1・2 枚目は結末が届くのを待ってから次へ進め、自然な持ち越しを混ぜない
        for _ in 0..<2 {
            try runtime.advance()
            SharedFrameSurfaceTests.awaitOutcomes(gpu)
        }
        try runtime.advance()

        // 検査の側の待ち (awaitOutcomes) も数に入るので、フレームを進める前後だけを比べる
        var waits = gpu.outcomeWaits
        try runtime.advance()
        #expect(!outlet.frames.map(\.frame).contains(3), "結末の届いていない 3 枚目を配った")
        #expect(runtime.target.encodedImagesMade == 2, "持ち越したのに 2 枚目の置き場へ組んでいない")
        #expect(gpu.outcomeWaits == waits, "結末の届いていない 3 枚目を、持ち越さずに待った")

        gpu.releaseHeldOutcomesForTesting()
        SharedFrameSurfaceTests.awaitOutcomes(gpu)
        waits = gpu.outcomeWaits
        try runtime.advance()
        #expect(outlet.frames.map(\.frame).prefix(4) == [1, 2, 3, 4], "届いた後に順を保って配っていない")
        #expect(gpu.outcomeWaits == waits, "結末が届いた後なのに待った")
        #expect(!runtime.warnings.hasWarned(.droppedOutletFrame), "遅れただけの絵を落とした")

        runtime.closePlugins()
        #expect(outlet.frames.map(\.frame) == [1, 2, 3, 4, 5])
    }

    /// 結末の知らせが届かない投入 (`losesNextOutcomeForTesting`) で、持ち越しを確かに起こす。3 枚目の
    /// 絵は配る時点で結末が届かないので持ち越し、4 枚目は 2 枚目の置き場へ組む。5 枚目を組むときに
    /// 置き場が 2 枚とも埋まっているので、3 枚目の結末を (縮めた上限まで) 待ち、届かなかった結末は
    /// 打ち切りとして 3 枚目を配らない。4 枚目からは順に配る。
    @Test("持ち越した絵は順を保って配り、待つのは置き場が 2 枚とも埋まったときだけ")
    func deferredFramesKeepTheirOrderAndWaitOnlyWhenBothStoragesAreHeld() throws {
        let outlet = FrameSyncTests.WatchingOutlet(readsBytes: false)
        let (runtime, gpu) = try makeRuntime(outlet) { sketch in
            if sketch.frameCount == 3 { sketch.canvas.gpu.losesNextOutcomeForTesting = true }
        }
        gpu.outcomeWaitLimit = .milliseconds(50)

        // 1・2 枚目は結末が届くのを待ってから次へ進め、自然な持ち越しを混ぜない
        for _ in 0..<2 {
            try runtime.advance()
            SharedFrameSurfaceTests.awaitOutcomes(gpu)
        }
        try runtime.advance()
        let waits = gpu.outcomeWaits
        try runtime.advance()
        // 3 枚目は持ち越し、4 枚目は 2 枚目の置き場へ組んだ
        #expect(!outlet.frames.map(\.frame).contains(3), "結末の届いていない 3 枚目を配った")
        #expect(runtime.target.encodedImagesMade == 2, "持ち越したのに 2 枚目の置き場へ組んでいない")
        #expect(gpu.outcomeWaits == waits, "置き場が空いているのに、結末を待った")

        try runtime.advance()
        // 5 枚目を組む前に、置き場を空けるため 3 枚目の結末を待った
        #expect(gpu.outcomeWaits == waits + 1, "置き場が 2 枚とも埋まったのに待っていない、または待ちすぎた")
        for _ in 0..<2 { try runtime.advance() }
        runtime.closePlugins()

        #expect(outlet.frames.map(\.frame) == [1, 2, 4, 5, 6, 7], "持ち越した絵の順が崩れた")
        #expect(runtime.target.encodedImagesMade == 2, "置き場を作り足している")
        let said = try #require(runtime.warnings.message(for: .droppedOutletFrame))
        #expect(said.contains("frame 3"), "\(said)")
    }
}
