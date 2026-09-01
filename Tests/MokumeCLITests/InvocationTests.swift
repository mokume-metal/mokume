// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation
import Testing

@testable import MokumeCLI

/// 走らせる口が受け取るもの (#680)。
///
/// **`run` と `watch` は同じものを受ける。** 別々に解いていた頃は、構成を選ぶ口が
/// どちらにも無く、`-c release` は場所として解釈されていた。
@Suite("走らせる口の引数")
struct InvocationTests {
    @Test("場所だけを渡せる")
    func takesJustThePlace() throws {
        #expect(try Invocation.parse(["/tmp/sketch"]) == Invocation(place: "/tmp/sketch"))
        #expect(try Invocation.parse([]) == Invocation())
    }

    /// **順序を問わない。** 打つ人が覚えることを増やさない。
    @Test("構成は場所の前でも後でも受ける")
    func takesTheConfigurationOnEitherSide() throws {
        let expected = Invocation(place: "/tmp/sketch", configuration: "release")
        #expect(try Invocation.parse(["/tmp/sketch", "-c", "release"]) == expected)
        #expect(try Invocation.parse(["-c", "release", "/tmp/sketch"]) == expected)
        #expect(
            try Invocation.parse(["--configuration", "release", "/tmp/sketch"]) == expected)
    }

    /// **名乗りと実体は同じ値から出す。** 選ばれていなければ道具立ての既定に任せ、
    /// 名乗りだけ既定の名前を使う。
    @Test("選ばれていなければ、道具立てに任せて既定の名前を名乗る")
    func leavesTheDefaultToTheToolchain() throws {
        let invocation = try Invocation.parse([])
        #expect(invocation.configuration == nil)
        #expect(invocation.configurationName == RunCommand.defaultConfigurationName)
        #expect(RunCommand.configurationArguments(invocation.configuration).isEmpty)
    }

    @Test("選ばれていれば、その名前を名乗り、その構成で組む")
    func carriesTheChosenConfiguration() throws {
        let invocation = try Invocation.parse(["-c", "release"])
        #expect(invocation.configurationName == "release")
        #expect(RunCommand.configurationArguments(invocation.configuration) == ["-c", "release"])
    }

    /// **知らない選択肢を黙って場所にしない。** 「スケッチが見つからない: …/-c」では
    /// 何を直せばよいか分からない。
    @Test("知らない選択肢は、使い方を出して止まる")
    func refusesUnknownOptions() {
        #expect(throws: CommandFailure.self) { try Invocation.parse(["--fast"]) }
        #expect(throws: CommandFailure.self) { try Invocation.parse(["-c"]) }
        #expect(throws: CommandFailure.self) { try Invocation.parse(["a", "b"]) }
    }
}
