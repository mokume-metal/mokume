// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import AVFoundation
import Foundation
import MokumeTestSupport
import Testing

@testable import MokumeAudio
@testable import MokumeCore

/// 値の並びの指紋 (FNV-1a をビット列に掛けたもの)。1 ビットでも違えば変わる。
func fingerprint(_ values: [Float]) -> UInt64 {
    var hash: UInt64 = 0xcbf2_9ce4_8422_2325
    for value in values {
        var bits = UInt64(value.bitPattern)
        for _ in 0..<4 {
            hash = (hash ^ (bits & 0xff)) &* 0x0000_0100_0000_01b3
            bits >>= 8
        }
    }
    return hash
}

/// 既定の速さ (#3473 の不変条件)。**速さを入れる前の木 (feat/soundfile-pan の 73217711) で同じ操作の列を回した
/// 指紋**と突き合わせる。期待の値は、直す前の木の `Sources/MokumeAudio` に差し替えてこの suite を回し、出た値を
/// 写した (この枝の出力を写していない)。指紋をとった列 (`askingRateOne` が `false`・`anchors` が `.none`) は速さの
/// API を使わない。それ以外の回は、同じ列の途中で速さ 1 を頼む (錨を足す・頭の速さを置き直す・錨を捨てる) だけで、
/// 同じ指紋になることを見る — 速さ 1 の錨を足した区切りは、速さを入れる前の式でなく錨から導く式を通る。
///
/// OS の変換に依る経路 (器の標本化率が出力と違う直の経路) は、OS の版で標本が変わりうるので指紋にしない — 48 kHz の
/// 器だけを鳴らす。ラックの節 (``FileNode``) は変換を自分で持つので、44.1 kHz・96 kHz も指紋にする。
@Suite("既定の速さは直す前と同じ標本", .serialized)
struct RateBaselineTests {
    /// 位置ごとに違う値の標本列。
    private static func steps(_ count: Int, seed: Int) -> [Float] {
        (0..<count).map { Float((($0 &* 7919 &+ seed) % 2003) - 1001) / 1200 }
    }

    /// 速さ 1 の錨の足し方。
    enum RateOneAnchors: CaseIterable, Sendable {
        /// 速さの API を使わない (指紋をとった列)。
        case none
        /// 途中で速さ 1 を頼む。始め直しは錨を持ち越す (鳴らす側の道)。
        case set
        /// 途中で速さ 1 を頼み、区切りの頭から速さ 1 にし直し (``Playhead/retime(_:kernel:)``)、区間ごとに古い錨を捨て
        /// (``Playhead/forget(before:)``)、始め直しはいまの位置を新しい錨にする (ラックの節の道)。
        case setRetimeAndForget
    }

