// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Darwin
import Foundation
import Testing

@testable import MokumeCore
@testable import MokumeMIDI

/// CoreMIDI の代わりに、検査が機材の抜き差しと届く語を直に渡す継ぎ目 (``MIDIBackend``) の偽物。
final class FakeMIDIBackend: MIDIBackend {
    var current: [MIDISourceInfo] = []
    private(set) var started = 0
    private(set) var changed: (@Sendable () -> Void)?
    /// いま受けている機材の、一意な番号ごとの受け取り先。
    private(set) var handlers: [Int32: @Sendable ([UInt32], UInt64) -> Void] = [:]

    func start(changed: @escaping @Sendable () -> Void) {
        started += 1
        self.changed = changed
    }

    func sources() -> [MIDISourceInfo] { current }

    /// 繋げないことにする機材 (一意な番号)。
    var failing: Set<Int32> = []
    private(set) var connectAttempts = 0

    func connect(_ source: MIDISourceInfo, handler: @escaping @Sendable ([UInt32], UInt64) -> Void) -> Bool {
        connectAttempts += 1
        guard !failing.contains(source.uniqueID) else { return false }
        handlers[source.uniqueID] = handler
        return true
    }

    func disconnect(_ source: MIDISourceInfo) {
        handlers[source.uniqueID] = nil
    }

    /// 機材 `uniqueID` から、語が届いたことにする。
    func deliver(_ uniqueID: Int32, _ words: [UInt32]) {
        handlers[uniqueID]?(words, mach_absolute_time())
    }

    static func source(_ uniqueID: Int32, _ name: String, endpoint: UInt32 = 1) -> MIDISourceInfo {
        MIDISourceInfo(uniqueID: uniqueID, name: name, endpoint: endpoint)
    }
}

/// 実機の配線を、偽の CoreMIDI で回す。本物の機材は要らない。
///
/// 係 (``MIDIHub``) は検査ごとに作り、プロセスの係 (``MIDIHub/shared``) には触れない。
@Suite("MIDI の実機の配線 (偽の CoreMIDI)", .serialized)
struct MIDIHubTests {
    private func port(_ id: String, on hub: MIDIHub) throws -> MIDIPort {
        let port = MIDIPort(id: id, name: "midi: \(id)", source: DeviceSource(id: id, hub: hub))
        try port.open()
        return port
    }

    private static let cc1: (Int) -> UInt32 = { 0x20B0_0100 | UInt32($0) }
    private static let on60: UInt32 = 0x2090_3C64
    private static let off60: UInt32 = 0x2080_3C00

    @Test("一覧は繋がっている機材を初めて繋がった順に返し、見張りは 1 度しか始まらない")
    func listsDevices() {
        let backend = FakeMIDIBackend()
        backend.current = [.init(uniqueID: 1, name: "Pad", endpoint: 1), .init(uniqueID: 2, name: "Keys", endpoint: 2)]
        let hub = MIDIHub(backend: backend)
        hub.start()
        hub.start()
        #expect(backend.started == 1)
        #expect(hub.devices.map(\.id) == ["Pad #1", "Keys #1"])
        #expect(hub.devices.map(\.name) == ["Pad", "Keys"])
        #expect(hub.devices.allSatisfy { $0.isConnected })
    }

    @Test("同じ名前の 2 台は #1・#2 になり、選んだ 1 台のメッセージだけが入る")
    func selectingOneOfTwo() throws {
        let backend = FakeMIDIBackend()
        backend.current = [.init(uniqueID: 1, name: "Pad", endpoint: 1), .init(uniqueID: 2, name: "Pad", endpoint: 2)]
        let hub = MIDIHub(backend: backend)
        hub.start()
        #expect(hub.devices.map(\.id) == ["Pad #1", "Pad #2"])

        let second = try port("Pad #2", on: hub)
        #expect(second.state == .running)
        backend.deliver(1, [Self.on60])
        backend.deliver(2, [Self.cc1(64), Self.off60])
        second.supply()
        #expect(second.messages == [.controlChange(channel: 1, controller: 1, value: 64), .noteOff(channel: 1, note: 60, velocity: 0)])
        #expect(second.controlChange(1) == 64.0 / 127)
    }

