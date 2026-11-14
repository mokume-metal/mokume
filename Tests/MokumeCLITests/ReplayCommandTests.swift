// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation
import MokumeTestSupport
import Testing
import mokume

@testable import MokumeCLI

/// 記録を流して照らす口 (`replay <記録>`・#3571)。子が流して照らすことは `ReplayPlaybackTests` (MokumeCoreTests) が見る。
@Suite("記録を流す口", .signalStateKept)
struct ReplayCommandTests {
    private static let typedFrom = URL(fileURLWithPath: "/tmp/typed-here", isDirectory: true)

    private func parse(_ arguments: [String]) throws(CommandFailure) -> ReplayCommand.Options {
        try ReplayCommand.parse(arguments, currentDirectory: Self.typedFrom)
    }

    @Test("最初の 1 つが記録で、打った場所から絶対パスに解き、残りは run と同じに解く")
    func theRecordComesFirst() throws {
        let options = try parse(["take.json", "sketch", "-c", "debug"])
        #expect(options.record == "/tmp/typed-here/take.json")
        #expect(options.invocation.configuration == "debug")
        #expect(try parse(["/abs/take.json"]).record == "/abs/take.json")
    }

    @Test("記録が無い・旗が先に来たら、記録を先に打つよう言う。--help はヘルプ")
    func aRecordIsNeeded() {
        for arguments in [[], ["-c", "debug"]] {
            do {
                _ = try parse(arguments)
                Issue.record("通った: \(arguments)")
            } catch {
                guard case .usage(let text) = error else {
                    Issue.record("\(error)")
                    return
                }
                #expect(text.contains("needs a record"), "\(text)")
            }
        }
        #expect(throws: CommandFailure.helpRequested) { try parse(["--help"]) }
        #expect(throws: CommandFailure.helpRequested) { try parse(["take.json", "-h"]) }
    }

    @Test("流す合図は replay の子にだけ渡し、親の環境に在っても落とす")
    func theSignalGoesOnlyToTheReplayChild() {
        let key = StartupReads.replay.key
        #expect(RunCommand.childEnvironment([key: "/tmp/stale.json"])[key] == nil, "親の合図を継いだ")
        #expect(RunCommand.childEnvironment([:], replaying: "/tmp/take.json")[key] == "/tmp/take.json")
    }

    @Test("食い違いは子の終わり方を終了コードにし、報告の場所を名乗る")
    func aDifferenceKeepsTheChildsStatus() {
        let failure = CommandFailure.replayDiffered(report: "/tmp/r.json", ending: .exited(1))
        #expect(failure.exitCode == 1)
        #expect(failure.message.contains("/tmp/r.json"))
        #expect(CommandFailure.replayDiffered(report: "/r", ending: .signalled(15)).exitCode == 143)
        #expect(Command.Verb.named("replay") == .replay)
    }

    @Test("結果のファイルは、子を起こした後に書かれたものだけを今回のものと読む")
    func onlyAFreshReportCounts() throws {
        let directory = try TestScratch.directory("mokume-replay-cli")
        let report = directory.appendingPathComponent("report.json")
        #expect(!ReplayCommand.isFresh(report, since: Date()), "無いファイル")
        try Data("{}".utf8).write(to: report)
        #expect(ReplayCommand.isFresh(report, since: Date().addingTimeInterval(-5)))
        #expect(!ReplayCommand.isFresh(report, since: Date().addingTimeInterval(60)), "前の回の結果")
    }
}