    @Test(
        "再生位置 (Playhead) の位置・番号・包絡の数・終わり・区間の標本が、直す前の木と同じ (速さ 1 を頼んでも)",
        arguments: RateOneAnchors.allCases)
    func playheadMatchesTheOldTree(anchors: RateOneAnchors) {
        let askingRateOne = anchors != .none
        let reshaping = anchors == .setRetimeAndForget
        let samples = Self.steps(1000, seed: 3)
        var seen: [Float] = []
        func note(_ head: inout Playhead, _ played: Int, covered: inout Int) {
            seen.append(Float(head.position(after: played)))
            seen.append(Float(head.number(after: played)))
            seen.append(Float(head.heard(after: played)))
            seen.append(head.hasEnded(after: played) ? 1 : 0)
            let span = head.span(of: samples, from: covered, after: played)
            covered = span.to
            seen.append(Float(span.base))
            seen.append(Float(span.from))
            seen += span.samples
            if reshaping { head.forget(before: AudioAnalysis.firstNeeded(from: covered)) }
        }
        // 1 度だけ: 終わりを越えて数える
        var head = Playhead(length: samples.count)
        var covered = 0
        head.play(looping: false)
        if askingRateOne { head.setRate(1, kernel: nil, at: 400) }
        if reshaping { head.retime(1, kernel: nil) }
        for played in stride(from: 0, through: 1200, by: 37) { note(&head, played, covered: &covered) }
        // ループ: 何周かした後に位置の側で始め直し、その後も数える
        head = Playhead(length: samples.count)
        covered = 0
        head.play(looping: true)
        if askingRateOne { head.setRate(1, kernel: nil, at: 700) }
        if reshaping { head.retime(1, kernel: nil) }
        for played in stride(from: 0, through: 2600, by: 113) { note(&head, played, covered: &covered) }
        head.carry(after: 2523, keepingAnchor: !reshaping)
        if askingRateOne { head.setRate(1, kernel: nil, at: 200) }
        for played in stride(from: 0, through: 1500, by: 97) { note(&head, played, covered: &covered) }
        // 鳴っている間の飛び・止めて鳴らし直す・頭へ戻す
        head.jump(to: 300)
        covered = head.start
        for played in stride(from: 0, through: 900, by: 61) { note(&head, played, covered: &covered) }
        head.pause(after: 250)
        head.play(looping: false)
        covered = head.start
        for played in stride(from: 0, through: 1000, by: 83) { note(&head, played, covered: &covered) }
        head.stop()
        seen.append(Float(head.position(after: 10)))
        #expect(fingerprint(seen) == 13_485_400_147_340_943_350, "指紋 \(fingerprint(seen))")
    }

    @Test(
        "ラックの節 (48 kHz・44.1 kHz・96 kHz のファイル) の標本と鳴った数が、直す前の木と同じ (速さ 1 を頼んでも)",
        arguments: [false, true])
    func fileNodeMatchesTheOldTree(askingRateOne: Bool) throws {
        var seen: [Float] = []
        for fileRate in [48_000.0, 44_100.0, 96_000.0] {
            let rack = SynthRack(sampleRate: 48_000)
            let samples = Self.steps(9000, seed: Int(fileRate) % 97)
            let node = try #require(rack.addFile(samples: samples, fileRate: fileRate, amplitude: 0.8))
            func begin(_ start: Int, looping: Bool, generation: Int) {
                rack.post(
                    SynthCommand(
                        op: .segment, node: UInt8(node.id),
                        bits: FileNode.segment(start: start, looping: looping, generation: generation)))
            }
            /// `frames` 標本を描く。`midway` があれば、`midway` 標本描いたところで速さ 1 を頼んでから残りを描く。
            func take(_ frames: Int, generation: Int, midway: Int? = nil) {
                var heard = render(rack, pieces: [(midway ?? frames) / 3, (midway ?? frames) - (midway ?? frames) / 3])
                if let midway {
                    _ = node.link.absorb()
                    node.link.request(1, kernel: nil)
                    let rest = render(rack, frames - midway)
                    _ = node.link.absorb()
                    heard.left += rest.left
                    heard.right += rest.right
                }
                seen += heard.left
                seen += heard.right
                seen.append(Float(node.played(generation: generation)))
            }
            begin(100, looping: false, generation: 1)
            take(3000, generation: 1)
            // 鳴っている最中に始め直す (前の区切りは消えながら残る)。速さ 1 を頼むのは 48 kHz のファイルだけ — 率の違う
            // ファイルは、錨を置き直すと率の比を掛けて割る丸めが変わる (速さを 1 に戻した後の音は、変える前と同じとは約束しない。
            // ``SoundFile`` は同じ速さの頼みを節へ渡さない)
            begin(4000, looping: true, generation: 2)
            take(7000, generation: 2, midway: askingRateOne && fileRate == 48_000 ? 1200 : nil)
            // 包絡を掛けて始め直す
            let shaping: [SynthCommand] =
                [
                    (SynthParam.attack, Float(0.01)), (.sustain, 0.02), (.level, 0.7), (.release, 0.03),
                ].map {
                    SynthCommand(op: .set, node: UInt8(node.id), param: $0.0, bits: UInt64($0.1.bitPattern))
                } + [SynthCommand(op: .envelope, node: UInt8(node.id), bits: 0)]
            rack.postReservation(
                [
                    SynthCommand(
                        op: .segment, node: UInt8(node.id),
                        bits: FileNode.segment(start: 8000, looping: false, generation: 3))
                ] + shaping)
            take(5000, generation: 3)
            rack.post(SynthCommand(op: .stop, node: UInt8(node.id)))
            take(1000, generation: 3)
        }
        #expect(fingerprint(seen) == 16_389_956_921_857_717_520, "指紋 \(fingerprint(seen))")
    }

