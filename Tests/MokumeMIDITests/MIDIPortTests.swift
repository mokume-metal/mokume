// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Testing

@testable import MokumeCore
@testable import MokumeMIDI

/// 記録したメッセージの列で、MIDI 入力の入り口を回す (ADR-0028 決定 6)。機材も GPU も要らない。
///
/// 入り口の口 (``MIDIPort/open()`` / ``MIDIPort/supply()``) を直に呼ぶ。走っているスケッチの中で同じことが
/// 起きるのは ``MIDISketchTests`` が見る。
@Suite("MIDI の入り口 (記録した列)")
struct MIDIPortTests {
    private func port(_ frames: [[MIDIMessage]?], capacity: Int = 4096) throws -> MIDIPort {
        let port = MIDIPort(
            id: "recorded", name: "midi (recorded)", source: RecordedMIDISource(frames: frames),
            capacity: capacity)
        try port.open()
        return port
    }

    /// 1 フレームずつ進め、そのフレームの値を写す。
    private func frames(_ port: MIDIPort, _ count: Int, cc: Int = 1)
        -> [(messages: [MIDIMessage], cc: Float?, state: SourceState)]
    {
        (0..<count).map { _ in
            port.supply()
            return (port.messages, port.controlChange(cc), port.state)
        }
    }

    private static let on60 = MIDIMessage.noteOn(channel: 1, note: 60, velocity: 100)
    private static let off60 = MIDIMessage.noteOff(channel: 1, note: 60, velocity: 0)
    private static func cc(_ value: Int, channel: Int = 1, controller: Int = 1) -> MIDIMessage {
        .controlChange(channel: channel, controller: controller, value: value)
    }

    @Test("i 番目のフレームに i 番目の組が入り、最後まで行けば最初に戻る")
    func messagesArriveInOrder() throws {
        let seen = frames(try port([[Self.on60], [], [Self.off60]]), 4)
        #expect(seen.map(\.messages) == [[Self.on60], [], [Self.off60], [Self.on60]])
        #expect(seen.allSatisfy { $0.state == .running })
    }

    @Test("1 フレームに届いたノートオン・ノートオフ・CC は、届いた順に全部入る")
    func oneFrameKeepsEverythingInOrder() throws {
        let frame = [Self.on60, Self.off60, Self.cc(64)]
        let seen = frames(try port([frame]), 1)
        #expect(seen[0].messages == frame)
    }

    @Test("同じ列を 2 度回すと、同じフレームに同じ結果が出る")
    func sameFramesSameResult() throws {
        let recorded: [[MIDIMessage]?] = [[Self.cc(10)], nil, [Self.on60, Self.cc(127, channel: 2)]]
        func record() throws -> [String] {
            frames(try port(recorded), 7).map { "\($0.messages) \(String(describing: $0.cc)) \($0.state)" }
        }
        #expect(try record() == record())
    }

    // MARK: - コントロールチェンジの現在値

    @Test("CC の現在値は 0〜1 に写り、届くまでは nil。127 が 1")
    func currentValue() throws {
        let seen = frames(try port([[], [Self.cc(0)], [Self.cc(127)], [Self.cc(64)]]), 4)
        #expect(seen.map(\.cc) == [nil, 0, 1, 64.0 / 127])
    }

    @Test("値は、次の CC が届くまで残る。動いていない番号は nil のまま")
    func valueStaysUntilTheNextOne() throws {
        let seen = frames(try port([[Self.cc(127)], [], []]), 3)
        #expect(seen.map(\.cc) == [1, 1, 1])
        let other = frames(try port([[Self.cc(127)]]), 1, cc: 2)
        #expect(other[0].cc == nil)
    }

    @Test("チャンネルを省くと、どのチャンネルでも最後に届いた値。渡すとそのチャンネルの値")
    func anyChannelOrOne() throws {
        let port = try port([[Self.cc(10, channel: 1), Self.cc(100, channel: 2)]])
        port.supply()
        #expect(port.controlChange(1) == 100.0 / 127)
        #expect(port.controlChange(1, channel: 1) == 10.0 / 127)
        #expect(port.controlChange(1, channel: 2) == 100.0 / 127)
        #expect(port.controlChange(1, channel: 3) == nil)
    }

    @Test("範囲の外のコントローラ・チャンネルを訊かれたら nil (落ちない)")
    func outOfRangeQuestions() throws {
        let port = try port([[Self.cc(1)]])
        port.supply()
        #expect(port.controlChange(-1) == nil)
        #expect(port.controlChange(128) == nil)
        #expect(port.controlChange(1, channel: 0) == nil)
        #expect(port.controlChange(1, channel: 17) == nil)
    }

