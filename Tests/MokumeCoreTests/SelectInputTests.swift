// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import AppKit
import Foundation
import IOSurface
import Testing

@testable import MokumeCore

/// ファイルを選ばせるダイアログ (`selectInput`) の結果を、入力の出来事 `fileSelected` として受ける
/// ([#3062](https://github.com/mokume-metal/mokume/issues/3062))。
///
/// 外から送る線・待ちの管理・合流点・面の属性を固める。本物の `NSOpenPanel` は人の操作を待つので、
/// ``FakeFilePicker`` に差し替えて、頼みが出る・結果が戻るところまでを見る。ダイアログが道具の窓の前に
/// 出るかは人の手 (PR 本文の「確認してほしい点」)。
/// 条件が満たされるまで、期限つきで待つ。**`Task` が走る順は他の検査と重なると変わる**ので、`yield` の回数に頼らない。
@MainActor
func eventually(_ seconds: Double = 5, _ condition: () -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + .seconds(seconds)
    while !condition(), ContinuousClock.now < deadline {
        try? await Task.sleep(for: .milliseconds(5))
    }
    return condition()
}

@MainActor
final class FakeFilePicker: FilePicker {
    struct Shown {
        let prompt: String
        let completion: @MainActor (String?) -> Void
        var dismissed = false
    }

    private(set) var shown: [Shown] = []
    /// 閉じるように言われた数。
    private(set) var dismissals = 0

    func pick(
        prompt: String, over window: NSWindow?, completion: @escaping @MainActor (String?) -> Void
    ) -> @MainActor () -> Void {
        let index = shown.count
        shown.append(Shown(prompt: prompt, completion: completion))
        return { [self] in
            shown[index].dismissed = true
            dismissals += 1
        }
    }

    /// 利用者が答えたことにする。閉じられた後の答えは届かない (本物と同じ)。
    func answer(_ index: Int, _ path: String?) {
        guard shown.indices.contains(index) else {
            Issue.record("\(index) 枚目のダイアログは出ていない (出た数: \(shown.count))")
            return
        }
        guard !shown[index].dismissed else { return }
        shown[index].completion(path)
    }
}

@Suite("ファイルを選ばせる: 線")
struct SelectInputWireTests {
    private func decode(_ json: String) throws -> RawInputEvent {
        try JSONDecoder().decode(RawInputEvent.self, from: Data(json.utf8))
    }

    @Test("選んだ結果も取り消しも、線へ書いて読み戻すと同じ出来事になる")
    func theResultSurvivesTheWire() throws {
        for event in [
            InputEvent.fileSelected(path: "/tmp/a.csv"),
            .fileSelected(path: "/tmp/he said \"hi\" 日本語.csv"),
            .fileSelected(path: nil),
            .fileSelected(path: "/tmp/a.csv", serial: 3),
            .fileSelected(path: nil, serial: 12),
        ] {
            #expect(try decode(event.wireLine).event == event, "\(event)")
            #expect(event.wireLine.filter { $0 == "\n" }.count == 1)
        }
        #expect(InputEvent.fileSelected(path: nil).wireLine.contains(#""paths":[]"#), "取り消しは空の配列")
        #expect(InputEvent.fileSelected(path: nil).wireType == .fileSelected)
        #expect(!InputEvent.fileSelected(path: nil).wireLine.contains("serial"), "番号なしの結果に番号を書いた")
        #expect(InputEvent.fileSelected(path: nil, serial: 4).wireLine.contains(#""serial":4"#))
    }

    @Test("頼みの番号 serial は省ける。載せるなら正の整数で、fileSelected でだけ読む")
    func theSerialIsOptionalAndPositive() throws {
        #expect(
            try decode(#"{"type": "fileSelected", "paths": ["/tmp/a.csv"], "serial": 2}"#).event
                == .fileSelected(path: "/tmp/a.csv", serial: 2))
        #expect(
            try decode(#"{"type": "fileSelected", "paths": [], "serial": null}"#).event
                == .fileSelected(path: nil, serial: nil), "null は省いたのと同じ")
        // 0 や負の番号は頼みの番号ではない。番号なしと読むと、狙った待ちではない待ちを終えうる
        for serial in ["0", "-1"] {
            #expect(
                try decode(#"{"type": "fileSelected", "paths": [], "serial": \#(serial)}"#).event
                    == nil, "serial \(serial)")
        }
        #expect(throws: DecodingError.self) {
            try decode(#"{"type": "fileSelected", "paths": [], "serial": 1.5}"#)
        }
        #expect(RawInputEvent.readKeys(forType: "fileSelected").contains("serial"))
        #expect(!RawInputEvent.readKeys(forType: "fileDropped").contains("serial"))
        #expect(!RawInputEvent.readKeys(forType: "mouseUp").contains("serial"))
    }

