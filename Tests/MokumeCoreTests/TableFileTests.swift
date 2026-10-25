// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation
import Testing

@testable import MokumeCore

/// CSV を表のセルへ読み解く規則と、書き戻す規則 (#1964)。ファイルも GPU も要らない。
///
/// 壊れた CSV を投げるのは、読み進めると値が 1 列ずつずれた表が黙って返るためである
/// (``TableFile`` の冒頭)。ここでは「投げる」ことと、壊れていた行を名乗ることを見る。
@Suite("CSV の読み解き")
nonisolated struct TableFileTests {
    private func parse(_ text: String, header: Bool = false) throws(DataFailure) -> TableFile.Parsed {
        try TableFile.parse(text, header: header, path: "t.csv")
    }

    @Test("見出しありなら最初の行が見出しになり、行には入らない")
    func headerRowBecomesTitles() throws {
        let parsed = try parse("date,high,low\n2025-01-01,8.5,1.2\n2025-01-02,9.0,0.4\n", header: true)
        #expect(parsed.titles == ["date", "high", "low"])
        #expect(parsed.rows == [["2025-01-01", "8.5", "1.2"], ["2025-01-02", "9.0", "0.4"]])
    }

    @Test("見出しなしなら最初の行も値の行で、見出しは無い")
    func withoutHeaderEveryLineIsARow() throws {
        let parsed = try parse("date,high,low\n2025-01-01,8.5,1.2\n")
        #expect(parsed.titles == nil)
        #expect(parsed.rows.count == 2)
        #expect(parsed.rows[0] == ["date", "high", "low"])
    }

    @Test("引用符の中のカンマと改行は値の一部で、\"\" は引用符 1 つ")
    func quotedCellsKeepCommasNewlinesAndQuotes() throws {
        let text = "name,note\n\"Smith, J\",\"line one\nline two\"\n\"say \"\"hi\"\"\",\"\"\n"
        let parsed = try parse(text, header: true)
        #expect(parsed.rows == [["Smith, J", "line one\nline two"], ["say \"hi\"", ""]])
    }

    @Test("CRLF・CR の行の終わりも、LF と同じ行に分ける。引用符の中の CRLF はそのまま残す")
    func everyLineEndingSplitsRows() throws {
        #expect(try parse("a,b\r\n1,2\r\n").rows == [["a", "b"], ["1", "2"]])
        #expect(try parse("a,b\r1,2\r").rows == [["a", "b"], ["1", "2"]])
        #expect(try parse("\"x\r\ny\",2\r\n").rows == [["x\r\ny", "2"]])
    }

    @Test("最後の改行と中身の無い行は行を作らない。改行が無くても最後の行は読む")
    func blankLinesAndTrailingNewlineMakeNoRows() throws {
        #expect(try parse("a,b\n1,2").rows == [["a", "b"], ["1", "2"]])
        #expect(try parse("a,b\n\n1,2\n\n").rows == [["a", "b"], ["1", "2"]])
        #expect(try parse("").rows.isEmpty)
        #expect(try parse("", header: true) == TableFile.Parsed(titles: [], rows: []))
    }

    @Test("空のセルは空の文字として残る。カンマだけの行は空のセルの並び")
    func emptyCellsStayEmpty() throws {
        #expect(try parse("a,,c\n,,\n").rows == [["a", "", "c"], ["", "", ""]])
    }

    @Test("セルの途中の引用符は文字のまま読む")
    func quoteInsideAnUnquotedCellIsLiteral() throws {
        #expect(try parse("5\" screen,1\n").rows == [["5\" screen", "1"]])
    }

    @Test("閉じない引用符は、開いた行を名乗って投げる")
    func unclosedQuoteNamesTheLineItOpened() {
        #expect(
            throws: DataFailure.malformed(
                path: "t.csv", line: 2, reason: "a quoted cell opened on this line is never closed")
        ) {
            try parse("a,b\n1,\"never closed\n3,4\n")
        }
    }

    @Test("閉じた引用符の後に文字が続けば投げる")
    func textAfterClosingQuoteThrows() {
        let failure = #expect(throws: DataFailure.self) { try parse("a,b\n\"x\"y,2\n") }
        guard case .malformed(_, let line, _) = failure else {
            Issue.record("malformed で投げていない: \(String(describing: failure))")
            return
        }
        #expect(line == 2)
    }

    @Test("列の数が見出しと違う行は、その行を名乗って投げる (詰めも捨てもしない)")
    func columnCountMismatchThrows() {
        let failure = #expect(throws: DataFailure.self) {
            try parse("date,high,low\n2025-01-01,8.5,1.2\n2025-01-02,9.0\n", header: true)
        }
        guard case .malformed(_, let line, let reason) = failure else {
            Issue.record("malformed で投げていない: \(String(describing: failure))")
            return
        }
        #expect(line == 3)
        #expect(reason.contains("2 cells") && reason.contains("the header has 3"))
    }

    @Test("見出しの無い表では、最初の行の列の数に揃っていない行を投げる")
    func columnCountFollowsFirstRowWithoutHeader() {
        let failure = #expect(throws: DataFailure.self) { try parse("1,2\n3,4,5\n") }
        guard case .malformed(_, let line, let reason) = failure else {
            Issue.record("malformed で投げていない: \(String(describing: failure))")
            return
        }
        #expect(line == 2)
        #expect(reason.contains("the first row has 2"))
    }

    @Test("引用符の中の改行をまたいでも、壊れた行の番号はファイルの行で数える")
    func lineNumbersCountNewlinesInsideQuotes() {
        let failure = #expect(throws: DataFailure.self) { try parse("a,b\n\"x\ny\",1\n2\n") }
        guard case .malformed(_, let line, _) = failure else {
            Issue.record("malformed で投げていない: \(String(describing: failure))")
            return
        }
        #expect(line == 4)
    }

    @Test("カンマ・引用符・改行を含むセルだけを囲んで書き、読み直すと同じセルに戻る")
    func formatQuotesOnlyWhatNeedsIt() throws {
        let rows = [["Smith, J", "say \"hi\"", "a\nb", "plain", " spaced "]]
        let text = TableFile.format(titles: ["n", "q", "l", "p", "s"], rows: rows)
        #expect(text == "n,q,l,p,s\n\"Smith, J\",\"say \"\"hi\"\"\",\"a\nb\",plain, spaced \n")
        #expect(try parse(text, header: true) == TableFile.Parsed(titles: ["n", "q", "l", "p", "s"], rows: rows))
    }

    /// 読む側は文字の先頭の U+FEFF を BOM として落とす (``TextFile/text(of:path:)``)。囲めば
    /// 書いた文字の頭は `"` になり、囲みの中の U+FEFF は値として残る (#2340)。
    @Test("頭が U+FEFF のセルは囲んで書く。途中に U+FEFF があるだけのセルは囲まない")
    func formatQuotesLeadingByteOrderMark() throws {
        let rows = [["\u{FEFF}z", "a\u{FEFF}b"], ["\u{FEFF}", "x"]]
        let text = TableFile.format(titles: nil, rows: rows)
        #expect(text == "\"\u{FEFF}z\",a\u{FEFF}b\n\"\u{FEFF}\",x\n")
        #expect(try parse(text).rows == rows)
        // 1 列の表の、U+FEFF だけのセルも囲む (空のセルと同じく、囲まないと行が消えうる)
        #expect(TableFile.format(titles: ["\u{FEFF}"], rows: [["1"]]) == "\"\u{FEFF}\"\n1\n")
    }

    /// 書いて読み直すと戻ることを、例ではなく小さな字母の総当たりで見る (#2340)。読み直しは
    /// ファイルと同じく ``TextFile/text(of:path:)`` を通すので、読む側が落とすもの (文字の先頭の
    /// BOM・中身の無い行) を書く側が取りこぼせば、ここで出る。
    @Test("セル 2 つの表は、どの値の組でも、書いて読み直すと同じ表に戻る")
    func everySmallTableRoundTrips() throws {
        let letters = ["a", " ", ",", "\"", "\n", "\r", "\u{FEFF}"]
        let cells = [""] + letters + letters.flatMap { first in letters.map { first + $0 } }
        var broken: [String] = []
        for header in [false, true] {
            for first in cells {
                for second in cells {
                    // 1 列 2 行と 2 列 1 行。見出しを持つ表は、最初の行が見出しになる
                    for lines in [[[first], [second]], [[first, second]]] {
                        let table = TableFile.Parsed(
                            titles: header ? lines[0] : nil, rows: Array(lines.dropFirst(header ? 1 : 0)))
                        let written = TableFile.format(titles: table.titles, rows: table.rows)
                        let reread = try parse(TextFile.text(of: Data(written.utf8), path: "t.csv"), header: header)
                        if reread != table { broken.append("\(table) → \(reread)") }
                    }
                }
            }
        }
        #expect(broken.isEmpty, "\(broken.count) 通りが戻らない: \(broken.prefix(3))")
    }

    @Test("1 列の表の空のセルは \"\" と書き、読み直しても行が消えない")
    func singleEmptyCellSurvivesRoundTrip() throws {
        let rows = [["a"], [""], ["b"]]
        let text = TableFile.format(titles: nil, rows: rows)
        #expect(text == "a\n\"\"\nb\n")
        #expect(try parse(text).rows == rows)
    }
}
