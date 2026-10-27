// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation
import MokumeTestSupport
import Testing

@testable import MokumeCore

/// JSON から文字・整数・真偽・配列を取り出す口と、最上位が配列の JSON (#2466)。XML の子の文字と属性の文字。
///
/// 走っているスケッチも GPU も要らない。**URL は外へ出ない** — 応答は ``CannedResponses`` が返す。
///
/// **知らせの控えはプロセスで 1 つで、同じ鍵は 1 度しか言わない。** キーの知らせは検査ごとの一意なキーで
/// 引く。配列の知らせは鍵が「口の名前 × 事情」で一意にできないので、**口ごとに 1 つの検査が持ち**、
/// 他の検査は同じ口の知らせを引かない (値だけを見る)。
@Suite("JSON の文字・整数・真偽・配列と XML の文字")
struct JSONReadingTests {
    final class Bare: Sketch {
        init() {}
        func draw() {}
    }

    private let folder = TestScratch.path("mokume-json-reading")

    private func file(_ name: String, _ text: String) throws -> String {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent(name)
        try Data(text.utf8).write(to: url)
        return url.path
    }

    private func cleanUp() { try? FileManager.default.removeItem(at: folder) }

    private func object(_ text: String) throws -> JSONObject {
        try Bare().parseJSONObject(text)
    }

    private func array(_ text: String) throws -> JSONArray {
        try Bare().parseJSONArray(text)
    }

    /// その鍵で言った知らせの文面。
    private func said(_ warning: DocumentValues.Warning) -> String? {
        DocumentValues.warnings.message(for: warning)
    }

    private func unique(_ stem: String = "k") -> String { "\(stem)-\(UUID().uuidString)" }

    // MARK: - 完了条件 1: 作例

    /// 本文の作例の応答。`features` が 2 件で、1 件は規模 5.5・地名 "Off the coast"・経緯度 142.4, 38.3。
    private static let quakes = """
        {"type": "FeatureCollection", "features": [
          {"properties": {"mag": 5.5, "place": "Off the coast"},
           "geometry": {"coordinates": [142.4, 38.3, 10]}},
          {"properties": {"mag": 2.1, "place": "Near the ridge"},
           "geometry": {"coordinates": [-122.5, 37.8, 4.5]}}
        ]}
        """

    @Test("作例: 地震の GeoJSON を URL から読み、配列・文字・数を取り出す")
    func quakeSampleReads() throws {
        let url = CannedResponses.serve(Self.quakes)
        let root = try Bare().loadJSONObject(url)
        let features = root.getJSONArray("features")
        #expect(features.count == 2)
        let first = features[0]
        let coordinates = first.getJSONObject("geometry").getJSONArray("coordinates")
        let properties = first.getJSONObject("properties")
        #expect(coordinates.getFloat(0) == 142.4)
        #expect(coordinates.getFloat(1) == 38.3)
        #expect(properties.getString("place") == "Off the coast")
        #expect(properties.getFloat("mag") == 5.5)

        // 本文の作例の式そのまま (for-in で回し、円の位置と大きさを求める)
        var circles: [(x: Float, y: Float, size: Float)] = []
        var labels: [String] = []
        for f in root.getJSONArray("features") {
            let c = f.getJSONObject("geometry").getJSONArray("coordinates")
            let p = f.getJSONObject("properties")
            circles.append((c.getFloat(0) / 180 * 100, c.getFloat(1) / 90 * 100, p.getFloat("mag") * 4))
            if p.getFloat("mag") > 5 { labels.append(p.getString("place")) }
        }
        #expect(circles.count == 2)
        #expect(circles[0].size == 22)
        #expect(labels == ["Off the coast"], "大きな地震だけ地名を添える")
    }

    // MARK: - 完了条件 2: 最上位が配列

    @Test("loadJSONArray はファイルの最上位の配列を読む。requestJSONArray・parseJSONArray も同じ")
    func topLevelArrayReads() async throws {
        defer { cleanUp() }
        let path = try file("numbers.json", "[1, 2, 3]")
        let sketch = Bare()
        let loaded = try sketch.loadJSONArray(path)
        #expect(loaded.count == 3)
        #expect(loaded.getFloat(2) == 3)
        #expect(try await sketch.requestJSONArray(path) == loaded)
        #expect(try sketch.parseJSONArray("[1, 2, 3]") == loaded)
    }

