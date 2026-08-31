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
enum ToolVersion {
    /// 版が読める在処の目印。
    static let cellarMarker = "Cellar"

    /// いまの道具の名乗り 1 行。
    static func describe() -> String {
        let executable = currentExecutable()
        return describe(executable: executable, modified: executable.flatMap(fileDate))
    }

    /// 在処と日時から名乗りを組む。
    ///
    /// **判定はここだけが持つ。** 引数で受けるのは、検査が在処を差し替えられるように
    /// するため (`Command.invokedName` と同じ流儀)。
    static func describe(executable: URL?, modified: Date?) -> String {
        guard let executable else { return DoctorCommand.unknown }
        if let version = homebrewVersion(in: executable) { return "\(version) (Homebrew)" }
        return "手元ビルド (\(modified.map(format) ?? DoctorCommand.unknown))"
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

    /// 日時の書式。**分までにする** — 秒は読み手の判断を変えない。
    static func format(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter.string(from: date)
    }
}
