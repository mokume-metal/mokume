// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation

/// 外とやりとりするファイルの置き場。
///
/// [ADR-0018] 決定 2 のとおり、**基準の解決はここ 1 箇所**にある。既定はプロセスの
/// 作業ディレクトリだが、環境変数 `MOKUME_WORK_DIR` があればそれを基準にする。
///
/// 作業ディレクトリは起動のされ方で変わり (端末から / アプリケーションとして /
/// ログイン項目から)、変わったことは書き込み失敗としてしか現れない。基準を外から
/// 与えられれば、どんな起動のされ方でも道具が場所を指定できる。
///
/// **プロセス起動時に一度だけ評価する。** 走っている間に基準が動くと、同じ要求が
/// どこへ応答されたのか追えなくなる。
///
/// [ADR-0018]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0018-observation-and-control-surface.md
public enum WorkDirectory {
    /// 環境変数の名前。
    static let environmentKey = "MOKUME_WORK_DIR"

    /// やりとりのファイルを置く親。
    public static let base: URL = resolve(environment: ProcessInfo.processInfo.environment)

    /// `<base>/.mokume`。
    public static var root: URL { base.appendingPathComponent(".mokume", isDirectory: true) }

    /// `<base>/.mokume/<name>`。用途ごとの区画。
    public static func facet(_ name: String) -> URL {
        root.appendingPathComponent(name, isDirectory: true)
    }

    /// 与えられた環境から基準を決める (検査から呼べる形)。
    ///
    /// 相対パスと `~` 始まりは、読み取り側の作業ディレクトリを基準に絶対化する。
    static func resolve(environment: [String: String]) -> URL {
        let current = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
        guard let given = environment[environmentKey], !given.isEmpty else { return current }
        let expanded = NSString(string: given).expandingTildeInPath
        return URL(fileURLWithPath: expanded, isDirectory: true, relativeTo: current).standardizedFileURL
    }
}
