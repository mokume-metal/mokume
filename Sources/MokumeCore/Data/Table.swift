// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation

/// 行と列に並んだ値。CSV を読んで作り (``Sketch/loadTable(_:header:)``)、CSV へ書き出す
/// (``Sketch/saveTable(_:_:)``)。
///
/// <!-- example: 文脈 var table: Table? -->
/// ```swift
/// func setup() {
///     guard var read = try? loadTable("data/temperatures.csv", header: true) else { return }
///     read.addColumn("mean")
///     for (i, row) in read.rows.enumerated() {
///         read.setFloat(i, "mean", (row.getFloat("high") + row.getFloat("low")) / 2)
///     }
///     try? saveTable(read, "out/temperatures-with-mean.csv")
///     table = read
/// }
/// ```
///
/// ## 値の型である
///
/// **代入すると写しになる。** 2 つの変数で持った表は、片方を書き換えてももう片方は変わらない。
/// 行 (``rows``) も読むための写しなので、書き換えは表に対して、行の番号を渡して行う
/// (``setFloat(_:_:_:)-(_,String,_)``)。Processing の `Table` は参照で持つので、行から
/// 書き換える (`row.setFloat(…)`) 書き方は、ここでは表から書き換える書き方になる。
///
/// ## 値は文字で持つ
///
/// セルは読んだ文字のまま持ち、数として読むのは取り出すときである
/// (``TableRow/getFloat(_:)-(String)``)。だから書き戻すと、触っていないセルは読んだときと
/// 同じ文字のまま出る (`12.50` が `12.5` に変わったりしない)。
public struct Table: Equatable, Sendable {
    /// 見出し。見出しの行を読まなかった表は `nil`。
    var titles: [String]?
    /// セル。行ごとに、どの行も ``columnCount`` だけ並ぶ。
    var cells: [[String]]

    init(_ parsed: TableFile.Parsed) {
        titles = parsed.titles
        cells = parsed.rows
    }

    /// 行の数。見出しの行は数えない。
    public var rowCount: Int { cells.count }

    /// 列の数。
    public var columnCount: Int { titles?.count ?? cells.first?.count ?? 0 }

    /// 列の名前 (見出し) を、左から並べたもの。**見出しの行を読まなかった表では空。**
    public var columnTitles: [String] { titles ?? [] }

    /// 行を上から並べたもの。見出しの行は入らない。
    ///
    /// <!-- example: 文脈 var table: Table! -->
    /// ```swift
    /// for (i, row) in table.rows.enumerated() {
    ///     let high = row.getFloat("high") * 10
    ///     rect(Float(i) * 3, height - high, 2, high)
    /// }
    /// ```
    ///
    /// **読むための写しである。** 行には書き換える口が無く、書き換えは
    /// ``setFloat(_:_:_:)-(_,String,_)`` で表に対して行う。
    public var rows: [TableRow] {
        cells.indices.map { TableRow(titles: titles, cells: cells[$0], index: $0) }
    }

    /// 右端に列を 1 つ足す。足した列のセルはどの行も空 (`""`)。
    ///
    /// 見出しの行を読まなかった表に足すと、表は見出しを持つようになる。もとからある列の
    /// 名前は空になり、書き出すと見出しの行が付く。
    public mutating func addColumn(_ title: String) {
        titles = (titles ?? Array(repeating: "", count: columnCount)) + [title]
        for row in cells.indices { cells[row].append("") }
    }

    /// セルに数を書く。`row` は 0 から数えた行の番号、`column` は列の名前。
    ///
    /// 数は文字にして持つ (`12.5` は `"12.5"`)。
    ///
    /// **無い列・表の外の行には書かず、初回だけ理由を知らせる。** 描く口と同じく投げない
    /// ([ADR-0020] 決定 5)。列を足すのは ``addColumn(_:)`` である。
    ///
    /// [ADR-0020]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0020-api-naming-and-surface.md
    public mutating func setFloat(_ row: Int, _ column: String, _ value: Float) {
        let index = TableValues.column(named: column, in: titles, call: "setFloat")
        write(row, index, String(value), call: "setFloat")
    }

