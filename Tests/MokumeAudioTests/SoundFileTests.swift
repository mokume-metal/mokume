// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import AVFAudio
import Foundation
import MokumeTestSupport
import Testing

@testable import MokumeAudio
@testable import MokumeCore

/// `setup()` と `draw()` で、検査が渡した手続きを走らせるスケッチ (音声ファイルの再生用)。
final class SoundSketch: Sketch {
    nonisolated(unsafe) static var onSetup: (SoundSketch) throws -> Void = { _ in }
    nonisolated(unsafe) static var onDraw: (SoundSketch) -> Void = { _ in }
    init() {}
    var settings: SketchSettings { SketchSettings(width: 8, height: 8) }
    func setup() throws { try Self.onSetup(self) }
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
    var peak: Float
    var spectrum: [Float]
}

/// 見出しだけで標本の無い (長さ 0 の) WAV を書く。
func writeEmptyWAV() throws -> URL {
    let url = TestScratch.path("mokume-sound", pathExtension: "wav")
    let format = try #require(
        AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 2, interleaved: false))
    _ = try AVAudioFile(forWriting: url, settings: format.settings)
    return url
}

/// 中身をそのまま書いた一時ファイル。
func writeBytes(_ bytes: [UInt8], extension suffix: String) throws -> URL {
    let url = TestScratch.path("mokume-sound", pathExtension: suffix)
    try Data(bytes).write(to: url)
    return url
}

/// 名前が在るものに解けるのに開けないもの — ディレクトリと、読む権利の無いファイル — を置く
/// ([#2358](https://github.com/mokume-metal/mokume/issues/2358))。
struct UnopenablePlaces {
    let folder = TestScratch.path("mokume-unopenable")

