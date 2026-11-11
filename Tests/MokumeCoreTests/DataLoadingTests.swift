// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation
import MokumeTestSupport
import Testing

@testable import MokumeCore

/// 文字列と表を読み書きする口 (#1964)。走っているスケッチも GPU も要らない —
/// 描き場所に触れない口なので、`init` の外で作った素のスケッチから呼べる。
@Suite("文字列と表の読み書き")
struct DataLoadingTests {
    final class Bare: Sketch {
        init() {}
        func draw() {}
    }

    /// 検査ごとに別の置き場。終わったら消す。
    private let folder = TestScratch.path("mokume-data")

    private func file(_ name: String, _ text: String) throws -> String {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent(name)
        try Data(text.utf8).write(to: url)
        return url.path
    }

    private func cleanUp() { try? FileManager.default.removeItem(at: folder) }

    private static let temperatures = "date,high,low\n2025-01-01,8.5,1.5\n2025-01-02,10,2\n"

    // MARK: - 文字列

    @Test("loadStrings は行ごとの文字列を返す。最後の改行は行を作らず、BOM と CRLF は残らない")
    func loadStringsSplitsLines() throws {
        defer { cleanUp() }
        let path = try file("poem.txt", "\u{FEFF}first\r\n\r\nthird\r\n")
        #expect(try Bare().loadStrings(path) == ["first", "", "third"])
    }

    @Test("requestStrings は loadStrings と同じ行を返す")
    func requestStringsMatchesLoad() async throws {
        defer { cleanUp() }
        let path = try file("poem.txt", "a\nb\n")
        let sketch = Bare()
        #expect(try await sketch.requestStrings(path) == sketch.loadStrings(path))
    }

    @Test("無い名前は、loadImage と同じ並びの探した場所を添えて投げる")
    func missingFileNamesWhereItLooked() async {
        let name = "no-such-data-\(UUID().uuidString).csv"
        let expected = DataFailure.notFound(path: name, searched: ImageFile.candidates(for: name).map(\.path))
        #expect(throws: expected) { try Bare().loadStrings(name) }
        #expect(throws: expected) { try Bare().loadTable(name, header: true) }
        await #expect(throws: expected) { try await Bare().requestStrings(name) }
        await #expect(throws: expected) { try await Bare().requestTable(name) }
        #expect(expected.description.contains("Looked in:"))
    }

    @Test("UTF-8 の文字として読めないファイルは unreadable で投げる")
    func nonUTF8FileIsUnreadable() throws {
        defer { cleanUp() }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent("latin1.txt")
        try Data([0x63, 0x61, 0x66, 0xE9, 0xFF, 0x0A]).write(to: url)
        #expect(throws: DataFailure.unreadable(path: url.path)) { try Bare().loadStrings(url.path) }
        #expect(throws: DataFailure.unreadable(path: url.path)) { try Bare().loadTable(url.path) }
    }

    // MARK: - 表を読む

    @Test("見出しありで読むと、列の名前で値を引ける")
    func loadTableWithHeaderReadsByName() throws {
        defer { cleanUp() }
        let table = try Bare().loadTable(try file("t.csv", Self.temperatures), header: true)
        #expect(table.columnTitles == ["date", "high", "low"])
        #expect(table.rowCount == 2)
        #expect(table.columnCount == 3)
        #expect(table.rows[0].getString("date") == "2025-01-01")
        #expect(table.rows[0].getFloat("high") == 8.5)
        #expect(table.rows[1].getFloat("low") == 2)
    }

    @Test("見出しなしで読むと、見出しの行も値の行で、列は番号で引く")
    func loadTableWithoutHeaderReadsByNumber() throws {
        defer { cleanUp() }
        let table = try Bare().loadTable(try file("t.csv", Self.temperatures))
        #expect(table.columnTitles.isEmpty)
        #expect(table.rowCount == 3)
        #expect(table.columnCount == 3)
        #expect(table.rows[0].getString(1) == "high")
        #expect(table.rows[2].getFloat(1) == 10)
    }

    @Test("表計算の道具が付ける BOM と CRLF があっても、最初の見出しを名前で引ける")
    func byteOrderMarkDoesNotHideFirstTitle() throws {
        defer { cleanUp() }
        let path = try file("excel.csv", "\u{FEFF}date,high\r\n2025-01-01,8.5\r\n")
        let table = try Bare().loadTable(path, header: true)
        #expect(table.columnTitles == ["date", "high"])
        #expect(table.rows[0].getString("date") == "2025-01-01")
    }

