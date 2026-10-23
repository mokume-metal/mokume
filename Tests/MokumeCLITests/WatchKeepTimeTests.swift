// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation
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
@Suite("watch --keep-time", .signalStateKept)
struct WatchKeepTimeTests {
    private func makeDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("mokume-keep-time-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
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

    @Test("旗を付けた見張りは、前の見張りの時計を始めに消し、終わりでも消す。旗の無い見張りは触れない")
    func theWatcherClearsItsFile() throws {
        let kept = SignalState.current()
        defer { kept.restore() }
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try Data(#"// swift-tools-version: 6.2"#.utf8)
            .write(to: root.appendingPathComponent("Package.swift"))
        let file = WatchCommand.keepTimeFile()
        let lock = URL(fileURLWithPath: file.path + ".lock")
        defer {
            try? FileManager.default.removeItem(at: file)
            try? FileManager.default.removeItem(at: lock)
        }
        #expect(file.path.hasPrefix("/"), "絶対パス")
        #expect(file.lastPathComponent.hasSuffix("\(getpid())"), "見張り 1 本ごとに別")

        // 旗が有る: 前の見張りが残したものは始める前に消え、巡回の中で置いたものは終わりで消える
        try Data("stale".utf8).write(to: file)
        try Data().write(to: lock)
        var existedInTheLoop = true
        try WatchCommand.run(
            ["--keep-time", root.path],
            watching: { _, _ in
                existedInTheLoop =
                    FileManager.default.fileExists(atPath: file.path)
                    || FileManager.default.fileExists(atPath: lock.path)
                try? Data("clock".utf8).write(to: file)
                try? Data().write(to: lock)
            })
        #expect(!existedInTheLoop, "前の見張りの時計が残っている")
        #expect(!FileManager.default.fileExists(atPath: file.path), "終わりで消していない")
        #expect(!FileManager.default.fileExists(atPath: lock.path), "錠のファイルを終わりで消していない")

        // 旗が無い: 何も作らず、在るものにも触れない
        try Data("untouched".utf8).write(to: file)
        try WatchCommand.run([root.path], watching: { _, _ in })
        #expect(try String(contentsOf: file, encoding: .utf8) == "untouched")
    }
}
