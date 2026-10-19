// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation

/// 見張り (`watch`) の下で、資材の置き場の断片を**元のファイル**から読む ([#2517]).
///
/// ## なぜ要るのか
///
/// 見張りの子の作業ディレクトリはスケッチの根で、`assets/paint.metal` は根の直下には無い。
/// 候補の並び (``ImageFile/candidates(for:)``) はそのあとビルドが束へ写した**写し**に解けるので、
/// 置き場の元のファイルを保存しても断片の見張りが見ている写しは変わらず、走らせたまま差し替わらない
/// (保存を拾って組み直すという ``Sketch/loadShader(_:values:surfaces:)`` の約束が破れる)。
///
/// ## 何をするのか
///
/// 見張りが子へ置き場の元の在処 (``StartupReads/assetOrigin``) を渡したときだけ、先頭が置き場の名前の
/// 相対パスを、**作業ディレクトリの次** (今は束の写しが占める位置) に置き場の元へ解く。作業ディレクトリに
/// 同名のファイルがあれば今までどおりそちらが先で、置き場の元に無ければ今までの候補がそのまま続く。
///
/// **断片の口 (``ShaderSource/read(at:)``) だけが通る。** 画像・模型・`loadBytes` など
/// ``ImageFile/candidates(for:)`` を共有する他の資材の在処は変えない (画像は資材の保存で作り直しが届く・
/// #2520)。見張りの外 (`mokume run`・束ねた `.app`) は合図が渡らないので、解き方は変わらない。
///
/// [#2517]: https://github.com/mokume-metal/mokume/issues/2517
nonisolated enum ShaderOrigin {
    /// 見張りが渡した置き場の元。**無ければ `nil`** — 空白だけの値と絶対パスでない値は渡されていない
    /// ものとして扱う (相対の値は読む側の作業ディレクトリで別の場所になる)。
    ///
    /// **環境を読むのはここだけ** — 一覧 ([StartupReads]) が読み場所としてこのファイルを名指している。
    static func startup(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL? {
        guard let given = environment[StartupReads.assetOrigin.key] else { return nil }
        let trimmed = given.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("/") else { return nil }
        return URL(fileURLWithPath: trimmed, isDirectory: true)
    }

    /// 候補の並びに、置き場の元を差す。
    ///
    /// - Parameter origin: 置き場の元 (`Sources/<target>/assets`)。`nil` なら何もしない。
    /// - Parameter path: 断片の名前。**先頭の区切りが置き場の名前** (`assets/paint.metal` なら `assets`)
    ///   のときだけ解く。絶対パス・置き場の外を指す名前 (`..` を含む)・置き場の名前でない先頭は
    ///   今までの候補のまま。
    /// - Parameter candidates: ``ImageFile/candidates(for:)`` の並び。先頭は作業ディレクトリ。
    static func inserting(origin: URL?, for path: String, into candidates: [URL]) -> [URL] {
        guard let origin, !candidates.isEmpty, !path.hasPrefix("/") else { return candidates }
        let parts = path.split(separator: "/", omittingEmptySubsequences: true)
        guard parts.count >= 2, parts[0] == origin.lastPathComponent,
            !parts.contains(".."), !parts.contains(".")
        else { return candidates }
        let source = parts.dropFirst().reduce(origin) { $0.appendingPathComponent(String($1)) }
        var arranged = candidates
        arranged.insert(source, at: 1)
        return arranged
    }
}