    @Test("requestTable は loadTable と同じ表を返す")
    func requestTableMatchesLoad() async throws {
        defer { cleanUp() }
        let path = try file("t.csv", Self.temperatures)
        let sketch = Bare()
        #expect(try await sketch.requestTable(path, header: true) == sketch.loadTable(path, header: true))
    }

    @Test("壊れた CSV は、ファイルの名前と壊れた行を添えて投げる")
    func malformedTableNamesFileAndLine() async throws {
        defer { cleanUp() }
        let path = try file("broken.csv", "date,high,low\n2025-01-01,8.5\n")
        let failure = #expect(throws: DataFailure.self) { try Bare().loadTable(path, header: true) }
        guard case .malformed(let named, let line, _) = failure else {
            Issue.record("malformed で投げていない: \(String(describing: failure))")
            return
        }
        #expect(named == path)
        #expect(line == 2)
        #expect(failure?.description.contains("line 2") == true)
        await #expect(throws: failure!) { try await Bare().requestTable(path, header: true) }
    }

    // MARK: - 値を取り出す

    @Test("数でないセルは NaN を返し、列ごとに 1 度だけ理由を知らせる")
    func notANumberReadsAsNaNAndWarnsOnce() throws {
        defer { cleanUp() }
        let column = "rain-\(UUID().uuidString)"
        let table = try Bare().loadTable(try file("t.csv", "day,\(column)\n1, 2.5 \n2,N/A\n3,\n"), header: true)
        #expect(table.rows[0].getFloat(column) == 2.5)  // 前後の空白は落とす
        #expect(table.rows[1].getFloat(column).isNaN)
        #expect(table.rows[2].getFloat(column).isNaN)
        let message = TableValues.warnings.message(for: .notANumber(column: "\"\(column)\""))
        #expect(message?.contains("row 1") == true)
        #expect(message?.contains("\"N/A\"") == true)
    }

    @Test("無い列の名前は NaN と空の文字を返し、表にある列を添えて知らせる")
    func missingColumnNameWarnsWithColumns() throws {
        defer { cleanUp() }
        let table = try Bare().loadTable(try file("t.csv", Self.temperatures), header: true)
        let typo = "hihg-\(UUID().uuidString)"
        #expect(table.rows[0].getFloat(typo).isNaN)
        #expect(table.rows[0].getString(typo) == "")
        let message = TableValues.warnings.message(for: .noColumn(typo))
        #expect(message?.contains("\"date\", \"high\", \"low\"") == true)
    }

    @Test("見出しの無い表を名前で引くと、番号で引くよう知らせる。表の外の列番号も落ちない")
    func namesWithoutHeaderAndOutOfRangeNumbers() throws {
        defer { cleanUp() }
        let table = try Bare().loadTable(try file("t.csv", "1,2\n"))
        #expect(table.rows[0].getFloat("high").isNaN)
        #expect(TableValues.warnings.hasWarned(.noHeader))
        #expect(table.rows[0].getFloat(5).isNaN)
        #expect(table.rows[0].getString(-1) == "")
        #expect(TableValues.warnings.hasWarned(.columnOutOfRange))
    }

    // MARK: - 表の行と列を書き換える (#3642)

    /// 3 行 × 2 列の表 (a: 1, 2, 3 / b: 10, 20, 30)。
    private static func threeRows() -> Table {
        var t = Table(columns: ["a", "b"])
        t.addRow([1, 10])
        t.addRow([2, 20])
        t.addRow([3, 30])
        return t
    }

    @Test("removeRow は行を除いて順を保ち、removeColumn は列と見出しを除き、clearRows は見出しを残す")
    func removeRowsAndColumns() {
        var t = Self.threeRows()
        t.removeRow(1)
        #expect(t.rowCount == 2)
        #expect(t.rows.map { $0.getString("a") } == ["1.0", "3.0"])
        #expect(t.rows.map { $0.getString("b") } == ["10.0", "30.0"])
        t.removeColumn("a")
        #expect(t.columnTitles == ["b"])
        #expect(t.columnCount == 1)
        #expect(t.getFloat(1, "b") == 30)
        t.clearRows()
        #expect(t.rowCount == 0)
        #expect(t.columnTitles == ["b"])
        #expect(t.columnCount == 1)

        // 番号の形と、見出しの無い表
        var u = Self.threeRows()
        u.removeColumn(0)
        #expect(u.columnTitles == ["b"])
        #expect(u.rows.map { $0.getFloat(0) } == [10, 20, 30])
        u.removeRow(2)
        u.removeRow(0)
        #expect(u.rows.map { $0.getFloat(0) } == [20])
    }