    @Test(
        "直に鳴らす経路 (48 kHz のモノラル・ステレオ) の左右の標本が、直す前の木と同じ (速さ 1 を頼んでも)",
        arguments: [false, true])
    func filePlayerMatchesTheOldTree(askingRateOne: Bool) throws {
        var seen: [Float] = []
        let mono = try monoBuffer(Self.steps(5000, seed: 11))
        let stereo = try stereoBuffer(left: Self.steps(5000, seed: 13), right: Self.steps(5000, seed: 17))
        for buffer in [mono, stereo] {
            let flow = try SoundFlow.offline(sampleRate: 48_000, channels: 2, maximumFrames: 4096)
            let player = try #require(FilePlayer(flow: flow, buffer: buffer))
            /// `frames` 標本を描く。`midway` があれば、`midway` 標本描いたところで速さ 1 を頼んでから残りを描く。
            func take(_ frames: Int, midway: Int? = nil) throws {
                var heard = try renderBoth(flow, midway ?? frames, chunk: 700)
                if let midway {
                    _ = player.absorbRate()
                    player.rate(1, kernel: nil)
                    let rest = try renderBoth(flow, frames - midway, chunk: 700)
                    _ = player.absorbRate()
                    heard.left += rest.left
                    heard.right += rest.right
                }
                seen += heard.left
                seen += heard.right
                seen.append(Float(player.played ?? -1))
            }
            player.play(from: 200, looping: false)
            try take(3000)
            player.play(from: 4000, looping: true)
            try take(4000, midway: askingRateOne ? 1500 : nil)
            player.pan = -0.5
            try take(2000)
            var shape = EnvelopeShape()
            shape.attack = 400
            shape.sustain = 900
            shape.release = 700
            shape.level = 0.6
            player.play(from: 0, looping: false, envelope: FileEnvelope(shape: shape, offset: 0))
            try take(3000)
            player.halt()
            try take(500)
        }
        #expect(fingerprint(seen) == 14_361_030_372_889_303_743, "指紋 \(fingerprint(seen))")
    }
}

/// 既定の速さ (#3473 の不変条件) を `SoundFile` の層で見る。``RateBaselineTests`` と同じく、**速さを入れる前の木
/// (73217711) の `Sources/MokumeAudio` に差し替えて同じ列を回した指紋**を期待にする。`SoundFile` が既定の経路で通る
/// 所 (包絡の位置の引き方・区間ごとの錨の片付け・鳴った数を読む所・録りへ移る順) を、固定の時計の書き出し全体で見る。
///
/// 列は、ループ・包絡・鳴っている間の飛び・止めて再開・録りへ移る (書き出しの時計から鳴らす経路へ)・止めている間の
/// 飛び・1 度だけの終わりを含む。毎フレームの位置と解析の値と、書いた `.mov` の音声トラックの標本を指紋にする。
/// 走っているスケッチの中で回して書き出すので GPU を要する。器は 48 kHz だけ (OS の変換に依らない)。
@Suite(
    "既定の速さは直す前と同じ書き出し (SoundFile)",
    .serialized,
    .enabled(
        if: RenderDevice.isAvailable,
        "この世代のコマンド構造に対応した GPU が無い実行環境ではスキップする")
)
struct SoundFileRateBaselineTests {
    /// 書いた `.mov` の音声トラックの標本 (左右を交互に並べたまま)。
    private func interleavedTrack(_ url: URL) async throws -> [Float] {
        let asset = AVURLAsset(url: url)
        let track = try #require(try await asset.loadTracks(withMediaType: .audio).first)
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(
            track: track,
            outputSettings: [
                AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMBitDepthKey: 32,
                AVLinearPCMIsFloatKey: true, AVLinearPCMIsBigEndianKey: false,
                AVLinearPCMIsNonInterleaved: false,
            ])
        reader.add(output)
        try #require(reader.startReading(), "音声を読み始められない: \(String(describing: reader.error))")
        var interleaved: [Float] = []
        while let buffer = output.copyNextSampleBuffer() {
            guard let block = CMSampleBufferGetDataBuffer(buffer) else { continue }
            var length = 0
            var pointer: UnsafeMutablePointer<Int8>?
            CMBlockBufferGetDataPointer(
                block, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &length, dataPointerOut: &pointer)
            guard let pointer else { continue }
            interleaved += Array(
                UnsafeBufferPointer(
                    start: UnsafeRawPointer(pointer).assumingMemoryBound(to: Float.self),
                    count: length / MemoryLayout<Float>.size))
        }
        return interleaved
    }

