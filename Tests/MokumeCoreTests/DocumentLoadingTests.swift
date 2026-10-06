// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation
import Testing

@testable import MokumeCore

/// JSON と XML をファイルと URL から読む口 (#2070)。走っているスケッチも GPU も要らない —
/// 描き場所に触れない口なので、`init` の外で作った素のスケッチから呼べる。
///
/// **URL は外へ出ない。** 応答は ``CannedResponses`` が予約済みの `.test` の名前で返す。
@Suite("JSON と XML の読み込み")
struct DocumentLoadingTests {
    final class Bare: Sketch {
        init() {}
        func draw() {}
    }

    /// 検査ごとに別の置き場。終わったら消す。
    private let folder = FileManager.default.temporaryDirectory
        .appendingPathComponent("mokume-documents-\(UUID().uuidString)")

    private func file(_ name: String, _ text: String) throws -> String {
        try file(name, Data(text.utf8))
    }

    private func file(_ name: String, _ bytes: Data) throws -> String {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent(name)
        try bytes.write(to: url)
        return url.path
    }

    private func cleanUp() { try? FileManager.default.removeItem(at: folder) }

    /// 壊れた文字を読んで、壊れていた行と理由を返す。`malformed` で投げなければ検査を落とす。
    private func malformedLine(
        _ read: () throws(DataFailure) -> Void, sourceLocation: SourceLocation = #_sourceLocation
    ) -> (line: Int, reason: String)? {
        do {
            try read()
            Issue.record("投げていない", sourceLocation: sourceLocation)
        } catch {
            if case .malformed(_, let line, let reason) = error { return (line, reason) }
            Issue.record("malformed で投げていない: \(error)", sourceLocation: sourceLocation)
        }
        return nil
    }

    private static let weather = #"{"name": "Sapporo", "main": {"temp": -3.5, "humidity": 80}}"#

    // MARK: - JSON をファイルから

    @Test("作例 1: 入れ子のオブジェクトへ降りて、気温を数で取り出す")
    func nestedObjectGivesTemperature() throws {
        defer { cleanUp() }
        let weather = try Bare().loadJSONObject(try file("weather.json", Self.weather))
        #expect(weather.getJSONObject("main").getFloat("temp") == -3.5)
        #expect(weather.getJSONObject("main").getFloat("humidity") == 80)
    }

    @Test("requestJSONObject は loadJSONObject と同じオブジェクトを返す")
    func requestJSONObjectMatchesLoad() async throws {
        defer { cleanUp() }
        let path = try file("weather.json", Self.weather)
        let sketch = Bare()
        #expect(try await sketch.requestJSONObject(path) == sketch.loadJSONObject(path))
    }

    @Test("日本語とエスケープは解いた文字で持つ。数の文字は数として読む")
    func escapesAndJapaneseAreDecoded() throws {
        defer { cleanUp() }
        let text = #"{"city": "札幌\né😀\"", "temp": " 18.5 ", "かな": 1}"#
        let object = try Bare().loadJSONObject(try file("escapes.json", text))
        #expect(object.members["city"] == .string("札幌\né😀\""))
        #expect(object.getFloat("temp") == 18.5)
        #expect(object.getFloat("かな") == 1)
    }

    @Test("大きな数と小さな数も数として読む。Double に収まらない数は壊れた JSON")
    func largeNumbers() throws {
        defer { cleanUp() }
        let text = #"{"big": 12345678901234567890, "neg": -9223372036854775809, "tiny": 1e-30, "max": 1e300}"#
        let object = try Bare().loadJSONObject(try file("big.json", text))
        #expect(object.getFloat("big") == Float(12345678901234567890.0))
        #expect(object.getFloat("neg") == Float(-9223372036854775809.0))
        #expect(object.getFloat("tiny") == Float(1e-30))
        #expect(object.getFloat("max") == .infinity)  // Float に収まらない数は無限大
        let path = try file("huge.json", "{\n\"a\": 1e400}")
        let broken = malformedLine { () throws(DataFailure) in _ = try Bare().loadJSONObject(path) }
        #expect(broken?.line == 2)
    }