    @Test("URL の扱いは loadJSONObject と同じ。2xx 以外は届かなかったものとして投げる")
    func arrayFromURL() async throws {
        let url = CannedResponses.serve("[1, 2, 3]")
        let sketch = Bare()
        #expect(try sketch.loadJSONArray(url).count == 3)
        #expect(try await sketch.requestJSONArray(url).getFloat(0) == 1)

        let missing = CannedResponses.serve("[]", status: 404)
        let failure = #expect(throws: DataFailure.self) { try sketch.loadJSONArray(missing) }
        guard case .unreachable(let named, _) = failure else {
            Issue.record("unreachable で投げていない: \(String(describing: failure))")
            return
        }
        #expect(named == missing)
    }

    @Test("loadJSONObject に最上位の配列を渡すと malformed で投げ、読む口 loadJSONArray を名乗る")
    func objectReaderPointsAtArrayReader() async throws {
        defer { cleanUp() }
        let path = try file("top.json", "\n[1, 2, 3]\n")
        let sketch = Bare()

        let load = #expect(throws: DataFailure.self) { try sketch.loadJSONObject(path) }
        guard case .malformed(let named, let line, let reason) = load else {
            Issue.record("malformed で投げていない: \(String(describing: load))")
            return
        }
        #expect(named == path)
        #expect(line == 2, "最上位の値が始まる行")
        #expect(reason.contains("an array"))
        #expect(reason.contains("loadJSONArray(_:)"), "\(reason)")

        let request = await #expect(throws: DataFailure.self) { try await sketch.requestJSONObject(path) }
        guard case .malformed(_, _, let requestReason) = request else {
            Issue.record("malformed で投げていない: \(String(describing: request))")
            return
        }
        #expect(requestReason.contains("requestJSONArray(_:)"), "\(requestReason)")

        let parse = #expect(throws: DataFailure.self) { try sketch.parseJSONObject("[1]") }
        guard case .malformed(_, _, let parseReason) = parse else {
            Issue.record("malformed で投げていない: \(String(describing: parse))")
            return
        }
        #expect(parseReason.contains("parseJSONArray(_:)"), "\(parseReason)")
    }

