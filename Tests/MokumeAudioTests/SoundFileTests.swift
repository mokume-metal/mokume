// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import AVFAudio
import Foundation
import Testing

@testable import MokumeAudio
@testable import MokumeCore

/// `setup()` と `draw()` で、検査が渡した手続きを走らせるスケッチ (音声ファイルの再生用)。
final class SoundSketch: Sketch {
    nonisolated(unsafe) static var onSetup: (SoundSketch) throws -> Void = { _ in }
    nonisolated(unsafe) static var onDraw: (SoundSketch) -> Void = { _ in }
    init() {}
    var settings: SketchSettings { SketchSettings(width: 8, height: 8) }
    func setup() { try? Self.onSetup(self) }
    func draw() {
        background(0, 0, 0)
        Self.onDraw(self)
    }
}

/// 1 フレームで聞こえたもの。
struct Heard: Equatable {
    var isPlaying: Bool
    var position: Int
    var level: Float
    var rms: Float
    var spectrum: [Float]
}

/// 見出しだけで標本の無い (長さ 0 の) WAV を書く。
func writeEmptyWAV() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("mokume-sound-\(UUID().uuidString).wav")
    let format = try #require(
        AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 2, interleaved: false))
    _ = try AVAudioFile(forWriting: url, settings: format.settings)
    return url
}

/// 中身をそのまま書いた一時ファイル。
func writeBytes(_ bytes: [UInt8], extension suffix: String) throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("mokume-sound-\(UUID().uuidString).\(suffix)")
    try Data(bytes).write(to: url)
    return url
}

/// 音声ファイルの再生 (#1979)。走っているスケッチの中で回すので GPU を要する。
///
/// 書き出しの経路 (固定の時計) は鳴らさずに回る。鳴らす経路は、manual rendering (offline) の
/// 流れを差し込んで回す — 出力の機材には出さない。
@Suite(
    "音声ファイルの再生",
    .serialized,
    .enabled(
        if: RenderDevice.isAvailable,
        "この世代のコマンド構造に対応した GPU が無い実行環境ではスキップする")
)
struct SoundFileTests {
    /// 60 fps・48 kHz の 1 フレームぶんの標本の数。
    private static let perFrame = 800

    private func run(
        frames: Int, clock: Clock? = nil, setup: @escaping (SoundSketch) throws -> Void,
        draw: @escaping (SoundSketch) -> Void = { _ in },
        between: (Int) throws -> Void = { _ in }
    ) throws -> SketchRuntime {
        SoundSketch.onSetup = setup
        SoundSketch.onDraw = draw
        let runtime = try SketchRuntime(sketch: SoundSketch(), gpu: try RenderDevice(), clock: clock)
        for frame in 1...frames {
            try runtime.advance()
            try between(frame)
        }
        return runtime
    }

    /// 作った再生を回し、`draw()` で聞こえたものをフレームごとに返す。`act` は `draw()` の
    /// 記録の後に、そのフレームの番号で呼ぶ。
    private func record(
        frames: Int, clock: Clock? = nil, _ make: @escaping (SoundSketch) throws -> SoundFile,
        act: @escaping (SoundFile, Int) -> Void = { _, _ in },
        between: (Int) throws -> Void = { _ in }
    ) throws -> [Heard] {
        var sound: SoundFile?
        var heard: [Heard] = []
        let runtime = try run(
            frames: frames, clock: clock,
            setup: { sound = try make($0) },
            draw: { sketch in
                guard let sound else { return }
                heard.append(
                    Heard(
                        isPlaying: sound.isPlaying, position: sound.position, level: sound.level,
                        rms: sound.rms, spectrum: sound.spectrum))
                act(sound, sketch.frameCount)
            },
            between: between)
        runtime.closePlugins()
        return heard
    }

    /// 頭から鳴らし始めて `played` 標本鳴ったときの、実時間の再生の窓を解析した値。
    private func expected(_ samples: [Float], played: Int) -> AudioLevels {
        AudioAnalysis.analyze(
            AudioAnalysis.window(of: samples, sampleRate: 48_000, endingAt: Double(played) / 48_000))
    }

    // MARK: - 書き出し (固定の時計) の窓

    @Test("固定の時計で 2 度書き出すと同じ値になり、鳴らし始めてからの経過で終わる窓の値になる")
    func exportIsRepeatable() throws {
        let url = try writeWAV(chord, sampleRate: 48_000)
        defer { try? FileManager.default.removeItem(at: url) }
        let make: (SoundSketch) throws -> SoundFile = { sketch in
            let sound = try sketch.loadSound(url.path)
            sound.play()
            return sound
        }
        let first = try record(frames: 8, make)
        let second = try record(frames: 8, make)
        #expect(first.count == 8)
        #expect(first == second)
        for (index, frame) in first.enumerated() {
            let played = index * Self.perFrame
            #expect(frame.position == played)
            let levels = expected(chord, played: played)
            #expect(frame.level == levels.level, "frame \(index + 1)")
            #expect(frame.spectrum == levels.spectrum, "frame \(index + 1)")
        }
        // 拍で揺れる音なので、フレームごとに値が動いている
        #expect(Set(first.map(\.level)).count > 1)
    }

