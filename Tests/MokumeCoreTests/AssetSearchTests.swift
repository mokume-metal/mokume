// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation
import Testing

@testable import MokumeCore

/// 名前から資材を探す並び。
///
/// **束ねて配ったときにしか通らない並びがある。** 包み (`.app`) の中では実行ファイルの
/// 隣が `Contents/MacOS/` になり、資材は `Contents/Resources/` へ入るので、隣だけを
/// 見ていると見つからない。組み上げた並びを手で作って確かめる。
@Suite("資材を探す並び")
struct AssetSearchTests {
    private func makeWorkspace() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("mokume-assets-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    /// 資材を 1 つ持つ包みを置く。
    private func makeBundle(named name: String, asset: String, in root: URL) throws -> URL {
        let bundle = root.appendingPathComponent(name, isDirectory: true)
        let file = bundle.appendingPathComponent(asset)
        try FileManager.default.createDirectory(
            at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "木目".write(to: file, atomically: true, encoding: .utf8)
        return file
    }

    @Test("実行ファイルの隣に並んだ包みの中を見る")
    func bundlesBesideTheExecutableAreSearched() throws {
        let root = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let asset = try makeBundle(named: "demo_demo.bundle", asset: "assets/mark.txt", in: root)

        let searched = ImageFile.candidates(
            for: "assets/mark.txt", workingDirectory: root.path, neighbourhood: root,
            resources: nil)
        #expect(searched.contains { $0.standardizedFileURL == asset.standardizedFileURL })
    }

    @Test("束ねた形では、資源の置き場に並んだ包みの中を見る")
    func bundlesInTheResourcesDirectoryAreSearched() throws {
        let root = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let app = root.appendingPathComponent("Demo.app", isDirectory: true)
        let resources = app.appendingPathComponent("Contents/Resources", isDirectory: true)
        try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
        let asset = try makeBundle(
            named: "demo_demo.bundle", asset: "assets/mark.txt", in: resources)

        // 束ねた形では、実行ファイルの隣は Contents/MacOS で、包みはそこには無い
        let searched = ImageFile.candidates(
            for: "assets/mark.txt", workingDirectory: "/", neighbourhood: app,
            resources: resources)
        #expect(
            searched.contains { $0.standardizedFileURL == asset.standardizedFileURL },
            """
            束ねた中の資材が、探す場所のどこにも入っていない。
            探した場所:
            \(searched.map { "  - \($0.path)" }.joined(separator: "\n"))
            """)
    }

    /// **起点がディレクトリへの symlink でも、その先に並ぶ包みの中を見る** ([#1330])。
    ///
    /// SwiftPM の `.build/release` は `out/Products/Release` への symlink なので、手で
    /// `./.build/release/<名前>` と打つと起点がこの形になる。起点は `Bundle.main.bundleURL`
    /// と同じくディレクトリの URL で渡す。
    ///
    /// **候補は起点の綴りのまま並ぶこと**も見る。symlink を解いて組むと、返す綴りが
    /// 比べる側と割れる ([#1255])。
    ///
    /// [#1330]: https://github.com/mokume-metal/mokume/issues/1330
    /// [#1255]: https://github.com/mokume-metal/mokume/issues/1255
    @Test("起点が symlink でも、その先に並んだ包みの中を起点の綴りのまま見る")
    func bundlesBehindASymlinkedNeighbourhoodAreSearched() throws {
        let root = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: root) }
        // SwiftPM と同じ形 (`release -> out/Products/Release`)
        let real = root.appendingPathComponent("out/Products/Release", isDirectory: true)
        _ = try makeBundle(named: "demo_demo.bundle", asset: "assets/mark.txt", in: real)
        let link = root.appendingPathComponent("release")
        try FileManager.default.createSymbolicLink(
            atPath: link.path, withDestinationPath: "out/Products/Release")
        let neighbourhood = URL(fileURLWithPath: link.path, isDirectory: true)

        let searched = ImageFile.candidates(
            for: "assets/mark.txt", workingDirectory: root.path, neighbourhood: neighbourhood,
            resources: nil)
        // 読む側 (`locate`) と同じく、最初に在るものを取る
        let found = searched.first { FileManager.default.fileExists(atPath: $0.path) }
        #expect(
            found?.path == link.appendingPathComponent("demo_demo.bundle/assets/mark.txt").path,
            """
            symlink の先の包みの中が、起点の綴りのまま最初に見つかっていない。
            探した場所:
            \(searched.map { "  - \($0.path)" }.joined(separator: "\n"))
            """)
    }

    @Test("起点の symlink に行き先が無ければ、包みの候補は足さない")
    func aDanglingNeighbourhoodAddsNoBundleCandidates() throws {
        let root = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: root) }
        // 行き先 (`out/Products/Release`) は作らない
        let link = root.appendingPathComponent("release")
        try FileManager.default.createSymbolicLink(
            atPath: link.path, withDestinationPath: "out/Products/Release")
        let neighbourhood = URL(fileURLWithPath: link.path, isDirectory: true)

        let searched = ImageFile.candidates(
            for: "assets/mark.txt", workingDirectory: root.path, neighbourhood: neighbourhood,
            resources: nil)
        // 作業ディレクトリと隣の 2 つだけで、列挙できなかった置き場から何も足されない
        #expect(
            searched.map(\.path) == [
                root.appendingPathComponent("assets/mark.txt").path,
                link.appendingPathComponent("assets/mark.txt").path,
            ])
    }

    @Test("全部の道を指す名前は、そのまま 1 つだけ返る")
    func anAbsolutePathIsUsedAsIs() {
        let searched = ImageFile.candidates(
            for: "/tmp/mark.txt", workingDirectory: "/somewhere",
            neighbourhood: URL(fileURLWithPath: "/elsewhere"), resources: nil)
        #expect(searched.map(\.path) == ["/tmp/mark.txt"])
    }
}
