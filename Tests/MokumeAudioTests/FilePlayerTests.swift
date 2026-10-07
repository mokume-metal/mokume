// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import AVFAudio
import Testing

@testable import MokumeAudio

/// 左右とも、標本の値が `位置 ÷ count` になる器 (2 チャンネル・48 kHz)。鳴った音を見れば、
/// どこを鳴らしたかが読める。
func rampBuffer(_ count: Int) throws -> AVAudioPCMBuffer {
    let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2))
    let buffer = try #require(
        AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count)))
    buffer.frameLength = AVAudioFrameCount(count)
    let channels = try #require(buffer.floatChannelData)
    for channel in 0..<2 {
        for index in 0..<count { channels[channel][index] = Float(index) / Float(count) }
    }
    return buffer
}

/// 機材に出さない流れで、`frames` 標本ぶん描かせて左の音を返す。
func render(_ flow: SoundFlow, _ frames: Int) throws -> [Float] {
    let output = try #require(
        AVAudioPCMBuffer(
            pcmFormat: flow.engine.manualRenderingFormat,
            frameCapacity: flow.engine.manualRenderingMaximumFrameCount))
    var left: [Float] = []
    var remaining = frames
    while remaining > 0 {
        let chunk = min(remaining, Int(output.frameCapacity))
        let status = try flow.engine.renderOffline(AVAudioFrameCount(chunk), to: output)
        #expect(status == .success)
        let data = try #require(output.floatChannelData)[0]
        left += (0..<Int(output.frameLength)).map { data[$0] }
        remaining -= chunk
    }
    return left
}

/// 実際に鳴らす (#1979)。manual rendering (offline) の流れで回すので、出力の機材にも GPU にも
/// 触れない ([ADR-0042] 決定 6)。描いた分だけ時間が進むので、決定論的に走る。
///
/// [ADR-0042]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0042-camera-and-audio-standard.md
@Suite("鳴らす", .serialized)
struct FilePlayerTests {
    private func makeFlow() throws -> SoundFlow {
        try SoundFlow.offline(sampleRate: 48_000, channels: 2, maximumFrames: 4096)
    }

    private func expectNear(_ actual: [Float], _ expected: [Float], _ comment: Comment? = nil) {
        #expect(actual.count == expected.count, comment)
        let worst = zip(actual, expected).map { abs($0 - $1) }.max() ?? 0
        #expect(worst < 1e-6, comment)
    }

    @Test("頭から鳴らすと、器の音がそのまま出て、描いた数だけ位置が進む")
    func playsFromTheHead() throws {
        let flow = try makeFlow()
        let buffer = try rampBuffer(1000)
        let player = try #require(FilePlayer(flow: flow, buffer: buffer))
        player.play(from: 0, looping: false)
        // まだ 1 度も描いていない流れでは、描いた数は読めない (呼ぶ側は 0 として扱う)
        #expect((player.played ?? 0) == 0)
        let heard = try render(flow, 300)
        expectNear(heard, (0..<300).map { Float($0) / 1000 })
        #expect(player.played == 300)
        // 1 度だけなら、終わりより後は無音
        let rest = try render(flow, 900)
        expectNear(Array(rest.prefix(700)), (300..<1000).map { Float($0) / 1000 })
        #expect(rest.suffix(200).allSatisfy { $0 == 0 })
        player.leave()
    }

    @Test("途中から鳴らすと、その位置から鳴り、ループなら終わりから頭へ続く")
    func playsFromTheMiddleAndLoops() throws {
        let flow = try makeFlow()
        let buffer = try rampBuffer(1000)
        let player = try #require(FilePlayer(flow: flow, buffer: buffer))

        player.play(from: 600, looping: false)
        let once = try render(flow, 500)
        expectNear(Array(once.prefix(400)), (600..<1000).map { Float($0) / 1000 })
        #expect(once.suffix(100).allSatisfy { $0 == 0 })

        player.play(from: 600, looping: true)
        #expect(player.played == 0, "鳴らし直すと、描いた数は区切りの始まりから数え直す")
        let looped = try render(flow, 1500)
        let expected = (600..<1000).map { Float($0) / 1000 } + (0..<1000).map { Float($0) / 1000 }
            + (0..<100).map { Float($0) / 1000 }
        expectNear(looped, expected)
        #expect(player.played == 1500)
        player.leave()
    }

    @Test("止めると無音になり、描いた数は読めなくなる")
    func haltSilences() throws {
        let flow = try makeFlow()
        let player = try #require(FilePlayer(flow: flow, buffer: try rampBuffer(1000)))
        player.play(from: 0, looping: true)
        _ = try render(flow, 200)
        player.halt()
        #expect(player.played == nil)
        #expect(try render(flow, 200).allSatisfy { $0 == 0 })
        player.leave()
    }

    @Test("音量を下げると、落ち着いた後の音がその倍率になる")
    func volumeScales() throws {
        let flow = try makeFlow()
        let player = try #require(FilePlayer(flow: flow, buffer: try rampBuffer(48_000)))
        player.volume = 0.5
        player.play(from: 0, looping: false)
        // 音量は滑らかに移るので、移り終えた後ろだけを見る
        let heard = try render(flow, 8192)
        let tail = Array(heard.suffix(1000))
        let expected = (7192..<8192).map { 0.5 * Float($0) / 48_000 }
        let worst = zip(tail, expected).map { abs($0 - $1) }.max() ?? 1
        #expect(worst < 1e-4)
        player.leave()
    }

    @Test("後ろ側を指す器は、元の器を手放しても同じ標本を指し続ける")
    func tailKeepsTheSourceAlive() throws {
        var tail: AVAudioPCMBuffer?
        do {
            let buffer = try rampBuffer(1000)
            tail = FilePlayer.tail(of: buffer, from: 990)
        }
        let kept = try #require(tail)
        #expect(kept.frameLength == 10)
        let data = try #require(kept.floatChannelData)
        #expect((0..<10).map { data[1][$0] } == (990..<1000).map { Float($0) / 1000 })
    }

    @Test("後ろ側は、始まりが 0 以下か終わり以上なら作らない (器そのものを鳴らす)")
    func tailBoundaries() throws {
        let buffer = try rampBuffer(1000)
        #expect(FilePlayer.tail(of: buffer, from: 0) == nil)
        #expect(FilePlayer.tail(of: buffer, from: 1000) == nil)
        #expect(FilePlayer.tail(of: buffer, from: 999)?.frameLength == 1)
    }
}
