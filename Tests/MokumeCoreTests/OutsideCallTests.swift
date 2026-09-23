// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation
import Testing

@testable import MokumeCore

/// 呼び出しの外から頼まれたときに言う 6 通を、**実装とは別の場所に写して突き合わせる**。
///
/// 以前の断りは「the sketch is not running」と言っていた。`draw()` が回り続けている最中に
/// `Task` から頼むとこれが出て、呼ぶ側は「起動に失敗したのか」「もう終わったのか」を
/// 疑うことになる ([#1322])。本当に走っていない場合 (`init` から・終わった後) とは
/// 見分けられないので、どちらでも事実と食い違わない「どこからなら受け付けるか」を言う。
///
/// [#1322]: https://github.com/mokume-metal/mokume/issues/1322
private let outsideCallNotices: [OutsideCall: String] = [
    .noLoop:
        "noLoop() is only accepted from inside setup(), draw() or an input callback such as "
            + "mousePressed(). This call was made from outside them, so it was ignored. A Task "
            + "started in one of them runs after it returns, and counts as outside",
    .loop:
        "loop() is only accepted from inside setup(), draw() or an input callback such as "
            + "mousePressed(). This call was made from outside them, so it was ignored. A Task "
            + "started in one of them runs after it returns, and counts as outside",
    .redraw:
        "redraw() is only accepted from inside setup(), draw() or an input callback such as "
            + "mousePressed(). This call was made from outside them, so it was ignored. A Task "
            + "started in one of them runs after it returns, and counts as outside",
    .save:
        "save() is only accepted from inside setup(), draw() or an input callback such as "
            + "keyPressed(). This call was made from outside them, so nothing was saved. A Task "
            + "started in one of them runs after it returns, and counts as outside",
    .beginRecord:
        "beginRecord() is only accepted from inside setup(), draw() or an input callback such as "
            + "keyPressed(). This call was made from outside them, so recording did not start. "
            + "A Task started in one of them runs after it returns, and counts as outside",
    .endRecord:
        "endRecord() is only accepted from inside setup(), draw() or an input callback such as "
            + "keyPressed(). This call was made from outside them, so no recording was stopped. "
            + "A Task started in one of them runs after it returns, and counts as outside",
]

/// 文面そのものの検査。**GPU は要らない** ので、GPU の無い環境でも走る。
@Suite("呼び出しの外から頼んだときの文面")
struct OutsideCallNoticeTests {
    @Test("6 つとも原文のまま")
    func noticesKeepTheirWording() {
        for (call, original) in outsideCallNotices {
            #expect(call.notice == original, "\(call) の文面が変わっている")
        }
    }

    @Test("種類を足したら、原文も足すことになる")
    func everyCallHasAnOriginal() {
        for call in OutsideCall.allCases {
            #expect(outsideCallNotices[call] != nil, "\(call) の原文が検査に無い")
        }
    }

    /// 原文を書き換えるときに、元の取り違えへ戻らないための検査。上の 2 つは「写しと
    /// 一致するか」しか見ないので、写しごと書き換えれば通ってしまう。
    @Test("走っていないとは言わず、受け付ける場所と Task を名指す")
    func noticesNameWhereToCallFrom() {
        for call in OutsideCall.allCases {
            let notice = call.notice
            #expect(!notice.contains("not running"), "\(call): \(notice)")
            #expect(notice.contains("setup()"), "\(call): \(notice)")
            #expect(notice.contains("draw()"), "\(call): \(notice)")
            #expect(notice.contains("Task"), "\(call): \(notice)")
        }
    }
}

