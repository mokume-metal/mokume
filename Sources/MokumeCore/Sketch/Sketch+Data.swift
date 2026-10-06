// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation

// 文字列と表。**説明文の正本はこちら** ([ADR-0020] 決定 4)。
//
// 描き場所に触れないので、``Canvas`` に転送先を持たない。走っていなくても (`init` の中でも)
// 読み書きできる。
//
// [ADR-0020]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0020-api-naming-and-surface.md
extension Sketch {

    // MARK: - 文字列

    /// 文字のファイルを読み、1 行ずつの文字列にする。読み終わるまで返らない。
    ///
    /// <!-- example: 文脈 var lines: [String] = [] -->
    /// ```swift
    /// func setup() {
    ///     lines = (try? loadStrings("data/poem.txt")) ?? []
    /// }
    ///
    /// func draw() {
    ///     background(23, 26, 31)
    ///     for (i, line) in lines.enumerated() {
    ///         text(line, 40, 60 + Float(i) * 28)
    ///     }
    /// }
    /// ```
    ///
    /// 読むのは **UTF-8** の文字。行の終わりは LF・CRLF・CR のどれでもよく、返る文字列に
    /// 改行は含まれない。**最後の改行は行を作らない** (`"a\nb\n"` は 2 行)。途中の空の行は
    /// 空の文字列として残る。先頭の BOM は読み飛ばす。
    ///
    /// 探す場所は ``loadImage(_:)`` と同じ (``assetURL(_:)``)。
    ///
    /// **読み込みは投げる。** 読めなかったときに別の道を選ぶ判断が要るので、黙って空へ
    /// 倒さない。見つからないときの説明には**探した場所**が載る。
    ///
    /// - Throws: 見つからないときに ``DataFailure/notFound(path:searched:)``、UTF-8 の文字と
    ///   して読めないときに ``DataFailure/unreadable(path:)``。
    // shot: 撮れない 読んだ文字列を返す口で、読む先のファイルがこのリポジトリの例には無い
    public func loadStrings(_ path: String) throws(DataFailure) -> [String] {
        let url = try dataURL(path)
        return TextFile.lines(of: try TextFile.read(url, path: path))
    }

    /// 文字のファイルを読み、1 行ずつの文字列にする。**読んでいる間、他の仕事を止めない。**
    ///
    /// <!-- example: 文脈 var lines: [String] = [] -->
    /// ```swift
    /// func setup() {
    ///     Task { lines = (try? await requestStrings("data/poem.txt")) ?? [] }
    /// }
    ///
    /// func draw() {
    ///     background(23, 26, 31)
    ///     for (i, line) in lines.enumerated() {
    ///         text(line, 40, 60 + Float(i) * 28)
    ///     }
    /// }
    /// ```
    ///
    /// 読み方と失敗は ``loadStrings(_:)`` と同じ。呼び方と届く前の扱いは ``requestImage(_:)``
    /// と同じで、**`setup()` の中で `Task` を起こし、そこから呼ぶ。** 届くまでの ``draw()`` は
    /// 文字列が無いまま呼ばれる。
    // shot: 撮れない 読んだ文字列を返す口で、読む先のファイルがこのリポジトリの例には無い
    public func requestStrings(_ path: String) async throws(DataFailure) -> [String] {
        let url = try dataURL(path)
        return try await Self.readAway(path) { () throws(DataFailure) in
            TextFile.lines(of: try TextFile.read(url, path: path))
        }
    }

    // MARK: - 表

    /// CSV のファイルを読み、表にする。読み終わるまで返らない。
    ///
    /// <!-- example: 文脈 var table: Table? -->
    /// ```swift
    /// func setup() {
    ///     table = try? loadTable("data/temperatures.csv", header: true)
    /// }
    ///
    /// func draw() {
    ///     background(23, 26, 31)
    ///     guard let table else { return }
    ///     for (i, row) in table.rows.enumerated() {
    ///         let high = row.getFloat("high") * 10
    ///         rect(Float(i) * 3, height - high, 2, high)
    ///     }
    /// }
    /// ```
    ///
    /// `header` が `true` なら、最初の行を列の名前 (見出し) として読み、名前で値を引ける
    /// (``TableRow/getFloat(_:)-(String)``)。`false` (既定) なら最初の行も値の行で、列は
    /// 番号で引く (``TableRow/getFloat(_:)-(Int)``)。
    ///
    /// ## 読み方
    ///
    /// - 区切りはカンマだけ。行の終わりは LF・CRLF・CR のどれでもよい。文字は UTF-8 で、
    ///   先頭の BOM は読み飛ばす
    /// - `"…"` で囲んだセルの中のカンマと改行は値の一部で、`""` は `"` 1 つ
    /// - **最後の改行と、中身の無い行は行を作らない**
    /// - セルは文字のまま持ち、数として読むのは取り出すとき
    ///
    /// ## 壊れた CSV は投げる
    ///
    /// **閉じない引用符と、列の数が見出し (見出しが無ければ最初の行) と違う行は、壊れていた行を
    /// 添えて投げる** (``DataFailure/malformed(path:line:reason:)``)。詰めたり捨てたりして
    /// 読み進めると、値が 1 列ずつずれた表が黙って返るためである。
    ///
    /// 探す場所は ``loadImage(_:)`` と同じ (``assetURL(_:)``)。
    ///
    /// - Throws: 見つからない・UTF-8 の文字として読めない・CSV として壊れているとき。
    // shot: 撮れない 読んだ表を返す口で、読む先のファイルがこのリポジトリの例には無い
    public func loadTable(_ path: String, header: Bool = false) throws(DataFailure) -> Table {
        let url = try dataURL(path)
        return Table(try TableFile.parse(try TextFile.read(url, path: path), header: header, path: path))
    }

