// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation
import mokume

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
            .first { WorkDirectory.directoryExists(at: $0) }
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
    /// 正本は SwiftPM がビルドの置き場へ残す `workspace-state.json` で、引き方は
    /// 依存の種類で変わる — パスで指したものは絶対パスがそのまま載り、取ってきたものは
    /// 置き場の `checkouts/` の下に置かれる。
    ///
    /// **置き場はパッケージ直下とは限らない。** 版ごとの共有へ移っているスケッチでは
    /// `.build` が 1 つも無いので、ここで `.build` を組み立てていると**黙って空振りし、
    /// 「mokume X はこの面を持たない」という名乗りごと消える** ([ADR-0037])。だから
    /// ``BuildDirectory/plausibleDirectories(for:root:pin:toolchain:)`` が並べる場所を
    /// 順に見る。
    ///
    /// [ADR-0037]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0037-shared-build-directory.md
    static func resolvedPackage(
        workDirectory: URL,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        home: URL = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
    ) -> URL? {
        let directories = BuildDirectory.plausibleDirectories(
            for: workDirectory,
            root: BuildDirectory.root(environment: environment, home: home),
            pin: DependencyVersion.pin(forPackageAt: workDirectory))
        for directory in directories {
            let url = directory.appendingPathComponent("workspace-state.json")
            if let resolved = SwiftPM.read(SwiftPM.WorkspaceState.self, at: url)?
                .resolved(packageName, under: directory)
            {
                return resolved
            }
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
