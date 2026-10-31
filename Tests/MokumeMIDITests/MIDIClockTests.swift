// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Darwin
import Foundation
import Testing

@testable import MokumeCore
@testable import MokumeMIDI

/// 受けた MIDI クロックから拍を数える (#3591)。CoreMIDI にも GPU にも触れない。
///
/// 拍の数え方は MIDI 1.0 の仕様どおり: 24 クロックで 1 拍・開始で 0・停止で止まり・再開で続き・曲の位置は
/// 止めている間の位置。**入力 → 結果をそのまま**書く。
@Suite("MIDI クロックから数える拍")
struct MIDIClockTests {
    private static let clocks = { (count: Int) in [MIDIMessage](repeating: .clock, count: count) }

    // MARK: - 状態機械

    @Test("24 個目のクロックで拍が 0 から 1 に、48 個目で 2 に変わる")
    func twentyFourClocksMakeABeat() {
        var clock = MIDIClock()
        var beats: [Int] = []
        for _ in 0..<49 {
            clock.apply(.clock)
            beats.append(clock.beat)
        }
        #expect(beats[22] == 0 && beats[23] == 1, "24 個目 (添字 23) で 1")
        #expect(beats[46] == 1 && beats[47] == 2, "48 個目 (添字 47) で 2")
        #expect(beats[48] == 2)
    }

    @Test("開始で数えたクロックを 0 に戻し、数え直す")
    func startResets() {
        var clock = MIDIClock()
        Self.clocks(24 * 3 + 5).forEach { clock.apply($0) }
        #expect(clock.beat == 3)
        clock.apply(.start)
        #expect(clock.beat == 0 && clock.count == 0 && clock.isRunning)
        Self.clocks(24).forEach { clock.apply($0) }
        #expect(clock.beat == 1)
    }

    @Test("停止の後に届くクロックは拍を進めず、再開で止めた位置から続ける")
    func stopAndContinue() {
        var clock = MIDIClock()
        Self.clocks(30).forEach { clock.apply($0) }
        clock.apply(.stop)
        // 機材は止めている間もクロックを送り続けることがある
        Self.clocks(100).forEach { clock.apply($0) }
        #expect(clock.beat == 1 && clock.count == 30)
        clock.apply(.continue)
        Self.clocks(18).forEach { clock.apply($0) }
        #expect(clock.count == 48 && clock.beat == 2, "止めた位置 (30) から 18 個で 48")
    }

    @Test("止めている間に曲の位置 8 (16 分音符 8 つ = 48 クロック) が届いて再開すると、拍は 2 から数える")
    func songPositionThenContinue() {
        var clock = MIDIClock()
        Self.clocks(24 * 3).forEach { clock.apply($0) }
        clock.apply(.stop)
        clock.apply(.songPosition(sixteenths: 8))
        #expect(clock.count == 48 && clock.beat == 2)
        clock.apply(.continue)
        #expect(clock.beat == 2)
        Self.clocks(24).forEach { clock.apply($0) }
        #expect(clock.beat == 3)
    }

    @Test("最初の開始が届く前は走っているとして数える。停止の後だけ止まる")
    func runningUntilStopped() {
        var clock = MIDIClock()
        #expect(clock.isRunning)
        Self.clocks(24).forEach { clock.apply($0) }
        #expect(clock.beat == 1)
        clock.apply(.stop)
        #expect(!clock.isRunning)
    }

    @Test("ノートとコントロールチェンジは拍に関わらず、状態は変わらない。拍に関わるものは変わりうると答える")
    func onlyTimingMessagesTouchTheClock() {
        var clock = MIDIClock()
        Self.clocks(10).forEach { clock.apply($0) }
        let before = clock
        let changed = [
            clock.apply(.noteOn(channel: 1, note: 60, velocity: 1)),
            clock.apply(.noteOff(channel: 1, note: 60, velocity: 0)),
            clock.apply(.controlChange(channel: 1, controller: 1, value: 1)),
        ]
        #expect(changed == [false, false, false])
        #expect(clock == before)
        var timing: [Bool] = []
        for message in [MIDIMessage.clock, .start, .stop, .continue, .songPosition(sixteenths: 1)] {
            timing.append(clock.apply(message))
        }
        #expect(timing == [true, true, true, true, true])
    }

    // MARK: - 入り口 (記録した列)

    private func port(_ frames: [[MIDIMessage]?], capacity: Int = 4096) throws -> MIDIPort {
        let port = MIDIPort(
            id: "recorded", name: "midi (recorded)", source: RecordedMIDISource(frames: frames),
            capacity: capacity)
        try port.open()
        return port
    }

