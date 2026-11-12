// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import AVFAudio
import Foundation
import Synchronization
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

/// 機材に出さない流れで、`frames` 標本ぶんを `chunk` 標本ずつ描かせて、左右の音を返す。
func renderBoth(_ flow: SoundFlow, _ frames: Int, chunk: Int = 4096) throws -> (left: [Float], right: [Float]) {
    let output = try #require(
        AVAudioPCMBuffer(
            pcmFormat: flow.engine.manualRenderingFormat,
            frameCapacity: flow.engine.manualRenderingMaximumFrameCount))
    var left: [Float] = []
    var right: [Float] = []
    var remaining = frames
    while remaining > 0 {
        let size = min(remaining, chunk, Int(output.frameCapacity))
        let status = try flow.engine.renderOffline(AVAudioFrameCount(size), to: output)
        #expect(status == .success)
        let data = try #require(output.floatChannelData)
        left += (0..<Int(output.frameLength)).map { data[0][$0] }
        right += (0..<Int(output.frameLength)).map { data[1][$0] }
        remaining -= size
    }
    return (left, right)
}

/// 1 チャンネルの器 (48 kHz)。標本は `values`。
func monoBuffer(_ values: [Float]) throws -> AVAudioPCMBuffer {
    let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1))
    let buffer = try #require(
        AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(values.count)))
    buffer.frameLength = AVAudioFrameCount(values.count)
    let data = try #require(buffer.floatChannelData)
    for (index, value) in values.enumerated() { data[0][index] = value }
    return buffer
}

/// 2 チャンネルの器 (48 kHz)。左右の標本は `left`・`right`。
func stereoBuffer(left: [Float], right: [Float]) throws -> AVAudioPCMBuffer {
    let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2))
    let buffer = try #require(
        AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(left.count)))
    buffer.frameLength = AVAudioFrameCount(left.count)
    let data = try #require(buffer.floatChannelData)
    for index in left.indices {
        data[0][index] = left[index]
        data[1][index] = right[index]
    }
    return buffer
}

