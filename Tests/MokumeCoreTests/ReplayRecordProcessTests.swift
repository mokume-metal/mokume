// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation
import MokumeTestSupport
import Testing

@testable import MokumeCore

/// 実プロセスの終わり方 — 終わりの合図で、完成した記録ができる ([#3570])。
///
/// ランタイムを直に回す検査 (``ReplayRecordingRuntimeTests``) は `closePlugins()` を呼んで終える。ここは、窓を開く
/// 実プロセス (ビルド済みの `reference-sketches`) を `MOKUME_RECORD` つきで起こし、`SIGTERM` / `SIGINT` を送って、
/// 合図 → 終わりの経路 → 記録の閉じ、までが 1 本につながっていることを見る。つながっていなければ、窓を閉じる経路は
/// 通っても、道具が子を止める経路 (`mokume run` の中継・見張りの停止) で完成品ができない。
///
/// 窓を持てない環境 (GPU の無い CI) と、実行ファイルが隣に無いときは飛ばす。窓の × の経路は人の手で確かめる。
///
/// [#3570]: https://github.com/mokume-metal/mokume/issues/3570
@Suite(
    "実行の記録: 実プロセスの終わり方",
    .serialized,
    .enabled(
        if: RenderDevice.isAvailable && ReplayRecordProcess.executable != nil,
        "窓を開ける GPU と、ビルド済みの reference-sketches が要る")
)
@MainActor
struct ReplayRecordProcessTests {
    @Test("SIGTERM と SIGINT で止めた実プロセスは、最後に描いた枚まで書いた完成品を行き先に置き、書き途中と錠を残さない", arguments: [SIGTERM, SIGINT])
    func aStopSignalLeavesACompleteRecord(signal: Int32) throws {
        let executable = try #require(ReplayRecordProcess.executable)
        let directory = try TestScratch.directory("mokume-record-process")
        let destination = directory.appendingPathComponent("take.json")

        let process = Process()
        process.executableURL = executable
        process.arguments = ["bricks-and-ball"]
        // つまみの保存 (.mokume/state) をリポジトリへ作らない
        process.currentDirectoryURL = directory
        var environment = ProcessInfo.processInfo.environment.filter { !$0.key.hasPrefix("MOKUME_") }
        environment[StartupReads.record.key] = destination.path
        process.environment = environment
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        defer { if process.isRunning { kill(process.processIdentifier, SIGKILL) } }

        // 書き途中のファイルに最初の束が書かれるまで待つ (60 枚ごとに書き出す)。期限つき
        let started = try ReplayRecordProcess.wait(upTo: .seconds(90)) {
            let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
            return names.contains { name in
                guard ReplayClaim.isPartial(name, of: "take.json") else { return false }
                let size = (try? FileManager.default.attributesOfItem(
                    atPath: directory.appendingPathComponent(name).path)[.size] as? Int) ?? 0
                return size > 0
            }
        }
        #expect(started, "実プロセスが記録を書き始めない")
        #expect(!FileManager.default.fileExists(atPath: destination.path), "終わるまで行き先は作られない")

        kill(process.processIdentifier, signal)
        let exited = try ReplayRecordProcess.wait(upTo: .seconds(60)) { !process.isRunning }
        #expect(exited, "合図で終わらない")
        guard exited else { return }

        let data = try Data(contentsOf: destination)
        let record = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(record["complete"] as? Bool == true)
        #expect(record["window"] as? Bool == true, "窓で回した")
        let steps = try #require(record["steps"] as? [[String: Any]])
        #expect(!steps.isEmpty)
        let last = try #require(record["last"] as? [String: Any], "最後に描いた枚が書かれている")
        #expect(last["frame"] as? Int == steps.last?["frame"] as? Int)
        #expect((last["pixelHash"] as? String)?.count == 64)
        let names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        #expect(!names.contains { ReplayClaim.isPartial($0, of: "take.json") }, ".partial が残った: \(names)")
        #expect(!names.contains("take.json.lock"), "錠が残った: \(names)")
    }
}

/// 実プロセスの検査の道具。
nonisolated enum ReplayRecordProcess {
    private nonisolated final class Anchor {}

    /// この検査の束の隣にある、ビルド済みの `reference-sketches`。無ければ `nil`。
    static let executable: URL? = {
        var candidates = [Bundle(for: Anchor.self).bundleURL.deletingLastPathComponent()]
        candidates += Bundle.allBundles.filter { $0.bundleURL.pathExtension == "xctest" }
            .map { $0.bundleURL.deletingLastPathComponent() }
        for directory in candidates {
            let url = directory.appendingPathComponent("reference-sketches")
            if FileManager.default.isExecutableFile(atPath: url.path) { return url }
        }
        return nil
    }()

    /// 条件が整うまで期限つきで待つ。整ったら `true`、期限が来たら `false`。
    static func wait(upTo limit: Duration, until condition: () -> Bool) throws -> Bool {
        let deadline = ContinuousClock.now + limit
        while ContinuousClock.now < deadline {
            if condition() { return true }
            Thread.sleep(forTimeInterval: 0.2)
        }
        return condition()
    }
}
