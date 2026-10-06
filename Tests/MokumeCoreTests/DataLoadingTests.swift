// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation
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
    private let folder = FileManager.default.temporaryDirectory
        .appendingPathComponent("mokume-data-\(UUID().uuidString)")

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
