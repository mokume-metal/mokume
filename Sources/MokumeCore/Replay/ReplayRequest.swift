// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation

/// 実行を頭から終わりまで 1 本の記録にする頼み (`mokume run --record <path>`・[#3570])。
///
/// ## 誰が決めるか
///
/// **道具が決め、環境変数で子へ渡す** (``StartupReads/record``・`MOKUME_RENDER` と同じ形)。作品のコードは
/// 1 行も変えない。値は記録の行き先のファイルの**絶対パス**そのもの — 相対の値は読む側の作業ディレクトリで
/// 別の場所になる (子は作業ディレクトリをスケッチに替えて起こされる)。道具が走らせた場所から解いて渡す。
///
/// ## 行き先は旗が必ず指す
///
/// 既定の行き先は持たない (2026-10-31 の決定)。`watch` は世代ごとに別の行き先を渡す
/// (``generation(of:number:)``)。
///
/// [#3570]: https://github.com/mokume-metal/mokume/issues/3570
package nonisolated struct ReplayRequest: Equatable, Sendable {
    /// 記録の行き先 (ファイル)。**絶対パス。**
    package let destination: URL

    /// 行き先を指して頼む。絶対パスでなければ作れない。
    package init?(destination path: String) {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("/"), trimmed.count > 1 else { return nil }
        self.destination = URL(fileURLWithPath: trimmed)
    }

    /// 環境変数に載せる値。
    package var environmentValue: String { destination.path }

    /// `watch` の世代 `number` (1 から) の行き先。**拡張子の前に `-<番号>` を挟む** (`take.json` → `take-2.json`)。
    /// 拡張子が無ければ末尾に付ける。作り直しは記録の切れ目なので、世代ごとに別のファイルになる。
    package static func generation(of destination: String, number: Int) -> String {
        let url = URL(fileURLWithPath: destination)
        let name = url.deletingPathExtension().lastPathComponent
        let ext = url.pathExtension
        let numbered = ext.isEmpty ? "\(name)-\(number)" : "\(name)-\(number).\(ext)"
        return url.deletingLastPathComponent().appendingPathComponent(numbered).path
    }

    /// 起動の環境から読む。**無ければ `nil`。** 読んだら環境から消す (``ClockHandover/startup(environment:unset:)``
    /// と同じ) — 合図はこのプロセスを起こした道具が渡したもので、このプロセスがさらに起こす子のものではない。
    ///
    /// 在って読めない値 (相対パス・空) は、`nil` を返して理由を 1 度言う。**環境を読むのはここだけ** — 一覧
    /// (``StartupReads``) が読み場所としてこのファイルを名指している。
    static func startup(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        unset: (String) -> Void = { unsetenv($0) },
        say: (String) -> Void = { FileHandle.standardError.write(Data("\($0)\n".utf8)) }
    ) -> ReplayRequest? {
        guard let given = environment[StartupReads.record.key] else { return nil }
        unset(StartupReads.record.key)
        guard let request = ReplayRequest(destination: given) else {
            say(
                "Not recording: \(StartupReads.record.key) is not the absolute path of a file (\(given)). "
                    + "Pass the destination with --record <path> to mokume run or mokume watch")
            return nil
        }
        return request
    }
}
