// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Darwin
import MokumeCore
import Synchronization

/// コントロールチェンジの現在値の表。チャンネルごと・番号ごとに、最後に届いた値を持つ。
///
/// 最新の 1 つの入れ物 (``ExternalInput``) に、表ごと入れる。1 フレームに別々のつまみが何本動いても、
/// 取り出した表がどれの最新も持つ。
nonisolated struct MIDIControllers: Sendable, Equatable {
    /// まだ届いていない印。
    private static let unset: UInt8 = 255

    /// チャンネル (0〜15) × 番号 (0〜127) の表。
    private var byChannel = [UInt8](repeating: unset, count: 16 * 128)
    /// 番号ごとに、チャンネルを問わず最後に届いた値。
    private var latest = [UInt8](repeating: unset, count: 128)

    /// 何も届いていない。
    var isEmpty: Bool { latest.allSatisfy { $0 == Self.unset } }

    /// 値を入れる。`channel` は 1〜16、`controller` と `value` は 0〜127 (呼ぶ側が確かめる)。
    mutating func set(channel: Int, controller: Int, value: Int) {
        byChannel[(channel - 1) * 128 + controller] = UInt8(value)
        latest[controller] = UInt8(value)
    }

    /// 値 (0〜127)。届いていなければ `nil`。`channel` を省けば、どのチャンネルでも最後に届いたもの。
    func value(controller: Int, channel: Int?) -> Int? {
        guard (0...127).contains(controller) else { return nil }
        let raw: UInt8
        if let channel {
            guard (1...16).contains(channel) else { return nil }
            raw = byChannel[(channel - 1) * 128 + controller]
        } else {
            raw = latest[controller]
        }
        return raw == Self.unset ? nil : Int(raw)
    }
}

/// 入り口 1 つぶんの入れ物。**届き方の違う 2 つを分けて持つ** ([ADR-0028] 決定 2)。
///
/// - ノートの押し離しとコントロールチェンジの出来事は落とさない列 (``ExternalQueue``)。1 フレームに
///   押して離した鍵も、届いた順に全部読む
/// - コントロールチェンジの現在値は最新の 1 つ (``ExternalInput``)。列が上限で古いものを捨てても、
///   現在値はいつも最新である
///
/// 状態は 2 つに同じものを置く。読むのは列の側である。
///
/// **入れ物へ入れるのは ``receive(_:hostTime:)`` の 1 本だけ。** 実機も記録の再生も同じ口を通るので、
/// 入れ物から先は出どころを知らない ([ADR-0028] 決定 6)。
///
/// [ADR-0028]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0028-external-inputs.md
nonisolated final class MIDIInbox: Sendable {
    let name: String
    let messages: ExternalQueue<MIDIMessage>
    let controllers: ExternalInput<MIDIControllers>

    /// 錠の内側でだけ触る、受けた側の記憶。
    private struct Memory: Sendable {
        var controllers = MIDIControllers()
        /// 押されているノート。(チャンネル, ノート) を 1 つの数にして持つ。
        var held: Set<Int> = []
    }
    private let memory = Mutex(Memory())

    init(name: String, state: SourceState, capacity: Int = 4096) {
        self.name = name
        messages = ExternalQueue(name: name, state: state, capacity: capacity)
        controllers = ExternalInput(name: name, state: state)
    }

    // MARK: - 入れる (どのスレッドからでも)

    /// 届いたメッセージを入れる。範囲に収まらないものは「読めずに捨てた」と数える。
    func receive(_ message: MIDIMessage, hostTime: UInt64 = mach_absolute_time()) {
        guard message.isValid else {
            messages.discardUnreadable()
            return
        }
        memory.withLock { memory in
            switch message {
            case .noteOn(let channel, let note, _): memory.held.insert(Self.key(channel, note))
            case .noteOff(let channel, let note, _): memory.held.remove(Self.key(channel, note))
            case .controlChange(let channel, let controller, let value):
                memory.controllers.set(channel: channel, controller: controller, value: value)
                controllers.send(memory.controllers, hostTime: hostTime)
            }
            messages.send(message, hostTime: hostTime)
        }
    }

    /// 読めずに捨てたものを数える (UMP で読めなかったもの)。
    func discardUnreadable(_ count: Int) {
        messages.discardUnreadable(count)
    }

    /// 出どころの状態を変える。
    func setState(_ state: SourceState) {
        messages.setState(state)
        controllers.setState(state)
    }

    /// 抜かれた。押していたノートを離したことにして、抜かれたと名乗る。
    ///
    /// **離す出来事を列に入れて順に当てる。** 抜いた瞬間の状態をフレームの側で消すと、抜いて挿し直すまでが
    /// 1 フレームに収まったとき、抜く前に押していたノートが押されたまま残る。コントロールチェンジの現在値は
    /// 残す (つまみは、抜いても動いていない)。
    func unplug(hostTime: UInt64 = mach_absolute_time()) {
        memory.withLock { memory in
            for key in memory.held.sorted() {
                messages.send(.noteOff(channel: key / 128 + 1, note: key % 128, velocity: 0), hostTime: hostTime)
            }
            memory.held.removeAll()
        }
        setState(.disconnected)
    }

    /// 読んだ現在値の表を、最新の 1 つへ入れ直す。外されていた入り口が足し直されたとき
    /// (``discardWaiting()`` で捨てた表を戻す)。
    func resendControllers() {
        let table = memory.withLock { $0.controllers }
        if !table.isEmpty { controllers.send(table) }
    }

    /// まだ取り出されていない出来事と表を、読まずに捨てる (``MIDIPort/close()``)。
    func discardWaiting() {
        messages.discardWaiting()
        controllers.discardWaiting()
        memory.withLock { $0.held.removeAll() }
    }

    /// 出どころの状態。
    var state: SourceState { messages.state }

    /// 観測の応答に載せる名乗り。最後に届いたのは、2 つの入れ物のうち後に取り出したほう。
    var report: SourceReport {
        let arrivals = [messages.lastArrival, controllers.lastArrival].compactMap { $0 }
        let latest = arrivals.max { ($0.frame, $0.hostTime) < ($1.frame, $1.hostTime) }
        return SourceReport(name: name, state: state, lastArrival: latest)
    }

    private static func key(_ channel: Int, _ note: Int) -> Int { (channel - 1) * 128 + note }
}
