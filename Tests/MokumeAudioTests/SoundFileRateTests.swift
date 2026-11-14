// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import AVFAudio
import Foundation
import MokumeTestSupport
import Testing

@testable import MokumeAudio
@testable import MokumeCore

/// `SoundFile.rate(_:)` (#3473)。走っているスケッチの中で回すので GPU を要する。書き出しの時計 (鳴らさない)・機材に
/// 出さない流れで鳴らす経路・エフェクトへ通した経路で、位置と解析が同じ操作から同じに進むことを見る。
@Suite(
    "音声ファイルの速さ",
    .serialized,
    .enabled(
        if: RenderDevice.isAvailable,
        "この世代のコマンド構造に対応した GPU が無い実行環境ではスキップする")
)
struct SoundFileRateTests {
    /// 60 fps・48 kHz の 1 フレームぶんの標本の数。
    private static let perFrame = 800

    /// 1 フレームの `draw()` で読んだもの。
    private struct Seen: Equatable {
        var position: Float
        var isPlaying: Bool
        var level: Float
        var rms: Float
        var peak: Float
        var spectrum: [Float]
    }

    /// 走らせて、`draw()` で読んだものをフレームごとに返す。`act` は読んだ後に、そのフレームの番号で呼ぶ。`flow` が
    /// あれば、その流れで鳴らし、フレームの間に 1 フレームぶん描かせる (無ければ書き出しの時計で、鳴らさない)。
    private func run(
        frames: Int, flow: SoundFlow? = nil, warn: @escaping (String) -> Void = { _ in },
        routed: Bool = false,
        make: @escaping (SoundSketch) throws -> AVAudioPCMBuffer,
        act: @escaping (SoundFile, Int) -> Void
    ) throws -> [Seen] {
        var sound: SoundFile?
        var seen: [Seen] = []
        SoundSketch.onSetup = { sketch in
            let made = SoundFile(
                name: "rate.wav", buffer: try make(sketch), owner: sketch, flow: flow, warn: warn)
            sketch.attach(made)
            if routed {
                let filter = sketch.createLowPass()
                filter.freq(20_000)
                filter.process(made)
            }
            sound = made
        }
        SoundSketch.onDraw = { sketch in
            guard let sound else { return }
            seen.append(
                Seen(
                    position: sound.position, isPlaying: sound.isPlaying, level: sound.level, rms: sound.rms,
                    peak: sound.peak, spectrum: sound.spectrum))
            act(sound, sketch.frameCount)
        }
        let runtime = try SketchRuntime(
            sketch: SoundSketch(), gpu: try RenderDevice(),
            clock: flow == nil ? .frameIndex(frameRate: 60) : nil)
        for _ in 0..<frames {
            try runtime.advance()
            if let flow { _ = try renderBoth(flow, Self.perFrame) }
        }
        runtime.closePlugins()
        return seen
    }

    /// 1 チャンネル・48 kHz の器。
    private static func buffer(_ values: [Float]) throws -> AVAudioPCMBuffer {
        try monoBuffer(values)
    }

    /// `seconds` 秒の `frequency` Hz の正弦 (振幅 0.5)。
    private static func sine(_ frequency: Double, seconds: Double) -> [Float] {
        (0..<Int(seconds * 48_000)).map { Float(0.5 * sin(2 * Double.pi * frequency * Double($0) / 48_000)) }
    }

    // MARK: - 位置 (完了条件 1・2)

    @Test("rate(2) の後 60 フレームで position が 2.0 秒、rate(0.5) で 0.5 秒進む。替えても跳ばず、替えたフレームの position は替える前のまま。同じ速さを毎フレーム渡しても同じ")
    func positionAdvancesWithTheRate() throws {
        let values = [Float](repeating: 0.1, count: 48_000 * 10)
        func positions(everyFrame: Bool) throws -> [Float] {
            try run(
                frames: 125, make: { _ in try Self.buffer(values) },
                act: { sound, frame in
                    if frame == 1 { sound.play() }
                    if frame == 2 || (everyFrame && (3...61).contains(frame)) { sound.rate(2) }
                    if frame == 62 || (everyFrame && frame > 62) { sound.rate(0.5) }
                }
            ).map(\.position)
        }
        let seen = try positions(everyFrame: false)
        // フレームの番号は 1 から、seen[n - 1] がフレーム n で読んだ値
        #expect(seen[1] == Float(1) / 60, "速さを替えたフレームは替える前の値")
        #expect(abs(seen[61] - seen[1] - 2) < 1e-5, "\(seen[61] - seen[1])")
        #expect(abs(seen[121] - seen[61] - 0.5) < 1e-5, "\(seen[121] - seen[61])")
        // 替えた点の前後で、1 フレームの進みは前の速さ・新しい速さのぶんだけ (跳ばない)
        #expect(abs((seen[62] - seen[61]) - Float(0.5) / 60) < 1e-6)
        #expect(try positions(everyFrame: true) == seen)
    }

