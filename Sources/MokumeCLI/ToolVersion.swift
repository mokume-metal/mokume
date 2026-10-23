// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation

/// 道具自身の版。
///
/// ## なぜソースに定数で持たないか
///
/// リリースは**リポジトリのファイルを 1 つも変えない** (`scripts/release.py` の冒頭)。
/// 版をソースに書けば、その規律を破るか、書いた値が腐るかのどちらかになる。
///
/// ## どこから導くか
///
/// **実行ファイルの在処が既に版を持っている。** Homebrew は `Cellar/<名前>/<版>/` に
/// 置くので、そこを読めばよい ([#634])。
///
/// **配布物は、自分の版を同梱の 1 行ファイル (``releaseFileName``) で名乗れる** ([#2887])。
/// Homebrew の置き場は `Cellar/` が版を持つが、同じ tarball を展開した場所は何も持たず、
/// 手元ビルドと区別できなかった。リリースの組み立て (`make cli-dist`) が版と SHA を受け取った
/// ときだけ、tarball の中にそのファイルを置く。実行ファイルの**隣**にあるので、展開した場所を
/// 別のディレクトリへ移しても名乗りは変わらない。
///
/// ## 規律
///
/// 1. **断定できないときは断定しない。** 在処から読めなければ「手元ビルド」と名乗る。
///    誤って配布版を名乗ると、古いことを疑う手掛かりを消してしまう — [#633] は手元
///    ビルドを配布版と取り違えて、解消済みの不具合を新しい不具合として起票した
/// 2. **添える日時はソースの新しさを意味しない。** 実行ファイルが組まれた時刻であって、
///    その中身がいつのソースから来たかは分からない (#633 はまさにここで取り違えた)。
///    それでも出すのは、**疑う契機になる**からである
///
/// [#633]: https://github.com/mokume-metal/mokume/issues/633
/// [#634]: https://github.com/mokume-metal/mokume/issues/634
/// [#2887]: https://github.com/mokume-metal/mokume/issues/2887
enum ToolVersion {
    /// 版が読める在処の目印。
    static let cellarMarker = "Cellar"

    /// 配布物が同梱する、自分の版と SHA を書いた 1 行ファイルの名前 (実行ファイルの隣)。
    /// 書き手は Makefile の `cli-dist`。
    static let releaseFileName = "mokume.release"

    /// 配布物が名乗る版と出所。
    struct Release: Equatable {
        /// `v` を落とした版 (`0.29.0`)。
        var version: String
        /// 先頭 7 文字に縮めた SHA。
        var commit: String
    }

    /// いまの道具の名乗り 1 行。
    static func describe() -> String {
        let executable = currentExecutable()
        return describe(executable: executable, modified: executable.flatMap(fileDate))
    }

    /// いまの道具の配布版。**読めなければ `nil`** (手元ビルドは版を持たない)。
    ///
    /// 名乗り (``describe()``) は人が読む文なので、依存の版と突き合わせるには使えない
    /// ([#1230](https://github.com/mokume-metal/mokume/issues/1230))。
    static func release() -> String? {
        currentExecutable().flatMap { releaseVersion(in: $0) }
    }

    /// 配布版。**配布物が名乗る版を、置き場の版より先に取る。** 同梱のファイルは同じ配布物から
    /// 来た版で、置き場 (Homebrew の `Cellar/<版>_1/`) は経路の名乗りだからである。
    static func releaseVersion(in executable: URL) -> String? {
        shipped(beside: executable)?.version ?? homebrewVersion(in: executable)
    }

    /// 在処と日時から名乗りを組む。
    ///
    /// **判定はここだけが持つ。** 引数で受けるのは、検査が在処を差し替えられるように
    /// するため (`Command.invokedName` と同じ流儀)。
    static func describe(executable: URL?, modified: Date?) -> String {
        guard let executable else { return DoctorCommand.unknown }
        // **版は配布物のものを優先し、置き場は経路の名乗りにだけ使う** (#2887)
        let shipped = shipped(beside: executable)
        if let cellar = homebrewVersion(in: executable) {
            return "\(shipped?.version ?? cellar) (Homebrew)"
        }
        if let shipped { return "\(shipped.version) (release \(shipped.commit))" }
        return "local build (\(modified.map { Timestamp.text($0) } ?? DoctorCommand.unknown))"
    }

    /// 実行ファイルの隣に同梱された版。**無い・空・形が壊れているときは `nil`** (規律 1 —
    /// 壊れた中身を版として名乗らない)。シンボリックリンクは辿って、実体の隣を見る。
    static func shipped(beside executable: URL) -> Release? {
        let url = executable.resolvingSymlinksInPath().deletingLastPathComponent()
            .appendingPathComponent(releaseFileName)
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        return parseRelease(text)
    }

    /// 同梱ファイルの中身 (`v0.29.0 e48a07f684804fc687269f1b929ebf1bc10fbd4f`) を読む。
    ///
    /// 形は「空白 1 つ以上で区切った 2 語 + 末尾の改行」だけ。版は `v` を付けても付けなくても
    /// よく、数字で始まり `[0-9A-Za-z.+_-]` だけ。SHA は 16 進の 7〜40 文字。外れたら `nil`。
    static func parseRelease(_ text: String) -> Release? {
        let words = text.split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "\n" || $0 == "\r" })
        guard words.count == 2 else { return nil }
        var version = String(words[0])
        if version.hasPrefix("v") { version.removeFirst() }
        let allowed = Set("0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz.+_-")
        guard version.first?.isNumber == true, version.allSatisfy({ allowed.contains($0) }) else {
            return nil
        }
        let commit = String(words[1])
        guard (7...40).contains(commit.count), commit.allSatisfy({ $0.isHexDigit }) else {
            return nil
        }
        return Release(version: version, commit: String(commit.prefix(7)).lowercased())
    }

    /// Homebrew が置いた版。読めなければ `nil`。
    static func homebrewVersion(in executable: URL) -> String? {
        let parts = executable.standardizedFileURL.pathComponents
        // `Cellar/<名前>/<版>/…` の並び。名前を跨いだ次が版になる
        guard let marker = parts.lastIndex(of: cellarMarker), marker + 2 < parts.count else {
            return nil
        }
        let version = parts[marker + 2]
        // **版の形をしているものだけ受ける。** HEAD ビルドや自分で並べた場所を配布版と
        // 名乗ると、規律 1 が守れない
        guard version.first?.isNumber == true else { return nil }
        return version
    }

    /// いま走っている実行ファイルの在処。
    ///
    /// **argv[0] より前に Bundle が持つ道を見る。** argv[0] は起動する側が自由に書けるので、
    /// 版の判定をそこに委ねると偽れる。
    static func currentExecutable() -> URL? {
        if let path = Bundle.main.executablePath, !path.isEmpty {
            return URL(fileURLWithPath: path)
        }
        guard let first = CommandLine.arguments.first, !first.isEmpty else { return nil }
        return URL(fileURLWithPath: first)
    }

    /// 実行ファイルが最後に書かれた時刻。読めなければ `nil` (投げない)。
    static func fileDate(_ url: URL) -> Date? {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        return attributes?[.modificationDate] as? Date
    }
}
