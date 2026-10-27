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

    /// 受け口が無ければ遮る合図は効かないので、そこだけ違っても戻ったとみなす (#3220)。
    /// ThreadSanitizer の下では、既定へ戻した受け口の遮る合図が全部を立てた形で読める。
    ///
    /// **受け口の段の前に、`SIGTERM` を既定へ戻す** (#3280)。無視の段の後に残った `SIG_IGN` のままだと、
    /// ``StopSignals/install()`` は「無視で継いだ合図」として何も置かず、受け口が無いので違いは
    /// 拾えない。**行き先の列は関数ポインタの配列で回さない** — 最適化の無い build (debug) では、先頭の
    /// `SIG_DFL` (nil) だけで反復が終わる。`SIG_IGN` の段が走らないまま緑になり、release でだけ走って
    /// 赤になった。仕組み (#3323 で確認): `SIG_IGN` は番地 1 の関数ポインタで、`sig_t?` をさらに
    /// Optional で包む (`for` の `next()` が返す形など) と、外側の `.none` のビット列と重なって `nil`
    /// と区別できない。包まない 1 段の `sig_t?` への `#expect(... == nil)` は `SIG_IGN` を誤らない。
    ///
    /// **段ごとに、行き先が本当にそうなったことを確かめる。** 置けていなければ段が空振りして緑のまま
    /// 見逃す (debug で緑だったのはそれ)。
    @Test("既定か無視の受け口は、遮る合図だけが違っても戻ったとみなし、受け口があれば違いを拾う")
    func comparesTheMaskOnlyForAHandler() throws {
        let kept = SignalState.current()
        defer { kept.restore() }
        for ignored in [false, true] {
            signal(SIGTERM, ignored ? SIG_IGN : SIG_DFL)
            let placed = StopSignals.current(SIGTERM)
            try #require(
                ignored ? StopSignals.isIgnored(placed) : StopSignals.isDefault(placed),
                "SIGTERM を\(ignored ? "無視" : "既定")にできていない")
            let snapshot = StopSignals.snapshot([SIGTERM])
            var action = StopSignals.current(SIGTERM)
            action.sa_mask = ~0
            sigaction(SIGTERM, &action, nil)
            #expect(
                StopSignals.changed(since: snapshot).isEmpty,
                "\(ignored ? "無視" : "既定")の受け口を、遮る合図の違いだけで戻っていないと読んだ")
        }

        // 直前の段が `SIG_IGN` を残しているので、受け口を置ける形 (既定) に戻してから置く
        signal(SIGTERM, SIG_DFL)
        StopSignals.install()
        let handler = StopSignals.current(SIGTERM)
        try #require(
            !StopSignals.isDefault(handler) && !StopSignals.isIgnored(handler), "SIGTERM に受け口が置かれていない")
        let snapshot = StopSignals.snapshot([SIGTERM])
        var action = handler
        action.sa_mask = ~0
        sigaction(SIGTERM, &action, nil)
        #expect(StopSignals.changed(since: snapshot) == [SIGTERM], "受け口がある合図の遮る合図の違いを見落とした")
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
