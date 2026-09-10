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
}
