// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

/// 文字列の並びを、1 行ずつのファイルの中身にする (``SketchPart/saveStrings(_:_:)``)。
///
/// 読む側は ``TextFile/lines(of:)`` で、書いた中身を ``SketchPart/loadStrings(_:)`` で読み直すと
/// 同じ並びに戻ることを、ここが受け持つ。戻らない要素 (改行を含む・頭が U+FEFF) は中身を変えずに
/// 書き、1 度だけ知らせる (#2468)。CSV と違って囲む引用符が無いので、`saveTable` のように
/// 書き方で戻す道が無い。
enum StringLines {
    /// 1 度だけ言う注意の種類。
    enum Warning: Hashable {
        /// 改行 (LF・CR) を含む要素があった。読み直すと行が分かれる。
        case lineBreak
        /// 最初の要素の頭が U+FEFF だった。読み直すと BOM として落ちる。
        case byteOrderMark
    }

    /// 言った注意の控え。書き換えるのは ``warnOnce(_:_:)`` だけ。
    private(set) static var warnings = WarningLog<Warning>()

    static func warnOnce(_ warning: Warning, _ message: @autoclosure () -> String) {
        warnings.warnOnce(warning, message())
    }

    /// 1 行ずつ LF で終えた中身。**最後の行にも LF を付ける** — 付けないと、最後の要素が空の
    /// とき (`["a", ""]`) に読み直すと消える (``TextFile/lines(of:)`` は最後の改行で行を作らない)。
    nonisolated static func format(_ strings: [String]) -> String {
        strings.map { $0 + "\n" }.joined()
    }

    /// 読み直して同じ並びに戻らない要素があれば、種類ごとに 1 度だけ知らせる。`path` は書いた先。
    static func warnIfLossy(_ strings: [String], path: String) {
        if let index = strings.firstIndex(where: { $0.unicodeScalars.contains { $0 == "\n" || $0 == "\r" } }) {
            warnOnce(
                .lineBreak,
                "saveStrings(): element \(index) holds a line break. \"\(path)\" was written as given, "
                    + "but loadStrings() will read it back as more than one line (said once)")
        }
        if strings.first?.unicodeScalars.first == "\u{FEFF}" {
            warnOnce(
                .byteOrderMark,
                "saveStrings(): the first element starts with U+FEFF, the same character as a byte "
                    + "order mark. \"\(path)\" was written as given, but loadStrings() will drop that "
                    + "character when reading it back (said once)")
        }
    }
}