/// **断る振る舞いは変えない。** `draw()` で起こした `Task` から頼んでも、進行も書き出しも
/// 動かない。GPU を要する。
///
/// **呼んだ時点で差し込みが外れていたことを、検査が自分で確かめる** (`RequestFromTaskTests`
/// と同じ形)。これが無いと、何かの拍子に差し込みが残ったまま呼ばれる形になっても緑の
/// ままで、断る経路を通っていないことに気付けない。
@Suite(
    "呼び出しの外から頼んでも効かない",
    .enabled(
        if: RenderDevice.isAvailable,
        "この世代のコマンド構造に対応した GPU が無い実行環境ではスキップする")
)
struct OutsideCallTests {
    /// 最初の `draw()` で `Task` を起こし、その中で頼むスケッチ。
    final class Asking: Sketch {
        var settings = SketchSettings(width: 8, height: 4)
        /// `setup()` で止めるか。
        var stopsInSetup = true
        /// `Task` の中で頼むもの。
        var ask: ((Asking) -> Void)?
        /// 起こした `Task`。検査はこれを待ってから、効いたかを見る。
        var asking: Task<Void, Never>?
        /// 頼んだ時点で、差し込み (``runningSketch``) が外れていたか。
        var detachedWhenCalled: [Bool] = []
        var drawCalls = 0

        init() {}
        func setup() {
            if stopsInSetup { noLoop() }
        }
        func draw() {
            drawCalls += 1
            background(0)
            guard asking == nil, let ask else { return }
            asking = Task {
                detachedWhenCalled.append(runningSketch == nil)
                ask(self)
            }
        }
    }

    private func makeRuntime(_ sketch: Asking) throws -> SketchRuntime {
        try SketchRuntime(sketch: sketch, gpu: RenderDevice())
    }

    /// 最初のフレームを描き、そこで起こした `Task` が頼み終えるまで待つ。
    private func drawOnceAndWaitForTheAsk(_ sketch: Asking, _ runtime: SketchRuntime) async throws {
        try runtime.advance()
        #expect(sketch.drawCalls == 1)
        await sketch.asking?.value
        // 断る経路を、実際に通っている
        #expect(sketch.detachedWhenCalled == [true])
    }

    @Test("noLoop() で止めたスケッチに Task から redraw() を頼んでも、draw() は増えない")
    func redrawFromATaskDoesNotDraw() async throws {
        let sketch = Asking()
        sketch.ask = { $0.redraw() }
        let runtime = try makeRuntime(sketch)
        try await drawOnceAndWaitForTheAsk(sketch, runtime)

        for _ in 0..<3 { try runtime.advance() }
        #expect(sketch.drawCalls == 1)
    }

    @Test("noLoop() で止めたスケッチに Task から loop() を頼んでも、回り出さない")
    func loopFromATaskDoesNotResume() async throws {
        let sketch = Asking()
        sketch.ask = { $0.loop() }
        let runtime = try makeRuntime(sketch)
        try await drawOnceAndWaitForTheAsk(sketch, runtime)

        for _ in 0..<3 { try runtime.advance() }
        #expect(sketch.drawCalls == 1)
    }

    @Test("回っているスケッチに Task から noLoop() を頼んでも、止まらない")
    func noLoopFromATaskDoesNotStop() async throws {
        let sketch = Asking()
        sketch.stopsInSetup = false
        sketch.ask = { $0.noLoop() }
        let runtime = try makeRuntime(sketch)
        try await drawOnceAndWaitForTheAsk(sketch, runtime)

        for _ in 0..<3 { try runtime.advance() }
        #expect(sketch.drawCalls == 4)
    }

    @Test("Task から頼んだ save() は、終わらせてもファイルにならない")
    func saveFromATaskWritesNothing() async throws {
        let out = FileManager.default.temporaryDirectory
            .appendingPathComponent("mokume-outside-call-\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: out) }
        let sketch = Asking()
        sketch.ask = { $0.save(out.path) }
        let runtime = try makeRuntime(sketch)
        try await drawOnceAndWaitForTheAsk(sketch, runtime)

        try runtime.advance()
        // 終わりの経路は、頼まれたまま書かれていない分を書き切る最後の受け皿である
        // (`LoopTests` の「次の advance() が無くても終わりまでに書かれる」)。そこでも出ない
        runtime.closePlugins()
        #expect(!FileManager.default.fileExists(atPath: out.path))
    }
}
