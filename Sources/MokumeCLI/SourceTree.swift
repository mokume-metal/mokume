// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation

/// `Sources/` の下のソースを、SwiftPM が組む範囲で集める。
///
/// **ディレクトリへのシンボリックリンクの中へも降りる** (#3993)。SwiftPM はリンクしたディレクトリの
/// 中のソースも組むので、降りないと見張りは保存を拾わず、束ねる前の検査は中を読まない。
/// `FileManager.enumerator` はリンクの中へ降りないので使わない。
///
/// **ディレクトリは実体 (`realpath(3)`) ごとに 1 度だけ歩く** — 祖先や互いを指すリンクがあっても
/// 列挙は終わり、同じディレクトリの中身を 2 度挙げない。実体のディレクトリを先に歩き切ってから
/// リンクを辿るので、実体とリンクの両方から着けるディレクトリは実体の側の名前で挙がる。
/// 辿れないリンクは降りない。
///
/// **資材の置き場 (`Sources/<名前>/assets`) そのものと、その中にあるディレクトリへのリンクは
/// 辿らない** — 置き場の中のシンボリックリンクは見張りの範囲の外 (#2519)。置き場の中の実体の
/// ディレクトリは歩く。隠しファイルは見ない。
nonisolated enum SourceTree {
    /// `sources` の下の、拡張子が `extensions` (小文字) のファイル。歩いた順で、並べ替えない。
    ///
    /// ファイルへのリンクは、拡張子が合えば先を辿らずに挙げる (辿れないリンクも挙げ、読めるかは
    /// 読む側が決める)。
    ///
    /// - Parameter descendingIntoPackages: 包みの形をしたディレクトリ (`.bundle` など) の中へも
    ///   降りるか。
    static func files(
        under sources: URL, extensions: Set<String>, descendingIntoPackages: Bool
    ) -> [URL] {
        guard let root = realPath(of: sources) else { return [] }
        var walked: Set<String> = [root]
        var found: [URL] = []
        // 歩く実体のディレクトリと、後で辿るディレクトリへのリンク
        var directories: [Place] = [Place(url: sources, depth: 0, inAssets: false)]
        var links: [Place] = []
        while true {
            if let directory = directories.popLast() {
                for entry in entries(of: directory.url) {
                    let place = directory.child(entry)
                    switch kind(of: entry) {
                    case .file:
                        if extensions.contains(entry.pathExtension.lowercased()) {
                            found.append(entry)
                        }
                    case .directory(let isPackage):
                        guard descendingIntoPackages || !isPackage,
                            let real = realPath(of: entry), walked.insert(real).inserted
                        else { continue }
                        directories.append(place)
                    case .linkToDirectory(let isPackage):
                        guard descendingIntoPackages || !isPackage, !place.inAssets else { continue }
                        links.append(place)
                    }
                }
            } else if !links.isEmpty {
                let link = links.removeFirst()
                guard let real = realPath(of: link.url), walked.insert(real).inserted else {
                    continue
                }
                directories.append(link)
            } else {
                return found
            }
        }
    }

    /// 歩く場所。`depth` は `Sources` からの深さ (`Sources/<名前>` が 1)。
    private struct Place {
        let url: URL
        let depth: Int
        /// 資材の置き場そのものか、その中か。
        let inAssets: Bool

        func child(_ url: URL) -> Place {
            Place(
                url: url, depth: depth + 1,
                inAssets: inAssets
                    || (depth + 1 == 2 && url.lastPathComponent == ResourceDeclaration.directoryName))
        }
    }

    private enum Kind {
        case file
        case directory(isPackage: Bool)
        case linkToDirectory(isPackage: Bool)
    }

    /// 中身 (隠しファイルを除く)。並びを決めるために名前で並べる。
    ///
    /// **名前を `directory` に足して作る** — `contentsOfDirectory(at:)` の返す URL は、リンクを
    /// 辿った先や `/private` を足した形になることがあり、リンクを通った名前を保てない。
    private static func entries(of directory: URL) -> [URL] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        return names.filter { !$0.hasPrefix(".") }.sorted().compactMap { name in
            let entry = directory.appendingPathComponent(name)
            let hidden = (try? entry.resourceValues(forKeys: [.isHiddenKey]))?.isHidden == true
            return hidden ? nil : entry
        }
    }

    /// 項目の種類。リンクは辿った先がディレクトリのときだけ `linkToDirectory` で、それ以外
    /// (ファイルへのリンク・辿れないリンク) はファイルとして扱う。
    private static func kind(of entry: URL) -> Kind {
        let keys: Set<URLResourceKey> = [.isSymbolicLinkKey, .isDirectoryKey, .isPackageKey]
        guard let values = try? entry.resourceValues(forKeys: keys) else { return .file }
        guard values.isSymbolicLink == true else {
            return values.isDirectory == true
                ? .directory(isPackage: values.isPackage == true) : .file
        }
        guard let real = realPath(of: entry),
            let target = try? URL(fileURLWithPath: real).resourceValues(forKeys: keys),
            target.isDirectory == true
        else { return .file }
        return .linkToDirectory(isPackage: target.isPackage == true)
    }

    /// 実体のパス。辿れなければ `nil`。`resolvingSymlinksInPath()` は辿れないリンクをそのまま返し、
    /// 先頭の `/private` を落とすので使わない。
    private static func realPath(of url: URL) -> String? {
        guard let resolved = realpath(url.path, nil) else { return nil }
        defer { free(resolved) }
        return String(cString: resolved)
    }
}
