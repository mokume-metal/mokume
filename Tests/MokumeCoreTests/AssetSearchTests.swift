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

    @Test("全部の道を指す名前は、そのまま 1 つだけ返る")
    func anAbsolutePathIsUsedAsIs() {
        let searched = ImageFile.candidates(
            for: "/tmp/mark.txt", workingDirectory: "/somewhere",
            neighbourhood: URL(fileURLWithPath: "/elsewhere"), resources: nil)
        #expect(searched.map(\.path) == ["/tmp/mark.txt"])
    }
}