    /// 1 フレームずつ進め、そのフレームの拍を並べる。
    private func beats(_ port: MIDIPort, _ count: Int) -> [Int] {
        (0..<count).map { _ in
            port.supply()
            return port.beat
        }
    }

    /// 拍が変わったフレームの番号。
    private func changes(_ beats: [Int]) -> [Int] {
        beats.indices.dropFirst().filter { beats[$0] != beats[$0 - 1] }
    }

    @Test("開始の後に 1 フレーム 1 クロックを注入すると、拍は 24 フレーム目に 1、48 フレーム目に 2 になる")
    func oneClockPerFrame() throws {
        let frames: [[MIDIMessage]?] = [[.start]] + (1..<73).map { _ in [.clock] }
        let seen = beats(try port(frames), 73)
        #expect(changes(seen) == [24, 48, 72])
        #expect(seen[0] == 0 && seen[23] == 0 && seen[24] == 1 && seen[47] == 1 && seen[48] == 2)
    }

    @Test("同じ列を 2 度回すと、同じフレームに同じ拍が出る")
    func sameSequenceSameBeats() throws {
        let frames: [[MIDIMessage]?] = [[.start]] + (1..<50).map { _ in [.clock] }
        #expect(try beats(port(frames), 100) == beats(port(frames), 100))
    }

    @Test("クロックを 1 フレームに 2 つずつにすると、拍の切り替わりの間隔が 24 フレームから 12 フレームになる")
    func tempoFollows() throws {
        let slow: [[MIDIMessage]?] = [[.start]] + (1..<73).map { _ in [.clock] }
        let fast: [[MIDIMessage]?] = [[.start]] + (1..<73).map { _ in [.clock, .clock] }
        let slowChanges = changes(beats(try port(slow), 73))
        let fastChanges = changes(beats(try port(fast), 73))
        #expect(slowChanges.adjacentDifferences == [24, 24])
        #expect(fastChanges.adjacentDifferences.allSatisfy { $0 == 12 })
        #expect(fastChanges.count >= 5)
    }

    @Test("拍が 3 になった後に開始を注入すると、そのフレームで 0 に戻り、数え直す")
    func startRestartsTheCount() throws {
        // 0 フレーム目に開始、72 個のクロックで拍 3。73 フレーム目に開始、その後に 24 個
        let frames: [[MIDIMessage]?] =
            [[.start]] + (0..<72).map { _ in [.clock] } + [[.start]] + (0..<24).map { _ in [.clock] }
        let seen = beats(try port(frames), frames.count)
        #expect(seen[72] == 3)
        #expect(seen[73] == 0, "開始が届いたフレームで 0 に戻る")
        #expect(seen.last == 1)
    }

    @Test("停止の後のクロックは拍を進めず、再開の後は止めた位置から続く")
    func stopThenContinue() throws {
        let frames: [[MIDIMessage]?] =
            [[.start]] + (0..<30).map { _ in [.clock] } + [[.stop]] + (0..<30).map { _ in [.clock] } + [[.continue]]
            + (0..<18).map { _ in [.clock] }
        let seen = beats(try port(frames), frames.count)
        #expect(seen[30] == 1 && seen[31] == 1, "停止した後も 1 のまま")
        #expect(seen[61] == 1 && seen[62] == 1, "止めている間の 30 個は数えない")
        #expect(seen.last == 2, "止めた位置 (30) から 18 個で 48 = 拍 2")
    }

    @Test("止めている間の曲の位置 8 と再開で、拍は 2 から数える")
    func songPositionMovesTheStoppedPosition() throws {
        let frames: [[MIDIMessage]?] = [
            [.start], [.stop], [.songPosition(sixteenths: 8)], [.continue], [.clock],
        ]
        let seen = beats(try port(frames), frames.count)
        #expect(seen == [0, 0, 2, 2, 2])
    }

    @Test("1 フレームに開始・クロック・曲の位置が重なっても、届いた順に数えた結果がそのフレームの拍になる")
    func severalInOneFrame() throws {
        let frame: [MIDIMessage] = [.start] + Self.clocks(24) + [.stop, .songPosition(sixteenths: 4), .continue]
        let port = try port([frame, Self.clocks(24)])
        port.supply()
        #expect(port.beat == 1, "曲の位置 4 = 24 クロック = 拍 1")
        port.supply()
        #expect(port.beat == 2)
    }

