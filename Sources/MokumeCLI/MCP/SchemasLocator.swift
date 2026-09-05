// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation

/// 面の仕様 (`Schemas/`) の在処。
///
/// **手元にあるものを読む。** どこかのブランチの最新ではなく、いま繋がっている
/// スケッチと同じ出所のものを返す — 版がずれた仕様を渡すと、それに合わせて書いた
/// 呼び出しが動かない。
///
/// 探すのは **依存 → 道具**の順。面は走っているスケッチとの取り決めなので、道具の版と
/// スケッチが依存する版がずれていたら、**依存側が正しい**。
enum SchemasLocator {
    /// 依存として引かれたときの package の名前。
    ///
    /// **完全一致で選ぶ。** 前方一致にすると名前の似た依存を取り違える。見るのが identity
    /// ではなく name なのは、**パスで指すと identity が末尾のディレクトリ名になる**ため
    /// (作業用の複製を指していれば worktree の名前になる)。
    static let packageName = "mokume"

    /// 仕様の置き場。見つからなければ `nil`。
    static func directory(
        workDirectory: URL,
        executable: URL = URL(fileURLWithPath: CommandLine.arguments.first ?? "")
    ) -> URL? {
        candidates(workDirectory: workDirectory, executable: executable)
            .first { DirectoryPresence.exists($0) }
    }

    /// 探す場所。**見つからなかったときに並べて返す** — 窓口の失敗は、次の一手を含む形にする。
    static func candidates(
        workDirectory: URL,
        executable: URL = URL(fileURLWithPath: CommandLine.arguments.first ?? "")
    ) -> [URL] {
        var candidates: [URL] = []
        // 依存として引かれているとき: 解決された実体の中
        if let package = resolvedPackage(workDirectory: workDirectory) {
            candidates.append(package.appendingPathComponent("Schemas", isDirectory: true))
        }
        // このリポジトリの中で走らせたとき: .build/debug/mokume-cli → リポジトリ直下
        var directory = executable.resolvingSymlinksInPath().standardizedFileURL
            .deletingLastPathComponent()
        for _ in 0..<5 {
            candidates.append(directory.appendingPathComponent("Schemas", isDirectory: true))
            directory = directory.deletingLastPathComponent()
        }
        return candidates
    }

    /// 依存として解決された mokume の実体。
    ///
    /// 正本は SwiftPM が作業ディレクトリへ残す `.build/workspace-state.json` で、引き方は
    /// 依存の種類で変わる — パスで指したものは絶対パスがそのまま載り、取ってきたものは
    /// `.build/checkouts/` の下に置かれる。
    static func resolvedPackage(workDirectory: URL) -> URL? {
        let url = workDirectory.appendingPathComponent(".build/workspace-state.json")
        guard let data = try? Data(contentsOf: url),
            let document = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let dependencies = (document["object"] as? [String: Any])?["dependencies"]
                as? [[String: Any]]
        else { return nil }

        for dependency in dependencies {
            let reference = dependency["packageRef"] as? [String: Any]
            guard reference?["name"] as? String == packageName else { continue }
            let state = dependency["state"] as? [String: Any]
            if state?["name"] as? String == "fileSystem", let path = state?["path"] as? String {
                return URL(fileURLWithPath: path, isDirectory: true)
            }
            guard let subpath = dependency["subpath"] as? String else { return nil }
            return workDirectory.appendingPathComponent(
                ".build/checkouts/\(subpath)", isDirectory: true)
        }
        return nil
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
