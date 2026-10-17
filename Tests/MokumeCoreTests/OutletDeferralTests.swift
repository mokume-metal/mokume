// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation
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

    // MARK: - 反証への応え

    /// 受け取るたびに転ぶ出口。受け取った番号を覚える。
    final class AlwaysFailingOutlet: Outlet {
        private(set) var frames: [Int] = []
        func receive(_ frame: OutputFrame) { frames.append(frame.frame) }
        var failure: String? { "always" }
    }

    /// **差込口の健康は、1 回の進めにつき 1 回だけ数える** (#2743 の反証 5)。持ち越した絵と次の絵を
    /// 同じ進めで 2 枚配っても、続けて転んだ数は 1 つしか進まない。1 枚ごとに数えると、1 回きりの
    /// 書き損じ (撮る係は新しい知らせが来るまで前の値を保つ・#1272) が 2 回ぶんに数えられ、1 回早く外れる。
    @Test("持ち越した絵と次の絵を同じ進めで配っても、差込口の転びは 1 回ぶんだけ数える")
    func seamHealthCountsOncePerAdvance() throws {
        let failing = AlwaysFailingOutlet()
        let (runtime, gpu) = try makeRuntime(failing) { sketch in
            if sketch.frameCount == 1 { sketch.canvas.gpu.holdsNextOutcomeForTesting = true }
        }
        try runtime.advance()
        // 1 枚目の結末が届いていないので持ち越す。ここではまだ配らない
        try runtime.advance()
        try #require(failing.frames.isEmpty, "結末の届いていない 1 枚目を配った")
        gpu.releaseHeldOutcomesForTesting()
        SharedFrameSurfaceTests.awaitOutcomes(gpu)

        for _ in 0..<4 {
            try runtime.advance()
            SharedFrameSurfaceTests.awaitOutcomes(gpu)
        }
        // 3 回目の進めで 1・2 枚目をまとめて配り (数えは 1)、4・5 回目で 3・4 枚目 (2・3) で外れる。
        // 1 枚ごとに数えると、3 回目で 2、4 回目で 3 になり、4 枚目を受け取らずに外れる
        #expect(failing.frames == [1, 2, 3, 4], "\(failing.frames)")
        runtime.closePlugins()
    }

    /// 止めて、押されたら画素を 1 つ書いて保存するスケッチ (#2743 の反証 4)。1 枚目の描き切りの投入は
    /// 打ち切ったことにし、そのフレームでも保存を頼む。
    final class StoppedSaver: Sketch {
        nonisolated(unsafe) static var directory = URL(fileURLWithPath: "/")
        var settings: SketchSettings { SketchSettings(width: 16, height: 16) }
        func setup() { noLoop() }
        func draw() {
            canvas.gpu.dropsNextSubmissionForTesting = DroppedWorkReadersTests.victim
            background(255, 0, 0)
            save(Self.directory.appendingPathComponent("first.png").path)
        }
        func mousePressed() {
            set(0, 0, .linear(red: 0, green: 0, blue: 1))
            save(Self.directory.appendingPathComponent("second.png").path)
        }
    }

    /// **止まっている間に、打ち切りの後で面を書き直したら、組み直して保存する** (#2743 の反証 4)。
    /// 打ち切られたフレームのままの面では組み直しても配れないので組み直さないが、書いた画素が面へ
    /// 戻れば面の中身は新しい。そこで頼んだ保存は、次の描画を待たずに書く。
    @Test("止まっている間に、打ち切りの後で面へ書けば、次の描画を待たずに保存する")
    func aStoppedSketchSavesAfterWritingOverADroppedFrame() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("mokume-stopped-dropped-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        StoppedSaver.directory = directory
        let runtime = try SketchRuntime(sketch: StoppedSaver(), gpu: try RenderDevice())
        let first = directory.appendingPathComponent("first.png")
        let second = directory.appendingPathComponent("second.png")

        try runtime.advance()
        // 打ち切られたフレームの絵では書かない
        #expect(!FileManager.default.fileExists(atPath: first.path), "打ち切られた絵で保存した")

        runtime.input.enqueue(.mouseDown(x: 4, y: 4, button: .left))
        try runtime.advance()
        // 押したコールバックが画素を書いたので、面の中身は新しい。止まったまま両方を書く
        #expect(FileManager.default.fileExists(atPath: first.path), "書き直した後も、1 枚目の保存を待たせている")
        #expect(FileManager.default.fileExists(atPath: second.path), "書き直した後の保存を、次の描画まで待たせている")
        runtime.closePlugins()
    }

    /// **塞がずに閉じる口 (`closePlugins(.peek)`) は、結末を待たない** (#2743 の反証 6)。結末の届かない
    /// 投入があっても、見に来るたびにすぐ返る。届かないまま待つ上限を過ぎたら、届かなかったものとして
    /// 落として決着する。
    @Test("塞がずに閉じる口は、結末の届かない絵に塞がれず、上限を過ぎたら落として決着する")
    func peekingCloseDoesNotWaitForOutcomes() throws {
        let outlet = FrameSyncTests.WatchingOutlet(readsBytes: false)
        let (runtime, gpu) = try makeRuntime(outlet) { sketch in
            if sketch.frameCount == 2 { sketch.canvas.gpu.losesNextOutcomeForTesting = true }
        }
        gpu.outcomeWaitLimit = .milliseconds(500)
        try runtime.advance()
        SharedFrameSurfaceTests.awaitOutcomes(gpu)
        try runtime.advance()

        let began = ContinuousClock.now
        let settled = runtime.closePlugins(.peek)
        let took = ContinuousClock.now - began
        #expect(!settled, "結末の届かない絵があるのに、決着したと言った")
        #expect(took < .milliseconds(200), "塞がずに見に来る口が \(took) 塞いだ")

        // 見に来続ければ、上限を過ぎたところで届かなかったものとして落とし、決着する
        let deadline = ContinuousClock.now + .seconds(10)
        var done = false
        while !done, ContinuousClock.now < deadline {
            let peekBegan = ContinuousClock.now
            done = runtime.closePlugins(.peek)
            #expect(ContinuousClock.now - peekBegan < .milliseconds(200), "見に来る口が塞いだ")
            if !done { Thread.sleep(forTimeInterval: 0.01) }
        }
        #expect(done, "上限を過ぎても決着しない")
        #expect(outlet.frames.map(\.frame) == [1], "結末の届かない 2 枚目を配った")
    }

    /// **待たずに問う口は、そのフレームの範囲より前の結末の欠けで塞がれない** (#2743 の反証 6)。範囲の
    /// 外の投入 (ここでは、フレームの間に積んだ空の投入) の結末が届かなくても、範囲の結末が揃って
    /// いれば待たずに配る。
    @Test("範囲より前の投入の結末が届かなくても、範囲が揃っていれば待たずに配る")
    func aMissingOutcomeBeforeTheRangeDoesNotHoldFramesBack() throws {
        let outlet = FrameSyncTests.WatchingOutlet(readsBytes: false)
        let (runtime, gpu) = try makeRuntime(outlet)
        gpu.outcomeWaitLimit = .seconds(2)
        try runtime.advance()
        SharedFrameSurfaceTests.awaitOutcomes(gpu)

        // どのフレームの範囲にも入らない投入の結末を落とす
        gpu.losesNextOutcomeForTesting = true
        try gpu.withCommands { commands throws(RenderFailure) in gpu.commit(commands) }

        let waits = gpu.outcomeWaits
        for _ in 0..<4 {
            try runtime.advance()
            // 結末が届く間合いを置く (待つ口は使わない — 待てば欠けた結末で塞がれる)
            Thread.sleep(forTimeInterval: 0.02)
        }
        #expect(gpu.outcomeWaits == waits, "範囲の外の欠けで結末を待った")
        #expect(outlet.frames.map(\.frame) == [1, 2, 3, 4], "\(outlet.frames.map(\.frame))")
        runtime.closePlugins()
    }
}