    @Test("見出しの無い表の列を番号で除くと、どの行からも同じ列が除かれる")
    func removeColumnWithoutHeader() throws {
        defer { cleanUp() }
        var t = try Bare().loadTable(try file("t.csv", "1,2,3\n4,5,6\n"))
        t.removeColumn(1)
        #expect(t.columnCount == 2)
        #expect(t.rows.map { [$0.getString(0), $0.getString(1)] } == [["1", "3"], ["4", "6"]])
        #expect(t.columnTitles.isEmpty)
    }

    @Test("無い列・表の外の行には何もせず、口ごとに 1 度だけ知らせる (投げない)")
    func editsOutsideTheTableDoNothing() {
        let before = Self.threeRows()
        var t = before
        t.removeRow(3)
        t.removeRow(-1)
        #expect(TableValues.warnings.message(for: .rowOutOfRange(call: "removeRow"))?.contains("there is no row 3") == true)
        #expect(TableValues.warnings.message(for: .rowOutOfRange(call: "removeRow"))?.hasSuffix("Nothing was removed") == true)
        let typo = "c-\(UUID().uuidString)"
        t.removeColumn(typo)
        #expect(TableValues.warnings.message(for: .noColumn(typo))?.hasPrefix("removeColumn(") == true)
        t.removeColumn(2)
        t.setInt(0, "q-\(UUID().uuidString)", 1)
        t.setInt(5, "a", 1)
        #expect(TableValues.warnings.message(for: .rowOutOfRange(call: "setInt"))?.contains("there is no row 5") == true)
        t.setInt(0, 9, 1)
        t.trim("t-\(UUID().uuidString)")
        t.trim(7)
        t.removeTokens("1", "r-\(UUID().uuidString)")
        t.removeTokens("1", -2)
        #expect(t == before)
    }

    @Test("setInt は整数の綴りで書き (setFloat は 3.0)、getInt で読み直すと同じ整数")
    func setIntWritesIntegerSpelling() {
        var t = Self.threeRows()
        t.setInt(0, "a", 3)
        #expect(t.getString(0, "a") == "3")
        t.setFloat(1, "a", 3)
        #expect(t.getString(1, "a") == "3.0")
        t.setInt(2, 1, -9_223_372_036_854_775_808)
        #expect(t.getString(2, 1) == "-9223372036854775808")
        #expect(t.getInt(2, 1) == Int.min)
        #expect(t.getInt(0, "a") == 3)
    }

    @Test("trim は前後の空白 (タブ・改行を含む) を落とし、列を名指すとその列だけ。見出しは触らない")
    func trimCells() throws {
        defer { cleanUp() }
        let csv = "\" name \",value\n\"  12 \t\",\" x \"\n\"\n7\r\n\",\"\ty\"\n"
        var all = try Bare().loadTable(try file("t.csv", csv), header: true)
        let original = all
        all.trim()
        #expect(all.rows.map { $0.getString(" name ") } == ["12", "7"])
        #expect(all.rows.map { $0.getString("value") } == ["x", "y"])
        #expect(all.columnTitles == [" name ", "value"])

        var named = original
        named.trim("value")
        #expect(named.rows.map { $0.getString("value") } == ["x", "y"])
        #expect(named.rows.map { $0.getString(" name ") } == original.rows.map { $0.getString(" name ") })
        var numbered = original
        numbered.trim(0)
        #expect(numbered.rows.map { $0.getString(0) } == ["12", "7"])
        #expect(numbered.rows.map { $0.getString(1) } == [" x ", "\ty"])
    }

    @Test("removeTokens はどれかの文字をセルから除き、列を名指すとその列だけ。見出しは触らない")
    func removeTokensFromCells() throws {
        defer { cleanUp() }
        let csv = "price,$ note\n\"$1,200\",\"a, b$\"\n\" $ 35\",x\n"
        var all = try Bare().loadTable(try file("t.csv", csv), header: true)
        let original = all
        all.removeTokens(",$ ")
        #expect(all.rows.map { $0.getString("price") } == ["1200", "35"])
        #expect(all.rows.map { $0.getString("$ note") } == ["ab", "x"])
        #expect(all.columnTitles == ["price", "$ note"])
        #expect(all.getInt(0, "price") == 1200)

        var named = original
        named.removeTokens(",$ ", "price")
        #expect(named.rows.map { $0.getString("price") } == ["1200", "35"])
        #expect(named.rows.map { $0.getString("$ note") } == ["a, b$", "x"])
        var numbered = original
        numbered.removeTokens("$", 1)
        #expect(numbered.rows.map { $0.getString(1) } == ["a, b", "x"])
        #expect(numbered.rows.map { $0.getString(0) } == ["$1,200", " $ 35"])
    }