    /// セルに数を書く。`column` は 0 から数えた列の番号。見出しの無い表はこちらで書く。
    ///
    /// 無い列・表の外の行の扱いは ``setFloat(_:_:_:)-(_,String,_)`` と同じ。
    public mutating func setFloat(_ row: Int, _ column: Int, _ value: Float) {
        let index = TableValues.column(numbered: column, width: columnCount, call: "setFloat")
        write(row, index, String(value), call: "setFloat")
    }

    /// セルに文字を書く。`row` は 0 から数えた行の番号、`column` は列の名前。
    ///
    /// 無い列・表の外の行の扱いは ``setFloat(_:_:_:)-(_,String,_)`` と同じ。
    public mutating func setString(_ row: Int, _ column: String, _ value: String) {
        let index = TableValues.column(named: column, in: titles, call: "setString")
        write(row, index, value, call: "setString")
    }

    /// セルに文字を書く。`column` は 0 から数えた列の番号。
    ///
    /// 無い列・表の外の行の扱いは ``setFloat(_:_:_:)-(_,String,_)`` と同じ。
    public mutating func setString(_ row: Int, _ column: Int, _ value: String) {
        let index = TableValues.column(numbered: column, width: columnCount, call: "setString")
        write(row, index, value, call: "setString")
    }

    /// 書く口の共通の道。列が解けなかったときは、解く側が既に知らせている。
    private mutating func write(_ row: Int, _ column: Int?, _ value: String, call: String) {
        guard let column else { return }
        guard cells.indices.contains(row) else {
            TableValues.warnOnce(
                .rowOutOfRange(call: call),
                "\(call)(): there is no row \(row) — \(TableValues.extent(rowCount, "row")). "
                    + "Nothing was written")
            return
        }
        cells[row][column] = value
    }
}

/// 表の 1 行。``Table/rows`` から取り出して、列の名前か番号で値を読む。
///
/// <!-- example: 文脈 var table: Table! -->
/// ```swift
/// for (i, row) in table.rows.enumerated() where row.getString("date").hasSuffix("-01") {
///     line(Float(i) * 3, 0, Float(i) * 3, row.getFloat("high") * 10)
/// }
/// ```
///
/// **読むための写しである。** 書き換えは表に対して行う (``Table/setFloat(_:_:_:)-(_,String,_)``)。
public struct TableRow: Sendable {
    let titles: [String]?
    let cells: [String]
    /// 表の中で何行目か (0 から)。知らせる文面に載せる。
    let index: Int

    /// 列の名前で、セルを文字のまま読む。
    ///
    /// **無い列なら空の文字を返し、初回だけ理由を知らせる** (表にある列の名前を添える)。
    /// 読み取りは落ちない ([ADR-0020] 決定 5)。
    ///
    /// [ADR-0020]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0020-api-naming-and-surface.md
    public func getString(_ column: String) -> String {
        cell(TableValues.column(named: column, in: titles, call: "getString")) ?? ""
    }

    /// 列の番号 (0 から) で、セルを文字のまま読む。見出しの無い表はこちらで読む。
    ///
    /// 無い列の扱いは ``getString(_:)-(String)`` と同じ。
    public func getString(_ column: Int) -> String {
        cell(TableValues.column(numbered: column, width: cells.count, call: "getString")) ?? ""
    }

    /// 列の名前で、セルを数として読む。前後の空白は落とす。
    ///
    /// <!-- example: 文脈 var row: TableRow! -->
    /// ```swift
    /// let mean = (row.getFloat("high") + row.getFloat("low")) / 2
    /// circle(width / 2, height / 2, mean * 4)
    /// ```
    ///
    /// **数にならないときは NaN を返し、初回だけ理由を知らせる** — セルが空・数でない文字
    /// (`"N/A"` など)・無い列のどれでも。読み取りは落ちない ([ADR-0020] 決定 5)。NaN は
    /// Processing の `getFloat` が欠けた値に返すものと同じで、0 のように黙って別の値に
    /// 化けない。幅や高さが NaN の矩形は描かれないので、欠けた日は縦棒の抜けとして見える。
    ///
    /// [ADR-0020]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0020-api-naming-and-surface.md
    public func getFloat(_ column: String) -> Float {
        let index = TableValues.column(named: column, in: titles, call: "getFloat")
        return number(index, named: "\"\(column)\"")
    }

