// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation
import Synchronization
import Testing

@testable import MokumeCore

/// 落とさない列 (ADR-0028 決定 2・#1962)。GPU は要らない。
///
/// **届いたものを届いた順に全部渡し、上限で捨てたことと読めずに捨てたことを、次に読まれた
/// ときに診断へ出すことが約束である。** 黙って捨てると、「値が来ない」のが送っていないから
/// なのか捨てられたからなのか区別できない。
@Suite("落とさない列")
struct ExternalQueueTests {
    /// 知らせを溜める行き先と、進められる時計。
    final class Probe: Sendable {
        let told = Mutex<[String]>([])
        let clock = Mutex<TimeInterval>(100)

        func queue(capacity: Int) -> ExternalQueue<Int> {
            ExternalQueue(
                name: "probe", state: .running, capacity: capacity,
                warn: { [self] line in told.withLock { $0.append(line) } },
                now: { [self] in clock.withLock { $0 } })
        }

        var lines: [String] { told.withLock { $0 } }

        func advance(_ seconds: TimeInterval) { clock.withLock { $0 += seconds } }
    }

    @Test("届いた順に全部を取り出し、取り出した後は空になる")
    func takesEverythingInOrder() {
        let probe = Probe()
        let queue = probe.queue(capacity: 8)
        for value in 1...5 { queue.send(value) }
        #expect(queue.take() == [1, 2, 3, 4, 5])
        #expect(queue.take() == [])
        #expect(probe.lines.isEmpty)
    }

    @Test("上限ちょうどは捨てない。1 つ超えたら、いちばん古いものを捨てて数える")
    func dropsTheOldestBeyondCapacity() {
        let probe = Probe()
        let queue = probe.queue(capacity: 3)
        for value in 1...3 { queue.send(value) }
        #expect(queue.take() == [1, 2, 3])
        #expect(probe.lines.isEmpty)

        for value in 1...4 { queue.send(value) }
        #expect(queue.take() == [2, 3, 4])
        #expect(queue.overflowed == 1)
        #expect(
            probe.lines == ["probe: 1 was dropped because 3 were already waiting to be read (1 in all)"])
    }

    @Test("上限が 1 より小さければ 1 にする")
    func capacityIsAtLeastOne() {
        let queue = Probe().queue(capacity: 0)
        #expect(queue.capacity == 1)
        queue.send(1)
        queue.send(2)
        #expect(queue.take() == [2])
    }

    @Test("読めずに捨てた数は、次に読まれたときに出る")
    func unreadableIsToldOnTheNextRead() {
        let probe = Probe()
        let queue = probe.queue(capacity: 8)
        queue.send(1)
        queue.discardUnreadable()
        queue.discardUnreadable(2)
        queue.discardUnreadable(0)  // 数えない
        #expect(probe.lines.isEmpty)  // 捨てた時点では言わない
        #expect(queue.take() == [1])
        #expect(queue.unreadable == 3)
        #expect(probe.lines == ["probe: 3 could not be read and were discarded (3 in all)"])
    }

    @Test("知らせは 1 秒に 1 度まで。間に捨てた分は次の知らせにまとめる")
    func noticesAreSpacedAndCarryTheDifference() {
        let probe = Probe()
        let queue = probe.queue(capacity: 1)
        queue.send(1)
        queue.send(2)  // 1 を捨てる
        _ = queue.take()
        #expect(probe.lines.count == 1)

        // 間を空けずに捨てても、まだ言わない
        queue.send(3)
        queue.send(4)
        queue.discardUnreadable()
        probe.advance(0.5)
        _ = queue.take()
        #expect(probe.lines.count == 1)

        // 間が空いた次の読みで、前の知らせから増えた分 (捨てた 1・読めない 1) をまとめて言う
        probe.advance(0.6)
        _ = queue.take()
        #expect(
            probe.lines == [
                "probe: 1 was dropped because 1 was already waiting to be read (1 in all)",
                "probe: 1 was dropped because 1 was already waiting to be read (2 in all); "
                    + "1 could not be read and was discarded (1 in all)",
            ])
        // 何も捨てていなければ、間が空いても言わない
        _ = queue.take()
        probe.advance(5)
        _ = queue.take()
        #expect(probe.lines.count == 2)
    }

    @Test("取り出したフレームが記録され、名乗りに載る。何も無ければ記録は動かない")
    func arrivalIsRecordedOnlyWhenSomethingIsTaken() {
        let queue = Probe().queue(capacity: 8)
        #expect(queue.lastArrival == nil)
        _ = queue.take()
        #expect(queue.lastArrival == nil)
        queue.send(1, hostTime: 10)
        queue.send(2, hostTime: 20)
        _ = queue.take()
        // スケッチの外で取り出したのでフレームは 0。時刻は最後に届いたもの
        #expect(queue.lastArrival == Arrival(frame: 0, time: 0, hostTime: 20))
        queue.setState(.disconnected)
        #expect(queue.report == SourceReport(name: "probe", state: .disconnected, lastArrival: queue.lastArrival))
    }

    @Test("どのスレッドから入れても、1 つも落とさず数も合う")
    func sendsFromManyThreads() async {
        let queue = Probe().queue(capacity: 4096)
        await withTaskGroup(of: Void.self) { group in
            for lane in 0..<8 {
                group.addTask {
                    for index in 0..<500 { queue.send(lane * 1000 + index) }
                }
            }
        }
        let taken = queue.take()
        #expect(taken.count == 4000)
        #expect(Set(taken).count == 4000)
        // 同じ送り手から入れたものは、その順のまま並ぶ
        for lane in 0..<8 {
            let mine = taken.filter { $0 / 1000 == lane }
            #expect(mine == mine.sorted())
        }
    }
}