    @Test("外から送る形 {type, paths} が読める。空の配列は取り消し")
    func theDocumentedShapesAreRead() throws {
        #expect(
            try decode(#"{"type": "fileSelected", "paths": ["/tmp/a.csv"]}"#).event
                == .fileSelected(path: "/tmp/a.csv"))
        #expect(try decode(#"{"type": "fileSelected", "paths": []}"#).event == .fileSelected(path: nil))
    }

    @Test("paths の無い・null の結果は、取り消しと読まず、読めない 1 件にする")
    func aMissingPathsIsNotACancel() throws {
        #expect(try decode(#"{"type": "fileSelected"}"#).event == nil)
        #expect(try decode(#"{"type": "fileSelected", "paths": null}"#).event == nil)
    }

    @Test("2 本以上の結果と、絶対パスでない要素は、読めない 1 件にする (先頭の 1 本を黙って取らない)")
    func unreadableResults() throws {
        #expect(
            try decode(#"{"type": "fileSelected", "paths": ["/tmp/a.csv", "/tmp/b.csv"]}"#).event == nil)
        for element in [#""""#, #""https://example.com/a.csv""#, #""a/b.csv""#] {
            #expect(try decode(#"{"type": "fileSelected", "paths": [\#(element)]}"#).event == nil)
        }
        #expect(throws: DecodingError.self) {
            try decode(#"{"type": "fileSelected", "paths": [3]}"#)
        }
    }

    @Test("paths は fileDropped と fileSelected でだけ読む。取り消しの空の配列は fileDropped では読めない")
    func pathsAreReadOnTheTwoTypes() throws {
        #expect(RawInputEvent.readKeys(forType: "fileSelected").contains("paths"))
        #expect(!RawInputEvent.readKeys(forType: "fileSelected").contains("amount"))
        #expect(!RawInputEvent.readKeys(forType: "mouseUp").contains("paths"))
        #expect(try decode(#"{"type": "fileDropped", "paths": [], "x": 1, "y": 2}"#).event == nil)
    }
}

@Suite("ファイルを選ばせる: 待ち")
@MainActor
struct SelectionBrokerTests {
    /// 待ちの結果を控える箱。**`await task.value` で待たない** — 壊れた待ちは返らず、検査が固まって赤にならない。
    @MainActor final class Outcome {
        var value: String??
    }

    private func ask(_ broker: SelectionBroker, _ prompt: String) -> Outcome {
        let outcome = Outcome()
        Task { outcome.value = .some(await broker.request(prompt)) }
        return outcome
    }

    @Test("頼むと待ちが立ち、結果で終わる。取り消しは nil")
    func aRequestWaitsForItsResult() async {
        let broker = SelectionBroker()
        #expect(!broker.isAwaiting && broker.pending == nil)
        let first = ask(broker, "pick")
        #expect(await eventually { broker.isAwaiting })
        #expect(broker.pending == SelectionBroker.Request(serial: 1, prompt: "pick"))
        #expect(first.value == nil, "結果が来ないうちに戻った")
        #expect(broker.resolve("/tmp/a.csv"))
        #expect(await eventually { first.value != nil })
        #expect(first.value == .some("/tmp/a.csv"))
        #expect(!broker.isAwaiting && broker.pending == nil, "終わった待ちの頼みが残っている")

        let second = ask(broker, "again")
        #expect(await eventually { broker.pending?.serial == 2 }, "通し番号が進まない")
        #expect(broker.resolve(nil))
        #expect(await eventually { second.value != nil })
        #expect(second.value == .some(nil))
    }

    @Test("待っていないときの結果は、何も終えない")
    func aResultWithoutAWaitDoesNothing() {
        let broker = SelectionBroker()
        #expect(!broker.resolve("/tmp/a.csv"))
    }

