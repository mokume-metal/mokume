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
    /// 環境変数の名前。**一覧から取る** — 起動の瞬間に読むものは
    /// ``StartupReads`` が正典で、ここに綴りを書き写さない (#380)。
    static let environmentKey = StartupReads.workDirectory.key

    /// やりとりのファイルを置く親。
    public static let base: URL = resolve(environment: ProcessInfo.processInfo.environment)

    /// 環境変数で**与えられた**基準。与えられていなければ `nil`。
    ///
    /// 道具は自分の既定値 (スケッチのパッケージの場所など) を持っているので、`base` の
    /// 「無ければ作業ディレクトリ」では当てはまらないことがある。**規則はここ 1 箇所に
    /// 置いたまま**、既定値だけを呼ぶ側に選ばせるための口である。
    public static let given: URL? = given(environment: ProcessInfo.processInfo.environment)

    /// `<base>/.mokume`。
    public static var root: URL { root(under: base) }

    /// 与えた基準の下の `.mokume`。
    ///
    /// **基準を外から渡せる形も要る。** 道具は自分の作業ディレクトリではなく、見張って
    /// いるスケッチの側の基準へ置く — 割れると両者は別の区画を見る (#331)。綴りは
    /// ここ 1 箇所に保つ。
    public static func root(under base: URL) -> URL {
        base.appendingPathComponent(".mokume", isDirectory: true)
    }

    /// `<base>/.mokume/<name>`。用途ごとの区画。
    public static func facet(_ name: String) -> URL {
        facet(name, under: base)
    }

    /// 与えた基準の下の区画。
    public static func facet(_ name: String, under base: URL) -> URL {
        root(under: base).appendingPathComponent(name, isDirectory: true)
    }

    /// `<base>/.mokume/state`。ライブラリが自分の続きを置く場所。
    ///
    /// **区画ではない。** 区画は「利用者が作ったときだけ有効」という switch を持つが
    /// ([ADR-0018] 決定 2)、ここに置くものは既定で効く。両者を同じ入れ物に置くと、
    /// 既定で効くものが区画を作った時点で switch が死ぬ。
    ///
    /// [ADR-0018]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0018-observation-and-control-surface.md
    static var state: URL { root.appendingPathComponent("state", isDirectory: true) }

    /// 合わせた値の保存先。
    static var savedParams: URL { state.appendingPathComponent("params.json") }

    /// 与えられた環境から基準を決める (検査から呼べる形)。
    static func resolve(environment: [String: String]) -> URL {
        given(environment: environment)
            ?? URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
    }

    /// 与えられた環境が基準を指定しているか (検査から呼べる形)。
    ///
    /// 相対パスと `~` 始まりは、読み取り側の作業ディレクトリを基準に絶対化する。
    public static func given(environment: [String: String]) -> URL? {
        guard let given = environment[environmentKey], !given.isEmpty else { return nil }
        let current = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
        let expanded = NSString(string: given).expandingTildeInPath
        return URL(fileURLWithPath: expanded, isDirectory: true, relativeTo: current).standardizedFileURL
    }
}
