// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation

// 資材の場所。
extension Sketch {
    /// 資材の名前を、実際に在るファイルの場所へ解く。
    ///
    /// <!-- example: 文脈 var notes: String? -->
    /// ```swift
    /// func setup() {
    ///     if let url = try? assetURL("assets/notes.txt") {
    ///         notes = try? String(contentsOf: url, encoding: .utf8)
    ///     }
    /// }
    /// ```
    ///
    /// **探す場所と順は ``loadImage(_:)`` と同じ** — 作業ディレクトリ、束ねた資源の置き場、
    /// 実行ファイルの隣の包みの中、の順に見て、最初に在ったものを返す。`/` で始まる名前は
    /// そのまま使う。mokume が読まない形式のファイルを、同梱した資材から読むのに使う。
    /// 外のパッケージが資材を読むときも、これを使えば利用者の置き方と食い違わない。
    ///
    /// - Throws: どこにも無いとき。説明には探した場所が載る。
    public func assetURL(_ path: String) throws(AssetFailure) -> URL {
        let searched = ImageFile.candidates(for: path)
        guard let url = searched.first(where: { FileManager.default.fileExists(atPath: $0.path) })
        else {
            throw .notFound(path: path, searched: searched.map(\.path))
        }
        return url
    }
}
