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
///
/// ## 宣言は道具立てが解いたものを読む
///
/// `Package.swift` の文字列を照らす形は採らない ([#3984](https://github.com/mokume-metal/mokume/issues/3984))。
/// 道具立てが受け付ける `.copy("./assets")` を宣言漏れとして拒み、別の target やコメントの
/// `resources: [.copy("assets")]` で通してしまう。`dump-package` が解いた target ごとの資材の
/// パスを読む。**同じ実行の後の段も宣言を読むので、読みは ``RunCommand/declaration(in:running:)``
/// の控えを分け持つ** — 同じ `Package.swift` に `dump-package` を 2 度起こさない。
nonisolated enum ResourceDeclaration {
    /// 資材の置き場としてこの名前を見る。
    static let directoryName = "assets"

    /// 宣言されていない置き場があれば投げる。
    ///
    /// **宣言が読めない回は止めない。** 道具立てが読めない `Package.swift` は、後の段 (`bundle` は
    /// 宣言を読む段・`run` などはビルド) が道具立ての理由を添えて止める。ここで「宣言が無い」と
    /// 名乗ると、本当の理由 (宣言が壊れている) を隠す。
    static func check(in root: URL) throws(CommandFailure) {
        let package = root.appendingPathComponent("Package.swift")
        guard FileManager.default.fileExists(atPath: package.path),
            let declared = try? RunCommand.dumpPackage(in: root)
        else { return }
        for directory in undeclared(in: root, declared: declared) {
            throw .resourcesNotDeclared(directory: directory)
        }
    }

    /// 中身を持つのに、置き場を持つ target が宣言していない置き場 (リポジトリからの相対)。
    ///
    /// **見るのは置き場を持つ target の宣言だけ** — 別の target の宣言では、その資材は束に
    /// 入らない。置き場 (`Sources/<名前>`) を持つ target が宣言に無ければ見ない: ビルドに入らない
    /// ディレクトリで、資材を宣言しても届かない。読み違えて誤って止めるほうが害が大きい。
    static func undeclared(in root: URL, declared: SwiftPM.Package) -> [String] {
        let sources = root.appendingPathComponent("Sources", isDirectory: true)
        guard
            let places = try? FileManager.default.contentsOfDirectory(
                at: sources, includingPropertiesForKeys: [.isDirectoryKey])
        else { return [] }

        var found: [String] = []
        for place in places.sorted(by: { $0.path < $1.path }) {
            let assets = place.appendingPathComponent(directoryName, isDirectory: true)
            guard hasContents(assets),
                let target = declared.target(placedAt: place, in: root),
                !declares(target)
            else { continue }
            found.append("Sources/\(place.lastPathComponent)/\(directoryName)")
        }
        return found
    }

    /// target が置き場 (またはその中) を資材として挙げているか。綴り (`./assets`・`assets/`) は
    /// 道具立てが揃えたものを、さらに揃えて見る。
    private static func declares(_ target: SwiftPM.Target) -> Bool {
        target.resources.contains { resource in
            guard let path = SwiftPM.Package.normalized(resource.path) else { return false }
            return path == directoryName || path.hasPrefix("\(directoryName)/")
        }
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
}
