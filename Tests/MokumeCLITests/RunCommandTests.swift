// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation
import Testing

@testable import MokumeCLI

/// 走らせたスケッチの終わり方が、道具の終わり方にどう出るか。
///
/// **終わる場所は `main.swift` の 1 つだけである。** 途中で `exit` を呼ぶと、名乗りも
/// 後始末もその catch を素通りする — 素通りしたことは出力からは読めないので、
/// 経路が 2 系統あること自体を型で塞いである。
@Suite("スケッチを走らせる")
struct RunCommandTests {
    @Test("宣言された実行ファイルの product から名前を取る")
    func findsTheExecutableProduct() {
        let dump = """
            {"products":[
              {"name":"lib","type":{"library":["automatic"]}},
              {"name":"tool","type":{"executable":null}}
            ]}
            """
        #expect(RunCommand.executableProductName(inDumpOf: dump) == "tool")
    }

    @Test("実行ファイルが無ければ、名前を作らない")
    func returnsNothingWithoutAnExecutable() {
        let dump = #"{"products":[{"name":"lib","type":{"library":["automatic"]}}]}"#
        #expect(RunCommand.executableProductName(inDumpOf: dump) == nil)
        #expect(RunCommand.executableProductName(inDumpOf: "壊れている") == nil)
    }

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
        #expect(message.contains("道具"))
    }
}
