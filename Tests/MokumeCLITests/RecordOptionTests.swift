// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation
import MokumeTestSupport
import Synchronization
import Testing

@testable import MokumeCLI
@testable import MokumeCore

/// `mokume run --record <path>` と `mokume watch --record <path>` — 実行を頭から終わりまで 1 本の記録にする旗 ([#3570])。
///
/// 記録そのもの (入力・つまみ・観測・開始の状態) は `ReplayRecordTests` が見る。ここが見るのは**道具の側**:
/// 旗が値を必ず取ること (既定の行き先を持たない)、`run` と `watch` だけが受けること、行き先を走らせた場所から
/// 絶対パスにして子の環境に載せること (渡さなければ親の環境からも落とす)、`watch` は世代ごとに別の行き先を渡すこと。
///
/// [#3570]: https://github.com/mokume-metal/mokume/issues/3570
@Suite("run / watch --record")
struct RecordOptionTests {
    private let base = URL(fileURLWithPath: "/work/here", isDirectory: true)

    private func destination(
        _ arguments: [String], adding extra: [Arguments.Option] = RecordOption.options
    ) throws -> String? {
        let (invocation, values) = try Invocation.parse(arguments, adding: extra, from: base)
        return try RecordOption.destination(in: values, from: invocation.currentDirectory)
    }

    private func failure(_ body: () throws -> Void) -> String? {
        do {
            try body()
            return nil
        } catch let failure as CommandFailure {
            if case .usage(let text) = failure { return text }
            return "\(failure)"
        } catch {
            return "\(error)"
        }
    }

    // MARK: - 旗

    @Test("旗は値を必ず取り、相対の行き先は走らせた場所から絶対パスにする。位置引数と紛れない")
    func theFlagTakesTheDestination() throws {
        #expect(try destination(["--record", "out/take.json", "sketch-dir"]) == "/work/here/out/take.json")
        #expect(try destination(["sketch-dir", "--record", "/tmp/take.json"]) == "/tmp/take.json")
        #expect(try destination(["sketch-dir"]) == nil, "既定の行き先は持たない — 旗が無ければ記録しない")
        let (invocation, _) = try Invocation.parse(
            ["--record", "take.json", "sketch-dir"], adding: RecordOption.options, from: base)
        #expect(invocation.place == "sketch-dir", "旗の値は場所に食われず、場所は旗の値に食われない")
    }

    @Test("値が無い・空・フォルダの行き先は、ビルドの前に断る")
    func aBadDestinationIsRefused() throws {
        let missing = failure { _ = try destination(["--record"]) }
        #expect(missing?.contains("--record needs somewhere to write the record") == true, "\(missing ?? "nil")")
        let empty = failure { _ = try destination(["--record", ""]) }
        #expect(empty?.contains("--record is empty") == true, "\(empty ?? "nil")")
        let slash = failure { _ = try destination(["--record", "out/"]) }
        #expect(slash?.contains("not a directory") == true, "\(slash ?? "nil")")

        let directory = try TestScratch.directory("mokume-record-option")
        let existing = failure { _ = try destination(["--record", directory.path]) }
        #expect(existing?.contains("is a directory") == true, "\(existing ?? "nil")")
    }

    @Test("render は知らない選択肢として断る。run と watch は受ける")
    func onlyRunAndWatchAcceptIt() throws {
        let refused = failure {
            _ = try RenderCommand.parse(
                ["--fps", "60", "--seconds", "1", "--out", "x.mov", "--record", "take.json"],
                currentDirectory: base)
        }
        #expect(refused?.contains("Unknown option: --record") == true, "\(refused ?? "nil")")
        // run は `Invocation.parse(adding:)` に RecordOption を足して受ける。watch は自分の選択肢に足してある
        let (_, watchValues) = try Invocation.parse(
            ["--record", "take.json", "--keep-time"], adding: WatchCommand.options, from: base)
        #expect(watchValues[RecordOption.flags[0]] == "take.json")
        #expect(watchValues[WatchCommand.keepTimeFlag] != nil)
        // 旗は値を取るので、doctor が値を場所に取り違えない
        #expect(Command.valueOptions.contains { $0.flags == RecordOption.flags })
    }

    // MARK: - 子へ渡す

