// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

/// CSV の文字を表のセルへ読み解き、表を CSV の文字へ書き戻す。
///
/// ## 読み方
///
/// - 区切りはカンマだけ。行の終わりは LF・CRLF・CR のどれでもよい
/// - **最後の改行は行を作らない。中身の無い行は読み飛ばす** (表の途中の空の行も)。1 列の
///   表の空の値は、書き戻すときに `""` と書いて空の行と見分ける (``format(titles:rows:)``)
/// - セルの頭が `"` なら、次に閉じる `"` までが値で、その間のカンマと改行も値の一部になる。
///   `""` は `"` 1 つ。セルの途中に現れた `"` は文字のまま読む
/// - 前後の空白は値の一部として残す (数として読むときに落とす — ``TableRow/getFloat(_:)-(String)``)
///
/// ## 壊れた CSV は投げる
///
/// 次の 3 つは ``DataFailure/malformed(path:line:reason:)`` で、壊れていた行を添えて投げる。
/// **読み進めると、値が 1 つずつずれた表が黙って返る**ためである。
///
/// - 閉じない引用符 — 開いた行を名乗る。閉じ忘れから先が 1 つのセルに飲み込まれる
/// - 閉じた引用符の後に、区切りでも改行でもない文字が続く
/// - 列の数が見出し (見出しが無ければ最初の行) と違う行
///
/// 隔離の外で走れる形にしてあるのは、待たない読み込みが読み解きを別の仕事として回すため
/// ([ADR-0010] 決定 6)。
///
/// [ADR-0010]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0010-concurrency-model.md
nonisolated enum TableFile {
    /// 読み解いた中身。``Table`` にする前の形。
    struct Parsed: Sendable, Equatable {
        /// 見出し。見出しの行を読まなかった表は `nil`。
        var titles: [String]?
        /// セル。行ごとに、どの行も同じ数だけ並ぶ。
        var rows: [[String]]
    }

    /// 1 行ぶんのセルと、その行が始まった行番号 (1 から)。
    private struct Record {
        var line: Int
        var cells: [String]
    }

    /// CSV の文字を表のセルへ読み解く。
    ///
    /// - Parameters:
    ///   - header: 最初の行を見出しとして読むか。
    ///   - path: 失敗を名乗るための名前。
    static func parse(_ text: String, header: Bool, path: String) throws(DataFailure) -> Parsed {
        var records = try records(of: text, path: path)
        var titles: [String]?
        if header {
            titles = records.isEmpty ? [] : records.removeFirst().cells
        }
        let width = titles?.count ?? records.first?.cells.count ?? 0
        if let broken = records.first(where: { $0.cells.count != width }) {
            let source = titles == nil ? "the first row" : "the header"
            throw .malformed(
                path: path, line: broken.line,
                reason: "this row has \(broken.cells.count) cells, but \(source) has \(width). "
                    + "A cell that holds a comma has to be quoted (\"a, b\")")
        }
        return Parsed(titles: titles, rows: records.map(\.cells))
    }

    /// 表を CSV の文字にする。行の終わりは LF で、最後の行も改行で終える。
    ///
    /// カンマ・引用符・改行を含むセルだけを引用符で囲む。**1 列の行の空のセルも囲む** —
    /// 囲まないと中身の無い行になり、読み直したときに読み飛ばされて行が消える。
    static func format(titles: [String]?, rows: [[String]]) -> String {
        var text = ""
        func append(_ cells: [String]) {
            if cells.count == 1, cells[0].isEmpty {
                text += "\"\"\n"
                return
            }
            text += cells.map(quoted).joined(separator: ",") + "\n"
        }
        if let titles { append(titles) }
        rows.forEach(append)
        return text
    }

    /// 囲みが要るセルだけを引用符で囲む。中の `"` は `""` にする。
    private static func quoted(_ cell: String) -> String {
        let needsQuotes = cell.unicodeScalars.contains {
            $0 == "," || $0 == "\"" || $0 == "\n" || $0 == "\r"
        }
        guard needsQuotes else { return cell }
        var escaped = String.UnicodeScalarView()
        for scalar in cell.unicodeScalars {
            if scalar == "\"" { escaped.append(scalar) }
            escaped.append(scalar)
        }
        return "\"" + String(escaped) + "\""
    }

    /// 文字を行とセルに分ける。見出しかどうかはまだ区別しない。
    ///
    /// 書記素ではなく Unicode のスカラーで見る。Swift は CRLF を 1 つの書記素に束ねるので、
    /// 書記素で比べると改行を取りこぼす。
    private static func records(of text: String, path: String) throws(DataFailure) -> [Record] {
        let scalars = Array(text.unicodeScalars)
        var records: [Record] = []
        var cells: [String] = []
        var cell = String.UnicodeScalarView()
        // いま読んでいる行番号と、いまの行が始まった行番号 (引用符の中の改行で両者がずれる)
        var line = 1
        var recordLine = 1
        // 引用符の中か。中なら、開いた行番号を持つ
        var quoteOpenedAt: Int?
        // 閉じた引用符の直後か (区切りか改行しか来てはいけない)
        var afterClosingQuote = false
        // この行に何か (文字・区切り・引用符) があったか。無い行は読み飛ばす
        var hasContent = false

        func endCell() {
            cells.append(String(cell))
            cell = String.UnicodeScalarView()
        }

        var index = 0
        while index < scalars.count {
            let scalar = scalars[index]
            let next = index + 1 < scalars.count ? scalars[index + 1] : nil

            if quoteOpenedAt != nil {
                switch scalar {
                case "\"" where next == "\"":
                    cell.append(scalar)
                    index += 1
                case "\"":
                    quoteOpenedAt = nil
                    afterClosingQuote = true
                case "\r" where next == "\n":
                    cell.append(scalar)
                    cell.append("\n")
                    index += 1
                    line += 1
                case "\n", "\r":
                    cell.append(scalar)
                    line += 1
                default:
                    cell.append(scalar)
                }
                index += 1
                continue
            }

            switch scalar {
            case ",":
                endCell()
                hasContent = true
                afterClosingQuote = false
            case "\n", "\r":
                if hasContent {
                    endCell()
                    records.append(Record(line: recordLine, cells: cells))
                }
                cells = []
                cell = String.UnicodeScalarView()
                hasContent = false
                afterClosingQuote = false
                if scalar == "\r", next == "\n" { index += 1 }
                line += 1
                recordLine = line
            case _ where afterClosingQuote:
                throw .malformed(
                    path: path, line: line,
                    reason: "a quoted cell is followed by more text before the next comma. "
                        + "A quote inside a quoted cell is written as two quotes (\"\")")
            case "\"" where cell.isEmpty:
                quoteOpenedAt = line
                hasContent = true
            default:
                cell.append(scalar)
                hasContent = true
            }
            index += 1
        }

        if let opened = quoteOpenedAt {
            throw .malformed(
                path: path, line: opened,
                reason: "a quoted cell opened on this line is never closed")
        }
        if hasContent {
            endCell()
            records.append(Record(line: recordLine, cells: cells))
        }
        return records
    }
}
