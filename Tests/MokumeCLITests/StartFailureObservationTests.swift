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

    private static let head =
        "Could not start sketch in /s: it exited with code 1 before drawing its first frame"
    private static let sketchLine = BuildReport.sketchReportedPrefix + "setup() threw: the file is missing"

    @Test("起動できなかったと記録にあれば、観測は応えないとは言わず、理由の最初の行と全文の在処を返す")
    func observeNamesTheReasonTheSketchDidNotStart() throws {
        let (facets, directory) = makeFacets()
        defer { try? FileManager.default.removeItem(at: directory) }
        try putStatus(in: directory, launched: false, reason: Self.head + "\n" + Self.sketchLine)
        let watch = try WatchPlaceLock.claim(under: directory)  // 記録を書いた見張りが今も居る
        defer { watch.release() }

        let outcome = Tools(facets: facets, makeID: { "H" }).call("observe", arguments: [:])
        #expect(outcome.isError)
        #expect(outcome.text.contains(Self.head), "理由の頭を言わない: \(outcome.text)")
        #expect(outcome.text.contains(Self.sketchLine), "子の理由の頭を言わない: \(outcome.text)")
        #expect(outcome.text.contains("build_status"), "全文の在処を指さない: \(outcome.text)")
        #expect(outcome.text.contains(BuildReport.statusRelativePath))
        #expect(!outcome.text.contains("did not answer"), "型どおりの案内に落ちた: \(outcome.text)")
    }

    /// **前の版が残っているかは記録から読めない** (#3172 の `keptPrevious`)。走っていないと断定しない。
    @Test("前の版が残っているかもしれない回に、スケッチが走っていないとは断定しない")
    func doesNotAssertThatNothingRuns() throws {
        let (facets, directory) = makeFacets()
        defer { try? FileManager.default.removeItem(at: directory) }
        try putStatus(in: directory, launched: false, reason: Self.head)
        let watch = try WatchPlaceLock.claim(under: directory)
        defer { watch.release() }

        let text = Tools(facets: facets, makeID: { "H" }).call("observe", arguments: [:]).text
        #expect(!text.contains("is not running"), "走っていないと断定した: \(text)")
        #expect(text.contains("newest version"), "新しい版が起動しなかったと言わない: \(text)")
    }

    /// **子が理由を置けなかった回 (落ちた・実行できない成果物) に、無い言葉を約束しない** (反証 1 回目の指摘 3)。
    @Test("子の理由の無い記録は、子自身の言葉を案内せず、記録の理由と端末だけを言う")
    func doesNotPromiseAnAccountTheSketchNeverGave() throws {
        let (facets, directory) = makeFacets()
        defer { try? FileManager.default.removeItem(at: directory) }
        let crashed = "Could not start sketch in /s: it crashed (signal 5) before drawing its first frame"
        try putStatus(in: directory, launched: false, reason: crashed)
        let watch = try WatchPlaceLock.claim(under: directory)
        defer { watch.release() }

        let text = Tools(facets: facets, makeID: { "H" }).call("observe", arguments: [:]).text
        #expect(text.contains(crashed), "記録の理由を言わない: \(text)")
        #expect(!text.contains("own account"), "無い言葉を約束した: \(text)")
        #expect(!text.contains("did not answer"), "型どおりの案内に落ちた: \(text)")
        #expect(text.contains("terminal"), "端末を指さない: \(text)")
    }

    /// **終われと言われて起こさなかった回は、起動の失敗ではない** (反証 1 回目の指摘 3)。「save すれば
    /// 作り直す」とも言えないので、元の案内へ落とす。
    @Test("終われと言われて起こさなかった記録は、起動の失敗として答えない")
    func aStopRequestedRecordIsNotAStartFailure() throws {
        let (facets, directory) = makeFacets()
        defer { try? FileManager.default.removeItem(at: directory) }
        try putStatus(in: directory, launched: false, reason: BuildReport.stopRequestedNotice)
        let watch = try WatchPlaceLock.claim(under: directory)
        defer { watch.release() }

        let text = Tools(facets: facets, makeID: { "H" }).call("observe", arguments: [:]).text
        #expect(text.contains("did not answer"), "\(text)")
    }

    /// **記録は見張りが終わっても残る** (反証 1 回目の指摘 1)。見張りを止めた後に手で起こし直した作品が
    /// 応えないとき、止まる前の記録で「見張りが作り直す」と答えず、既存の案内 (区画が無かったなら起動し直す・
    /// #227) が先に答える。
    @Test("見張りが居なければ、残った記録より先に、区画が無かったときの起動し直しの案内が答える")
    func aLeftoverRecordDoesNotHideTheExistingGuidance() throws {
        let (facets, directory) = makeFacets()
        defer { try? FileManager.default.removeItem(at: directory) }
        try putStatus(in: directory, launched: false, reason: Self.head + "\n" + Self.sketchLine)
        // 見張りは居ない。窓口の区画 (observe) も、この呼び出しが作る (existed == false)
        #expect(!FileManager.default.fileExists(atPath: facets.observeFacet.path))

        let text = Tools(facets: facets, makeID: { "H" }).call("observe", arguments: [:]).text
        #expect(text.contains("launched without"), "起動し直しの案内が先に答えない: \(text)")
        #expect(text.contains("this call created it"), "\(text)")
        #expect(!text.contains("newest version"), "止まった見張りが作り直すと答えた: \(text)")
    }

    /// **次の作り直しが通って起こせば、前の子の失敗は出なくなる。** 見張りは記録を起動した回に書き換える。
    @Test("次の作り直しで起動した回の記録になれば、観測は型どおりの案内に戻る")
    func theReasonGoesAwayOnceTheNextSketchStarted() throws {
        let (facets, directory) = makeFacets()
        defer { try? FileManager.default.removeItem(at: directory) }
        try putStatus(in: directory, launched: true, reason: nil)
        let watch = try WatchPlaceLock.claim(under: directory)
        defer { watch.release() }

        let outcome = Tools(facets: facets, makeID: { "H" }).call("observe", arguments: [:])
        #expect(outcome.isError)
        #expect(outcome.text.contains("did not answer"), "型どおりの案内に戻らない: \(outcome.text)")
        #expect(!outcome.text.contains("newest version"), "\(outcome.text)")
    }

    @Test("作り直しが通らなかった記録は、起動できなかった理由として答えない")
    func aFailedBuildIsNotAStartFailure() throws {
        let (facets, directory) = makeFacets()
        defer { try? FileManager.default.removeItem(at: directory) }
        try putStatus(in: directory, launched: false, reason: nil, ok: false)
        let watch = try WatchPlaceLock.claim(under: directory)
        defer { watch.release() }

        let outcome = Tools(facets: facets, makeID: { "H" }).call("observe", arguments: [:])
        #expect(outcome.text.contains("did not answer"), "\(outcome.text)")
    }

    // MARK: - 子が自分で渡す理由 (WorkDirectory)

    @Test("起動できなかった子は、見張りに起こされ、区画 build が在れば自分の pid で理由の全文を置く")
    func aChildHandsOverItsReasonThroughTheBuildFacet() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("mokume-start-note-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let facet = WorkDirectory.facet(WorkDirectory.buildFacetName, under: base)

        // 見張りが区画を作っていない場所では、置かない (区画の有無は「効かせる」印になりうる)
        WorkDirectory.noteStartFailure("boom\ndetail", forProcess: 4242, under: base, owner: "mokume watch")
        #expect(!FileManager.default.fileExists(atPath: facet.path), "区画を生やした")

        try FileManager.default.createDirectory(at: facet, withIntermediateDirectories: true)
        WorkDirectory.noteStartFailure("boom\ndetail", forProcess: 4242, under: base, owner: "mokume watch")
        let url = WorkDirectory.startFailureURL(forProcess: 4242, under: facet)
        #expect(try String(contentsOf: url, encoding: .utf8) == "boom\ndetail")
        #expect(
            WorkDirectory.startFailureURL(forProcess: 4243, under: facet) != url,
            "pid が名前に入っていない")
    }

    /// **見張りの外の実行は置かない** (反証 1 回目の指摘 5)。`mokume run`・`render`・手で起こした子が、前の
    /// 見張りの残した区画に、誰も掃かないファイルを置き続けない。
    @Test("見張りに起こされていない子は、区画 build が在っても理由を置かない")
    func aChildNotStartedByTheWatcherLeavesNothing() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("mokume-start-note-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let facet = WorkDirectory.facet(WorkDirectory.buildFacetName, under: base)
        try FileManager.default.createDirectory(at: facet, withIntermediateDirectories: true)

        WorkDirectory.noteStartFailure("boom", forProcess: 4242, under: base, owner: nil)
        let left = try FileManager.default.contentsOfDirectory(atPath: facet.path)
        #expect(left.isEmpty, "見張りに起こされていない子が置いた: \(left)")
    }
}
