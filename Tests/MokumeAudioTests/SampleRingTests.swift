// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import CoreAudio
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
        #expect(ring.lastHostTime == 7)
    }

    @Test("一周した後も、最新の窓が古い順に並ぶ")
    func latestAfterWrapping() {
        let ring = SampleRing(capacity: 8)
        var next: Float = 0
        for _ in 0..<5 {
            ring.write(count: 3, hostTime: 0) { _ in defer { next += 1 }; return next }
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
                    mNumberChannels: 2, mDataByteSize: UInt32(bytes.count), mData: bytes.baseAddress))
            var stamp = AudioTimeStamp()
            stamp.mHostTime = 42
            stamp.mFlags = .hostTimeValid
            MicrophoneSource.mix(&list, frames: 3, timestamp: &stamp, into: ring)
        }
        #expect(ring.latest(3) == [0.5, 0.5, 0])
        #expect(ring.lastHostTime == 42)
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