    /// CSV のファイルを読み、表にする。**読んでいる間、他の仕事を止めない。**
    ///
    /// <!-- example: 文脈 var table: Table? -->
    /// ```swift
    /// func setup() {
    ///     Task { table = try? await requestTable("data/temperatures.csv", header: true) }
    /// }
    ///
    /// func draw() {
    ///     background(23, 26, 31)
    ///     guard let table else { return }
    ///     for (i, row) in table.rows.enumerated() {
    ///         let high = row.getFloat("high") * 10
    ///         rect(Float(i) * 3, height - high, 2, high)
    ///     }
    /// }
    /// ```
    ///
    /// 読み方と失敗は ``loadTable(_:header:)`` と同じ。呼び方と届く前の扱いは
    /// ``requestImage(_:)`` と同じで、**`setup()` の中で `Task` を起こし、そこから呼ぶ。**
    /// 大きな表を読んでもフレームが詰まらない。
    // shot: 撮れない 読んだ表を返す口で、読む先のファイルがこのリポジトリの例には無い
    public func requestTable(_ path: String, header: Bool = false) async throws(DataFailure) -> Table {
        let url = try dataURL(path)
        let parsed = try await Self.readAway(path) { () throws(DataFailure) in
            try TableFile.parse(try TextFile.read(url, path: path), header: header, path: path)
        }
        return Table(parsed)
    }

    /// 表を CSV のファイルにする。書き終わるまで返らない。
    ///
    /// <!-- example: 文脈 var table: Table? -->
    /// ```swift
    /// func setup() {
    ///     do {
    ///         var read = try loadTable("data/temperatures.csv", header: true)
    ///         read.addColumn("mean")
    ///         for (i, row) in read.rows.enumerated() {
    ///             read.setFloat(i, "mean", (row.getFloat("high") + row.getFloat("low")) / 2)
    ///         }
    ///         try saveTable(read, "out/temperatures-with-mean.csv")
    ///         table = read
    ///     } catch {
    ///         print(error)
    ///     }
    /// }
    /// ```
    ///
    /// 見出しを持つ表なら、最初の行に見出しを書く。文字は UTF-8 (BOM なし)、行の終わりは LF。
    /// カンマ・引用符・改行を含むセルだけを `"…"` で囲む。書いたファイルを ``loadTable(_:header:)``
    /// で読み直すと、同じ表に戻る。
    ///
    /// 置き場は**作業ディレクトリが基準** (``save(_:)`` と同じ)。途中のディレクトリは無ければ
    /// 作る。**書きかけを残さない** — 隣の一時ファイルへ書いてから置き換えるので、途中で
    /// 止まっても前の中身か新しい中身のどちらかが残る。
    ///
    /// **書き出しは投げる。** 書けなかったときに別の道を選ぶ判断が要るので、黙って
    /// 捨てない。
    ///
    /// - Throws: 書けなかったときに ``DataFailure/unwritable(path:reason:)``。
    // shot: 撮れない 結果が絵ではなくファイルになる
    public func saveTable(_ table: Table, _ path: String) throws(DataFailure) {
        try TextFile.write(TableFile.format(titles: table.titles, rows: table.cells), to: path)
    }

    // MARK: - 共通の道

    /// 名前を、在るファイルの場所へ解く。探し方は ``assetURL(_:)`` そのもの。
    private func dataURL(_ path: String) throws(DataFailure) -> URL {
        do {
            return try assetURL(path)
        } catch {
            switch error {
            case .notFound(let path, let searched): throw .notFound(path: path, searched: searched)
            }
        }
    }

    /// 読んで解く仕事を、別の仕事として回して待つ。
    ///
    /// `Task.detached` の失敗は型を失うので、ここで ``DataFailure`` へ戻す。
    private static func readAway<Value: Sendable>(
        _ path: String, _ work: @escaping @Sendable () throws(DataFailure) -> Value
    ) async throws(DataFailure) -> Value {
        do {
            return try await Task.detached(priority: .utility) { try work() }.value
        } catch let failure as DataFailure {
            throw failure
        } catch {
            throw .unreadable(path: path)
        }
    }
}