    @Test("番号つきの結果は、番号が同じ待ちだけを終える。違う番号は何も終えない")
    func aNumberedResultEndsOnlyItsOwnWait() async {
        let broker = SelectionBroker()
        let first = ask(broker, "one")
        #expect(await eventually { broker.pending?.serial == 1 })
        let second = ask(broker, "two")
        #expect(await eventually { broker.pending?.serial == 2 })
        #expect(await eventually { first.value != nil })
        // 1 番への古い答えは、2 番の待ちを終えない
        #expect(!broker.resolve("/tmp/old.csv", serial: 1))
        #expect(broker.isAwaiting && second.value == nil, "古い番号の答えが新しい待ちを終えた")
        // 番号なし (外から) は今の待ちへ、番号が合えば終わる
        #expect(broker.resolve("/tmp/new.csv", serial: 2))
        #expect(await eventually { second.value != nil })
        #expect(second.value == .some("/tmp/new.csv"))
        // 終わった待ちの番号の送り直しは、何も終えない
        #expect(!broker.resolve("/tmp/new.csv", serial: 2))
    }

    @Test("実行が終わると、待ちは nil で終わり、その後の頼みは待たずに nil を返す")
    func endingTheRunEndsTheWaitAndRefusesTheNext() async {
        let broker = SelectionBroker()
        let waiting = ask(broker, "one")
        #expect(await eventually { broker.isAwaiting })
        broker.end()
        #expect(await eventually { waiting.value != nil }, "実行が終わっても待ちが終わらない")
        #expect(waiting.value == .some(nil))
        #expect(broker.isEnded && broker.pending == nil)
        let after = ask(broker, "two")
        #expect(await eventually { after.value != nil }, "終わった実行で頼むと待たされる")
        #expect(after.value == .some(nil))
        #expect(!broker.isAwaiting)
    }

    @Test("待ちの最中にもう 1 度頼むと、前の待ちは nil で終わり、新しい頼みが立つ")
    func aSecondRequestEndsTheFirstWithNil() async {
        let broker = SelectionBroker()
        let first = ask(broker, "one")
        #expect(await eventually { broker.isAwaiting })
        let second = ask(broker, "two")
        #expect(await eventually { broker.pending?.serial == 2 })
        #expect(await eventually { first.value != nil }, "前の待ちが終わらない")
        #expect(first.value == .some(nil))
        #expect(broker.pending == SelectionBroker.Request(serial: 2, prompt: "two"))
        #expect(broker.resolve("/tmp/b.csv"))
        #expect(await eventually { second.value != nil })
        #expect(second.value == .some("/tmp/b.csv"), "結果が前の待ちへ渡った")
    }
}

@Suite("ファイルを選ばせる: 合流点")
@MainActor
struct SelectInputInputTests {
    private func run(_ state: InputState, _ events: [InputEvent]) -> [InputCallback] {
        for event in events { state.enqueue(event) }
        var seen: [InputCallback] = []
        state.beginFrame { seen.append($0) }
        return seen
    }

    @Test("待っていれば結果を配り、待っていなければ配らずに 1 度だけ言う")
    func aResultIsDeliveredOnlyToAWait() async {
        let state = InputState()
        let unawaited = run(state, [.fileSelected(path: "/tmp/a.csv"), .fileSelected(path: nil)])
        #expect(unawaited.isEmpty, "待っていないのに配った: \(unawaited)")
        #expect(state.warnings.message(for: .unawaitedSelection) != nil)

        let waiting = Task { await state.selection.request("pick") }
        #expect(await eventually { state.selection.isAwaiting })
        let awaited = run(state, [.fileSelected(path: "/tmp/a.csv")])
        #expect(awaited == [.fileSelected(path: "/tmp/a.csv", serial: nil)])
        waiting.cancel()
    }