    @Test("書き換えた表を saveTable で書いて読み直すと、書き換えた表に戻る")
    func editedTableRoundTrips() throws {
        defer { cleanUp() }
        var t = Self.threeRows()
        t.addColumn("note")
        t.setString(0, "note", "  keep \t")
        t.setString(2, "note", "$5,000")
        t.removeRow(1)
        t.removeColumn("b")
        t.setInt(1, "a", 42)
        t.trim("note")
        t.removeTokens("$,", 1)
        let path = folder.appendingPathComponent("edited.csv").path
        try Bare().saveTable(t, path)
        let read = try Bare().loadTable(path, header: true)
        #expect(read == t)
        #expect(read.columnTitles == ["a", "note"])
        #expect(read.rows.map { [$0.getString("a"), $0.getString("note")] } == [["1.0", "keep"], ["42", "5000"]])
    }

    // MARK: - 表から番号で読む (#3641)

    @Test("表から行の番号と列で 1 つのセルを読む: 名前と番号の 2 つの形が、行から読んだ値と同じ")
    func tableReadsOneCell() {
        var t = Table(columns: ["x", "y"])
        t.addRow([10, 20])
        #expect(t.getFloat(0, "y") == 20)
        #expect(t.getString(0, 0) == "10.0")
        #expect(t.getInt(0, "x") == 10)
        #expect(t.getFloat(0, 1) == 20)
        #expect(t.getString(0, "y") == "20.0")
        #expect(t.getInt(0, 1) == 20)
        // 2 行目を足しても、番号で引いた行のセルを読む (先頭の行に固定されていない)
        t.addRow([-3, 7])
        #expect(t.getInt(1, "x") == -3)
        #expect(t.getFloat(1, "y") == 7)
        #expect(t.getString(1, 1) == "7.0")
        for row in 0..<t.rowCount {
            for column in ["x", "y"] {
                #expect(t.getString(row, column) == t.rows[row].getString(column))
                #expect(t.getInt(row, column) == t.rows[row].getInt(column))
            }
        }
    }

    @Test("表の外の行は、行の口と同じ空の値 (空の文字・NaN・0) を返し、口ごとに 1 度だけ行を名乗って知らせる")
    func tableReadOutsideRows() {
        var t = Table(columns: ["x", "y"])
        t.addRow([10, 20])
        #expect(t.getFloat(5, "x").isNaN)
        let floatMessage = TableValues.warnings.message(for: .rowOutOfRange(call: "getFloat"))
        #expect(floatMessage?.contains("getFloat(): there is no row 5") == true)
        #expect(floatMessage?.contains("numbered 0") == true)
        #expect(floatMessage?.contains("Reading it as NaN") == true)
        // 1 度だけ: 別の行でも文面は変わらない
        #expect(t.getFloat(-1, 0).isNaN)
        #expect(TableValues.warnings.message(for: .rowOutOfRange(call: "getFloat")) == floatMessage)
        #expect(t.getString(1, "x") == "")
        #expect(TableValues.warnings.message(for: .rowOutOfRange(call: "getString"))?.contains("no row 1") == true)
        // 知らせは口ごとの空の値を名乗る (空の文字・NaN・0)
        #expect(TableValues.warnings.message(for: .rowOutOfRange(call: "getString"))?.hasSuffix("Reading it as an empty string") == true)
        #expect(t.getInt(Int.max, 1) == 0)
        #expect(TableValues.warnings.message(for: .rowOutOfRange(call: "getInt"))?.contains("Reading it as 0") == true)
        // 書く口の知らせとは別に数える
        #expect(TableValues.warnings.message(for: .rowOutOfRange(call: "getInt")) != TableValues.warnings.message(for: .rowOutOfRange(call: "setFloat")))
    }