    /// 列の番号 (0 から) で、セルを数として読む。見出しの無い表はこちらで読む。
    ///
    /// 数にならないときの扱いは ``getFloat(_:)-(String)`` と同じ。
    public func getFloat(_ column: Int) -> Float {
        let index = TableValues.column(numbered: column, width: cells.count, call: "getFloat")
        return number(index, named: "\(column)")
    }

    private func cell(_ column: Int?) -> String? {
        guard let column else { return nil }
        return cells[column]
    }

    private func number(_ column: Int?, named name: String) -> Float {
        guard let text = cell(column) else { return .nan }
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        if let value = Float(trimmed) { return value }
        TableValues.warnOnce(
            .notANumber(column: name),
            "getFloat(): row \(index), column \(name) holds \"\(text)\", which is not a number. "
                + "Reading it as NaN (said once per column)")
        return .nan
    }
}

/// 表の値を読み書きする口が 1 度だけ言う注意。
///
/// 表は値の型で持ち主が無いので、控えをここに置く。形は ``NumberValues`` と同じで、鍵で
/// 数える仕組みは ``WarningLog`` が持つ。
enum TableValues {
    /// 1 度だけ言う注意の種類。
    enum Warning: Hashable {
        /// 名前で引いた列が無い。**名前ごとに数える** — 綴りを誤った列ごとに 1 度言う。
        case noColumn(String)
        /// 見出しの無い表を名前で引いた。
        case noHeader
        /// 番号で引いた列が表の外。
        case columnOutOfRange
        /// 書く口に渡した行が表の外。**口ごとに数える。**
        case rowOutOfRange(call: String)
        /// 数として読めないセルがあった。**列ごとに数える** — 欠けた値の多い列が、
        /// 他の列の注意を黙らせない。
        case notANumber(column: String)
    }

    /// 言った注意の控え。書き換えるのは ``warnOnce(_:_:)`` だけ。
    private(set) static var warnings = WarningLog<Warning>()

    static func warnOnce(_ warning: Warning, _ message: @autoclosure () -> String) {
        warnings.warnOnce(warning, message())
    }

    /// 列の名前を番号に解く。解けなければ初回だけ知らせて `nil`。
    static func column(named name: String, in titles: [String]?, call: String) -> Int? {
        guard let titles else {
            warnOnce(
                .noHeader,
                "\(call)(\"\(name)\"): this table was read without a header row, so its columns "
                    + "have no names. Read it with loadTable(_:header: true), or use the column number")
            return nil
        }
        if let index = titles.firstIndex(of: name) { return index }
        warnOnce(
            .noColumn(name),
            "\(call)(\"\(name)\"): the table has no column named \"\(name)\". "
                + "Its columns are: \(titles.map { "\"\($0)\"" }.joined(separator: ", "))")
        return nil
    }

    /// 列の番号が表の中かを確かめる。外なら初回だけ知らせて `nil`。
    static func column(numbered column: Int, width: Int, call: String) -> Int? {
        if (0..<width).contains(column) { return column }
        warnOnce(
            .columnOutOfRange,
            "\(call)(\(column)): there is no column \(column) — \(extent(width, "column"))")
        return nil
    }

    /// 表の広がりを 1 句で言う (`the table has 3 columns, numbered 0 to 2`)。
    static func extent(_ count: Int, _ noun: String) -> String {
        switch count {
        case 0: "the table has no \(noun)s"
        case 1: "the table has 1 \(noun), numbered 0"
        default: "the table has \(count) \(noun)s, numbered 0 to \(count - 1)"
        }
    }
}