    @Test(
        "SoundFile を通した固定の時計の書き出し (位置・解析の値・音声トラック) が、直す前の木と同じ (直に鳴らす・エフェクトへ通す)",
        arguments: [false, true])
    func exportMatchesTheOldTree(routed: Bool) async throws {
        // 0.75 秒 (45 フレーム) の、位置ごとに違う値
        // 下限の Swift 6.3 が推論しきれないので、閉包の型を書く
        let values = (0..<36_000).map { (index: Int) -> Float in Float(((index &* 7919 &+ 5) % 2003) - 1001) / 1200 }
        let wav = try writeWAV(values, sampleRate: 48_000)
        defer { try? FileManager.default.removeItem(at: wav) }
        let url = TestScratch.path("mokume-rate-baseline", pathExtension: "mov")
        defer { try? FileManager.default.removeItem(at: url) }
        var sound: SoundFile?
        var seen: [Float] = []
        SoundSketch.onSetup = { sketch in
            let loaded = try sketch.loadSound(wav.path)
            if routed {
                let filter = sketch.createLowPass()
                filter.freq(20_000)
                filter.process(loaded)
            }
            sound = loaded
        }
        SoundSketch.onDraw = { sketch in
            guard let sound else { return }
            seen += [
                sound.position, sound.isPlaying ? 1 : 0, sound.level, sound.rms, sound.peak, sound.isBeat ? 1 : 0,
            ]
            seen += sound.spectrum
            switch sketch.frameCount {
            case 1: sound.loop()
            case 6: sound.triggerEnvelope(attack: 0.02, sustain: 0.05, level: 0.8, release: 0.03)
            case 12: sound.jump(0.3)
            case 16: sound.pause()
            case 19: sound.play()
            case 22: sketch.beginRecord(url.path)
            case 27: sound.jump(0.1)
            case 31: sound.triggerEnvelope(attack: 0.01, sustain: 0.02, level: 0.6, release: 0.05)
            case 36: sound.pause()
            case 38: sound.loop()
            case 45: sound.stop()
            case 46: sound.jump(0.6)
            case 47: sound.play()
            case 70: sketch.endRecord()
            default: break
            }
        }
        let runtime = try SketchRuntime(
            sketch: SoundSketch(), gpu: try RenderDevice(), clock: .frameIndex(frameRate: 60))
        for _ in 0..<70 { try runtime.advance() }
        runtime.closePlugins()
        let track = try await interleavedTrack(url)
        // 録りは 22 フレーム目に頼んで 70 フレーム目に止める (48 フレーム・2 チャンネル)
        #expect(track.count == 48 * 800 * 2, "\(track.count) 標本")
        seen += track
        let expected: UInt64 = routed ? 5_132_911_987_656_980_455 : 8_164_350_754_493_010_403
        #expect(fingerprint(seen) == expected, "指紋 \(fingerprint(seen))")
    }
}