    @Test("無い列は、表の口でも行の口と同じ空の値と、表にある列を添えた知らせ")
    func tableReadMissingColumns() {
        var t = Table(columns: ["x", "y"])
        t.addRow([10, 20])
        let typo = "z-\(UUID().uuidString)"
        #expect(t.getFloat(0, typo).isNaN)
        #expect(t.getInt(0, typo) == 0)
        #expect(t.getString(0, typo) == "")
        #expect(TableValues.warnings.message(for: .noColumn(typo))?.contains("\"x\", \"y\"") == true)
        #expect(t.getInt(0, 2) == 0)
        #expect(t.getFloat(0, -1).isNaN)
        #expect(t.getString(0, 9) == "")
        #expect(TableValues.warnings.hasWarned(.columnOutOfRange))
        // 無い列と無い行が重なれば、列の知らせだけで、セルの知らせは出ない
        #expect(t.getInt(7, typo) == 0)
        #expect(TableValues.warnings.message(for: .notAnInteger(column: "\"\(typo)\"")) == nil)
    }

    @Test("getInt は丸めない: 整数の値の綴りだけを読み、他は 0 と列ごとに 1 度の知らせ (表の口と行の口で同じ)")
    func getIntDoesNotRound() throws {
        defer { cleanUp() }
        let column = "count-\(UUID().uuidString)"
        let cells: [(text: String, expected: Int?)] = [
            ("2", 2), ("2.0", 2), ("1e3", 1000), (" 7 ", 7), ("-0", 0), ("+5", 5),
            ("9223372036854775807", Int.max), ("-9223372036854775808", Int.min),
            ("9007199254740993", 9_007_199_254_740_993),
            ("2.5", nil), ("N/A", nil), ("", nil), ("0x10", nil), ("inf", nil),
            ("9223372036854775808", nil), ("-9223372036854775809", nil), ("1e19", nil),
        ]
        let csv = "day,\(column)\n" + cells.enumerated().map { "\($0.offset),\($0.element.text)" }.joined(separator: "\n")
        let table = try Bare().loadTable(try file("counts.csv", csv), header: true)
        #expect(table.rowCount == cells.count)
        for (row, cell) in cells.enumerated() {
            #expect(table.getInt(row, column) == cell.expected ?? 0, "\(cell.text)")
            #expect(table.getInt(row, 1) == cell.expected ?? 0, "\(cell.text)")
            #expect(table.rows[row].getInt(column) == cell.expected ?? 0, "\(cell.text)")
            #expect(table.rows[row].getInt(1) == cell.expected ?? 0, "\(cell.text)")
        }
        // 列ごとに 1 度: 最初に読めなかった行 ("2.5" の行) を名乗る
        let message = TableValues.warnings.message(for: .notAnInteger(column: "\"\(column)\""))
        #expect(message?.contains("row 9") == true)
        #expect(message?.contains("\"2.5\"") == true)
        #expect(message?.contains("Reading it as 0") == true)
        // 列の番号で引いた口は、番号を名乗る別の鍵で数える
        #expect(TableValues.warnings.hasWarned(.notAnInteger(column: "1")))
    }

    @Test("getFloat の表の口は、行の口と同じ綴りで数を読み、数でないセルは NaN と列ごとの知らせ")
    func tableGetFloatMatchesRow() throws {
        defer { cleanUp() }
        let column = "rain-\(UUID().uuidString)"
        let table = try Bare().loadTable(try file("t.csv", "day,\(column)\n1, 2.5 \n2,N/A\n"), header: true)
        #expect(table.getFloat(0, column) == 2.5)
        #expect(table.getFloat(1, column).isNaN)
        let message = TableValues.warnings.message(for: .notANumber(column: "\"\(column)\""))
        #expect(message?.contains("row 1") == true)
        #expect(message?.contains("\"N/A\"") == true)
    }

    // MARK: - 書く

