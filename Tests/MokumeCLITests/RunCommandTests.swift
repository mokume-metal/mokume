// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation
import Testing
import mokume

@testable import MokumeCLI

/// 走らせたスケッチの終わり方が、道具の終わり方にどう出るか。
///
/// **終わる場所は `main.swift` の 1 つだけである。** 途中で `exit` を呼ぶと、名乗りも
/// 後始末もその catch を素通りする — 素通りしたことは出力からは読めないので、
/// 経路が 2 系統あること自体を型で塞いである。
@Suite("スケッチを走らせる")
struct RunCommandTests {
    /// 指定した終了コードで終わるだけの実行ファイルを置く。
    private func makeExecutable(exiting status: Int32) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("mokume-run-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let executable = directory.appendingPathComponent("sketch")
        try "#!/bin/sh\nexit \(status)\n".write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: executable.path)
        return executable
    }

    /// 両方の流れへ 1 行ずつ書くだけの子。
    ///
    /// **偽の道具立てを `PATH` へ置く形は採らない。** `swift(_:in:capturing:errors:)` は
    /// 実行するものを `/usr/bin/env swift` に固定しているので、そちらからは差し替え
    /// られない。管の配線は `capture(_:capturing:errors:)` が持つので、任意の子を
    /// そこへ渡せば同じ配線を通せる。
    private func makeTalkativeChild() -> Process {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "echo out; echo err >&2"]
        return process
    }

    @Test("掴む形で愚痴を混ぜると、子が stderr にだけ書いた行も出力に載る")
    func mergedErrorsReachTheOutput() throws {
        let result = try RunCommand.capture(
            makeTalkativeChild(), capturing: true, errors: .merge)

        #expect(result.status == 0)
        #expect(result.output.contains("err"), "stderr の行が出力に載っていない")
        #expect(result.output.contains("out"), "stdout の行まで落としている")
    }

    /// 混ぜる先が広がっていないことの裏。
    ///
    /// 出力をファイルパスや JSON として解く呼び出し (`binPath` / `dumpPackage` /
    /// `Toolchain.describe`) は、警告 1 行が混ざるだけで解けなくなる ([#731])。
    ///
    /// [#731]: https://github.com/mokume-metal/mokume/issues/731
    @Test("愚痴を混ぜない形では、stderr の行は出力に載らない")
    func inheritedErrorsStayOutOfTheOutput() throws {
        let result = try RunCommand.capture(
            makeTalkativeChild(), capturing: true, errors: .inherit)

        #expect(result.output.contains("out"))
        #expect(!result.output.contains("err"), "混ぜない形なのに stderr が出力へ入った")
    }

    /// `env` 越しに起こす子。`swift` を実際に `PATH` から消さずに、同じ経路を通す。
    private func makeChildThroughEnv(_ arguments: [String]) -> Process {
        let process = Process()
        process.executableURL = RunCommand.envURL
        process.arguments = arguments
        return process
    }

    /// `/usr/bin/env` 自体は必ず起動できるので、起動の失敗としては届かない。
    /// **見逃すと空の出力が「走らせるものが無い」と読まれ、Package.swift を疑わせる**
    /// ([#1157](https://github.com/mokume-metal/mokume/issues/1157))。
    @Test("env 越しに探した道具が無ければ、道具が無いと投げる")
    func aMissingToolIsThrownAsSuch() {
        let tool = "mokume-no-such-tool-\(UUID().uuidString)"
        #expect(throws: CommandFailure.toolchainMissing(tool)) {
            try RunCommand.capture(
                makeChildThroughEnv([tool, "build"]), capturing: true, errors: .discard)
        }
    }

    /// 裏側。道具が在って失敗した回は今までどおり呼び手へ終了コードを返す — そこから先の
    /// 「ビルドが通らない」「走らせるものが無い」の案内は、呼び手の経路が変わらず持つ。
    @Test("env 越しに見つかった道具の失敗は、投げずに終了コードを返す")
    func aFoundToolsFailureIsReturned() throws {
        let result = try RunCommand.capture(
            makeChildThroughEnv(["false"]), capturing: true, errors: .discard)
        #expect(result.status == 1)
    }

    @Test("env 越しでない子の 127 は、その子の終了コードとして返す")
    func a127FromAnyOtherChildIsReturned() throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "exit 127"]
        let result = try RunCommand.capture(process, capturing: true, errors: .discard)
        #expect(result.status == 127)
    }

    @Test("0 以外で終わったスケッチは、終了コードを載せて投げる")
    func nonZeroExitsAreThrown() throws {
        let executable = try makeExecutable(exiting: 3)
        #expect(throws: CommandFailure.sketchExited(status: 3)) {
            try RunCommand.launch(executable, in: executable.deletingLastPathComponent())
        }
    }

    @Test("0 で終わったスケッチは、何も投げない")
    func cleanExitsAreQuiet() throws {
        let executable = try makeExecutable(exiting: 0)
        try RunCommand.launch(executable, in: executable.deletingLastPathComponent())
    }

    /// **道具の PID だけへ届く合図で、スケッチを孤児にしない**
    /// ([#1171](https://github.com/mokume-metal/mokume/issues/1171))。
    ///
    /// 端末の Control + C はグループ全体に届くので人の操作では起きず、エージェントや
    /// スクリプトが道具だけを止める経路で起きる。ここでは検査の走者そのものを道具に見立て、
    /// **自分のプロセスへ**合図を送る。
    ///
    /// **壊れた実装で走者ごと死なせない。** 受け口が置かれていなければ合図を送らずに失敗を
    /// 記録し、受け口が子へ渡さなければ期限で子を落として失敗を記録する — どちらでも
    /// `launch` の待ちは戻る。
    @Test(
        "道具だけへ終わりの合図が届いても、走らせていたスケッチを残さずに終わる",
        arguments: RunCommand.stopSignals)
    func aStopSignalTakesTheSketchDownToo(stopSignal: Int32) throws {
        /// 糸をまたいで結果を受け渡す箱。**触るのは終わりの合図の後だけ**なので鍵は要らない。
        nonisolated final class Sender: @unchecked Sendable {
            var failures: [String] = []
            var pid: pid_t?
            let done = DispatchSemaphore(value: 0)
        }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("mokume-run-signal-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let marker = directory.appendingPathComponent("pid")
        let executable = directory.appendingPathComponent("sketch")
        // **番号を書き終えてから名乗る** (途中を読ませない)。`exec` で番号を保ったまま眠る
        try """
            #!/bin/sh
            echo $$ > '\(marker.path).tmp' && mv '\(marker.path).tmp' '\(marker.path)'
            exec sleep 30
            """.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: executable.path)

        var before = sigaction()
        sigaction(stopSignal, nil, &before)
        let sender = Sender()
        // **並行プールに載せず、専用の糸で送る** (上の `theRunningChildCanBeTakenOutAndStopped`
        // と同じ理由)。期限はどれも安全網である (#564)
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
                sender.failures.append("スケッチが起きない")
                return
            }
            var current = sigaction()
            sigaction(stopSignal, nil, &current)
            guard current.__sigaction_u.__sa_handler != nil else {
                sender.failures.append("走らせている間、合図の受け口が置かれていない")
                kill(pid, SIGKILL)
                return
            }
            kill(getpid(), stopSignal)
            let gone = Date().addingTimeInterval(10)
            while kill(pid, 0) == 0, Date() < gone {
                Thread.sleep(forTimeInterval: 0.005)
            }
            if kill(pid, 0) == 0 {
                sender.failures.append("道具が合図を受けたのに、スケッチが残っている")
                kill(pid, SIGKILL)
            }
        }

        #expect(throws: CommandFailure.stopped(signal: stopSignal)) {
            try RunCommand.launch(executable, in: directory)
        }
        #expect(sender.done.wait(timeout: .now() + 60) == .success, "合図を送る糸が戻らない")
        for failure in sender.failures { Issue.record(Comment(rawValue: failure)) }
        let pid = try #require(sender.pid)
        #expect(kill(pid, 0) != 0, "launch が戻った後もスケッチが残っている")

        var after = sigaction()
        sigaction(stopSignal, nil, &after)
        #expect(
            (after.__sigaction_u.__sa_handler == nil) == (before.__sigaction_u.__sa_handler == nil),
            "走り終えた後に、合図の受け口を元へ戻していない")
    }

    /// **合図で止めた回は、慣習の 128 + 番号で終わる。** スケッチの成否として 15 を返すと、
    /// 止めた側は「スケッチが自分で失敗した」と読む。
    @Test("合図で止めた回は、スケッチの失敗とは別の終わり方を名乗る")
    func aStoppedRunSaysItWasStopped() {
        #expect(CommandFailure.stopped(signal: SIGTERM).exitCode == 128 + SIGTERM)
        #expect(!CommandFailure.stopped(signal: SIGTERM).message.contains("sketch's own output"))
    }

    /// **引き継ぐのはスケッチの終了コードだけ。**
    ///
    /// 呼ぶ側が `run` に見ているのは道具の成否ではなくスケッチの成否である。組み立ての
    /// 失敗は道具自身の失敗なので、ほかの失敗と同じ 1 で終わる。
    @Test("道具自身の失敗は 1 で終わる")
    func onlyTheSketchExitCodePassesThrough() {
        #expect(CommandFailure.sketchExited(status: 3).exitCode == 3)
        #expect(CommandFailure.sketchExited(status: 130).exitCode == 130)
        #expect(CommandFailure.buildFailed(status: 3).exitCode == 1)
        #expect(CommandFailure.templatesMissing.exitCode == 1)
    }

    @Test("道具が足した失敗ではないことが、文面から読める")
    func theMessageSaysWhoseFailureItIs() {
        let message = CommandFailure.sketchExited(status: 3).message
        #expect(message.contains("3"))
        #expect(message.contains("the tool"))
    }

    /// **合図を渡すのは `run` だけである** ([#1120](https://github.com/mokume-metal/mokume/issues/1120))。
    ///
    /// 見張り (`watch`) は渡さない — 子は窓を持たず、確認は道具の側が出している
    /// ([ADR-0032] 決定 1)。渡さなければ載らないので、受け取る側は「無ければ確かめない」
    /// だけで済む。
    ///
    /// [ADR-0032]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0032-window-ownership.md
    @Test("窓の × を確かめさせる合図は、渡したときだけ子の環境に載る")
    func theCloseSignalLandsOnlyWhenGiven() {
        #expect(RunCommand.childEnvironment([:])[StartupReads.closeConfirmation.key] == nil)
        #expect(
            RunCommand.childEnvironment([:], stamp: "abc", reportingRate: "debug")[
                StartupReads.closeConfirmation.key] == nil,
            "見張りが渡す組み合わせで合図が載っている")

        let carried = RunCommand.childEnvironment([:], confirmingCloseFor: "mokume run")
        #expect(carried[StartupReads.closeConfirmation.key] == "mokume run")
    }

    // MARK: - 出来上がりの置き場 (#1067)

    /// **置き場を聞くのに `swift` を 1 本起こす。** 見張りは宣言が変わるまでそれを持ち回る
    /// ので (``BuildResolver``)、渡されたら聞き直さないことがここの約束である —
    /// 聞き直すと、手元の実測で毎回 315 ms が作り直しの時間に乗る
    /// ([#1067](https://github.com/mokume-metal/mokume/issues/1067))。
    ///
    /// **`Package.swift` の無い場所で見る。** 作り直しそのものは即座に失敗するが、
    /// 置き場をどこから得たかは結果に載るので、そこだけを見れば `swift build` の完走を
    /// 待たずに済む。
    @Test("置き場を渡した回は、道具立てに聞き直さない")
    func aGivenBinPathIsUsedAsIs() throws {
        let directory = try makeEmptyDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let given = directory.appendingPathComponent("given-bin", isDirectory: true)

        let rebuilt = try RunCommand.rebuild(
            in: directory, context: testContext(), capturing: true, binPath: given)

        #expect(rebuilt.binPath == given, "渡した置き場を使わず、道具立てに聞き直している")
    }

    /// 裏。**渡さなければ今までどおり聞く** — `run` と `bundle` はこちらを通る。
    @Test("置き場を渡さなければ、道具立てに聞く")
    func anAbsentBinPathIsAskedFor() throws {
        let directory = try makeEmptyDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let rebuilt = try RunCommand.rebuild(
            in: directory, context: testContext(), capturing: true)

        // place を組み立てて確かめない (道具立てが並びを変えた日に黙って別の場所を指す)。
        // **このパッケージの下の `.build` であること**だけを見る
        #expect(
            rebuilt.binPath.path.contains(directory.lastPathComponent),
            "聞いた先が別のパッケージの下になっている")
        #expect(rebuilt.binPath.lastPathComponent != "given-bin")
        #expect(rebuilt.binPath.path.contains(".build"), "道具立てが答える置き場の形をしていない")
    }

    private func makeEmptyDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("mokume-binpath-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    // MARK: - 走っている作り直しを掴む (#1147)

    /// **作り直しは `swift` を何度か呼ぶ** (`--show-bin-path` → `build` → 場合により
    /// `dump-package`)。止めると決めた後に 2 本目を起こすと、それが新しく `.build` の鍵を
    /// 握って、止めたはずの作り直しが続く ([#1147](https://github.com/mokume-metal/mokume/issues/1147))。
    @Test("止めると決めた後は、次の子を起こさずに投げる")
    func aStoppedBuildLaunchesNothingMore() {
        let running = RunningBuild()
        #expect(running.stop() == nil, "何も起こしていないのに子を掴んでいる")

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "exit 0"]
        #expect(throws: CommandFailure.rebuildStopped) {
            try RunCommand.capture(process, capturing: true, errors: .discard, running: running)
        }
        #expect(process.processIdentifier == 0, "止めると決めた後に子を起こした")
    }

    /// **掴んだ子は、終わったら手放す。** 手放さないと、次に止める口は終わった子を返し、
    /// 呼ぶ側は居ない相手に合図を撃つことになる。
    @Test("走っている子は止める口から取り出せて、終われば手放される")
    func theRunningChildCanBeTakenOutAndStopped() throws {
        /// 糸をまたいで結果を受け渡す箱。**触るのは終わりの合図の後だけ**なので鍵は要らない。
        nonisolated final class Outcome: @unchecked Sendable {
            var status: Int32?
            let done = DispatchSemaphore(value: 0)
        }
        let marker = FileManager.default.temporaryDirectory
            .appendingPathComponent("mokume-running-build-\(UUID().uuidString)")
        let running = RunningBuild()
        let outcome = Outcome()
        // **並行プールに載せず、専用の糸で待つ。** `Task.detached` で待たせたら、`make ci-check`
        // の並列の下でプールの糸が他の検査に塞がれ、60 秒待っても子が起きなかった (CI で実測)。
        // `Process` は閉じた中で作る (送れる値ではない)。起きたことは子が印を置いて名乗る
        //
        // **印は組み込みのリダイレクトで置き、`touch` を呼ばない。** `/bin/sh` (bash) は前面の子を
        // 待つ間に SIGINT を受けても、子が普通に終われば「子が処理した」とみなして続きを実行する。
        // `touch` が終わってから刈り取るまでの窓に撃つと `exec sleep 30` まで進んで眠り切り、
        // 待ちの期限と同時に赤くなった — 負荷の下ほど窓は広い (#1166)。子を待たなければ窓は無い
        Thread.detachNewThread {
            defer { outcome.done.signal() }
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.arguments = ["-c", ": > '\(marker.path)'; exec sleep 30"]
            outcome.status = try? RunCommand.capture(
                process, capturing: true, errors: .discard, running: running
            ).status
        }
        // **待つ側が期限を持つ** (#564)。期限は安全網である
        let deadline = Date().addingTimeInterval(30)
        while !FileManager.default.fileExists(atPath: marker.path), Date() < deadline {
            Thread.sleep(forTimeInterval: 0.005)
        }

        let child = try #require(running.stop(), "走っている子を掴んでいない")
        child.interrupt()
        #expect(outcome.done.wait(timeout: .now() + 30) == .success, "止めた子を待つ糸が戻らない")
        #expect(outcome.status == SIGINT, "取り出した子が、止めた合図で終わっていない")
        #expect(running.stop() == nil, "終わった子を掴んだままでいる")
    }
}