    @Test("rate(0) は位置を進めず、鳴っているまま。解析の値は前の値のまま。動き出すと止まった位置から")
    func zeroHoldsThePosition() throws {
        let seen = try run(
            frames: 40, make: { _ in try Self.buffer(Self.sine(440, seconds: 2)) },
            act: { sound, frame in
                if frame == 1 { sound.play() }
                if frame == 10 { sound.rate(0) }
                if frame == 30 { sound.rate(1) }
            })
        #expect(seen[10...29].allSatisfy { $0.position == seen[10].position && $0.isPlaying })
        #expect(seen[11...29].allSatisfy { $0.level == seen[10].level && $0.spectrum == seen[10].spectrum })
        #expect(seen[10].level > 0)
        #expect(seen[31].position > seen[30].position)
        #expect(abs((seen[30].position - seen[29].position) - Float(1) / 60) < 1e-6)
    }

    @Test("rate(-1)・rate(.nan)・rate(.infinity) は速さを変えず、何度呼んでも知らせは 1 度だけ")
    func refusedRatesWarnOnce() throws {
        var warnings: [String] = []
        let seen = try run(
            frames: 30, warn: { warnings.append($0) },
            make: { _ in try Self.buffer([Float](repeating: 0.1, count: 48_000 * 2)) },
            act: { sound, frame in
                if frame == 1 {
                    sound.play()
                    sound.rate(2)
                }
                if frame >= 5 {
                    sound.rate(-1)
                    sound.rate(.nan)
                    sound.rate(.infinity)
                    sound.rate(-.infinity)
                }
            })
        #expect(warnings.count == 1, "\(warnings)")
        #expect(warnings.first?.contains("rate()") == true)
        // 速さは 2 のまま
        #expect(abs(seen[29].position - seen[9].position - Float(2 * 20) / 60) < 1e-5)
    }

    @Test("1 度だけを速さ 2 で鳴らすと、長さの半分の時間で終わって頭へ戻る。duration はファイルの秒のまま")
    func oneShotEndsAtTheRate() throws {
        var duration: Float = 0
        let seen = try run(
            frames: 40, make: { _ in try Self.buffer([Float](repeating: 0.2, count: 48_000)) },
            act: { sound, frame in
                duration = sound.duration
                if frame == 1 {
                    sound.rate(2)
                    sound.play()
                }
            })
        #expect(duration == 1)
        // 0.5 秒 (30 フレーム) で 1 秒ぶん鳴りきる
        #expect(seen[29].isPlaying && abs(seen[29].position - Float(58) / 60) < 1e-6)
        #expect(!seen[30].isPlaying && seen[30].position == 0)
        #expect(seen[30].peak > 0, "鳴り終わったフレームは終わりまでの区間を解析する")
    }

    @Test("速さ 2 のループは duration で折り返し、鳴っている間の jump は次のフレームでその位置から 2 倍で進む")
    func loopWrapsAndJumpLands() throws {
        let seen = try run(
            frames: 60, make: { _ in try Self.buffer([Float](repeating: 0.2, count: 48_000)) },
            act: { sound, frame in
                if frame == 1 {
                    sound.rate(2)
                    sound.loop()
                }
                if frame == 40 { sound.jump(0.25) }
            })
        // 30 フレームで 1 周
        #expect(seen[30].position == 0)
        #expect(abs(seen[35].position - Float(10) / 60) < 1e-6)
        #expect(seen[40].position == 0.25, "次のフレームは飛び先から鳴り始める")
        #expect(abs(seen[41].position - (0.25 + Float(2) / 60)) < 1e-6)
    }

    // MARK: - 解析 (完了条件 3)

    @Test("1 kHz の正弦を rate(2) で鳴らすと、spectrum の山は 2 kHz の帯に出る (速さ 1 なら 1 kHz)")
    func spectrumFollowsThePitch() throws {
        func peakBand(rate: Float) throws -> Int {
            let seen = try run(
                frames: 20, make: { _ in try Self.buffer(Self.sine(1000, seconds: 2)) },
                act: { sound, frame in
                    if frame == 1 {
                        sound.rate(rate)
                        sound.play()
                    }
                })
            let spectrum = seen[15].spectrum
            return spectrum.indices.max { spectrum[$0] < spectrum[$1] } ?? -1
        }
        // 帯 k の中心は k × 48000 ÷ 1024 Hz
        #expect([21, 22].contains(try peakBand(rate: 1)))
        #expect([42, 43].contains(try peakBand(rate: 2)))
    }

    // MARK: - 経路によらず同じ (完了条件 6・決定 2・4)

    /// 速さ・包絡・飛び・止めて鳴らし直すを混ぜた操作の列。
    private static func mixedOperations(_ sound: SoundFile, _ frame: Int) {
        switch frame {
        case 1: sound.loop()
        case 4: sound.rate(1.5)
        case 9: sound.rate(0.5)
        case 13: sound.rate(0)
        case 16: sound.rate(2.25)
        case 20: sound.jump(0.3)
        case 24: sound.pause()
        case 26:
            sound.rate(0.75)
            sound.play()
        case 30: sound.triggerEnvelope(attack: 0.02, sustain: 0.05, level: 0.8, release: 0.03)
        case 33: sound.rate(3)
        default: break
        }
    }

