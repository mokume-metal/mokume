// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Testing

@testable import reference_sketches

/// `reference-sketches --render` が、解けない引数を使い方の誤りとして断ること (#2490)。
///
/// `--frames` の値が欠けている・数でないときは黙って静止画の経路へ落ち、負数は実行時に trap し、
/// 0 は空の置き場を黙って作り、置き場を省くと `--frames` が置き場の名前になっていた。GPU は要らない。
@Suite("reference-sketches --render の引数")
struct RenderArgumentsTests {
    private func failure(_ arguments: [String]) -> RenderArguments.Failure? {
        do {
            _ = try RenderArguments.parse(arguments)
            return nil
        } catch let failure as RenderArguments.Failure {
            return failure
        } catch {
            return nil
        }
    }

    @Test(
        "解けない値は、理由を名乗って断る",
        arguments: [
            ["shots", "--frames"],
            ["shots", "--frames", "abc"],
            ["shots", "--frames", "1.5"],
            ["shots", "--frames", "-3"],
            ["shots", "--frames", "0"],
            // 値を取る口の次に別の綴りが来ても、それを値として読まない
            ["shots", "--frames", "--other"],
            ["--frames"],
            ["shots", "extra"],
            ["shots", "--unknown"],
        ])
    func refusesUnusableArguments(arguments: [String]) {
        #expect(failure(arguments) != nil, "\(arguments) は断られるはず")
    }

    @Test("断る理由に、打たれた綴りと値が入る")
    func namesTheOffendingValue() {
        #expect(failure(["shots", "--frames", "abc"])?.message.contains("abc") == true)
        #expect(failure(["shots", "--frames", "-3"])?.message.contains("-3") == true)
        #expect(failure(["shots", "--bogus"])?.message == "知らない引数: --bogus")
    }

    @Test("置き場を省いても --frames を置き場の名前として読まない")
    func framesIsNotTakenForTheDirectory() throws {
        let parsed = try RenderArguments.parse(["--frames", "90"])
        #expect(parsed.directory == "shots")
        #expect(parsed.frames == 90)
    }

    @Test("従来の呼び方 (置き場だけ・置き場と --frames・何も渡さない) はそのまま通る")
    func acceptsTheExistingCalls() throws {
        #expect(try RenderArguments.parse([]) == RenderArguments(directory: "shots", frames: nil))
        #expect(
            try RenderArguments.parse(["out"]) == RenderArguments(directory: "out", frames: nil))
        #expect(
            try RenderArguments.parse(["out", "--frames", "90"])
                == RenderArguments(directory: "out", frames: 90))
        #expect(
            try RenderArguments.parse(["--frames", "1", "out"])
                == RenderArguments(directory: "out", frames: 1))
    }
}
