// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Darwin
import Foundation
import MokumeDiagnostics
import Synchronization

/// 外から届く出来事を、落とさずに溜める列。
///
/// ``ExternalInput`` (最新の 1 つ) と対になる、外から届くものの入れ物である ([ADR-0028] 決定 2 の
/// 「落とさない列」)。押された・離された・届いたメッセージのように、**1 つでも落とすと意味が
/// 変わるもの**を入れる。受け渡しの 3 層は ``ExternalInput`` と同じで、この型は真ん中を持つ。
///
/// 1. **OS のコールバック層** — 任意のスレッドで ``send(_:hostTime:)``・``discardUnreadable(_:)``・
///    ``setState(_:)`` を呼ぶ
/// 2. **入れ物** — この型。届いた順に溜める
/// 3. **フレーム** — 入り口の ``Inlet/supply()`` が ``take()`` で、前に取り出した後に届いた
///    **全部**を取り出す。取り出したフレームが ``Arrival`` に記録される
///
/// ```swift
/// final class Doorbell: Inlet {
///     let input = ExternalQueue<String>(name: "doorbell", state: .running)
///     private(set) var rings: [String] = []
///     func supply() { rings = input.take() }
///     var report: SourceReport? { input.report }
/// }
/// ```
///
/// ## 上限で捨て、捨てたことを黙らない
///
/// **上限の無い列は、読まない利用者のところで無限に伸びる。** だから上限 (``capacity``) を持ち、
/// 超えたら**古いものから**捨てる — 新しいものほど、いまの様子を表しているからである。捨てた数と、
/// 届いたが読めずに捨てた数 (``discardUnreadable(_:)``) を数え、**次に読まれたときに**診断へ出す。
/// 黙って捨てると、「値が来ない」のが送っていないからなのか捨てられたからなのか区別できない。
/// 捨て続けても行が埋まらないよう、知らせは 1 秒に 1 度までにまとめる。
///
/// **差し替えはここで行う** ([ADR-0028] 決定 6)。実機・記録の再生・合成した出来事のどれも、
/// 同じ ``send(_:hostTime:)`` へ入れる。入り口から先は、出どころを知らない。
///
/// [ADR-0028]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0028-external-inputs.md
public nonisolated final class ExternalQueue<Value: Sendable>: Sendable {
    /// 何の入り口か。観測の応答と診断に出る名前。
    public let name: String
    /// 溜めておける数。超えたら古いものから捨てる。
    public let capacity: Int

    private let waiting: Mutex<Waiting<Value>>
    private let current: Mutex<SourceState>
    private let arrival = Mutex<Arrival?>(nil)
    private let told = Mutex(Told())
    private let warn: @Sendable (String) -> Void
    private let now: @Sendable () -> TimeInterval

    /// 知らせの間隔 (秒)。この間に捨てたものは、次の知らせにまとめて出す。
    static var noticeInterval: TimeInterval { 1 }

    /// - Parameters:
    ///   - name: 観測の応答と診断に出る名前。
    ///   - state: 始まりの状態。
    ///   - capacity: 溜めておける数。1 より小さければ 1 にする。
    public convenience init(name: String, state: SourceState, capacity: Int = 4096) {
        self.init(
            name: name, state: state, capacity: capacity, warn: { Diagnostics.warn($0) },
            now: { ProcessInfo.processInfo.systemUptime })
    }

    /// 検査が知らせの行き先と時計を差し替える口。
    init(
        name: String, state: SourceState, capacity: Int,
        warn: @escaping @Sendable (String) -> Void,
        now: @escaping @Sendable () -> TimeInterval
    ) {
        self.name = name
        self.capacity = max(1, capacity)
        waiting = Mutex(Waiting<Value>(capacity: max(1, capacity)))
        current = Mutex(state)
        self.warn = warn
        self.now = now
    }

    // MARK: - OS のコールバック層から (どのスレッドからでも)

    /// 届いたものを列の後ろへ入れる。上限に達していれば、いちばん古いものを捨てて数える。
    ///
    /// - Parameters:
    ///   - value: 届いたもの。
    ///   - hostTime: 届いた瞬間の host time。省けば呼んだ瞬間。
    public func send(_ value: Value, hostTime: UInt64 = mach_absolute_time()) {
        waiting.withLock { $0.append(value, hostTime: hostTime) }
    }

    /// 届いたが読めなかったものを、列に入れずに捨てたと数える。数は次に読まれたときに診断へ出る。
    ///
    /// - Parameter count: 捨てた数。
    public func discardUnreadable(_ count: Int = 1) {
        guard count > 0 else { return }
        waiting.withLock { $0.unreadable += count }
    }

    /// 出どころの状態を変える。
    public func setState(_ state: SourceState) {
        current.withLock { $0 = state }
    }

    /// 出どころの状態。
    public var state: SourceState { current.withLock { $0 } }

    // MARK: - フレームから (main actor)

    /// 前に取り出した後に届いたものを、届いた順に全部取り出す。無ければ空。
    ///
    /// 1 つ以上取り出したら、そのフレームを ``lastArrival`` に記録する。前に読んだ後に捨てた
    /// ものがあれば、ここで診断に出す。``Inlet/supply()`` の中で呼ぶ — スケッチの外で呼ぶと、
    /// フレームは 0 として記録される。
    @MainActor
    public func take() -> [Value] {
        let drained = waiting.withLock { $0.drain() }
        if let hostTime = drained.lastHostTime {
            let record = Arrival(
                frame: runningSketch?.frameCount ?? 0, time: runningSketch?.time ?? 0,
                hostTime: hostTime)
            arrival.withLock { $0 = record }
        }
        tellDiscards(overflowed: drained.overflowed, unreadable: drained.unreadable)
        return drained.values
    }

    /// 最後に取り出したものが、どのフレームに割り当てられたか。まだなら `nil`。
    public var lastArrival: Arrival? { arrival.withLock { $0 } }

    /// 観測の応答に載せる名乗り。``Inlet/report`` から返す。
    public var report: SourceReport {
        SourceReport(name: name, state: state, lastArrival: lastArrival)
    }

    // MARK: - 捨てた数

    /// 上限で捨てた数 (始まってからの累計)。
    var overflowed: Int { waiting.withLock { $0.overflowed } }
    /// 読めずに捨てた数 (始まってからの累計)。
    var unreadable: Int { waiting.withLock { $0.unreadable } }

    /// 前に知らせた後に増えた分を、間隔を空けて 1 行で言う。
    private func tellDiscards(overflowed: Int, unreadable: Int) {
        let message: String? = told.withLock { told in
            guard overflowed > told.overflowed || unreadable > told.unreadable else { return nil }
            let moment = now()
            if let last = told.at, moment - last < Self.noticeInterval { return nil }
            var parts: [String] = []
            if overflowed > told.overflowed {
                let count = overflowed - told.overflowed
                parts.append(
                    "\(count) \(count == 1 ? "was" : "were") dropped because \(capacity) "
                        + "\(capacity == 1 ? "was" : "were") already waiting to be read "
                        + "(\(overflowed) in all)")
            }
            if unreadable > told.unreadable {
                let count = unreadable - told.unreadable
                parts.append(
                    "\(count) could not be read and \(count == 1 ? "was" : "were") discarded "
                        + "(\(unreadable) in all)")
            }
            told = Told(overflowed: overflowed, unreadable: unreadable, at: moment)
            return "\(name): " + parts.joined(separator: "; ")
        }
        if let message { warn(message) }
    }
}