    @Test("行き先は子の環境に載り、渡さなければ親の環境に在っても落とす (render の子にも継がせない)")
    func theChildGetsItOnlyWhenAsked() throws {
        let key = StartupReads.record.key
        #expect(RunCommand.childEnvironment([:])[key] == nil)
        #expect(RunCommand.childEnvironment([key: "/tmp/stale.json"])[key] == nil, "親の合図を継いだ")
        #expect(RunCommand.childEnvironment([:], recording: "/tmp/take.json")[key] == "/tmp/take.json")
        let request = try #require(
            RenderRequest(frameRate: 24, frameCount: 1, destination: "/tmp/mokume-never-written.mov"))
        #expect(
            RunCommand.childEnvironment([key: "/tmp/stale.json"], rendering: request)[key] == nil,
            "render の子へ継がせない")
        // 子が読む値の形と同じ型で読み戻せる
        let carried = RunCommand.childEnvironment([:], recording: "/tmp/take.json")[key]
        #expect(ReplayRequest(destination: carried ?? "")?.destination.path == "/tmp/take.json")
    }

    @Test("watch は子を起こすたびに別の世代の行き先を渡す")
    func watchGivesEachGenerationItsOwnFile() {
        let generations = RecordGenerations(destination: "/tmp/out/take.json")
        #expect(generations.next() == "/tmp/out/take-1.json")
        #expect(generations.next() == "/tmp/out/take-2.json")
        #expect(generations.next() == "/tmp/out/take-3.json")
        // 別の見張りは別の数え
        #expect(RecordGenerations(destination: "/tmp/out/take.json").next() == "/tmp/out/take-1.json")
    }

    @Test("watch の世代の名前に記録でないものが在れば、触らずに番号を飛ばし、飛ばしたことを 1 度言う (#3970)")
    func watchSkipsGenerationNamesTakenByOtherFiles() throws {
        let manager = FileManager.default
        let directory = try TestScratch.directory("mokume-record-generations")
        let base = directory.appendingPathComponent("take.json").path
        let first = directory.appendingPathComponent("take-1.json")
        let second = directory.appendingPathComponent("take-2.json")
        try Data("{\"theme\":\"dark\"}".utf8).write(to: first)
        try Data("my notes".utf8).write(to: second)

        // 見張りの始まりの掃除は、記録でないファイルに触らない
        #expect(ReplayRequest.discardGenerations(of: base).isEmpty)
        let said = Mutex<[String]>([])
        let generations = RecordGenerations(destination: base) { line in said.withLock { $0.append(line) } }
        let third = generations.next()
        #expect(third == directory.appendingPathComponent("take-3.json").path)
        #expect(said.withLock { $0.count } == 1, "飛ばしたことは 1 度だけ言う: \(said.withLock { $0 })")
        let notice = said.withLock { $0.first } ?? ""
        #expect(notice.contains("take-1.json") && notice.contains("take-2.json") && notice.contains(third))

        // 以降の保存も同じ規則: 記録でないもの (フォルダ・リンク) の番号は飛ばし、記録の残りは使う
        try manager.createDirectory(
            at: directory.appendingPathComponent("take-4.json"), withIntermediateDirectories: false)
        // リンクは指す先が記録でも飛ばす (子が置き換えるとリンクが外れる)
        let elsewhere = directory.appendingPathComponent("elsewhere.json")
        try Data("{\"schemaVersion\":1}".utf8).write(to: elsewhere)
        try manager.createSymbolicLink(
            atPath: directory.appendingPathComponent("take-5.json").path, withDestinationPath: elsewhere.path)
        #expect(generations.next() == directory.appendingPathComponent("take-6.json").path)
        #expect(said.withLock { $0.count } == 2)
        try Data("{\"schemaVersion\":1}".utf8).write(to: directory.appendingPathComponent("take-7.json"))
        #expect(generations.next() == directory.appendingPathComponent("take-7.json").path)
        #expect(generations.next() == directory.appendingPathComponent("take-8.json").path)
        #expect(said.withLock { $0.count } == 2, "飛ばさなかった回は黙る")

        #expect((try? Data(contentsOf: first)) == Data("{\"theme\":\"dark\"}".utf8))
        #expect((try? Data(contentsOf: second)) == Data("my notes".utf8))
    }

    @Test("飛ばした知らせは塞いでいた名前 (錠の名前も) を名指し、多ければ先頭の 3 つと残りの数にまとめる (#3970)")
    func theSkipNoticeNamesWhatHeldTheNumber() throws {
        let manager = FileManager.default
        let directory = try TestScratch.directory("mokume-record-generations-notice")
        let base = directory.appendingPathComponent("take.json").path
        // 1: 錠の名前がフォルダ (行き先は無い)。2〜5: 記録でないファイル
        try manager.createDirectory(
            at: directory.appendingPathComponent("take-1.json.lock"), withIntermediateDirectories: false)
        for number in 2...5 {
            try Data("notes".utf8).write(to: directory.appendingPathComponent("take-\(number).json"))
        }
        let said = Mutex<[String]>([])
        let path = RecordGenerations(destination: base) { line in said.withLock { $0.append(line) } }.next()
        #expect(path == directory.appendingPathComponent("take-6.json").path)
        let notice = said.withLock { $0.first } ?? ""
        #expect(
            notice
                == "Skipped generation numbers held by something other than a record or its lock file, which is "
                + "kept as it is (take-1.json.lock, take-2.json, take-3.json and 2 more). This build records to "
                + path)
        // 上限ちょうどは数でまとめない
        #expect(
            RecordGenerations.skipNotice(["a", "b", "c"], recordingTo: "/x").contains("(a, b, c). This build"))
    }

    // MARK: - 反証 1 回目

    @Test("記録が書かれたかは、在るかではなく、この実行の始まりより後に書かれたかで決める")
    func anEarlierRecordDoesNotCountAsWritten() throws {
        let directory = try TestScratch.directory("mokume-record-written")
        let path = directory.appendingPathComponent("take.json").path
        let launched = Date()
        #expect(!RunCommand.recordWasWritten(at: path, since: launched), "無ければ書かれていない")

        // 前の回の完成品が残っている (子が記録を始めなかった回) — 書かれたことにしない
        try Data("{}".utf8).write(to: URL(fileURLWithPath: path))
        try FileManager.default.setAttributes(
            [.modificationDate: launched.addingTimeInterval(-60)], ofItemAtPath: path)
        #expect(!RunCommand.recordWasWritten(at: path, since: launched), "前の回の完成品を、今回のものと読んだ")

        // この実行が書いた
        try FileManager.default.setAttributes(
            [.modificationDate: launched.addingTimeInterval(5)], ofItemAtPath: path)
        #expect(RunCommand.recordWasWritten(at: path, since: launched))
    }

    @Test("道具が言う行き先と、子が書く場所は同じ綴りで、前後の空白も削らない")
    func theToldDestinationIsTheWrittenOne() throws {
        let given = try #require(try destination(["--record", "/tmp/ record dir/take .json "]))
        #expect(given == "/tmp/ record dir/take .json ")
        #expect(ReplayRequest(destination: given)?.environmentValue == given)
        let carried = RunCommand.childEnvironment([:], recording: given)[StartupReads.record.key]
        #expect(carried == given)
    }
}
