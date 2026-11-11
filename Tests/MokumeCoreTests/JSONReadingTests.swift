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

    /// `getInt` の境界の組 (#3950)。左は JSON の値の綴りそのまま、右は返るべき整数で、`nil` は
    /// 「0 を返して知らせる」。**整数かどうかは、桁が残っている所 (文字・Foundation が `Decimal` で
    /// 渡す長い数) で決める** — `Double` に丸めた後では、`Int.min` の 1 つ外も `Int.min` に、端数のある
    /// 文字も整数に見える。
    private static let integerBoundaries: [(json: String, expected: Int?)] = [
        // 数の値: Int の両端と、その 1 つ外
        ("-9223372036854775808", Int.min),
        ("-9223372036854775809", nil),
        ("9223372036854775807", Int.max),
        ("9223372036854775808", nil),
        ("-18446744073709551615", nil),
        // 数の値: Foundation が Decimal で渡す長い綴り。丸めた後の Double ではなく綴りの値で決める
        ("-9223372036854775808.0", Int.min),
        ("-9223372036854775808.5", nil),
        ("1.00000000000000000000001", nil),
        ("100000000000000000000.0", nil),
        // 数の値: いまの振る舞いを固定する行。`JSONSerialization` が読み解く時点で丸める (17 桁以下の綴りは
        // `Double` で、39 桁以上は Decimal の 38 桁で)。`JSONFile` の「その読み方に従う」の内とするか、数の
        // 綴りを本体が読むかは #3958 で決める。決まったらここを書き換える
        ("1.0000000000000001", 1),
        ("9007199254740993.0", 9_007_199_254_740_992),
        ("1.000000000000000000000000000000000000000000001", 1),
        // 数の値: 従来どおり
        ("2.0", 2), ("1e3", 1000), ("-0", 0), ("-0.0", 0), ("2.5", nil), ("1e30", nil),
        // 数の文字: Int の両端と、その 1 つ外
        (#""-9223372036854775808""#, Int.min),
        (#""-9223372036854775809""#, nil),
        (#""9223372036854775807""#, Int.max),
        (#""9223372036854775808""#, nil),
        // 数の文字: 端数・指数のある綴りも、丸めずに値で決める
        (#""9007199254740993.0""#, 9_007_199_254_740_993),
        (#""1.0000000000000001""#, nil),
        (#""-9223372036854775808.0""#, Int.min),
        (#""-9223372036854775808.5""#, nil),
        (#""92233720368547758.07e2""#, Int.max),
        (#""9.223372036854775808e18""#, nil),
        (#""-9.223372036854775808e18""#, Int.min),
        (#""100e-2""#, 1),
        (#""150e-2""#, nil),
        (#""1E+2""#, 100),
        (#""0.0e999999999999""#, 0),
        (#""1e999999999999""#, nil),
        (#""1e-999999999999""#, nil),
        // 数の文字: 従来の有効な綴り (空白・符号・0・先頭の 0・小数点で終わる)
        (#""1e3""#, 1000), (#""3.0""#, 3), (#"" 3\n""#, 3), (#""\t-7 ""#, -7), (#""-0""#, 0),
        (#""+0.0""#, 0), (#""+5""#, 5), (#""007""#, 7), (#""5.""#, 5),
        // 数の文字でない綴り
        (#""""#, nil), (#"" ""#, nil), (#""1 2""#, nil), (#"".5""#, nil), (#"".""#, nil),
        (#""-""#, nil), (#""1e""#, nil), (#""0x10""#, nil), (#""inf""#, nil), (#""--1""#, nil),
    ]

    @Test("getInt の境界: Int の両端とその 1 つ外・端数・指数・空白・-0 を、キーで引く口と番号で引く口で同じに読む")
    func getIntBoundaries() throws {
        let cases = Self.integerBoundaries
        let keys = cases.map { _ in unique("bound") }
        let members = zip(keys, cases).map { #""\#($0)": \#($1.json)"# }.joined(separator: ", ")
        let byKey = try object("{\(members)}")
        let byIndex = try array("[\(cases.map(\.json).joined(separator: ", "))]")
        for (index, (key, item)) in zip(keys, cases).enumerated() {
            #expect(byKey.getInt(key) == item.expected ?? 0, "getInt(key) \(item.json)")
            #expect(byIndex.getInt(index) == item.expected ?? 0, "getInt(index) \(item.json)")
            // 読めない値は 0 を返して知らせ、読めた値は知らせない
            #expect((said(.notAnInteger(key: key)) != nil) == (item.expected == nil), "知らせ \(item.json)")
        }
    }

    @Test("読めない桁の多い数の知らせは、丸めた値ではなく書かれた綴りを名乗る。2.0 は 2.0 と名乗る")
    func getIntNamesTheSpelling() throws {
        let below = unique("below")
        let tiny = unique("tiny")
        let half = unique("half")
        let whole = unique("whole")
        let value = try object(
            """
            {"\(below)": -9223372036854775809, "\(tiny)": 1.00000000000000000000001,
             "\(half)": -9223372036854775808.5, "\(whole)": 2.0}
            """)
        #expect(value.getInt(below) == 0)
        #expect(
            said(.notAnInteger(key: below))
                == "getInt(\"\(below)\"): the value of \"\(below)\" is -9223372036854775809, which is not an "
                + "integer that fits in an Int. Reading it as 0 (said once per key)")
        #expect(value.getInt(tiny) == 0)
        #expect(said(.notAnInteger(key: tiny))?.contains("is 1.00000000000000000000001, which") == true)
        #expect(value.getInt(half) == 0)
        #expect(said(.notAnInteger(key: half))?.contains("is -9223372036854775808.5, which") == true)
        // 桁の多い数も、数として読む口では丸めた値で読める
        #expect(value.getFloat(tiny) == 1)
        #expect(value.getString(whole) == "")
        #expect(said(.notAString(key: whole))?.contains("is 2.0, which is not a string") == true)
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

    // MARK: - オブジェクトを作って書く (#3643)

    @Test("空から作って書いたオブジェクトを saveJSONObject で書き、loadJSONObject で読み直すと同じ")
    func writtenObjectRoundTrips() throws {
        defer { cleanUp() }
        var o = JSONObject()
        o.setString("name", "Sapporo")
        o.setFloat("temp", -3.5)
        o.setInt("count", 2)
        o.setBoolean("rain", false)
        let path = folder.appendingPathComponent("out/a.json").path
        try Bare().saveJSONObject(o, path)
        let read = try Bare().loadJSONObject(path)
        #expect(read == o)
        #expect(read.getString("name") == "Sapporo")
        #expect(read.getFloat("temp") == -3.5)
        #expect(read.getInt("count") == 2)
        #expect(read.getBoolean("rain") == false)
    }

    @Test("書く順は決まっている: キーは文字の順、UTF-8 (BOM なし)・LF・字下げ 2。同じ値は同じバイト列")
    func writtenBytesAreDeterministic() throws {
        defer { cleanUp() }
        var first = JSONObject()
        first.setInt("b", 1)
        first.setString("a", "é\"\\\n\t\u{01}/")
        var inner = JSONObject()
        inner.setFloat("z", 0.1)
        inner.setFloat("y", 2)
        first.setJSONObject("c", inner)
        first.setJSONObject("d", JSONObject())
        first.setJSONArray("e", try array("[]"))
        first.setJSONArray("f", try array(#"[1, "x", true, null]"#))
        var second = JSONObject()
        second.setJSONArray("f", try array(#"[1, "x", true, null]"#))
        second.setJSONArray("e", try array("[]"))
        second.setJSONObject("d", JSONObject())
        second.setJSONObject("c", inner)
        second.setString("a", "é\"\\\n\t\u{01}/")
        second.setInt("b", 1)
        let one = folder.appendingPathComponent("one.json").path
        let two = folder.appendingPathComponent("two.json").path
        try Bare().saveJSONObject(first, one)
        try Bare().saveJSONObject(second, two)
        let bytes = try Data(contentsOf: URL(fileURLWithPath: one))
        let other = try Data(contentsOf: URL(fileURLWithPath: two))
        #expect(bytes == other)
        let expected = """
            {
              "a": "é\\"\\\\\\n\\t\\u0001/",
              "b": 1,
              "c": {
                "y": 2.0,
                "z": 0.1
              },
              "d": {},
              "e": [],
              "f": [
                1,
                "x",
                true,
                null
              ]
            }

            """
        #expect(String(decoding: bytes, as: UTF8.self) == expected)
        #expect(bytes.first == UInt8(ascii: "{"), "BOM を付けない")
        #expect(!bytes.contains(0x0D), "行の終わりは LF だけ")
        #expect(try Bare().loadJSONObject(one) == first)
    }

    @Test("入れ子は写しを書き換えて setJSONObject で戻す。既にあるキーは種類が変わっても置き換える")
    func nestedAndReplacedValues() {
        var o = JSONObject()
        var main = JSONObject()
        main.setFloat("temp", 1)
        o.setJSONObject("main", main)
        #expect(o.getJSONObject("main").getFloat("temp") == 1)
        // 渡した時点の写し: 後で main を書き換えても o の中は変わらない
        main.setFloat("temp", 9)
        #expect(o.getJSONObject("main").getFloat("temp") == 1)
        o.setString("main", "gone")
        #expect(o.getString("main") == "gone")
        o.setInt("main", 2)
        #expect(o.getInt("main") == 2)
        #expect(o.keys == ["main"])
    }

    @Test("NaN と無限はキーに書かず、キーごとに 1 度だけ知らせる。既にある値も置き換えない")
    func nonFiniteIsNotWritten() {
        let key = unique("nan")
        var o = JSONObject()
        o.setFloat(key, .nan)
        #expect(o.hasKey(key) == false)
        #expect(said(.notFinite(key: key))?.contains("JSON has no spelling for nan") == true)
        let infinite = unique("inf")
        o.setFloat(infinite, 4)
        o.setFloat(infinite, -.infinity)
        #expect(o.getFloat(infinite) == 4)
        #expect(said(.notFinite(key: infinite))?.contains("-inf") == true)
    }

    @Test("読んだ桁の多い数は綴りのまま書き出し、読み直すと同じ値と同じ知らせになる")
    func longNumbersKeepTheirSpelling() throws {
        defer { cleanUp() }
        let read = try object(
            #"{"below": -9223372036854775809, "tiny": 1.00000000000000000000001, "min": -9223372036854775808.0, "two": 2.0}"#)
        let path = folder.appendingPathComponent("long.json").path
        try Bare().saveJSONObject(read, path)
        let text = try String(contentsOfFile: path, encoding: .utf8)
        #expect(text.contains(#""below": -9223372036854775809,"#))
        #expect(text.contains(#""tiny": 1.00000000000000000000001"#))
        #expect(text.contains(#""min": -9223372036854775808,"#), "Int に収まる整数の値は整数の綴り")
        #expect(text.contains(#""two": 2.0"#))
        let again = try Bare().loadJSONObject(path)
        #expect(again == read)
        #expect(again.getInt("below") == 0)
        #expect(again.getInt("min") == Int.min)
    }

    @Test("書けない置き場では unwritable を投げ、前の中身を残す (saveTable と同じ道)")
    func unwritablePlaceThrows() throws {
        defer { cleanUp() }
        let blocker = try file("blocker", "x")
        var o = JSONObject()
        o.setInt("a", 1)
        let failure = #expect(throws: DataFailure.self) {
            try Bare().saveJSONObject(o, blocker + "/inside.json")
        }
        guard case .unwritable(let path, _) = failure else {
            Issue.record("unwritable で投げなかった: \(String(describing: failure))")
            return
        }
        #expect(path == blocker + "/inside.json")
        let existing = try file("keep.json", "{\"old\": true}\n")
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: folder.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder.path) }
        #expect(throws: DataFailure.self) { try Bare().saveJSONObject(o, existing) }
        #expect(try String(contentsOfFile: existing, encoding: .utf8) == "{\"old\": true}\n")
    }

    // MARK: - 配列を作って書く (#3644)

    @Test("空から作った配列に足して書き、saveJSONArray → loadJSONArray で読み直すと同じ")
    func writtenArrayRoundTrips() throws {
        defer { cleanUp() }
        var a = JSONArray()
        a.append(1)
        a.append("two")
        a.append(true)
        #expect(a.count == 3)
        #expect(a.getInt(0) == 1)
        #expect(a.getString(1) == "two")
        #expect(a.getBoolean(2) == true)
        a.append(-3.5 as Float)
        var o = JSONObject()
        o.setInt("n", 7)
        a.append(o)
        let path = folder.appendingPathComponent("out/a.json").path
        try Bare().saveJSONArray(a, path)
        let read = try Bare().loadJSONArray(path)
        #expect(read == a)
        #expect(read.getFloat(3) == -3.5)
        #expect(read.getJSONObject(4).getInt("n") == 7)
        let text = try String(contentsOfFile: path, encoding: .utf8)
        #expect(text == "[\n  1,\n  \"two\",\n  true,\n  -3.5,\n  {\n    \"n\": 7\n  }\n]\n", "要素は並んだ順のまま、字下げ 2・LF")
    }

    @Test("remove は 1 つ除いて後ろを詰め、範囲の外は何もせず 1 度だけ知らせる")
    func removeShiftsAndIgnoresOutside() throws {
        var a = try array(#"[10, 20, 30]"#)
        a.remove(1)
        #expect(a.count == 2)
        #expect(a.getInt(0) == 10)
        #expect(a.getInt(1) == 30)
        let before = a
        a.remove(2)
        a.remove(-1)
        #expect(a == before)
        let message = said(.arrayElement(call: "remove", problem: .outOfRange))
        #expect(message?.hasPrefix("remove(2): the JSON array has 2 elements, so there is no element 2. Nothing was removed") == true)
    }

    @Test("set は範囲の中なら種類が変わっても置き換え、範囲の外には書かず口ごとに 1 度知らせる")
    func setReplacesInsideAndIgnoresOutside() throws {
        var a = try array(#"[1, "x", true]"#)
        let before = a
        a.setFloat(5, 1)
        #expect(a == before, "伸ばさない (Processing は null で埋める)")
        #expect(
            said(.arrayElement(call: "setFloat", problem: .outOfRange))?
                .hasPrefix("setFloat(5): the JSON array has 3 elements, so there is no element 5. Nothing was written") == true)
        a.setInt(3, 1)
        a.setString(-1, "y")
        a.setBoolean(9, false)
        a.setJSONObject(3, JSONObject())
        a.setJSONArray(3, JSONArray())
        #expect(a == before)
        for call in ["setInt", "setString", "setBoolean", "setJSONObject", "setJSONArray"] {
            #expect(said(.arrayElement(call: call, problem: .outOfRange))?.contains("Nothing was written") == true, "\(call)")
        }

        a.setFloat(0, 2.5)
        a.setInt(1, 4)
        a.setString(2, "z")
        #expect(a.getFloat(0) == 2.5)
        #expect(a.getInt(1) == 4)
        #expect(a.getString(2) == "z")
        a.setBoolean(0, true)
        var inner = JSONObject()
        inner.setString("k", "v")
        a.setJSONObject(1, inner)
        a.setJSONArray(2, try array("[9]"))
        #expect(a.getBoolean(0) == true)
        #expect(a.getJSONObject(1).getString("k") == "v")
        #expect(a.getJSONArray(2).getInt(0) == 9)
    }

    @Test("配列の配列を append(JSONArray) で組み、読み直すと getJSONArray(0).getFloat(1) で戻る")
    func nestedArraysRoundTrip() throws {
        defer { cleanUp() }
        var ring = JSONArray()
        for (x, y) in [(142.4, 38.3), (141.0, 43.1)] as [(Float, Float)] {
            var corner = JSONArray()
            corner.append(x)
            corner.append(y)
            ring.append(corner)
        }
        let path = folder.appendingPathComponent("ring.json").path
        try Bare().saveJSONArray(ring, path)
        let read = try Bare().loadJSONArray(path)
        #expect(read.getJSONArray(0).getFloat(1) == 38.3)
        #expect(read.getJSONArray(1).getFloat(0) == 141)
        #expect(read == ring)
        let empty = folder.appendingPathComponent("empty.json").path
        try Bare().saveJSONArray(JSONArray(), empty)
        #expect(try String(contentsOfFile: empty, encoding: .utf8) == "[]\n")
    }

    @Test("NaN と無限は append でも setFloat でも書かず、口ごとに 1 度知らせる")
    func arrayNonFiniteIsNotWritten() {
        var a = JSONArray()
        a.append(.nan)
        a.append(Float.infinity)
        #expect(a.isEmpty)
        #expect(said(.arrayElement(call: "append", problem: .notFinite))?.contains("JSON has no spelling for nan") == true)
        a.append(1 as Float)
        a.setFloat(0, -.infinity)
        #expect(a.getFloat(0) == 1)
        #expect(said(.arrayElement(call: "setFloat", problem: .notFinite))?.hasPrefix("setFloat(0, -inf)") == true)
    }

    @Test("書き方と書けない置き場は saveJSONObject と同じ: 同じ値は同じバイト列、unwritable を投げて前の中身を残す")
    func arrayWritingMatchesObjectWriting() throws {
        defer { cleanUp() }
        var o = JSONObject()
        o.setInt("b", 1)
        o.setInt("a", 2)
        var a = JSONArray()
        a.append(o)
        let path = folder.appendingPathComponent("same.json").path
        try Bare().saveJSONArray(a, path)
        let text = try String(contentsOfFile: path, encoding: .utf8)
        #expect(text == "[\n  {\n    \"a\": 2,\n    \"b\": 1\n  }\n]\n", "入れ子のオブジェクトのキーは文字の順")
        let long = try array("[-9223372036854775809]")
        try Bare().saveJSONArray(long, path)
        #expect(try String(contentsOfFile: path, encoding: .utf8) == "[\n  -9223372036854775809\n]\n")

        let blocker = try file("blocker", "x")
        let failure = #expect(throws: DataFailure.self) {
            try Bare().saveJSONArray(a, blocker + "/inside.json")
        }
        guard case .unwritable(let failedPath, _) = failure else {
            Issue.record("unwritable で投げなかった: \(String(describing: failure))")
            return
        }
        #expect(failedPath == blocker + "/inside.json")
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

    // MARK: - null を確かめる・XML の読み口の残り・parseXML (#3645)

    @Test("isNull: null の値と無いキーは true、他の値は false で、知らせない")
    func jsonObjectIsNull() throws {
        let value = try object(#"{"a": null, "b": 1, "s": "null", "z": 0, "o": {}, "f": false}"#)
        #expect(value.isNull("a"))
        #expect(!value.isNull("b"))
        #expect(!value.isNull("s"), "文字の \"null\" は null ではない")
        #expect(!value.isNull("z"))
        #expect(!value.isNull("o"))
        #expect(!value.isNull("f"))
        let gone = unique("gone")
        #expect(value.isNull(gone), "無いキーは true (2026-10-31 の決定)")
        #expect(said(.noKey(gone)) == nil, "isNull は知らせない")
        // 無いキーと null の値は hasKey で分かれる
        #expect(value.hasKey("a") && !value.hasKey(gone))
        #expect(JSONObject().isNull("a"))
    }

    @Test("isNull(i): null の要素と範囲の外の番号は true、他は false で、知らせない")
    func jsonArrayIsNull() throws {
        let value = try array(#"[null, 1, "null", [], {"a": null}]"#)
        #expect(value.isNull(0))
        #expect(!value.isNull(1))
        #expect(!value.isNull(2), "文字の \"null\" は null ではない")
        #expect(!value.isNull(3))
        #expect(!value.isNull(4))
        #expect(value.getJSONObject(4).isNull("a"))
        #expect(value.isNull(-1), "範囲の外は true")
        #expect(value.isNull(5), "範囲の外は true")
        #expect(value.isNull(Int.max))
        #expect(JSONArray().isNull(0))
        #expect(said(.arrayElement(call: "isNull", problem: .outOfRange)) == nil, "isNull は知らせない")
    }

    @Test("parseXML: 名前・すべての子・整数・文字の数・属性の有無と一覧を読む (完了条件の例)")
    func parseXMLReadsTheExample() throws {
        let sky = try Bare().parseXML(#"<sky><star x="3" n="2">4.5</star><moon/></sky>"#)
        #expect(sky.getName() == "sky")
        #expect(sky.getChildren().map { $0.getName() } == ["star", "moon"])
        let star = sky.getChildren()[0]
        #expect(star.getInt("n") == 2)
        #expect(star.getFloatContent() == 4.5)
        #expect(star.hasAttribute("x"))
        #expect(!star.hasAttribute("y"))
        #expect(said(.noAttribute(element: "star", name: "y")) == nil, "hasAttribute は知らせない")
        #expect(star.listAttributes() == ["n", "x"])
        #expect(sky.getChildren()[1].listAttributes().isEmpty)
    }

    @Test("getChildren() は名前を選ばず書かれた順に並べ、孫は入れず、子が無ければ黙って空")
    func xmlAllChildren() throws {
        let tag = unique("root").replacingOccurrences(of: "-", with: "_")
        let root = try Bare().parseXML("<\(tag)>text<b/><a><deep/></a>more<b n=\"1\"/><s:c/></\(tag)>")
        #expect(root.getChildren().map { $0.getName() } == ["b", "a", "b", "s:c"])
        #expect(root.getChildren()[2].getInt("n") == 1)
        #expect(root.getChildren()[1].getChildren().map { $0.getName() } == ["deep"])
        #expect(root.getChildren()[0].getChildren().isEmpty)
        // getChild が返した空の要素は名前も空で、子も属性も無い
        let missing = root.getChild(unique("none"))
        #expect(missing.getName() == "")
        #expect(missing.getChildren().isEmpty)
        #expect(missing.listAttributes().isEmpty)
    }

    @Test("listAttributes は書かれた順でも辞書の順でもなく文字の順で、何度読んでも同じ")
    func xmlAttributesAreSorted() throws {
        // 辞書の順にたまたま合わないよう、属性を多く並べる
        let names = ["zeta", "alpha", "m", "B", "a10", "a9", "y", "c", "x", "d", "w", "e", "v", "f"]
        let attributes = names.map { "\($0)=\"1\"" }.joined(separator: " ")
        let xml = try Bare().parseXML("<e \(attributes)/>")
        #expect(xml.listAttributes() == names.sorted())
        #expect(xml.listAttributes() == ["B", "a10", "a9", "alpha", "c", "d", "e", "f", "m", "v", "w", "x", "y", "zeta"])
        #expect(try Bare().parseXML("<e \(attributes)/>").listAttributes() == xml.listAttributes())
    }

    @Test("XML の getInt は丸めない: 2 と 2.0 は 2、端数・収まらない数・数でない文字・無い属性は 0 と 1 度の知らせ")
    func xmlAttributeInt() throws {
        let tag = unique("el").replacingOccurrences(of: "-", with: "_")
        let xml = try Bare().parseXML(
            #"<\#(tag) a="2" b="2.0" c=" 1e3&#10;" d="2.5" e="9223372036854775808" f="-9223372036854775808" "#
                + #"g="9007199254740993" h="0x10" i="" j="-0"/>"#)
        #expect(xml.getInt("a") == 2)
        #expect(xml.getInt("b") == 2)
        #expect(xml.getInt("c") == 1000, "前後の空白 (改行も) は落とす")
        #expect(xml.getInt("f") == Int.min)
        #expect(xml.getInt("g") == 9_007_199_254_740_993, "Double を通さず、2⁵³ を越える桁も落とさない")
        #expect(xml.getInt("j") == 0)
        for name in ["a", "b", "c", "f", "g", "j"] {
            #expect(said(.attributeNotAnInteger(element: tag, name: name)) == nil, "読めた \(name) は知らせない")
        }

        #expect(xml.getInt("d") == 0, "端数は丸めずに 0")
        let message = try #require(said(.attributeNotAnInteger(element: tag, name: "d")))
        #expect(message.contains(#"getInt("d")"#), "\(message)")
        #expect(message.contains(#"d="2.5""#), "\(message)")
        _ = xml.getInt("d")
        #expect(said(.attributeNotAnInteger(element: tag, name: "d")) == message, "2 度目は言い直さない")

        #expect(xml.getInt("e") == 0, "Int に収まらない")
        #expect(said(.attributeNotAnInteger(element: tag, name: "e")) != nil)
        #expect(xml.getInt("h") == 0, "16 進は数でない")
        #expect(xml.getInt("i") == 0)
        #expect(said(.attributeNotAnInteger(element: tag, name: "i")) != nil)

        let missing = unique("attr")
        #expect(xml.getInt(missing) == 0)
        let absent = try #require(said(.noAttribute(element: tag, name: missing)))
        #expect(absent.contains("getInt("), "\(absent)")
    }

    @Test("getIntContent・getFloatContent は要素の文字を 10 進で読み、整数は丸めない")
    func xmlContentNumbers() throws {
        func element(_ content: String) throws -> (XML, String) {
            let tag = unique("v").replacingOccurrences(of: "-", with: "_")
            return (try Bare().parseXML("<\(tag)>\(content)</\(tag)>"), tag)
        }
        let (padded, paddedTag) = try element("\n  12\n")
        #expect(padded.getIntContent() == 12, "前後の空白と字下げの改行は落とす")
        #expect(padded.getFloatContent() == 12)
        #expect(said(.contentNotAnInteger(element: paddedTag)) == nil)
        #expect(said(.contentNotANumber(element: paddedTag)) == nil)
        #expect(try element("2.0").0.getIntContent() == 2)
        #expect(try element("1e3").0.getIntContent() == 1000)
        #expect(try element("9007199254740993").0.getIntContent() == 9_007_199_254_740_993)
        #expect(try element(" -3.5 ").0.getFloatContent() == -3.5)
        #expect(try element("<![CDATA[7]]>").0.getIntContent() == 7, "CDATA の中の文字も読む")

        // 完了条件 3: "4.5" の整数は 0 と 1 度の知らせ
        let (half, halfTag) = try element("4.5")
        #expect(half.getIntContent() == 0)
        #expect(half.getFloatContent() == 4.5)
        let message = try #require(said(.contentNotAnInteger(element: halfTag)))
        #expect(message.contains("getIntContent()"), "\(message)")
        #expect(message.contains(#""4.5""#), "\(message)")
        _ = half.getIntContent()
        #expect(said(.contentNotAnInteger(element: halfTag)) == message)

        let (word, wordTag) = try element("nan")
        #expect(word.getFloatContent().isNaN, "文字の nan は数でない")
        #expect(word.getIntContent() == 0)
        let notNumber = try #require(said(.contentNotANumber(element: wordTag)))
        #expect(notNumber.contains("getFloatContent()"), "\(notNumber)")

        let (empty, emptyTag) = try element("")
        #expect(empty.getFloatContent().isNaN)
        #expect(empty.getIntContent() == 0)
        #expect(said(.contentNotANumber(element: emptyTag))?.contains("no text") == true)
        #expect(said(.contentNotAnInteger(element: emptyTag)) != nil)

        // 子の要素の中の文字は含まない (getContent と同じ)
        let (nested, _) = try element("<n>5</n>")
        #expect(nested.getChild("n").getIntContent() == 5)
        #expect(nested.getIntContent() == 0)
    }

    @Test("parseXML は壊れた文字を壊れた行と口の名前を添えて malformed で投げる (parseJSONObject と同じ)")
    func parseXMLThrowsMalformed() throws {
        let sketch = Bare()
        let broken = #expect(throws: DataFailure.self) { try sketch.parseXML("<sky>\n<star>\n</sky>\n") }
        guard case .malformed(let named, let line, _) = broken else {
            Issue.record("malformed で投げていない: \(String(describing: broken))")
            return
        }
        #expect(named == "parseXML(_:)", "文字には名前が無いので口の名前を名乗る")
        #expect(line == 3, "\(String(describing: broken))")
        #expect(
            broken?.description.contains(#""parseXML(_:)" is broken at line"#) == true,
            "\(String(describing: broken))")

        for text in ["", "   ", "<a>", "<a/><b/>", "text", "<a></b>"] {
            let failure = #expect(throws: DataFailure.self, "\(text)") { try sketch.parseXML(text) }
            guard case .malformed(let path, _, _) = failure else {
                Issue.record("malformed で投げていない (\(text)): \(String(describing: failure))")
                continue
            }
            #expect(path == "parseXML(_:)")
        }
        // 読み方は loadXML と同じ: 宣言の encoding は読まず、外の実体は読まない
        let declared = try sketch.parseXML(#"<?xml version="1.0" encoding="Shift_JIS"?><t>冬</t>"#)
        #expect(declared.getContent() == "冬")
    }
}