    @Test("番号つきの結果は、いまの待ちの番号と同じときだけ配る。違う番号と送り直しは黙って捨てる")
    func aNumberedResultIsDeliveredOnlyToItsOwnWait() async {
        let state = InputState()
        // 待ちが無いときの番号つき (送り直しの遅れ) は、警告にしない
        #expect(run(state, [.fileSelected(path: "/tmp/a.csv", serial: 1)]).isEmpty)
        #expect(state.warnings.message(for: .unawaitedSelection) == nil, "送り直しを警告にした")

        let first = Task { await state.selection.request("one") }
        #expect(await eventually { state.selection.pending?.serial == 1 })
        // 1 番の答えが溜まりにある間に頼み直す
        state.enqueue(.fileSelected(path: "/tmp/old.csv", serial: 1))
        let second = Task { await state.selection.request("two") }
        #expect(await eventually { state.selection.pending?.serial == 2 })
        var seen: [InputCallback] = []
        state.beginFrame { seen.append($0) }
        #expect(seen.isEmpty, "古い答えが新しい待ちを終えた: \(seen)")
        #expect(state.selection.isAwaiting)
        #expect(state.warnings.message(for: .unawaitedSelection) == nil)

        // 2 番の答えは終え、同じ答えの送り直しは (待ちが終わった後なので) 配らず、警告もしない
        // (配り先 `SketchRuntime` と同じに、配られた結果で待ちを終える)
        for _ in 0..<2 { state.enqueue(.fileSelected(path: "/tmp/b.csv", serial: 2)) }
        var answered: [InputCallback] = []
        state.beginFrame { callback in
            answered.append(callback)
            if case .fileSelected(let path, let serial) = callback {
                state.selection.resolve(path, serial: serial)
            }
        }
        #expect(answered == [.fileSelected(path: "/tmp/b.csv", serial: 2)], "\(answered)")
        #expect(state.warnings.message(for: .unawaitedSelection) == nil)
        first.cancel()
        second.cancel()
    }

