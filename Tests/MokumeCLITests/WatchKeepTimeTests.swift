// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import AppKit
import Foundation
import MokumeTestSupport
import Synchronization
import Testing

@testable import MokumeCLI
@testable import MokumeCore

/// `mokume watch --keep-time` — 作り直しをまたいで作者の時計を渡す旗 ([#2414])。
///
/// 時計そのもの (渡された値から始まる・書く) は `ClockHandoverTests` が見る。ここが見るのは**道具の側**:
/// 旗を `watch` だけが受けること、場所を子の環境に載せる (渡さなければ親の環境からも落とす) こと、
/// 見張りが場所を始めに消し終わりで消すこと。
///
/// [#2414]: https://github.com/mokume-metal/mokume/issues/2414
@Suite("watch --keep-time", .serialized, .signalStateKept)
struct WatchKeepTimeTests {
    private func makeDirectory() throws -> URL {
        let url = try TestScratch.directory("mokume-keep-time")
        return url
    }

    // MARK: - 旗

    @Test("旗は値を取らない: 次の語を食わず、置き場の語は位置引数として残り、打たなければ載らない")
    func theFlagTakesNoValue() throws {
        let (invocation, values) = try Invocation.parse(
            ["--keep-time", "sketch-dir"], adding: WatchCommand.options, from: URL(fileURLWithPath: "/"))
        #expect(values[WatchCommand.keepTimeFlag] != nil)
        #expect(invocation.place == "sketch-dir")

        // 打たなければ載らない。順が逆でも同じ
        let (_, without) = try Invocation.parse(
            ["sketch-dir"], adding: WatchCommand.options, from: URL(fileURLWithPath: "/"))
        #expect(without[WatchCommand.keepTimeFlag] == nil)
        let (after, with) = try Invocation.parse(
            ["sketch-dir", "-c", "release", "--keep-time"], adding: WatchCommand.options,
            from: URL(fileURLWithPath: "/"))
        #expect(with[WatchCommand.keepTimeFlag] != nil)
        #expect(after.place == "sketch-dir" && after.configuration == "release")
    }

    @Test("値を付けた綴り (--keep-time=1) は、空白で区切る案内ではなく、知らない選択肢として断る")
    func aValueOnTheFlagIsRefused() {
        do {
            _ = try Invocation.parse(
                ["--keep-time=1"], adding: WatchCommand.options, from: URL(fileURLWithPath: "/"))
            Issue.record("断らなかった")
        } catch let failure as CommandFailure {
            guard case .usage(let text) = failure else {
                Issue.record("\(failure)")
                return
            }
            #expect(text.hasPrefix("Unknown option: --keep-time=1"), "\(text)")
            #expect(!text.contains("separate the value"), "\(text)")
        } catch {
            Issue.record("\(error)")
        }
    }

    @Test("旗を受けるのは watch だけ: run・render と、足さない解き方は知らない選択肢として断る")
    func onlyWatchAcceptsTheFlag() {
        func message(_ body: () throws -> Void) -> String? {
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
        let run = message { _ = try Invocation.parse(["--keep-time"], from: URL(fileURLWithPath: "/")) }
        #expect(run?.hasPrefix("Unknown option: --keep-time") == true, "\(run ?? "断らなかった")")
        let render = message {
            _ = try RenderCommand.parse(
                ["--keep-time", "--fps", "60", "--seconds", "1", "--out", "/tmp/x.mov"],
                currentDirectory: URL(fileURLWithPath: "/"))
        }
        #expect(render?.hasPrefix("Unknown option: --keep-time") == true, "\(render ?? "断らなかった")")
        // 案内は旗を名乗る
        #expect(Command.usage().contains("--keep-time"))
    }

    // MARK: - 子の環境

    @Test("時計を運ぶ場所は、渡したときだけ載り、親の環境からは継がない")
    func theKeepTimeFileLandsOnlyWhenGiven() {
        let key = StartupReads.keepTime.key
        #expect(RunCommand.childEnvironment([:])[key] == nil)
        #expect(RunCommand.childEnvironment([key: "/tmp/clock"])[key] == nil, "親の合図を継いだ")
        #expect(RunCommand.childEnvironment([:], keepTime: "/tmp/clock")[key] == "/tmp/clock")
        // 読むだけの合図も、立てたときだけ (場所と一緒にだけ) 載り、親の環境からは継がない (#4070)
        let readOnly = StartupReads.keepTimeReadOnly.key
        #expect(RunCommand.childEnvironment([readOnly: "1"], keepTime: "/tmp/clock")[readOnly] == nil, "親の合図を継いだ")
        #expect(RunCommand.childEnvironment([:], keepTime: "/tmp/clock", keepTimeReadOnly: true)[readOnly] == "1")
        #expect(RunCommand.childEnvironment([:], keepTimeReadOnly: true)[readOnly] == nil, "場所なしで載せた")
        // 書き出しの子にも、渡さなければ落ちる
        let request = RenderRequest(frameRate: 60, frameCount: 1, destination: "/tmp/x.mov")
        #expect(RunCommand.childEnvironment([key: "/tmp/clock"], rendering: request)[key] == nil)
    }

    @Test("本物の起こす口は、渡された場所を子へ載せ、渡されなければ載せない")
    func theLiveLaunchPassesTheKeepTimeFile() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let seen = directory.appendingPathComponent("seen")
        let readOnly = directory.appendingPathComponent("read-only")
        let executable = directory.appendingPathComponent("sketch")
        try """
            #!/bin/sh
            printf '%s' "$\(StartupReads.keepTime.key)" > '\(seen.path)'
            printf '%s' "$\(StartupReads.keepTimeReadOnly.key)" > '\(readOnly.path)'
            """.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: executable.path)
        let resolver = BuildResolver(directory: directory) { _ in
            BuildResolution(
                context: BuildContext(
                    configuration: nil, place: .inPackage(.localDependency), product: "sketch",
                    assets: .undecided),
                binPath: directory)
        }