    @Test("クロックは拍を進めるだけで出来事の列に入らない。開始・停止・再開・曲の位置は届いた順に入る")
    func clocksAreNotListedButTransportIs() throws {
        let note = MIDIMessage.noteOn(channel: 1, note: 60, velocity: 100)
        let frame: [MIDIMessage] = [
            .start, .clock, note, .clock, .stop, .songPosition(sixteenths: 8), .continue, .clock,
        ]
        let port = try port([frame])
        port.supply()
        #expect(port.messages == [.start, note, .stop, .songPosition(sixteenths: 8), .continue])
        #expect(port.beat == 2)
    }

    @Test("クロックを大量に流しても、出来事の列の上限を薄めない (捨てた数は増えない)")
    func clocksDoNotFillTheQueue() throws {
        let port = try port([Self.clocks(500)], capacity: 4)
        port.supply()
        #expect(port.messages.isEmpty)
        #expect(port.inbox.messages.overflowed == 0)
        #expect(port.beat == 20)
    }

    @Test("何も届いていないうちの拍は 0。ノートとコントロールチェンジだけでは動かない")
    func beatIsZeroWithoutClock() throws {
        let port = try port([[.noteOn(channel: 1, note: 60, velocity: 1)], [.controlChange(channel: 1, controller: 1, value: 5)]])
        #expect(port.beat == 0)
        #expect(beats(port, 2) == [0, 0])
    }

    @Test("拍は届いた後の最初のフレームに割り当てられ、名乗りの最後に届いたフレームに載る (#2603 の記録の土台)")
    func clocksAreAssignedToTheNextFrame() throws {
        let port = try port([[], [.clock], []])
        port.supply()
        #expect(port.report?.lastArrival == nil)
        port.supply()
        #expect(port.report?.lastArrival != nil)
        let arrival = try #require(port.report?.lastArrival)
        #expect(arrival.hostTime > 0)
        port.supply()
        #expect(port.report?.lastArrival == arrival, "届かなかったフレームでは動かない")
    }

    @Test("外して足し直しても、数えた拍は戻る。外していた間に届いたものは当てない")
    func closeAndReopenKeepsTheBeat() throws {
        let frames: [[MIDIMessage]?] = [[.start] + Self.clocks(30), Self.clocks(24)]
        let port = try port(frames)
        port.supply()
        #expect(port.beat == 1)
        port.close()
        #expect(port.state == .stopped)
        try port.open()
        // 足し直した最初のフレームは列の次 (2 番目): 30 + 24 = 54 クロック
        port.supply()
        #expect(port.beat == 2)
    }

    @Test("抜かれている間は数えず、抜く前の拍は残る")
    func unplugKeepsTheBeat() throws {
        let frames: [[MIDIMessage]?] = [[.start] + Self.clocks(48), nil, Self.clocks(24)]
        let seen = beats(try port(frames), 3)
        #expect(seen == [2, 2, 3])
    }

    @Test("範囲に収まらない曲の位置は、列にも拍にも入らず、読めずに捨てたと数える")
    func invalidSongPositionIsDiscarded() throws {
        let port = try port([[.start] + Self.clocks(24) + [.songPosition(sixteenths: 16384), .songPosition(sixteenths: -1)]])
        port.supply()
        #expect(port.beat == 1)
        #expect(port.messages == [.start], "クロックは列に入らない")
        #expect(port.inbox.messages.unreadable == 2)
    }

    @Test("走っている間に曲の位置が届いても、位置を置く")
    func songPositionWhileRunning() throws {
        let frames: [[MIDIMessage]?] = [[.start] + Self.clocks(72), [.songPosition(sixteenths: 8)], Self.clocks(24)]
        #expect(beats(try port(frames), 3) == [3, 2, 3])
    }

    // MARK: - 実機の配線 (偽の CoreMIDI)

    @Test("実機から届いた語も、同じ入れ物を通って同じ拍になる。拍に関わらない種類は数えずに読み飛ばす")
    func deviceWordsMakeTheSameBeat() throws {
        let backend = FakeMIDIBackend()
        backend.current = [FakeMIDIBackend.source(1, "Deck")]
        let hub = MIDIHub(backend: backend)
        hub.start()
        let port = MIDIPort(id: "Deck #1", name: "midi: Deck #1", source: DeviceSource(id: "Deck #1", hub: hub))
        try port.open()

        backend.deliver(1, [0x10FA_0000])  // 開始
        backend.deliver(1, [UInt32](repeating: 0x10F8_0000, count: 24))
        backend.deliver(1, [0x10FE_0000])  // アクティブセンシング
        port.supply()
        #expect(port.beat == 1)
        #expect(port.inbox.messages.unreadable == 0)

        backend.deliver(1, [0x10FC_0000, 0x10F2_0800, 0x10FB_0000])  // 停止・位置 8・再開
        port.supply()
        #expect(port.beat == 2)
    }

