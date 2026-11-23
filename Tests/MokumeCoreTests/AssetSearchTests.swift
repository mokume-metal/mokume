// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation
import MokumeTestSupport
import Synchronization
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

    /// **探してよい包みにだけ当たる** (#4038)。共有の置き場では、改名する前のパッケージ名の包み (`Aaa_demo`) が
    /// いまの包み (`demo_demo`) より名前の順で先に並び、同じ相対パスの資材を持つ。許す一覧が無ければ古い包みの資材に
    /// 解ける (直す前の `mokume run` で実測した形)。在れば、いまの包みの資材に解ける。
    @Test("許す一覧に無い包みは探さず、名前の順で後ろのいまの包みの資材に解ける", arguments: [false, true])
    func bundlesOutsideTheAllowanceAreNotSearched(allowing: Bool) throws {
        let root = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let stale = try makeBundle(named: "Aaa_demo.bundle", asset: "assets/logo.txt", in: root)
        let current = try makeBundle(named: "demo_demo.bundle", asset: "assets/logo.txt", in: root)
        let allowance = AssetBundles.Allowance(bundles: ["demo_demo.bundle"], packages: ["mokume"])

        let search = ImageFile.search(
            for: "assets/logo.txt", workingDirectory: root.appendingPathComponent("sketch").path,
            neighbourhood: root, resources: nil, allowance: allowing ? allowance : nil)
        let found = try AssetLookup.locate(search, path: "assets/logo.txt")
        #expect(found.standardizedFileURL == (allowing ? current : stale).standardizedFileURL)
        #expect(search.places.contains { $0.path.contains("Aaa_demo.bundle") } == !allowing)
    }

    /// **後から置き場に現れた包みも探さない** (#4038 の 2 回目の反証・指摘 1)。許す一覧は名前から決まるので、
    /// 道具が子を起こした後に別のスケッチや `swift test` が置いた包み (`Aa_other`・`demo_demoTests`) も、名前の順で先に
    /// 来ても探さない。依存の名前で始まる包み (`mokume_MokumeCore`) と、大文字と小文字だけ違う綴りの自分の包みは探す。
    @Test("許す一覧は、後から置き場に現れた包みも探させない")
    func bundlesThatAppearLaterAreNotSearched() throws {
        let root = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let allowance = try #require(
            AssetBundles.Allowance(bundles: ["demo_Demo.bundle"], packages: ["mokume"]))
        let current = try makeBundle(named: "demo_demo.bundle", asset: "assets/logo.txt", in: root)
        _ = try makeBundle(named: "mokume_MokumeCore.bundle", asset: "assets/core.txt", in: root)
        func search(_ path: String) -> AssetLookup.Search {
            ImageFile.search(
                for: path, workingDirectory: root.appendingPathComponent("sketch").path, neighbourhood: root,
                resources: nil, allowance: allowance)
        }
        #expect(try AssetLookup.locate(search("assets/logo.txt"), path: "assets/logo.txt") == current)
        // 子を起こした後に置かれた包み
        _ = try makeBundle(named: "Aa_other.bundle", asset: "assets/logo.txt", in: root)
        _ = try makeBundle(named: "demo_demoTests.bundle", asset: "assets/logo.txt", in: root)
        let later = search("assets/logo.txt")
        #expect(try AssetLookup.locate(later, path: "assets/logo.txt") == current)
        #expect(Set(later.skipped.map(\.bundle)) == ["Aa_other.bundle", "demo_demoTests.bundle"])
        #expect(search("assets/core.txt").places.contains { $0.path.contains("mokume_MokumeCore.bundle") })
    }

    /// 許す一覧の値: 名前そのもの (`.bundle`) と名前の頭 (`_`) を `/` で区切る。**読めない項が 1 つでもあれば
    /// 値ごと読まない** (全部探す) — 読めた項だけで許すと、残りの依存の包みを外しすぎる。
    @Test("許す一覧の値は組んだとおりに読め、読めない項があれば値ごと捨てる")
    func theAllowanceValueRoundTrips() throws {
        let allowance = try #require(
            AssetBundles.Allowance(bundles: ["demo_demo.bundle"], packages: ["mokume", "Extra-Thing.v2"]))
        #expect(allowance.value == "demo_demo.bundle/extra-thing.v2_/mokume_")
        #expect(AssetBundles.Allowance(value: allowance.value) == allowance)
        #expect(allowance.allows("Extra-Thing.v2_ExtraLib.bundle"))
        #expect(allowance.allows("DEMO_demo.bundle"))
        #expect(!allowance.allows("demo_demoTests.bundle"))
        #expect(!allowance.allows("mokumex_Core.bundle"))

        for broken in ["", "/", "demo_demo.bundle/", "demo_demo.bundle//mokume_", "demo_demo.bundle/mokume", "_"] {
            #expect(AssetBundles.Allowance(value: broken) == nil, "\(broken) を読んだ")
        }
        // 組めない名前が 1 つでもあれば組まない
        #expect(AssetBundles.Allowance(bundles: ["a/b.bundle"], packages: ["mokume"]) == nil)
        #expect(AssetBundles.Allowance(bundles: ["demo"], packages: ["mokume"]) == nil)
        #expect(AssetBundles.Allowance(bundles: [], packages: ["a/b"]) == nil)
        #expect(AssetBundles.Allowance(bundles: [], packages: [""]) == nil)
        #expect(AssetBundles.Allowance(bundles: [], packages: []) == nil)
    }

    /// 合図の読み手: main で読んだら環境から消して控え、main の外では読むだけで消さず控えもしない。控えた後に
    /// 環境へ現れた合図は main なら消すが、控えは替えない。**自分の環境を持つ読み手で確かめる** — プロセスの環境に
    /// 許す一覧を置くと、並んで走るほかの検査の資材の探索が包みを外す (#4038 の 2 回目の反証・指摘 5)。
    @Test("合図は main で読んで環境から消し、main の外では読むだけにする")
    func theSignalIsTakenOnMainOnly() {
        let key = StartupReads.assetBundles.key
        let environment = Mutex<[String: String]>([key: "demo_demo.bundle/mokume_"])
        let signal = AssetBundles.Signal(
            environment: { environment.withLock { $0 } },
            unset: { name in environment.withLock { _ = $0.removeValue(forKey: name) } })
        let expected = AssetBundles.Allowance(bundles: ["demo_demo.bundle"], packages: ["mokume"])

        #expect(signal.startup(onMain: false) == expected)
        #expect(environment.withLock { $0[key] } != nil, "main の外で合図を消した")
        #expect(signal.startup(onMain: true) == expected)
        #expect(environment.withLock { $0[key] } == nil, "main で読んだのに環境に残っている")
        #expect(signal.startup(onMain: false) == expected, "控えていない")

        environment.withLock { $0[key] = "other_other.bundle" }
        #expect(signal.startup(onMain: true) == expected, "控えを替えた")
        #expect(environment.withLock { $0[key] } == nil)

        // 渡されていない・読めない値は全部探す
        let none = AssetBundles.Signal(environment: { [key: "bad"] }, unset: { _ in })
        #expect(none.startup(onMain: true) == nil)
    }

    /// **本番の探索の口が、合図の読み手から許す一覧を取る** (#4038 の反証・指摘 8)。起点と読み手だけを差し替えた
    /// 本番の口 (``ImageFile/search(for:neighbourhood:resources:signal:)``) が、一覧に無い包みを探さない。
    @Test("本番の探索の口は、合図の読み手が渡した一覧に無い包みを探さない")
    func theProductionSearchReadsTheSignal() throws {
        let root = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try makeBundle(named: "Aaa_demo.bundle", asset: "assets/logo.txt", in: root)
        let current = try makeBundle(named: "demo_demo.bundle", asset: "assets/logo.txt", in: root)
        let key = StartupReads.assetBundles.key
        let signal = AssetBundles.Signal(environment: { [key: "demo_demo.bundle/mokume_"] }, unset: { _ in })

        let search = ImageFile.search(for: "assets/logo.txt", neighbourhood: root, resources: nil, signal: signal)
        #expect(!search.places.contains { $0.path.contains("Aaa_demo.bundle") }, "一覧に無い包みを探した")
        #expect(search.skipped.map(\.bundle) == ["Aaa_demo.bundle", "Aaa_demo.bundle"])
        let found = try AssetLookup.locate(search, path: "assets/logo.txt")
        #expect(found.standardizedFileURL == current.standardizedFileURL)
    }

    /// **探させなかった包みにしか無い資材は、黙って「見つからない」にしない** (#4038 の反証・指摘 2)。外す包みは
    /// 名前の形から決めるので、依存の包みを取り違えて外しうる。そのとき失敗は変えずに、包みの名前を挙げて包みごとに
    /// 1 度知らせる。外していない包みで見つかれば何も言わない。**同じパスの確かめは 1 度だけ** — 見つからない資材を
    /// 毎フレーム探すスケッチで、外した包みの `stat` を毎フレーム払わない (2 回目の反証・指摘 6)。
    @Test("探させなかった包みにだけ在る資材は、見つからない失敗のまま包みの名前を 1 度知らせ、同じパスは 1 度しか確かめない")
    func anAssetOnlyInASkippedBundleIsNamed() throws {
        let root = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let wrongly = "Extra-\(UUID().uuidString)_ExtraLib.bundle"
        let only = "assets/only-\(UUID().uuidString).txt"
        _ = try makeBundle(named: wrongly, asset: only, in: root)
        let allowance = AssetBundles.Allowance(bundles: ["demo_demo.bundle"], packages: ["mokume"])
        func locate(_ path: String) throws(AssetFailure) -> URL {
            try AssetLookup.locate(
                ImageFile.search(
                    for: path, workingDirectory: root.appendingPathComponent("sketch").path,
                    neighbourhood: root, resources: nil, allowance: allowance),
                path: path)
        }

        #expect(AssetBundles.shouldCheck(only), "まだ確かめていないパスを確かめないと言った")
        // 確かめ済みのパスとして控えたので、外した包みに在っても知らせない (毎フレームの `stat` を払わない)
        #expect(throws: AssetFailure.self) { try locate(only) }
        #expect(!AssetBundles.missedSnapshot.hasWarned(wrongly))

        let fresh = "assets/fresh-\(UUID().uuidString).txt"
        _ = try makeBundle(named: wrongly, asset: fresh, in: root)
        #expect(throws: AssetFailure.self) { try locate(fresh) }
        let said = AssetBundles.missedSnapshot.message(for: wrongly)
        #expect(said?.contains(wrongly) == true, "外した包みを名乗っていない")
        #expect(said?.contains(fresh) == true)
        #expect(!AssetBundles.shouldCheck(fresh), "同じパスを 2 度確かめる")

        // 外した包みにも無い資材では知らせない
        let other = "Other-\(UUID().uuidString)_X.bundle"
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent(other), withIntermediateDirectories: true)
        #expect(throws: AssetFailure.self) { try locate("assets/none-\(UUID().uuidString).txt") }
        #expect(!AssetBundles.missedSnapshot.hasWarned(other))
    }

    @Test("全部の道を指す名前は、そのまま 1 つだけ返る")
    func anAbsolutePathIsUsedAsIs() {
        let searched = ImageFile.candidates(
            for: "/tmp/mark.txt", workingDirectory: "/somewhere",
            neighbourhood: URL(fileURLWithPath: "/elsewhere"), resources: nil)
        #expect(searched.map(\.path) == ["/tmp/mark.txt"])
    }
}
