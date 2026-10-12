// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation
import mokume

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

    /// 解いた場所の在り方。
    ///
    /// **無い・ディレクトリでないことを、子を起こす前に読み分けるために持つ** (#2314)。
    /// `Process.run()` は作業ディレクトリが無いときも実行ファイルが無いときと同じ失敗で
    /// 投げるので、失敗の値からは分けられない。
    nonisolated enum Presence: Equatable {
        /// ディレクトリとして在る。
        case directory
        /// 何も無い。
        case missing
        /// 在るが、ディレクトリではない (ファイルなど)。
        case notDirectory

        /// 場所を読んで決める。ディレクトリかの判定は ``WorkDirectory/directoryExists(at:)`` の
        /// 1 本を使う (`ObjCBool` の受け渡しを写さない — #988)。
        static func of(_ place: URL) -> Presence {
            if WorkDirectory.directoryExists(at: place) { return .directory }
            return FileManager.default.fileExists(atPath: place.path) ? .notDirectory : .missing
        }
    }

    /// 案内に載せる形。**シェルにそのまま貼れる 1 語**にする。
    ///
    /// 単引用で包み、中の `'` は `'\''` (閉じて・逃がした `'` を置いて・開き直す) にする。
    /// **POSIX の sh と、bash・zsh (macOS の既定) では**、単引用の中にほかに意味を持つ文字が
    /// 無いので、空白も `$`・`"`・`\` もそのまま通る。二重引用は `$` と `` ` `` と `\` を
    /// 解くので使わない。
    ///
    /// **fish はこの規則の外である** — 単引用の中でも `\\` と `\'` を解くので、`\` を含む
    /// 場所はそのままでは通らない (`'\''` の形も fish では別の意味になる)。案内は sh 系に
    /// 貼られる前提で組んでいる。
    static func shellWord(_ url: URL) -> String {
        "'" + url.path.replacingOccurrences(of: "'", with: #"'\''"#) + "'"
    }
}