    @Test("区画から送ると、待っているときだけ accepted。待っていない・2 本は ignored で、待ちが無い件は名乗る")
    func theInboxChecksTheWait() async throws {
        let facet = FileManager.default.temporaryDirectory
            .appendingPathComponent("mokume-select-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: facet, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: facet) }
        let inbox = InputInbox(directory: facet)
        let state = InputState()
        func send(_ id: String, _ events: String) throws -> InputReport {
            try AtomicFile.write(
                Data(#"{"id":"\#(id)","events":[\#(events)]}"#.utf8),
                to: facet.appendingPathComponent("request.json"))
            return try #require(inbox.drain(into: state))
        }

        // 待っていない: 捨てて、応答の warnings で名乗る
        let before = try send("s1", #"{"type":"fileSelected","paths":["/tmp/a.csv"]}"#)
        #expect(before.accepted == 0 && before.ignored == 1)
        let warnings = try #require(before.warnings)
        #expect(warnings.count == 1 && warnings[0].hasPrefix("events[0]: "), "\(warnings)")

        let waiting = Task { await state.selection.request("pick") }
        #expect(await eventually { state.selection.isAwaiting })
        // 待っている: 2 本は読めない 1 件、取り消しの空の配列は 1 件通り、同じ要求の 2 件目は待つ相手がいない
        let during = try send(
            "s2",
            #"{"type":"fileSelected","paths":["/tmp/a.csv","/tmp/b.csv"]},"#
                + #"{"type":"fileSelected","paths":[]},"#
                + #"{"type":"fileSelected","paths":["/tmp/c.csv"]}"#)
        #expect(during.accepted == 1 && during.ignored == 2, "\(during)")
        var seen: [InputCallback] = []
        state.beginFrame { seen.append($0) }
        #expect(seen == [.fileSelected(path: nil, serial: nil)])
        waiting.cancel()
    }

    @Test("区画から送る番号つきの結果は、番号が合うときだけ accepted。合わないものは ignored で名乗る")
    func theInboxChecksTheSerial() async throws {
        let facet = FileManager.default.temporaryDirectory
            .appendingPathComponent("mokume-select-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: facet, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: facet) }
        let inbox = InputInbox(directory: facet)
        let state = InputState()
        func send(_ id: String, _ events: String) throws -> InputReport {
            try AtomicFile.write(
                Data(#"{"id":"\#(id)","events":[\#(events)]}"#.utf8),
                to: facet.appendingPathComponent("request.json"))
            return try #require(inbox.drain(into: state))
        }

        let waiting = Task { await state.selection.request("pick") }
        #expect(await eventually { state.selection.pending?.serial == 1 })
        // 番号が違う結果は待ちを終えない。合う結果は 1 件通り、同じ要求の次は待つ相手がいない
        let report = try send(
            "s1",
            #"{"type":"fileSelected","paths":["/tmp/old.csv"],"serial":7},"#
                + #"{"type":"fileSelected","paths":["/tmp/a.csv"],"serial":1},"#
                + #"{"type":"fileSelected","paths":["/tmp/a.csv"],"serial":1}"#)
        #expect(report.accepted == 1 && report.ignored == 2, "\(report)")
        let warnings = try #require(report.warnings)
        #expect(warnings.count == 2 && warnings[0].contains("serial"), "\(warnings)")
        var seen: [InputCallback] = []
        state.beginFrame { seen.append($0) }
        #expect(seen == [.fileSelected(path: "/tmp/a.csv", serial: 1)], "\(seen)")
        waiting.cancel()
    }
}

@Suite("ファイルを選ばせる: 面の属性")
@MainActor
struct SelectInputAttributeTests {
    private func makeSurface() throws -> IOSurfaceRef {
        try #require(IOSurfaceCreate(SharedFrameSurface.properties(width: 4, height: 4)))
    }

    @Test("載せた頼みを読める。文言は日本語も運ぶ")
    func readsWhatWasPublished() throws {
        let surface = try makeSurface()
        SharedFrameSurface.publishSelection(
            SelectionBroker.Request(serial: 7, prompt: "CSV を選ぶ"), to: surface)
        #expect(
            SharedFrameSurface.selectionRequest(on: surface)
                == SelectionBroker.Request(serial: 7, prompt: "CSV を選ぶ"))
    }

    @Test("頼んでいなければ属性ごと消す (面は使い回される)")
    func removesWhenNotRequested() throws {
        let surface = try makeSurface()
        SharedFrameSurface.publishSelection(SelectionBroker.Request(serial: 1, prompt: "x"), to: surface)
        SharedFrameSurface.publishSelection(nil, to: surface)
        #expect(SharedFrameSurface.selectionRequest(on: surface) == nil)
        #expect(IOSurfaceCopyValue(surface, SharedFrameSurface.selectInputAttribute as CFString) == nil)
    }

    /// **番号と文言は 1 つの属性に入れる。** 別々の属性にすると、書き換えと読みが重なったときに、
    /// 番号は前の頼みのまま文言だけ次の頼みのものを読んで、別の頼みの文言でダイアログが出うる。
    @Test("頼みの番号と文言は 1 つの値に入り、頼み直しでは組ごと入れ替わる")
    func theSerialAndThePromptTravelTogether() throws {
        let surface = try makeSurface()
        SharedFrameSurface.publishSelection(SelectionBroker.Request(serial: 1, prompt: "one"), to: surface)
        SharedFrameSurface.publishSelection(SelectionBroker.Request(serial: 2, prompt: "two"), to: surface)
        #expect(
            SharedFrameSurface.selectionRequest(on: surface)
                == SelectionBroker.Request(serial: 2, prompt: "two"))
        // 番号の属性が単独の数ではない (文言を別の属性に載せていない)
        let value = IOSurfaceCopyValue(surface, SharedFrameSurface.selectInputAttribute as CFString)
        #expect(value is NSDictionary, "番号と文言が 1 つの値に入っていない: \(String(describing: value))")
        #expect(IOSurfaceCopyValue(surface, "mokume.selectInputPrompt" as CFString) == nil)
    }

    @Test("載っていない面・正でない番号の面は、頼んでいないと読む")
    func readsNothingFromAnUnrequestedSurface() throws {
        let surface = try makeSurface()
        #expect(SharedFrameSurface.selectionRequest(on: surface) == nil)
        let zero: [String: Any] = [SharedFrameSurface.selectInputSerialKey: NSNumber(value: 0)]
        IOSurfaceSetValue(
            surface, SharedFrameSurface.selectInputAttribute as CFString, zero as CFDictionary)
        #expect(SharedFrameSurface.selectionRequest(on: surface) == nil)
        // 番号の無い・数でない値も頼みとして読まない
        for value: Any in [["prompt": "x"], ["serial": "3", "prompt": "x"], 3] {
            IOSurfaceSetValue(
                surface, SharedFrameSurface.selectInputAttribute as CFString, value as CFTypeRef)
            #expect(SharedFrameSurface.selectionRequest(on: surface) == nil, "\(value)")
        }
    }
}

/// 呼ぶ側の `Task` が待ち、結果の出来事で終わる。窓の外から送る区画 (`.mokume/input`) で結果を差し替える。
/// GPU を要する。
@Suite(
    "ファイルを選ばせる: スケッチから",
    .enabled(
        if: RenderDevice.isAvailable,
        "この世代のコマンド構造に対応した GPU が無い実行環境ではスキップする")
)
@MainActor
struct SelectInputSketchTests {
    final class Asker: Sketch {
        var results: [String?] = []
        var stopsInSetup = false
        var settings: SketchSettings { SketchSettings(width: 32, height: 24) }
        func setup() { if stopsInSetup { noLoop() } }
        func draw() { background(.display(red: 0, green: 0, blue: 0)) }
        func mousePressed() {
            Task { results.append(await selectInput("pick")) }
        }
    }

    private func makeFacet() throws -> URL {
        let facet = FileManager.default.temporaryDirectory
            .appendingPathComponent("mokume-select-sketch-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: facet, withIntermediateDirectories: true)
        return facet
    }

    private func send(_ events: String, id: String, to facet: URL) throws {
        try AtomicFile.write(
            Data(#"{"id":"\#(id)","events":[\#(events)]}"#.utf8),
            to: facet.appendingPathComponent("request.json"))
    }

    /// 押して、頼みの通し番号が進む (= 新しい `selectInput` が頼みを立てる) まで待つ。
    private func press(_ runtime: SketchRuntime) async throws {
        let before = runtime.input.selection.pending?.serial ?? 0
        runtime.input.enqueue(.mouseDown(x: 1, y: 1, button: .left))
        try runtime.advance()
        #expect(await eventually { (runtime.input.selection.pending?.serial ?? 0) > before })
    }

    @Test("selectInput は頼みを立てて待ち、注入した結果で終わる。取り消しは nil", arguments: [false, true])
    func theWaitEndsWithTheInjectedResult(stopped: Bool) async throws {
        let facet = try makeFacet()
        let sketch = Asker()
        sketch.stopsInSetup = stopped
        let runtime = try SketchRuntime(
            sketch: sketch, gpu: try RenderDevice(), clock: nil, now: { 0 }, observer: nil,
            inbox: InputInbox(directory: facet))
        try runtime.advance()
        try await press(runtime)
        #expect(runtime.input.selection.pending == SelectionBroker.Request(serial: 1, prompt: "pick"))
        #expect(sketch.results.isEmpty, "結果が来ないうちに戻った")

        try send(#"{"type":"fileSelected","paths":["/tmp/a.csv"]}"#, id: "r1", to: facet)
        try runtime.advance()
        #expect(await eventually { sketch.results.count == 1 })
        #expect(sketch.results == ["/tmp/a.csv"])
        #expect(runtime.input.selection.pending == nil)

        // もう 1 度: 取り消し
        try await press(runtime)
        try send(#"{"type":"fileSelected","paths":[]}"#, id: "r2", to: facet)
        try runtime.advance()
        #expect(await eventually { sketch.results.count == 2 })
        #expect(sketch.results == ["/tmp/a.csv", nil])
    }

    @Test("待ちの最中にもう 1 度呼ぶと、前の待ちは nil で終わる")
    func aSecondCallEndsTheFirstWithNil() async throws {
        let facet = try makeFacet()
        let sketch = Asker()
        let runtime = try SketchRuntime(
            sketch: sketch, gpu: try RenderDevice(), clock: nil, now: { 0 }, observer: nil,
            inbox: InputInbox(directory: facet))
        try runtime.advance()
        try await press(runtime)
        try await press(runtime)
        #expect(await eventually { sketch.results.count == 1 })
        #expect(sketch.results == [nil], "前の待ちが終わらない")
        #expect(runtime.input.selection.pending?.serial == 2)
        try send(#"{"type":"fileSelected","paths":["/tmp/b.csv"]}"#, id: "r1", to: facet)
        try runtime.advance()
        #expect(await eventually { sketch.results.count == 2 })
        #expect(sketch.results == [nil, "/tmp/b.csv"])
    }

    @Test("待っていないときに結果を送ると、捨てられて応答の warnings で名乗る。待ちは何も終わらない")
    func aResultWithoutAWaitIsNamed() async throws {
        let facet = try makeFacet()
        let sketch = Asker()
        let runtime = try SketchRuntime(
            sketch: sketch, gpu: try RenderDevice(), clock: nil, now: { 0 }, observer: nil,
            inbox: InputInbox(directory: facet))
        try runtime.advance()
        try send(#"{"type":"fileSelected","paths":["/tmp/a.csv"]}"#, id: "r1", to: facet)
        try runtime.advance()
        let report = try JSONSerialization.jsonObject(
            with: Data(contentsOf: facet.appendingPathComponent("report.json")))
        let object = try #require(report as? [String: Any])
        #expect(object["ignored"] as? Int == 1 && object["accepted"] as? Int == 0, "\(object)")
        #expect((object["warnings"] as? [String])?.count == 1)
        // その後に頼んだ待ちを、古い結果が終えない
        try await press(runtime)
        #expect(sketch.results.isEmpty)
        #expect(runtime.input.selection.isAwaiting)
    }

    @Test("古い番号の結果は、頼み直した後の待ちを終えない。番号つきの送り直しは警告せず待ちを 1 度だけ終える")
    func aStaleOrRepeatedNumberedResultDoesNotDisturbTheWait() async throws {
        let facet = try makeFacet()
        let sketch = Asker()
        let runtime = try SketchRuntime(
            sketch: sketch, gpu: try RenderDevice(), clock: nil, now: { 0 }, observer: nil,
            inbox: InputInbox(directory: facet))
        try runtime.advance()
        try await press(runtime)
        // 頼み直した (前の待ちは nil で終わる)。その後に、1 番への答え (管や溜まりに残っていた行) が届く
        try await press(runtime)
        runtime.input.enqueue(.fileSelected(path: "/tmp/old.csv", serial: 1))
        try runtime.advance()
        #expect(await eventually { sketch.results.count == 1 })
        #expect(sketch.results == [nil], "前の待ちが nil で終わるだけのはず: \(sketch.results)")
        #expect(runtime.input.selection.pending?.serial == 2, "古い答えが新しい待ちを終えた")

        // 2 番の答えが 2 度届く (送り直し)。待ちを終えるのは 1 度で、警告は出ない
        runtime.input.enqueue(.fileSelected(path: "/tmp/b.csv", serial: 2))
        runtime.input.enqueue(.fileSelected(path: "/tmp/b.csv", serial: 2))
        try runtime.advance()
        #expect(await eventually { sketch.results.count == 2 })
        #expect(sketch.results == [nil, "/tmp/b.csv"])
        try runtime.advance()
        #expect(runtime.input.warnings.message(for: .unawaitedSelection) == nil, "送り直しを警告にした")
    }

    @Test("実行が終わった後の呼び出しは待たずに nil を返し、終わるときの待ちは nil で終わる")
    func afterTheRunEndsItReturnsNil() async throws {
        let facet = try makeFacet()
        let sketch = Asker()
        let runtime = try SketchRuntime(
            sketch: sketch, gpu: try RenderDevice(), clock: nil, now: { 0 }, observer: nil,
            inbox: InputInbox(directory: facet))
        try runtime.advance()
        try await press(runtime)
        runtime.closePlugins()
        #expect(await eventually { sketch.results.count == 1 }, "終わった実行で待ちが残っている")
        #expect(sketch.results == [nil])

        // 終わった後に呼ぶと、待たずに nil。言うのは 1 度。**戻りを `await` で待たず箱で見る** — 壊れた実装は返らない
        let log = OutsideRun()
        let broker = runtime.input.selection
        let box = SelectionBrokerTests.Outcome()
        let second = SelectionBrokerTests.Outcome()
        Task {
            await OutsideRun.$current.withValue(log) {
                await LaunchingSketch.$selection.withValue(broker) {
                    struct Part: SketchPart {}
                    box.value = .some(await Part().selectInput("x"))
                    second.value = .some(await Part().selectInput("y"))
                }
            }
        }
        #expect(await eventually { second.value != nil }, "終わった実行で頼むと待たされる")
        #expect(box.value == .some(nil) && second.value == .some(nil))
        #expect(log.messages.count == 1, "\(log.messages)")
        #expect(!broker.isAwaiting)
    }

    @Test("走っている実行の外から呼ぶと、頼まずに nil を返し、1 度だけ警告する")
    func outsideARunReturnsNil() async {
        struct Part: SketchPart {}
        let log = OutsideRun()
        let result = await OutsideRun.$current.withValue(log) {
            let first = await Part().selectInput("x")
            let second = await Part().selectInput("y")
            return (first, second)
        }
        #expect(result.0 == nil && result.1 == nil)
        #expect(log.messages.count == 1, "\(log.messages)")
        #expect(log.messages.first?.contains("selectInput()") == true)
    }
}