    @Test("後から作った入り口・足し直した入り口は、作る前から数えていた拍を読める")
    func lateSubscribersSeeTheBeat() throws {
        let backend = FakeMIDIBackend()
        backend.current = [FakeMIDIBackend.source(1, "Deck")]
        let hub = MIDIHub(backend: backend)
        hub.start()
        // 入り口が 1 つも無い間に、4 拍ぶん数える
        backend.deliver(1, [0x10FA_0000] + [UInt32](repeating: 0x10F8_0000, count: 24 * 4))
        func open() throws -> MIDIPort {
            let port = MIDIPort(id: "Deck #1", name: "midi: Deck #1", source: DeviceSource(id: "Deck #1", hub: hub))
            try port.open()
            return port
        }
        let late = try open()
        late.supply()
        #expect(late.beat == 4, "作り直した直後に拍が 0 へ戻らない")

        // 外している間に届いた分も、足し直した入り口に戻る
        late.close()
        backend.deliver(1, [UInt32](repeating: 0x10F8_0000, count: 24))
        try late.open()
        late.supply()
        #expect(late.beat == 5)
        let fresh = try open()
        #expect(fresh.beat == 0, "作っただけでは supply() するまで読めない")
        fresh.supply()
        #expect(fresh.beat == 5)
    }

    @Test("外している間に開始が届いて数えたクロックが 0 に戻っても、足し直した入り口の拍は古い値のまま残らない")
    func reattachedPortAdoptsAStartThatEqualsTheDefault() throws {
        let backend = FakeMIDIBackend()
        backend.current = [FakeMIDIBackend.source(1, "Deck")]
        let hub = MIDIHub(backend: backend)
        hub.start()
        let port = MIDIPort(id: "Deck #1", name: "midi: Deck #1", source: DeviceSource(id: "Deck #1", hub: hub))
        try port.open()
        backend.deliver(1, [UInt32](repeating: 0x10F8_0000, count: 48))
        port.supply()
        #expect(port.beat == 2)

        port.close()
        backend.deliver(1, [0x10FA_0000])  // 開始: 数えたクロック 0・走行中 (既定値と同じ)
        try port.open()
        port.supply()
        #expect(port.beat == 0, "外す前の拍 2 が残った")
        backend.deliver(1, [UInt32](repeating: 0x10F8_0000, count: 24))
        port.supply()
        #expect(port.beat == 1)
    }

    @Test("クロックを一度も受けていない機材では、足し直した入り口に拍を渡さない (名乗りの最後に届いたフレームが付かない)")
    func noClockNoAdoption() throws {
        let backend = FakeMIDIBackend()
        backend.current = [FakeMIDIBackend.source(1, "Deck")]
        let hub = MIDIHub(backend: backend)
        hub.start()
        let port = MIDIPort(id: "Deck #1", name: "midi: Deck #1", source: DeviceSource(id: "Deck #1", hub: hub))
        try port.open()
        backend.deliver(1, [0x2090_3C64])
        port.supply()
        #expect(port.inbox.clock.lastArrival == nil)
    }

    @Test("外していた間に進めたフレームの拍に関わるメッセージは、記録の入り口でも数える (実機の中継と同じ拍)")
    func recordedPortCountsSkippedFrames() throws {
        // 持ち主の無い入り口は位置を進めない (``DetachedFrames``) ので、飛ばす数を入れ物へ直に渡して見る
        let inbox = MIDIInbox(name: "recorded", state: .running)
        let skipped: [MIDIMessage] =
            [.start] + Self.clocks(30) + [.stop] + Self.clocks(10) + [.continue] + Self.clocks(18)
            + [.noteOn(channel: 1, note: 60, velocity: 1), .controlChange(channel: 1, controller: 1, value: 5)]
        inbox.advanceClock(through: skipped)
        let taken = inbox.take()
        #expect(taken.clock?.beat == 2, "止めた位置 30 から 18 個で 48")
        #expect(taken.messages.isEmpty, "出来事は届かない (外していた間のもの)")
        #expect(taken.controllers == nil)
    }
}

extension Array where Element == Int {
    /// 隣り合う要素の差。
    fileprivate var adjacentDifferences: [Int] { zip(self, dropFirst()).map { $1 - $0 } }
}
