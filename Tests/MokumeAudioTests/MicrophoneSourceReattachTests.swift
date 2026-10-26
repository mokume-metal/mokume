// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Testing

@testable import MokumeAudio
@testable import MokumeCore

/// 実機のマイクの層 (``MicrophoneSource``) で、止めた後に外す前の音が出ないこと (#3122)。GPU も機材も要らない。
///
/// 入り口 (``AudioIn``) の検査は替え玉の出どころを使うので、環 (`ring`) と `lastTotal` の層を通らない。
/// ここは環に直に書き、止めて、取り出しを直に駆動する。
@Suite("実機のマイクの足し直し")
struct MicrophoneSourceReattachTests {
    /// 環に標本を `count` 個書く。
    private func write(_ source: MicrophoneSource, count: Int, value: Float, hostTime: UInt64) {
        source.ring.write(count: count, hostTime: hostTime) { _ in value }
    }

    @Test("止める前に環へ届いて入れ物へ送っていない標本は、止めた後の取り出しで送らない。止めた後に書かれたものは送る")
    func stopDropsWhatWasWrittenButNotSent() {
        let source = MicrophoneSource(device: nil)
        let input = ExternalInput<AudioSpan>(name: "microphone", state: .running)

        // 1 つ目は送って読まれる。2 つ目は環に届いたが、まだ送っていない
        write(source, count: 1024, value: 0.5, hostTime: 1)
        source.pump(into: input, at: 0)
        #expect(input.take() != nil)
        write(source, count: 1024, value: 0.75, hostTime: 2)

        source.stop()
        source.pump(into: input, at: 0)
        #expect(input.take() == nil, "止める前の標本が、止めた後の取り出しで出た")

        // 足し直した後に書かれたものは、送る
        write(source, count: 512, value: 0.25, hostTime: 3)
        source.pump(into: input, at: 0)
        let window = input.take()
        #expect(window != nil)
        #expect(window?.samples.last == 0.25)
    }

    @Test("何も書かれていないまま止めても、止めた後に書かれたものは送る")
    func stopWithNothingWrittenKeepsTheNextOne() {
        let source = MicrophoneSource(device: nil)
        let input = ExternalInput<AudioSpan>(name: "microphone", state: .running)
        source.stop()
        write(source, count: 256, value: 0.5, hostTime: 1)
        source.pump(into: input, at: 0)
        #expect(input.take() != nil)
    }
}
