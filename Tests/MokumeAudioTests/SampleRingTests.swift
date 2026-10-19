// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import CoreAudio
import Dispatch
import Synchronization
import Testing

@testable import MokumeAudio

/// 標本の環と、realtime スレッドでの畳み込み (ADR-0042 決定 7)。機材は要らない。
@Suite("標本の環")
struct SampleRingTests {
    @Test("最新の窓は、まだ書かれていない分を前の 0 で埋める")
    func latestBeforeFull() {
        let ring = SampleRing(capacity: 16)
        ring.write(count: 3, hostTime: 7) { Float($0 + 1) }
        #expect(ring.latest(5) == [0, 0, 1, 2, 3])
        #expect(ring.total == 3)
        #expect(ring.snapshot(5).hostTime == 7)
    }

    @Test("一周した後も、最新の窓が古い順に並ぶ")
    func latestAfterWrapping() {
        let ring = SampleRing(capacity: 8)
        var next: Float = 0
        for _ in 0..<5 {
            ring.write(count: 3, hostTime: 0) { _ in
                defer { next += 1 }
                return next
            }
        }
        // 0〜14 を書いた。最新の 4 つは 11〜14
        #expect(ring.latest(4) == [11, 12, 13, 14])
        #expect(ring.total == 15)
    }

    @Test("交互に並んだ 2 チャンネルは、平均して 1 つになる")
    func interleavedStereoIsAveraged() {
        let ring = SampleRing(capacity: 16)
        var samples: [Float] = [1, 0, 0.5, 0.5, -1, 1]  // L R L R L R
        samples.withUnsafeMutableBytes { bytes in
            var list = AudioBufferList(
                mNumberBuffers: 1,
                mBuffers: AudioBuffer(
                    mNumberChannels: 2, mDataByteSize: UInt32(bytes.count), mData: bytes.baseAddress
                ))
            var stamp = AudioTimeStamp()
            stamp.mHostTime = 42
            stamp.mFlags = .hostTimeValid
            MicrophoneSource.mix(&list, frames: 3, timestamp: &stamp, into: ring)
        }
        #expect(ring.latest(3) == [0.5, 0.5, 0])
        #expect(ring.snapshot(3).hostTime == 42)
    }

    @Test("チャンネルごとの置き場に分かれた 2 チャンネルも、平均して 1 つになる")
    func separatedStereoIsAveraged() {
        let ring = SampleRing(capacity: 16)
        var left: [Float] = [1, 0.2, -1]
        var right: [Float] = [0, 0.2, 0]
        let list = AudioBufferList.allocate(maximumBuffers: 2)
        defer { free(list.unsafeMutablePointer) }
        left.withUnsafeMutableBytes { leftBytes in
            right.withUnsafeMutableBytes { rightBytes in
                list[0] = AudioBuffer(
                    mNumberChannels: 1, mDataByteSize: UInt32(leftBytes.count),
                    mData: leftBytes.baseAddress)
                list[1] = AudioBuffer(
                    mNumberChannels: 1, mDataByteSize: UInt32(rightBytes.count),
                    mData: rightBytes.baseAddress)
                var stamp = AudioTimeStamp()
                MicrophoneSource.mix(list.unsafePointer, frames: 3, timestamp: &stamp, into: ring)
            }
        }
        #expect(ring.latest(3) == [0.5, 0.2, -0.5])
    }
}

extension SampleRingTests {
    @Test("読み手が窓を持ったまま止まっても、書き手は周回し、持っていた窓は変わらない")
    func heldSnapshotSurvivesWrapping() {
        let ring = SampleRing(capacity: 8)
        ring.write(count: 8, hostTime: 8) { Float($0) }
        let held = ring.snapshot(8) {
            // 受領からコピーまでの間に書き手を進める。OS の時機や sleep に頼らない。
            for batch in 1...1000 {
                ring.write(count: 8, hostTime: UInt64((batch + 1) * 8)) {
                    Float(batch * 8 + $0)
                }
            }
        }
        #expect(held.samples == (0..<8).map(Float.init))
        #expect(held.total == 8)
        #expect(held.hostTime == 8)
        let newest = ring.snapshot(8)
        #expect(newest.samples == (8000..<8008).map(Float.init))
        #expect(newest.total == 8008)
        #expect(newest.hostTime == 8008)
        // 新しい公開がなければ、読み終わった古い窓へ戻らない。
        #expect(ring.latest(8) == newest.samples)
    }

    @Test("公開面を交互に再利用しても、小さい書き込みの履歴と長い書き込みの末尾を保つ")
    func retainedHistory() {
        let ring = SampleRing(capacity: 8)
        var end = 0
        for count in [1, 2, 1, 0, 3, 1, 20, 2, 1, 9, 1] {
            let start = end
            end += count
            ring.write(count: count, hostTime: UInt64(end + 100)) { Float(start + $0) }
            let snapshot = ring.snapshot(8)
            let expected = (end - 8..<end).map { $0 < 0 ? Float(0) : Float($0) }
            #expect(snapshot.samples == expected)
            #expect(snapshot.total == end)
            #expect(snapshot.hostTime == UInt64(end + 100))
        }
        #expect(ring.latest(0).isEmpty)
    }

    @Test("単一書き手/読み手の並行中も、標本・総数・時刻は同じ連続窓を指す")
    func concurrentSnapshots() async {
        let valid = await Task.detached { Self.stressSnapshots() }.value
        #expect(valid)
    }

    private nonisolated static func stressSnapshots() -> Bool {
        let ring = SampleRing(capacity: 64)
        let workers = DispatchGroup()
        let invalid = Atomic<Bool>(false)
        workers.enter()
        DispatchQueue.global().async {
            defer { workers.leave() }
            var total = 0
            for batch in 0..<4000 {
                let count = [1, 3, 11, 64, 129][batch % 5]
                let start = total
                total += count
                ring.write(count: count, hostTime: UInt64(total)) { Float(start + $0) }
            }
        }
        workers.enter()
        DispatchQueue.global().async {
            defer { workers.leave() }
            var last = 0
            for _ in 0..<4000 {
                let snapshot = ring.snapshot(64)
                if snapshot.total < last || snapshot.hostTime != UInt64(snapshot.total) {
                    invalid.store(true, ordering: .relaxed)
                }
                last = snapshot.total
                for (offset, sample) in snapshot.samples.enumerated() {
                    let index = snapshot.total - 64 + offset
                    if sample != (index < 0 ? 0 : Float(index)) {
                        invalid.store(true, ordering: .relaxed)
                    }
                }
            }
        }
        // 待つ側が期限を持つ。仕事自体も固定回数で、失敗しても回り続けない。
        guard workers.wait(timeout: .now() + 15) == .success else { return false }
        return !invalid.load(ordering: .relaxed)
    }
}
