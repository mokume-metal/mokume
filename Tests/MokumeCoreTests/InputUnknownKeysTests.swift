// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation
import MokumeTestSupport
import Testing

@testable import MokumeCore

/// 入力の要求の知らない鍵を、応答の `warnings` で名乗る ([#2843](https://github.com/mokume-metal/mokume/issues/2843))。
/// **要求は失敗させず、出来事も `ignored` へ回さない** ([ADR-0018] 決定 3)。GPU は要らない。
///
/// [ADR-0018]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0018-observation-and-control-surface.md
@Suite("入力の要求の知らない鍵")
struct InputUnknownKeysTests {
    private func makeFacet() throws -> URL {
        let url = try TestScratch.directory("mokume-input-keys")
        return url
    }

    private func send(_ body: String, to facet: URL) throws {
        try AtomicFile.write(Data(body.utf8), to: facet.appendingPathComponent("request.json"))
    }

    /// 書かれた応答の鍵 (道具が読む姿)。
    private func writtenKeys(in facet: URL) throws -> Set<String> {
        let data = try Data(contentsOf: facet.appendingPathComponent("report.json"))
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        return Set(object.keys)
    }

    @Test("出来事の綴りの誤りは、左クリックとして受けたうえで、位置・名前・読む鍵を名乗る")
    func namesAMisspelledKeyInsideAnEvent() throws {
        let facet = try makeFacet()
        let state = InputState()
        try send(
            #"{"id":"i1","events":[{"type":"mouseDown","x":1,"y":2,"buton":1}]}"#, to: facet)

        let report = try #require(InputInbox(directory: facet).drain(into: state))
        #expect(report.id == "i1")
        #expect(report.accepted == 1, "要求も出来事も断らない")
        #expect(report.ignored == 0)
        state.beginFrame()
        #expect(state.button == .left, "buton を button として読んだ")

        let warnings = try #require(report.warnings, "名乗りが無い")
        #expect(warnings.count == 1, "\(warnings)")
        let line = try #require(warnings.first)
        #expect(line.hasPrefix("events[0]: "), "位置が無い: \(line)")
        #expect(line.contains("buton"), "名前が無い: \(line)")
        for key in RawInputEvent.readKeys(forType: "mouseDown") {
            #expect(line.contains(key), "読む鍵 \(key) が並ばない: \(line)")
        }
        // 書かれた応答にも載る
        #expect(try writtenKeys(in: facet).contains("warnings"))
    }

    /// `amount` は pinched で、`clickCount` は mouseDown でだけ読む ([#2762](https://github.com/mokume-metal/mokume/issues/2762))。
    /// ほかの種別に付いていたら、足す前と同じく読まない鍵として名乗り、その 1 件は通す。
    /// 型違いの値でも、その 1 件を `ignored` にしない — `mouseUp` が落ちると釦が押されたまま残る。
    @Test("clickCount・amount は読む種別でだけ読む。ほかの種別では読まない鍵として名乗り、1 件は通す")
    func namesTheKeysOnlyOneTypeReads() throws {
        let facet = try makeFacet()
        let state = InputState()
        try send(
            #"{"id":"i8","events":[{"type":"mouseDown","x":1,"y":2,"clickCount":1},"#
                + #"{"type":"mouseUp","x":1,"y":2,"clickCount":1.5},"#
                + #"{"type":"scrolled","dy":3,"amount":0.5},"#
                + #"{"type":"pinched","amount":0.2,"clickCount":2}]}"#,
            to: facet)

        let report = try #require(InputInbox(directory: facet).drain(into: state))
        #expect(report.accepted == 4, "型違いの clickCount が付いた mouseUp が落ちた")
        #expect(report.ignored == 0)
        state.beginFrame()
        #expect(state.pressedButtons.isEmpty, "mouseUp が届かず、釦が押されたまま残った")
        #expect(state.pinch == 0.2)

        let warnings = try #require(report.warnings)
        #expect(warnings.count == 3, "\(warnings)")
        #expect(warnings[0].hasPrefix("events[1]: ") && warnings[0].contains("clickCount"))
        #expect(warnings[1].hasPrefix("events[2]: ") && warnings[1].contains("amount"))
        #expect(warnings[2].hasPrefix("events[3]: ") && warnings[2].contains("clickCount"))
        // 名乗る「読む鍵」は、その種別が読む鍵 (mouseUp は clickCount も amount も読まない)
        #expect(!warnings[0].contains("the keys read are type, x, y, button, dx, dy, code, characters, isRepeat, amount"))
        #expect(!RawInputEvent.readKeys(forType: "mouseUp").contains("clickCount"))
        #expect(!RawInputEvent.readKeys(forType: "mouseUp").contains("amount"))
        #expect(RawInputEvent.readKeys(forType: "pinched").contains("amount"))
        #expect(!RawInputEvent.readKeys(forType: "pinched").contains("clickCount"))
        #expect(RawInputEvent.readKeys(forType: "teleport") == RawInputEvent.readKeys, "知らない種別は全部を読む鍵とする")
    }

    @Test("名乗る位置は、知らない鍵を持つ出来事の番号である")
    func namesTheIndexOfEachEventThatHasOne() throws {
        let facet = try makeFacet()
        try send(
            #"{"id":"i2","events":[{"type":"mouseMoved","x":1,"y":2},"#
                + #"{"type":"keyDown","code":0,"isRepat":true},{"type":"scrolled","dy":1,"dX":2}]}"#,
            to: facet)

        let report = try #require(InputInbox(directory: facet).drain(into: InputState()))
        #expect(report.accepted == 3)
        let warnings = try #require(report.warnings)
        #expect(warnings.count == 2, "\(warnings)")
        #expect(warnings[0].hasPrefix("events[1]: ") && warnings[0].contains("isRepat"))
        #expect(warnings[1].hasPrefix("events[2]: ") && warnings[1].contains("dX"))
    }

    @Test("要求の最上位の余りも名乗る。要求は断らず、出来事は ignored へ回さない")
    func namesAnExtraKeyOfTheRequest() throws {
        let facet = try makeFacet()
        try send(#"{"id":"i3","events":[],"evnt":1}"#, to: facet)

        let report = try #require(InputInbox(directory: facet).drain(into: InputState()))
        #expect(report.id == "i3")
        #expect(report.accepted == 0)
        #expect(report.ignored == 0)
        let warnings = try #require(report.warnings)
        #expect(warnings.count == 1, "\(warnings)")
        #expect(warnings[0].contains("evnt"))
        #expect(warnings[0].contains("id, events"), "読む鍵が並ばない: \(warnings[0])")
        #expect(!warnings[0].hasPrefix("events["), "位置を出来事に取り違えた")
    }

    @Test("events が欠けて解けない要求でも、最上位の綴りの誤りを名乗る")
    func namesAnExtraKeyOfARequestWhoseEventsAreMissing() throws {
        let facet = try makeFacet()
        try send(#"{"id":"i4","evnts":[{"type":"mouseMoved","x":1,"y":2}]}"#, to: facet)

        let report = try #require(InputInbox(directory: facet).drain(into: InputState()))
        #expect(report.accepted == 0)
        #expect(report.ignored == 1, "解けなかった 1 件の数え方は変わらない (#2550)")
        let warnings = try #require(report.warnings)
        #expect(warnings.count == 1 && warnings[0].contains("evnts"), "\(warnings)")
    }

    @Test("解けなかった出来事・知らない種別の出来事の綴りの誤りも名乗る")
    func namesTheKeysOfAnEventThatCountsInIgnored() throws {
        let facet = try makeFacet()
        // type の綴りの誤り (tpye) で解けない 1 件と、知らない種別の 1 件
        try send(
            #"{"id":"i5","events":[{"tpye":"mouseMoved","x":1,"y":2},"#
                + #"{"type":"teleport","where":3}]}"#,
            to: facet)

        let report = try #require(InputInbox(directory: facet).drain(into: InputState()))
        #expect(report.accepted == 0)
        #expect(report.ignored == 2, "ignored の数え方は変わらない")
        let warnings = try #require(report.warnings)
        #expect(warnings.count == 2, "\(warnings)")
        #expect(warnings[0].hasPrefix("events[0]: ") && warnings[0].contains("tpye"))
        #expect(warnings[1].hasPrefix("events[1]: ") && warnings[1].contains("where"))
    }

    /// 数千件が同じ綴りの誤りを持っても、応答を同じ数の行で埋めない。
    @Test("名乗る出来事の数には上限があり、残りは件数だけ言う")
    func capsTheNumberOfNamedEvents() throws {
        let facet = try makeFacet()
        let count = InputRequest.namedEventLimit + 3
        let events = (0..<count).map { _ in #"{"type":"mouseMoved","x":1,"y":2,"z":3}"# }
        try send(#"{"id":"i6","events":[\#(events.joined(separator: ","))]}"#, to: facet)

        let report = try #require(InputInbox(directory: facet).drain(into: InputState()))
        #expect(report.accepted == count)
        let warnings = try #require(report.warnings)
        #expect(warnings.count == InputRequest.namedEventLimit + 1, "\(warnings.count) 行")
        #expect(warnings.last == "3 more events also carried keys that were not read")
    }

    @Test("長い鍵の名前は、観測と同じ上限で切って返す")
    func cutsALongKeyName() throws {
        let facet = try makeFacet()
        let long = String(repeating: "k", count: UnknownKeys.namedKeyLength + 20)
        try send(#"{"id":"i7","events":[{"type":"keyUp","code":0,"\#(long)":1}]}"#, to: facet)

        let report = try #require(InputInbox(directory: facet).drain(into: InputState()))
        let line = try #require(report.warnings?.first)
        #expect(!line.contains(long), "書き手が置いた長さのまま返した")
        #expect(line.contains(String(long.prefix(UnknownKeys.namedKeyLength)) + "…"))
    }

    /// `Schemas/examples/input-report-unknown-keys.json` は、実際の名乗りの文面そのもの。
    /// 文面を直したのに例が古いまま残ると、書き手は存在しない文面を読むことになる。
    @Test("スキーマの例の名乗りは、実際に返る文面と同じ")
    func theSchemaExampleIsTheRealWording() throws {
        let file = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Schemas/examples/input-report-unknown-keys.json")
        let example = try #require(
            try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])

        let facet = try makeFacet()
        try send(
            #"{"id":"9c4e2f","events":[{"type":"mouseDown","x":1,"y":2,"buton":1}]}"#, to: facet)
        let report = try #require(InputInbox(directory: facet).drain(into: InputState()))
        #expect(example["warnings"] as? [String] == report.warnings)
    }

    /// 応答のバイトが変わらないこと: 知らない鍵が無ければ `warnings` の鍵ごと書かない。
    @Test(
        "知らない鍵が無い応答は warnings を持たない",
        arguments: [
            #"{"id":"q1","events":[{"type":"mouseDown","x":1,"y":2,"button":0}]}"#,
            #"{"id":"q1","events":[]}"#,
            #"{"id":"q1","events":[{"type":"mouseDown"}]}"#,
            #"{"id":"q1","events":5}"#,
        ])
    func staysSilentWhenEveryKeyIsKnown(_ request: String) throws {
        let facet = try makeFacet()
        try send(request, to: facet)

        let report = try #require(InputInbox(directory: facet).drain(into: InputState()))
        #expect(report.warnings == nil)
        #expect(
            try writtenKeys(in: facet) == ["schemaVersion", "id", "accepted", "ignored", "dropped"])
    }
}

/// 読み手が読む鍵と、スキーマの `properties` の一致 ([#2843](https://github.com/mokume-metal/mokume/issues/2843))。
///
/// 名乗りの文面は「読む鍵」を並べる。どちらかにだけ鍵を足すと、名乗りが嘘になる (読むのに
/// 知らないと言う、読まないのに読むと言う)。スキーマは書く側が読むので、割れると書き手も惑う。
@Suite("読み手の鍵とスキーマの欄")
struct ReadKeysMatchTheSchemaTests {
    private static func schema(_ name: String) throws -> [String: Any] {
        let file = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Schemas/\(name).schema.json")
        return try #require(
            try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
    }

    private static func properties(_ object: [String: Any]) throws -> Set<String> {
        Set(try #require(object["properties"] as? [String: Any]).keys)
    }

    /// 食い違いを名指しする。
    private func expectSame(_ read: [String], _ declared: Set<String>, _ what: String) {
        let reader = Set(read)
        #expect(reader.count == read.count, "\(what): 読み手の鍵が重なっている")
        #expect(
            reader == declared,
            "\(what): 読み手だけ \(reader.subtracting(declared).sorted())・スキーマだけ \(declared.subtracting(reader).sorted())"
        )
    }

    @Test("入力の出来事: RawInputEvent の鍵と input-request の items.properties")
    func inputEvent() throws {
        let request = try Self.schema("input-request")
        let top = try #require(request["properties"] as? [String: Any])
        let events = try #require(top["events"] as? [String: Any])
        let item = try #require(events["items"] as? [String: Any])
        expectSame(RawInputEvent.readKeys, try Self.properties(item), "入力の出来事")
        #expect(item["additionalProperties"] as? Bool == false, "出来事は additionalProperties: false")
    }

    @Test("入力の要求の最上位: InputRequest の鍵と input-request の properties")
    func inputRequest() throws {
        expectSame(
            InputRequest.readKeys, try Self.properties(try Self.schema("input-request")),
            "入力の要求の最上位")
    }

    @Test("観測の要求: ObservationRequest の鍵と observe-request の properties")
    func observationRequest() throws {
        expectSame(
            ObservationRequest.readKeys, try Self.properties(try Self.schema("observe-request")),
            "観測の要求")
    }
}
