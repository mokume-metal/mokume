// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Darwin
import Testing

@testable import MokumeCore

/// 終わりの合図の受け口 ([#1219](https://github.com/mokume-metal/mokume/issues/1219))。
///
/// **検査のプロセスそのものの受け口を置き換える。** 置いたら必ず戻す — 戻し忘れると、以後
/// この検査のプロセスは Control + C でも `SIGTERM` でも終わらなくなる。受け口はプロセスに
/// 1 つなので、この suite の中では並べて走らせない。
@Suite("終わりの合図の受け口", .serialized)
struct StopSignalsTests {
    /// いまの受け口を引く。
    private func current(_ number: Int32) -> sigaction {
        var action = sigaction()
        sigaction(number, nil, &action)
        return action
    }

    /// 受け口を据えてから `body` を走らせ、終わったら据える前へ戻す。
    private func with(
        _ number: Int32, handler: (@convention(c) (Int32) -> Void)?, _ body: () throws -> Void
    ) rethrows {
        var action = sigaction()
        action.__sigaction_u.__sa_handler = handler
        var saved = sigaction()
        sigaction(number, &action, &saved)
        defer { sigaction(number, &saved, nil) }
        try body()
    }

    /// **背面 (`&`) で起こされた子の約束を壊さない。** シェルは前面の仕事にだけ Control + C を
    /// 届けるために、背面の子へ `SIGINT` を無視で渡す。
    @Test("無視で継いだ合図には、受け口を置かない")
    func leavesAnIgnoredSignalIgnored() {
        with(SIGINT, handler: SIG_IGN) {
            with(SIGTERM, handler: SIG_DFL) {
                let replaced = StopSignals.install()
                defer { StopSignals.restore(replaced) }

                #expect(replaced.map(\.number) == [SIGTERM])
                #expect(StopSignals.isIgnored(current(SIGINT)), "無視で継いだ SIGINT を上書きした")
                #expect(!StopSignals.isDefault(current(SIGTERM)), "SIGTERM に受け口が無い")
            }
        }
    }

    @Test("既定のままの合図には、SIGTERM にも SIGINT にも受け口を置く")
    func handlesBothSignalsByDefault() {
        with(SIGINT, handler: SIG_DFL) {
            with(SIGTERM, handler: SIG_DFL) {
                let replaced = StopSignals.install()
                defer { StopSignals.restore(replaced) }

                #expect(Set(replaced.map(\.number)) == [SIGTERM, SIGINT])
                for number in [SIGTERM, SIGINT] {
                    let action = current(number)
                    #expect(!StopSignals.isDefault(action) && !StopSignals.isIgnored(action))
                }
            }
            #expect(StopSignals.isDefault(current(SIGINT)), "受け口を戻していない")
        }
    }

    /// **実際に合図を送る。** 受け口が置かれていなければ、送った瞬間に検査のプロセスごと
    /// 落ちる — だから送る前に、置かれたことを `#require` で確かめる。
    @Test("合図を受けると旗が立ち、読むと下りる")
    func aSignalRaisesTheFlagOnce() throws {
        sketchStopRequested = 0
        try with(SIGTERM, handler: SIG_DFL) {
            let replaced = StopSignals.install()
            defer { StopSignals.restore(replaced) }
            let action = current(SIGTERM)
            try #require(!StopSignals.isDefault(action) && !StopSignals.isIgnored(action))

            #expect(!StopSignals.takeRequest(), "送る前から旗が立っている")
            raise(SIGTERM)
            #expect(StopSignals.takeRequest())
            #expect(!StopSignals.takeRequest(), "読んでも旗が下りない")
        }
    }
}
