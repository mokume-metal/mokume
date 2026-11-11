// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation

/// 行と列に並んだ値。CSV を読んで作り (``SketchPart/loadTable(_:header:)``)、CSV へ書き出す
/// (``SketchPart/saveTable(_:_:)``)。
///
/// <!-- example: 文脈 var table: Table? -->
/// ```swift
/// func setup() throws {
///     var read = try loadTable("data/temperatures.csv", header: true)
///     read.addColumn("mean")
///     for (i, row) in read.rows.enumerated() {
///         read.setFloat(i, "mean", (row.getFloat("high") + row.getFloat("low")) / 2)
///     }
///     try saveTable(read, "out/temperatures-with-mean.csv")
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
/// 読み出しは main actor の上にあるので、`DispatchQueue.concurrentPerform` などで並列に回すときは、分ける前に値へ写しておく (形は ``map(_:_:_:_:_:)`` の説明)。
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

    /// 見出しだけを持つ、行の無い表を作る。行は ``addRow(_:)`` で足す。Processing の `new Table()` と
    /// `addColumn()` をまとめた形。
    ///
    /// <!-- example: 文脈 var log = Table(columns: ["frame", "x", "y"]) -->
    /// ```swift
    /// func mouseDragged(deltaX: Float, deltaY: Float) {
    ///     log.addRow([Float(frameCount), mouseX, mouseY])
    /// }
    ///
    /// func keyPressed() {
    ///     if key == "s" { try? saveTable(log, "out/strokes.csv") }
    /// }
    /// ```
    ///
    /// `keyPressed()` は投げ返せない所で、書けなくても絵は続くので `try?` で受けている (理由が要るなら
    /// `do` / `catch` で受ける)。``SketchPart/saveTable(_:_:)`` で書くと最初の行が見出しになり、
    /// ``SketchPart/loadTable(_:header:)`` を `header: true` で読み直すと同じ表に戻る。
    public init(columns: [String]) {
        titles = columns
        cells = []
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

    /// 下端に行を 1 つ足す。`values` は左の列から並べた数で、**列の数と同じだけ渡す。**
    ///
    /// 数は ``setFloat(_:_:_:)-(_,String,_)`` と同じ綴りで文字にして持つ (`10` は `"10.0"`)。文字の
    /// セルは、足した行へ ``setString(_:_:_:)-(_,String,_)`` で書く (行の番号は足す前の ``rowCount``)。
    ///
    /// **列の数と合わない並びは足さず、初回だけ理由を知らせる。** 無い列に書かない
    /// ``setFloat(_:_:_:)-(_,String,_)`` と同じく投げない ([ADR-0020] 決定 5)。
    ///
    /// [ADR-0020]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0020-api-naming-and-surface.md
    public mutating func addRow(_ values: [Float]) {
        guard values.count == columnCount else {
            TableValues.warnOnce(
                .rowWidth(call: "addRow"),
                "addRow(): got \(values.count) value\(values.count == 1 ? "" : "s"), but "
                    + "\(TableValues.extent(columnCount, "column")). No row was added")
            return
        }
        cells.append(values.map { String($0) })
    }

    /// セルに数を書く。`row` は 0 から数えた行の番号、`column` は列の名前。
    ///
    /// 数は文字にして持つ (`12.5` は `"12.5"`)。NaN と無限は `"nan"`・`"inf"`・`"-inf"` と
    /// 書かれ、10 進の綴りでないので、``TableRow/getFloat(_:)-(String)`` で読み直すと数でない
    /// 文字として NaN になる (知らせが出る)。
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

    /// セルに整数を書く。`row` は 0 から数えた行の番号、`column` は列の名前。
    ///
    /// <!-- example: 文脈 var hits = Table(columns: ["frame", "count"]) -->
    /// ```swift
    /// func mousePressed() {
    ///     hits.addRow([Float(frameCount), 0])
    ///     hits.setInt(hits.rowCount - 1, "count", 3)
    /// }
    /// ```
    ///
    /// 整数の綴りで書く (`3` は `"3"`。``setFloat(_:_:_:)-(_,String,_)`` は `"3.0"`)。``getInt(_:_:)-(_,String)``
    /// で読み直すと同じ整数に戻る。
    ///
    /// 無い列・表の外の行の扱いは ``setFloat(_:_:_:)-(_,String,_)`` と同じ (書かずに、初回だけ知らせる)。
    public mutating func setInt(_ row: Int, _ column: String, _ value: Int) {
        let index = TableValues.column(named: column, in: titles, call: "setInt")
        write(row, index, String(value), call: "setInt")
    }

    /// セルに整数を書く。`column` は 0 から数えた列の番号。見出しの無い表はこちらで書く。
    ///
    /// <!-- example: 文脈 var counts: Table! -->
    /// ```swift
    /// func mousePressed() {
    ///     counts.setInt(0, 1, counts.getInt(0, 1) + 1)
    /// }
    /// ```
    ///
    /// 綴りと、無い列・表の外の行の扱いは ``setInt(_:_:_:)-(_,String,_)`` と同じ。
    public mutating func setInt(_ row: Int, _ column: Int, _ value: Int) {
        let index = TableValues.column(numbered: column, width: columnCount, call: "setInt")
        write(row, index, String(value), call: "setInt")
    }

    /// 行をすべて除く。見出し (列の名前と数) は残る。
    ///
    /// <!-- example: 文脈 var log = Table(columns: ["frame", "x", "y"]) -->
    /// ```swift
    /// func keyPressed() {
    ///     if key == "c" { log.clearRows() }
    /// }
    /// ```
    ///
    /// 見出しの行を読まなかった表は、列の数を行から数えるので、行を除くと ``columnCount`` は 0 になる。
    public mutating func clearRows() {
        cells.removeAll()
    }

    /// 行を 1 つ除く。`row` は 0 から数えた行の番号で、後ろの行は 1 つずつ前へ詰まる (順は保つ)。
    ///
    /// <!-- example: 文脈 var log = Table(columns: ["frame", "x", "y"]) -->
    /// ```swift
    /// func mouseDragged(deltaX: Float, deltaY: Float) {
    ///     log.addRow([Float(frameCount), mouseX, mouseY])
    ///     if log.rowCount > 100 { log.removeRow(0) }
    /// }
    /// ```
    ///
    /// **表の外の行には何もせず、初回だけ理由を知らせる** (``setFloat(_:_:_:)-(_,String,_)`` と同じく
    /// 投げない。[ADR-0020] 決定 5)。
    ///
    /// [ADR-0020]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0020-api-naming-and-surface.md
    public mutating func removeRow(_ row: Int) {
        guard cells.indices.contains(row) else {
            TableValues.warnOnce(
                .rowOutOfRange(call: "removeRow"),
                "removeRow(): there is no row \(row) — \(TableValues.extent(rowCount, "row")). "
                    + "Nothing was removed")
            return
        }
        cells.remove(at: row)
    }

    /// 列を 1 つ除く。`column` は列の名前で、右の列は 1 つずつ左へ詰まる。
    ///
    /// <!-- example: 文脈 var table: Table! -->
    /// ```swift
    /// func setup() throws {
    ///     table.removeColumn("notes")
    ///     try saveTable(table, "out/without-notes.csv")
    /// }
    /// ```
    ///
    /// **無い列には何もせず、初回だけ理由を知らせる** (表にある列の名前を添える。投げない)。
    public mutating func removeColumn(_ column: String) {
        remove(column: TableValues.column(named: column, in: titles, call: "removeColumn"))
    }

    /// 列を 1 つ除く。`column` は 0 から数えた列の番号。見出しの無い表はこちらで除く。
    ///
    /// <!-- example: 文脈 var table: Table! -->
    /// ```swift
    /// func keyPressed() {
    ///     if key == "x", table.columnCount > 0 { table.removeColumn(table.columnCount - 1) }
    /// }
    /// ```
    ///
    /// 無い列の扱いは ``removeColumn(_:)-(String)`` と同じ。
    public mutating func removeColumn(_ column: Int) {
        remove(column: TableValues.column(numbered: column, width: columnCount, call: "removeColumn"))
    }

    /// すべてのセルの前後の空白を落とす。空白には改行とタブも含める (`"  12 \t"` は `"12"`)。
    ///
    /// <!-- example: 文脈 var table: Table! -->
    /// ```swift
    /// func setup() throws {
    ///     table = try loadTable("data/survey.csv", header: true)
    ///     table.trim()
    /// }
    /// ```
    ///
    /// 整えるのはセルだけで、見出し (列の名前) は書き換えない。数として読む口
    /// (``getFloat(_:_:)-(_,String)``) は前後の空白を落として読むので、整えなくても数は読める。
    /// 整えるのは、文字のまま比べる・書き出すときである。
    public mutating func trim() {
        rewrite(column: nil) { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
    }

    /// 列の名前を名指して、その列のセルだけ前後の空白を落とす。
    ///
    /// <!-- example: 文脈 var table: Table! -->
    /// ```swift
    /// table.trim("name")
    /// ```
    ///
    /// 落とす空白は ``trim()`` と同じ。**無い列には何もせず、初回だけ理由を知らせる。**
    public mutating func trim(_ column: String) {
        let index = TableValues.column(named: column, in: titles, call: "trim")
        guard let index else { return }
        rewrite(column: index) { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
    }

    /// 列の番号 (0 から) を名指して、その列のセルだけ前後の空白を落とす。見出しの無い表はこちら。
    ///
    /// <!-- example: 文脈 var table: Table! -->
    /// ```swift
    /// table.trim(0)
    /// ```
    ///
    /// 扱いは ``trim(_:)-(String)`` と同じ。
    public mutating func trim(_ column: Int) {
        let index = TableValues.column(numbered: column, width: columnCount, call: "trim")
        guard let index else { return }
        rewrite(column: index) { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
    }

    /// `tokens` に含まれるどれかの文字を、すべてのセルから除く (`removeTokens(",$ ")` は `"$1,200"` を
    /// `"1200"` にする)。
    ///
    /// <!-- example: 文脈 var prices: Table! -->
    /// ```swift
    /// func setup() throws {
    ///     prices = try loadTable("data/prices.csv", header: true)
    ///     prices.removeTokens(",$ ")
    /// }
    /// ```
    ///
    /// `tokens` は並びではなく、1 文字ずつの集まりとして読む (`",$"` はカンマと `$` のどちらも除く)。
    /// 文字は Swift の `Character` (書記素) で比べる。整えるのはセルだけで、見出しは書き換えない。
    public mutating func removeTokens(_ tokens: String) {
        let removed = Set(tokens)
        rewrite(column: nil) { $0.filter { !removed.contains($0) } }
    }

    /// 列の名前を名指して、その列のセルだけから `tokens` のどれかの文字を除く。
    ///
    /// <!-- example: 文脈 var prices: Table! -->
    /// ```swift
    /// prices.removeTokens(",$", "price")
    /// ```
    ///
    /// 除く文字は ``removeTokens(_:)`` と同じ。**無い列には何もせず、初回だけ理由を知らせる。**
    public mutating func removeTokens(_ tokens: String, _ column: String) {
        let index = TableValues.column(named: column, in: titles, call: "removeTokens")
        guard let index else { return }
        let removed = Set(tokens)
        rewrite(column: index) { $0.filter { !removed.contains($0) } }
    }

    /// 列の番号 (0 から) を名指して、その列のセルだけから `tokens` のどれかの文字を除く。
    ///
    /// <!-- example: 文脈 var prices: Table! -->
    /// ```swift
    /// prices.removeTokens(",$", 1)
    /// ```
    ///
    /// 扱いは ``removeTokens(_:_:)-(_,String)`` と同じ。
    public mutating func removeTokens(_ tokens: String, _ column: Int) {
        let index = TableValues.column(numbered: column, width: columnCount, call: "removeTokens")
        guard let index else { return }
        let removed = Set(tokens)
        rewrite(column: index) { $0.filter { !removed.contains($0) } }
    }

    /// 列を除く共通の道。列が解けなかったときは、解く側が既に知らせている。
    private mutating func remove(column: Int?) {
        guard let column else { return }
        titles?.remove(at: column)
        for row in cells.indices { cells[row].remove(at: column) }
    }

    /// セルを書き換える共通の道。`column` が `nil` ならすべての列。
    private mutating func rewrite(column: Int?, _ change: (String) -> String) {
        for row in cells.indices {
            if let column {
                cells[row][column] = change(cells[row][column])
            } else {
                cells[row] = cells[row].map(change)
            }
        }
    }

    /// 行の番号と列の名前で、セルを文字のまま読む。`row` は 0 から数えた行の番号。
    ///
    /// <!-- example: 文脈 var table: Table! -->
    /// ```swift
    /// for i in 0..<table.rowCount {
    ///     text(table.getString(i, "date"), 20, 20 + Float(i) * 16)
    /// }
    /// ```
    ///
    /// **番号で回すときは ``rows`` ではなくこの口で読む。** ``rows`` は呼ぶたびに全行の写しを作るので、
    /// ループの中で `rows[i]` と引くと、行の数の 2 乗の手間になる。この口は行を写さずにセルを読む。
    ///
    /// **無い列・表の外の行なら空の文字を返し、初回だけ理由を知らせる** (``TableRow/getString(_:)-(String)``
    /// と同じ空の値)。読み取りは落ちない ([ADR-0020] 決定 5)。
    ///
    /// [ADR-0020]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0020-api-naming-and-surface.md
    public func getString(_ row: Int, _ column: String) -> String {
        let index = TableValues.column(named: column, in: titles, call: "getString")
        return read(row, index, call: "getString", reading: "an empty string") ?? ""
    }

    /// 行の番号と列の番号 (どちらも 0 から) で、セルを文字のまま読む。見出しの無い表はこちらで読む。
    ///
    /// <!-- example: 文脈 var table: Table! -->
    /// ```swift
    /// for i in 0..<table.rowCount {
    ///     text(table.getString(i, 0), 20, 20 + Float(i) * 16)
    /// }
    /// ```
    ///
    /// 無い列・表の外の行の扱いは ``getString(_:_:)-(_,String)`` と同じ。
    public func getString(_ row: Int, _ column: Int) -> String {
        let index = TableValues.column(numbered: column, width: columnCount, call: "getString")
        return read(row, index, call: "getString", reading: "an empty string") ?? ""
    }

    /// 行の番号と列の名前で、セルを数として読む。
    ///
    /// <!-- example: 文脈 var table: Table! -->
    /// ```swift
    /// for i in 0..<table.rowCount {
    ///     let high = table.getFloat(i, "high") * 10
    ///     rect(Float(i) * 3, height - high, 2, high)
    /// }
    /// ```
    ///
    /// 数とする綴りと、数にならないときの扱い (NaN と、列ごとに 1 度の知らせ) は
    /// ``TableRow/getFloat(_:)-(String)`` と同じ。番号で回すときに ``rows`` を経ない理由は
    /// ``getString(_:_:)-(_,String)`` にある。
    ///
    /// **無い列・表の外の行なら NaN を返し、初回だけ理由を知らせる。**
    public func getFloat(_ row: Int, _ column: String) -> Float {
        let index = TableValues.column(named: column, in: titles, call: "getFloat")
        let text = read(row, index, call: "getFloat", reading: "NaN")
        return TableValues.number(text, row: row, named: "\"\(column)\"")
    }

    /// 行の番号と列の番号 (どちらも 0 から) で、セルを数として読む。見出しの無い表はこちらで読む。
    ///
    /// <!-- example: 文脈 var table: Table! -->
    /// ```swift
    /// for i in 0..<table.rowCount {
    ///     point(table.getFloat(i, 0), table.getFloat(i, 1))
    /// }
    /// ```
    ///
    /// 扱いは ``getFloat(_:_:)-(_,String)`` と同じ。
    public func getFloat(_ row: Int, _ column: Int) -> Float {
        let index = TableValues.column(numbered: column, width: columnCount, call: "getFloat")
        let text = read(row, index, call: "getFloat", reading: "NaN")
        return TableValues.number(text, row: row, named: "\(column)")
    }

    /// 行の番号と列の名前で、セルを整数として読む。
    ///
    /// <!-- example: 文脈 var table: Table! -->
    /// ```swift
    /// for i in 0..<table.rowCount {
    ///     let count = table.getInt(i, "count")
    ///     rect(20 + Float(i) * 30, height - 20, 24, -Float(count) * 4)
    /// }
    /// ```
    ///
    /// 読み方は ``TableRow/getInt(_:)-(String)`` と同じ (**丸めない**。`"2"`・`"2.0"`・`"1e3"` は整数で、
    /// `"2.5"` は 0 を返して知らせる)。番号で回すときに ``rows`` を経ない理由は
    /// ``getString(_:_:)-(_,String)`` にある。
    ///
    /// **無い列・表の外の行なら 0 を返し、初回だけ理由を知らせる。**
    public func getInt(_ row: Int, _ column: String) -> Int {
        let index = TableValues.column(named: column, in: titles, call: "getInt")
        let text = read(row, index, call: "getInt", reading: "0")
        return TableValues.integer(text, row: row, named: "\"\(column)\"")
    }

    /// 行の番号と列の番号 (どちらも 0 から) で、セルを整数として読む。見出しの無い表はこちらで読む。
    ///
    /// <!-- example: 文脈 var table: Table! -->
    /// ```swift
    /// for i in 0..<table.rowCount {
    ///     circle(width / 2, height / 2, Float(table.getInt(i, 0)))
    /// }
    /// ```
    ///
    /// 扱いは ``getInt(_:_:)-(_,String)`` と同じ。
    public func getInt(_ row: Int, _ column: Int) -> Int {
        let index = TableValues.column(numbered: column, width: columnCount, call: "getInt")
        let text = read(row, index, call: "getInt", reading: "0")
        return TableValues.integer(text, row: row, named: "\(column)")
    }

    /// 読む口の共通の道。セルの文字か、読めなければ `nil`。列が解けなかったときは、解く側が既に
    /// 知らせている。表の外の行は、口ごとに 1 度知らせる。
    private func read(_ row: Int, _ column: Int?, call: String, reading empty: String) -> String? {
        guard let column else { return nil }
        guard cells.indices.contains(row) else {
            TableValues.warnOnce(
                .rowOutOfRange(call: call),
                "\(call)(): there is no row \(row) — \(TableValues.extent(rowCount, "row")). "
                    + "Reading it as \(empty)")
            return nil
        }
        return cells[row][column]
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

    /// 列の名前で、セルを数として読む。
    ///
    /// <!-- example: 文脈 var row: TableRow! -->
    /// ```swift
    /// let mean = (row.getFloat("high") + row.getFloat("low")) / 2
    /// circle(width / 2, height / 2, mean * 4)
    /// ```
    ///
    /// 数とするのは **10 進の綴りだけ** (`"12.5"`・`"-2"`・`"+5"`・`".5"`・`"1e3"`) で、前後の
    /// 空白は改行も含めて落とす (`"3\n"` は 3)。`Float` に収まらない数 (`"1e39"`) は無限大になる。
    ///
    /// **数にならないときは NaN を返し、初回だけ理由を知らせる** — セルが空・数でない文字
    /// (`"N/A"` など)・無い列のどれでも。`"nan"`・`"NaN"`・`"inf"`・`"Infinity"`・16 進 (`"0x10"`)
    /// も、数でない文字である。読み取りは落ちない ([ADR-0020] 決定 5)。NaN は
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
    /// 数とする綴りと、数にならないときの扱いは ``getFloat(_:)-(String)`` と同じ。
    public func getFloat(_ column: Int) -> Float {
        let index = TableValues.column(numbered: column, width: cells.count, call: "getFloat")
        return number(index, named: "\(column)")
    }

    /// 列の名前で、セルを整数として読む。
    ///
    /// <!-- example: 文脈 var row: TableRow! -->
    /// ```swift
    /// let stations = row.getInt("stations")
    /// for i in 0..<stations {
    ///     circle(20 + Float(i) * 12, height / 2, 8)
    /// }
    /// ```
    ///
    /// **丸めない** — `"2"`・`"2.0"`・`"1e3"` は整数で、`"2.5"` は 0 を返して知らせる (黙って別の値を
    /// 返さない。``JSONObject/getInt(_:)`` と同じ)。数とする綴りは ``getFloat(_:)-(String)`` と同じ
    /// 10 進だけで、前後の空白は落とす。小数が要るときは ``getFloat(_:)-(String)``。
    ///
    /// **整数にならないときは 0 を返し、初回だけ理由を知らせる** — セルが空・整数でない数・`Int` に
    /// 収まらない数・数でない文字 (`"N/A"` など)・無い列のどれでも (列ごとに 1 度)。読み取りは落ちない
    /// ([ADR-0020] 決定 5)。
    ///
    /// [ADR-0020]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0020-api-naming-and-surface.md
    public func getInt(_ column: String) -> Int {
        let index = TableValues.column(named: column, in: titles, call: "getInt")
        return TableValues.integer(cell(index), row: self.index, named: "\"\(column)\"")
    }

    /// 列の番号 (0 から) で、セルを整数として読む。見出しの無い表はこちらで読む。
    ///
    /// <!-- example: 文脈 var row: TableRow! -->
    /// ```swift
    /// circle(width / 2, height / 2, Float(row.getInt(0)))
    /// ```
    ///
    /// 読み方と、整数にならないときの扱いは ``getInt(_:)-(String)`` と同じ。
    public func getInt(_ column: Int) -> Int {
        let index = TableValues.column(numbered: column, width: cells.count, call: "getInt")
        return TableValues.integer(cell(index), row: self.index, named: "\(column)")
    }

    private func cell(_ column: Int?) -> String? {
        guard let column else { return nil }
        return cells[column]
    }

    private func number(_ column: Int?, named name: String) -> Float {
        TableValues.number(cell(column), row: index, named: name)
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
        /// 足す行の値の数が、列の数と合わない。**口ごとに数える。**
        case rowWidth(call: String)
        /// 数として読めないセルがあった。**列ごとに数える** — 欠けた値の多い列が、
        /// 他の列の注意を黙らせない。
        case notANumber(column: String)
        /// 整数として読めないセルがあった。**列ごとに数える** (``notANumber(column:)`` と同じ理由)。
        case notAnInteger(column: String)
    }

    /// セルの文字を数にする (`getFloat` の口が共有する)。`text` が `nil` (無い列・表の外の行) なら、
    /// 解く側が既に知らせているので黙って NaN。数でない文字は、列ごとに 1 度知らせて NaN。
    static func number(_ text: String?, row: Int, named name: String) -> Float {
        guard let text else { return .nan }
        if let value = DecimalText.float(text) { return value }
        warnOnce(
            .notANumber(column: name),
            "getFloat(): row \(row), column \(name) holds \"\(text)\", which is not a number. "
                + "Reading it as NaN (said once per column)")
        return .nan
    }

    /// セルの文字を整数にする (`getInt` の口が共有する)。丸めずに、綴りの値が整数で `Int` に収まる
    /// ときだけ読む (``DecimalText/int(_:)``)。`text` が `nil` なら黙って 0、読めなければ列ごとに
    /// 1 度知らせて 0。
    static func integer(_ text: String?, row: Int, named name: String) -> Int {
        guard let text else { return 0 }
        if let value = DecimalText.int(text) { return value }
        warnOnce(
            .notAnInteger(column: name),
            "getInt(): row \(row), column \(name) holds \"\(text)\", which is not an integer that "
                + "fits in an Int. Reading it as 0 (said once per column)")
        return 0
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
