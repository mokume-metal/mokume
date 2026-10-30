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
    ///
    /// - **速度 0 のノートオンは、ノートオフにして入れる。** 実機から読んだものも、注入した列も同じ形になる
    ///   (入れ物から先は出どころを知らない)
    /// - **抜かれている間は捨てる。** 抜いた後に遅れて届いた callback が、離されないノートを残さないように、
    ///   状態の見張り (``unplug(hostTime:)``) と同じ錠の内側で見る
    func receive(_ message: MIDIMessage, hostTime: UInt64 = mach_absolute_time()) {
        guard message.isValid else {
            messages.discardUnreadable()
            return
        }
        let message = message.releasingZeroVelocity
        memory.withLock { memory in
            guard state != .disconnected else { return }
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
            // 離す出来事を入れた同じ錠の内側で名乗る。この後に届くものは ``receive(_:hostTime:)`` が捨てる
            setState(.disconnected)
        }
    }

    /// 読んだ現在値の表を、最新の 1 つへ入れ直す。外されていた入り口が足し直されたとき
    /// (``discardWaiting()`` で捨てた表を戻す)。
    ///
    /// **錠の内側で送る。** 錠を放してから送ると、その隙間に届いた新しい値を、古い表が上書きする。
    func resendControllers() {
        memory.withLock { memory in
            if !memory.controllers.isEmpty { controllers.send(memory.controllers) }
        }
    }

    /// 中継 (``MIDIFeed``) が持つ最後の現在値の表を、この入れ物の表にして最新の 1 つへ入れる。
    /// 後から繋いだ入り口・足し直された入り口が、繋ぐ前に動いたつまみの値を読めるようにする。
    /// 何も届いていない表では何もしない。
    func adopt(_ table: MIDIControllers) {
        memory.withLock { memory in
            guard !table.isEmpty else { return }
            memory.controllers = table
            controllers.send(table)
        }
    }

    /// 現在値の表と出来事を、**同じ錠の内側で**取り出す。別々に取ると、その間に届いたものを片方だけが
    /// 持ち、同じフレームで表と列が食い違う。
    @MainActor
    func take() -> (controllers: MIDIControllers?, messages: [MIDIMessage]) {
        memory.withLock { _ in
            MainActor.assumeIsolated { (controllers.take(), messages.take()) }
        }
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