/// CPU に負荷を掛ける。コア数ちょうどの busy スレッドを回し、`stop()` か期限で止まる。
///
/// 負荷の重い機械でだけ起きる競合 (#3277) を、手元でも起こすため。**数をコア数に留め、掛ける間を検査の
/// ループの間だけにする** — 並走する他の suite (期限つきの待ちを持つもの) を、少ないコアの CI で揺らさない。
/// **期限を持つ** — 止め忘れても、検査が終わった後に回り続けない。**期限で切れたことは黙らない**
/// (``expired``) — 検査の側が、負荷が最後まで掛かっていたかを見る。
nonisolated final class CPULoad: @unchecked Sendable {
    private let running = Atomic<Bool>(true)
    private let cut = Atomic<Bool>(false)

    init(deadline: TimeInterval = 60) {
        let until = Date().addingTimeInterval(deadline)
        for _ in 0..<ProcessInfo.processInfo.activeProcessorCount {
            Thread.detachNewThread { [self] in
                var x: UInt64 = 0x9E37_79B9_7F4A_7C15
                while running.load(ordering: .relaxed) {
                    for _ in 0..<10_000 { x = x &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407 }
                    if x == 0 { break }
                    if Date() > until {
                        cut.store(true, ordering: .relaxed)
                        break
                    }
                }
            }
        }
    }

    /// 期限で負荷が切れたか。`true` なら、その後の回は負荷なしで走ったことになる。
    var expired: Bool { cut.load(ordering: .relaxed) }

    func stop() {
        running.store(false, ordering: .relaxed)
    }
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

    /// 描いている途中の流れへ鳴らし始めても、直後の最初のウィンドウの先頭の標本から鳴る (#3270・#3277)。
    /// `AVAudioPlayerNode` の命令の取り込みが描くのに間に合わないと、ウィンドウまるごと無音になった (M3 Max で
    /// 5〜10%)。命令を原子値で渡す形では起きないので、回数で数える。
    ///
    /// **負荷なしと負荷ありの両方を回す。** 負荷なしは、`AVAudioPlayerNode` に戻すと確かに赤になる側 (負荷を
    /// 掛けると呼ぶ側も遅れて、取り込みが間に合ってしまい、赤になる回が減る) で、退行の検知役。負荷ありは、
    /// コア数ぶんの busy スレッドを回した重い機械でも、ウィンドウの先頭から鳴ることを見る確認役 (検知役ではない)。
    /// 負荷が期限で切れたら、負荷なしで走った回が混じるので、黙らず失敗にする。
    @Test(
        "描いている途中の流れへ鳴らし始めると、直後に描いたウィンドウの先頭の標本から鳴る",
        arguments: [false, true])
    func startsAtTheFirstSampleOfTheNextWindow(underLoad: Bool) throws {
        let attempts = 200
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4800))
        buffer.frameLength = 4800
        let channels = try #require(buffer.floatChannelData)
        for channel in 0..<2 { for index in 0..<4800 { channels[channel][index] = 0.25 } }
        // 負荷を掛けるのは、このループの間だけ
        let load = underLoad ? CPULoad() : nil
        defer { load?.stop() }
        var silentWindows = 0
        for _ in 0..<attempts {
            let flow = try makeFlow()
            // 書き出しの音声トラックと同じく、何も出さない節も繋いでおく (``SoundTrackMixer`` の無音の節)
            let silent = AVAudioSourceNode { _, _, _, list in
                for buffer in UnsafeMutableAudioBufferListPointer(list) {
                    if let data = buffer.mData { memset(data, 0, Int(buffer.mDataByteSize)) }
                }
                return noErr
            }
            #expect(flow.join(silent, format: format))
            let player = try #require(FilePlayer(flow: flow, buffer: buffer))
            _ = try render(flow, 2400)
            player.play(from: 0, looping: false)
            let window = try render(flow, 800)
            if !window.allSatisfy({ $0 == 0.25 }) { silentWindows += 1 }
            player.leave()
        }
        let loadWasCut = load?.expired ?? false
        load?.stop()
        #expect(!loadWasCut, "負荷が期限で切れた: 残りの回は負荷なしで走った")
        #expect(silentWindows == 0, "\(attempts) 回のうち \(silentWindows) 回、ウィンドウの先頭から鳴らなかった")
    }

    @Test("途中から鳴らす・ループの折り返しは、描き出しの区切りをまたいでも同じ標本になる")
    func loopWrapsAcrossRenderChunks() throws {
        let flow = try makeFlow()
        let player = try #require(FilePlayer(flow: flow, buffer: try rampBuffer(1000)))
        player.play(from: 600, looping: true)
        // 7 標本ずつ描く: 器の終わり (1000) と描き出しの区切りが揃わない
        var heard: [Float] = []
        for _ in 0..<300 { heard += try render(flow, 7) }
        let expected = (0..<2100).map { Float(($0 + 600) % 1000) / 1000 }
        expectNear(heard, expected)
        #expect(player.played == 2100)
        player.leave()
    }

    /// 終わり以降の始まり (`start >= length`) は、1 度だけなら鳴らす残りが無いので無音で、ループなら頭から鳴る
    /// (ラックの節 (``FileNode``) と同じ・#3303)。頭から鳴らし直すのは、始まりを決める `Playhead` の仕事。
    @Test("終わり以降から始めた区切りは、1 度だけなら無音のまま、ループなら頭から鳴る。描いた数は進む")
    func startingAtTheEndPlaysNothingOnceAndTheHeadWhenLooping() throws {
        let flow = try makeFlow()
        let player = try #require(FilePlayer(flow: flow, buffer: try rampBuffer(1000)))
        for start in [1000, 1500] {
            player.play(from: start, looping: false)
            let silent = try render(flow, 600)
            #expect(silent.allSatisfy { $0 == 0 }, "1 度だけ・start \(start): 頭の音が出ている")
            #expect(player.played == 600, "無音でも描いた数は進む")
            player.play(from: start, looping: true)
            let heard = try render(flow, 300)
            expectNear(heard, (0..<300).map { Float($0) / 1000 })
        }
        player.leave()
    }

    @Test("1 度だけなら、器の終わりより後は無音のまま、止めるまで描いた数が進む")
    func playedOnceKeepsCountingAfterTheEnd() throws {
        let flow = try makeFlow()
        let player = try #require(FilePlayer(flow: flow, buffer: try rampBuffer(1000)))
        player.play(from: 400, looping: false)
        let heard = try render(flow, 800)
        expectNear(Array(heard.prefix(600)), (400..<1000).map { Float($0) / 1000 })
        #expect(heard.suffix(200).allSatisfy { $0 == 0 })
        #expect(player.played == 800, "鳴らし終えた後も、止めるまで描いた数は進む")
        player.leave()
    }

    @Test("音の側は、無音だけを書いた描き出しで無音の印を返す (止めている間・鳴らし終えた後)")
    func voiceReportsSilentRenders() throws {
        let voice = try #require(FileVoice(buffer: try rampBuffer(100)))
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2))
        let out = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 64))
        out.frameLength = 64
        let list = UnsafeMutableAudioBufferListPointer(out.mutableAudioBufferList)
        let data = try #require(out.floatChannelData)
        func render() -> Bool {
            for channel in 0..<2 { for index in 0..<64 { data[channel][index] = 9 } }
            return voice.render(frames: 64, into: list)
        }
        func isAllZero() -> Bool { (0..<2).allSatisfy { channel in (0..<64).allSatisfy { data[channel][$0] == 0 } } }
        // まだ何も頼まれていない
        #expect(render() && isAllZero())
        voice.send(.play(start: 0, looping: false), generation: 1)
        #expect(!render(), "音が出る描き出しは無音ではない")
        #expect(!render(), "器の終わりが途中に来る描き出しは、前半が音")
        #expect(render() && isAllZero(), "鳴らし終えた後は無音")
        voice.send(.play(start: 0, looping: true), generation: 2)
        #expect(!render() && !render() && !render(), "ループは鳴り続ける")
        voice.send(.halt, generation: 3)
        #expect(render() && isAllZero(), "止めたら無音")
    }

    @Test("同じ描き出しの前に命令が重なったら、最後の命令だけが効く")
    func onlyTheLastOrderBeforeARenderTakesEffect() throws {
        let flow = try makeFlow()
        let player = try #require(FilePlayer(flow: flow, buffer: try rampBuffer(1000)))
        player.play(from: 100, looping: false)
        player.play(from: 400, looping: false)
        expectNear(try render(flow, 5), (400..<405).map { Float($0) / 1000 })
        // 同じ位置から鳴らし直しても、区切りは始め直す (同じ語を出しても、前の区切りの続きにならない)
        player.play(from: 400, looping: false)
        #expect(player.played == 0)
        expectNear(try render(flow, 5), (400..<405).map { Float($0) / 1000 })
        // 止めてから鳴らし直す: 止めた命令は流れず、鳴らし直しだけが効く
        player.halt()
        player.play(from: 200, looping: false)
        #expect(player.played == 0)
        expectNear(try render(flow, 5), (200..<205).map { Float($0) / 1000 })
        // 鳴らしてすぐ止める: 無音のまま、描いた数は読めない
        player.play(from: 300, looping: false)
        player.halt()
        #expect(player.played == nil)
        #expect(try render(flow, 50).allSatisfy { $0 == 0 })
        player.leave()
    }

    @Test("1 チャンネルの器も、そのまま鳴る")
    func playsAMonoBuffer() throws {
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1000))
        buffer.frameLength = 1000
        let data = try #require(buffer.floatChannelData)
        for index in 0..<1000 { data[0][index] = Float(index) / 1000 }
        let flow = try makeFlow()
        let player = try #require(FilePlayer(flow: flow, buffer: buffer))
        player.play(from: 0, looping: false)
        // 1 チャンネルの音は、流れの混ぜる節が左右へ振り分ける (振り分けの大きさは問わず、形だけを見る)
        let heard = try render(flow, 500)
        #expect(heard.count == 500)
        #expect(heard[0] == 0)
        #expect(heard.dropFirst().allSatisfy { $0 > 0 })
        #expect(zip(heard, heard.dropFirst()).allSatisfy { $0 < $1 }, "傾きが保たれる")
        player.leave()
    }

    /// 定位を入れる前 (#3473 の前) の木で、1 チャンネルの器は流れの混ぜる節が左右とも 1 倍で振り分けていた。
    /// 定位を持つ形でも、既定 (`pan` 0) では左右とも元の標本そのまま (1 標本も違わない)。
    @Test("既定の定位では、1 チャンネルの器は左右とも元の標本そのまま、2 チャンネルの器は左右のまま鳴る")
    func defaultPanKeepsEverySample() throws {
        let values = (0..<3000).map { Float(($0 * 37) % 1001) / 1000 - 0.5 }
        let mono = try makeFlow()
        let monoPlayer = try #require(FilePlayer(flow: mono, buffer: try monoBuffer(values)))
        monoPlayer.play(from: 0, looping: true)
        let heard = try renderBoth(mono, 6000, chunk: 733)
        let expected = (0..<6000).map { values[$0 % 3000] }
        #expect(heard.left == expected, "1 チャンネルの左")
        #expect(heard.right == expected, "1 チャンネルの右")
        monoPlayer.leave()

        let other = values.map { -$0 * 0.5 }
        let stereo = try makeFlow()
        let stereoPlayer = try #require(
            FilePlayer(flow: stereo, buffer: try stereoBuffer(left: values, right: other)))
        stereoPlayer.play(from: 0, looping: false)
        let both = try renderBoth(stereo, 3000)
        #expect(both.left == values && both.right == other)
        stereoPlayer.leave()
    }

    /// 1 チャンネルの器は、中央で 1 になるよう掛け直した等しい大きさの定位 (#3473 の 2026-11-13 の決定)。
    @Test(
        "1 チャンネルの器の定位は 左 √2·cos θ・右 √2·sin θ で、端の反対側は無音",
        arguments: [Float(-1), -0.5, 0.25, 1])
    func monoPanIsEqualPowerScaledToTheCentre(position: Float) throws {
        let values = (0..<2000).map { Float(($0 * 13) % 401) / 400 - 0.5 }
        let flow = try makeFlow()
        let player = try #require(FilePlayer(flow: flow, buffer: try monoBuffer(values)))
        // 鳴らす前に頼んだ定位は、鳴らし始めの頭から効く (移らない)
        player.pan = position
        player.play(from: 0, looping: false)
        let heard = try renderBoth(flow, 2000)
        let angle = Double(position + 1) * 0.25 * Double.pi
        let left = Float(2.0.squareRoot() * cos(angle))
        let right = Float(2.0.squareRoot() * sin(angle))
        let worst = values.indices.map {
            max(abs(heard.left[$0] - values[$0] * left), abs(heard.right[$0] - values[$0] * right))
        }.max() ?? 1
        #expect(worst < 1e-6, "最大のずれ \(worst)")
        if position == -1 { #expect(heard.right.allSatisfy { $0 == 0 }, "左の端で右が無音") }
        if position == 1 { #expect(heard.left.allSatisfy { $0 == 0 }, "右の端で左が無音") }
        // 左右を合わせた大きさは中央 (左右とも 1 倍) と同じ
        #expect(abs(left * left + right * right - 2) < 1e-5)
        player.leave()
    }

    /// 2 チャンネルの器はバランス: 反対側にだけ 1 - |pan| を掛ける直線 (#3473 の 2026-11-13 の決定)。
    @Test("2 チャンネルの器の定位はバランスで、反対側にだけ 1 - |pan| を掛け、手前の側は元のまま")
    func stereoPanIsABalance() throws {
        let leftValues = (0..<2000).map { Float(($0 * 13) % 401) / 400 - 0.5 }
        let rightValues = leftValues.map { 0.25 - $0 * 0.5 }
        for (position, keptLeft, keptRight) in [(Float(-1), Float(1), Float(0)), (0.5, 0.5, 1), (1, 0, 1)] {
            let flow = try makeFlow()
            let player = try #require(
                FilePlayer(flow: flow, buffer: try stereoBuffer(left: leftValues, right: rightValues)))
            player.pan = position
            player.play(from: 0, looping: false)
            let heard = try renderBoth(flow, 2000)
            #expect(heard.left == leftValues.map { $0 * keptLeft }, "pan \(position) の左")
            #expect(heard.right == rightValues.map { $0 * keptRight }, "pan \(position) の右")
            player.leave()
        }
    }

    /// 鳴っている間に変えた定位は、次の描き出しの先頭から約 5 ミリ秒 (48 kHz で 240 標本) の直線で移る。
    /// 移り方は描いた標本の数だけで決まり、描き出しの区切り方に依らない。
    @Test("鳴っている間に変えた定位は、次の描き出しの先頭から 240 標本で移りきり、描き出しの区切り方に依らない")
    func panMovesFromTheNextRenderAndDoesNotDependOnChunks() throws {
        let values = [Float](repeating: 0.5, count: 4000)
        func run(chunk: Int) throws -> (left: [Float], right: [Float]) {
            let flow = try makeFlow()
            let player = try #require(FilePlayer(flow: flow, buffer: try monoBuffer(values)))
            player.play(from: 0, looping: true)
            var heard = try renderBoth(flow, 1000, chunk: chunk)
            player.pan = -1
            let after = try renderBoth(flow, 1000, chunk: chunk)
            heard.left += after.left
            heard.right += after.right
            player.leave()
            return heard
        }
        let whole = try run(chunk: 4096)
        #expect(whole.left[0..<1000].allSatisfy { $0 == 0.5 } && whole.right[0..<1000].allSatisfy { $0 == 0.5 })
        #expect(whole.right[1000] < 0.5 && whole.right[1000] > 0.4, "頼んだ次の描き出しの先頭から移り始める")
        #expect(whole.right[1240...].allSatisfy { $0 == 0 }, "240 標本で移りきる")
        #expect(whole.left[1240...].allSatisfy { abs($0 - 0.5 * Float(2.0.squareRoot())) < 1e-6 })
        let pieces = try run(chunk: 7)
        #expect(pieces.left == whole.left && pieces.right == whole.right)
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
}
