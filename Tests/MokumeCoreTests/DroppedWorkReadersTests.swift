// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation
import Testing

@testable import MokumeCore

/// 投げる読む口は、GPU が仕上げなかった絵を成功として返さない
/// ([#1932](https://github.com/mokume-metal/mokume/issues/1932))。
///
/// 口は 4 つ — ``RenderTarget/readPixels()``・``RenderTarget/encodeForDisplay(scale:)``・
/// ``RenderTarget/writePNG(to:)``・``SketchRuntime/renderFrame(to:)``。返す絵が拠った範囲の投入
/// (同じ面で前に判定した読みの後に土台へ積まれた投入すべて、この読みが積んだ読み戻し・出力段まで)
/// のどれかを GPU が打ち切っていたら、結末が届くのを待ってから `.workDropped` を投げる。
///
/// **打ち切りは GPU を止めずに作る** ([#1065] の完了条件 4)。`dropsNextSubmissionForTesting` で
/// 次の投入を打ち切られたことにする。投入は GPU で普通に走り、結末だけが本物のハンドラを通って
/// 「打ち切り」として遅れて届く — だから絵そのものは無事で、検査が見るのは口が名乗るかどうかである。
///
/// [#1065]: https://github.com/mokume-metal/mokume/issues/1065
@Suite(
    "投げる読む口と GPU の打ち切り",
    .serialized,
    .enabled(if: RenderDevice.isAvailable, "GPU が無い環境ではスキップ"))
struct DroppedWorkReadersTests {
    /// #1812 の run 36463335392 で実際に届いた理由。
    static let victim =
        "Discarded (victim of GPU error/recovery) (00000005:kIOGPUCommandBufferCallbackErrorInnocentVictim)"

    static let red = LinearRGBA.linear(red: 1, green: 0, blue: 0)
    static let blue = LinearRGBA.linear(red: 0, green: 0, blue: 1)

    private func makeCanvas(_ gpu: RenderDevice) throws -> Canvas {
        try CanvasFixture.make(gpu: gpu, width: 16, height: 16)
    }

    /// 1 色で塗り切る。描き切りの投入は 1 本である。
    private func paint(_ canvas: Canvas, _ color: LinearRGBA) throws {
        try canvas.draw { canvas.background(color) }
    }

