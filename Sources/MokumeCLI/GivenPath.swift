// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation

/// 利用者が打ったパスを、場所 (絶対パスの URL) へ解く。**基準は走らせた場所。**
///
/// ## なぜ 1 か所にするのか
///
/// 口ごとに解き方が違っていた — 相対の `URL` のまま持ち回る・走らせた場所から解く・
/// スケッチの場所から解く、が混ざり、同じ綴りが口によって別の場所を指した
/// ([#2323](https://github.com/mokume-metal/mokume/issues/2323))。
///
/// - 相対の `URL` のまま `Process.currentDirectoryURL` へ渡すと、Foundation は**先頭の `..`
///   だけを落とす**。`../probe` は `<走らせた場所>/probe` を名指しして起動に失敗し、`..` は
///   投げずに走らせた場所で子を動かす ([#2314](https://github.com/mokume-metal/mokume/issues/2314))
/// - `--scratch-path` だけがスケッチの場所から解いていたので、`render` で隣に並ぶ `--out` と
///   基準が割れていた ([#2320](https://github.com/mokume-metal/mokume/issues/2320))
///
/// だから**受け取った時点で 1 度だけ絶対パスにし、以後はそれだけを使う。** 基準は走らせた
/// 場所 — シェルの補完が効くのはそこからなので、打つ人が組み立てる相対パスはそちらが基準に
/// なる (#2323 の判断)。例外は Package.swift へ書く `new --local` だけで、あちらは作られる
/// スケッチから見た相対である (``NewCommand/packageIdentity(local:sketch:)``)。
///
/// **main actor には置かない。** 見張りの作り直しの糸からも辿られる (``Invocation`` と同じ)。
nonisolated enum GivenPath {
    /// 走らせた場所。
    static var currentDirectory: URL {
        URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
    }

    /// 打たれたパスを、`base` から解いた絶対パスの URL にする。
    ///
    /// 先頭の `~` は home に展開する (引用して打たれたときにシェルが展開しないため)。
    /// 返す URL は**基準の URL を持たず、`.`・`..` を含まない** — 相対の URL を `Process` へ
    /// 渡すと先頭の `..` が落ちる (上の説明)。
    ///
    /// - Parameter base: 相対パスを解く基準。既定は走らせた場所で、**検査から渡せる形にしてある。**
    static func resolve(_ given: String, from base: URL = currentDirectory, isDirectory: Bool = true)
        -> URL
    {
        let expanded = NSString(string: given).expandingTildeInPath
        return URL(fileURLWithPath: expanded, isDirectory: isDirectory, relativeTo: base)
            .standardizedFileURL
    }

    /// 案内に載せる形。**シェルにそのまま貼れる 1 語**にする。
    ///
    /// 単引用で包み、中の `'` は `'\''` (閉じて・逃がした `'` を置いて・開き直す) にする。
    /// 単引用の中ではほかに意味を持つ文字が無いので、空白も `$`・`"`・`\` もそのまま通る。
    /// 二重引用は `$` と `` ` `` と `\` を解くので使わない。
    static func shellWord(_ url: URL) -> String {
        "'" + url.path.replacingOccurrences(of: "'", with: #"'\''"#) + "'"
    }
}
