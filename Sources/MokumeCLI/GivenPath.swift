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
    /// **空文字列は `base` そのものに解ける** (Foundation の解き方)。場所を名指していないので、
    /// 打たれた値としては口が断る (``Arguments/emptyPlace(_:)``・#2485) — ここは受け取った後の
    /// 計算で、断る場所ではない。
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
    /// **無い・ディレクトリでない・入れないことを読み分けるために持つ** (#2314)。子を
    /// 起こせなかったとき、`Process.run()` の失敗はどれも同じ形 (`NSFileNoSuchFileError` で、
    /// 違うのは `NSFilePath` に名指しした場所だけ) になり、入れない場所でも「無い」と
    /// 言う (実測: `chmod 000` の親の下を作業ディレクトリにすると `NSFileNoSuchFileError`)。
    /// だから失敗の値ではなく、**失敗の後にこちらで場所を stat し直して**決める。
    ///
    /// **限界: 読み直す前に場所が消えたり戻ったりすると、読み分けが変わる** (起こした時点と
    /// 確かめた時点の間の競合)。その回は、確かめた時点の姿を名乗る。
    ///
    /// **「無い」と言うのは、stat が `ENOENT` を返し、symlink でもないときだけ。** 入れない
    /// (`EACCES`)・symlink が巡る (`ELOOP`)・symlink の宛先が無い、は場所は在るので
    /// ``unreachable(reason:)`` で理由を言う — 「nothing is there」と言うと、在る場所を
    /// 探させることになる。
    nonisolated enum Presence: Equatable {
        /// ディレクトリとして在る。
        case directory
        /// 何も無い (`ENOENT`)。
        case missing
        /// 在るが、ディレクトリではない (ファイルなど)。
        case notDirectory
        /// 辿り着けない。`reason` は C の文面 (`strerror_r`) か、symlink の宛先が無いこと。
        case unreachable(reason: String)

        /// 場所を読んで決める。stat (symlink を辿る) の結果と `errno` で分ける。
        ///
        /// **``WorkDirectory/directoryExists(at:)`` と同じ判定である** — あちらも symlink を
        /// 辿った stat でディレクトリかを見るので、`.directory` になるのはあちらが `true` を
        /// 返すときだけ (検査が両方を突き合わせる)。あちらは真偽しか返さないので、辿り着けない
        /// 理由はここで読む。
        static func of(_ place: URL) -> Presence {
            var info = stat()
            guard stat(place.path, &info) == 0 else {
                let code = errno
                guard code == ENOENT else { return .unreachable(reason: GivenPath.errorText(code)) }
                // 名前は在るのに辿ると無い — 宛先の無い symlink である
                var link = stat()
                return lstat(place.path, &link) == 0
                    ? .unreachable(reason: "a symbolic link to something that is not there")
                    : .missing
            }
            return (info.st_mode & S_IFMT) == S_IFDIR ? .directory : .notDirectory
        }

        /// 名乗るときの句。**場所に関わる理由だけを持つ** (``directory`` は名乗らない)。
        var reason: String {
            switch self {
            case .directory: "a directory"
            case .missing: "no such directory"
            case .notDirectory: "not a directory"
            case .unreachable(let reason): reason
            }
        }
    }

    /// `errno` の C の文面 (`strerror_r`)。
    ///
    /// **Foundation の説明は言語の設定に左右されうるが、道具が話す言葉は英語で、設定で
    /// 切り替えない** (ADR-0038 決定 1・2)。`strerror` でなく `strerror_r` なのは、見張りの
    /// 作り直しが別の糸から呼ぶため。
    static func errorText(_ code: Int32) -> String {
        var text = [CChar](repeating: 0, count: 256)
        guard strerror_r(code, &text, text.count) == 0 else { return "error \(code)" }
        return text.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
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