    @Test("実時間の速さで鳴らした再生は、書き出しと同じ時刻の窓から同じ値を取り、鳴った音もその位置にある")
    func playbackMatchesExport() throws {
        let url = try writeWAV(chord, sampleRate: 48_000)
        defer { try? FileManager.default.removeItem(at: url) }
        let exported = try record(frames: 8) { sketch in
            let sound = try sketch.loadSound(url.path)
            sound.play()
            return sound
        }

        // 1 フレームぶんずつ描かせる流れ = 実時間の再生を、機材に出さずに回す
        let flow = try SoundFlow.offline(sampleRate: 48_000, channels: 2, maximumFrames: 4096)
        var heardSound: [Float] = []
        let played = try record(
            frames: 8,
            { sketch in
                let sound = try sketch.loadSound(url.path, flow: flow)
                sound.play()
                return sound
            },
            between: { _ in heardSound += try render(flow, Self.perFrame) })
        #expect(played == exported)
        // 鳴ったのはファイルの頭からの音そのもの (左右とも同じ音を書いてある)
        #expect(heardSound.count == 8 * Self.perFrame)
        let worst = zip(heardSound, chord).map { abs($0 - $1) }.max() ?? 1
        #expect(worst < 1e-6)
    }

    @Test("書き出しの位置は、作品の宣言ではなく書き出しの時計の fps で進む")
    func exportFollowsTheClockRate() throws {
        let url = try writeWAV(chord, sampleRate: 48_000)
        defer { try? FileManager.default.removeItem(at: url) }
        let heard = try record(frames: 3, clock: .frameIndex(frameRate: 30)) { sketch in
            let sound = try sketch.loadSound(url.path)
            sound.play()
            return sound
        }
        #expect(heard.map(\.position) == [0, 1600, 3200])
    }

    @Test("作品が時刻を止めても、音は止まらずに進む")
    func pauseTimeDoesNotStopTheSound() throws {
        let url = try writeWAV(chord, sampleRate: 48_000)
        defer { try? FileManager.default.removeItem(at: url) }
        var times: [Float] = []
        var positions: [Int] = []
        var sound: SoundFile?
        let runtime = try run(
            frames: 4,
            setup: { sketch in
                sound = try sketch.loadSound(url.path)
                sound?.play()
                sketch.pauseTime()
            },
            draw: { sketch in
                times.append(sketch.time)
                positions.append(sound?.position ?? -1)
            })
        #expect(times == [0, 0, 0, 0])
        #expect(positions == [0, 800, 1600, 2400])
        runtime.closePlugins()
    }

    // MARK: - 鳴らす・止める

    @Test("止めると位置を覚えて無音になり、鳴らすと続きから。頭へ戻す・鳴らし直す・ループも効く")
    func operationsFollowSoundFile() throws {
        let url = try writeWAV(chord, sampleRate: 48_000)
        defer { try? FileManager.default.removeItem(at: url) }
        let heard = try record(
            frames: 10,
            { sketch in
                let sound = try sketch.loadSound(url.path)
                sound.play()
                return sound
            },
            act: { sound, frame in
                switch frame {
                case 3: sound.pause()
                case 5: sound.play()
                case 7: sound.stop()
                case 8: sound.loop()
                case 9: sound.loop()  // 鳴っている最中なので頭から鳴らし直す
                default: break
                }
            })
        #expect(heard.map(\.isPlaying) == [true, true, true, false, false, true, true, false, true, true])
        #expect(heard.map(\.position) == [0, 800, 1600, 1600, 1600, 2400, 3200, 0, 800, 800])
        // 止まっている間は無音で、鳴っている間は音がある (頭のフレームは鳴らし始めた瞬間で、まだ無音)
        #expect(heard[3].level == 0 && heard[4].level == 0 && heard[7].level == 0)
        #expect(heard[1].level > 0 && heard[5].level > 0 && heard[8].level > 0)
        // 続きから鳴らした窓は、止めた位置から始まる区切りで切る (止めていた間は鳴っていない)
        let resumed = Array(repeating: Float(0), count: 1024 - 800) + chord[1600..<2400]
        #expect(heard[5].spectrum == AudioAnalysis.analyze(resumed).spectrum)
    }

