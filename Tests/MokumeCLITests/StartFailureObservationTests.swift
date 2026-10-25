// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation
import Testing
import mokume

@testable import MokumeCLI

/// 起動の段で止まった子の理由が、子が終わった後の `observe` に届くこと
/// ([#3169](https://github.com/mokume-metal/mokume/issues/3169))。
///
/// 理由は子の標準エラーにしか無く、`observe` は型どおりの「応えない」の案内に落ちていた。見張りが
/// 作り直しの記録 (`.mokume/build/status.json`) に起動できなかった回として書くので、窓口はそれを読んで答える。
@Suite("起動できなかった子の後の観測")
struct StartFailureObservationTests {
    private func makeFacets() -> (Facets, URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("mokume-start-failure-\(UUID().uuidString)", isDirectory: true)
        return (Facets(directory: directory, waitLimit: 0.05), directory)
    }

    /// 見張りが書く記録を置く。
    private func putStatus(
        in directory: URL, launched: Bool, reason: String?, ok: Bool = true
    ) throws {
        let url = BuildReport.statusURL(under: directory)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var object: [String: Any] = [
            "schemaVersion": 1, "ok": ok, "status": 0, "output": "Build complete!",
            "configuration": "debug", "launched": launched, "timings": ["buildMs": 1],
        ]
        if let reason { object["notStartedReason"] = reason }
        try JSONSerialization.data(withJSONObject: object).write(to: url)
    }

    @Test("起動できなかったと記録にあれば、観測は応えないとは言わず、理由の最初の行と全文の在処を返す")
    func observeNamesTheReasonTheSketchDidNotStart() throws {
        let (facets, directory) = makeFacets()
        defer { try? FileManager.default.removeItem(at: directory) }
        let head = "Could not start sketch in /s: it exited with code 1 before drawing its first frame"
        let reason = head + "\nsetup() threw: the file is missing"
        try putStatus(in: directory, launched: false, reason: reason)

        let outcome = Tools(facets: facets, makeID: { "H" }).call("observe", arguments: [:])
        #expect(outcome.isError)
        #expect(outcome.text.contains(head), "理由の頭を言わない: \(outcome.text)")
        #expect(outcome.text.contains("setup() threw: the file is missing"), "子の理由の頭を言わない: \(outcome.text)")
        #expect(outcome.text.contains("build_status"), "全文の在処を指さない: \(outcome.text)")
        #expect(outcome.text.contains(BuildReport.statusRelativePath))
        #expect(!outcome.text.contains("did not answer"), "型どおりの案内に落ちた: \(outcome.text)")
    }

    /// **次の作り直しが通って起こせば、前の子の失敗は出なくなる。** 見張りは記録を起動した回に書き換える。
    @Test("次の作り直しで起動した回の記録になれば、観測は型どおりの案内に戻る")
    func theReasonGoesAwayOnceTheNextSketchStarted() throws {
        let (facets, directory) = makeFacets()
        defer { try? FileManager.default.removeItem(at: directory) }
        try putStatus(in: directory, launched: true, reason: nil)

        let outcome = Tools(facets: facets, makeID: { "H" }).call("observe", arguments: [:])
        #expect(outcome.isError)
        #expect(outcome.text.contains("did not answer"), "型どおりの案内に戻らない: \(outcome.text)")
        #expect(!outcome.text.contains("The sketch is not running"), "\(outcome.text)")
    }

    @Test("作り直しが通らなかった記録は、起動できなかった理由として答えない")
    func aFailedBuildIsNotAStartFailure() throws {
        let (facets, directory) = makeFacets()
        defer { try? FileManager.default.removeItem(at: directory) }
        try putStatus(in: directory, launched: false, reason: nil, ok: false)

        let outcome = Tools(facets: facets, makeID: { "H" }).call("observe", arguments: [:])
        #expect(outcome.text.contains("did not answer"), "\(outcome.text)")
    }

    // MARK: - 子が自分で渡す理由 (WorkDirectory)

    @Test("起動できなかった子は、区画 build が在れば自分の pid で理由の全文を置き、無ければ区画を作らない")
    func aChildHandsOverItsReasonThroughTheBuildFacet() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("mokume-start-note-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let facet = WorkDirectory.facet(WorkDirectory.buildFacetName, under: base)

        // 見張りが区画を作っていない場所では、置かない (区画の有無は「効かせる」印になりうる)
        WorkDirectory.noteStartFailure("boom\ndetail", forProcess: 4242, under: base)
        #expect(!FileManager.default.fileExists(atPath: facet.path), "区画を生やした")

        try FileManager.default.createDirectory(at: facet, withIntermediateDirectories: true)
        WorkDirectory.noteStartFailure("boom\ndetail", forProcess: 4242, under: base)
        let url = WorkDirectory.startFailureURL(forProcess: 4242, under: facet)
        #expect(try String(contentsOf: url, encoding: .utf8) == "boom\ndetail")
        #expect(
            WorkDirectory.startFailureURL(forProcess: 4243, under: facet) != url,
            "pid が名前に入っていない")
    }
}