    /// `name` という名前のディレクトリと、同じ名前に `locked-` を冠した読む権利の無いファイルを置き、
    /// 場所と、開こうとして OS が返す番号の C の文面を返す。外した権利は ``cleanUp()`` が戻す。
    func place(_ name: String) throws -> [(path: String, reason: String)] {
        let directory = folder.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let locked = folder.appendingPathComponent("locked-\(name)")
        try Data("not audio".utf8).write(to: locked)
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: locked.path)
        // root で走ると権利を外しても読める。読めてしまうと、検査が見たいものを見ていない
        try #require(!FileManager.default.isReadableFile(atPath: locked.path), "読む権利を外せていない")
        return [
            (directory.path, String(cString: strerror(EISDIR))),
            (locked.path, String(cString: strerror(EACCES))),
        ]
    }

    /// 外した読む権利を戻してから、置き場を消す。
    func cleanUp() {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        for placed in names.map({ folder.appendingPathComponent($0).path })
        where !FileManager.default.isReadableFile(atPath: placed) {
            try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: placed)
        }
        try? FileManager.default.removeItem(at: folder)
    }
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
                        isPlaying: sound.isPlaying, position: sound.samplePosition, level: sound.level,
                        rms: sound.rms, peak: sound.peak, spectrum: sound.spectrum))
                act(sound, sketch.frameCount)
            },
            between: between)
        runtime.closePlugins()
        return heard
    }

    /// 頭から鳴らし始めて、`played` 標本のところまで鳴ったフレームの値。前のフレームは `previous` 標本のところ。
    /// 標本が進んでいない (`previous == played`) フレームは、解析する標本が無く、前の値のまま。
    private func expected(
        _ samples: [Float], previous: Int, played: Int, loops: Bool = false
    ) -> AudioLevels {
        AudioAnalysis.analyze(span(of: samples, from: previous, to: played, loops: loops))
    }

    // MARK: - 書き出し (固定の時計) の窓

    @Test("固定の時計で 2 度書き出すと同じ値になり、前のフレームから鳴らし始めてからの経過までの区間の値になる")
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
            // 鳴らし始めた最初のフレームは、まだ 1 標本も鳴っていない空の区間で、無音のまま
            let levels = index == 0
                ? .silence : expected(chord, previous: played - Self.perFrame, played: played)
            #expect(frame.level == levels.level, "frame \(index + 1)")
            #expect(frame.peak == levels.peak, "frame \(index + 1)")
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

    /// **区間の境界は、絶対のフレーム番号の式 ⌊N·sr/fps⌋ の差で数える** ([#3136] の条件 8・ADR-0042 の「時刻の対応」)。
    /// 鳴らし始めたフレームからの差で数えると、48000 Hz・144 fps (1 フレーム 333.33 標本) では、載せる窓の
    /// 継ぎ目と最大 1 標本ずれる。
    ///
    /// [#3136]: https://github.com/mokume-metal/mokume/issues/3136
    @Test("途中のフレームから鳴らし始めた位置は、絶対のフレーム番号の窓の継ぎ目と揃う (48000 Hz・144 fps)")
    func positionLinesUpWithTheAbsoluteWindows() throws {
        let url = try writeWAV(chord, sampleRate: 48_000)
        defer { try? FileManager.default.removeItem(at: url) }
        let heard = try record(
            frames: 40, clock: .frameIndex(frameRate: 144),
            { try $0.loadSound(url.path) },
            act: { sound, frameCount in if frameCount == 5 { sound.play() } })
        #expect(heard.count == 40)
        // draw() の frameCount 5 (フレーム 4) で呼んだ play() が、窓 4 の先頭から鳴らす
        for (index, frame) in heard.enumerated() where index >= 5 {
            let expected = index * 48_000 / 144 - 4 * 48_000 / 144  // 整数で独立に数えた絶対の窓の先頭の差
            #expect(frame.position == expected, "frame \(index)")
        }
        #expect(heard[6].position == 667, "旧式 ⌊(N - origin)·sr/fps⌋ なら 666")
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
                positions.append(sound?.samplePosition ?? -1)
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
        // 続きから鳴らした区間は、止めた位置から始まる区切りで切る。止めた位置より前の窓の部分は、
        // 止めていた間は鳴っていないので 0
        let resumed = span(from: 1600, to: 2400) { $0 < 1600 ? 0 : chord[$0] }
        #expect(heard[5].spectrum == AudioAnalysis.analyze(resumed).spectrum)
    }

    /// 実際に鳴らしている間は、フレームの頭の `supply()` から `pause()`・`stop()` を呼ぶまでに標本が鳴っている。その分の
    /// 区間を解析せずに無音にすると、鳴り終わり (終わりまでの区間を解析してから止まる) と形が揃わない。
    @Test("鳴らしている最中に pause()・stop() すると、止める前に鳴っていた分の区間が次のフレームで解析され、その次から無音になる")
    func stoppingAnalysesWhatPlayedBeforeIt() throws {
        let url = try writeWAV(chord, sampleRate: 48_000)
        defer { try? FileManager.default.removeItem(at: url) }
        for stopping in ["pause", "stop"] {
            let flow = try SoundFlow.offline(sampleRate: 48_000, channels: 2, maximumFrames: 4096)
            var sound: SoundFile?
            let heard = try record(
                frames: 6,
                { sketch in
                    let made = try sketch.loadSound(url.path, flow: flow)
                    made.play()
                    sound = made
                    return made
                },
                between: { frame in
                    // 1 フレームぶん鳴らしてから止める。フレーム 3 の `supply()` の後に 800 標本鳴っている
                    _ = try render(flow, Self.perFrame)
                    if frame == 3 {
                        if stopping == "pause" { sound?.pause() } else { sound?.stop() }
                    }
                })
            #expect(heard.count == 6)
            // フレーム 3 の supply() は [800, 1600) を解析済み。止めた位置は 2400 なので、[1600, 2400) が残る
            let tail = expected(chord, previous: 1600, played: 2400)
            #expect(tail.peak > 0 && tail.level > 0)
            #expect(heard[3].level == tail.level && heard[3].peak == tail.peak, "\(stopping): 止める前に鳴っていた分")
            #expect(!heard[3].isPlaying)
            #expect(heard[4].level == 0 && heard[5].level == 0, "\(stopping): その次から無音")
        }
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
        // 鳴り終わったフレームは、終わりまでの区間 (1600..<2000) を解析してから止まる。次のフレームからは無音
        let tail = expected(short, previous: 1600, played: 2000)
        #expect(once[3].level == tail.level && once[3].peak == tail.peak && once[3].level > 0)
        #expect(once[4].level == 0 && once[4].peak == 0)

        let looped = try record(frames: 6) { sketch in
            let sound = try sketch.loadSound(url.path)
            sound.loop()
            return sound
        }
        #expect(looped.allSatisfy { $0.isPlaying })
        #expect(looped.map(\.position) == [0, 800, 1600, 400, 1200, 0])
        // 継ぎ目を越えた区間 (1600..<2400) は、終わりの後に頭が続く。窓の格子はファイルの位置を戻さずに数える
        let seam = expected(short, previous: 1600, played: 2400, loops: true)
        #expect(looped[3].spectrum == seam.spectrum)
        #expect(looped[3].peak == seam.peak)
        #expect(looped[3].level > 0)
    }

    /// 1 フレームより短い一発音は、鳴り終わったフレームの区間 (鳴り始めてから終わりまで) に入る。窓の終わりで見ていたときは、
    /// 鳴り終わったフレームを無音に戻して、peak が一度も出なかった。
    @Test("24 fps で 20 ミリ秒の一発音を鳴らすと、鳴り終わったフレームの peak に出て、次のフレームから無音になる")
    func aOneShotShorterThanAFrameIsSeen() throws {
        let click = [Float](repeating: 0.5, count: 960)
        let url = try writeWAV(click, sampleRate: 48_000)
        defer { try? FileManager.default.removeItem(at: url) }
        let heard = try record(frames: 4, clock: .frameIndex(frameRate: 24)) { sketch in
            let sound = try sketch.loadSound(url.path)
            sound.play()
            return sound
        }
        #expect(heard.map(\.isPlaying) == [true, false, false, false])
        #expect(heard[0].peak == 0, "鳴らし始めた最初のフレームは標本が進まない")
        #expect(heard[1].peak == 0.5 && heard[1].rms == 0.5, "鳴り終わったフレーム: \(heard[1])")
        #expect(heard[2].peak == 0 && heard[3].peak == 0)
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

    // MARK: - 解析は読まれたときだけ (#2379)

    @Test("値を読まない再生は解析されず、読む再生は 1 フレームに何度読んでも 1 回だけ解析される")
    func onlyTheValuesThatAreReadGetAnalyzed() throws {
        let url = try writeWAV(chord, sampleRate: 48_000)
        defer { try? FileManager.default.removeItem(at: url) }
        let frames = 5
        var unread: SoundFile?
        var read: SoundFile?
        let analyzerBefore = AudioAnalyzer.shared.analyses
        let runtime = try run(
            frames: frames,
            setup: { sketch in
                let first = try sketch.loadSound(url.path)
                first.play()
                let second = try sketch.loadSound(url.path)
                second.play()
                unread = first
                read = second
            },
            draw: { _ in
                guard let read else { return }
                _ = read.level
                _ = read.spectrum
                _ = read.rms
            })
        runtime.closePlugins()

        #expect(unread?.analyses == 0)
        // 鳴らし始めた最初のフレームは標本が進んでいない空の区間で、解く物が無い
        #expect(read?.analyses == frames - 1)
        #expect(AudioAnalyzer.shared.analyses - analyzerBefore == frames - 1, "解析は共有の解析器を通る")
    }

    /// **音量はフレームの頭の値で窓に掛かる。** 読む前に `amp()` で変えても、そのフレームの値は
    /// 変える前の音量のもので、変えた音量は次のフレームから効く (毎フレーム解析していたときと同じ)。
    @Test("読む前に音量を変えても、そのフレームの値はフレームの頭の音量のもので、次のフレームから効く")
    func aVolumeChangedBeforeTheReadTakesEffectNextFrame() throws {
        let url = try writeWAV(chord, sampleRate: 48_000)
        defer { try? FileManager.default.removeItem(at: url) }
        func heardRMS(changingVolumeAt frame: Int?) throws -> [Float] {
            var sound: SoundFile?
            var seen: [Float] = []
            let runtime = try run(
                frames: 4,
                setup: { sketch in
                    let loaded = try sketch.loadSound(url.path)
                    loaded.play()
                    sound = loaded
                },
                draw: { sketch in
                    guard let sound else { return }
                    if sketch.frameCount == frame { sound.amp(0.5) }
                    seen.append(sound.rms)
                })
            runtime.closePlugins()
            return seen
        }
        let steady = try heardRMS(changingVolumeAt: nil)
        let changed = try heardRMS(changingVolumeAt: 3)
        #expect(steady.count == 4 && changed.count == 4)
        #expect(changed[2] == steady[2], "変えたフレームの値は、変える前の音量のまま")
        #expect(abs(changed[3] - steady[3] * 0.5) < 1e-6, "次のフレームから半分になる")
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

    // MARK: - 位置・長さ・飛ぶ (#2464)

    /// 10 秒・48 kHz の音 (拍で揺れる和音を繰り返す)。
    private static let tenSeconds: [Float] = (0..<480_000).map { chord[$0 % chord.count] }

    /// 標本の位置を秒にしたもの (`SoundFile.position` と同じ割り方)。
    private static func seconds(_ sample: Int) -> Float { Float(Double(sample) / 48_000) }

    /// 1 フレームで聞こえたもの (秒の位置と、`draw()` の中で操作した直後の位置)。
    private struct Moment: Equatable {
        var isPlaying: Bool
        var position: Float
        var level: Float
        var spectrum: [Float]
        var afterAct: Float
    }

    private func moments(
        frames: Int, flow: SoundFlow? = nil, url: URL,
        start: @escaping (SoundFile) -> Void = { $0.play() },
        act: @escaping (SoundFile, Int) -> Void,
        between: (Int) throws -> Void = { _ in }
    ) throws -> [Moment] {
        var sound: SoundFile?
        var seen: [Moment] = []
        let runtime = try run(
            frames: frames,
            setup: { sketch in
                let made = try flow.map { try sketch.loadSound(url.path, flow: $0) } ?? sketch.loadSound(url.path)
                start(made)
                sound = made
            },
            draw: { sketch in
                guard let sound else { return }
                let before = Moment(
                    isPlaying: sound.isPlaying, position: sound.position, level: sound.level,
                    spectrum: sound.spectrum, afterAct: 0)
                act(sound, sketch.frameCount)
                seen.append(Moment(
                    isPlaying: before.isPlaying, position: before.position, level: before.level,
                    spectrum: before.spectrum, afterAct: sound.position))
            },
            between: between)
        runtime.closePlugins()
        return seen
    }

    @Test("10 秒の音を 60 fps で鳴らすと、121 フレーム目の position は 2.0 秒で、duration は 10.0 秒")
    func positionAndDurationAreSeconds() throws {
        let url = try writeWAV(Self.tenSeconds, sampleRate: 48_000)
        defer { try? FileManager.default.removeItem(at: url) }
        var duration: Float = 0
        let seen = try moments(frames: 121, url: url, act: { sound, _ in duration = sound.duration })
        #expect(seen.count == 121)
        #expect(seen.first?.position == 0)
        #expect(seen[60].position == 1.0)
        #expect(seen.last?.position == 2.0)
        #expect(duration == 10.0)
    }

    // MARK: - 拍 (#3137)

    /// クリック列のファイルを `fps` の固定の時計で回し、拍のあったフレーム (`frameCount`) を返す。
    ///
    /// - Parameters:
    ///   - readFrom: 読み始めるフレーム (それまでは読まない)。`nil` なら一度も読まない。
    ///   - frame: `act` を呼ぶフレーム。
    private func beatFrames(
        url: URL, fps: Int, seconds: Int = 3, readFrom: Int? = 0, looping: Bool = false,
        at frame: Int? = nil, _ act: @escaping (SoundFile) -> Void = { _ in }
    ) throws -> (frames: [Int], steps: Int) {
        var sound: SoundFile?
        var frames: [Int] = []
        let runtime = try run(
            frames: fps * seconds, clock: .frameIndex(frameRate: fps),
            setup: { sketch in
                sound = try sketch.loadSound(url.path)
                if looping { sound?.loop() } else { sound?.play() }
            },
            draw: { sketch in
                guard let sound else { return }
                if let readFrom, sketch.frameCount >= readFrom, sound.isBeat { frames.append(sketch.frameCount) }
                if sketch.frameCount == frame { act(sound) }
            })
        let steps = sound?.beatSteps ?? -1
        runtime.closePlugins()
        return (frames, steps)
    }

    @Test("isBeat: クリック列のファイルを 60 fps と 24 fps で回すと、拍の数はどちらもクリックの数。読まなくても処理は進み、どのフレームから読み始めても同じ。飛んだ先と鳴らし直しでは履歴を捨てる")
    func beatsFromAFile() throws {
        // 最初のクリックはファイルの頭のすぐ後 (履歴の無い、流れの最初の立ち上がり)
        let starts = [1_000, 12_000, 36_511, 60_001, 84_479]
        let stream = AudioFeatureTests.clicks(at: starts, count: 144_000)
        let url = try writeWAV(stream, sampleRate: 48_000)
        defer { try? FileManager.default.removeItem(at: url) }

        let reference = try beatFrames(url: url, fps: 60)
        #expect(reference.frames.count == starts.count, "\(reference.frames)")
        #expect(try beatFrames(url: url, fps: 24).frames.count == starts.count)
        let unread = try beatFrames(url: url, fps: 60, readFrom: nil)
        #expect(unread.steps > 0, "読まなくても、区間が置かれるたびに拍の処理を進める")
        #expect(unread.steps == reference.steps)
        // どのフレームから読み始めても、それ以後の拍のフレームは同じ (拍のフレーム自体から読み始めても)
        for first in [reference.frames[1], reference.frames[1] + 1, reference.frames[2] - 1, 100] {
            #expect(
                try beatFrames(url: url, fps: 60, readFrom: first).frames == reference.frames.filter { $0 >= first },
                "\(first) フレーム目から読み始める")
        }
        // 3 つ目のクリックの後 (frameCount 50 = 0.82 秒) に 2 秒の位置 (無音) へ飛ぶと、4・5 番目のクリックは聞こえない
        let jumped = try beatFrames(url: url, fps: 60, at: 50) { $0.jump(2.0) }
        #expect(jumped.frames.count == 3, "\(jumped.frames)")
        // 同じところで頭から鳴らし直すと、ファイルの頭の立ち上がり (履歴の無い流れの最初) も拍になる
        let replayed = try beatFrames(url: url, fps: 60, at: 50) { $0.play() }
        #expect(replayed.frames.count == 3 + starts.count, "\(replayed.frames)")
    }

    @Test("isBeat: 飛ぶフレームには、飛ぶ前の区間で見つけた拍が残る (飛び先の履歴だけを捨てる)")
    func jumpKeepsTheBeatBeforeTheJump() throws {
        let starts = [12_000, 36_511, 60_001]
        let url = try writeWAV(AudioFeatureTests.clicks(at: starts, count: 144_000), sampleRate: 48_000)
        defer { try? FileManager.default.removeItem(at: url) }
        let plain = try beatFrames(url: url, fps: 60)
        #expect(plain.frames.count == starts.count)
        // 各クリックの拍が出るフレームの 1 つ前に、無音の位置へ飛ぶように頼む。頼んだ次のフレームが飛ぶフレームで、
        // そのフレームの区間は飛ぶ前の続き。拍はそのフレームに出る
        for beat in plain.frames {
            let jumped = try beatFrames(url: url, fps: 60, at: beat - 1) { $0.jump(2.5) }
            #expect(jumped.frames.contains(beat), "\(beat) フレーム目の拍が飛ぶフレームで消えた: \(jumped.frames)")
            #expect(jumped.frames.filter { $0 > beat }.isEmpty, "飛び先 (無音) に拍は無い")
        }
    }

    @Test("isBeat: 鳴り続ける間は、ループで頭へ戻っても履歴は続き、周ごとに同じ位置の拍が出る")
    func beatsContinueAcrossLoops() throws {
        // 0.5 秒 (24000 標本) の音に 1 つのクリック。3 秒で 6 周する
        let url = try writeWAV(AudioFeatureTests.clicks(at: [3_000], count: 24_000), sampleRate: 48_000)
        defer { try? FileManager.default.removeItem(at: url) }
        let looped = try beatFrames(url: url, fps: 60, looping: true)
        #expect(looped.frames.count == 6, "\(looped.frames)")
        // 周の長さは 30 フレーム。ブロックの境目は周の長さの割り切れない分だけずれるので、拍のフレームは 1 つまでずれる
        #expect(zip(looped.frames, looped.frames.dropFirst()).allSatisfy { 30...31 ~= $1 - $0 }, "\(looped.frames)")
    }

    @Test("isBeat: ループしないファイルの終わりの、閉じていない端数のブロックにだけある立ち上がりも拍になる")
    func beatInTheFinalFragmentOfAFile() throws {
        // 20 ブロックと 200 標本。クリックは最後の端数のブロック [10240, 10440) の中で立ち上がる
        let count = 20 * 512 + 200
        let url = try writeWAV(AudioFeatureTests.clicks(at: [10_250], count: count), sampleRate: 48_000)
        defer { try? FileManager.default.removeItem(at: url) }
        let ended = try beatFrames(url: url, fps: 60, seconds: 1)
        #expect(ended.frames.count == 1, "\(ended.frames)")
        // 鳴り終わったフレームに出る: 10440 標本は 13.05 フレーム目
        #expect(ended.frames == [15], "\(ended.frames)")
    }

    @Test("isBeat: 出力の機材が替わって鳴らし直しても、位置が連続するので履歴は続く (ループの何周目でも)")
    func beatsSurviveRestartingTheOutput() throws {
        // 0.5 秒の音に 1 つのクリック。ループで 3 周した後に出力を止める
        let url = try writeWAV(AudioFeatureTests.clicks(at: [3_000], count: 24_000), sampleRate: 48_000)
        defer { try? FileManager.default.removeItem(at: url) }
        func frames(restartingAt restart: Int?) throws -> [Int] {
            let flow = try SoundFlow.offline(sampleRate: 48_000, channels: 2, maximumFrames: 4096)
            var sound: SoundFile?
            var found: [Int] = []
            let runtime = try run(
                frames: 150,
                setup: { sketch in
                    sound = try sketch.loadSound(url.path, flow: flow)
                    sound?.loop()
                },
                draw: { sketch in
                    if sound?.isBeat == true { found.append(sketch.frameCount) }
                },
                between: { frame in
                    _ = try render(flow, Self.perFrame)
                    // 出力の機材が替わると、流れは自分で止まる。次の supply() が鳴らし直す
                    if frame == restart { flow.engine.stop() }
                })
            runtime.closePlugins()
            return found
        }
        let plain = try frames(restartingAt: nil)
        #expect(plain.count >= 4, "\(plain)")
        // 4 周目の鳴らし直し (93 フレーム目。次のクリックの 3 フレーム前) の直後のクリックも、履歴が続くので拍になる。
        // 履歴を捨てると、約 85 ミリ秒 (5 フレーム) の間は出ない
        let restarted = try frames(restartingAt: 93)
        // 鳴らし直した流れは出力の時計が始め直しになるので、拍のフレームは 1 つまでずれる。数は変わらない
        #expect(restarted.count == plain.count, "鳴らし直しの前後で拍が欠けた: \(restarted) / \(plain)")
        #expect(zip(restarted, plain).allSatisfy { abs($0 - $1) <= 1 }, "\(restarted) / \(plain)")
    }

    @Test("isBeat: 鳴らしている最中の pause() の直前に鳴った分 (止めた最後の区間) の拍は、止めたフレームに出る")
    func beatInTheLastIntervalBeforeStopping() throws {
        // 1900 標本にクリックの立ち上がり。ブロック [1536, 2048) は 2048 で閉じる
        let url = try writeWAV(AudioFeatureTests.clicks(at: [1_900], count: 144_000), sampleRate: 48_000)
        defer { try? FileManager.default.removeItem(at: url) }
        let flow = try SoundFlow.offline(sampleRate: 48_000, channels: 2, maximumFrames: 4096)
        var sound: SoundFile?
        var seen: [(position: Int, isBeat: Bool, isPlaying: Bool)] = []
        let runtime = try run(
            frames: 6,
            setup: { sketch in
                sound = try sketch.loadSound(url.path, flow: flow)
                sound?.play()
            },
            draw: { sketch in
                guard let sound else { return }
                seen.append((sound.samplePosition, sound.isBeat, sound.isPlaying))
                if sketch.frameCount == 3 {
                    // フレームの頭の後に 700 標本鳴ってから止める。止める前に鳴っていた分 (1600..<2300) に、拍がある
                    _ = try? render(flow, 700)
                    sound.pause()
                }
            },
            between: { frame in
                if frame < 3 { _ = try render(flow, Self.perFrame) }
            })
        runtime.closePlugins()
        #expect(seen.map(\.isPlaying) == [true, true, true, false, false, false], "\(seen)")
        #expect(seen[2].isBeat == false, "止める前の区間にはまだ拍が無い: \(seen)")
        #expect(seen[3].isBeat, "止めた最後の区間の拍が、止めたフレームに出ない: \(seen)")
        #expect(seen[4].isBeat == false)
    }

    @Test("鳴っている間の jump(5) は、呼んだ直後から 5.0 を返し、次のフレームでちょうど 5.0 から鳴って、解析の区間は 5.0 秒から始まる")
    func jumpWhilePlayingLandsOnTheNextFrame() throws {
        let url = try writeWAV(Self.tenSeconds, sampleRate: 48_000)
        defer { try? FileManager.default.removeItem(at: url) }
        let act: (SoundFile, Int) -> Void = { sound, frame in if frame == 3 { sound.jump(5) } }
        let seen = try moments(frames: 5, url: url, act: act)

        #expect(seen.map(\.position) == [0, Self.seconds(800), Self.seconds(1600), 5, Self.seconds(240_800)])
        // 呼んだ直後 (同じフレームの続き) から飛び先を見せる
        #expect(seen[2].afterAct == 5)
        #expect(seen.allSatisfy { $0.isPlaying })
        // 飛んだフレームの区間は、飛ぶ前の区切りで前のフレームから鳴り続けていた分 (1600..<2400)。飛び先の区間は
        // 次のフレームから (飛び先から始まる)
        let oldTail = AudioAnalysis.analyze(span(of: Self.tenSeconds, from: 1600, to: 2400))
        #expect(seen[3].level == oldTail.level && seen[3].spectrum == oldTail.spectrum)
        #expect(seen[2].level > 0 && seen[3].level != seen[2].level)
        // 次のフレームの区間は飛び先から始まる。窓の前の部分は、飛ぶ前からそこまで鳴っていたのと同じく、
        // ファイルの標本で埋める (飛び先の前の標本は 0 でない)
        let landing = AudioAnalysis.analyze(
            span(of: Self.tenSeconds, from: 240_000, to: 240_800))
        #expect(seen[4].level == landing.level)
        #expect(seen[4].spectrum == landing.spectrum)
        #expect(seen[4].level > 0)

        // 実際に鳴らす経路でも同じ値になり、飛んだフレームから 5 秒の位置の音が鳴る
        let flow = try SoundFlow.offline(sampleRate: 48_000, channels: 2, maximumFrames: 4096)
        var heardSound: [[Float]] = []
        let played = try moments(
            frames: 5, flow: flow, url: url, act: act,
            between: { _ in heardSound.append(try render(flow, Self.perFrame)) })
        #expect(played == seen)
        let landed = heardSound[3]
        let worst = zip(landed, Self.tenSeconds[240_000..<240_800]).map { abs($0 - $1) }.max() ?? 1
        #expect(worst < 1e-6, "飛んだフレームに鳴った音が 5 秒の位置の音でない")
    }

    @Test("止めている間の jump(5) は位置だけを動かして鳴らさず、次の play() がそこから鳴らす")
    func jumpWhilePausedOnlyMoves() throws {
        let url = try writeWAV(Self.tenSeconds, sampleRate: 48_000)
        defer { try? FileManager.default.removeItem(at: url) }
        let seen = try moments(frames: 5, url: url) { sound, frame in
            switch frame {
            case 2: sound.pause()
            case 3: sound.jump(5)
            case 4: sound.play()
            default: break
            }
        }
        #expect(seen.map(\.isPlaying) == [true, true, false, false, true])
        #expect(seen[2].afterAct == 5)
        #expect(seen[3].position == 5)
        #expect(seen[3].level == 0, "止めている間は鳴らない")
        // play() の区切りは呼んだフレームから数える (止めた位置から鳴らすときと同じ)
        #expect(seen[4].position == Self.seconds(240_800))
    }

    @Test("頭へ戻した後と鳴り終えた後の jump → play() は、飛び先から鳴らす")
    func jumpAfterStopOrEndThenPlay() throws {
        let url = try writeWAV(Self.tenSeconds, sampleRate: 48_000)
        defer { try? FileManager.default.removeItem(at: url) }
        let stopped = try moments(frames: 3, url: url) { sound, frame in
            if frame == 2 {
                sound.stop()
                sound.jump(5)
                sound.play()
            }
        }
        #expect(stopped[1].afterAct == 5)
        #expect(stopped[2].position == Self.seconds(240_800))

        // 2000 標本の音は 4 フレーム目で鳴り終わって頭へ戻る
        let short = sine(band: 40, amplitude: 0.5, count: 2000)
        let shortURL = try writeWAV(short, sampleRate: 48_000)
        defer { try? FileManager.default.removeItem(at: shortURL) }
        let ended = try moments(frames: 6, url: shortURL) { sound, frame in
            if frame == 5 {
                sound.jump(0.015625)  // 750 標本
                sound.play()
            }
        }
        #expect(ended.map(\.isPlaying) == [true, true, true, false, false, true])
        #expect(ended[4].position == 0)
        #expect(ended[4].afterAct == Self.seconds(750))
        #expect(ended[5].position == Self.seconds(1550))
    }

    @Test("範囲の外は知らせずに端へ寄せ、数でない値は位置を変えずに 1 度だけ知らせる")
    func jumpClampsAndIgnoresNonNumbers() throws {
        let url = try writeWAV(Self.tenSeconds, sampleRate: 48_000)
        defer { try? FileManager.default.removeItem(at: url) }
        var notices: [String] = []
        var reported: [Float] = []
        let runtime = try run(
            frames: 2,
            setup: { sketch in
                let loaded = try AudioFile.load(url, path: "ten.wav")
                let sound = SoundFile(
                    name: "ten.wav", buffer: loaded, owner: sketch, flow: nil,
                    warn: { notices.append($0) })
                sketch.attach(sound)
                sound.jump(-1)
                reported.append(sound.position)
                sound.jump(11)
                reported.append(sound.position)
                #expect(notices.isEmpty, "範囲の外は知らせない: \(notices)")
                sound.jump(.nan)
                sound.jump(.infinity)
                sound.jump(-.infinity)
                reported.append(sound.position)
                // 鳴っている間に頼んだ範囲の外も、呼んだ直後から端を見せる
                sound.play()
                sound.jump(-3)
                reported.append(sound.position)
                sound.jump(12)
                reported.append(sound.position)
            })
        runtime.closePlugins()
        #expect(reported == [0, 10, 10, 0, 10])
        #expect(notices.count == 1, "\(notices)")
        #expect(notices.first?.contains("not a number") == true)
    }

    // MARK: - 外して足し直す (#3108)

    /// 外して (`detach`) 足し直した (`attach`) ファイルを回し、各フレームの後に流れから描いた音を返す。
    /// 4 フレーム目で外し、8 フレーム目で足し直して `loop()` する。`between` は各フレームの後 (描いた音を
    /// 取る前) に、フレームの番号で呼ぶ。`inspect` は走らせた後 (後片付けの前) に実行を渡す。
    private func renderedAcrossReattach(
        url: URL, viaLoadSound: Bool, source: URL?, notices: @escaping (String) -> Void = { _ in },
        between: @escaping (Int) throws -> Void = { _ in },
        inspect: (SketchRuntime) -> Void = { _ in }
    ) throws -> [[Float]] {
        let flow = try SoundFlow.offline(sampleRate: 48_000, channels: 2, maximumFrames: 4096)
        var sound: SoundFile?
        var heard: [[Float]] = []
        let runtime = try run(
            frames: 12,
            setup: { sketch in
                if viaLoadSound {
                    sound = try sketch.loadSound(url.path, flow: flow)
                } else {
                    let loaded = try AudioFile.load(url, path: "chord.wav")
                    let made = SoundFile(
                        name: "chord.wav", buffer: loaded, owner: sketch, flow: flow, source: source,
                        warn: notices)
                    sketch.attach(made)
                    sound = made
                }
                sound?.loop()
            },
            draw: { sketch in
                guard let sound else { return }
                if sketch.frameCount == 4 { sketch.detach(sound) }
                if sketch.frameCount == 8 {
                    sketch.attach(sound)
                    sound.loop()
                }
            },
            between: { frame in
                try between(frame)
                heard.append(try render(flow, Self.perFrame))
            })
        inspect(runtime)
        runtime.closePlugins()
        return heard
    }

    private func peak(_ frames: ArraySlice<[Float]>) -> Float {
        frames.flatMap { $0 }.map { abs($0) }.max() ?? 0
    }

    @Test("外して足し直して loop() すると、最初と同じ出力で鳴り直し、「出力が開けない」と知らせない")
    func reattachedFileIsHeardAgain() throws {
        let url = try writeWAV(chord, sampleRate: 48_000)
        defer { try? FileManager.default.removeItem(at: url) }
        for viaLoadSound in [true, false] {
            var notices: [String] = []
            let heard = try renderedAcrossReattach(
                url: url, viaLoadSound: viaLoadSound, source: url, notices: { notices.append($0) })
            #expect(heard.count == 12)
            #expect(peak(heard[0..<3]) > 0.1, "最初は鳴る (viaLoadSound: \(viaLoadSound))")
            #expect(peak(heard[4..<7]) == 0, "外している間は鳴らない (viaLoadSound: \(viaLoadSound))")
            #expect(peak(heard[7..<12]) > 0.1, "足し直した後も鳴る (viaLoadSound: \(viaLoadSound))")
            #expect(notices.isEmpty, "出力が開けるのに知らせた: \(notices)")
        }
    }

    @Test("足し直しで音が鳴り直したとき、鳴った音は loop() が始めたファイルの頭からの音")
    func reattachedFilePlaysFromTheTop() throws {
        let url = try writeWAV(chord, sampleRate: 48_000)
        defer { try? FileManager.default.removeItem(at: url) }
        let heard = try renderedAcrossReattach(url: url, viaLoadSound: true, source: url)
        // 足し直したフレーム (8 フレーム目) の後に描いた音は、ファイルの頭 (loop() で頭から) の音
        let again = heard[7...].flatMap { $0 }
        let worst = zip(again, chord).map { abs($0 - $1) }.max() ?? 1
        #expect(worst < 1e-6)
    }

    /// 足し直した後の `loop()` で読み直した結果、鳴らさず実時間で進み、知らせが 1 度だけ出ることを確かめる。
    private func expectCannotReload(
        url: URL, source: URL?, between: @escaping (Int) throws -> Void = { _ in },
        reason: String, sourceLocation: SourceLocation = #_sourceLocation
    ) throws {
        var notices: [String] = []
        let heard = try renderedAcrossReattach(
            url: url, viaLoadSound: false, source: source, notices: { notices.append($0) },
            between: between)
        #expect(peak(heard[7..<12]) == 0, "器が戻せなければ鳴らさない", sourceLocation: sourceLocation)
        #expect(notices.count == 1, "1 度だけ知らせる: \(notices)", sourceLocation: sourceLocation)
        let text = notices.first ?? ""
        #expect(text.contains("could not be read again"), "\(text)", sourceLocation: sourceLocation)
        #expect(text.contains(reason), "事情を名乗る: \(text)", sourceLocation: sourceLocation)
        #expect(!text.contains("No audio output"), "\(text)", sourceLocation: sourceLocation)
    }

    @Test("足し直して鳴らすとき、読み込んだ場所が読み直せなければ、鳴らさずに実時間で位置を進め、読めなかった事情を 1 度だけ知らせる")
    func reattachWithoutReadableSourceFallsBackToTheClock() throws {
        let url = try writeWAV(chord, sampleRate: 48_000)
        defer { try? FileManager.default.removeItem(at: url) }
        // ファイルから作ったのではない
        try expectCannotReload(url: url, source: nil, reason: "nothing to read it from")
        // 外している間に消えた (見つからないと開けないを取り違えない)
        let gone = TestScratch.path("mokume-gone", pathExtension: "wav")
        try expectCannotReload(url: url, source: gone, reason: gone.lastPathComponent)
        // 外している間に、音声でないものに替わった
        let swapped = try writeBytes(Array("not audio".utf8), extension: "wav")
        defer { try? FileManager.default.removeItem(at: swapped) }
        try expectCannotReload(url: url, source: swapped, reason: "cannot be read as audio")
    }

    @Test("足し直して鳴らすとき、読み直したファイルが標本の数・標本化率・チャンネル数のどれかで別のものなら、読み直せない扱いにする")
    func reattachDetectsAReplacedFile() throws {
        let url = try writeWAV(chord, sampleRate: 48_000)
        defer { try? FileManager.default.removeItem(at: url) }
        // 標本の数は同じで、標本化率だけが違う
        let slower = try writeWAV(chord, sampleRate: 44_100)
        defer { try? FileManager.default.removeItem(at: slower) }
        try expectCannotReload(url: url, source: slower, reason: "differ")
        // 標本の数が違う
        let shorter = try writeWAV(Array(chord.prefix(40_000)), sampleRate: 48_000)
        defer { try? FileManager.default.removeItem(at: shorter) }
        try expectCannotReload(url: url, source: shorter, reason: "differ")
        // チャンネル数が違う (同じ長さ・同じ標本化率のモノラル)
        let mono = TestScratch.path("mokume-mono", pathExtension: "wav")
        defer { try? FileManager.default.removeItem(at: mono) }
        let monoFormat = try #require(
            AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 1, interleaved: false))
        // 書き終えて閉じてから読ませる (AVAudioFile は手放すときに閉じる)
        do {
            let monoFile = try AVAudioFile(forWriting: mono, settings: monoFormat.settings)
            let monoBuffer = try #require(
                AVAudioPCMBuffer(pcmFormat: monoFormat, frameCapacity: AVAudioFrameCount(chord.count)))
            monoBuffer.frameLength = AVAudioFrameCount(chord.count)
            let channel = try #require(monoBuffer.floatChannelData)[0]
            for (index, sample) in chord.enumerated() { channel[index] = sample }
            try monoFile.write(from: monoBuffer)
        }
        try expectCannotReload(url: url, source: mono, reason: "differ")
    }

    @Test("足し直して鳴らすために読み直すのは draw() を止める同期の読み込みなので、loadSound と同じく 1 度だけ知らせる")
    func reattachReadIsNoticedAsABlockingLoad() throws {
        let url = try writeWAV(chord, sampleRate: 48_000)
        defer { try? FileManager.default.removeItem(at: url) }
        let call = "play() or loop() on a SoundFile attached again"
        var message: String?
        _ = try renderedAcrossReattach(
            url: url, viaLoadSound: true, source: url,
            inspect: { message = $0.blockingLoads.message(for: call) })
        #expect(message == BlockingLoads.notice(call, instead: nil))
        // 外さなければ読み直さないので知らせない
        var quiet: String? = "unset"
        let runtime = try run(
            frames: 3,
            setup: { sketch in
                try sketch.loadSound(url.path).loop()
            })
        quiet = runtime.blockingLoads.message(for: call)
        runtime.closePlugins()
        #expect(quiet == nil)
    }

    @Test("書き出し (固定の時計) では、外して足し直しても位置が同じで、知らせない")
    func reattachInExportKeepsThePosition() throws {
        let url = try writeWAV(chord, sampleRate: 48_000)
        defer { try? FileManager.default.removeItem(at: url) }
        var sound: SoundFile?
        var positions: [Int] = []
        let runtime = try run(
            frames: 11,
            setup: { sketch in
                sound = try sketch.loadSound(url.path)
                sound?.loop()
            },
            draw: { sketch in
                guard let sound else { return }
                positions.append(sound.samplePosition)
                if sketch.frameCount == 4 { sketch.detach(sound) }
                if sketch.frameCount == 8 {
                    sketch.attach(sound)
                    sound.loop()
                }
            })
        runtime.closePlugins()
        #expect(positions[0..<4] == [0, 800, 1600, 2400])
        // 足し直して頭から数え直した位置は、最初に鳴らし始めたときと同じ進み方
        #expect(positions[8..<11] == [800, 1600, 2400])
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

    @Test("ディレクトリと読む権利の無いファイルは、unopenable で開けない事情を名乗る (形式・破損の助言を出さない)")
    func unopenableNamesWhy() throws {
        let places = UnopenablePlaces()
        defer { places.cleanUp() }
        let placed = try places.place("kick.wav")
        var failures: [AudioFailure] = []
        let runtime = try run(frames: 1, setup: { sketch in
            for (path, _) in placed {
                do throws(AudioFailure) { _ = try sketch.loadSound(path) } catch { failures.append(error) }
            }
        })
        runtime.closePlugins()
        #expect(failures == placed.map { .unopenable(path: $0.path, location: $0.path, reason: $0.reason) })
        for failure in failures {
            #expect(!failure.description.contains("damaged"), "\(failure)")
            #expect(!failure.description.contains("format"), "\(failure)")
        }
    }
}
