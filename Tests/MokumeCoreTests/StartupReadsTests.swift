// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation
import Testing

@testable import MokumeCore

/// 起動の瞬間にだけ読むものの一覧 (#380)。GPU は要らない。
///
/// **一覧が実態から漏れていないことを、ここが見る。** 読み手を足した人が一覧に載せ忘れる
/// ことは必ず起きるので、載せ忘れをコードの側から見つけられるようにしてある — 検査は
/// `Sources/` を読み、一覧が名乗る `readSite` と突き合わせる。
///
/// **新しい検査の仕組みは足していない** (ADR-0008 決定 5)。`swift test` は `make ci-check`
/// の中で既に走るので、既存の検査の責務を広げるだけで済む。リポジトリを `#filePath` から
/// 辿る形は `ObservationProtocolTests` ほかに前例がある。
@Suite("起動の瞬間に読むものの一覧")
struct StartupReadsTests {
    /// リポジトリの根 (`Tests/MokumeCoreTests/<この file>` から 3 つ上)。
    static let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()

    /// 一覧を通さずに環境を読んでよい場所と、**その理由**。
    ///
    /// 作法は `scripts/api-surface.py` の `FOREIGN_ALLOWLIST` と同じ — **対象と理由を組で
    /// 書く**。1 行足すたびに判断が入るのが狙いで、書けるのは「起動の瞬間に決まるものでは
    /// ない」と言い切れる理由に限る。
    static let environmentAllowlist = [
        "Sources/MokumeCLI/MCP/MCPServer.swift":
            "既定引数。読んだ環境はそのまま WorkDirectory.given(environment:) へ渡すので、"
            + "規則そのものは一覧を通っている",
        "Sources/MokumeCLI/WatchSession.swift":
            "子プロセスへ渡す環境の複製。読むのではなく運ぶ",
        "Sources/MokumeCLI/BundleCommand.swift":
            "束ねるときに読む署名の名前。決まるのは配るものを組む瞬間で、走らせた"
            + "スケッチの起動とは関係が無い — 一覧に載せると走らせる側の話に混ざる",
    ]

    /// 起動の瞬間に読んでいる疑いのある書き方と、それを名乗る言い方。
    static let signatures = [
        (mark: "ProcessInfo.processInfo.environment", what: "起動の瞬間に環境を読んでいる"),
        (mark: "static func makeIfEnabled", what: "区画があるときだけ作る読み手を持っている"),
    ]

    /// `Sources/` の Swift ファイルを、リポジトリからの相対パスで返す。
    static func sources() -> [String] {
        let directory = root.appendingPathComponent("Sources", isDirectory: true)
        guard let found = FileManager.default.enumerator(atPath: directory.path) else { return [] }
        return found.compactMap { $0 as? String }
            .filter { $0.hasSuffix(".swift") }
            .map { "Sources/\($0)" }
            .sorted()
    }

    static func text(of path: String) throws -> String {
        try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
    }

    /// その書き方が現れるファイル。
    static func sources(containing mark: String) throws -> [String] {
        try sources().filter { try text(of: $0).contains(mark) }
    }

    static var readSites: Set<String> { Set(StartupReads.all.map(\.readSite)) }

    @Test("一覧が名乗る読み場所は、実在して一覧を参照している")
    func readSitesGoThroughTheList() throws {
        for entry in StartupReads.all {
            let body = try Self.text(of: entry.readSite)
            // 迂回が残らないこと — 綴りを書き写した読み手は一覧を参照しない
            #expect(
                body.contains("StartupReads."),
                "\(entry.readSite) が StartupReads を参照していない (一覧を通らずに読んでいる)")
        }
    }

    @Test("起動時に環境を読む場所は、一覧か理由つきの許可にしかない")
    func everyEnvironmentReadIsAccountedFor() throws {
        let allowed = Self.readSites.union(Self.environmentAllowlist.keys)
        for path in try Self.sources(containing: Self.signatures[0].mark) {
            #expect(
                allowed.contains(path),
                """
                \(path) が\(Self.signatures[0].what)が、StartupReads の一覧に無い。
                一覧へ足すか、起動の瞬間に決まるものではない理由を environmentAllowlist に書く
                """)
        }
    }

    @Test("区画があるときだけ作る読み手は、一覧の読み場所にしかない")
    func everyFacetGateIsAccountedFor() throws {
        for path in try Self.sources(containing: Self.signatures[1].mark) {
            #expect(
                Self.readSites.contains(path),
                "\(path) が\(Self.signatures[1].what)が、StartupReads の一覧に無い")
        }
    }

    @Test("一覧と許可に、実体を失った行が残っていない")
    func neitherListNorAllowlistHasGhosts() throws {
        let sources = Set(Self.sources())
        for entry in StartupReads.all {
            #expect(sources.contains(entry.readSite), "一覧が指す \(entry.readSite) が無い")
        }
        for (path, reason) in Self.environmentAllowlist {
            #expect(sources.contains(path), "許可に載る \(path) が無い (\(reason))")
        }
    }

    @Test("鍵は一覧が正典で、読み手はそこから取っている")
    func readersTakeTheirKeyFromTheList() {
        #expect(WorkDirectory.environmentKey == StartupReads.workDirectory.key)
        #expect(SourceStamp.environmentKey == StartupReads.sourceStamp.key)
        // 同じ鍵が 2 度並んでいたら、どちらが正典か決まらない
        #expect(Set(StartupReads.all.map(\.key)).count == StartupReads.all.count)
    }
}
