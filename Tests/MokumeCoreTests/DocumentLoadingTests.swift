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

    /// 負の側は `JSONSerialization` が投げずに `-inf` として返す。壊れていた位置もくれないので、
    /// 本体が文字から探して名乗る (#2329)。
    @Test(
        "Double に収まらない負の数も壊れた JSON で、その数が書かれた行と列を名乗る",
        arguments: [
            ("負の大きな指数", #"{"a": -1e400}"#, 1, 7, "-1e400"),
            ("Double の最小値の少し外", #"{"a": -1.8e308}"#, 1, 7, "-1.8e308"),
            ("大文字の E", #"{"a": -1E400}"#, 1, 7, "-1E400"),
            ("配列の中", #"{"a": [-1e400]}"#, 1, 8, "-1e400"),
            ("入れ子の中", #"{"o": {"a": -1e400}}"#, 1, 13, "-1e400"),
            ("2 行目", "{\n\"a\": -1e400}", 2, 6, "-1e400"),
            ("CRLF の行", "{\"a\": [1,\r\n-1e400]}", 2, 1, "-1e400"),
            ("CR の行", "{\"a\": [1,\r\r -1e400]}", 3, 2, "-1e400"),
            // 文字列の中の数の綴りと、閉じない引用符 (\") は数として読まない
            ("文字列の中は数でない", "{\"s\": \"-1e400 \\\" -1e999\",\n\"a\":\n -1e400}", 3, 2, "-1e400"),
            // 収まる負の数より後ろにある、収まらない数を名乗る
            ("収まる数の後ろ", "{\"x\": -1e300, \"y\": -2,\n \"a\": -1e999}", 2, 7, "-1e999"),
            // 列は文字で数える (``JSONFile`` の行と列の数え方)
            ("日本語の後ろ", "{\"札幌\": -1e400}", 1, 8, "-1e400"),
            // `JSONSerialization` は重複したキーの先の値を残し、後ろの -inf は木から落ちる
            ("重複したキーの後ろ", "{\"a\": 1,\n\"a\": -1e400}", 2, 6, "-1e400"),
            // 壊れた箇所が複数あれば、符号によらず文字の中で最初のものを名乗る
            ("正の数より前", "{\"a\": -1e400,\n\"b\": 1e400}", 1, 7, "-1e400"),
            ("負の数より前", "{\"a\": [1e400,\n-1e400]}", 1, 8, "1e400"),
            ("配列の中で正の数より前", "[-1e400, 1e400]", 1, 2, "-1e400"),
        ])
    func negativeOverflowIsMalformed(
        _ name: String, _ text: String, _ line: Int, _ column: Int, _ literal: String
    ) throws {
        defer { cleanUp() }
        let path = try file("negative.json", text)
        let broken = malformedLine { () throws(DataFailure) in _ = try Bare().loadJSONObject(path) }
        #expect(broken?.line == line, "\(name)")
        #expect(broken?.reason.hasSuffix("(column \(column))") == true, "\(name): \(broken?.reason ?? "")")
        #expect(broken?.reason.contains(literal) == true, "\(name): \(broken?.reason ?? "")")
    }

    @Test("Double に収まらない数は、符号によらず同じ行と同じ形の文面を名乗る")
    func overflowNamesSameLineEitherSign() throws {
        defer { cleanUp() }
        let positive = try file("positive.json", "{\n\"a\": 1e400}")
        let negative = try file("negative.json", "{\n\"a\": -1e400}")
        let up = malformedLine { () throws(DataFailure) in _ = try Bare().loadJSONObject(positive) }
        let down = malformedLine { () throws(DataFailure) in _ = try Bare().loadJSONObject(negative) }
        #expect(up?.line == 2)
        #expect(down?.line == up?.line)
        #expect(up?.reason == "Number 1e400 does not fit in a Double (column 6)")
        #expect(down?.reason == "Number -1e400 does not fit in a Double (column 6)")
    }

    @Test(
        "数の形が崩れた綴りは、大きくても収まらない数とは名乗らない",
        arguments: ["{\"a\": 1.e400}", "{\"a\": 01e400}", "{\"a\": -e400}", "{\"a\": 1e+}"])
    func malformedNumbersAreNotUnfit(_ text: String) throws {
        defer { cleanUp() }
        let path = try file("syntax.json", text)
        let broken = malformedLine { () throws(DataFailure) in _ = try Bare().loadJSONObject(path) }
        #expect(broken?.line == 1)
        #expect(broken?.reason.contains("does not fit") == false, "\(broken?.reason ?? "")")
    }

    @Test("Double に収まらない負の数は、待たない版でも URL の本文でも同じ失敗で投げる")
    func negativeOverflowSameForEveryDoor() async throws {
        defer { cleanUp() }
        let text = "{\"o\": {\n\"a\": [-1e400]}}"
        let path = try file("negative.json", text)
        let failure = #expect(throws: DataFailure.self) { try Bare().loadJSONObject(path) }
        guard let failure, case .malformed(_, 2, let reason) = failure else {
            Issue.record("line 2 の malformed で投げていない: \(String(describing: failure))")
            return
        }
        await #expect(throws: failure) { try await Bare().requestJSONObject(path) }

        // URL の本文は、名前が URL になるほかはファイルと同じ失敗
        let url = CannedResponses.serve(text)
        let expected = DataFailure.malformed(path: url, line: 2, reason: reason)
        #expect(throws: expected) { try Bare().loadJSONObject(url) }
        await #expect(throws: expected) { try await Bare().requestJSONObject(url) }
    }

    @Test("Double の最小値ちょうどは読め、Float に収まらないので getFloat は負の無限大")
    func mostNegativeDoubleReads() throws {
        defer { cleanUp() }
        let object = try Bare().loadJSONObject(try file("edge.json", #"{"a": -1.7976931348623157e308}"#))
        #expect(object.members["a"] == .number(-.greatestFiniteMagnitude))
        #expect(object.getFloat("a") == -.infinity)
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

    // MARK: - XML 宣言の encoding (#2332)

    /// 中身は常に UTF-8 で書き、**ASCII でない文字を属性の値とコメントに持たせる**
    /// (ASCII だけなら、宣言が何でも libxml2 は読めてしまう)。
    private static let starryBody = #"<sky><星 x="値é"/><!-- 星 --></sky>"#

    /// 宣言だけを替える。**どれも `loadXML` の約束 (文字は UTF-8) の内側では、宣言の無いときと同じ木になる。**
    private nonisolated static let declarations: [(name: String, text: String)] = [
        ("宣言なし", ""),
        ("UTF-8", #"<?xml version="1.0" encoding="UTF-8"?>"#),
        ("Shift_JIS", #"<?xml version="1.0" encoding="Shift_JIS"?>"#),
        ("一重引用符", "<?xml version='1.0' encoding='Shift_JIS'?>"),
        ("ISO-8859-1", #"<?xml version="1.0" encoding="ISO-8859-1"?>"#),
        ("UTF-16", #"<?xml version="1.0" encoding="UTF-16"?>"#),
        ("= の前後に空白", #"<?xml version="1.0" encoding = "Shift_JIS" ?>"#),
        ("standalone が続く", #"<?xml version="1.0" encoding="Shift_JIS" standalone="yes"?>"#),
        ("複数行にまたがる", "<?xml\n version=\"1.0\"\n encoding=\"Shift_JIS\"\n?>"),
        ("複数行にまたがる (CRLF)", "<?xml\r\n version=\"1.0\"\r\n encoding=\"Shift_JIS\"\r\n?>"),
        ("複数行にまたがる (CR)", "<?xml\r version=\"1.0\"\r encoding=\"Shift_JIS\"\r?>"),
        // 名前の形 (英字で始まり、英数字と . _ -) をしていれば、知らない名前でも読む
        ("無い名前", #"<?xml version="1.0" encoding="nonsense"?>"#),
        ("_ を含む名前", #"<?xml version="1.0" encoding="x_y.z-1"?>"#),
    ]

    /// 値が名前の形 (XML 1.0 の `EncName`) をしていない宣言。XML として壊れているので、これまでどおり
    /// `malformed` で投げる。
    private nonisolated static let malformedDeclarations: [(name: String, text: String)] = [
        ("空の名前", #"<?xml version="1.0" encoding=""?>"#),
        ("数字で始まる名前", #"<?xml version="1.0" encoding="1abc"?>"#),
        ("空白を含む名前", #"<?xml version="1.0" encoding="Shift JIS"?>"#),
        ("ASCII でない名前", #"<?xml version="1.0" encoding="é"?>"#),
        ("一重引用符の空の名前", "<?xml version='1.0' encoding=''?>"),
    ]

    @Test("宣言の encoding が何でも、UTF-8 として読んだ同じ木になる", arguments: declarations)
    func declaredEncodingIsNotRead(_ name: String, _ declaration: String) throws {
        defer { cleanUp() }
        let sky = try Bare().loadXML(try file("sky.xml", declaration + Self.starryBody))
        #expect(sky.element.name == "sky", "\(name)")
        #expect(sky.getChildren("星").count == 1, "\(name)")
        #expect(sky.getChildren("星").first?.element.attributes == ["x": "値é"], "\(name)")
    }

    @Test("URL の本文も、待たない版も、宣言の encoding を読まない")
    func declaredEncodingIsNotReadFromURLs() async throws {
        let url = CannedResponses.serve(#"<?xml version="1.0" encoding="Shift_JIS"?>"# + Self.starryBody)
        let waited = try Bare().loadXML(url)
        #expect(waited.getChildren("星").first?.element.attributes == ["x": "値é"])
        #expect(try await Bare().requestXML(url) == waited)
        defer { cleanUp() }
        let path = try file("sky.xml", #"<?xml version="1.0" encoding="ISO-8859-1"?>"# + Self.starryBody)
        #expect(try await Bare().requestXML(path) == waited)
    }

    @Test("宣言を扱っても、壊れた行は動かない", arguments: declarations)
    func declarationDoesNotShiftTheLine(_ name: String, _ declaration: String) throws {
        defer { cleanUp() }
        // 宣言の後の行で壊れる (4 行目の `</c>` が閉じる名前の食い違い)。宣言が何行を使っても、
        // 宣言の行数の分だけ後ろへ下がるだけで、宣言の書き換えが行を足し引きしない
        let used = TextFile.lines(of: declaration + "x").count - 1
        let path = try file("broken.xml", declaration + "\n<sky>\n<星/>\n</c>\n</sky>")
        let broken = malformedLine { () throws(DataFailure) in _ = try Bare().loadXML(path) }
        #expect(broken?.line == used + 4, "\(name)")
    }

    @Test("値が名前の形でない宣言は、書き換えず、これまでどおり malformed で投げる", arguments: malformedDeclarations)
    func declarationsThatAreNotNamesStayMalformed(_ name: String, _ declaration: String) async throws {
        defer { cleanUp() }
        let path = try file("broken.xml", declaration + Self.starryBody)
        let broken = malformedLine { () throws(DataFailure) in _ = try Bare().loadXML(path) }
        #expect(broken?.line == 1, "\(name)")
        #expect(broken?.reason.isEmpty == false, "\(name)")
        // 待たない版も同じ失敗で投げる
        guard let failure = #expect(throws: DataFailure.self, "\(name)", performing: { try Bare().loadXML(path) })
        else { return }
        await #expect(throws: failure, "\(name)") { try await Bare().requestXML(path) }
    }

    @Test("先頭に BOM が残っても、宣言の encoding を読まない。BOM が 2 つのファイルは 1 つ残る")
    func declaredEncodingIsNotReadAfterLeftoverBOM() throws {
        defer { cleanUp() }
        let bom = Data([0xEF, 0xBB, 0xBF])
        let shiftJIS = Data((#"<?xml version="1.0" encoding="Shift_JIS"?>"# + Self.starryBody).utf8)
        let undeclared = Data(Self.starryBody.utf8)
        // `TextFile` は BOM を 1 つしか落とさない。BOM が 2 つのファイルでは 1 つが残り、libxml2 は
        // それを読み飛ばしてから宣言を読む
        for (name, count, body) in [
            ("BOM 1 つ・Shift_JIS", 1, shiftJIS), ("BOM 2 つ・Shift_JIS", 2, shiftJIS),
            ("BOM 1 つ・宣言なし", 1, undeclared), ("BOM 2 つ・宣言なし", 2, undeclared),
        ] {
            var bytes = Data()
            for _ in 0..<count { bytes.append(bom) }
            bytes.append(body)
            let sky = try Bare().loadXML(try file("bom-\(name).xml", bytes))
            #expect(sky.getChildren("星").first?.element.attributes == ["x": "値é"], "\(name)")
        }
    }

    @Test("宣言が Shift_JIS でも、中身が本当に Shift_JIS のバイトなら、これまでどおり unreadable")
    func realShiftJISBytesAreStillUnreadable() throws {
        defer { cleanUp() }
        // 「ス」の Shift_JIS (0x83 0x58) は UTF-8 としては読めない。宣言に従って読み分ける道は開かない
        var bytes = Data(#"<?xml version="1.0" encoding="Shift_JIS"?><a x=""#.utf8)
        bytes.append(contentsOf: [0x83, 0x58])
        bytes.append(Data(#""/>"#.utf8))
        let path = try file("sjis.xml", bytes)
        #expect(throws: DataFailure.unreadable(path: path)) { try Bare().loadXML(path) }
    }

    @Test("宣言の外に書かれた encoding=\"…\" は書き換えない")
    func encodingTextOutsideTheDeclarationIsKept() throws {
        defer { cleanUp() }
        let body = #"<sky note='encoding="Shift_JIS"'><!-- encoding="Shift_JIS" --></sky>"#
        for declaration in ["", #"<?xml version="1.0"?>"#, #"<?xml version="1.0" encoding="Shift_JIS"?>"#] {
            let sky = try Bare().loadXML(try file("note.xml", declaration + body))
            #expect(sky.element.attributes["note"] == #"encoding="Shift_JIS""#, "\(declaration)")
        }
    }

    @Test("XMLParser に渡すバイトは、先頭の XML 宣言の encoding の値だけを UTF-8 にする")
    func onlyTheDeclarationsEncodingValueIsRewritten() {
        func passed(_ source: String) -> String { String(decoding: XMLFile.document(of: source), as: UTF8.self) }
        #expect(
            passed(#"<?xml version="1.0" encoding="Shift_JIS" standalone="no"?><a/>"#)
                == #"<?xml version="1.0" encoding="UTF-8" standalone="no"?><a/>"#)
        #expect(
            passed("<?xml version='1.0'  encoding = 'ISO-8859-1' ?><a/>")
                == "<?xml version='1.0'  encoding = 'UTF-8' ?><a/>")
        // 先頭に残った BOM (``TextFile/text(of:path:)`` は 1 つしか落とさない) は残したまま、その後ろの
        // 宣言を書き換える。いくつ並んでいても飛ばして探す
        #expect(
            passed("\u{FEFF}" + #"<?xml version="1.0" encoding="Shift_JIS"?><a/>"#)
                == "\u{FEFF}" + #"<?xml version="1.0" encoding="UTF-8"?><a/>"#)
        #expect(
            passed("\u{FEFF}\u{FEFF}" + #"<?xml version="1.0" encoding="Shift_JIS"?><a/>"#)
                == "\u{FEFF}\u{FEFF}" + #"<?xml version="1.0" encoding="UTF-8"?><a/>"#)
        // 宣言でないもの・書き換えるものが無いものは、そのまま渡す
        for same in [
            #"<?xml-stylesheet href="a.css" encoding="Shift_JIS"?><a/>"#,
            // 空白が前にある宣言は先頭にない。libxml2 が断るので、触らない
            #" <?xml version="1.0" encoding="Shift_JIS"?><a/>"#,
            #"<!-- --><?xml version="1.0" encoding="Shift_JIS"?><a/>"#,
            #"<?xml version="1.0"?><a note='encoding="Shift_JIS"'/>"#,
            #"<?xml version="1.0" encoding="utf-8"?><a/>"#,
            #"<?xml version="1.0" encoding="Shift_JIS"#,  // 引用符が閉じていない
            // 値が名前の形でない宣言は、XML として壊れている。触らず libxml2 に言わせる
            #"<?xml version="1.0" encoding=""?><a/>"#,
            #"<?xml version="1.0" encoding="1abc"?><a/>"#,
            #"<?xml version="1.0" encoding="Shift JIS"?><a/>"#,
            #"<?xml version="1.0" encoding="é"?><a/>"#,
            "<a/>",
            "",
        ] {
            #expect(passed(same) == same)
        }
    }

    @Test("宣言の書き換えと CR の LF への置き換えは、同じ文書の中で両方効く")
    func declarationAndLineBreaksTogether() {
        func passed(_ source: String) -> String { String(decoding: XMLFile.document(of: source), as: UTF8.self) }
        // 宣言が CR で改行している。値の前の CR も、後ろの CR も LF になり、値だけが UTF-8 になる
        #expect(
            passed("<?xml\r version=\"1.0\"\r encoding=\"Shift_JIS\"\r?>\r\n<a x=\"1\r2\"/>\r")
                == "<?xml\n version=\"1.0\"\n encoding=\"UTF-8\"\n?>\n<a x=\"1\n2\"/>\n")
        // CR の無い文書は、元のバイトと同じ (宣言が UTF-8 でも、無くても)
        #expect(passed("<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<a/>\n") == "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<a/>\n")
        #expect(passed("<a x=\"星\"/>\n") == "<a x=\"星\"/>\n")
        // CR だけで宣言が無い文書も、LF になる
        #expect(passed("<a>\r<b/>\r</a>") == "<a>\n<b/>\n</a>")
    }

    @Test("XMLParser に渡すバイトは、CRLF と単独の CR を LF にする (文字参照の CR は触れない)")
    func lineBreaksArePassedAsLF() {
        func passed(_ source: String) -> String { String(decoding: XMLFile.document(of: source), as: UTF8.self) }
        #expect(passed("<a x=\"1\r2\">\r\n<b/>\r\r\n</a>\r") == "<a x=\"1\n2\">\n<b/>\n\n</a>\n")
        #expect(passed("<a x=\"&#13;\">\n</a>") == "<a x=\"&#13;\">\n</a>")
        #expect(passed("<a>星\r値</a>") == "<a>星\n値</a>")
    }

    // MARK: - XML の行の終わり (#2331)

    /// 行の終わりの 3 通り。どれも 1 つの行の終わり (``TextFile/lines(of:)``)。
    private static let lineBreaks: [(name: String, text: String)] = [
        ("LF", "\n"), ("CRLF", "\r\n"), ("CR", "\r"),
    ]

    @Test(
        "行の終わりが LF・CRLF・CR のどれでも、壊れた XML は同じ行を名乗る",
        arguments: [
            ("閉じる名前の食い違い", "<a>\n<b>\n<x/>\n</c>\n</a>", 4),
            ("引用符の無い属性", "<a>\n<b x=1/>\n</a>", 2),
            ("不正な文字", "<a>\n\u{01}</a>", 2),
            ("根が 2 つ", "<a/>\n<b/>", 2),
            ("定義の無い実体", "<a>\n\n&nope;</a>", 3),
            ("閉じない要素", "<a>\n<b/>\n", 2),
            ("閉じ忘れた根の後ろの改行", "<a>\n<b>\n<x/>\n", 3),
            ("空白だけ", "  \n  \n", 2),
        ])
    func malformedXMLNamesTheSameLineWithAnyBreak(_ name: String, _ text: String, _ line: Int) throws {
        defer { cleanUp() }
        for (kind, lineBreak) in Self.lineBreaks {
            let path = try file("broken-\(kind).xml", text.replacingOccurrences(of: "\n", with: lineBreak))
            let broken = malformedLine { () throws(DataFailure) in _ = try Bare().loadXML(path) }
            #expect(broken?.line == line, "\(name) (\(kind))")
        }
    }

    @Test("libxml2 が文面に添える行も、CR だけの文書で LF の文書と同じになる")
    func reasonNamesTheSameLineWithAnyBreak() throws {
        defer { cleanUp() }
        // 「Opening and ending tag mismatch: b line 2 and c」の `line 2` は libxml2 自身の数えた行
        let text = "<a>\n<b>\n<x/>\n</c>\n</a>"
        var reasons: [String] = []
        for (kind, lineBreak) in Self.lineBreaks {
            let path = try file("reason-\(kind).xml", text.replacingOccurrences(of: "\n", with: lineBreak))
            reasons.append(
                malformedLine { () throws(DataFailure) in _ = try Bare().loadXML(path) }?.reason ?? "")
        }
        #expect(reasons[0].contains("b line 2"), "\(reasons[0])")
        #expect(reasons == [String](repeating: reasons[0], count: 3), "\(reasons)")
    }

    @Test("深すぎる入れ子も、行の終わりによらず同じ行を名乗る")
    func deepXMLNamesTheSameLineWithAnyBreak() throws {
        defer { cleanUp() }
        for (kind, lineBreak) in Self.lineBreaks {
            // 1 行に 1 つ開く。514 番目 (根の下に 513 段目) を開いた行で投げる
            let text =
                String(repeating: "<a>" + lineBreak, count: 514)
                + String(repeating: "</a>" + lineBreak, count: 514)
            let path = try file("deep-\(kind).xml", text)
            let broken = malformedLine { () throws(DataFailure) in _ = try Bare().loadXML(path) }
            #expect(broken?.line == 514, "\(kind)")
            #expect(broken?.reason.contains("deeper than 512 levels") == true, "\(kind)")
        }
    }

    @Test("属性の値の改行は、行の終わりによらず空白 1 つ。文字参照で書いた CR・LF はそのまま")
    func lineBreaksInAttributeValues() throws {
        defer { cleanUp() }
        for (kind, lineBreak) in Self.lineBreaks {
            let path = try file("value-\(kind).xml", "<a x=\"1\(lineBreak)2\" y=\"1&#13;2\" z=\"1&#10;2\"/>")
            #expect(
                try Bare().loadXML(path).element.attributes == ["x": "1 2", "y": "1\r2", "z": "1\n2"],
                "\(kind)")
        }
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

    // MARK: - URL を待つ期限 (#2264)

    /// 同期の受け取り (``WebFile/fetchWaiting(_:path:limit:)``) を、期限を `limit` に縮めて別の糸で
    /// 走らせ、結果とかかった時間を返す。
    ///
    /// **待つ側 (この検査) も期限を持つ。** `limit` に 3 秒足した時間を越えたら、応答を打ち切って
    /// (``CannedResponses/cut(_:)``) `nil` を返す — 期限で返らない実装でも、検査は止まらずに赤になる。
    /// `.timeLimit` は使わない (main actor の上で検査全体の秒数を縛るため)。
    private func fetchOffMain(
        _ url: String, limit: Duration
    ) -> (outcome: Result<Data, DataFailure>, called: ContinuousClock.Instant, took: Duration)? {
        // 受け取りの糸が書き、合図を待った後にだけ読む (打ち切ったときは読まない)
        nonisolated final class Box: @unchecked Sendable {
            var outcome: Result<Data, DataFailure>?
            var called = ContinuousClock.now
            var took = Duration.zero
        }
        guard let target = URL(string: url) else {
            Issue.record("URL として組めない: \(url)")
            return nil
        }
        let box = Box()
        let returned = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            let clock = ContinuousClock()
            let start = clock.now
            box.called = start
            box.outcome = Result { () throws(DataFailure) in try WebFile.fetchWaiting(target, path: url, limit: limit) }
            box.took = clock.now - start
            returned.signal()
        }
        let patience = (limit + .seconds(3)) / .seconds(1)
        guard returned.wait(timeout: .now() + patience) == .success else {
            CannedResponses.cut(url)
            _ = returned.wait(timeout: .now() + patience)
            return nil
        }
        return box.outcome.map { ($0, box.called, box.took) }
    }

    @Test("少しずつ返し続ける応答でも、呼んでからの総時間が期限を越えたら取り消して unreachable で投げる")
    func tricklePastLimitIsUnreachable() throws {
        // 20 ミリ秒ごとに 1 バイト。音沙汰の無い間は期限に届かないので、受け口の時間切れでは切れない。
        // **ただしそれは、呼んでから返るまで、期限以上の空白が 1 度も無かった回に限る** — 並列の
        // 負荷の下では、届き始めるまでに期限が過ぎる回がある (#2689)。その回は受け口の時間切れでも
        // 同じ失敗で返り、総時間で切る実装かを見分けられないので、新しい応答でやり直す
        let limit = Duration.milliseconds(300)
        for _ in 1...5 {
            let url = CannedResponses.serve(.trickle(body: Data(repeating: 0x20, count: 100_000), every: .milliseconds(20)))
            let returned = try #require(fetchOffMain(url, limit: limit), "期限で返らず、検査の側の期限で打ち切った")
            let arrivals = CannedResponses.arrivals(url)
            let marks = [returned.called] + arrivals + [returned.called + returned.took]
            let longestSilence = zip(marks, marks.dropFirst()).map { $1 - $0 }.max() ?? .zero
            guard arrivals.count >= 2, longestSilence < limit else { continue }
            #expect(
                returned.outcome
                    == .failure(.unreachable(url: url, reason: "no complete answer came back within 0.3 seconds")))
            #expect(returned.took >= limit)
            // 諦めた受け取りは取り消すので、受け口が応答を止める。止めるのは受け口の糸で少し遅れる
            // ので、待つ側が 2 秒の期限を持って待つ
            let until = ContinuousClock.now + .seconds(2)
            while !CannedResponses.stopped(url), ContinuousClock.now < until { Thread.sleep(forTimeInterval: 0.01) }
            #expect(CannedResponses.stopped(url), "期限を越えた受け取りを取り消していない")
            return
        }
        try Test.cancel("5 回とも、期限 0.3 秒以上の空白を挟まずに本文を返し続けられなかった (前提の不成立)")
    }

    @Test("何も返さない応答も、期限で取り消して同じ unreachable で投げる")
    func silencePastLimitIsUnreachable() throws {
        // 受け口の時計と待つ側の期限が同じ値で競る。受け口の時間切れを畳む処理
        // (`WebFile.failure(of:path:limit:)`) を外しても、この検査は**確率でしか赤くならない**
        // (受け口の時間切れが先に届いた回だけ赤)。畳み込みは下の「受け口の時間切れは…」が、
        // 競り合いに依らない決まった結果で見る
        let url = CannedResponses.serve(.silent)
        let limit = Duration.milliseconds(300)
        let returned = try #require(fetchOffMain(url, limit: limit), "期限で返らず、検査の側の期限で打ち切った")
        #expect(
            returned.outcome == .failure(.unreachable(url: url, reason: "no complete answer came back within 0.3 seconds")))
        #expect(returned.took >= limit)
    }

    @Test("何も返さない応答には、同期版と待たない版が同じ失敗の値を投げる")
    func silenceFailsAlikeForBothWaits() async throws {
        let url = CannedResponses.serve(.silent)
        let target = try #require(URL(string: url))
        let limit = Duration.milliseconds(300)
        let waited = try #require(fetchOffMain(url, limit: limit), "同期版が期限で返らず、検査の側の期限で打ち切った")
        // 待たない版にも、待つ側 (この検査) が期限を持つ。越えたら応答を打ち切るので、受け口の
        // 期限で返らない実装でも検査は止まらない (打ち切ると「取り消した」で返り、下の比べで赤になる)
        let cutoff = DispatchWorkItem { CannedResponses.cut(url) }
        DispatchQueue.global().asyncAfter(deadline: .now() + (limit + .seconds(3)) / .seconds(1), execute: cutoff)
        defer { cutoff.cancel() }
        let requested: Result<Data, DataFailure>
        do {
            requested = .success(try await WebFile.fetch(target, path: url, limit: limit))
        } catch {
            requested = .failure(error)
        }
        #expect(requested == waited.outcome)
        #expect(requested == .failure(.unreachable(url: url, reason: "no complete answer came back within 0.3 seconds")))
    }

    @Test("受け口の時間切れは、期限の間に答えが完結しなかった失敗に畳む。他の誤りは受け口の事情のまま")
    func sessionTimeoutFoldsIntoOverdue() {
        let url = "https://folding.test/data"
        let overdue = DataFailure.unreachable(url: url, reason: "no complete answer came back within 60.0 seconds")
        #expect(WebFile.overdue(path: url, limit: .seconds(60)) == overdue)
        // 受け口は時間切れを URLError でも、NSURLErrorDomain の NSError でも渡しうる。どちらも畳む
        #expect(WebFile.failure(of: URLError(.timedOut), path: url, limit: .seconds(60)) == overdue)
        let timedOut = NSError(domain: NSURLErrorDomain, code: NSURLErrorTimedOut)
        #expect(WebFile.failure(of: timedOut, path: url, limit: .seconds(60)) == overdue)
        let refused = URLError(.cannotConnectToHost)
        #expect(
            WebFile.failure(of: refused, path: url, limit: .seconds(60))
                == .unreachable(url: url, reason: refused.localizedDescription))
    }

    @Test("期限より早く刻み終える応答は、少しずつ届いても読める")
    func trickleWithinLimitIsRead() throws {
        let body = Data(#"{"t": 1}"#.utf8)
        let url = CannedResponses.serve(.trickle(body: body, every: .milliseconds(10)))
        // 刻み終えるのは 0.1 秒ほどだが、負荷の下でも期限の内に収まる長さにしておく (#2689)
        let returned = try #require(fetchOffMain(url, limit: .seconds(5)), "期限で返らず、検査の側の期限で打ち切った")
        #expect(returned.outcome == .success(body))
        #expect(CannedResponses.delivered(url) == body.count)
    }

    @Test("同期の待ちの期限は、loadJSONObject の説明が名乗る「最長 60 秒」と同じ数")
    func waitLimitIsTheDocumentedSixtySeconds() {
        // 変えるなら、`loadJSONObject(_:)` の説明 (Sketch+Data.swift) の秒数も同じ PR で直す
        #expect(WebFile.waitLimit == .seconds(60))
    }
}