    @Test("抜くと切断を名乗り、押していたノートは離れる。挿し直すと同じ識別子の同じ入り口が戻る")
    func unplugAndReplug() throws {
        let backend = FakeMIDIBackend()
        backend.current = [.init(uniqueID: 1, name: "Pad", endpoint: 1)]
        let hub = MIDIHub(backend: backend)
        hub.start()
        let port = try port("Pad #1", on: hub)
        backend.deliver(1, [Self.cc1(100), Self.on60])
        port.supply()
        #expect(port.state == .running)

        backend.current = []
        hub.refresh()
        #expect(backend.handlers.isEmpty, "抜いた機材の受け取り先は外れる")
        port.supply()
        #expect(port.state == .disconnected)
        #expect(port.messages == [.noteOff(channel: 1, note: 60, velocity: 0)])
        #expect(port.controlChange(1) == 100.0 / 127)
        #expect(hub.devices.map(\.isConnected) == [false])
        #expect(port.report?.state == .disconnected)

        // 端点は挿し直すと変わる。同じ一意な番号で戻る
        backend.current = [.init(uniqueID: 1, name: "Pad", endpoint: 7)]
        hub.refresh()
        #expect(port.state == .running)
        #expect(hub.devices.map(\.id) == ["Pad #1"])
        backend.deliver(1, [Self.on60])
        port.supply()
        #expect(port.messages == [.noteOn(channel: 1, note: 60, velocity: 100)])
    }

    @Test("同じ機種の 2 台を両方抜いて逆の順に挿しても、識別子は入れ替わらない")
    func reverseReplug() throws {
        let backend = FakeMIDIBackend()
        backend.current = [.init(uniqueID: 1, name: "Pad", endpoint: 1), .init(uniqueID: 2, name: "Pad", endpoint: 2)]
        let hub = MIDIHub(backend: backend)
        hub.start()
        backend.current = []
        hub.refresh()
        backend.current = [.init(uniqueID: 2, name: "Pad", endpoint: 5), .init(uniqueID: 1, name: "Pad", endpoint: 6)]
        hub.refresh()
        let first = try port("Pad #1", on: hub)
        backend.deliver(1, [Self.cc1(10)])
        first.supply()
        #expect(first.controlChange(1) == 10.0 / 127)
        #expect(hub.devices.map(\.id) == ["Pad #1", "Pad #2"])
    }

    @Test("端点だけが変わった (挿し直しが 1 回の知らせに収まった) 機材も、いったん抜かれて戻る")
    func endpointChangeCountsAsReplug() throws {
        let backend = FakeMIDIBackend()
        backend.current = [.init(uniqueID: 1, name: "Pad", endpoint: 1)]
        let hub = MIDIHub(backend: backend)
        hub.start()
        let port = try port("Pad #1", on: hub)
        backend.deliver(1, [Self.on60])
        port.supply()
        backend.current = [.init(uniqueID: 1, name: "Pad", endpoint: 9)]
        hub.refresh()
        port.supply()
        #expect(port.messages == [.noteOff(channel: 1, note: 60, velocity: 0)])
        #expect(port.state == .running)
        #expect(backend.handlers.count == 1)
    }

    @Test("読めない種類 (ピッチベンド) は列に入らず、読めずに捨てたと数える")
    func unreadableKindsAreCounted() throws {
        let backend = FakeMIDIBackend()
        backend.current = [.init(uniqueID: 1, name: "Pad", endpoint: 1)]
        let hub = MIDIHub(backend: backend)
        hub.start()
        let port = try port("Pad #1", on: hub)
        backend.deliver(1, [0x20E0_0040, 0x20E0_0140, 0x20E0_0240])
        backend.deliver(1, [0x10F8_0000])  // クロックは数えない
        port.supply()
        #expect(port.messages.isEmpty)
        #expect(port.inbox.messages.unreadable == 3)
    }

