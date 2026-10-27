// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import AppKit
import Foundation
import MokumeTestSupport
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
        // 書き出しの子にも、渡さなければ落ちる
        let request = RenderRequest(frameRate: 60, frameCount: 1, destination: "/tmp/x.mov")
        #expect(RunCommand.childEnvironment([key: "/tmp/clock"], rendering: request)[key] == nil)
    }

    @Test("本物の起こす口は、渡された場所を子へ載せ、渡されなければ載せない")
    func theLiveLaunchPassesTheKeepTimeFile() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let seen = directory.appendingPathComponent("seen")
        let executable = directory.appendingPathComponent("sketch")
        try """
            #!/bin/sh
            printf '%s' "$\(StartupReads.keepTime.key)" > '\(seen.path)'
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
}