    @Test("loadJSONArray にオブジェクトを渡すと malformed で loadJSONObject を名乗り、数や文字は案内を付けない")
    func arrayReaderPointsAtObjectReader() throws {
        defer { cleanUp() }
        let sketch = Bare()
        let object = #expect(throws: DataFailure.self) {
            try sketch.loadJSONArray(try file("object.json", #"{"a": 1}"#))
        }
        guard case .malformed(_, _, let reason) = object else {
            Issue.record("malformed で投げていない: \(String(describing: object))")
            return
        }
        #expect(reason.contains("not an array"))
        #expect(reason.contains("loadJSONObject(_:)"), "\(reason)")

        let number = #expect(throws: DataFailure.self) { try sketch.parseJSONArray("42") }
        guard case .malformed(_, _, let numberReason) = number else {
            Issue.record("malformed で投げていない: \(String(describing: number))")
            return
        }
        #expect(numberReason.contains("a number") || numberReason.contains("42"), "\(numberReason)")
        #expect(!numberReason.contains("Read it with"), "配列でもオブジェクトでもない値には案内が付かない")
    }

    @Test("走っていない所 (init の外の素のスケッチ) でも、読む口は loadJSONObject と同じく読める")
    func readsOutsideARun() throws {
        defer { cleanUp() }
        let path = try file("a.json", "[true]")
        #expect(try Bare().loadJSONArray(path).getBoolean(0))
    }

    // MARK: - 完了条件 3: 欠けた値

    @Test("無いキー・型の違う値は空の値を返し、キーごとに 1 度だけ知らせる")
    func missingAndWrongValuesAreEmpty() throws {
        let key = unique()
        let kinds = try object(
            #"{"\#(key)": 18.5, "text": "abc", "flag": true, "nothing": null, "list": [1], "map": {"a": 1}}"#)
        let gone = unique("gone")

        #expect(kinds.getString(gone) == "")
        #expect(kinds.getInt(gone) == 0)
        #expect(kinds.getBoolean(gone) == false)
        #expect(kinds.getJSONArray(gone).isEmpty)
        #expect(kinds.getJSONObject(gone) == JSONObject([:]))
        #expect(said(.noKey(gone))?.contains("getString") == true, "最初の口が名乗る")

        // 型の違い: 数は文字でない・文字は真偽でない・真偽は配列でない…
        #expect(kinds.getString(key) == "")
        #expect(said(.notAString(key: key))?.contains("is 18.5, which is not a string") == true)
        let k2 = unique()
        let wrong = try object(#"{"\#(k2)": "yes"}"#)
        #expect(wrong.getBoolean(k2) == false)
        #expect(said(.notABoolean(key: k2))?.contains(#"is "yes", which is not a boolean"#) == true)
        #expect(wrong.getJSONArray(k2).isEmpty)
        #expect(said(.notAnArray(key: k2))?.contains("which is not an array") == true)
        #expect(wrong.getInt(k2) == 0)
        #expect(said(.notAnInteger(key: k2))?.contains(#"is "yes""#) == true)
        #expect(kinds.getString("nothing") == "")
        #expect(kinds.getJSONArray("map").isEmpty)

        // 1 度だけ: 同じ鍵の文面は 2 度目の呼びで変わらない
        let before = said(.notAString(key: key))
        _ = kinds.getString(key)
        #expect(said(.notAString(key: key)) == before)
    }

    @Test("読めた値は知らせない (文字・真偽・配列・入れ子)")
    func readableValuesStaySilent() throws {
        let key = unique()
        let value = try object(#"{"\#(key)": "here"}"#)
        #expect(value.getString(key) == "here")
        #expect(said(.notAString(key: key)) == nil)
        #expect(said(.noKey(key)) == nil)
        let flag = unique()
        let flags = try object(#"{"\#(flag)": false}"#)
        #expect(flags.getBoolean(flag) == false)
        #expect(said(.notABoolean(key: flag)) == nil)
    }

    // MARK: - 完了条件 4: getInt は丸めない

    @Test("getInt は整数の値だけを読む: 2 と 2.0 は 2、2.5 と Int に収まらない数は 0 と知らせ")
    func getIntDoesNotRound() throws {
        let whole = unique("whole")
        let tenth = unique("tenth")
        let huge = unique("huge")
        let big = unique("big")
        let value = try object(
            """
            {"\(whole)": 2, "two": 2.0, "e": 1e3, "neg": -7, "\(tenth)": 2.5, "\(huge)": 1e30,
             "max": 9223372036854775807, "min": -9223372036854775808, "\(big)": 9223372036854775808,
             "precise": 9007199254740993, "zero": -0}
            """)
        #expect(value.getInt(whole) == 2)
        #expect(value.getInt("two") == 2)
        #expect(value.getInt("e") == 1000)
        #expect(value.getInt("neg") == -7)
        #expect(value.getInt("zero") == 0)
        // 桁を落とさない: Double にすると 9007199254740992 に化ける整数
        #expect(value.getInt("precise") == 9_007_199_254_740_993)
        #expect(value.getInt("max") == Int.max)
        #expect(value.getInt("min") == Int.min)

        #expect(value.getInt(tenth) == 0)
        #expect(said(.notAnInteger(key: tenth))?.contains("is 2.5") == true)
        #expect(value.getInt(huge) == 0)
        #expect(said(.notAnInteger(key: huge)) != nil)
        #expect(value.getInt(big) == 0, "Int.max より 1 大きい整数は収まらない")
        #expect(said(.notAnInteger(key: big)) != nil)
        // 知らせなかったキー
        #expect(said(.notAnInteger(key: whole)) == nil)
    }

    @Test("getInt は数の文字のうち、整数の値のものだけを読む")
    func getIntReadsIntegerSpellings() throws {
        let value = try object(
            #"{"a": "3", "b": " 3\n", "c": "3.0", "d": "1e3", "e": "+5", "f": "2.5", "g": "x", "h": "0x10", "i": "9007199254740993"}"#)
        #expect(value.getInt("a") == 3)
        #expect(value.getInt("b") == 3)
        #expect(value.getInt("c") == 3)
        #expect(value.getInt("d") == 1000)
        #expect(value.getInt("e") == 5)
        #expect(value.getInt("i") == 9_007_199_254_740_993, "整数の綴りは Double を通さない")
        for key in ["f", "g", "h"] {
            #expect(value.getInt(key) == 0, "\(key)")
        }
    }

    @Test("getFloat は整数の値も読み、数の文字の読み方は今までと同じ")
    func getFloatStillReadsNumbers() throws {
        let value = try object(#"{"i": 7, "d": 7.5, "s": "7.25", "big": 9007199254740993}"#)
        #expect(value.getFloat("i") == 7)
        #expect(value.getFloat("d") == 7.5)
        #expect(value.getFloat("s") == 7.25)
        #expect(value.getFloat("big") == Float(9_007_199_254_740_993))
    }

    // MARK: - 完了条件 5: 配列

    @Test("JSONArray は for-in で回れ、要素は JSONObject。count・first・map も使える")
    func arrayIsACollection() throws {
        let features = try array(#"[{"n": 1}, {"n": 2}, {"n": 3}]"#)
        var sum: Float = 0
        for f in features { sum += f.getFloat("n") }
        #expect(sum == 6)
        #expect(features.count == 3)
        #expect(!features.isEmpty)
        #expect(features.first?.getFloat("n") == 1)
        #expect(features.map { $0.getFloat("n") } == [1, 2, 3])
        #expect(features.indices == 0..<3)
        #expect(try array("[]").isEmpty)
        #expect(features.reversed().map { $0.getFloat("n") } == [3, 2, 1])
        #expect(features.dropFirst().count == 2, "RandomAccessCollection の既定の道具が使える")
    }

    @Test("getFloat(i): 数の配列を番号で読む。範囲の外・数でない要素は NaN と、口ごとに 1 度の知らせ")
    func arrayGetFloat() throws {
        let numbers = try array(#"[1, "2.5", "x", true]"#)
        #expect(numbers.getFloat(0) == 1)
        #expect(numbers.getFloat(1) == 2.5, "数の文字は読む")
        #expect(numbers.getFloat(2).isNaN)
        #expect(numbers.getFloat(3).isNaN)
        #expect(numbers.getFloat(4).isNaN)
        #expect(numbers.getFloat(-1).isNaN)
        let wrong = try #require(said(.arrayElement(call: "getFloat", problem: .wrongKind)))
        #expect(wrong.contains("getFloat("))
        #expect(wrong.contains("which is not a number"))
        let range = try #require(said(.arrayElement(call: "getFloat", problem: .outOfRange)))
        #expect(range.contains("no element"))
        // 口ごとに 1 度: 何度外れても、文面は最初のまま (番号ごとに増えない)
        for index in 10..<500 { _ = numbers.getFloat(index) }
        #expect(said(.arrayElement(call: "getFloat", problem: .outOfRange)) == range)
        #expect(said(.arrayElement(call: "getFloat", problem: .wrongKind)) == wrong)
    }

    @Test("getString(i)・getInt(i)・getBoolean(i): 種類の違いは空の値と知らせ、番号で読める")
    func arrayScalarGetters() throws {
        let mixed = try array(#"["a", 2, true, 2.5, null]"#)
        #expect(mixed.getString(0) == "a")
        #expect(mixed.getString(1) == "", "数は文字でない")
        #expect(said(.arrayElement(call: "getString", problem: .wrongKind)) != nil)
        #expect(mixed.getString(9) == "")
        #expect(said(.arrayElement(call: "getString", problem: .outOfRange)) != nil)

        #expect(mixed.getInt(1) == 2)
        #expect(mixed.getInt(3) == 0, "2.5 は丸めない")
        #expect(mixed.getInt(0) == 0)
        #expect(said(.arrayElement(call: "getInt", problem: .wrongKind))?.contains("integer") == true)
        #expect(mixed.getInt(9) == 0)
        #expect(said(.arrayElement(call: "getInt", problem: .outOfRange)) != nil)

        #expect(mixed.getBoolean(2))
        #expect(mixed.getBoolean(1) == false)
        #expect(said(.arrayElement(call: "getBoolean", problem: .wrongKind)) != nil)
        #expect(mixed.getBoolean(9) == false)
        #expect(said(.arrayElement(call: "getBoolean", problem: .outOfRange)) != nil)
    }

    @Test("オブジェクトでない要素は、空のオブジェクトとして渡し、口ごとに 1 度だけ知らせる")
    func nonObjectElementsAreEmptyObjects() throws {
        let numbers = try array("[10, 20, 30]")
        var seen = 0
        for element in numbers {
            #expect(element == JSONObject([:]))
            seen += 1
        }
        #expect(seen == 3)
        let message = try #require(said(.arrayElement(call: "getJSONObject", problem: .wrongKind)))
        #expect(message.contains("which is not an object"))
        #expect(numbers[7] == JSONObject([:]), "範囲の外でも落ちない")
        #expect(said(.arrayElement(call: "getJSONObject", problem: .outOfRange)) != nil)
        // 範囲の外で落ちなくても、数で読めば読める
        #expect(numbers.getFloat(1) == 20)
    }

    @Test("配列の配列は getJSONArray(i) で降りる (GeoJSON の多角形)")
    func nestedArrays() throws {
        let ring = try array("[[1, 2], [3, 4], 5]")
        #expect(ring.getJSONArray(1).getFloat(0) == 3)
        #expect(ring.getJSONArray(0).count == 2)
        #expect(ring.getJSONArray(2).isEmpty)
        #expect(said(.arrayElement(call: "getJSONArray", problem: .wrongKind)) != nil)
        #expect(ring.getJSONArray(8).isEmpty)
        #expect(said(.arrayElement(call: "getJSONArray", problem: .outOfRange)) != nil)
    }

    // MARK: - 完了条件 6: キー

    @Test("keys は辞書の順ではなく文字の順に並べ、hasKey は null の値でも true で、知らせない")
    func keysAreSortedAndHasKeyIsQuiet() throws {
        let value = try object(#"{"b": 1, "a": null, "c": [], "Z": 2, "あ": 3, "10": 4, "9": 5}"#)
        #expect(value.keys == ["10", "9", "Z", "a", "b", "c", "あ"])
        #expect(value.keys == value.keys, "同じ並びを返し続ける")
        #expect(value.hasKey("a"), "null の値でもキーはある")
        #expect(value.hasKey("b"))
        let gone = unique("gone")
        #expect(!value.hasKey(gone))
        #expect(said(.noKey(gone)) == nil, "hasKey は知らせない")
        #expect(JSONObject([:]).keys.isEmpty)
    }

    // MARK: - 完了条件 7: 文字から読む

    @Test("parseJSONObject は届いた文字を読む。壊れた文字は壊れた行を添えて malformed")
    func parseJSONObjectReadsText() throws {
        let sketch = Bare()
        let message = try sketch.parseJSONObject("{\"a\":1}")
        #expect(message.getFloat("a") == 1)
        #expect(message.getInt("a") == 1)

        let broken = #expect(throws: DataFailure.self) { try sketch.parseJSONObject("{\n  \"a\": 1,\n  \"b\": \n") }
        guard case .malformed(let named, let line, _) = broken else {
            Issue.record("malformed で投げていない: \(String(describing: broken))")
            return
        }
        #expect(named == "parseJSONObject(_:)", "文字には名前が無いので口の名前を名乗る")
        #expect(line >= 2)
        #expect(
            broken?.description.contains(#""parseJSONObject(_:)" is broken at line"#) == true,
            "\(String(describing: broken))")

        #expect(throws: DataFailure.self) { try sketch.parseJSONObject("") }
        #expect(throws: DataFailure.self) { try sketch.parseJSONArray("[1, 2") }
    }

    @Test("parseJSONArray は文字を読み、Double に収まらない数は断る (ファイルと同じ読み方)")
    func parseJSONArrayReadsText() throws {
        #expect(try Bare().parseJSONArray("  [1,\n 2]  ").count == 2)
        let overflow = #expect(throws: DataFailure.self) { try Bare().parseJSONArray("[1,\n1e400]") }
        guard case .malformed(_, let line, let reason) = overflow else {
            Issue.record("malformed で投げていない: \(String(describing: overflow))")
            return
        }
        #expect(line == 2)
        #expect(reason.contains("does not fit in a Double"), "\(reason)")
    }

    // MARK: - 完了条件 8: XML

    private static let feed = """
        <rss version="2.0">
          <channel>
            <title>News &amp; Notes</title>
            <item><title>A</title><link>https://x.test/a</link></item>
            <item><title><![CDATA[B <b>]]></title></item>
          </channel>
        </rss>
        """

    @Test("XML: 子へ降りて文字を読む。getChild は最初の子、getContent は要素の直下の文字")
    func xmlContent() throws {
        defer { cleanUp() }
        let rss = try Bare().loadXML(try file("feed.xml", Self.feed))
        let channel = rss.getChild("channel")
        let items = channel.getChildren("item")
        #expect(items.count == 2)
        #expect(items[0].getChild("title").getContent() == "A")
        #expect(channel.getChild("item").getChild("link").getContent() == "https://x.test/a")
        #expect(channel.getChild("title").getContent() == "News & Notes", "実体参照は解いた値")
        #expect(items[1].getChild("title").getContent() == "B <b>", "CDATA の中身も文字")
        // 要素の直下だけ: 子の要素の中の文字は含まない。字下げの空白は書かれたまま残る
        let direct = channel.getContent()
        #expect(!direct.contains("News"))
        #expect(direct.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        #expect(rss.getChild("channel").getChild("item").getChild("title").getContent() == "A")
    }

    @Test("XML: 属性の文字は getString で読む。値が空の属性は知らせず、無い属性は空の文字と 1 度の知らせ")
    func xmlAttributeString() throws {
        defer { cleanUp() }
        let tag = unique("el").replacingOccurrences(of: "-", with: "_")
        let missing = unique("attr")
        let xml = try Bare().loadXML(
            try file("a.xml", #"<\#(tag) name="冬 &amp; 夜" empty="" size="6"/>"#))
        #expect(xml.getString("name") == "冬 & 夜")
        #expect(xml.getString("empty") == "")
        #expect(xml.getString("size") == "6")
        #expect(said(.noAttribute(element: tag, name: "empty")) == nil, "あるので知らせない")
        #expect(xml.getString(missing) == "")
        let message = try #require(said(.noAttribute(element: tag, name: missing)))
        #expect(message.contains("getString("))
        #expect(message.contains("Its attributes are"))
        let before = said(.noAttribute(element: tag, name: missing))
        _ = xml.getString(missing)
        #expect(said(.noAttribute(element: tag, name: missing)) == before)
    }

    @Test("XML: 無い子は空の要素と 1 度の知らせ。繋いだ先も落ちない")
    func xmlMissingChild() throws {
        defer { cleanUp() }
        let tag = unique("root").replacingOccurrences(of: "-", with: "_")
        let name = unique("child")
        let xml = try Bare().loadXML(try file("c.xml", "<\(tag)><a/><b/></\(tag)>"))
        let missing = xml.getChild(name)
        #expect(missing.getContent() == "")
        #expect(missing.getChildren("x").isEmpty)
        let message = try #require(said(.noChild(element: tag, name: name)))
        #expect(message.contains("getChild("))
        #expect(message.contains(#"Its children are named: "a", "b""#), "\(message)")

        // 子が 1 つも無い要素でも、getChild は知らせる (getChildren は黙って空)
        let leaf = try Bare().loadXML(try file("leaf.xml", "<\(tag)/>"))
        let other = unique("leafchild")
        #expect(leaf.getChild(other).getContent() == "")
        #expect(said(.noChild(element: tag, name: other))?.contains("It has no children") == true)
        let quiet = unique("quiet")
        #expect(leaf.getChildren(quiet).isEmpty)
        #expect(said(.noChild(element: tag, name: quiet)) == nil)
    }

    @Test("XML: 文字の中の改行と字下げは書かれたまま。混ざった文字は直下の分を書かれた順に連ねる")
    func xmlContentIsVerbatim() throws {
        defer { cleanUp() }
        let xml = try Bare().loadXML(try file("m.xml", "<p>\n  one <b>bold</b> two\n</p>"))
        #expect(xml.getContent() == "\n  one  two\n")
        #expect(xml.getChild("b").getContent() == "bold")
        let empty = try Bare().loadXML(try file("e.xml", "<p/>"))
        #expect(empty.getContent() == "")
    }
}