    @Test("鳴らす経路 (機材に出さない流れ) と書き出しの時計で、同じ操作の列の位置と解析の値が全フレームで一致する")
    func speakerAndFramesAgree() throws {
        let values = Self.sine(330, seconds: 0.8).enumerated().map { $0.element + Float($0.offset % 97) / 400 }
        let framesRun = try run(
            frames: 45, make: { _ in try Self.buffer(values) }, act: Self.mixedOperations)
        let flow = try SoundFlow.offline(sampleRate: 48_000, channels: 2, maximumFrames: 4096)
        let speakerRun = try run(
            frames: 45, flow: flow, make: { _ in try Self.buffer(values) }, act: Self.mixedOperations)
        #expect(framesRun.count == 45 && speakerRun.count == 45)
        for (index, pair) in zip(framesRun, speakerRun).enumerated() {
            #expect(pair.0 == pair.1, "フレーム \(index + 1)")
        }
        #expect(Set(framesRun.map(\.position)).count > 20)
    }

    /// 止めている間に、続く 2 フレームで速さを変えてから鳴らす操作の列。止めている間の速さは、鳴らす側が受けた点を
    /// 主スレッドが読まないと、2 度目の速さを鳴らす側が受けない。
    private static func pausedRateChanges(_ sound: SoundFile, _ frame: Int) {
        switch frame {
        case 1: sound.loop()
        case 5: sound.rate(1.5)
        case 10: sound.pause()
        case 12: sound.rate(2)
        case 13: sound.rate(0.75)
        case 14: sound.play()
        case 20: sound.stop()
        case 21: sound.rate(3)
        case 22: sound.rate(0.5)
        case 23: sound.rate(1.25)
        case 25: sound.loop()
        default: break
        }
    }

    @Test("止めている間に 2 フレーム続けて速さを変えてから鳴らしても、鳴らす経路・エフェクトへ通した経路と書き出しの時計で位置と解析の値が全フレームで一致する")
    func rateChangedWhilePausedAgrees() throws {
        let values = Self.sine(330, seconds: 0.8).enumerated().map { $0.element + Float($0.offset % 97) / 400 }
        let framesRun = try run(
            frames: 40, make: { _ in try Self.buffer(values) }, act: Self.pausedRateChanges)
        // 鳴らし直した区間は、最後に頼んだ速さで進む
        #expect(abs((framesRun[15].position - framesRun[14].position) - Float(0.75) / 60) < 1e-5)
        #expect(abs((framesRun[26].position - framesRun[25].position) - Float(1.25) / 60) < 1e-5)
        let flow = try SoundFlow.offline(sampleRate: 48_000, channels: 2, maximumFrames: 4096)
        let speakerRun = try run(
            frames: 40, flow: flow, make: { _ in try Self.buffer(values) }, act: Self.pausedRateChanges)
        let routedRun = try run(
            frames: 40, routed: true, make: { _ in try Self.buffer(values) }, act: Self.pausedRateChanges)
        #expect(speakerRun.count == 40 && routedRun.count == 40)
        for (index, pair) in zip(framesRun, speakerRun).enumerated() {
            #expect(pair.0 == pair.1, "鳴らす経路のフレーム \(index + 1)")
        }
        for (index, pair) in zip(framesRun, routedRun).enumerated() {
            #expect(pair.0 == pair.1, "エフェクトへ通した経路のフレーム \(index + 1)")
        }
    }

    @Test("エフェクトへ通しても、速さを変えた位置と解析の値は通さないときと全フレームで一致する (48 kHz のファイル)")
    func routedAgreesWithDirect() throws {
        let values = Self.sine(330, seconds: 0.8).enumerated().map { $0.element + Float($0.offset % 97) / 400 }
        let direct = try run(
            frames: 45, make: { _ in try Self.buffer(values) }, act: Self.mixedOperations)
        let routed = try run(
            frames: 45, routed: true, make: { _ in try Self.buffer(values) }, act: Self.mixedOperations)
        for (index, pair) in zip(direct, routed).enumerated() {
            #expect(pair.0 == pair.1, "フレーム \(index + 1)")
        }
    }

    @Test("速さを変えて鳴っている途中でエフェクトへ通しても、位置は続き、速さは保たれる")
    func routingMidwayKeepsTheRate() throws {
        var filter: LowPass?
        let seen = try run(
            frames: 40,
            make: { sketch in
                filter = sketch.createLowPass()
                filter?.freq(20_000)
                return try Self.buffer([Float](repeating: 0.2, count: 48_000 * 4))
            },
            act: { sound, frame in
                if frame == 1 {
                    sound.loop()
                    sound.rate(0.5)
                }
                if frame == 20 { filter?.process(sound) }
            })
        for frame in 2..<39 {
            #expect(
                abs((seen[frame + 1].position - seen[frame].position) - Float(0.5) / 60) < 1e-5,
                "フレーム \(frame + 1)")
        }
    }
}