    @Test("機材が一度も繋がっていない識別子は unavailable")
    func stateOfAnUnseenDevice() throws {
        let backend = FakeMIDIBackend()
        let hub = MIDIHub(backend: backend)
        hub.start()
        #expect(hub.devices.isEmpty)
        let ghost = try port("Ghost #1", on: hub)
        #expect(ghost.state == .unavailable)
    }

    @Test("外した入り口へは届かず、足し直すと同じ機材のメッセージが届く")
    func detachedPortGetsNothing() throws {
        let backend = FakeMIDIBackend()
        backend.current = [.init(uniqueID: 1, name: "Pad", endpoint: 1)]
        let hub = MIDIHub(backend: backend)
        hub.start()
        let port = try port("Pad #1", on: hub)
        port.close()
        backend.deliver(1, [Self.on60])
        port.supply()
        #expect(port.messages.isEmpty)
        try port.open()
        backend.deliver(1, [Self.off60])
        port.supply()
        #expect(port.messages == [.noteOff(channel: 1, note: 60, velocity: 0)])
    }

    @Test("見張りが知らせたら、main へ寄せて一覧を引き直す")
    func changeNotificationRefreshes() async throws {
        let backend = FakeMIDIBackend()
        let hub = MIDIHub(backend: backend)
        hub.start()
        #expect(hub.devices.isEmpty)
        backend.current = [.init(uniqueID: 1, name: "Pad", endpoint: 1)]
        // CoreMIDI は任意のスレッドから知らせる
        let notify = try #require(backend.changed)
        DispatchQueue.global().async { notify() }
        // 待つ側が期限を持つ (2 秒)
        let deadline = ContinuousClock.now + .seconds(2)
        while hub.devices.isEmpty, ContinuousClock.now < deadline {
            await withCheckedContinuation { done in DispatchQueue.main.async { done.resume() } }
        }
        #expect(hub.devices.map(\.id) == ["Pad #1"])
    }

    // MARK: - 反証の直し (#3507)

    @Test("後から作った入り口・足し直した入り口は、作る前に動いたつまみの現在値を読める")
    func lateSubscribersSeeTheCurrentValue() throws {
        let backend = FakeMIDIBackend()
        backend.current = [.init(uniqueID: 1, name: "Pad", endpoint: 1)]
        let hub = MIDIHub(backend: backend)
        hub.start()
        // 入り口が 1 つも無い間に動いたつまみ
        backend.deliver(1, [Self.cc1(100)])
        let late = try port("Pad #1", on: hub)
        late.supply()
        #expect(late.controlChange(1) == 100.0 / 127)

        // 外している間に動いても、足し直した入り口に戻る
        late.close()
        backend.deliver(1, [Self.cc1(20)])
        try late.open()
        late.supply()
        #expect(late.controlChange(1) == 20.0 / 127)
        let fresh = try port("Pad #1", on: hub)
        #expect(fresh.controlChange(1) == nil, "作っただけでは supply() するまで読めない")
    }

    @Test("MIDIPort の最初の supply() で、同じ機材の 2 つ目の入り口にも現在値が入る")
    func secondPortOnTheSameDevice() throws {
        let backend = FakeMIDIBackend()
        backend.current = [.init(uniqueID: 1, name: "Pad", endpoint: 1)]
        let hub = MIDIHub(backend: backend)
        hub.start()
        let first = try port("Pad #1", on: hub)
        backend.deliver(1, [Self.cc1(7)])
        first.supply()
        let second = try port("Pad #1", on: hub)
        second.supply()
        #expect(second.controlChange(1) == 7.0 / 127)
        #expect(second.messages.isEmpty, "出来事は繋いだ後に届いたものだけ")
    }