        for given in ["/tmp/mokume-clock", nil] as [String?] {
            let hooks = WatchSession.Hooks.live(
                resolver: resolver, running: RunningBuild(), keepTime: given)
            let child = try hooks.launch(executable, directory, nil, nil)
            child.waitUntilExit()
            #expect(try String(contentsOf: seen, encoding: .utf8) == (given ?? ""), "\(given ?? "渡さない")")
            #expect(try String(contentsOf: readOnly, encoding: .utf8) == "", "選ぶ前は書く子")
            // **見張りが選んだ番号の場所を受ける** (起こし直しは新しい場所で時刻を 0 から始める・#3428)。旗の無い見張りは
            // 選んでも載せない。0 に戻せば旗の場所
            hooks.selectClock(.init(place: 1))
            let renewed = try hooks.launch(executable, directory, nil, nil)
            renewed.waitUntilExit()
            #expect(
                try String(contentsOf: seen, encoding: .utf8) == (given.map { $0 + "-1" } ?? ""),
                "番号 1: \(given ?? "渡さない")")
            // **読むだけを選べば、合図が場所と一緒に載る** (試聴の子・#4070)。旗の無い見張りは場所が無いので載せない
            hooks.selectClock(.init(place: 0, readsOnly: true))
            let auditioned = try hooks.launch(executable, directory, nil, nil)
            auditioned.waitUntilExit()
            #expect(try String(contentsOf: seen, encoding: .utf8) == (given ?? ""), "読むだけ: \(given ?? "渡さない")")
            #expect(
                try String(contentsOf: readOnly, encoding: .utf8) == (given == nil ? "" : "1"),
                "読むだけ: \(given ?? "渡さない")")
            hooks.selectClock(.init(place: 0))
            let back = try hooks.launch(executable, directory, nil, nil)
            back.waitUntilExit()
            #expect(try String(contentsOf: seen, encoding: .utf8) == (given ?? ""), "番号 0: \(given ?? "渡さない")")
            #expect(try String(contentsOf: readOnly, encoding: .utf8) == "", "選び直せば書く子: \(given ?? "渡さない")")
        }
    }

    // MARK: - 見張りの口

    @Test("時計のファイルは専用のディレクトリの中に置く (一時ディレクトリの直下に置かない)")
    func theClockFileLivesInItsOwnDirectory() {
        let file = WatchCommand.keepTimeFile()
        #expect(file.path.hasPrefix("/"), "絶対パス")
        let directory = file.deletingLastPathComponent()
        #expect(directory.lastPathComponent == "mokume-keep-time-\(getpid())", "見張り 1 本ごとに別: \(directory.path)")
        #expect(directory.deletingLastPathComponent().standardizedFileURL
            == FileManager.default.temporaryDirectory.standardizedFileURL)
    }

    @Test("旗を付けた見張りは、前の見張りの時計 (ファイル・錠・書きかけ) を始めに消し、終わりでも消す。旗の無い見張りは触れない")
    func theWatcherClearsItsFiles() throws {
        let kept = SignalState.current()
        defer { kept.restore() }
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try Data(#"// swift-tools-version: 6.2"#.utf8)
            .write(to: root.appendingPathComponent("Package.swift"))
        let file = WatchCommand.keepTimeFile()
        let directory = file.deletingLastPathComponent()
        let lock = URL(fileURLWithPath: file.path + ".lock")
        // `AtomicFile` の一時ファイルの名: `.<名前>.<pid>-<連番>.tmp`
        let leftover = directory.appendingPathComponent(".clock.99999-4.tmp")
        let later = directory.appendingPathComponent(".clock.99999-5.tmp")
        defer { try? FileManager.default.removeItem(at: directory) }
        func plant(_ urls: [URL]) throws {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            for url in urls { try Data("x".utf8).write(to: url) }
        }

        // 旗が有る: 前の見張りが残したものは始める前に消え、巡回の中で置いたものは終わりで消える
        try plant([file, lock, leftover])
        var leftInTheLoop = true
        try WatchCommand.run(
            ["--keep-time", root.path],
            watching: { _, _ in
                leftInTheLoop = [file, lock, leftover].contains { FileManager.default.fileExists(atPath: $0.path) }
                try? plant([file, lock, later])
            })
        #expect(!leftInTheLoop, "前の見張りの時計が残っている")
        #expect(!FileManager.default.fileExists(atPath: directory.path), "終わりで消していない")

        // 旗が無い: 何も作らず、在るものにも触れない
        try plant([file])
        try WatchCommand.run([root.path], watching: { _, _ in })
        #expect(try String(contentsOf: file, encoding: .utf8) == "x")
    }

    @Test("名前が前置きで始まらないディレクトリは消さない (場所の取り違えで一時ディレクトリそのものを消さない)")
    func onlyItsOwnDirectoryIsRemoved() throws {
        let directory = try TestScratch.directory("unrelated")
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("clock")
        try Data("x".utf8).write(to: file)
        WatchCommand.removeKeepTimeFiles(file)
        #expect(FileManager.default.fileExists(atPath: file.path))
    }

    @Test("Dock の「終了」・ログアウトで run() に戻らなくても、後始末で時計のファイルと錠と書きかけを消す。2 度通っても害は無い")
    func teardownClearsTheClockFilesWithoutReturningFromRun() async throws {
        let kept = SignalState.current()
        defer { kept.restore() }
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let clockDirectory = directory.appendingPathComponent("mokume-keep-time-\(getpid())", isDirectory: true)
        try FileManager.default.createDirectory(at: clockDirectory, withIntermediateDirectories: true)
        let file = clockDirectory.appendingPathComponent("clock")
        let lock = URL(fileURLWithPath: file.path + ".lock")
        let temporary = clockDirectory.appendingPathComponent(".clock.88-1.tmp")
        for url in [file, lock, temporary] { try Data("x".utf8).write(to: url) }

        let session = await MainActor.run {
            WatchSession(
                directory: directory, context: testContext(), hooks: WatchCommandTests.Stub().hooks())
        }
        await MainActor.run {
            // 道具立てが終わる経路 (`applicationWillTerminate`) だけを通す。`run()` の `defer` は通らない
            let delegate = WatchCommand.ApplicationDelegate(
                stopRequested: {}, isFinished: { true },
                teardown: { WatchCommand.teardown(session, nil, keepTimeFile: file) })
            delegate.applicationWillTerminate(Notification(name: NSApplication.willTerminateNotification))
        }
        for url in [file, lock, temporary] {
            #expect(!FileManager.default.fileExists(atPath: url.path), "\(url.lastPathComponent) が残っている")
        }
        // 2 度目 (巡回を抜けた道と両方から呼ばれうる) は、何も無くても落ちない
        await MainActor.run { WatchCommand.removeKeepTimeFiles(file) }
    }

    // MARK: - 試聴を挟む列 (#4070)

    /// 生きている子の番号。時計の書き手が生きているかを、プロセスを起こさずに演じる。
    private nonisolated final class Living: Sendable {
        private let pids = Mutex<Set<Int32>>([])
        func start(_ pid: Int32) { pids.withLock { _ = $0.insert(pid) } }
        func end(_ pid: Int32) { pids.withLock { _ = $0.remove(pid) } }
        func contains(_ pid: Int32) -> Bool { pids.withLock { $0.contains(pid) } }
    }

    /// 見張りが起こした子 1 つ (`pid` と、生まれた順の世代)。時計の場所と読むだけかは、見張りが渡す環境
    /// (`RunCommand.childEnvironment`) から子の口 (``ClockHandover/startup(environment:unset:)``) が読んだとおりにする。
    @MainActor
    private struct Child {
        let handover: ClockHandover
        let sink: ClockHandover.FileSink

        init(path: String, audition: Bool = false, pid: Int32, generation: Double, living: Living) throws {
            let environment = RunCommand.childEnvironment([:], keepTime: path, keepTimeReadOnly: audition)
            let given = try #require(ClockHandover.startup(environment: environment, unset: { _ in }))
            living.start(pid)
            let sink = ClockHandover.FileSink(path: path, warn: { _ in }, isAlive: { living.contains($0) })
            self.sink = sink
            handover = ClockHandover(
                read: { ClockHandover.read(path: path) }, write: { sink.submit($0) },
                isAlive: { living.contains($0) }, warn: { _ in }, writer: pid, generation: generation,
                path: path, readsOnly: given.readsOnly)
        }

        func publish(_ seconds: Double, held: Bool = false, at moment: Double) {
            handover.publish(
                seconds: seconds, isHeld: held, isStill: false, kind: .realtime, frames: 0, at: moment)
            sink.settle()
        }
    }

    @Test("試聴を挟む列: 止めた本番から試聴に入り、試聴で時計を動かして捨てても、次の本番は本番の子の時計から始まる")
    @MainActor
    func anAbandonedAuditionLeavesNoClockBehind() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("clock").path
        let living = Living()

        // 本番の子が 120 秒で止めている
        let production = try Child(path: path, pid: 10, generation: 1, living: living)
        production.publish(120, held: true, at: 100)
        // 保存して試聴に入る。試聴の子は本番の時計を引き継いで、止めた 120 秒から始まる
        let audition = try Child(path: path, audition: true, pid: 11, generation: 2, living: living)
        let inherited = audition.handover.predecessor()?.start(at: 130)
        #expect(inherited?.seconds == 120 && inherited?.isHeld == true, "\(String(describing: inherited))")
        // 試聴の中で作者が時計を動かす (150 秒へ飛んで止める)。本番の子は止めたまま描き続ける
        audition.publish(150, held: true, at: 160)
        production.publish(120, held: true, at: 161)
        // `leave` で試聴を捨てる。本番の子は止めたまま描き続ける
        living.end(11)
        production.publish(120, held: true, at: 170)

        // 保存して本番を作り直す。新しい本番は、本番の子が止めた 120 秒から始まる
        let next = try Child(path: path, pid: 12, generation: 3, living: living)
        let started = next.handover.predecessor()?.start(at: 180)
        #expect(started?.seconds == 120 && started?.isHeld == true, "試聴の子の時計が残った: \(String(describing: started))")
    }

    @Test("試聴を挟む列: 試聴の子が生きている間も、本番の子は自分の時計を書き続け、試聴の子の秒はファイルに載らない")
    @MainActor
    func productionKeepsWritingWhileAuditioning() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("clock").path
        let living = Living()

        let production = try Child(path: path, pid: 10, generation: 1, living: living)
        production.publish(120, at: 100)
        let audition = try Child(path: path, audition: true, pid: 11, generation: 2, living: living)
        // 試聴の子は 120 秒から走り、作者が 200 秒へ飛ぶ
        audition.publish(120, at: 100.1)
        audition.publish(200, at: 100.2)
        guard case .found(let during) = ClockHandover.read(path: path) else {
            Issue.record("読めない")
            return
        }
        #expect(during.writer == 10 && during.seconds == 120, "試聴の子の時計が載った: \(during)")
        #expect(audition.sink.writeCount == 0, "試聴の子が書いた")
        // 本番の子は走り続け、しばらく書いていないので書き直す
        production.publish(121, at: 101)
        guard case .found(let read) = ClockHandover.read(path: path) else {
            Issue.record("読めない")
            return
        }
        #expect(read.writer == 10 && read.seconds == 121, "本番の子の時計が書かれていない: \(read)")
    }

    @Test("見張りは、本番の場所を受ける試聴の子だけを読むだけにする: 本番の子・起こし直した試聴の子・出た後の本番の子は書く")
    @MainActor
    func onlyAnAuditionSharingTheProductionClockReadsOnly() async throws {
        let harness = try WatchAuditionTests.Harness()
        try #require(await harness.save())
        #expect(try await harness.ask("audition")["accepted"] as? Bool == true)
        try #require(await harness.save())
        #expect(harness.clocks == [0, 0] && harness.readOnlyClocks == [false, true], "本番 s1・試聴 s2")
        // 試聴の中の次の保存も、本番の場所を読むだけ
        try #require(await harness.save())
        #expect(harness.clocks.last == 0 && harness.readOnlyClocks.last == true, "試聴 s3")
        // 起こし直した試聴の子は、本番と分け持たない自分の場所に書く
        #expect(try await harness.ask("restart")["accepted"] as? Bool == true)
        #expect(harness.clocks.last == 1 && harness.readOnlyClocks.last == false, "起こし直した試聴")
        #expect(try await harness.ask("leave")["accepted"] as? Bool == true)
        try #require(await harness.save())
        #expect(harness.clocks.last == 0 && harness.readOnlyClocks.last == false, "出た後の本番 s4")
    }
}
