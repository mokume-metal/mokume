// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation
import Testing
import mokume

@testable import MokumeCLI

/// 固定の fps で動きを書き出す口 (`render`・[#1282])。
///
/// **ビルドの前に止まるべきものは、ビルドの前に止まる。** 引数の誤りを数分のビルドの後で
/// 知らせると、直して打ち直すたびにまたビルドを待つことになる。子が窓を開かずに書き出す
/// ことは `SketchApplicationRenderTests` (MokumeCoreTests) が本物の GPU で見る。
///
/// [#1282]: https://github.com/mokume-metal/mokume/issues/1282
@Suite("固定の fps で書き出す口")
struct RenderCommandTests {
    /// `--out` の相対パスを解く基準 (打った場所)。
    private static let typedFrom = URL(fileURLWithPath: "/tmp/typed-here", isDirectory: true)

    private func parse(_ arguments: [String]) throws(CommandFailure) -> RenderCommand.Options {
        try RenderCommand.parse(arguments, currentDirectory: Self.typedFrom)
    }

    /// 使い方の誤りとして止まったか。**文面に `needle` を含むこと**まで見る — 止まっても、
    /// 何を直せばよいかが書かれていなければ打ち直せない。
    private func expectUsage(
        _ arguments: [String], mentioning needle: String,
        sourceLocation: SourceLocation = #_sourceLocation
    ) {
        do {
            _ = try parse(arguments)
            Issue.record("止まらなかった: \(arguments)", sourceLocation: sourceLocation)
        } catch {
            guard case .usage(let text) = error else {
                Issue.record("使い方の誤りではない: \(error)", sourceLocation: sourceLocation)
                return
            }
            #expect(
                text.contains(needle), "文面に \(needle) が無い: \(text)",
                sourceLocation: sourceLocation)
        }
    }

    // MARK: - 解ける形 (完了条件 1・2)

    @Test("場所・構成・置き場と、fps・秒数・行き先を受け、枚数は fps × 秒数になる")
    func takesEverythingAndCountsTheFrames() throws {
        let options = try parse([
            "Cast", "-c", "release", "--scratch-path", ".build", "--fps", "60", "--seconds",
            "48", "--out", "/tmp/cast.mov",
        ])
        #expect(
            options.invocation
                == Invocation(place: "Cast", configuration: "release", scratchPath: ".build"))
        #expect(options.request.frameRate == 60)
        #expect(options.request.frameCount == 2880)
        #expect(options.request.destination == "/tmp/cast.mov")
    }

    /// **子の作業ディレクトリはスケッチの場所である。** 相対のまま渡すと、書いたものが
    /// スケッチの中に出来て、打った場所には何も無い。
    @Test("--out の相対パスは、打った場所から解いて絶対パスで渡す")
    func aRelativeOutIsResolvedFromWhereItWasTyped() throws {
        let movie = try parse(["--fps", "30", "--seconds", "2", "--out", "renders/a.mov"])
        #expect(movie.request.destination == "/tmp/typed-here/renders/a.mov")
        let series = try parse(["--fps", "30", "--seconds", "2", "--out", "../f-####.png"])
        #expect(series.request.destination == "/tmp/f-####.png")
    }

    /// 10 進で掛ける。2 進の浮動小数だと `100 × 1.1` が 110 にならず (110.00000000000001)、正しい組まで断る。
    @Test("秒数は小数でも受け、fps × 秒数が整数なら通す")
    func fractionalSecondsThatMakeWholeFramesPass() throws {
        func frames(_ fps: String, _ seconds: String) throws -> Int {
            try parse(["--fps", fps, "--seconds", seconds, "--out", "/a.mov"]).request.frameCount
        }
        #expect(try frames("30", "0.1") == 3)
        #expect(try frames("100", "1.1") == 110)
        #expect(try frames("24", "2.5") == 60)
        // 境目: 1 枚ちょうど
        #expect(try frames("1", "1") == 1)
    }

    // MARK: - ビルドの前に止まる (完了条件 1)

    @Test(
        "--fps・--seconds・--out のどれかが欠けたら、欠けたものを名指して止まる",
        arguments: [
            (["--seconds", "2", "--out", "/a.mov"], "--fps"),
            (["--fps", "30", "--out", "/a.mov"], "--seconds"),
            (["--fps", "30", "--seconds", "2"], "--out"),
        ])
    func aMissingFlagStopsWithItsName(arguments: [String], missing: String) {
        expectUsage(arguments, mentioning: missing)
    }

    /// **枚数は丸めない。** 丸めると、頼んだ長さと書き出した長さが黙って食い違う。
    @Test("fps × 秒数が整数にならない組は、丸めずに止まる")
    func aFractionalFrameCountIsRefused() {
        expectUsage(["--fps", "30", "--seconds", "0.05", "--out", "/a.mov"], mentioning: "1.5")
        expectUsage(
            ["--fps", "60", "--seconds", "0.001", "--out", "/a.mov"],
            mentioning: "not a whole number")
    }

    @Test(
        "fps は 1 以上の整数だけを受ける",
        arguments: ["0", "-30", "29.97", "abc", ""])
    func aBadFrameRateIsRefused(rate: String) {
        expectUsage(["--fps", rate, "--seconds", "2", "--out", "/a.mov"], mentioning: "--fps")
    }

    @Test(
        "秒数は 0 より大きい数だけを受ける",
        arguments: ["0", "-1", "abc", "2s", "inf", "nan", "0x10"])
    func aBadLengthIsRefused(seconds: String) {
        expectUsage(["--fps", "30", "--seconds", seconds, "--out", "/a.mov"], mentioning: "--seconds")
    }

    /// 形の規則は撮る係のもの。`.mov` か、番号の入る場所 (`#`) を持つ連番。
    @Test("行き先が動画でも連番でもなければ止まる", arguments: ["/a.png", "/a", "/a.mp4"])
    func anUnrecordableOutIsRefused(out: String) {
        expectUsage(["--fps", "30", "--seconds", "2", "--out", out], mentioning: "--out")
    }

    /// **`run` / `watch` の選択肢はそのまま効き、知らない選択肢は断る** (``Invocation`` と同じ規律)。
    @Test("知らない選択肢は、場所にせずに止まる")
    func anUnknownOptionIsRefused() {
        expectUsage(["--fps", "30", "--seconds", "2", "--out", "/a.mov", "-o", "x"], mentioning: "-o")
    }

    /// 解いた後にパッケージを探すので、`Package.swift` の無い場所でも使い方の誤りが先に出る。
    @Test("引数の誤りは、スケッチを探す前 (ビルドの前) に止まる")
    func argumentErrorsComeBeforeTheBuild() throws {
        let empty = FileManager.default.temporaryDirectory
            .appendingPathComponent("mokume-render-empty-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: empty) }

        let refused = #expect(throws: CommandFailure.self) {
            try RenderCommand.run([empty.path, "--fps", "30", "--out", "/a.mov"])
        }
        guard case .usage = refused else {
            Issue.record("使い方の誤りの前に、別の理由で止まった: \(String(describing: refused))")
            return
        }
        // 引数が揃えば、次はスケッチを探して無いと言う (ここでもビルドはしない)
        #expect(throws: CommandFailure.packageNotFound(path: empty.path)) {
            try RenderCommand.run([empty.path, "--fps", "30", "--seconds", "1", "--out", "/a.mov"])
        }
    }

    @Test("案内に render の行が並ぶ")
    func theUsageListsRender() {
        let usage = Command.usage("mokume")
        #expect(usage.contains("  render [<directory>]"))
        #expect(usage.contains("--fps <n> --seconds <s> --out <path>"))
        #expect(Command.Verb.named("render") == .render)
    }

    // MARK: - 子へ渡す合図 (完了条件 8)

    /// **子は同じ型で読む。** 道具が組んだ値を、子の側の読み手がそのまま戻せること。
    @Test("書き出しの頼みは、渡したときだけ子の環境に載り、子の読み手がそのまま戻せる")
    func theRequestLandsOnlyWhenGivenAndReadsBack() throws {
        let key = StartupReads.render.key
        #expect(RunCommand.childEnvironment([:])[key] == nil)
        #expect(
            RunCommand.childEnvironment([:], reportingRate: "debug", confirmingCloseFor: "mokume run")[key]
                == nil,
            "run が渡す組み合わせで書き出しの合図が載っている")

        let request = try #require(
            RenderRequest(frameRate: 30, frameCount: 90, destination: "/tmp/a:b/out.mov"))
        let carried = RunCommand.childEnvironment([:], rendering: request)
        #expect(RenderRequest(environmentValue: try #require(carried[key])) == request)
        // 窓を持たないので、× を確かめる合図も速さの名乗りも載せない
        #expect(carried[StartupReads.closeConfirmation.key] == nil)
        #expect(carried[StartupReads.frameRateNotice.key] == nil)
    }

    // MARK: - 終わり方 (完了条件 6)

    /// 環境を書き留めてから、指定した終了コードで終わる子。
    private func makeChild(exiting status: Int32) throws -> (executable: URL, seen: URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("mokume-render-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let seen = directory.appendingPathComponent("seen")
        let executable = directory.appendingPathComponent("sketch")
        try """
            #!/bin/sh
            printf '%s' "$\(StartupReads.render.key)" > '\(seen.path)'
            exit \(status)
            """.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: executable.path)
        return (executable, seen)
    }

    @Test("子が 0 で終われば何も投げず、子には頼みが渡っている")
    func aCleanChildIsQuietAndGotTheRequest() throws {
        let child = try makeChild(exiting: 0)
        let request = try #require(
            RenderRequest(frameRate: 24, frameCount: 48, destination: "/tmp/out.mov"))
        try RenderCommand.launch(
            child.executable, in: child.executable.deletingLastPathComponent(), request: request)
        #expect(try String(contentsOf: child.seen, encoding: .utf8) == request.environmentValue)
    }

    /// **`render` の終了コードは「書けたか」である。** スケッチの成否として名乗ると、呼ぶ側は
    /// どこが欠けたかを読めない。
    @Test("子が 0 以外で終われば、書き出しが揃わなかったと名乗って 0 以外で終わる")
    func aFailingChildSaysTheRenderIsIncomplete() throws {
        let child = try makeChild(exiting: 1)
        let request = try #require(
            RenderRequest(frameRate: 24, frameCount: 48, destination: "/tmp/out.mov"))
        #expect(throws: CommandFailure.renderIncomplete(destination: "/tmp/out.mov", status: 1)) {
            try RenderCommand.launch(
                child.executable, in: child.executable.deletingLastPathComponent(),
                request: request)
        }
        let failure = CommandFailure.renderIncomplete(destination: "/tmp/out.mov", status: 1)
        #expect(failure.exitCode != 0)
        #expect(failure.message.contains("/tmp/out.mov"))
    }

    // MARK: - 途中で止める (完了条件 7)

    /// **端末の Control + C は子へ届かない** — `Process` は子を別のプロセスグループに置くので、
    /// 前面のグループ (道具) にしか配られない。道具が受けて渡さないと、道具だけが消えて子は
    /// 書き出しを続ける。ここでは検査の走者を道具に見立て、**自分のプロセスへ** SIGINT を送る。
    ///
    /// **壊れた実装で走者ごと死なせない。** 受け口が置かれていなければ送らずに失敗を記録する。
    @Test("道具へ SIGINT が届いたら子を止め、止めたと名乗る")
    func aSigintToTheToolStopsTheChild() throws {
        /// 糸をまたいで結果を受け渡す箱。**触るのは終わりの合図の後だけ**なので鍵は要らない。
        nonisolated final class Sender: @unchecked Sendable {
            var failures: [String] = []
            var pid: pid_t?
            let done = DispatchSemaphore(value: 0)
        }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("mokume-render-sigint-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let marker = directory.appendingPathComponent("pid")
        let executable = directory.appendingPathComponent("sketch")
        try """
            #!/bin/sh
            echo $$ > '\(marker.path).tmp' && mv '\(marker.path).tmp' '\(marker.path)'
            exec sleep 30
            """.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: executable.path)

        // **既定の受け口から始める。** 走者が無視で継いでいると、SIGINT を受けない側へ倒れる
        var standard = sigaction()
        standard.__sigaction_u.__sa_handler = SIG_DFL
        var before = sigaction()
        sigaction(SIGINT, &standard, &before)
        defer { sigaction(SIGINT, &before, nil) }

        let sender = Sender()
        Thread.detachNewThread {
            defer { sender.done.signal() }
            let started = Date().addingTimeInterval(30)
            while Date() < started {
                if let text = try? String(contentsOf: marker, encoding: .utf8),
                    let pid = pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines))
                {
                    sender.pid = pid
                    break
                }
                Thread.sleep(forTimeInterval: 0.005)
            }
            guard let pid = sender.pid else {
                sender.failures.append("子が起きない")
                return
            }
            var current = sigaction()
            sigaction(SIGINT, nil, &current)
            guard current.__sigaction_u.__sa_handler != nil else {
                sender.failures.append("書き出している間、SIGINT の受け口が置かれていない")
                kill(pid, SIGKILL)
                return
            }
            kill(getpid(), SIGINT)
            let gone = Date().addingTimeInterval(10)
            while kill(pid, 0) == 0, Date() < gone {
                Thread.sleep(forTimeInterval: 0.005)
            }
            if kill(pid, 0) == 0 {
                sender.failures.append("道具が SIGINT を受けたのに、子が残っている")
                kill(pid, SIGKILL)
            }
        }

        let request = try #require(
            RenderRequest(frameRate: 30, frameCount: 900, destination: "/tmp/stopped.mov"))
        #expect(throws: CommandFailure.stopped(signal: SIGINT)) {
            try RenderCommand.launch(executable, in: directory, request: request)
        }
        #expect(sender.done.wait(timeout: .now() + 60) == .success, "合図を送る糸が戻らない")
        for failure in sender.failures { Issue.record(Comment(rawValue: failure)) }
        let pid = try #require(sender.pid)
        #expect(kill(pid, 0) != 0, "launch が戻った後も子が残っている")
        var after = sigaction()
        sigaction(SIGINT, nil, &after)
        #expect(after.__sigaction_u.__sa_handler == nil, "走り終えた後に、SIGINT の受け口を元へ戻していない")
    }

    @Test("書き終えたら、どこへ何枚書いたかを 1 行で名乗る")
    func theReportNamesTheCountAndThePlace() throws {
        let request = try #require(
            RenderRequest(frameRate: 60, frameCount: 2880, destination: "/tmp/cast.mov"))
        let line = RenderCommand.report(request)
        #expect(line == "Wrote 2880 frames at 60 fps to /tmp/cast.mov")
        #expect(!line.contains("\n"))
    }
}
