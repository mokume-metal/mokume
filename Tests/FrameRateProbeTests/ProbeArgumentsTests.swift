// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Testing

@testable import frame_rate_probe

/// 計測の道具が、解けない引数を使い方の誤りとして断ること (#2490)。
///
/// 値を取る引数の値が欠けている・数でない・意味のない数のとき、黙って既定のまま走っていた。
/// `--seconds nan` は測り終える条件が永遠に偽になり、プロセスが終わらない。
@Suite("frame-rate-probe の引数")
struct ProbeArgumentsTests {
    private func failure(_ arguments: [String]) -> ProbeArguments.Failure? {
        do {
            _ = try ProbeArguments.parse(arguments)
            return nil
        } catch let failure as ProbeArguments.Failure {
            return failure
        } catch {
            return nil
        }
    }

    // ------------------------------------------------------------ 断る

    @Test(
        "解けない値は、理由を名乗って断る",
        arguments: [
            ["--seconds", "abc"],
            ["--seconds"],
            ["--seconds", "nan"],
            ["--seconds", "inf"],
            ["--seconds", "-inf"],
            ["--seconds", "-1"],
            ["--seconds", "0"],
            ["--minimize-after", "x"],
            ["--minimize-after"],
            ["--minimize-after", "nan"],
            ["--minimize-after", "inf"],
            ["--minimize-after", "-1"],
            // 値を取る口の次に別の綴りが来ても、それを値として読まない
            ["--seconds", "--allow-display-sleep"],
            // 畳む前に測り終える (畳まないまま黙って終わる)
            ["--seconds", "3", "--minimize-after", "3"],
            ["--seconds", "3", "--minimize-after", "5"],
            ["--minimize-after", "3", "--seconds", "2"],
            // --seconds が既定 (6 秒) のときも、既定と比べる
            ["--minimize-after", "6"],
            ["--minimize-after", "10"],
        ])
    func refusesUnusableValues(arguments: [String]) {
        let refused = failure(arguments)
        #expect(refused != nil, "\(arguments) は断られるはず")
        // 断る理由に、どの引数の話かが入っている
        #expect(refused?.message.contains(arguments[0]) == true)
    }

    @Test("数でない値は、打たれた値をそのまま名乗る")
    func namesTheOffendingValue() {
        #expect(failure(["--seconds", "abc"])?.message.contains("abc") == true)
    }

    @Test("知らない引数は、これまでどおり断る")
    func refusesUnknownArgument() {
        #expect(failure(["--secnds", "3"])?.message == "知らない引数: --secnds")
    }

    // ------------------------------------------------------------ 通す

    @Test("引数が無ければ既定 (6 秒・畳まない・スリープを断る)")
    func defaults() throws {
        let parsed = try ProbeArguments.parse([])
        #expect(parsed.seconds == 6)
        #expect(parsed.minimizeAfter == nil)
        #expect(parsed.allowsDisplaySleep == false)
    }

    @Test("scripts/measure-frame-rate.sh の呼び方は、そのまま通る")
    func acceptsTheCallsOfTheMeasuringScript() throws {
        #expect(try ProbeArguments.parse(["--seconds", "7"]).seconds == 7)
        #expect(try ProbeArguments.parse(["--seconds", "17"]).seconds == 17)

        let minimized = try ProbeArguments.parse(["--seconds", "7", "--minimize-after", "3"])
        #expect(minimized.seconds == 7)
        #expect(minimized.minimizeAfter == 3)

        let awake = try ProbeArguments.parse(["--seconds", "7", "--allow-display-sleep"])
        #expect(awake.seconds == 7)
        #expect(awake.allowsDisplaySleep)
    }

    @Test("畳むのが測り終えるより前なら通る (既定の 6 秒との比べ方も)")
    func minimizingBeforeTheEndPasses() throws {
        #expect(try ProbeArguments.parse(["--minimize-after", "5.9"]).minimizeAfter == 5.9)
        #expect(try ProbeArguments.parse(["--minimize-after", "3", "--seconds", "4"]).seconds == 4)
        #expect(try ProbeArguments.parse(["--seconds", "10", "--minimize-after", "9"]).minimizeAfter == 9)
    }

    @Test("--seconds の小数は通るが、断る理由には 1 秒刻みで切り上がることを書く")
    func fractionalSecondsAreExplained() throws {
        #expect(try ProbeArguments.parse(["--seconds", "6.5"]).seconds == 6.5)
        #expect(failure(["--seconds", "0"])?.message.contains("1 秒刻み") == true)
    }

    @Test("境界: 0 は畳むまでの秒数としてだけ通り、小数も通る")
    func boundaries() throws {
        #expect(try ProbeArguments.parse(["--minimize-after", "0"]).minimizeAfter == 0)
        #expect(try ProbeArguments.parse(["--seconds", "0.5"]).seconds == 0.5)
    }
}
