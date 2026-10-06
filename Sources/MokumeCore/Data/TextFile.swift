// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation

/// 文字のファイルを読み書きする。文字列の行 (``Sketch/loadStrings(_:)``)・表
/// (``Sketch/loadTable(_:header:)``)・JSON (``Sketch/loadJSONObject(_:)``)・XML
/// (``Sketch/loadXML(_:)``) が共有する。
///
/// **探すのは呼ぶ側** (``Sketch/assetURL(_:)``)。ここが受け取るのは場所が分かったファイルで、
/// 名前 (`path`) は失敗を名乗るためだけに持ち回る。
///
/// 隔離の外で走れる形にしてあるのは、待たない読み込みが読む仕事を別の仕事として回すため
/// ([ADR-0010] 決定 6)。
///
/// [ADR-0010]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0010-concurrency-model.md
nonisolated enum TextFile {
    /// ファイルを UTF-8 の文字として読む。先頭の BOM は落とす。
    static func read(_ url: URL, path: String) throws(DataFailure) -> String {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw .unreadable(path: path)
        }
        return try text(of: data, path: path)
    }

    /// 受け取ったバイト列を UTF-8 の文字として解く。先頭の BOM は落とす。
    ///
    /// URL から受け取った本文 (``WebFile``) もここを通す。**ファイルと URL で読み方を
    /// 分けない** — 同じ JSON が、置き場によって読めたり読めなかったりしないように。
    static func text(of data: Data, path: String) throws(DataFailure) -> String {
        // Foundation の `String(data:encoding:)` ではなく標準ライブラリで解く。あちらは BOM を
        // 黙って落とすので、落とすことが読み方の約束なのか道具の都合なのかが、ここから読めない
        guard var text = String(validating: data, as: UTF8.self) else {
            throw .unreadable(path: path)
        }
        // **BOM は値の一部ではない。** 表計算の道具が UTF-8 で書き出すと先頭に付くことがあり、
        // 残すと 1 行目 (表なら最初の列の見出し) の頭に見えない 1 文字が混ざって、名前で引けなくなる
        if text.unicodeScalars.first == "\u{FEFF}" { text.unicodeScalars.removeFirst() }
        return text
    }

    /// 文字を行に分ける。行の終わりは LF・CRLF・CR のどれでもよい。
    ///
    /// **最後の改行は行を作らない** — `"a\nb\n"` は 2 行である。改行だけが続くところは
    /// 空の行として残す (`"a\n\nb"` は 3 行)。
    static func lines(of text: String) -> [String] {
        var lines: [String] = []
        var current = ""
        var afterCarriageReturn = false
        // 書記素ではなく Unicode のスカラーで見る。Swift は CRLF を 1 つの書記素に束ねるので、
        // 書記素で比べると CR と LF の単独の改行を取りこぼす
        for scalar in text.unicodeScalars {
            switch scalar {
            case "\n" where afterCarriageReturn:
                afterCarriageReturn = false
            case "\n", "\r":
                lines.append(current)
                current = ""
                afterCarriageReturn = scalar == "\r"
            default:
                current.unicodeScalars.append(scalar)
                afterCarriageReturn = false
            }
        }
        if !current.isEmpty { lines.append(current) }
        return lines
    }

    /// 文字を UTF-8 (BOM なし) でファイルにする。途中のディレクトリは無ければ作る。
    ///
    /// **書きかけを残さない。** 隣の一時ファイルへ書いてから置き換えるので、書いている途中で
    /// 止まっても、前の中身か新しい中身のどちらかが残る。
    static func write(_ text: String, to path: String) throws(DataFailure) {
        let url = URL(fileURLWithPath: path)
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(text.utf8).write(to: url, options: .atomic)
        } catch {
            throw .unwritable(path: path, reason: Self.reason(of: error))
        }
    }

    /// 書けなかった事情を、人が読む 1 文にする。
    private static func reason(of error: any Error) -> String {
        let underlying = (error as NSError).userInfo[NSUnderlyingErrorKey] as? NSError
        return underlying?.localizedDescription ?? (error as NSError).localizedDescription
    }
}
