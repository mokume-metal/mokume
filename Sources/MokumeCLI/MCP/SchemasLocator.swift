// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation

/// 面の仕様 (`Schemas/`) の在処。
///
/// **手元にあるものを読む。** どこかのブランチの最新ではなく、いま繋がっている
/// 道具と同じ出所のものを返す — 版がずれた仕様を渡すと、それに合わせて書いた
/// 呼び出しが動かない。
enum SchemasLocator {
    /// 道具の実行ファイルから見た位置を辿る。
    static func directory(
        executable: URL = URL(fileURLWithPath: CommandLine.arguments.first ?? "")
    ) -> URL? {
        var candidates: [URL] = []
        // 開発中: .build/debug/mokume-cli → リポジトリ直下
        let resolved = executable.resolvingSymlinksInPath().standardizedFileURL
        var directory = resolved.deletingLastPathComponent()
        for _ in 0..<5 {
            candidates.append(directory.appendingPathComponent("Schemas", isDirectory: true))
            directory = directory.deletingLastPathComponent()
        }
        return candidates.first { url in
            var isDirectory: ObjCBool = false
            return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
                && isDirectory.boolValue
        }
    }

    /// 仕様の名前の一覧。
    static func names(in root: URL) -> [String] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
        return names.filter { $0.hasSuffix(".schema.json") }
            .map { String($0.dropLast(".schema.json".count)) }
            .sorted()
    }

    /// 仕様の中身。
    static func contents(of name: String, in root: URL) -> String? {
        let url = root.appendingPathComponent("\(name).schema.json")
        return try? String(contentsOf: url, encoding: .utf8)
    }
}
