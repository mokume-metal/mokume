// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Darwin
import Testing

@testable import MokumeCore

/// 終わりの合図の受け口 ([#1219](https://github.com/mokume-metal/mokume/issues/1219))。
///
/// **検査のプロセスそのものの受け口を置き換える。** 置いたら必ず戻す — 戻し忘れると、以後
/// この検査のプロセスは Control + C でも `SIGTERM` でも終わらなくなる。控えて戻すのは
/// ``SignalState`` で、戻し忘れは suite の trait が赤にする (#1937)。受け口はプロセスに
/// 1 つなので、この suite の中では並べて走らせない。
@Suite("終わりの合図の受け口", .serialized, .signalStateKept)
struct StopSignalsTests {
    /// **背面 (`&`) で起こされた子の約束を壊さない。** シェルは前面の仕事にだけ Control + C を
    /// 届けるために、背面の子へ `SIGINT` を無視で渡す。
    @Test("無視で継いだ合図には、受け口を置かない")
    func leavesAnIgnoredSignalIgnored() {
        let kept = SignalState.current()
        defer { kept.restore() }
        signal(SIGINT, SIG_IGN)
        signal(SIGTERM, SIG_DFL)

        let replaced = StopSignals.install()
        #expect(replaced.map(\.number) == [SIGTERM])
        #expect(StopSignals.isIgnored(StopSignals.current(SIGINT)), "無視で継いだ SIGINT を上書きした")
        #expect(!StopSignals.isDefault(StopSignals.current(SIGTERM)), "SIGTERM に受け口が無い")
    }

    @Test("既定のままの合図には、SIGTERM にも SIGINT にも受け口を置く")
    func handlesBothSignalsByDefault() {
        let kept = SignalState.current()
        defer { kept.restore() }
        signal(SIGINT, SIG_DFL)
        signal(SIGTERM, SIG_DFL)

        let replaced = StopSignals.install()
        #expect(Set(replaced.map(\.number)) == [SIGTERM, SIGINT])
        for number in [SIGTERM, SIGINT] {
            let action = StopSignals.current(number)
            #expect(!StopSignals.isDefault(action) && !StopSignals.isIgnored(action))
        }
        StopSignals.restore(replaced)
        #expect(StopSignals.isDefault(StopSignals.current(SIGINT)), "受け口を戻していない")
    }

    /// **実際に合図を送る。** 受け口が置かれていなければ、送った瞬間に検査のプロセスごと
    /// 落ちる — だから送る前に、置かれたことを `#require` で確かめる。
    @Test("合図を受けると旗が立ち、読むと下りる")
    func aSignalRaisesTheFlagOnce() throws {
        // **旗も受け口と一緒に控えて戻す** (#1937)。読んでも下りない実装だと、旗が残って後の
        // 検査に拾われる
        let kept = SignalState.current()
        defer { kept.restore() }
        sketchStopRequested = 0
        signal(SIGTERM, SIG_DFL)

        StopSignals.install()
        let action = StopSignals.current(SIGTERM)
        try #require(!StopSignals.isDefault(action) && !StopSignals.isIgnored(action))

        #expect(!StopSignals.takeRequest(), "送る前から旗が立っている")
        raise(SIGTERM)
        #expect(StopSignals.takeRequest())
        #expect(!StopSignals.takeRequest(), "読んでも旗が下りない")
    }
}