    @Test("1 度だけなら終わりで止まって無音になり、ループなら継ぎ目を越えて鳴り続ける")
    func endAndSeam() throws {
        // 2000 標本 (約 42 ミリ秒) の短い音
        let short = sine(band: 40, amplitude: 0.5, count: 2000)
        let url = try writeWAV(short, sampleRate: 48_000)
        defer { try? FileManager.default.removeItem(at: url) }

        let once = try record(frames: 5) { sketch in
            let sound = try sketch.loadSound(url.path)
            sound.play()
            return sound
        }
        // 4 フレーム目 (2400 標本) で鳴り終わる。終わったフレームから無音で、頭へ戻っている
        #expect(once.map(\.isPlaying) == [true, true, true, false, false])
        #expect(once.map(\.position) == [0, 800, 1600, 0, 0])
        #expect(once[2].level > 0)
        #expect(once[3].level == 0 && once[4].level == 0)

        let looped = try record(frames: 6) { sketch in
            let sound = try sketch.loadSound(url.path)
            sound.loop()
            return sound
        }
        #expect(looped.allSatisfy { $0.isPlaying })
        #expect(looped.map(\.position) == [0, 800, 1600, 400, 1200, 0])
        // 継ぎ目を越えた窓は、終わりの後に頭が続く
        let seam = (1376..<2000).map { short[$0] } + (0..<400).map { short[$0] }
        #expect(looped[3].spectrum == AudioAnalysis.analyze(seam).spectrum)
        #expect(looped[3].level > 0)
    }

    @Test("音量は解析の値にも掛かり、0〜1 の外は丸め、数でない値は無視して、それぞれ 1 度だけ知らせる")
    func ampScalesClampsAndWarnsOnce() throws {
        let tone = sine(band: 40, amplitude: 0.5, count: 48_000)
        let url = try writeWAV(tone, sampleRate: 48_000)
        defer { try? FileManager.default.removeItem(at: url) }

        var notices: [String] = []
        func heard(_ adjust: @escaping (SoundFile) -> Void) throws -> [Heard] {
            try record(frames: 3) { sketch in
                let loaded = try AudioFile.load(url, path: "tone.wav")
                let sound = SoundFile(
                    name: "tone.wav", buffer: loaded, owner: sketch, flow: nil,
                    warn: { notices.append($0) })
                sketch.attach(sound)
                sound.play()
                adjust(sound)
                return sound
            }
        }

        let full = try heard { _ in }
        let half = try heard { $0.amp(0.5) }
        #expect(abs(half[2].rms - full[2].rms * 0.5) < 1e-6)
        #expect(notices.isEmpty)

        let loud = try heard { sound in
            sound.amp(2)
            sound.amp(3)
        }
        #expect(loud[2].rms == full[2].rms, "1 を越えた音量は 1 に丸める")
        #expect(notices.count == 1, "丸めたことは 1 度だけ言う: \(notices)")
        #expect(notices.first?.contains("from 0 to 1") == true)

        notices.removeAll()
        let ignored = try heard { sound in
            sound.amp(0.5)
            sound.amp(.nan)
            sound.amp(.infinity)
        }
        #expect(ignored[2].rms == half[2].rms, "数でない値の前の音量のまま")
        #expect(notices.count == 1, "\(notices)")
        #expect(notices.first?.contains("not a number") == true)

        let muted = try heard { $0.amp(-1) }
        #expect(muted[2].isPlaying && muted[2].level == 0)
    }

    @Test("閉じると止まって無音になる")
    func closeSilences() throws {
        let url = try writeWAV(chord, sampleRate: 48_000)
        defer { try? FileManager.default.removeItem(at: url) }
        var sound: SoundFile?
        let runtime = try run(
            frames: 3,
            setup: { sketch in
                sound = try sketch.loadSound(url.path)
                sound?.loop()
            })
        #expect(sound?.level ?? 0 > 0)
        runtime.closePlugins()
        #expect(sound?.isPlaying == false)
        #expect(sound?.level == 0)
    }

    // MARK: - 作れないとき

    @Test("見つからない・読めない・対応外の形式・長さ 0 は、作るときに型のついた失敗で投げる")
    func failuresAreThrownAtCreation() throws {
        let garbage = try writeBytes(Array("not audio".utf8), extension: "wav")
        // 見出しの途中で切れた WAV (壊れたファイル)
        let truncated = try writeBytes(Array("RIFF\u{24}\0\0\0WAVEfmt ".utf8), extension: "wav")
        // MIDI の見出し (macOS が音声として読めない形式)
        let midi = try writeBytes(
            [0x4D, 0x54, 0x68, 0x64, 0, 0, 0, 6, 0, 0, 0, 1, 0, 0x60], extension: "mid")
        let empty = try writeEmptyWAV()
        defer {
            for url in [garbage, truncated, midi, empty] { try? FileManager.default.removeItem(at: url) }
        }

        var failures: [AudioFailure] = []
        let runtime = try run(frames: 1, setup: { sketch in
            for path in ["no-such-sound.wav", garbage.path, truncated.path, midi.path, empty.path] {
                do throws(AudioFailure) { _ = try sketch.loadSound(path) } catch { failures.append(error) }
            }
        })
        #expect(failures.count == 5)
        if case .notFound(let path, let searched) = failures.first {
            #expect(path == "no-such-sound.wav")
            #expect(!searched.isEmpty)
        } else {
            Issue.record("見つからないことが notFound にならない: \(failures)")
        }
        #expect(Array(failures.dropFirst().prefix(3)) == [
            .unreadable(path: garbage.path), .unreadable(path: truncated.path),
            .unreadable(path: midi.path),
        ])
        #expect(failures.last == .empty)
        runtime.closePlugins()
    }
}
