// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation
import Testing
import mokume

@testable import MokumeCLI

/// 同じ区画を 2 人が同時に使ったとき、窓口が「応えなかった」と偽らないこと
/// ([#2857](https://github.com/mokume-metal/mokume/issues/2857))。
///
/// 応答 (`report.json`) も要求 (`request.json`) も 1 枚しか持たない。別の書き手が自分の要求を上書きする・
/// 置き換えると、自分の識別子は応答に二度と現れず、窓口は期限まで待って「走っているスケッチが応えなかった」
/// と答え、起動し直しなど直らない道へ人を送っていた。**別の書き手が `request.json` を置き換え、その
/// 要求に応答が書かれた**ことは、時計なしでファイルだけから分かる (面は要求を 1 枚ずつ拾い、応え終えるまで
/// 次を拾わない)。その時点で自分の識別子の応答はもう来ないので、取り合ったと名乗って次の手を添える。
@Suite("同じ区画を別の書き手と取り合ったとき")
struct FacetsContestedTests {
    /// `sleep` が呼ばれるたびに 1 刻み進む時計。`actions[n]` は n 回目の `sleep` で走る (区画の書き換え)。
    private final class FakeClock {
        let tick: UInt64 = 1_000_000_000
        var actions: [Int: () -> Void] = [:]
        private(set) var ticks = 0

        var now: DispatchTime {
            DispatchTime(uptimeNanoseconds: 1_000_000_000 + UInt64(ticks) * tick)
        }

        func sleep() {
            ticks += 1
            actions[ticks]?()
        }
    }

    private func makeFacets(waitLimit: TimeInterval = 5) -> (Facets, URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("mokume-facets-contested-\(UUID().uuidString)", isDirectory: true)
        return (Facets(directory: directory, waitLimit: waitLimit), directory)
    }

    private func requestURL(_ facet: URL) -> URL { WorkDirectory.requestURL(under: facet) }
    private func reportURL(_ facet: URL) -> URL { WorkDirectory.reportURL(under: facet) }

    // MARK: - 待ちの判定 (Facets.exchange・偽の時計)

    private func exchange(
        _ facets: Facets, facet: URL, clock: FakeClock
    ) throws -> Facets.Exchange {
        try facets.exchange(
            facet: facet, request: ["id": "mine"], id: "mine",
            sleep: { _ in clock.sleep() }, now: { clock.now })
    }

