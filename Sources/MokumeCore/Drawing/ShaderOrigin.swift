// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation
import Synchronization

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
/// **束にも写されている断片だけである。** 束の写しの候補が在るときに限って元を差す。置き場が束に
/// 入っていない構成 (`.copy("assets/img.png")` だけの宣言・`.process("assets")`) では、変更前どおり
/// 「見つからない」になる — 資材の宣言の検査 (`ResourceDeclaration.check`) が止めるはずの抜けを、見張りだけが
/// 隠さない。
///
/// **断片の口 (``ShaderSource/read(at:origin:candidates:)``) だけが通る。** 画像・模型・`loadBytes` など
/// ``ImageFile/candidates(for:)`` を共有する他の資材の在処は変えない (画像は資材の保存で作り直しが届く・
/// #2520)。見張りの外 (`mokume run`・束ねた `.app`) は合図が渡らないので、解き方は変わらない。
///
/// [#2517]: https://github.com/mokume-metal/mokume/issues/2517
nonisolated enum ShaderOrigin {
    /// 合図を読んだか、読んだ値。**一度だけ控える** — 読んだら環境から消すので、2 度目からは環境に無い。
    private struct Taken {
        var done = false
        var value: URL?
    }

    private static let taken = Mutex(Taken())

    /// 見張りが渡した置き場の元。**無ければ `nil`。** 初めて呼んだときに環境から読んで消し、控える。
    ///
    /// **環境を読むのはここだけ** — 一覧 ([StartupReads]) が読み場所としてこのファイルを名指している。
    /// **読んだら環境から消す** (``SharedFrameSurface/launchOwner`` と同じ)。合図はこのプロセスを起こした
    /// 見張りが渡したもので、このプロセスがさらに起こす子 (スケッチが `Process` で直に走らせる別の実行
    /// ファイルなど) のものではない — 継がせると、孫が別のスケッチの断片をこの置き場から読みかねない。
    /// 読むのは ``SketchApplication`` の組み立てで、スケッチの `setup()` より前である。
    static func startup() -> URL? {
        taken.withLock { taken in
            if !taken.done {
                taken.value = take()
                taken.done = true
            }
            return taken.value
        }
    }

    /// 控えを捨てる。**検査だけが呼ぶ** — 本番は起動の瞬間に 1 度読んだきりである。
    static func forgetStartup() {
        taken.withLock { $0 = Taken() }
    }

    /// 合図を読み、環境から消す。
    static func take(
        from environment: [String: String] = ProcessInfo.processInfo.environment,
        unset: (String) -> Void = { unsetenv($0) }
    ) -> URL? {
        let origin = origin(from: environment)
        if environment[StartupReads.assetOrigin.key] != nil { unset(StartupReads.assetOrigin.key) }
        return origin
    }

    /// 環境に載った合図を解く。空白だけの値と絶対パスでない値は渡されていないものとして扱う
    /// (相対の値は読む側の作業ディレクトリで別の場所になる)。
    static func origin(from environment: [String: String]) -> URL? {
        guard let given = environment[StartupReads.assetOrigin.key] else { return nil }
        let trimmed = given.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("/") else { return nil }
        return URL(fileURLWithPath: trimmed, isDirectory: true)
    }

    /// 候補の並びに、置き場の元を差す。
    ///
    /// - Parameter origin: 置き場の元 (`Sources/<target>/assets`)。`nil` なら何もしない。
    /// - Parameter path: 断片の名前。**先頭の区切りが置き場の名前** (`assets/paint.metal` なら `assets`)
    ///   のときだけ解く。比べるときは大文字小文字を区別しない (束の写しの解き方と揃える — APFS の既定)。
    ///   絶対パス・置き場の外を指す名前 (`..` を含む)・置き場の名前でない先頭は今までの候補のまま。
    /// - Parameter candidates: ``ImageFile/candidates(for:)`` の並び。先頭は作業ディレクトリ。
    /// - Parameter exists: ファイルが在るか。**既定は他の口と同じ判定** (``AssetLookup/presence(of:)``・#2838)。
    ///   確かめられない候補は在るとは数えない (探す口がそこで止めて名乗る)。**差すのは、作業ディレクトリより後ろの候補 (束の写し) の
    ///   どれかが在るときだけ** — 束に入っていない断片を、見張りだけが元から読んで隠さない。
    static func inserting(
        origin: URL?, for path: String, into candidates: [URL],
        exists: (URL) -> Bool = { AssetLookup.presence(of: $0) == .present }
    ) -> [URL] {
        guard let origin, !candidates.isEmpty, !path.hasPrefix("/") else { return candidates }
        let parts = path.split(separator: "/", omittingEmptySubsequences: true)
        guard parts.count >= 2,
            parts[0].caseInsensitiveCompare(origin.lastPathComponent) == .orderedSame,
            !parts.contains(".."), !parts.contains(".")
        else { return candidates }
        guard candidates.dropFirst().contains(where: exists) else { return candidates }
        let source = parts.dropFirst().reduce(origin) { $0.appendingPathComponent(String($1)) }
        var arranged = candidates
        arranged.insert(source, at: 1)
        return arranged
    }
}
