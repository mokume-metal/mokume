// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation

/// `Sources/` の下のソースを、SwiftPM が組む範囲で集める。
///
/// **ディレクトリへのシンボリックリンクの中へも降りる** (#3993)。SwiftPM はリンクしたディレクトリの
/// 中のソースも組むので、降りないと見張りは保存を拾わず、束ねる前の検査は中を読まない。
/// `FileManager.enumerator` はリンクの中へ降りないので使わない。
///
/// **ディレクトリは実体 (装置とファイル番号) ごとに 1 度だけ歩く** — 祖先や互いを指すリンクが
/// あっても列挙は終わり、同じディレクトリの中身を 2 度挙げない。実体のディレクトリを先に歩き
/// 切ってからリンクを辿るので、実体とリンクの両方から着けるディレクトリは実体の側の名前で挙がる。
/// **同じ実体へ着くリンクが複数あれば、名前の順で先に歩いたリンクの名前で挙がる** — リンクを
/// 足す・消す・名前を変えると、中身を保存しなくても挙がる名前が変わりうる。辿れないリンクは降りない。
///
/// **資材の置き場 (`Sources/<名前>/assets`) には降りない** — 置き場の中は見張りの資材の数え方
/// (``SourceStamp/sources(in:)``) が数え、置き場の中のシンボリックリンクは範囲の外 (#2519)。
/// 置き場は名前の綴りでなくファイルとして見る (大文字と小文字を区別しないボリュームの `Assets` も
/// 置き場)。宣言された置き場の中の `.swift` は束へ写されるだけで組まれない。隠しファイルは見ない。
nonisolated enum SourceTree {
    /// `sources` の下の、拡張子が `extensions` (小文字) のファイル。歩いた順で、並べ替えない。
    ///
    /// ファイルへのリンクは、拡張子が合えば先を辿らずに挙げる (辿れないリンクも挙げ、読めるかは
    /// 読む側が決める)。
    ///
    /// - Parameters:
    ///   - descendingIntoPackages: 包みの形をしたディレクトリ (`.bundle` など) の中へも降りるか。
    ///   - shouldContinue: ディレクトリを 1 つ歩くごとに問う。`false` ならそこで止め、それまでに
    ///     挙げたものを返す。
    static func files(
        under sources: URL, extensions: Set<String>, descendingIntoPackages: Bool,
        shouldContinue: () -> Bool = { true }
    ) -> [URL] {
        guard let root = Place(linkAt: sources, depth: 0) else { return [] }
        // 資材の置き場は歩いたものとして始める — 置き場そのものにも、他所から置き場を指すリンクにも
        // 降りない。置き場の名前で引いて実体を取るので、大文字と小文字を区別しないボリュームの
        // `Assets` も置き場になる
        var walked: Set<Identity> = [root.identity]
        for (name, _) in entries(of: root.physical) {
            let place = root.physical.appendingPathComponent(name)
                .appendingPathComponent(ResourceDeclaration.directoryName)
            if let identity = Identity(of: place), identity.isDirectory { walked.insert(identity) }
        }
        var found: [URL] = []
        // 歩く実体のディレクトリと、後で辿るディレクトリへのリンク
        var directories: [Place] = [root]
        var links: [Place] = []
        while shouldContinue() {
            if let directory = directories.popLast() {
                for (name, values) in entries(of: directory.physical) {
                    let entry = directory.url.appendingPathComponent(name)
                    let physical = directory.physical.appendingPathComponent(name)
                    if values.isSymbolicLink == true {
                        guard let link = Place(linkAt: entry, depth: directory.depth + 1) else {
                            // ファイルへのリンク・辿れないリンク
                            if extensions.contains(entry.pathExtension.lowercased()) {
                                found.append(entry)
                            }
                            continue
                        }
                        guard !walked.contains(link.identity),
                            descendingIntoPackages || !isPackage(link.physical)
                        else { continue }
                        links.append(link)
                    } else if values.isDirectory == true {
                        guard descendingIntoPackages || values.isPackage != true,
                            let identity = Identity(of: physical), walked.insert(identity).inserted
                        else { continue }
                        directories.append(
                            Place(
                                url: entry, physical: physical, depth: directory.depth + 1,
                                identity: identity))
                    } else if extensions.contains(entry.pathExtension.lowercased()) {
                        found.append(entry)
                    }
                }
            } else if !links.isEmpty {
                let link = links.removeFirst()
                if walked.insert(link.identity).inserted { directories.append(link) }
            } else {
                break
            }
        }
        return found
    }

    /// 歩くディレクトリ。`url` は挙げる名前 (リンクを通った名前)、`physical` は中身を読む実体の
    /// パス — 終わりの成分がリンクの URL は、`contentsOfDirectory(at:)` が先の中身を返さない。
    private struct Place {
        let url: URL
        let physical: URL
        /// `Sources` からの深さ (`Sources/<名前>` が 1)。
        let depth: Int
        let identity: Identity

        init(url: URL, physical: URL, depth: Int, identity: Identity) {
            self.url = url
            self.physical = physical
            self.depth = depth
            self.identity = identity
        }

        /// リンクかもしれない `url` を辿った先のディレクトリ。辿れない・ディレクトリでなければ `nil`。
        init?(linkAt url: URL, depth: Int) {
            guard let resolved = realpath(url.path, nil) else { return nil }
            defer { free(resolved) }
            let physical = URL(fileURLWithPath: String(cString: resolved), isDirectory: true)
            guard let identity = Identity(of: physical), identity.isDirectory else { return nil }
            self.init(url: url, physical: physical, depth: depth, identity: identity)
        }
    }

    /// ディレクトリの実体。`stat(2)` はリンクを辿る。
    private struct Identity: Hashable {
        let device: dev_t
        let number: ino_t
        let isDirectory: Bool

        init?(of url: URL) {
            var info = stat()
            guard stat(url.path, &info) == 0 else { return nil }
            device = info.st_dev
            number = info.st_ino
            isDirectory = (info.st_mode & S_IFMT) == S_IFDIR
        }
    }

    private static let keys: Set<URLResourceKey> = [
        .isSymbolicLinkKey, .isDirectoryKey, .isPackageKey,
    ]

    /// 中身 (隠しファイルを除く) の名前と属性。並びを決めるために名前で並べる。
    ///
    /// 属性は列挙と一緒に読む。返すのは名前だけで、URL は呼ぶ側が作る — `contentsOfDirectory(at:)`
    /// の返す URL は `/private` を足した形などになることがあり、リンクを通った名前を保てない。
    private static func entries(of directory: URL) -> [(String, URLResourceValues)] {
        let listed =
            (try? FileManager.default.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: Array(keys),
                options: [.skipsHiddenFiles])) ?? []
        return listed.compactMap { url -> (String, URLResourceValues)? in
            guard let values = try? url.resourceValues(forKeys: keys) else { return nil }
            return (url.lastPathComponent, values)
        }
        .sorted { $0.0 < $1.0 }
    }

    /// 実体のディレクトリが包みか。
    private static func isPackage(_ physical: URL) -> Bool {
        (try? physical.resourceValues(forKeys: [.isPackageKey]))?.isPackage == true
    }
}
