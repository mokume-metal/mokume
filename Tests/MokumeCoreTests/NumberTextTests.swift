// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation
import Synchronization
import Testing

@testable import MokumeCore

/// 値を数として取り出す口が、文字をどう数にするか (#2330)。口は 4 つ — JSON の値
/// (``JSONObject/getFloat(_:)``)・XML の属性 (``XML/getFloat(_:)``)・表のセルを名前で
/// (``TableRow/getFloat(_:)-(String)``)・番号で (``TableRow/getFloat(_:)-(Int)``)。
///
/// **数とするのは 10 進の綴りだけで、前後の空白は改行も落とす。** 口ごとに写しを持たないので、
/// 同じ綴りの表を 4 つの口に回す。走っているスケッチも GPU も要らない。
@Suite("文字を数として読む")
struct NumberTextTests {
    final class Bare: Sketch {
        init() {}
        func draw() {}
    }

    enum Door: String, CaseIterable, Sendable {
        case json, xml, tableByName, tableByNumber
    }

    /// 番号で引く表の列。知らせの控えは列の番号ごとなので、呼ぶたびに他の検査が使わない
    /// 番号にする (数えるのは 1 つずつ増やす番号で、表の幅はその番号 + 1)。
    private static let nextColumn = Mutex(64)

    /// 文字を 1 つ置き、その口で数として読む。名前は呼ぶたびに新しくし、知らせの控えを他の
    /// 検査と分ける。読んだ値と、その口が知らせた文面 (知らせなければ `nil`) を返す。
    private static func read(_ text: String, through door: Door) -> (value: Float, said: String?) {
        let name = "n\(UUID().uuidString.prefix(8))"
        switch door {
        case .json:
            let value = JSONObject([name: .string(text)]).getFloat(name)
            return (value, DocumentValues.warnings.message(for: .notANumber(key: name)))
        case .xml:
            let element = XMLFile.Element(name: "e\(name)", attributes: [name: text], children: [])
            let value = XML(element).getFloat(name)
            return (value, DocumentValues.warnings.message(for: .attributeNotANumber(element: "e\(name)", name: name)))
        case .tableByName:
            let value = Table(TableFile.Parsed(titles: [name], rows: [[text]])).rows[0].getFloat(name)
            return (value, TableValues.warnings.message(for: .notANumber(column: "\"\(name)\"")))
        case .tableByNumber:
            let column = nextColumn.withLock { next in
                defer { next += 1 }
                return next
            }
            let row = Array(repeating: "0", count: column) + [text]
            let value = Table(TableFile.Parsed(titles: nil, rows: [row])).rows[0].getFloat(column)
            return (value, TableValues.warnings.message(for: .notANumber(column: "\(column)")))
        }
    }

    @Test(
        "10 進の綴りは数として読み、知らせない。前後の空白は改行も落とす",
        arguments: Door.allCases,
        [
            ("18.5", Float(18.5)), (" -2 ", -2), ("+5", 5), (".5", 0.5), ("5.", 5), ("1e3", 1000),
            ("1E-3", 0.001), ("-0", 0), ("007", 7),
            // 10 進だが Float に収まらない数は無限大 (数の値の `1e300` と同じ — `largeNumbers`)
            ("1e39", .infinity), ("-1e39", -.infinity),
            // 前後の空白は改行も落とす (Processing の `getFloat` と同じ)
            ("3\n", 3), ("\r\n3", 3), ("\t2\t", 2), ("\n 4 \r", 4), ("\u{A0}6\u{2028}", 6),
        ])
    func decimalsReadAsNumbers(_ door: Door, _ sample: (text: String, value: Float)) {
        let read = Self.read(sample.text, through: door)
        #expect(read.value == sample.value, "\(door) \(sample.text.debugDescription)")
        #expect(read.said == nil, "\(door) \(sample.text.debugDescription): \(read.said ?? "")")
    }

    @Test(
        "10 進でない綴りは数でない文字で、NaN を返して知らせる",
        arguments: Door.allCases,
        [
            // Swift の `Float(String)` が受ける綴り。10 進でないので数としない
            "nan", "NaN", "-nan", "snan", "inf", "-inf", "Infinity", "-Infinity", "0x10", "0x1p3",
            // 10 進の形が崩れている
            "1_0", "e5", "1e", "1e+", ".", "+", "-", "--1", "+-1", "1.2.3", "1 2", "1,5", "1.5f",
            // 全角の数字・空・空白だけ・数でない文字
            "１", "", " \n ", "N/A",
            // 数字の後ろの NUL。`Float(String)` は NUL で読むのを止めて 3 を返す
            "3\u{0}abc",
        ])
    func otherSpellingsAreNotNumbers(_ door: Door, _ text: String) {
        let read = Self.read(text, through: door)
        #expect(read.value.isNaN, "\(door) \(text.debugDescription) -> \(read.value)")
        #expect(read.said?.contains("not a number") == true, "\(door) \(text.debugDescription): 知らせが無い")
    }

    // MARK: - ファイルから

    /// 検査ごとに別の置き場。終わったら消す。
    private let folder = FileManager.default.temporaryDirectory
        .appendingPathComponent("mokume-number-text-\(UUID().uuidString)")

    private func file(_ name: String, _ text: String) throws -> String {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent(name)
        try Data(text.utf8).write(to: url)
        return url.path
    }

    @Test("ファイルから読んだ値の前後の改行も落とす: 表のセル・JSON の文字・XML の文字参照")
    func newlinesAroundValuesFromFiles() throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        let sketch = Bare()
        let table = try sketch.loadTable(try file("t.csv", "a,b\n\"3\n\",\"\r\n3\"\n"), header: true)
        #expect(table.rows[0].getFloat("a") == 3)
        #expect(table.rows[0].getFloat("b") == 3)
        #expect(table.rows[0].getFloat(0) == 3)
        let json = try sketch.loadJSONObject(try file("v.json", #"{"t": "3\n"}"#))
        #expect(json.getFloat("t") == 3)
        // 属性の中の改行そのものは XML の決まりで空白になる。文字参照 `&#10;` は改行のまま届く
        let xml = try sketch.loadXML(try file("v.xml", #"<r x="&#10;5" y="5&#13;&#10;"/>"#))
        #expect(xml.getFloat("x") == 5)
        #expect(xml.getFloat("y") == 5)
    }

    /// 判断 3 の代償。`setFloat` は数を `String(value)` で書くので、非有限の値は `"nan"`・`"inf"`
    /// になり、読み直すと 10 進でない文字として NaN と知らせになる (無限は値が変わる)。
    @Test("setFloat で書いた非有限の値は、読み直すと数でない文字になる")
    func nonFiniteWrittenBySetFloatReadsAsNaN() throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        let column = "c\(UUID().uuidString.prefix(8))"
        var table = try Bare().loadTable(try file("t.csv", "\(column)\n1\n2\n"), header: true)
        table.setFloat(0, column, .infinity)
        table.setFloat(1, column, 12.5)
        #expect(table.rows[0].getString(column) == "inf")
        #expect(table.rows[0].getFloat(column).isNaN)
        #expect(table.rows[1].getFloat(column) == 12.5)
        #expect(TableValues.warnings.message(for: .notANumber(column: "\"\(column)\""))?.contains("\"inf\"") == true)
    }
}