    /// (a) 自分の要求に応えた後、見回りより先に、別の書き手の要求への応答で上書きされた。
    /// 見回りが見るのは終わりの姿だけで、自分の識別子は二度と現れない。
    @Test("当たった後に上書きされた回 (a): 期限を待たず、取り合いとして返る")
    func overwrittenAfterItWasAnswered() throws {
        let (facets, directory) = makeFacets()
        defer { try? FileManager.default.removeItem(at: directory) }
        let facet = facets.observeFacet
        let clock = FakeClock()
        clock.actions[1] = {
            put(#"{"id":"mine"}"#, at: reportURL(facet))
            put(#"{"id":"theirs"}"#, at: requestURL(facet))
            put(#"{"id":"theirs"}"#, at: reportURL(facet))
        }
        guard case .contested = try exchange(facets, facet: facet, clock: clock) else {
            Issue.record("取り合いとして返らなかった")
            return
        }
        #expect(clock.ticks == 1, "期限まで待った: \(clock.ticks) 刻み")
    }

    /// (b) 読まれる前に置き換えられた。置き換えた側の応答が書かれるまでは、まだ判断しない。
    @Test("読まれる前に置き換えられた回 (b): 置き換えた側の応答が書かれた時点で取り合いとして返る")
    func replacedBeforeItWasRead() throws {
        let (facets, directory) = makeFacets()
        defer { try? FileManager.default.removeItem(at: directory) }
        let facet = facets.observeFacet
        let clock = FakeClock()
        clock.actions[1] = { put(#"{"id":"theirs"}"#, at: requestURL(facet)) }
        clock.actions[3] = { put(#"{"id":"theirs"}"#, at: reportURL(facet)) }
        guard case .contested = try exchange(facets, facet: facet, clock: clock) else {
            Issue.record("取り合いとして返らなかった")
            return
        }
        #expect(clock.ticks == 3, "置き換えられただけで見切った・または遅れた: \(clock.ticks) 刻み")
    }

    /// 早まらない 1: 別の識別子の応答が (前の取り合いの名残りとして) 見えても、request.json がまだ
    /// 自分の要求なら待つ。
    @Test("request.json がまだ自分の要求なら、別の識別子の応答が見えても待ち続け、自分の応答を返す")
    func doesNotGiveUpWhileTheRequestIsStillMine() throws {
        let (facets, directory) = makeFacets()
        defer { try? FileManager.default.removeItem(at: directory) }
        let facet = facets.observeFacet
        try FileManager.default.createDirectory(at: facet, withIntermediateDirectories: true)
        put(#"{"id":"theirs"}"#, at: reportURL(facet))
        let clock = FakeClock()
        clock.actions[2] = { put(#"{"id":"mine"}"#, at: reportURL(facet)) }
        guard case .answered(let report) = try exchange(facets, facet: facet, clock: clock) else {
            Issue.record("自分の応答を返さなかった")
            return
        }
        #expect(report["id"] as? String == "mine")
        #expect(clock.ticks == 2)
    }

    /// 早まらない 2: request.json が置き換わっていても、応答がまだ置き換えた側を echo していない間は待つ。
    /// 期限が来たら、置き換わっていたことを添えて諦める。
    @Test("置き換わっていても、応答がその要求を echo しない間は待ち、期限で置き換わっていたと返る")
    func waitsUntilTheReplacerIsAnswered() throws {
        let (facets, directory) = makeFacets(waitLimit: 5)
        defer { try? FileManager.default.removeItem(at: directory) }
        let facet = facets.observeFacet
        try FileManager.default.createDirectory(at: facet, withIntermediateDirectories: true)
        put(#"{"id":"older"}"#, at: reportURL(facet))
        let clock = FakeClock()
        clock.actions[1] = { put(#"{"id":"theirs"}"#, at: requestURL(facet)) }
        guard case .timedOut(let replaced) = try exchange(facets, facet: facet, clock: clock) else {
            Issue.record("期限で諦めなかった")
            return
        }
        #expect(replaced, "置き換わっていたことを言わない")
        #expect(clock.ticks == 5, "上限の 5 刻みまで待っていない: \(clock.ticks)")
    }

    @Test("自分の要求のまま期限が来たら、置き換わっていたとは言わない")
    func timesOutPlainlyWhenNobodyReplacedTheRequest() throws {
        let (facets, directory) = makeFacets(waitLimit: 3)
        defer { try? FileManager.default.removeItem(at: directory) }
        let facet = facets.observeFacet
        guard case .timedOut(let replaced) = try exchange(facets, facet: facet, clock: FakeClock()) else {
            Issue.record("期限で諦めなかった")
            return
        }
        #expect(!replaced)
    }

    /// b1 の後にすぐ b2 が置かれて、自分には `report=b1`・`request=b2` しか見えない。**直前の応答と
    /// 自分の応答のどちらでもない応答が見え、request.json が自分のものでなければ、取り合い**
    /// (応答の識別子と request.json の識別子が一致しなくてよい)。
    @Test("別の書き手の応答 b1 の後に b2 が置かれても、見逃さず取り合いとして返す")
    func aLaterRequestByTheOtherWriterIsNotMissed() throws {
        let (facets, directory) = makeFacets()
        defer { try? FileManager.default.removeItem(at: directory) }
        let facet = facets.observeFacet
        try FileManager.default.createDirectory(at: facet, withIntermediateDirectories: true)
        put(#"{"id":"before"}"#, at: reportURL(facet))
        let clock = FakeClock()
        clock.actions[1] = {
            put(#"{"id":"b2"}"#, at: requestURL(facet))
            put(#"{"id":"b1"}"#, at: reportURL(facet))
        }
        guard case .contested = try exchange(facets, facet: facet, clock: clock) else {
            Issue.record("b1 → b2 の並びを見逃した")
            return
        }
        #expect(clock.ticks == 1)
    }

    /// 置く直前の応答が見えているだけでは、何も起きていない。
    @Test("置く直前の応答が見えているだけなら、request.json が置き換わっていても待ち続ける")
    func theEchoFromBeforeIsNotAContest() throws {
        let (facets, directory) = makeFacets(waitLimit: 3)
        defer { try? FileManager.default.removeItem(at: directory) }
        let facet = facets.observeFacet
        try FileManager.default.createDirectory(at: facet, withIntermediateDirectories: true)
        put(#"{"id":"before"}"#, at: reportURL(facet))
        let clock = FakeClock()
        clock.actions[1] = { put(#"{"id":"b2"}"#, at: requestURL(facet)) }
        guard case .timedOut(let replaced) = try exchange(facets, facet: facet, clock: clock) else {
            Issue.record("直前の応答だけで見切った")
            return
        }
        #expect(replaced)
        #expect(clock.ticks == 3)
    }

    /// 崩れた中身 (原子的に置かない書き手) の request.json は、自分の要求ではない。応答が別の識別子を
    /// echo すれば取り合い、echo しなければ期限で「置き換わっていた」と返る。
    @Test("壊れた request.json は自分の要求ではない: 別の応答が現れれば取り合い、現れなければ置き換わっていたと返る")
    func aBrokenRequestIsNotMine() throws {
        do {
            let (facets, directory) = makeFacets(waitLimit: 4)
            defer { try? FileManager.default.removeItem(at: directory) }
            let facet = facets.observeFacet
            let clock = FakeClock()
            clock.actions[1] = {
                put("{not json", at: requestURL(facet))
                put(#"{"id":"theirs"}"#, at: reportURL(facet))
            }
            guard case .contested = try exchange(facets, facet: facet, clock: clock) else {
                Issue.record("壊れた要求で上書きされたのに、取り合いとして返らなかった")
                return
            }
        }
        for broken in ["{not json", #"{"events":[]}"#] {
            let (facets, directory) = makeFacets(waitLimit: 4)
            defer { try? FileManager.default.removeItem(at: directory) }
            let facet = facets.observeFacet
            let clock = FakeClock()
            clock.actions[1] = { put(broken, at: requestURL(facet)) }
            guard case .timedOut(let replaced) = try exchange(facets, facet: facet, clock: clock) else {
                Issue.record("期限で諦めなかった (\(broken))")
                return
            }
            #expect(replaced, "識別子の無い・壊れた要求への置き換えを、置き換えと数えない (\(broken))")
            #expect(clock.ticks == 4)
        }
    }

    /// request.json が無い・読めない回は判定を飛ばす (応答がどうでも決着にしない)。
    @Test("request.json が無ければ判定を飛ばして待ち続ける")
    func aMissingRequestSkipsTheJudgement() throws {
        let (facets, directory) = makeFacets(waitLimit: 3)
        defer { try? FileManager.default.removeItem(at: directory) }
        let facet = facets.observeFacet
        let clock = FakeClock()
        clock.actions[1] = {
            try? FileManager.default.removeItem(at: requestURL(facet))
            put(#"{"id":"theirs"}"#, at: reportURL(facet))
        }
        guard case .timedOut(let replaced) = try exchange(facets, facet: facet, clock: clock) else {
            Issue.record("要求が無いのに見切った")
            return
        }
        #expect(!replaced)
    }

    // MARK: - 窓口の答え (Tools)

    /// 区画の書き換えを、窓口が待っている間に別の糸から行う。**終わりの姿だけを一度に置く**
    /// (要求を置き換え、その応答が書かれた後の姿) ので、読み手がどの瞬間に見ても取りこぼさない。
    private func contendedCall(
        tool: String, arguments: [String: Any], facet: (Facets) -> URL
    ) throws -> (outcome: (text: String, isError: Bool), seconds: Double) {
        let (facets, directory) = makeFacets()
        defer { try? FileManager.default.removeItem(at: directory) }
        let place = facet(facets)
        let tools = Tools(facets: facets, makeID: { "mine" })
        let finished = DispatchSemaphore(value: 0)
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.3) {
            put(#"{"id":"theirs","events":[]}"#, at: requestURL(place))
            put(#"{"id":"theirs"}"#, at: reportURL(place))
            finished.signal()
        }
        let started = ContinuousClock.now
        let outcome = tools.call(tool, arguments: arguments)
        let elapsed = ContinuousClock.now - started
        _ = finished.wait(timeout: .now() + 5)
        let parts = elapsed.components
        return (outcome, Double(parts.seconds) + Double(parts.attoseconds) * 1e-18)
    }

    private func put(_ json: String, at url: URL) {
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? Data(json.utf8).write(to: url, options: .atomic)
    }

    @Test("入力: 別の書き手に置き換えられたら、期限を待たず、取り合ったことと次の手を言う")
    func inputSaysItWasContested() throws {
        let result = try contendedCall(
            tool: "input", arguments: ["events": [["type": "key"]]], facet: { $0.inputFacet })
        #expect(result.seconds < 4, "期限まで待った: \(result.seconds) 秒")
        #expect(result.outcome.isError)
        let text = result.outcome.text
        #expect(text.contains("Another writer"), "取り合ったと言わない: \(text)")
        #expect(text.contains("observe"), "次の手 (observe で確かめる) を言わない: \(text)")
        #expect(!text.contains("did not answer"), "応えなかったと偽った: \(text)")
        #expect(!text.contains("Restart"), "直らない起動し直しへ送った: \(text)")
    }

    @Test("期限で諦めた回に別の書き手が置き換えていたら、その 1 文を応えなかった案内の前に足す")
    func aTimedOutCallSaysTheRequestWasReplaced() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("mokume-facets-contested-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let facets = Facets(directory: directory, waitLimit: 0.4)
        let place = facets.inputFacet
        let tools = Tools(facets: facets, makeID: { "mine" })
        // 置く前から、前の書き手への応答が残っている
        put(#"{"id":"older"}"#, at: reportURL(place))
        let finished = DispatchSemaphore(value: 0)
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.1) {
            // 要求は置き換わったが、応答は前のまま動かない
            put(#"{"id":"theirs","events":[]}"#, at: requestURL(place))
            finished.signal()
        }
        let outcome = tools.call("input", arguments: ["events": [["type": "key"]]])
        _ = finished.wait(timeout: .now() + 5)
        #expect(outcome.isError)
        #expect(outcome.text.hasPrefix("Another writer replaced this request"))
        // 置き換えられたと分かっているのに、走っていないとは言わず、起動し直しへ送らない
        #expect(!outcome.text.contains("did not answer"), "走っていないと偽った: \(outcome.text)")
        #expect(!outcome.text.contains("Restart"), "直らない起動し直しへ送った: \(outcome.text)")
        #expect(!outcome.text.contains("watch"), "起動し直しを勧めた: \(outcome.text)")
        #expect(outcome.text.contains("observe"), "次の手を言わない: \(outcome.text)")
        #expect(outcome.text.contains("may be busy"), "長い列の観測の最中でありうると言わない: \(outcome.text)")
    }

    /// `time` 付きの観測は 1 フレームを描き直して副作用を残す。撮り直してよいとは言わない。
    @Test("time 付きの観測は、撮り直してよいと言わず、確かめてからと言う")
    func aTimedObservationIsNotSaidToBeSafeToRepeat() throws {
        let result = try contendedCall(
            tool: "observe", arguments: ["time": 1.5], facet: { $0.observeFacet })
        #expect(result.outcome.isError)
        let text = result.outcome.text
        #expect(text.contains("Another writer"), "取り合ったと言わない: \(text)")
        #expect(!text.contains("is safe"), "撮り直してよいと言った: \(text)")
        #expect(text.contains("without time"), "確かめてからと言わない: \(text)")
    }

    @Test("観測: 同じく取り合ったことを言い、撮り直してよいと添える")
    func observeSaysItWasContested() throws {
        let result = try contendedCall(tool: "observe", arguments: [:], facet: { $0.observeFacet })
        #expect(result.seconds < 4, "期限まで待った: \(result.seconds) 秒")
        #expect(result.outcome.isError)
        let text = result.outcome.text
        #expect(text.contains("Another writer"), "取り合ったと言わない: \(text)")
        #expect(text.contains("again"), "撮り直してよいと言わない: \(text)")
        #expect(!text.contains("did not answer"), "応えなかったと偽った: \(text)")
        #expect(!text.contains("Restart"), "直らない起動し直しへ送った: \(text)")
    }
}
