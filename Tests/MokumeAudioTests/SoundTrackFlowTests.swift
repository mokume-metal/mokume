// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import AVFAudio
import Foundation
import Testing

@testable import MokumeAudio
@testable import MokumeCore

/// 書き出しの音声トラックを描く流れ (`TrackFlow`) と、窓の式 (#3125)。機材にも許可にも GPU にも触れない。
@Suite("書き出しの音声トラック (流れの時間)", .serialized)
struct SoundTrackFlowTests {
    /// 標本の番号だけで決まる、正の単調でない値の器 (1 秒・48 kHz・モノラル)。鳴った位置が値から読める。
    private func ramp(_ count: Int = 48_000) throws -> AVAudioPCMBuffer {
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1))
        let buffer = try #require(
            AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count)))
        buffer.frameLength = AVAudioFrameCount(count)
        let data = try #require(buffer.floatChannelData)[0]
        for index in 0..<count { data[index] = Float(index % 997 + 1) / 2000 }
        return buffer
    }

    /// ループで鳴らし続ける流れ。
    private func loopingTrack(base: Int = 0) throws -> (TrackFlow, FilePlayer) {
        let flow = try SoundFlow.offline(sampleRate: 48_000, channels: 2, maximumFrames: 4096)
        let player = try #require(FilePlayer(flow: flow, buffer: try ramp()))
        player.play(from: 0, looping: true)
        return (TrackFlow(flow: flow, base: base), player)
    }

    private let count = 800

    @Test("描けなかった窓は無音になるが、流れの時間は描き足して戻るので、以後の窓は元の時刻の標本になる")
    func aFailedRenderDoesNotShiftLaterWindows() throws {
        let (reference, playerA) = try loopingTrack()
        let (broken, playerB) = try loopingTrack()
        defer {
            playerA.leave()
            playerB.leave()
        }
        // 3 回目の描きだけが失敗する (窓 2 の分)
        var calls = 0
        broken.renderChunk = { engine, frames, buffer in
            calls += 1
            if calls == 3 { return false }
            return (try? engine.renderOffline(frames, to: buffer)) == .success
        }
        for window in 0..<10 {
            let end = (window + 1) * count
            let good = reference.advance(to: end, keeping: count)
            let actual = broken.advance(to: end, keeping: count)
            #expect(good.complete)
            switch window {
            case 2:
                #expect(!actual.complete, "失敗した窓が描き切れたことになっている")
                #expect(actual.left.allSatisfy { $0 == 0 }, "失敗した窓の音は無音にする")
            default:
                #expect(actual.complete, "窓 \(window)")
                // 失敗した窓の前後で、窓の標本は失敗の無い流れと 1 ビットも違わない (時刻がずれていない)
                #expect(actual.left == good.left && actual.right == good.right, "窓 \(window) の標本が違う")
            }
        }
        #expect(broken.rendered == reference.rendered)
    }

    @Test("頼まれなかったフレームの分を捨てて描き進めても、次の窓は失敗の無い流れと同じ標本になる")
    func skippingAheadKeepsTheFlowInStep() throws {
        let (reference, playerA) = try loopingTrack()
        let (skipping, playerB) = try loopingTrack()
        defer {
            playerA.leave()
            playerB.leave()
        }
        let window = 5
        let end = (window + 1) * count
        let good = reference.advance(to: end, keeping: count)
        // 窓 0〜4 は頼まれず、捨てる
        #expect(skipping.advance(to: window * count, keeping: 0).complete)
        let actual = skipping.advance(to: end, keeping: count)
        #expect(actual.left == good.left && actual.right == good.right)
        #expect(actual.left.contains { $0 != 0 })
    }

    @Test("流れが描けなければ、描き切れなかったと返し、無音を返す (落ちない)")
    func aFlowThatCannotStartReportsIncomplete() throws {
        let (track, player) = try loopingTrack()
        defer { player.leave() }
        track.renderChunk = { _, _, _ in false }
        let rendered = track.advance(to: count, keeping: count)
        #expect(rendered.complete == false)
        #expect(rendered.left == [Float](repeating: 0, count: count))
    }
}

/// 窓の式は Core の `SoundWindow` と Audio の `FrameSamples` に 1 つずつある (Core は Audio を読み込めない)。
/// 食い違うと、音声トラックの窓と、音源が数える位置が同じ時刻を指さなくなる ([ADR-0042] 決定 6 の改訂)。
///
/// [ADR-0042]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0042-camera-and-audio-standard.md
nonisolated struct SoundWindowFormulaTests {
    @Test("SoundWindow の窓の先頭・長さは、FrameSamples の式 (⌊N·sr/fps⌋) と、どの fps・どのフレームでも一致する")
    func theTwoFormulasAgree() {
        let rates = [1, 24, 25, 29, 30, 44, 48, 50, 59, 60, 90, 96, 120, 144, 240, 1000, 47_999, 48_000, 96_000]
        for fps in rates {
            for frame in Array(0..<1200) + [10_000, 123_457, 1_000_003] {
                let start = SoundWindow.start(ofFrame: frame, frameRate: fps)
                #expect(
                    start == FrameSamples.start(ofFrame: frame, perSecond: fps, sampleRate: 48_000),
                    "fps \(fps) フレーム \(frame)")
                #expect(
                    SoundWindow.count(ofFrame: frame, frameRate: fps)
                        == FrameSamples.count(from: frame, to: frame + 1, perSecond: fps, sampleRate: 48_000),
                    "fps \(fps) フレーム \(frame) の長さ")
            }
        }
    }
}