/// 溜まっているものと、捨てた数。錠の内側でだけ触る。
private nonisolated struct Waiting<Value: Sendable>: Sendable {
    /// 環。満ちるまでは後ろへ足し、満ちたら ``head`` (いちばん古いもの) を上書きして進める。
    private var ring: [(value: Value, hostTime: UInt64)] = []
    private var head = 0
    private let capacity: Int
    /// 上限で捨てた数 (累計)。
    private(set) var overflowed = 0
    /// 読めずに捨てた数 (累計)。
    var unreadable = 0

    init(capacity: Int) { self.capacity = capacity }

    mutating func append(_ value: Value, hostTime: UInt64) {
        guard ring.count == capacity else {
            ring.append((value, hostTime))
            return
        }
        ring[head] = (value, hostTime)
        head = (head + 1) % capacity
        overflowed += 1
    }

    /// 届いた順に全部を取り出し、空にする。
    mutating func drain() -> (
        values: [Value], lastHostTime: UInt64?, overflowed: Int, unreadable: Int
    ) {
        let ordered = ring[head...] + ring[..<head]
        ring.removeAll()
        head = 0
        return (ordered.map(\.value), ordered.last?.hostTime, overflowed, unreadable)
    }
}

/// 前に知らせたときの累計と時刻。
private nonisolated struct Told: Sendable {
    var overflowed = 0
    var unreadable = 0
    var at: TimeInterval?
}
