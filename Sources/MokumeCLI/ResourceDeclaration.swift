// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation

/// 資材の置き場が、パッケージの宣言に書かれているかを見る。
///
/// ## なぜ走らせる前に止めるのか
///
/// 宣言を書かないと**ビルドは静かに通り、実行時に読めないだけ**になる。この形の
/// 不具合は「描画側は正しく動いているのに絵にならない」という現れ方をするので、
/// 実装を疑うと当たりが外れ続ける。
///
/// 直し方は「宣言を忘れられない構造にすること」で、道具で作ったスケッチは最初から
/// 宣言を持っている。それでも人は置き場を増やすので、**走らせる前にここで止める**。
nonisolated enum ResourceDeclaration {
    /// 資材の置き場としてこの名前を見る。
    static let directoryName = "assets"

    /// 宣言されていない置き場があれば投げる。
    static func check(in root: URL) throws(CommandFailure) {
        let package = root.appendingPathComponent("Package.swift")
        guard let manifest = try? String(contentsOf: package, encoding: .utf8) else { return }
        for directory in undeclared(in: root, manifest: manifest) {
            throw .resourcesNotDeclared(directory: directory)
        }
    }

    /// 中身を持つのに宣言されていない置き場 (リポジトリからの相対)。
    ///
    /// 判定は**宣言の有無だけ**を見る。どの target のどの行かまでは読まない —
    /// 宣言の書き方は複数あり、読み違えて誤って止めるほうが害が大きい。
    static func undeclared(in root: URL, manifest: String) -> [String] {
        let sources = root.appendingPathComponent("Sources", isDirectory: true)
        guard
            let targets = try? FileManager.default.contentsOfDirectory(
                at: sources, includingPropertiesForKeys: [.isDirectoryKey])
        else { return [] }

        var found: [String] = []
        for target in targets.sorted(by: { $0.path < $1.path }) {
            let assets = target.appendingPathComponent(directoryName, isDirectory: true)
            guard hasContents(assets) else { continue }
            let relative = "Sources/\(target.lastPathComponent)/\(directoryName)"
            guard !declares(directoryName, in: manifest) else { continue }
            found.append(relative)
        }
        return found
    }

    /// 置き場に中身があるか (隠しファイルは数えない)。
    private static func hasContents(_ directory: URL) -> Bool {
        guard
            let entries = try? FileManager.default.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles])
        else { return false }
        return !entries.isEmpty
    }

    /// 宣言の中で、その名前が資材として挙がっているか。
    static func declares(_ name: String, in manifest: String) -> Bool {
        guard manifest.contains("resources:") else { return false }
        return manifest.contains("\"\(name)\"") || manifest.contains("\"\(name)/")
    }
}