    @Test("真偽は数と分けて持つ。true は数として読まない")
    func booleansAreNotNumbers() throws {
        defer { cleanUp() }
        let key = "flag-\(UUID().uuidString)"
        let object = try Bare().loadJSONObject(try file("b.json", #"{"\#(key)": true, "one": 1, "zero": 0}"#))
        #expect(object.members[key] == .bool(true))
        #expect(object.members["one"] == .number(1))
        #expect(object.getFloat("zero") == 0)
        #expect(object.getFloat(key).isNaN)
        #expect(DocumentValues.warnings.message(for: .notANumber(key: key))?.contains("is true") == true)
    }

    // MARK: - 壊れた JSON

    @Test(
        "壊れた JSON は、壊れていた行を添えて投げる",
        arguments: [
            ("閉じない括弧", "{\"a\": 1,\n \"b\": [1, 2,\n}", 3),
            ("不正な文字", "{\n\"a\": \"\u{01}\"}", 2),
            ("値の後の余り", "{\"a\": 1}\n\nrest", 3),
            ("空", "", 1),
            ("空白だけ", "  \n  ", 2),
            ("CRLF の行", "{\r\n\"a\": 1,\r\n\"b\": x,\r\n\"c\": 3\r\n}", 3),
            ("CR の行", "{\r\"a\": 1,\r\"b\": x}", 3),
            ("最後の改行の後ろで尽きた", "{\"a\": 1,\n", 1),
        ])
    func malformedJSONNamesLine(_ name: String, _ text: String, _ line: Int) throws {
        defer { cleanUp() }
        let path = try file("broken.json", text)
        let broken = malformedLine { () throws(DataFailure) in _ = try Bare().loadJSONObject(path) }
        #expect(broken?.line == line, "\(name)")
        #expect(broken?.reason.isEmpty == false)
    }

    @Test("壊れた JSON は、待たない版でも同じ失敗で投げる")
    func malformedJSONSameForRequest() async throws {
        defer { cleanUp() }
        let path = try file("broken.json", "{\"a\": [1, 2,\n}")
        let failure = #expect(throws: DataFailure.self) { try Bare().loadJSONObject(path) }
        #expect(failure?.description.contains("broken.json\" is broken at line 2") == true)
        await #expect(throws: failure!) { try await Bare().requestJSONObject(path) }
    }

    @Test("最上位がオブジェクトでない JSON は、最上位の値の行を添えて投げる")
    func topLevelMustBeObject() throws {
        defer { cleanUp() }
        let path = try file("list.json", "\n\n[1, 2]")
        let broken = malformedLine { () throws(DataFailure) in _ = try Bare().loadJSONObject(path) }
        #expect(broken?.line == 3)
        #expect(broken?.reason.contains("an array") == true)
    }

    @Test("入れ子は最上位の下に 512 段まで読め、その先は投げる。待たない版も同期版と同じ深さまで読む")
    func deepNestingIsBounded() async throws {
        defer { cleanUp() }
        // 最上位のオブジェクトを 1 段と数える
        func nested(_ depth: Int) -> String {
            String(repeating: #"{"a":"#, count: depth - 1) + "{}" + String(repeating: "}", count: depth - 1)
        }
        let deep = try file("deep.json", nested(513))
        // 待たない版は別の thread で読む。共有の thread の小さなスタックでは、ここで落ちていた
        var object = try await Bare().requestJSONObject(deep)
        #expect(try Bare().loadJSONObject(deep) == object)
        for _ in 0..<512 { object = object.getJSONObject("a") }
        #expect(object == JSONObject([:]))

        let deeper = try file("deeper.json", nested(514))
        let failure = await #expect(throws: DataFailure.self) { try await Bare().requestJSONObject(deeper) }
        #expect(failure?.description.contains("Too many nested") == true)
    }

    // MARK: - JSON から値を取り出す

    @Test("無いキーは NaN を返し、在るキーを添えて 1 度だけ知らせる")
    func missingKeyWarnsWithKeys() throws {
        defer { cleanUp() }
        let weather = try Bare().loadJSONObject(try file("weather.json", Self.weather))
        let typo = "tmep-\(UUID().uuidString)"
        #expect(weather.getJSONObject("main").getFloat(typo).isNaN)
        let message = DocumentValues.warnings.message(for: .noKey(typo))
        #expect(message?.contains(#"Its keys are: "humidity", "temp""#) == true)
    }

    @Test("無いキーのオブジェクトは空になり、繋いだ先の数は NaN になる")
    func missingObjectChainsToNaN() throws {
        defer { cleanUp() }
        let weather = try Bare().loadJSONObject(try file("weather.json", Self.weather))
        let typo = "mian-\(UUID().uuidString)"
        let missing = weather.getJSONObject(typo)
        #expect(missing == JSONObject([:]))
        #expect(missing.getFloat("temp").isNaN)
        #expect(DocumentValues.warnings.message(for: .noKey(typo))?.contains("getJSONObject") == true)
    }

    @Test("数でない値・オブジェクトでない値は、値を名乗って 1 度だけ知らせる")
    func wrongKindsWarnOnce() throws {
        defer { cleanUp() }
        let key = "k-\(UUID().uuidString)"
        let object = try Bare().loadJSONObject(
            try file("kinds.json", #"{"\#(key)": "N/A", "list": [1], "nothing": null}"#))
        #expect(object.getFloat(key).isNaN)
        #expect(object.getFloat(key).isNaN)
        #expect(DocumentValues.warnings.message(for: .notANumber(key: key))?.contains(#""N/A""#) == true)
        #expect(object.getFloat("nothing").isNaN)
        #expect(object.getJSONObject(key) == JSONObject([:]))
        #expect(DocumentValues.warnings.message(for: .notAnObject(key: key))?.contains("not an object") == true)
        #expect(object.getJSONObject("list") == JSONObject([:]))
        #expect(DocumentValues.warnings.message(for: .notAnObject(key: "list"))?.contains("an array") == true)
    }

    // MARK: - XML をファイルから

    private static let sky = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!-- 星の並び -->
        <sky name="冬 &amp; 夜">
          <star x="120" y="80" size="6"/>
          <star x=" 200 " y="140" size="4"><note/></star>
          <planet x="300" y="40"/>
        </sky>
        """

    @Test("作例 2: 名前で子を取り出し、属性を数で読む。孫は入らない")
    func childrenAndAttributes() throws {
        defer { cleanUp() }
        let sky = try Bare().loadXML(try file("sky.xml", Self.sky))
        let stars = sky.getChildren("star")
        #expect(stars.count == 2)
        #expect(stars.map { $0.getFloat("x") } == [120, 200])
        #expect(stars[1].getFloat("size") == 4)
        #expect(sky.getChildren("note").isEmpty)
        #expect(sky.getChildren("planet").count == 1)
    }

    @Test("日本語と実体参照は解いた値で持つ")
    func entitiesAndJapanese() throws {
        defer { cleanUp() }
        let sky = try Bare().loadXML(try file("sky.xml", Self.sky))
        #expect(sky.element.name == "sky")
        #expect(sky.element.attributes["name"] == "冬 & 夜")
    }

    @Test("requestXML は loadXML と同じ要素を返す")
    func requestXMLMatchesLoad() async throws {
        defer { cleanUp() }
        let path = try file("sky.xml", Self.sky)
        let sketch = Bare()
        #expect(try await sketch.requestXML(path) == sketch.loadXML(path))
    }

    @Test("外の実体は読まない")
    func externalEntitiesAreNotRead() throws {
        defer { cleanUp() }
        let outside = try file("outside.xml", #"<planet x="1"/>"#)
        let text = """
            <?xml version="1.0"?>
            <!DOCTYPE sky [<!ENTITY outside SYSTEM "file://\(outside)">]>
            <sky>&outside;</sky>
            """
        let sky = try Bare().loadXML(try file("sky.xml", text))
        #expect(sky.element.children.isEmpty)
    }

    // MARK: - 壊れた XML

    @Test(
        "壊れた XML は、壊れていた行を添えて投げる",
        arguments: [
            ("閉じる名前の食い違い", "<a>\n<b>\n</a>", 3),
            ("引用符の無い属性", "<a>\n<b x=1/>\n</a>", 2),
            ("不正な文字", "<a>\n\u{01}</a>", 2),
            ("根が 2 つ", "<a/>\n<b/>", 2),
            ("定義の無い実体", "<a>\n\n&nope;</a>", 3),
            ("閉じない要素", "<a>\n<b/>\n", 2),
            ("空", "", 1),
            ("空白だけ", "  \n  \n", 2),
        ])
    func malformedXMLNamesLine(_ name: String, _ text: String, _ line: Int) throws {
        defer { cleanUp() }
        let path = try file("broken.xml", text)
        let broken = malformedLine { () throws(DataFailure) in _ = try Bare().loadXML(path) }
        #expect(broken?.line == line, "\(name)")
        #expect(broken?.reason.isEmpty == false)
    }

    @Test(
        "文字の終わりで壊れた XML は、どう壊れたかを自分の言葉で言う",
        arguments: [
            ("根を閉じ忘れた", "<sky>\n<star/>", "the text ended before <sky> was closed"),
            ("根を閉じ忘れた (子なし)", "<sky>", "the text ended before <sky> was closed"),
            ("根が 2 つ", "<a/>\n<b/>", "there is more after the root element <a>"),
            ("空白だけ", "  \n  \n", "there is no element in it"),
            ("空", "", "there is no element in it"),
        ])
    func endOfTextReasons(_ name: String, _ text: String, _ reason: String) throws {
        defer { cleanUp() }
        let path = try file("end.xml", text)
        let broken = malformedLine { () throws(DataFailure) in _ = try Bare().loadXML(path) }
        #expect(broken?.reason.hasPrefix(reason) == true, "\(name): \(broken?.reason ?? "")")
    }

    @Test("入れ子は根の下に 512 段まで読め、その先は投げる。10 万段でも落ちずに投げる")
    func deepXMLIsBounded() async throws {
        defer { cleanUp() }
        func nested(_ depth: Int) -> String {
            String(repeating: "<a>", count: depth) + String(repeating: "</a>", count: depth)
        }
        let deep = try file("deep.xml", nested(513))
        var element = try await Bare().requestXML(deep)
        #expect(try Bare().loadXML(deep) == element)
        for _ in 0..<512 { element = element.getChildren("a")[0] }
        #expect(element.element.children.isEmpty)

        let deeper = try file("deeper.xml", nested(514))
        let failure = await #expect(throws: DataFailure.self) { try await Bare().requestXML(deeper) }
        #expect(failure?.description.contains("deeper than 512 levels") == true)
        let deepest = try file("deepest.xml", nested(100_000))
        await #expect(throws: DataFailure.self) { try await Bare().requestXML(deepest) }
    }

    // MARK: - XML から値を取り出す

    @Test("無い属性・数でない属性は NaN を返し、1 度だけ知らせる")
    func attributeWarnings() throws {
        defer { cleanUp() }
        let element = "e\(UUID().uuidString.prefix(8))"
        let star = try Bare().loadXML(try file("e.xml", #"<\#(element) x="12" label="bright"/>"#))
        #expect(star.getFloat("size").isNaN)
        #expect(
            DocumentValues.warnings.message(for: .noAttribute(element: element, name: "size"))?
                .contains(#"Its attributes are: "label", "x""#) == true)
        #expect(star.getFloat("label").isNaN)
        #expect(
            DocumentValues.warnings.message(for: .attributeNotANumber(element: element, name: "label"))?
                .contains(#"label="bright""#) == true)
    }

    @Test("合う子が無ければ空。他の名前の子があるときだけ、在る名前を添えて知らせる")
    func childWarnings() throws {
        defer { cleanUp() }
        let root = "r\(UUID().uuidString.prefix(8))"
        let sky = try Bare().loadXML(try file("r.xml", "<\(root)><star/><star/><planet/></\(root)>"))
        #expect(sky.getChildren("stars").isEmpty)
        #expect(
            DocumentValues.warnings.message(for: .noChild(element: root, name: "stars"))?
                .contains(#"Its children are named: "planet", "star""#) == true)
        let leaf = sky.getChildren("planet")[0]
        #expect(leaf.getChildren("moon").isEmpty)
        #expect(!DocumentValues.warnings.hasWarned(.noChild(element: "planet", name: "moon")))
    }

    // MARK: - ファイルの失敗

    @Test("無い名前は、loadImage と同じ並びの探した場所を添えて投げる")
    func missingFileNamesWhereItLooked() async {
        let name = "no-such-data-\(UUID().uuidString).json"
        let expected = DataFailure.notFound(path: name, searched: ImageFile.candidates(for: name).map(\.path))
        #expect(throws: expected) { try Bare().loadJSONObject(name) }
        #expect(throws: expected) { try Bare().loadXML(name) }
        await #expect(throws: expected) { try await Bare().requestJSONObject(name) }
        await #expect(throws: expected) { try await Bare().requestXML(name) }
    }

    @Test("UTF-8 の文字として読めないファイルは unreadable。BOM は読み飛ばす")
    func encodings() throws {
        defer { cleanUp() }
        let latin1 = try file("latin1.json", Data([0x7B, 0x22, 0xE9, 0x22, 0x3A, 0x31, 0x7D]))
        #expect(throws: DataFailure.unreadable(path: latin1)) { try Bare().loadJSONObject(latin1) }
        #expect(throws: DataFailure.unreadable(path: latin1)) { try Bare().loadXML(latin1) }
        let bom = try file("bom.json", "\u{FEFF}{\"a\": 1}")
        #expect(try Bare().loadJSONObject(bom).getFloat("a") == 1)
        let bomXML = try file("bom.xml", "\u{FEFF}<a x=\"1\"/>")
        #expect(try Bare().loadXML(bomXML).getFloat("x") == 1)
    }

    @Test("http でも https でもない綴りはファイルの名前として探す")
    func otherSchemesAreFileNames() {
        let name = "ftp://canned.test/\(UUID().uuidString).json"
        #expect(throws: DataFailure.notFound(path: name, searched: ImageFile.candidates(for: name).map(\.path))) {
            try Bare().loadJSONObject(name)
        }
    }

    // MARK: - URL から

    @Test("URL から JSON を読む。同期版も待たない版も、差し替えた応答を返す")
    func jsonFromURL() async throws {
        let url = CannedResponses.serve(Self.weather)
        let sketch = Bare()
        let waited = try sketch.loadJSONObject(url)
        #expect(waited.getJSONObject("main").getFloat("temp") == -3.5)
        #expect(try await sketch.requestJSONObject(url) == waited)
    }

    @Test("URL から XML を読む。同期版も待たない版も、差し替えた応答を返す")
    func xmlFromURL() async throws {
        let url = CannedResponses.serve(Self.sky)
        let sketch = Bare()
        let waited = try sketch.loadXML(url)
        #expect(waited.getChildren("star").count == 2)
        #expect(try await sketch.requestXML(url) == waited)
    }

    @Test("2xx でない状態は、状態の数を添えて unreachable で投げる (本文は読まない)")
    func badStatusIsUnreachable() async throws {
        let url = CannedResponses.serve(#"{"message": "not here"}"#, status: 404)
        let failure = #expect(throws: DataFailure.self) { try Bare().loadJSONObject(url) }
        guard case .unreachable(let named, let reason) = failure else {
            Issue.record("unreachable で投げていない: \(String(describing: failure))")
            return
        }
        #expect(named == url)
        #expect(reason.contains("404"))
        #expect(failure!.description.hasPrefix("Cannot read \"\(url)\""))
        await #expect(throws: failure!) { try await Bare().requestJSONObject(url) }
        let server = CannedResponses.serve("<oops/>", status: 503)
        await #expect(throws: DataFailure.self) { try await Bare().requestXML(server) }
    }

    @Test("繋がらない URL は unreachable で投げる")
    func connectionFailureIsUnreachable() async throws {
        let url = CannedResponses.serve(.fail(.cannotConnectToHost))
        let failure = #expect(throws: DataFailure.self) { try Bare().loadXML(url) }
        guard case .unreachable(let named, let reason) = failure else {
            Issue.record("unreachable で投げていない: \(String(describing: failure))")
            return
        }
        #expect(named == url)
        #expect(!reason.isEmpty)
        await #expect(throws: failure!) { try await Bare().requestXML(url) }
        // 応答を置いていない `.test` の名前も、外へ問い合わせずに届かない
        let nowhere = "https://nowhere-\(UUID().uuidString.lowercased()).test/now"
        await #expect(throws: DataFailure.self) { try await Bare().requestJSONObject(nowhere) }
    }

    @Test("届いたが壊れた本文は、URL を名乗って malformed で投げる")
    func brokenBodyIsMalformed() async throws {
        let url = CannedResponses.serve("{\"temp\":\n 18.5,,}")
        let failure = #expect(throws: DataFailure.self) { try Bare().loadJSONObject(url) }
        guard case .malformed(let named, let line, _) = failure else {
            Issue.record("malformed で投げていない: \(String(describing: failure))")
            return
        }
        #expect(named == url)
        #expect(line == 2)
        await #expect(throws: failure!) { try await Bare().requestJSONObject(url) }
    }

    @Test("UTF-8 でない本文は、URL を名乗って unreadable で投げる")
    func nonUTF8BodyIsUnreadable() async throws {
        let url = CannedResponses.serve(.answer(status: 200, body: Data([0x3C, 0x61, 0xFF, 0x2F, 0x3E])))
        #expect(throws: DataFailure.unreadable(path: url)) { try Bare().loadXML(url) }
        await #expect(throws: DataFailure.unreadable(path: url)) { try await Bare().requestXML(url) }
    }

    @Test("URL として組めない綴りは unreachable で投げる")
    func unusableURL() {
        #expect(throws: DataFailure.unreachable(url: "https://", reason: "this is not a URL that can be requested")) {
            try Bare().loadJSONObject("https://")
        }
    }
}