    @Test("1 フレームに別々のつまみが動いても、どちらの最新も読める")
    func twoControllersInOneFrame() throws {
        let port = try port([[Self.cc(10, controller: 1), Self.cc(20, controller: 2)]])
        port.supply()
        #expect(port.controlChange(1) == 10.0 / 127)
        #expect(port.controlChange(2) == 20.0 / 127)
    }

    // MARK: - 上限と読めないもの

    @Test("列が上限で古い出来事を捨てても、CC の現在値は最新のまま。捨てた数が数えられる")
    func overflowKeepsTheCurrentValue() throws {
        // 上限 2。先頭の CC は列から捨てられるが、現在値の入れ物には入っている
        let frame: [MIDIMessage] = [Self.cc(127), Self.on60, Self.off60, Self.on60]
        let port = try port([frame], capacity: 2)
        port.supply()
        #expect(port.messages == [Self.off60, Self.on60])
        #expect(port.controlChange(1) == 1)
        #expect(port.inbox.messages.overflowed == 2)
    }

    @Test("範囲に収まらないメッセージは、列にも現在値にも入らず、読めずに捨てたと数える")
    func invalidMessagesAreCounted() throws {
        let bad: [MIDIMessage] = [
            .noteOn(channel: 0, note: 60, velocity: 1), .noteOn(channel: 17, note: 60, velocity: 1),
            .noteOff(channel: 1, note: 128, velocity: 0), Self.cc(-1), Self.cc(128, controller: 3),
        ]
        let port = try port([bad + [Self.cc(5)]])
        port.supply()
        #expect(port.messages == [Self.cc(5)])
        #expect(port.controlChange(3) == nil)
        #expect(port.inbox.messages.unreadable == 5)
    }

    // MARK: - 抜かれる

    @Test("抜かれると切断を名乗り、押していたノートは離れる。CC の現在値は残り、挿し直すと戻る")
    func unplugAndReplug() throws {
        let seen = frames(try port([[Self.cc(127), Self.on60], nil, nil, [Self.on60]]), 4)
        #expect(seen.map(\.state) == [.running, .disconnected, .disconnected, .running])
        // 抜かれたフレームに、押していたノートの離しが入る。2 度目の nil では増えない
        #expect(seen[1].messages == [.noteOff(channel: 1, note: 60, velocity: 0)])
        #expect(seen[2].messages == [])
        #expect(seen.map(\.cc) == [1, 1, 1, 1])
    }

    @Test("離す出来事は、押していた全部に、チャンネルとノートの順で入る")
    func unplugReleasesEveryHeldNote() throws {
        let held: [MIDIMessage] = [
            .noteOn(channel: 2, note: 40, velocity: 1), .noteOn(channel: 1, note: 64, velocity: 1),
            .noteOn(channel: 1, note: 60, velocity: 1), .noteOn(channel: 1, note: 62, velocity: 1),
            .noteOff(channel: 1, note: 62, velocity: 0),
        ]
        let seen = frames(try port([held, nil]), 2)
        #expect(
            seen[1].messages == [
                .noteOff(channel: 1, note: 60, velocity: 0), .noteOff(channel: 1, note: 64, velocity: 0),
                .noteOff(channel: 2, note: 40, velocity: 0),
            ])
    }

    @Test("観測の応答の名乗りに、状態と最後に届いたフレームが載る")
    func reportsState() throws {
        let port = try port([[Self.cc(1)], nil])
        port.supply()
        #expect(port.report?.state == .running)
        #expect(port.report?.lastArrival != nil)
        port.supply()
        #expect(port.report?.state == .disconnected)
    }

    @Test("空の列は unavailable のまま、何も入らない")
    func emptyRecording() throws {
        let seen = frames(try port([]), 2)
        #expect(seen.allSatisfy { $0.messages.isEmpty && $0.state == .unavailable })
    }

    // MARK: - 外す・足し直す

    @Test("外すと stopped になり、読まれなかった出来事は捨てられる。足し直すと現在値が戻る")
    func closeAndReopen() throws {
        let port = try port([[Self.cc(64)], [Self.on60]])
        port.supply()
        port.close()
        #expect(port.state == .stopped)
        #expect(port.messages.isEmpty)
        try port.open()
        #expect(port.state == .running)
        port.supply()
        // 外す前に届いて読まれなかったものは当てない。足し直した後の最初のフレームは、列の次 (2 番目)
        #expect(port.messages == [Self.on60])
        #expect(port.controlChange(1) == 64.0 / 127)
    }
}