    @Test("繋げなかった機材は running と名乗らず、一覧には載り、次の引き直しで繋ぎ直す")
    func connectFailureIsRetried() throws {
        let backend = FakeMIDIBackend()
        backend.current = [.init(uniqueID: 1, name: "Pad", endpoint: 1)]
        backend.failing = [1]
        let hub = MIDIHub(backend: backend)
        hub.start()
        #expect(hub.devices.map(\.id) == ["Pad #1"])
        #expect(hub.devices.map(\.isConnected) == [false])
        let port = try port("Pad #1", on: hub)
        #expect(port.state == .unavailable)

        hub.refresh()
        #expect(backend.connectAttempts == 2, "引き直すたびに繋ぎ直す")
        #expect(port.state == .unavailable)

        backend.failing = []
        hub.refresh()
        #expect(port.state == .running)
        #expect(hub.devices.map(\.isConnected) == [true])
        backend.deliver(1, [Self.on60])
        port.supply()
        #expect(port.messages == [.noteOn(channel: 1, note: 60, velocity: 100)])
        #expect(hub.devices.map(\.id) == ["Pad #1"], "席は増えない")
    }

    @Test("同じ名前の機材の番号は、一覧の順ではなく一意な番号の順に振る")
    func numbersFollowUniqueIDs() {
        let backend = FakeMIDIBackend()
        backend.current = [.init(uniqueID: 20, name: "Pad", endpoint: 2), .init(uniqueID: 10, name: "Pad", endpoint: 1)]
        let hub = MIDIHub(backend: backend)
        hub.start()
        #expect(hub.devices.map(\.id) == ["Pad #1", "Pad #2"])
        // #1 は一意な番号 10 の機材。20 だけを抜くと #2 が抜かれる
        backend.current = [.init(uniqueID: 10, name: "Pad", endpoint: 1)]
        hub.refresh()
        #expect(hub.devices.map(\.isConnected) == [true, false])
    }

    @Test("端点が同じで名前だけが変わっても、抜いたことにせず、ノートも離さない。名前だけ更新する")
    func renameIsNotAnUnplug() throws {
        let backend = FakeMIDIBackend()
        backend.current = [.init(uniqueID: 1, name: "Pad", endpoint: 1)]
        let hub = MIDIHub(backend: backend)
        hub.start()
        let port = try port("Pad #1", on: hub)
        backend.deliver(1, [Self.on60])
        port.supply()
        backend.current = [.init(uniqueID: 1, name: "Pad Renamed", endpoint: 1)]
        hub.refresh()
        port.supply()
        #expect(port.state == .running)
        #expect(port.messages.isEmpty)
        #expect(hub.devices.map(\.name) == ["Pad Renamed"])
        #expect(hub.devices.map(\.id) == ["Pad #1"])
        // 同じ綴りの識別子を、新しい機材が取り合わない
        backend.current += [.init(uniqueID: 2, name: "Pad", endpoint: 2)]
        hub.refresh()
        #expect(Set(hub.devices.map(\.id)).count == 2)
    }

    @Test("抜いた後に遅れて届いた callback は捨て、押しっぱなしを残さない。挿し直した後は届く")
    func lateCallbackAfterUnplugIsDropped() throws {
        let backend = FakeMIDIBackend()
        backend.current = [.init(uniqueID: 1, name: "Pad", endpoint: 1)]
        let hub = MIDIHub(backend: backend)
        hub.start()
        let port = try port("Pad #1", on: hub)
        let late = try #require(backend.handlers[1])
        backend.current = []
        hub.refresh()
        port.supply()
        // 抜いた後に、古い接続の callback が遅れて届く
        late([Self.on60], mach_absolute_time())
        port.supply()
        #expect(port.messages.isEmpty)
        // 挿し直して抜く。遅れて届いた noteOn が押しっぱなしとして残っていれば、ここで noteOff が出る
        backend.current = [.init(uniqueID: 1, name: "Pad", endpoint: 2)]
        hub.refresh()
        backend.current = []
        hub.refresh()
        port.supply()
        #expect(port.messages.isEmpty)
    }
}