    private func temporaryPNG() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("mokume-dropped-\(UUID().uuidString).png")
    }

    /// 打ち切りを名乗る失敗か。**理由は 1 行目に載る** (窓の経路は 1 行目しか流さない・#1343)。
    private func namesTheDrop(_ failure: RenderFailure?) -> Bool {
        failure == .workDropped(reason: Self.victim) && failure?.headline.contains(Self.victim) == true
    }

    // MARK: - 4 つの口が投げる

    @Test("描画が打ち切られた後の readPixels() は、絵を返さずに打ち切りを名乗って投げる")
    func readPixelsThrowsForADroppedDrawing() throws {
        let gpu = try RenderDevice()
        let canvas = try makeCanvas(gpu)
        try paint(canvas, Self.red)
        _ = try canvas.output.readPixels()

        gpu.dropsNextSubmissionForTesting = Self.victim
        try paint(canvas, Self.blue)
        let failure = #expect(throws: RenderFailure.self) { _ = try canvas.output.readPixels() }
        #expect(namesTheDrop(failure), "名乗りが違う: \(String(describing: failure))")
    }

    @Test("描画が打ち切られた後の encodeForDisplay() と writePNG() は投げ、ファイルを書かない")
    func displayReadsThrowForADroppedDrawing() throws {
        let gpu = try RenderDevice()
        let canvas = try makeCanvas(gpu)
        try paint(canvas, Self.red)
        _ = try canvas.output.encodeForDisplay()

        gpu.dropsNextSubmissionForTesting = Self.victim
        try paint(canvas, Self.blue)
        let failure = #expect(throws: RenderFailure.self) { _ = try canvas.output.encodeForDisplay() }
        #expect(namesTheDrop(failure), "名乗りが違う: \(String(describing: failure))")

        let url = temporaryPNG()
        let written = #expect(throws: RenderFailure.self) { try canvas.output.writePNG(to: url) }
        #expect(namesTheDrop(written), "名乗りが違う: \(String(describing: written))")
        #expect(!FileManager.default.fileExists(atPath: url.path), "打ち切られた絵を書き出した")
    }

    /// フレームごとに青で塗るだけのスケッチ。
    final class Blue: Sketch {
        var settings: SketchSettings { SketchSettings(width: 16, height: 16) }
        func draw() { background(0, 0, 255) }
    }

    @Test("フレームの描画が打ち切られた renderFrame(to:) は投げ、ファイルを書かない。次のフレームは書ける")
    func renderFrameThrowsForADroppedFrame() throws {
        let gpu = try RenderDevice()
        let runtime = try SketchRuntime(sketch: Blue(), gpu: gpu)
        let first = temporaryPNG()
        let second = temporaryPNG()
        let third = temporaryPNG()
        defer { for url in [first, second, third] { try? FileManager.default.removeItem(at: url) } }
        try runtime.renderFrame(to: first)

        gpu.dropsNextSubmissionForTesting = Self.victim
        let failure = #expect(throws: RenderFailure.self) { try runtime.renderFrame(to: second) }
        #expect(namesTheDrop(failure), "名乗りが違う: \(String(describing: failure))")
        #expect(!FileManager.default.fileExists(atPath: second.path), "打ち切られたフレームを書き出した")

        // 次のフレームは新しく描くので、打ち切りは範囲の外になる
        try runtime.renderFrame(to: third)
        #expect(FileManager.default.fileExists(atPath: third.path))
    }

    // MARK: - 読みが自分で積んだ投入

    /// 読み戻しだけが打ち切られたなら、面の中身は無事である。投げた後の読みは読み戻しから積み直す。
    @Test("readPixels() の読み戻しが打ち切られると投げ、次の読みは読み戻しを積み直して今の絵を返す")
    func aDroppedReadbackIsReadAgain() throws {
        let gpu = try RenderDevice()
        let canvas = try makeCanvas(gpu)
        try paint(canvas, Self.blue)

        gpu.dropsNextSubmissionForTesting = Self.victim
        let readbacks = canvas.output.pixelReadbacksEncoded
        let failure = #expect(throws: RenderFailure.self) { _ = try canvas.output.readPixels() }
        #expect(namesTheDrop(failure), "名乗りが違う: \(String(describing: failure))")
        #expect(canvas.output.pixelReadbacksEncoded == readbacks + 1, "打ち切られたのが読み戻しでない")

        // 打ち切られた読み戻しの写しを「映した」まま返すと、ここが前の中身になる
        let again = try canvas.output.readPixels()
        #expect(canvas.output.pixelReadbacksEncoded == readbacks + 2, "読み戻しを積み直していない")
        #expect(again[4, 4].blue == 1 && again[4, 4].red == 0)
    }

    @Test("encodeForDisplay() の出力段が打ち切られると投げ、次の読みは組み直して今の絵を返す")
    func aDroppedOutputPassIsComposedAgain() throws {
        let gpu = try RenderDevice()
        let canvas = try makeCanvas(gpu)
        try paint(canvas, Self.blue)

        gpu.dropsNextSubmissionForTesting = Self.victim
        let failure = #expect(throws: RenderFailure.self) { _ = try canvas.output.encodeForDisplay() }
        #expect(namesTheDrop(failure), "名乗りが違う: \(String(describing: failure))")

        let again = try canvas.output.encodeForDisplay()[4, 4]
        #expect(again.blue == 255 && again.red == 0)
    }

    // MARK: - 投げた後の読み (完了条件 3)

    @Test("描画の打ち切りで投げた後は、この面へ書く新しい投入が無い限り何度読んでも投げ、何も積まない")
    func aDroppedDrawingStaysRefusedUntilSomethingNewIsSubmitted() throws {
        let gpu = try RenderDevice()
        let canvas = try makeCanvas(gpu)
        try paint(canvas, Self.red)
        _ = try canvas.output.readPixels()
        gpu.dropsNextSubmissionForTesting = Self.victim
        try paint(canvas, Self.blue)
        #expect(throws: RenderFailure.workDropped(reason: Self.victim)) { _ = try canvas.output.readPixels() }

        let submitted = gpu.submissionCount
        #expect(throws: RenderFailure.workDropped(reason: Self.victim)) { _ = try canvas.output.readPixels() }
        #expect(throws: RenderFailure.workDropped(reason: Self.victim)) {
            _ = try canvas.output.encodeForDisplay()
        }
        #expect(gpu.submissionCount == submitted, "断るだけの読みが投入を積んだ")

        // 新しく描けば、その描画が範囲になる。前の打ち切りは範囲の外
        try paint(canvas, Self.red)
        let read = try canvas.output.readPixels()
        #expect(read[4, 4].red == 1 && read[4, 4].blue == 0)
    }

    /// この面の中身を変えない投入 (投げない口の読み戻し・出口へ渡す出力段・何も描かない描き切り・
    /// 別の面への描画) を「新しい投入」に数えると、打ち切られた中身が次の投げる読みで成功として返る
    /// (#1932 の反証 2)。
    @Test("投げた後に、この面を書き換えない投入が積まれても、投げる口は断り続ける")
    func submissionsThatDoNotWriteTheSurfaceDoNotLiftTheRefusal() throws {
        let gpu = try RenderDevice()
        let canvas = try makeCanvas(gpu)
        let other = try makeCanvas(gpu)
        try paint(canvas, Self.red)
        _ = try canvas.output.readPixels()
        gpu.dropsNextSubmissionForTesting = Self.victim
        try paint(canvas, Self.blue)
        #expect(throws: RenderFailure.workDropped(reason: Self.victim)) { _ = try canvas.output.readPixels() }

        let submitted = gpu.submissionCount
        // 投げない口が積む読み戻しと出力段
        _ = canvas.output.pixels
        _ = try canvas.output.encodeToImage().read()
        // 描き場所の読む口 (何も描いていないので、描き切りは読み戻しだけを積む)
        canvas.loadPixels()
        _ = canvas.get(4, 4)
        _ = canvas.pixels
        // 何も描かないフレームと、別の面への描画
        try canvas.draw {}
        try paint(other, Self.red)
        #expect(gpu.submissionCount > submitted, "この面を書き換えない投入が 1 本も積まれていない")
        #expect(throws: RenderFailure.workDropped(reason: Self.victim)) { _ = try canvas.output.readPixels() }
        #expect(throws: RenderFailure.workDropped(reason: Self.victim)) {
            _ = try canvas.output.encodeForDisplay()
        }
    }

    /// 打ち切られたのが面を書き換えない投入 (別の読む口の読み戻し・出口の出力段・何も描かない描き切り)
    /// だけなら、面の中身は無事である。範囲に入った読みは 1 回投げるが、持ち越さない (#1932 の反証 3)。
    @Test("面を書き換えない投入の打ち切りでは、範囲に入った読みが 1 回投げるだけで、次の読みは今の絵を返す",
        arguments: ["読み戻し", "出力段", "何も描かない描き切り"])
    func dropsOfSubmissionsThatDoNotWriteTheSurfaceAreNotHeld(kind: String) throws {
        let gpu = try RenderDevice()
        let canvas = try makeCanvas(gpu)
        try paint(canvas, Self.red)
        _ = try canvas.output.readPixels()
        // 写しを古くしておく。投げない口が読み戻しを積むように
        try paint(canvas, Self.blue)

        gpu.dropsNextSubmissionForTesting = Self.victim
        switch kind {
        case "読み戻し": _ = canvas.output.pixels
        case "出力段": _ = try canvas.output.encodeToImage().read()
        default: canvas.loadPixels()
        }
        let failure = #expect(throws: RenderFailure.self) { _ = try canvas.output.readPixels() }
        #expect(namesTheDrop(failure), "名乗りが違う: \(String(describing: failure))")

        let again = try canvas.output.readPixels()
        #expect(again[4, 4].blue == 1 && again[4, 4].red == 0)
        #expect(try canvas.output.encodeForDisplay()[4, 4].blue == 255)
    }

    /// **CPU が書いた画素の唯一の写しを、判定が捨てない** (#1932 の反証 1)。書き戻しが打ち切られると
    /// 書いた画素は面へ届かず、写しにしか残らない。写しの「映した」を下ろすと、次の読み戻しがそれを
    /// 面の中身で上書きして失う。
    @Test("CPU が書いた画素の書き戻しが打ち切られても、書いた画素は失われず、次に描くときに面へ届く")
    func pixelsWhoseWriteBackWasDroppedAreWrittenBackAgain() throws {
        let gpu = try RenderDevice()
        let canvas = try makeCanvas(gpu)
        try paint(canvas, Self.red)
        _ = try canvas.output.readPixels()

        try canvas.draw {
            canvas.set(4, 4, Self.blue)
            // 次の投入は、このフレームの終わりの描き切り (書いた画素の書き戻し)
            gpu.dropsNextSubmissionForTesting = Self.victim
        }
        #expect(throws: RenderFailure.workDropped(reason: Self.victim)) { _ = try canvas.output.readPixels() }

        // 差し込みは結末だけを打ち切りにし、GPU の書き戻しそのものは走る。だから絵ではなく、書いた
        // 画素が写しに残って書き込み待ちへ戻ったことを見る
        #expect(canvas.output.hasPendingPixelWrites, "書いた画素を書き込み待ちへ戻していない")
        let mirrored = try #require(canvas.output.pixelMirror)
        let blue = Pixels(
            base: mirrored.storage.contents(), width: 16, height: 16,
            bytesPerRow: mirrored.bytesPerRow, mirror: mirrored)[4, 4]
        #expect(blue.blue == 1 && blue.red == 0, "写しの書いた画素が読み戻しで上書きされた: \(blue)")

        // (4, 4) には触れずに描き足す。この描き切りが、書いた画素を書き戻し直す
        let writeBacks = canvas.output.pixelWriteBacksEncoded
        try canvas.draw {
            canvas.noStroke()
            canvas.fill(Self.blue)
            canvas.rect(12, 12, 2, 2)
        }
        #expect(canvas.output.pixelWriteBacksEncoded == writeBacks + 1, "書き戻し直していない")
        let read = try canvas.output.readPixels()
        #expect(read[4, 4].blue == 1 && read[4, 4].red == 0, "書いた画素が失われた: \(read[4, 4])")
        #expect(read[0, 0].red == 1, "描いていない所が変わった")
    }

    // MARK: - 結末の知らせが欠けたとき (#1932 の反証 8・9)

    @Test("結末の知らせが欠けた投入は、待つ上限で打ち切りとして名乗り、以後の読みはそこで止まらない")
    func aLostOutcomeIsNamedOnceAndDoesNotStallLaterReads() throws {
        let gpu = try RenderDevice()
        gpu.outcomeWaitLimit = .milliseconds(200)
        let canvas = try makeCanvas(gpu)
        try paint(canvas, Self.red)
        _ = try canvas.output.readPixels()

        gpu.losesNextOutcomeForTesting = true
        try paint(canvas, Self.blue)
        let failure = #expect(throws: RenderFailure.self) { _ = try canvas.output.readPixels() }
        let reason = CommandFaultLog.lostReason(after: gpu.outcomeWaitLimit)
        #expect(failure == .workDropped(reason: reason), "名乗りが違う: \(String(describing: failure))")
        // 合図は届いているので、「描きすぎ」へ送らない
        #expect(failure?.description.contains("drawing too much") == false)

        // 欠けた番号で止まっていれば、次の読みも上限まで待って同じく投げる
        try paint(canvas, Self.red)
        let waits = gpu.outcomeWaits
        let read = try canvas.output.readPixels()
        #expect(read[4, 4].red == 1)
        #expect(gpu.outcomeWaits - waits <= 1)
    }

    // MARK: - 観測の撮影 (#1932 の反証 4)

    /// 揃わなかった目録は `image` を落とす — 読み手はこの鍵の有無だけで成否を言える (ADR-0018 決定 3)。
    @Test("観測の撮影は、打ち切られたフレームの絵を撮らず、揃わなかった目録に理由を載せる")
    func observationDoesNotCaptureADroppedFrame() throws {
        let facet = FileManager.default.temporaryDirectory
            .appendingPathComponent("mokume-dropped-observe-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: facet, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: facet) }
        let gpu = try RenderDevice()
        let runtime = try SketchRuntime(
            sketch: Blue(), gpu: gpu, clock: nil, now: { 0 }, observer: FrameObserver(directory: facet))
        try runtime.advance()

        try AtomicFile.write(
            Data(#"{"id":"dropped"}"#.utf8), to: facet.appendingPathComponent("request.json"))
        gpu.dropsNextSubmissionForTesting = Self.victim
        try runtime.advance()

        let data = try Data(contentsOf: facet.appendingPathComponent("report.json"))
        let report = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
        #expect(report["id"] as? String == "dropped")
        #expect(report["image"] as? String == nil, "打ち切られたフレームの絵を撮った")
        #expect((report["frames"] as? [Any])?.isEmpty == true, "打ち切られたフレームの絵を目録に載せた")
        let warnings = report["warnings"] as? [String] ?? []
        #expect(warnings.contains { $0.contains(Self.victim) }, "理由が警告に無い: \(warnings)")
    }

    // MARK: - 範囲

    @Test("前の判定の後に描き直せば、それより前の打ち切りでは投げない")
    func dropsBeforeTheLastJudgedReadAreOutOfRange() throws {
        let gpu = try RenderDevice()
        let canvas = try makeCanvas(gpu)
        gpu.dropsNextSubmissionForTesting = Self.victim
        try paint(canvas, Self.red)
        #expect(throws: RenderFailure.workDropped(reason: Self.victim)) {
            _ = try canvas.output.encodeForDisplay()
        }
        try paint(canvas, Self.blue)
        let read = try canvas.output.readPixels()
        #expect(read[4, 4].blue == 1)
        #expect(gpu.commandFaultCount == 1, "打ち切りの記録が 1 つでない — 前提が崩れている")
    }

    @Test("面を作る前に土台で打ち切られた投入では、その面の読みは投げない")
    func dropsBeforeTheSurfaceExistedAreOutOfRange() throws {
        let gpu = try RenderDevice()
        let earlier = try makeCanvas(gpu)
        gpu.dropsNextSubmissionForTesting = Self.victim
        try paint(earlier, Self.red)

        let later = try makeCanvas(gpu)
        try paint(later, Self.blue)
        let read = try later.output.readPixels()
        #expect(read[4, 4].blue == 1)
        // 同じ打ち切りは、前からあった面の読みでは範囲に入る
        #expect(throws: RenderFailure.workDropped(reason: Self.victim)) { _ = try earlier.output.readPixels() }
    }

    /// **範囲を土台の全投入にした選択を留める。** 面へ書く投入に絞ると、置いた別の描き場所の
    /// 描画のように、絵が依存するのに面へは書かない投入の打ち切りが黙った成功になる。
    @Test("同じ土台の別の面への投入が範囲の中で打ち切られても投げる")
    func dropsOnAnotherSurfaceOfTheSameDeviceAreInRange() throws {
        let gpu = try RenderDevice()
        let canvas = try makeCanvas(gpu)
        let other = try makeCanvas(gpu)
        try paint(canvas, Self.red)
        _ = try canvas.output.readPixels()

        gpu.dropsNextSubmissionForTesting = Self.victim
        try paint(other, Self.blue)
        #expect(throws: RenderFailure.workDropped(reason: Self.victim)) { _ = try canvas.output.readPixels() }
    }

    /// 土台の記録だけを作る差し込み (`recordCommandFaultForTesting`) は番号を持たない。
    /// 表明の文面で名乗る口 (`faultNote()`) の検査がそれを使うので、読む口を巻き込まない。
    @Test("番号を持たない打ち切りの記録では、投げる口は投げない")
    func unnumberedFaultRecordsDoNotReachTheReaders() throws {
        let gpu = try RenderDevice()
        let canvas = try makeCanvas(gpu)
        gpu.recordCommandFaultForTesting(Self.victim)
        try paint(canvas, Self.blue)
        #expect(try canvas.output.readPixels()[4, 4].blue == 1)
        #expect(try canvas.output.encodeForDisplay()[4, 4].blue == 255)
    }

    // MARK: - 正常系

    @Test("打ち切りが無ければ絵を返し、結末の待ちは読み 1 回につき高々 1 回で、変わらない面の読み直しは何も積まず待たない")
    func undroppedReadsReturnThePictureAndWaitAtMostOnce() throws {
        let gpu = try RenderDevice()
        let canvas = try makeCanvas(gpu)
        try paint(canvas, Self.blue)

        var waits = gpu.outcomeWaits
        let read = try canvas.output.readPixels()
        #expect(read[4, 4].blue == 1 && read[4, 4].red == 0)
        #expect(gpu.outcomeWaits - waits <= 1)

        // 変わらない面を読み直す。写しは映したままなので、積むものも待つものも無い
        let submitted = gpu.submissionCount
        let blocking = gpu.blockingWaits
        waits = gpu.outcomeWaits
        #expect(try canvas.output.readPixels() == read)
        #expect(gpu.submissionCount == submitted)
        #expect(gpu.blockingWaits == blocking)
        #expect(gpu.outcomeWaits == waits)

        waits = gpu.outcomeWaits
        let shown = try canvas.output.encodeForDisplay()[4, 4]
        #expect(shown.blue == 255 && shown.red == 0)
        #expect(gpu.outcomeWaits - waits <= 1)
    }
}
