// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import CryptoKit
import Foundation

/// 監視しているソースの世代。
///
/// **中身から導く。** 時刻や連番で振ると「編集して元に戻した」ときに別の世代を
/// 名乗ってしまい、読み手は反映されていない変更を反映済みと読む。中身から導けば、
/// 変われば必ず変わり、変わらなければ変わらない。
enum SourceStamp {
    /// 数えるファイル。ここに無い変更は作り直しを起こさない。
    static let watchedExtensions: Set<String> = ["swift", "metal"]

    /// いまの世代。読めるファイルが 1 つも無ければ `nil`。
    static func current(for directory: URL) -> String? {
        let files = sources(in: directory)
        guard !files.isEmpty else { return nil }
        var hasher = SHA256()
        for file in files {
            guard let contents = try? Data(contentsOf: file) else { continue }
            // 名前も混ぜる。中身が同じファイルの名前だけが変わった場合も別の世代になる
            hasher.update(data: Data(file.path.utf8))
            hasher.update(data: contents)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined().prefix(12).description
    }

    /// 監視するファイルを集める。
    static func sources(in directory: URL) -> [URL] {
        var found: [URL] = []
        let manifest = directory.appendingPathComponent("Package.swift")
        if FileManager.default.fileExists(atPath: manifest.path) { found.append(manifest) }

        let sources = directory.appendingPathComponent("Sources", isDirectory: true)
        if let walker = FileManager.default.enumerator(
            at: sources, includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles, .skipsPackageDescendants])
        {
            for case let url as URL in walker
            where watchedExtensions.contains(url.pathExtension.lowercased()) {
                found.append(url)
            }
        }
        return found.sorted { $0.path < $1.path }
    }
}
