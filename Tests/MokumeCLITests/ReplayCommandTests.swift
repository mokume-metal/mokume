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

    /// 子の代わり。結果を書くか・どう終わるかを決めて、`launch` に差す。
    private func child(writing report: URL?, ending: CommandFailure?) -> (URL, URL, [String: String]) throws(
        CommandFailure
    ) -> Void {
        { _, _, environment throws(CommandFailure) in
            #expect(environment[StartupReads.replay.key] == "/tmp/take.json")
            if let report { try? Data(#"{"matched":false}"#.utf8).write(to: report) }
            if let ending { throw ending }
        }
    }

    private func replay(report: URL, child: (URL, URL, [String: String]) throws(CommandFailure) -> Void) -> CommandFailure? {
        do {
            try ReplayCommand.replay(
                URL(fileURLWithPath: "/bin/false"), in: Self.typedFrom, record: "/tmp/take.json", report: report,
                launch: child)
            return nil
        } catch {
            return error
        }
    }

    @Test("前の回の結果を消してから子を起こし、子が結果を書かずに 1 で終われば、食い違いでなく子の失敗として名乗る")
    func aStaleReportIsNotThisReplays() throws {
        let directory = try TestScratch.directory("mokume-replay-cli")
        let report = directory.appendingPathComponent("report.json")
        try Data(#"{"matched":true}"#.utf8).write(to: report)
        let failed = replay(report: report, child: child(writing: nil, ending: .sketchExited(status: 1)))
        #expect(failed == .sketchExited(status: 1), "\(String(describing: failed))")
        #expect(!FileManager.default.fileExists(atPath: report.path), "前の回の結果が残った")

        // 0 で終わって結果が無い (合図を読まない古い子)
        try Data(#"{"matched":true}"#.utf8).write(to: report)
        #expect(replay(report: report, child: child(writing: nil, ending: nil)) == .replayReportMissing(path: report.path))
        // 結果を書いて 1 で終わった: 食い違い
        #expect(
            replay(report: report, child: child(writing: report, ending: .sketchExited(status: 1)))
                == .replayDiffered(report: report.path, ending: .exited(1)))
        // 結果を書いて 0 で終わった: 一致
        #expect(replay(report: report, child: child(writing: report, ending: nil)) == nil)
    }

    @Test("記録を読む前・ビルドの前に前の回の結果を消す (流す前に断った回に古い結果を残さない)")
    func aRefusedReplayDoesNotLeaveAStaleReport() throws {
        let directory = try TestScratch.directory("mokume-replay-cli-refused")
        let options = try ReplayCommand.parse(["take.json", directory.path], currentDirectory: directory)
        let report = try ReplayCommand.reportURL(for: options.invocation)
        try FileManager.default.createDirectory(
            at: report.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(#"{"matched":true}"#.utf8).write(to: report)
        // 記録が無い: ビルドの前に断る
        #expect {
            try ReplayCommand.run([directory.appendingPathComponent("take.json").path, directory.path])
        } throws: { error in
            guard case CommandFailure.recordUnreadable = error else { return false }
            return true
        }
        #expect(!FileManager.default.fileExists(atPath: report.path), "前の回の結果が残った")
    }
}
