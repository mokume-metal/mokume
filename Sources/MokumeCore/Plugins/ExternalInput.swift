// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Darwin
import Synchronization

/// 外から届く値の、最新の 1 つを預かる入れ物。
///
/// 外から届くものを受ける入り口の、共通の土台である ([ADR-0042] 決定 4)。受け渡しは
/// 3 層で、この型はその真ん中を持つ。
///
/// 1. **OS のコールバック層** — 任意のスレッドで ``send(_:hostTime:)`` と
///    ``setState(_:)`` を呼ぶ
/// 2. **入れ物** — この型。最新の 1 つだけを持ち、新しいものが古いものを上書きする
///    ([ADR-0028] 決定 2 の「最新の 1 つ」)。溜まらない
/// 3. **フレーム** — 入り口の ``Inlet/supply()`` が ``take()`` で取り出す。
///    取り出したフレームが ``Arrival`` に記録される
///
/// **差し替えはここで行う** ([ADR-0028] 決定 6)。実機・記録の再生・合成した値の
/// どれも、同じ ``send(_:hostTime:)`` へ入れる。入り口から先は、出どころを知らない。
///
/// ```swift
/// final class Thermometer: Inlet {
///     let input = ExternalInput<Double>(name: "thermometer", state: .running)
///     private(set) var celsius = 0.0
///     func supply() {
///         if let value = input.take() { celsius = value }
///     }
///     var report: SourceReport? { input.report }
/// }
/// ```
///
/// [ADR-0028]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0028-external-inputs.md
/// [ADR-0042]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0042-camera-and-audio-standard.md
public nonisolated final class ExternalInput<Value: Sendable>: Sendable {
    /// 何の入り口か。観測の応答に出る名前。
    public let name: String

    private let latest = Mutex<(value: Value, hostTime: UInt64)?>(nil)
    private let current: Mutex<SourceState>
    private let arrival = Mutex<Arrival?>(nil)

    /// - Parameters:
    ///   - name: 観測の応答に出る名前。
    ///   - state: 始まりの状態。
    public init(name: String, state: SourceState) {
        self.name = name
        current = Mutex(state)
    }

    // MARK: - OS のコールバック層から (どのスレッドからでも)

    /// 届いた値を入れる。前に入っていて、まだ取り出されていないものは捨てる。
    ///
    /// - Parameters:
    ///   - value: 届いた値。
    ///   - hostTime: 届いた瞬間の host time。省けば呼んだ瞬間。
    public func send(_ value: Value, hostTime: UInt64 = mach_absolute_time()) {
        latest.withLock { $0 = (value, hostTime) }
    }

    /// 出どころの状態を変える。
    public func setState(_ state: SourceState) {
        current.withLock { $0 = state }
    }

    /// 出どころの状態。
    public var state: SourceState { current.withLock { $0 } }

    // MARK: - フレームから (main actor)

    /// 前に取り出した後に届いた値を取り出す。新しいものが無ければ `nil`。
    ///
    /// 取り出したフレームを ``lastArrival`` に記録する。``Inlet/supply()`` の中で呼ぶ —
    /// スケッチの外で呼ぶと、フレームは 0 として記録される。
    @MainActor
    public func take() -> Value? {
        guard let taken = latest.withLock({ slot in defer { slot = nil }; return slot }) else {
            return nil
        }
        let record = Arrival(
            frame: runningSketch?.frameCount ?? 0, time: runningSketch?.time ?? 0,
            hostTime: taken.hostTime)
        arrival.withLock { $0 = record }
        return taken.value
    }

    /// 最後に取り出した値が、どのフレームに割り当てられたか。まだなら `nil`。
    public var lastArrival: Arrival? { arrival.withLock { $0 } }

    /// 観測の応答に載せる名乗り。``Inlet/report`` から返す。
    public var report: SourceReport {
        SourceReport(name: name, state: state, lastArrival: lastArrival)
    }
}