    @Test("作例 1: 平均の列を足して書き出し、読み直すと同じ表に戻る")
    func addColumnSaveAndReadBack() throws {
        defer { cleanUp() }
        let sketch = Bare()
        var table = try sketch.loadTable(try file("t.csv", Self.temperatures), header: true)
        table.addColumn("mean")
        for (i, row) in table.rows.enumerated() {
            table.setFloat(i, "mean", (row.getFloat("high") + row.getFloat("low")) / 2)
        }
        let out = folder.appendingPathComponent("out/with-mean.csv").path
        try sketch.saveTable(table, out)

        #expect(
            try String(contentsOfFile: out, encoding: .utf8)
                == "date,high,low,mean\n2025-01-01,8.5,1.5,5.0\n2025-01-02,10,2,6.0\n")
        let reread = try sketch.loadTable(out, header: true)
        #expect(reread == table)
        #expect(reread.rows[1].getFloat("mean") == 6)
    }

    @Test("引用符と改行を含むセルも、書いて読み直すと同じ値に戻る")
    func quotedCellsRoundTrip() throws {
        defer { cleanUp() }
        let sketch = Bare()
        var table = try sketch.loadTable(try file("t.csv", "name,note\nA,plain\n"), header: true)
        table.setString(0, "note", "says \"hi\", then\nleaves")
        table.setString(0, 0, "Smith, J")
        let out = folder.appendingPathComponent("round.csv").path
        try sketch.saveTable(table, out)
        let reread = try sketch.loadTable(out, header: true)
        #expect(reread == table)
        #expect(reread.rows[0].getString("note") == "says \"hi\", then\nleaves")
        #expect(reread.rows[0].getString("name") == "Smith, J")
    }

    /// 書いた文字の頭に来るセル (見出しがあれば 1 列目の見出し、無ければ 1 行目 1 列目) の
    /// 頭の U+FEFF は、読む側が BOM として落とす (#1964 の採択)。書く側が囲んで残す (#2340)。
    @Test(
        "頭が U+FEFF のセルも、書いて読み直すと同じ表に戻る",
        arguments: [
            (false, 1, "\u{FEFF}"), (false, 1, "\u{FEFF}z"), (false, 2, "\u{FEFF}"), (false, 2, "\u{FEFF}z"),
            (true, 1, "\u{FEFF}"), (true, 1, "\u{FEFF}z"), (true, 2, "\u{FEFF}"), (true, 2, "\u{FEFF}z"),
            (true, 2, "\u{FEFF}date"),
        ])
    func leadingByteOrderMarkRoundTrips(header: Bool, width: Int, first: String) throws {
        defer { cleanUp() }
        let sketch = Bare()
        let titles = header ? Array([first, "b"].prefix(width)) : nil
        let firstRow = Array([header ? "1" : first, "2"].prefix(width))
        let table = Table(TableFile.Parsed(titles: titles, rows: [firstRow, Array(["3", "4"].prefix(width))]))
        let out = folder.appendingPathComponent("bom-\(header)-\(width).csv").path
        try sketch.saveTable(table, out)
        let reread = try sketch.loadTable(out, header: header)
        #expect(reread == table)
        #expect(reread.rowCount == 2)
        // 消えたことは `==` でも分かる。残ったのが元のスカラーの並びそのものであることも見る
        let firstCell = header ? reread.columnTitles.first : reread.rows.first?.getString(0)
        #expect(firstCell.map { Array($0.unicodeScalars) } == Array(first.unicodeScalars))
    }

    @Test("見出しの無い表に名前つきの列を足すと、見出しの行が付いて書き出される")
    func addColumnToHeaderlessTableAddsHeader() throws {
        defer { cleanUp() }
        let sketch = Bare()
        var table = try sketch.loadTable(try file("t.csv", "1,2\n"))
        table.addColumn("sum")
        table.setFloat(0, 2, table.rows[0].getFloat(0) + table.rows[0].getFloat(1))
        #expect(table.columnTitles == ["", "", "sum"])
        let out = folder.appendingPathComponent("sum.csv").path
        try sketch.saveTable(table, out)
        #expect(try String(contentsOfFile: out, encoding: .utf8) == ",,sum\n1,2,3.0\n")
    }

    @Test("無い列・表の外の行には書かず、落ちずに知らせる")
    func writesOutsideTheTableAreIgnored() throws {
        defer { cleanUp() }
        var table = try Bare().loadTable(try file("t.csv", Self.temperatures), header: true)
        let before = table
        let typo = "maen-\(UUID().uuidString)"
        table.setFloat(0, typo, 1)
        table.setFloat(99, "high", 1)
        table.setString(0, 7, "x")
        #expect(table == before)
        #expect(TableValues.warnings.hasWarned(.noColumn(typo)))
        #expect(TableValues.warnings.message(for: .rowOutOfRange(call: "setFloat"))?.contains("numbered 0 to 1") == true)
    }

    // MARK: - 表を作る・文字列を書く (#2468)

    @Test("作った表に行を足して書くと、見出しと行が書かれ、見出しありで読み直すと同じ表に戻る")
    func createdTableRoundTrips() throws {
        defer { cleanUp() }
        let sketch = Bare()
        var table = Table(columns: ["x", "y"])
        #expect(table.rowCount == 0)
        #expect(table.columnTitles == ["x", "y"])
        table.addRow([10, 20])
        table.addRow([30, 40])
        let out = folder.appendingPathComponent("out/a.csv").path
        try sketch.saveTable(table, out)
        // 数は setFloat と同じ綴り (`10` は `"10.0"`)
        #expect(try String(contentsOfFile: out, encoding: .utf8) == "x,y\n10.0,20.0\n30.0,40.0\n")
        let reread = try sketch.loadTable(out, header: true)
        #expect(reread == table)
        #expect(reread.rows[1].getFloat("y") == 40)
    }

    @Test("足した行の文字のセルは setString で書け、setFloat と同じ綴りで数を持つ")
    func addedRowsTakeStringsAfterward() {
        var table = Table(columns: ["frame", "label"])
        table.addRow([1.5, 0])
        table.setString(0, "label", "start")
        var expected = Table(columns: ["frame", "label"])
        expected.addRow([0, 0])
        expected.setFloat(0, "frame", 1.5)
        expected.setString(0, "label", "start")
        #expect(table == expected)
        #expect(table.rows[0].getString("frame") == String(Float(1.5)))
    }

    @Test("列の数と合わない addRow は行を足さず、落ちずに知らせる")
    func addRowWithTheWrongWidthIsIgnored() {
        var table = Table(columns: ["x", "y"])
        table.addRow([1, 2, 3])
        table.addRow([1])
        #expect(table.rowCount == 0)
        let message = TableValues.warnings.message(for: .rowWidth(call: "addRow"))
        #expect(message?.contains("the table has 2 columns") == true)
        #expect(message?.contains("No row was added") == true)
        table.addRow([1, 2])
        #expect(table.rowCount == 1)
    }

    @Test("saveStrings は UTF-8 (BOM なし)・LF で 1 行ずつ書き、loadStrings で読み直すと同じ並びに戻る")
    func saveStringsRoundTrips() throws {
        defer { cleanUp() }
        let sketch = Bare()
        let out = folder.appendingPathComponent("out/a.txt").path
        try sketch.saveStrings(["a", "b"], out)
        let bytes = try Data(contentsOf: URL(fileURLWithPath: out))
        #expect(Array(bytes) == Array("a\nb\n".utf8))
        #expect(try sketch.loadStrings(out) == ["a", "b"])

        // 空の要素・最後の空の要素・空の並びも戻る
        for strings in [["", "x", ""], ["a", ""], [""], []] as [[String]] {
            try sketch.saveStrings(strings, out)
            #expect(try sketch.loadStrings(out) == strings, "\(strings)")
        }
    }

    @Test("改行を含む要素と、頭が U+FEFF の最初の要素は、中身を変えずに書いて知らせる")
    func saveStringsWarnsAboutLossyElements() throws {
        defer { cleanUp() }
        let sketch = Bare()
        let out = folder.appendingPathComponent("b.txt").path
        try sketch.saveStrings(["a\nb"], out)
        #expect(try String(contentsOfFile: out, encoding: .utf8) == "a\nb\n")
        #expect(try sketch.loadStrings(out) == ["a", "b"])
        #expect(StringLines.warnings.message(for: .lineBreak)?.contains("more than one line") == true)

        try sketch.saveStrings(["x", "c\rd"], out)
        #expect(try sketch.loadStrings(out) == ["x", "c", "d"])

        try sketch.saveStrings(["\u{FEFF}head", "tail"], out)
        let bytes = try Data(contentsOf: URL(fileURLWithPath: out))
        #expect(Array(bytes) == Array("\u{FEFF}head\ntail\n".utf8), "中身は変えずに書く")
        #expect(try sketch.loadStrings(out) == ["head", "tail"])
        #expect(StringLines.warnings.message(for: .byteOrderMark)?.contains("U+FEFF") == true)
    }

    @Test("saveStrings も、書けない場所へは unwritable で投げる")
    func saveStringsToAnUnwritablePlaceThrows() throws {
        defer { cleanUp() }
        let blocker = try file("blocker", "x")
        let out = blocker + "/a.txt"
        let failure = #expect(throws: DataFailure.self) { try Bare().saveStrings(["a"], out) }
        guard case .unwritable(let path, _) = failure else {
            Issue.record("unwritable で投げていない: \(String(describing: failure))")
            return
        }
        #expect(path == out)
    }

    // MARK: - バイト列 (#3708)

    /// 中身をバイトのまま置く。
    private func file(_ name: String, bytes: [UInt8]) throws -> String {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent(name)
        try Data(bytes).write(to: url)
        return url.path
    }

    /// 文字として読めないバイト・BOM・CRLF を含む中身。どれも解かずにそのまま返ることを見る。
    private static let blob: [UInt8] = [0xEF, 0xBB, 0xBF, 0x00, 0xFF, 0x0D, 0x0A, 0x80, 0x41]

    @Test("loadBytes は中身を解かずにそのまま返し、requestBytes は同じバイト列を返す")
    func loadBytesReturnsTheContentAsIs() async throws {
        defer { cleanUp() }
        let path = try file("blob.bin", bytes: Self.blob)
        let sketch = Bare()
        #expect(try sketch.loadBytes(path) == Self.blob)
        #expect(try await sketch.requestBytes(path) == sketch.loadBytes(path))
    }

    @Test("空のファイルは空のバイト列になる")
    func anEmptyFileGivesNoBytes() async throws {
        defer { cleanUp() }
        let path = try file("empty.bin", bytes: [])
        #expect(try Bare().loadBytes(path) == [])
        #expect(try await Bare().requestBytes(path) == [])
    }

    @Test("無い名前・無いディレクトリの中の名前は、探した場所を添えて notFound で投げる")
    func missingBytesNameWhereItLooked() async {
        for name in ["no-such-blob-\(UUID().uuidString).bin", folder.appendingPathComponent("no-dir/blob.bin").path] {
            let expected = DataFailure.notFound(path: name, searched: ImageFile.candidates(for: name).map(\.path))
            #expect(throws: expected) { try Bare().loadBytes(name) }
            await #expect(throws: expected) { try await Bare().requestBytes(name) }
        }
    }

    @Test("saveBytes は無い途中のディレクトリを作って書き、loadBytes で読み直すと同じ並びに戻る。書きかけは残らない")
    func saveBytesRoundTrips() throws {
        defer { cleanUp() }
        let sketch = Bare()
        let out = folder.appendingPathComponent("out/nested/blob.bin").path
        try sketch.saveBytes(Self.blob, out)
        #expect(try sketch.loadBytes(out) == Self.blob)
        // 上書きも同じ。短い中身で書き直すと、前の中身の尾は残らない
        try sketch.saveBytes([1, 2], out)
        #expect(try sketch.loadBytes(out) == [1, 2])
        try sketch.saveBytes([], out)
        #expect(try sketch.loadBytes(out) == [])
        let left = try FileManager.default.contentsOfDirectory(atPath: folder.appendingPathComponent("out/nested").path)
        #expect(left == ["blob.bin"], "書きかけの一時ファイルが残っている: \(left)")
    }

    @Test("saveBytes も、書けない場所 (途中がファイル・行き先がディレクトリ) へは unwritable で投げる")
    func saveBytesToAnUnwritablePlaceThrows() throws {
        defer { cleanUp() }
        let blocker = try file("blocker", "x")
        let directory = folder.appendingPathComponent("taken.bin")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for out in [blocker + "/blob.bin", directory.path] {
            let failure = #expect(throws: DataFailure.self) { try Bare().saveBytes([1], out) }
            guard case .unwritable(let path, let reason) = failure else {
                Issue.record("unwritable で投げていない: \(String(describing: failure))")
                continue
            }
            #expect(path == out)
            #expect(!reason.isEmpty)
        }
        #expect(try String(contentsOfFile: blocker, encoding: .utf8) == "x", "途中のファイルを壊していない")
    }

    @Test("書けない場所へは unwritable で投げる")
    func unwritablePlaceThrows() throws {
        defer { cleanUp() }
        let sketch = Bare()
        let table = try sketch.loadTable(try file("t.csv", Self.temperatures), header: true)
        // 置き場にしたい名前が、既にファイルとして在る (ディレクトリを作れない)
        let blocker = try file("blocker", "x")
        let out = blocker + "/t.csv"
        let failure = #expect(throws: DataFailure.self) { try sketch.saveTable(table, out) }
        guard case .unwritable(let path, let reason) = failure else {
            Issue.record("unwritable で投げていない: \(String(describing: failure))")
            return
        }
        #expect(path == out)
        #expect(!reason.isEmpty)
    }
}
