// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation
import MokumeTestSupport
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
        let root = try TestScratch.directory("mokume-assets")
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

    /// **道具が外した包みは探さない** (#4038)。共有の置き場では、改名する前のパッケージ名の包み (`Aaa_demo`) が
    /// いまの包み (`demo_demo`) より名前の順で先に並び、同じ相対パスの資材を持つ。外さなければ古い包みの資材に解ける
    /// (直す前の `mokume run` で実測した形)。外したら、いまの包みの資材に解ける。
    @Test("外した包みは探さず、名前の順で後ろのいまの包みの資材に解ける", arguments: [false, true])
    func skippedBundlesAreNotSearched(skipping: Bool) throws {
        let root = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let stale = try makeBundle(named: "Aaa_demo.bundle", asset: "assets/logo.txt", in: root)
        let current = try makeBundle(named: "demo_demo.bundle", asset: "assets/logo.txt", in: root)

        let search = ImageFile.search(
            for: "assets/logo.txt", workingDirectory: root.appendingPathComponent("sketch").path,
            neighbourhood: root, resources: nil, skipping: skipping ? ["Aaa_demo.bundle"] : [])
        let found = try AssetLookup.locate(search, path: "assets/logo.txt")
        #expect(found.standardizedFileURL == (skipping ? current : stale).standardizedFileURL)
        #expect(search.places.contains { $0.path.contains("Aaa_demo.bundle") } == !skipping)
    }

    /// 道具が渡す値を読み、環境から消す。`.bundle` で終わらない名前は捨てる。渡されなければ何も外さない。
    @Test("探さない包みの合図を読み、環境から消す")
    func undeclaredBundlesAreTakenFromTheEnvironment() {
        let key = StartupReads.undeclaredBundles.key
        var unset: [String] = []
        let names = UndeclaredBundles.take(
            from: [key: "Aaa_demo.bundle/other_other.bundle//not-a-bundle"], unset: { unset.append($0) })
        #expect(names == ["Aaa_demo.bundle", "other_other.bundle"])
        #expect(unset == [key])

        unset = []
        #expect(UndeclaredBundles.take(from: [:], unset: { unset.append($0) }).isEmpty)
        #expect(unset.isEmpty)

        // 道具の側が組む値は、読む側で同じ集合に戻る。空なら渡さない
        let value = UndeclaredBundles.value(of: ["b.bundle", "a.bundle", "bad/name.bundle"])
        #expect(value == "a.bundle/b.bundle")
        #expect(UndeclaredBundles.names(from: [key: value ?? ""]) == ["a.bundle", "b.bundle"])
        #expect(UndeclaredBundles.value(of: []) == nil)
    }

    /// **本番の探索の口が、道具の合図で外す** (#4038 の反証・指摘 8)。合図を環境に置いた状態から、起点だけを
    /// 差し替えた本番の口 (``ImageFile/search(for:neighbourhood:resources:)``) が、外した包みを探さない。
    /// main で呼ぶ — 合図を控えて消すのは main だけで、ほかの検査の main の外の探索は読むだけである。
    @MainActor
    @Test("本番の探索の口は、道具が環境に置いた合図の包みを探さない")
    func theProductionSearchReadsTheSignal() throws {
        let root = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let gone = "Aaa-\(UUID().uuidString)_demo.bundle"
        _ = try makeBundle(named: gone, asset: "assets/logo.txt", in: root)
        let current = try makeBundle(named: "demo_demo.bundle", asset: "assets/logo.txt", in: root)
        let key = StartupReads.undeclaredBundles.key
        UndeclaredBundles.forgetStartup()
        setenv(key, gone, 1)
        defer {
            unsetenv(key)
            UndeclaredBundles.forgetStartup()
        }

        let search = ImageFile.search(for: "assets/logo.txt", neighbourhood: root, resources: nil)
        #expect(!search.places.contains { $0.path.contains(gone) }, "合図の包みを探した")
        #expect(search.skipped.map(\.bundle) == [gone, gone])
        let found = try AssetLookup.locate(search, path: "assets/logo.txt")
        #expect(found.standardizedFileURL == current.standardizedFileURL)
    }

    /// **外した包みにしか無い資材は、黙って「見つからない」にしない** (#4038 の反証・指摘 2)。外す包みは名前の形から
    /// 決めるので、依存の包みを取り違えて外しうる。そのとき失敗は変えずに、外した包みの名前を挙げて包みごとに
    /// 1 度知らせる。外していない包みで見つかれば何も言わない。
    @Test("外した包みにだけ在る資材は、見つからない失敗のまま、その包みの名前を 1 度知らせる")
    func anAssetOnlyInASkippedBundleIsNamed() throws {
        let root = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let wrongly = "Extra-\(UUID().uuidString)_ExtraLib.bundle"
        _ = try makeBundle(named: wrongly, asset: "assets/only.txt", in: root)
        func locate(_ path: String) throws(AssetFailure) -> URL {
            try AssetLookup.locate(
                ImageFile.search(
                    for: path, workingDirectory: root.appendingPathComponent("sketch").path,
                    neighbourhood: root, resources: nil, skipping: [wrongly]),
                path: path)
        }

        #expect(throws: AssetFailure.self) { try locate("assets/only.txt") }
        let said = UndeclaredBundles.missedSnapshot.message(for: wrongly)
        #expect(said?.contains(wrongly) == true, "外した包みを名乗っていない")
        #expect(said?.contains("assets/only.txt") == true)
        #expect(throws: AssetFailure.self) { try locate("assets/only.txt") }
        #expect(UndeclaredBundles.missedSnapshot.count { $0 == wrongly } == 1)

        // 外した包みにも無い資材では知らせない
        let other = "Other-\(UUID().uuidString)_X.bundle"
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent(other), withIntermediateDirectories: true)
        #expect(throws: AssetFailure.self) {
            try AssetLookup.locate(
                ImageFile.search(
                    for: "assets/none.txt", workingDirectory: root.path, neighbourhood: root, resources: nil,
                    skipping: [other]),
                path: "assets/none.txt")
        }
        #expect(!UndeclaredBundles.missedSnapshot.hasWarned(other))
    }

    @Test("全部の道を指す名前は、そのまま 1 つだけ返る")
    func anAbsolutePathIsUsedAsIs() {
        let searched = ImageFile.candidates(
            for: "/tmp/mark.txt", workingDirectory: "/somewhere",
            neighbourhood: URL(fileURLWithPath: "/elsewhere"), resources: nil)
        #expect(searched.map(\.path) == ["/tmp/mark.txt"])
    }
}
