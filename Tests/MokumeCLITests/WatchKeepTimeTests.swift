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
        #expect(RunCommand.childEnvironment([:], assetBundles: nil)[key] == nil)
        #expect(RunCommand.childEnvironment([key: "/tmp/clock"], assetBundles: nil)[key] == nil, "親の合図を継いだ")
        #expect(RunCommand.childEnvironment([:], keepTime: "/tmp/clock", assetBundles: nil)[key] == "/tmp/clock")
        // 読むだけの合図も、立てたときだけ (場所と一緒にだけ) 載り、親の環境からは継がない (#4070)
        let readOnly = StartupReads.keepTimeReadOnly.key
        #expect(RunCommand.childEnvironment([readOnly: "1"], keepTime: "/tmp/clock", assetBundles: nil)[readOnly] == nil, "親の合図を継いだ")
        #expect(RunCommand.childEnvironment([:], keepTime: "/tmp/clock", keepTimeReadOnly: true, assetBundles: nil)[readOnly] == "1")
        #expect(RunCommand.childEnvironment([:], keepTimeReadOnly: true, assetBundles: nil)[readOnly] == nil, "場所なしで載せた")
        // 従う子の番号は、読むだけの合図と一緒にだけ載り、親の環境からは継がない (#3566)
        let follows = StartupReads.keepTimeFollows.key
        #expect(RunCommand.childEnvironment([follows: "7"], keepTime: "/tmp/clock", keepTimeReadOnly: true, assetBundles: nil)[follows] == nil)
        #expect(
            RunCommand.childEnvironment([:], keepTime: "/tmp/clock", keepTimeReadOnly: true, keepTimeFollows: 7, assetBundles: nil)[follows]
                == "7")
        #expect(RunCommand.childEnvironment([:], keepTime: "/tmp/clock", keepTimeFollows: 7, assetBundles: nil)[follows] == nil, "書く子に載せた")
        #expect(RunCommand.childEnvironment([:], keepTimeReadOnly: true, keepTimeFollows: 7, assetBundles: nil)[follows] == nil, "場所なしで載せた")
        // 子の口は、読むだけの子にだけ番号を持たせ、0 以上の整数でなければ従う子が分からないとする
        let take = { (env: [String: String]) in ClockHandover.startup(environment: env, unset: { _ in }) }
        let base = [StartupReads.keepTime.key: "/tmp/clock"]
        #expect(take(base.merging([readOnly: "1", follows: "42"]) { $1 })?.follows == 42)
        #expect(take(base.merging([readOnly: "1", follows: "0"]) { $1 })?.follows == 0)
        #expect(take(base.merging([readOnly: "1", follows: "-3"]) { $1 })?.follows == nil)
        #expect(take(base.merging([readOnly: "1", follows: "x"]) { $1 })?.follows == nil)
        #expect(take(base.merging([readOnly: "1"]) { $1 })?.follows == nil)
        #expect(take(base.merging([follows: "42"]) { $1 })?.follows == nil, "書く子が番号を持った")
        var unset: [String] = []
        _ = ClockHandover.startup(environment: base.merging([follows: "42"]) { $1 }, unset: { unset.append($0) })
        #expect(unset.contains(follows), "番号を孫へ継がせる")
        // 書き出しの子にも、渡さなければ落ちる
        let request = RenderRequest(frameRate: 60, frameCount: 1, destination: "/tmp/x.mov")
        #expect(RunCommand.childEnvironment([key: "/tmp/clock"], rendering: request, assetBundles: nil)[key] == nil)
    }

    @Test("本物の起こす口は、渡された場所を子へ載せ、渡されなければ載せない")
    func theLiveLaunchPassesTheKeepTimeFile() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let seen = directory.appendingPathComponent("seen")
        let readOnly = directory.appendingPathComponent("read-only")
        let followed = directory.appendingPathComponent("follows")
        let executable = directory.appendingPathComponent("sketch")
        try """
            #!/bin/sh
            printf '%s' "$\(StartupReads.keepTime.key)" > '\(seen.path)'
            printf '%s' "$\(StartupReads.keepTimeReadOnly.key)" > '\(readOnly.path)'
            printf '%s' "$\(StartupReads.keepTimeFollows.key)" > '\(followed.path)'
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
                resolver: resolver, running: RunningBuild(), dependencies: .silent, keepTime: given)
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
            hooks.selectClock(.init(place: 0, readsOnly: true, follows: 4321))
            let auditioned = try hooks.launch(executable, directory, nil, nil)
            auditioned.waitUntilExit()
            #expect(try String(contentsOf: seen, encoding: .utf8) == (given ?? ""), "読むだけ: \(given ?? "渡さない")")
            #expect(
                try String(contentsOf: readOnly, encoding: .utf8) == (given == nil ? "" : "1"),
                "読むだけ: \(given ?? "渡さない")")
            #expect(
                try String(contentsOf: followed, encoding: .utf8) == (given == nil ? "" : "4321"),
                "従う子: \(given ?? "渡さない")")
            // 書く子には、従う子の番号を選んでも載せない
            hooks.selectClock(.init(place: 0, follows: 4321))
            let back = try hooks.launch(executable, directory, nil, nil)
            back.waitUntilExit()
            #expect(try String(contentsOf: seen, encoding: .utf8) == (given ?? ""), "番号 0: \(given ?? "渡さない")")
            #expect(try String(contentsOf: readOnly, encoding: .utf8) == "", "選び直せば書く子: \(given ?? "渡さない")")
            #expect(try String(contentsOf: followed, encoding: .utf8) == "", "書く子に番号: \(given ?? "渡さない")")
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
        let timers: Timers

        /// - Parameter follows: 読むだけの子 (`audition`) が従う本番の子の番号。見張りの環境を通して渡る。
        init(
            path: String, audition: Bool = false, follows: Int32? = nil, pid: Int32, generation: Double,
            living: Living, timers: Timers = Timers()
        ) throws {
            let environment = RunCommand.childEnvironment(
                [:], keepTime: path, keepTimeReadOnly: audition, keepTimeFollows: follows, assetBundles: nil)
            let given = try #require(ClockHandover.startup(environment: environment, unset: { _ in }))
            living.start(pid)
            let sink = ClockHandover.FileSink(path: path, warn: { _ in }, isAlive: { living.contains($0) })
            self.sink = sink
            self.timers = timers
            handover = ClockHandover(
                read: { ClockHandover.read(path: path) }, write: { sink.submit($0) },
                isAlive: { living.contains($0) }, warn: { _ in }, writer: pid, generation: generation,
                path: path, readsOnly: given.readsOnly, follows: given.follows, now: { timers.now },
                schedule: { delay, work in timers.add(delay, work) })
        }

        func publish(_ seconds: Double, held: Bool = false, still: Bool = false, at moment: Double) {
            handover.publish(
                seconds: seconds, isHeld: held, isStill: still, kind: .realtime, frames: 0, at: moment)
            sink.settle()
        }

        /// 頼まれた見直しを、時計を `moment` へ進めて走らせる。走らせた数を返す。
        @discardableResult
        func fire(at moment: Double) -> Int {
            let count = timers.fire(at: moment)
            sink.settle()
            return count
        }
    }

    /// 止まっている間の見直しの替え玉。実時間を待たず、検査が時刻を決めて走らせる。
    @MainActor
    private final class Timers {
        private(set) var now: Double = 0
        private var works: [@MainActor () -> Void] = []
        /// 頼まれた数 (走らせたものも含む)。
        private(set) var requested = 0

        func add(_ delay: Double, _ work: @escaping @MainActor () -> Void) {
            #expect(delay == ClockHandover.refreshInterval)
            requested += 1
            works.append(work)
        }

        func fire(at moment: Double) -> Int {
            now = moment
            let due = works
            works = []
            for work in due { work() }
            return due.count
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
        let audition = try Child(path: path, audition: true, follows: 10, pid: 11, generation: 2, living: living)
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
        let audition = try Child(path: path, audition: true, follows: 10, pid: 11, generation: 2, living: living)
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

    // MARK: - 送った版の時計 (#3566 の決定 2)

    private func written(_ path: String) -> ClockHandover.Snapshot? {
        guard case .found(let snapshot) = ClockHandover.read(path: path) else { return nil }
        return snapshot
    }

    @Test("送った子は、前の本番が最後に書いて止まってから書き始める。次の試聴の子は送った子の時計を読むだけ")
    @MainActor
    func theSentChildStartsWritingAfterThePreviousProductionStops() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("clock").path
        let living = Living()

        let production = try Child(path: path, pid: 10, generation: 1, living: living)
        production.publish(120, at: 100)
        let sent = try Child(path: path, audition: true, follows: 10, pid: 11, generation: 2, living: living)
        // 送った後・乗り換えの前: 前の本番が生きている間、送った子は読むだけ
        sent.publish(150, at: 100.1)
        #expect(written(path)?.writer == 10 && sent.sink.writeCount == 0, "\(String(describing: written(path)))")
        // 前の本番が最後に書き、止まる
        production.publish(125, held: true, at: 105)
        living.end(10)
        #expect(written(path)?.writer == 10 && written(path)?.seconds == 125)
        // 送った子が書き始める
        sent.publish(156, at: 106)
        let after = try #require(written(path))
        #expect(after.writer == 11 && after.seconds == 156, "送った子が書き手にならない: \(after)")
        #expect(sent.handover.tookOver)
        // 次の試聴の子は、送った子 (いまの本番) と時計を分け持つので読むだけ
        let next = try Child(path: path, audition: true, follows: 11, pid: 12, generation: 3, living: living)
        next.publish(300, at: 107)
        #expect(written(path)?.writer == 11 && next.sink.writeCount == 0, "次の試聴の子が書いた")
        let started = next.handover.predecessor()?.start(at: 107)
        #expect(started?.seconds == 157 && started?.isHeld == false, "\(String(describing: started))")
    }

    @Test("逆の順: 前の本番が書く前に送った子が書こうとしても見送り、前の本番の最後の時計は上書きされない")
    @MainActor
    func theSentChildYieldsUntilThePreviousProductionIsGone() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("clock").path
        let living = Living()

        let production = try Child(path: path, pid: 10, generation: 1, living: living)
        production.publish(120, at: 100)
        let sent = try Child(path: path, audition: true, follows: 10, pid: 11, generation: 2, living: living)
        // 送った子が先に書こうとする (前の本番はまだ止まりかけで生きている)
        sent.publish(150, held: true, at: 101)
        // 止まりかけの前の本番が、その後に最後の時計を書く — 世代の新しい送った子はまだ書いていないので見送らない
        production.publish(130, held: true, at: 102)
        #expect(written(path)?.writer == 10 && written(path)?.seconds == 130, "\(String(describing: written(path)))")
        // 同時: 前の本番が生きている間は、同じ時刻に頼んでも送った子の時計は載らない
        production.publish(131, held: true, at: 102.6)
        sent.publish(151, held: true, at: 102.6)
        #expect(written(path)?.writer == 10 && written(path)?.seconds == 131 && sent.sink.writeCount == 0)
        // 前の本番が止まった直後は、まだ見直す前 (前に見てから ``refreshInterval`` 未満)。見直すと書く
        living.end(10)
        sent.publish(151, held: true, at: 102.7)
        #expect(written(path)?.writer == 10, "見直しの間隔の前に書いた")
        sent.publish(151, held: true, at: 103.2)
        #expect(written(path)?.writer == 11 && written(path)?.seconds == 151, "\(String(describing: written(path)))")
    }

    @Test("送った後に起きた次の試聴の子は、送った子より先に前の本番の死を見ても書き手にならず、試聴の秒は本番の場所に残らない")
    @MainActor
    func theNextAuditionDoesNotTakeOverFromTheSentChild() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("clock").path
        let living = Living()

        let production = try Child(path: path, pid: 10, generation: 1, living: living)
        production.publish(120, held: true, at: 100)
        // 送った子 (前の本番に従う)。送った後に起きた次の試聴の子 (送った子に従う)
        let sent = try Child(path: path, audition: true, follows: 10, pid: 11, generation: 2, living: living)
        let next = try Child(path: path, audition: true, follows: 11, pid: 12, generation: 3, living: living)
        // 前の本番が止まる。次の試聴の子が、送った子より先に見直す (試聴の中で 300 秒へ飛んで止めた)
        living.end(10)
        next.publish(300, held: true, at: 101)
        #expect(written(path)?.writer == 10 && next.sink.writeCount == 0, "次の試聴の子が書いた: \(String(describing: written(path)))")
        // 送った子が書き手になり、試聴を捨てた後の本番の版は送った子の時計から始まる
        sent.publish(130, held: true, at: 101.1)
        living.end(12)
        sent.publish(130, held: true, at: 102)
        let after = try #require(written(path))
        #expect(after.writer == 11 && after.seconds == 130, "\(after)")
    }

    @Test("従う子が分からない読むだけの子 (古い見張り) は書かない。従う本番が居なかった子 (0) は書く")
    @MainActor
    func aReadOnlyChildWithoutALeaderNeverWrites() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("clock").path
        let living = Living()
        let production = try Child(path: path, pid: 10, generation: 1, living: living)
        production.publish(120, held: true, at: 100)
        living.end(10)
        let unknown = try Child(path: path, audition: true, pid: 11, generation: 2, living: living)
        unknown.publish(130, held: true, at: 101)
        unknown.publish(131, held: true, at: 102)
        #expect(written(path)?.writer == 10 && !unknown.handover.tookOver, "従う子の分からない子が書いた")
        // 試聴に入ったときに本番が走っていなかった (落ちていた): 守る本番の時計が無いので書く (受け入れ済みの代償)
        let orphan = try Child(path: path, audition: true, follows: 0, pid: 12, generation: 3, living: living)
        orphan.publish(140, held: true, at: 103)
        #expect(written(path)?.writer == 12 && written(path)?.seconds == 140)
    }

    @Test("送った子が noLoop() で止まっていても、前の本番が止まった後の見直しで、ウィンドウに出ている枚の秒を書く")
    @MainActor
    func aStillSentChildTakesOverOnTheRecheck() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("clock").path
        let living = Living()

        let production = try Child(path: path, pid: 10, generation: 1, living: living)
        production.publish(120, at: 100)
        let timers = Timers()
        let sent = try Child(
            path: path, audition: true, follows: 10, pid: 11, generation: 2, living: living, timers: timers)
        // 送った子が最初の枚で止まる (`noLoop()`)。前の本番が生きているので書かず、見直しを 1 つだけ頼む
        sent.publish(42, still: true, at: 100.1)
        #expect(written(path)?.writer == 10 && timers.requested == 1)
        // 見直したときも前の本番が生きている: また 1 つ頼む
        #expect(sent.fire(at: 100.6) == 1)
        #expect(written(path)?.writer == 10 && timers.requested == 2)
        // 前の本番が最後に書いて止まる。枚は来ないまま、次の見直しで書き手になり、止まった枚の秒を書く
        production.publish(125, at: 100.9)
        living.end(10)
        #expect(sent.fire(at: 101.1) == 1)
        let after = try #require(written(path))
        #expect(after.writer == 11 && after.seconds == 42 && after.isStill, "止まった送った子が書かない: \(after)")
        #expect(timers.requested == 2, "書き手になった後も見直しを頼んだ")
        // 次の版は、止まった枚の秒から始まる (止まっていた間を足さない)
        let next = try Child(path: path, pid: 12, generation: 3, living: living)
        #expect(next.handover.predecessor()?.start(at: 200).seconds == 42)
    }

    @Test("見直しを頼むのは、読むだけで止まっている子だけ: 走っている読むだけの子・書く子・動き出した子は頼まない")
    @MainActor
    func onlyAStillReadOnlyChildSchedulesARecheck() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("clock").path
        let living = Living()
        let writerTimers = Timers()
        let production = try Child(path: path, pid: 10, generation: 1, living: living, timers: writerTimers)
        production.publish(120, still: true, at: 100)
        #expect(writerTimers.requested == 0, "書く子が見直しを頼んだ")
        let timers = Timers()
        let audition = try Child(
            path: path, audition: true, follows: 10, pid: 11, generation: 2, living: living, timers: timers)
        audition.publish(130, held: true, at: 100.1)
        #expect(timers.requested == 0, "走っている読むだけの子が見直しを頼んだ")
        // 止まってから動き出すと、頼んであった見直しは何もせず、頼み直さない
        audition.publish(131, still: true, at: 100.2)
        audition.publish(132, at: 100.3)
        living.end(10)
        #expect(audition.fire(at: 100.8) == 1)
        #expect(written(path)?.writer == 10 && timers.requested == 1, "動き出した子が見直しで書いた")
    }

    @Test("受け入れた代償: 試聴の間に本番が自分で落ちると試聴の子が書き始め、出た後に同じ場所で起きた本番はその秒から始まる")
    @MainActor
    func anAuditionTakesOverWhenTheProductionCrashes() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("clock").path
        let living = Living()
        let production = try Child(path: path, pid: 10, generation: 1, living: living)
        production.publish(120, held: true, at: 100)
        let audition = try Child(path: path, audition: true, follows: 10, pid: 11, generation: 2, living: living)
        // 本番が落ちる。試聴の子が書き手になる (試聴の中で 150 秒へ飛んで止めた)
        living.end(10)
        audition.publish(150, held: true, at: 101)
        #expect(written(path)?.writer == 11 && written(path)?.seconds == 150)
        // `leave` で試聴の子が止まり、見張りは出た時点のソースで本番を同じ場所から起こす
        living.end(11)
        let recovered = try Child(path: path, pid: 12, generation: 3, living: living)
        let started = recovered.handover.predecessor()?.start(at: 110)
        #expect(started?.seconds == 150 && started?.isHeld == true, "\(String(describing: started))")
    }

    @Test("受け入れた代償の見張りの側: 試聴中に本番が落ちてから出ると、本番は同じ場所 (書く子) で起き直す")
    @MainActor
    func leavingAfterTheProductionCrashedRestartsOnTheSamePlace() async throws {
        let harness = try WatchAuditionTests.Harness()
        let production = try #require(await harness.save())
        #expect(try await harness.ask("audition")["accepted"] as? Bool == true)
        _ = try #require(await harness.save())
        #expect(harness.followedClocks.last == production.processIdentifier)
        harness.tell(production, "crash")
        await harness.beat()
        let launched = harness.gens.count
        #expect(try await harness.ask("leave")["accepted"] as? Bool == true)
        await harness.beat()
        await harness.beat()
        try #require(harness.gens.count > launched, "出た後に本番を起こしていない")
        #expect(harness.clocks.last == 0 && harness.readOnlyClocks.last == false, "\(harness.clocks)")
    }

    @Test("通し: 見張りが選んだ場所・読むだけ・従う子を実物の時計の口に通すと、送った子だけが書き手になり、次の試聴の子は書かない")
    @MainActor
    func theWatcherChoicesKeepOneWriterAfterASend() async throws {
        let harness = try WatchAuditionTests.Harness()
        let production = try #require(await harness.save())
        #expect(try await harness.ask("audition")["accepted"] as? Bool == true)
        let sent = try #require(await harness.save())
        #expect(try await harness.ask("send")["accepted"] as? Bool == true)
        await harness.session.generationPromoted(pid: sent.processIdentifier, from: .window)
        harness.wait(production)
        try #require(!production.isRunning)
        let next = try #require(await harness.save())
        #expect(harness.session.auditionChild === next)
        // 見張りが選んだ値: 本番 (書く)・送った子 (読むだけ・本番に従う)・次の試聴の子 (読むだけ・送った子に従う)
        #expect(harness.clocks == [0, 0, 0] && harness.readOnlyClocks == [false, true, true], "\(harness.clocks)")
        #expect(
            harness.followedClocks == [nil, production.processIdentifier, sent.processIdentifier],
            "\(harness.followedClocks)")

        // その値を本物の環境と口 (`childEnvironment` → `ClockHandover.startup`) に通し、実のプロセスの生死で書かせる
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("clock").path
        func handover(_ index: Int, _ process: Process) throws -> (ClockHandover, ClockHandover.FileSink) {
            let environment = RunCommand.childEnvironment(
                [:], keepTime: path, keepTimeReadOnly: harness.readOnlyClocks[index],
                keepTimeFollows: harness.followedClocks[index], assetBundles: nil)
            let given = try #require(ClockHandover.startup(environment: environment, unset: { _ in }))
            let sink = ClockHandover.FileSink(path: path, warn: { _ in })
            return (
                ClockHandover(
                    read: { ClockHandover.read(path: path) }, write: { sink.submit($0) }, warn: { _ in },
                    writer: process.processIdentifier, generation: Double(index + 1), path: path,
                    readsOnly: given.readsOnly, follows: given.follows),
                sink
            )
        }
        let (sentClock, sentSink) = try handover(1, sent)
        let (nextClock, nextSink) = try handover(2, next)
        // 次の試聴の子が先に見直す (試聴の中で 300 秒へ飛んだ)。送った子が生きているので書かない
        nextClock.publish(seconds: 300, isHeld: true, isStill: false, kind: .realtime, frames: 0, at: 10)
        nextSink.settle()
        #expect(nextSink.writeCount == 0, "次の試聴の子が書いた")
        // 送った子は、従う前の本番が居ないので書く
        sentClock.publish(seconds: 42, isHeld: true, isStill: false, kind: .realtime, frames: 0, at: 10.1)
        sentSink.settle()
        #expect(written(path)?.writer == sent.processIdentifier && written(path)?.seconds == 42)
        nextClock.publish(seconds: 301, isHeld: true, isStill: false, kind: .realtime, frames: 0, at: 11)
        nextSink.settle()
        #expect(nextSink.writeCount == 0 && written(path)?.seconds == 42, "次の試聴の子の秒が本番の場所に載った")
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

    @Test("試聴中に本番を起こし直して時計が分かれた後の試聴の子は、本番と時計を分け持たないので書く")
    @MainActor
    func anAuditionAfterAProductionRestartWritesItsClock() async throws {
        let harness = try WatchAuditionTests.Harness()
        try #require(await harness.save())
        // 本番の作り直しの最中に本番で起こし直しを頼み、済む前に試聴へ入る (起こし直しは本番の子に当たる)
        let building = try await harness.holdBuild()
        #expect(try await harness.ask("restart")["accepted"] as? Bool == true)
        #expect(try await harness.ask("audition")["accepted"] as? Bool == true)
        harness.releaseRebuild()
        await building.value
        await harness.beat()
        let restarted = try #require(harness.session.child)
        await harness.session.generationPromoted(pid: restarted.processIdentifier)
        try #require(await harness.save())
        // 本番 s1・本番 s2・起こし直した本番 (新しい場所)・試聴 s3 (前の本番の場所に残る)
        #expect(harness.clocks == [0, 0, 1, 0], "\(harness.clocks)")
        #expect(harness.readOnlyClocks == [false, false, false, false], "\(harness.readOnlyClocks)")
    }
}
