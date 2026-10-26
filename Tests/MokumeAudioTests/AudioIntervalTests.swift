// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation
import Testing

@testable import MokumeAudio
@testable import MokumeCore

/// 解析が前のフレーム以後の全標本を覆うこと (#3136)。音源の標本 0 から 512 ごとの格子の窓・区間の値・
/// 供給の単位に依らないこと・長く止まった後の上限を、**機材も GPU も使わずに**見る。
@Suite("音の解析: 前のフレーム以後の区間")
struct AudioIntervalTests {
    /// 種の決まった乱数の標本列 (-0.5〜0.5)。
    private static func noise(count: Int, seed: UInt32 = 20_261_025) -> [Float] {
        var state = seed
        return (0..<count).map { _ in
            state = state &* 1_664_525 &+ 1_013_904_223
            return Float(Int32(bitPattern: state)) / Float(Int32.max) * 0.5
        }
    }

    private static func close(_ lhs: [Float], _ rhs: [Float], tolerance: Float = 1e-5) -> Bool {
        lhs.count == rhs.count && zip(lhs, rhs).allSatisfy { abs($0 - $1) <= tolerance }
    }

    // MARK: - 区間の値

    @Test("区間の値は、窓を介さない rms・peak と、終わりが区間に入る格子の窓の平均になる")
    func spanMatchesAWindowByWindowBruteForce() {
        let stream = Self.noise(count: 9000)
        // 区間の始まりと終わりを、格子の境界の上・途中・窓の長さより短い所に振る
        let intervals = [
            (0, 800), (700, 1500), (1024, 2048), (1500, 1600), (3000, 7900), (2047, 2049),
            (1100, 1200),  // 窓が 0 本 (終わりが入る窓が無い) → 区間の終わりまでに終わった最後の窓
            (100, 200),  // まだ 1 本も終わっていない → 0
        ]
        for (from, to) in intervals {
            let levels = AudioAnalysis.analyze(span(of: stream, from: from, to: to))

            let interval = Array(stream[from..<to])
            let rms = (interval.map { $0 * $0 }.reduce(0, +) / Float(interval.count)).squareRoot()
            #expect(abs(levels.rms - rms) < 1e-6, "rms [\(from), \(to))")
            #expect(levels.peak == interval.map { abs($0) }.max(), "peak [\(from), \(to))")

            // 窓 k は標本 [512k - 1024, 512k)。終わりが [from, to) に入るのは k = from/512 + 1 ... to/512
            let firstWindow = from / 512 + 1
            let lastWindow = to / 512
            let windows =
                firstWindow <= lastWindow
                ? Array(firstWindow...lastWindow) : (lastWindow >= 1 ? [lastWindow] : [])
            let spectra = windows.map { k in
                AudioAnalysis.analyze(
                    (0..<1024).map { offset in
                        let index = 512 * k - 1024 + offset
                        return index < 0 ? 0 : stream[index]
                    }
                ).spectrum
            }
            var expected = [Float](repeating: 0, count: AudioAnalysis.bandCount)
            for spectrum in spectra {
                for band in expected.indices { expected[band] += spectrum[band] / Float(spectra.count) }
            }
            #expect(Self.close(levels.spectrum, expected), "spectrum [\(from), \(to))")
            #expect(levels.spectrumLevels == levels.spectrum.map { AudioAnalysis.level(AudioAnalysis.decibels($0)) })
        }
    }

    @Test("窓 1 本ぶんの区間 (窓の終わりの 512 標本) の値は、窓 1 本の解析と、rms・peak 以外で一致する")
    func oneWindowOfSpanIsTheOldWindowAnalysis() {
        let stream = Self.noise(count: 4000)
        // 窓 k = 4 は標本 [1024, 2048)。終わりがこの区間に入る窓はそれだけ
        let levels = AudioAnalysis.analyze(span(of: stream, from: 1536, to: 2048))
        let window = AudioAnalysis.analyze(Array(stream[1024..<2048]))
        #expect(levels.spectrum == window.spectrum, "窓 1 本ならビット一致")
        #expect(levels.spectrumLevels == window.spectrumLevels)
    }

    @Test("連続するフレームの区間では、終わりが入る格子の窓が重ならず欠けず並ぶ (24・30・60・144 fps)")
    func everyGridWindowBelongsToExactlyOneFrame() {
        for fps in [24, 30, 60, 144] {
            // フレーム f の区間は、独立に整数で数えた [(f-1)·48000/fps, f·48000/fps)。窓の番号は実装が選ぶ
            var next = 1  // 次のフレームが持つはずの最初の窓の番号 (窓 0 は終わりが標本 0 で、どの区間にも入らない)
            var framesWithoutWindows = 0
            for frame in 1...(fps * 2) {
                let from = (frame - 1) * 48_000 / fps
                let to = frame * 48_000 / fps
                guard let windows = AudioAnalysis.windowsEnding(from: from, to: to) else {
                    framesWithoutWindows += 1
                    continue
                }
                #expect(windows.lowerBound == next, "\(fps) fps frame \(frame): 前のフレームの続きから (重ならず欠けず)")
                next = windows.upperBound + 1
            }
            // 最後の窓は、最後の区間の終わり 2 秒ぶんの格子の窓まで来ている
            #expect(next - 1 == 2 * 48_000 / AudioAnalysis.hop, "\(fps) fps")
            // 144 fps だけ、窓が 0 本のフレームがある (1 フレーム 333 標本が hop 512 より短い)
            #expect((framesWithoutWindows > 0) == (fps == 144), "\(fps) fps: 窓が 0 本のフレーム \(framesWithoutWindows)")
        }
    }

    @Test("区間が空なら rms・peak は 0 で、spectrum は区間の終わりまでに終わった最後の窓")
    func emptySpanIsSilentExceptTheLastWindow() {
        let stream = Self.noise(count: 3000)
        let empty = AudioAnalysis.analyze(span(of: stream, from: 1300, to: 1300))
        #expect(empty.rms == 0 && empty.peak == 0 && empty.level == 0)
        let last = AudioAnalysis.analyze(Array(stream[0..<1024]))  // 窓 2 = [0, 1024) (1300 / 512 = 2)
        #expect(empty.spectrum == last.spectrum)
        #expect(AudioAnalysis.analyze(span(of: stream, from: 0, to: 0)) == .silence)
    }

    // MARK: - 例 (条件 1): 24 fps でもクリックを見落とさない

    /// 48 kHz・24 fps の固定の時計で、各フレームの区間のどこかに 10 ms のクリックを置いた標本列を、標本列の
    /// 出どころ (``RecordedSource``) から解析する。1 フレーム 2000 標本で、区間の終わりの 1024 標本の窓には
    /// クリックが入らないフレームがある。
    @Test("24 fps で、各フレームの区間のどこかに置いた 10 ms のクリックは、すべてのフレームで peak に出る")
    func aClickAnywhereInTheIntervalIsNeverMissed() {
        let perFrame = 2000
        let frames = 24
        var stream = [Float](repeating: 0, count: perFrame * frames)
        var outsideTheLastWindow = 0
        for frame in 1..<frames {
            // フレーム f の区間は [(f - 1)·2000, f·2000)。クリックの位置は区間の中で振る
            let offset = (frame * 397) % 1500
            let position = (frame - 1) * perFrame + offset
            if position + 480 <= frame * perFrame - AudioAnalysis.windowSize { outsideTheLastWindow += 1 }
            for index in position..<(position + 480) { stream[index] = 0.5 }
        }
        // 例が意味を持つ: 区間の終わりの窓 (1024 標本) の外に落ちるクリックがある
        #expect(outsideTheLastWindow > 5, "窓の外に落ちたクリック: \(outsideTheLastWindow)")

        let source = RecordedSource(samples: stream, sampleRate: 48_000)
        let input = ExternalInput<AudioSpan>(name: "samples", state: .running)
        let analyzer = AudioAnalyzer()
        // 固定の時計の 24 fps: 作者の時計の秒 = フレームの番号 ÷ 24。区間の終わりはちょうど frame·2000
        source.start(into: input, at: SourceClock(seconds: 0, perSecond: 24))
        for frame in 1..<frames {
            source.pump(into: input, at: SourceClock(seconds: Double(frame) / 24, perSecond: 24))
            guard let span = input.take() else {
                Issue.record("frame \(frame): 区間が入らない")
                continue
            }
            let levels = analyzer.analyze(span)
            #expect(levels.peak == 0.5, "frame \(frame): peak \(levels.peak)")
            #expect(levels.level > 0.7, "frame \(frame): level \(levels.level)")
        }
    }

    // MARK: - 作者の時計の位置 (固定の時計)

    @Test("作者の時計の位置 (秒 × fps) の頭の標本は、止めも飛びもしない間、フレームの番号の式 ⌊N·sr/fps⌋ と 1 標本も違わない")
    func theAuthorsPositionMatchesTheFrameFormula() {
        for fps in [24, 30, 60, 100, 144] {
            for frame in 0...5000 {
                // 固定の時計の秒は N / fps (倍精度)。fps を掛け戻した位置が N の近くでずれても、式と同じ標本になる
                let seconds = Double(frame) / Double(fps)
                let position = FrameSamples.start(
                    ofPosition: seconds * Double(fps), perSecond: fps, sampleRate: 48_000)
                #expect(position == frame * 48_000 / fps, "\(fps) fps frame \(frame)")
            }
        }
        // フレームの途中 (14.4 フレーム目 = 0.1 秒、144 fps) は、4800 標本ちょうど
        #expect(FrameSamples.start(ofPosition: 0.1 * 144, perSecond: 144, sampleRate: 48_000) == 4800)
    }

    @Test("時刻を指定した観測の枚は、指定の秒で終わる 1 フレームぶんの区間を別に見せ、通常の続きの区間は観測の有無で変わらない")
    func anObservationIsSolvedApartFromTheNormalSpans() {
        let stream = Self.noise(count: 400_000)
        func run(observingAt observed: Int?) -> [AudioSpan] {
            let source = RecordedSource(samples: stream, sampleRate: 48_000)
            let input = ExternalInput<AudioSpan>(name: "samples", state: .running)
            source.start(into: input, at: SourceClock(seconds: 0, perSecond: 60))
            var spans: [AudioSpan] = []
            for frame in 1...6 {
                source.pump(
                    into: input,
                    at: SourceClock(
                        seconds: Double(frame) / 60, perSecond: 60, observed: frame == observed ? 5 : nil))
                if let span = input.take() { spans.append(span) }
            }
            return spans
        }
        let plain = run(observingAt: nil)
        let observed = run(observingAt: 3)
        #expect(plain.count == 6 && observed.count == 6)
        for (index, (a, b)) in zip(plain, observed).enumerated() {
            var bare = b
            bare.observation = nil
            #expect(a == bare, "枚 \(index + 1): 通常の続きが観測で動いた")
            #expect((b.observation != nil) == (index == 2))
        }
        // 5 秒 = 300 フレーム目: その 1 フレーム前の頭から 300 フレーム目の頭まで (整数で独立に数える)
        guard let shown = observed[2].observation else {
            Issue.record("観測の枚に区間が無い")
            return
        }
        #expect(shown.from == 299 * 800)
        #expect(shown.base + shown.samples.count == 300 * 800)
        let wanted: [Float] = (299 * 800..<300 * 800).map { stream[$0] }
        #expect(Array(shown.samples.suffix(800)) == wanted)
    }

    // MARK: - 供給の単位に依らない (条件 2)

    /// ``MicrophoneSource`` の環へ `stream` を `chunk` 標本ずつ書き、`fps` のフレームの終わり (`frameEnds`) に
    /// ちょうど届いたところで取り出して解析する。返すのは、フレームごとの区間 (始まり・終わり) と値。
    private func listen(
        to stream: [Float], chunk: Int, fps: Int
    ) throws -> [(from: Int, to: Int, levels: AudioLevels)] {
        let source = MicrophoneSource(device: nil)
        let input = ExternalInput<AudioSpan>(name: "microphone", state: .running)
        let analyzer = AudioAnalyzer()
        var written = 0
        var found: [(from: Int, to: Int, levels: AudioLevels)] = []
        var frame = 1
        while written < stream.count {
            let count = min(chunk, stream.count - written)
            let base = written
            source.ring.write(count: count, hostTime: UInt64(base)) { stream[base + $0] }
            written += count
            let end = frame * 48_000 / fps  // 独立に整数で数えた ⌊N·48000/fps⌋
            if written == end {
                source.pump(into: input, at: 0)
                let span = try #require(input.take())
                found.append((span.from, span.to, analyzer.analyze(span)))
                frame += 1
            }
        }
        return found
    }

    @Test("届くチャンクの長さを変えても、同じ区間の値はビット一致する (60・30・24 fps)")
    func chunkLengthDoesNotChangeTheValues() throws {
        let stream = Self.noise(count: 24_000)
        for (fps, chunks) in [(60, [100, 200, 400, 800]), (30, [160, 320, 800, 1600]), (24, [125, 250, 500, 2000])] {
            let runs = try chunks.map { try listen(to: stream, chunk: $0, fps: fps) }
            let first = try #require(runs.first)
            #expect(first.count >= 10, "\(fps) fps")
            for run in runs.dropFirst() {
                #expect(run.count == first.count)
                for (a, b) in zip(first, run) {
                    #expect(a.from == b.from && a.to == b.to, "\(fps) fps: 区間の取り方")
                    #expect(a.levels == b.levels, "\(fps) fps [\(a.from), \(a.to))")
                }
            }
        }
    }

    @Test("fps を変えても窓の格子は同じ: 30 fps の 1 フレームは、60 fps の連続する 2 フレームを合わせたもの")
    func gridDoesNotDependOnTheFrameRate() throws {
        let stream = Self.noise(count: 24_000)
        let fast = try listen(to: stream, chunk: 800, fps: 60)
        let slow = try listen(to: stream, chunk: 800, fps: 30)
        for (index, frame) in slow.enumerated() {
            let (a, b) = (fast[2 * index], fast[2 * index + 1])
            #expect(a.from == frame.from && b.to == frame.to && a.to == b.from)
            #expect(frame.levels.peak == max(a.levels.peak, b.levels.peak))
            let squares = a.levels.rms * a.levels.rms * 800 + b.levels.rms * b.levels.rms * 800
            #expect(abs(frame.levels.rms - (squares / 1600).squareRoot()) < 1e-6)
            // 窓の本数で重みを付けた平均が一致する (どちらの 60 fps のフレームにも窓が 1 本以上ある)
            let windows = { (from: Int, to: Int) in Float(to / 512 - from / 512) }
            let (na, nb) = (windows(a.from, a.to), windows(b.from, b.to))
            let combined = zip(a.levels.spectrum, b.levels.spectrum).map { ($0 * na + $1 * nb) / (na + nb) }
            #expect(Self.close(frame.levels.spectrum, combined), "[\(frame.from), \(frame.to))")
        }
    }

    // MARK: - 標本列の出どころ (条件 4)

    @Test("標本列は、前のフレームの時刻から今の時刻までを入れる。標本が進まないフレームは何も入れず、過去へ飛んだらそこから数え直す")
    func recordedSourceFollowsTime() throws {
        let stream = Self.noise(count: 4000)
        let source = RecordedSource(samples: stream, sampleRate: 1000)
        let input = ExternalInput<AudioSpan>(name: "samples", state: .running)
        source.start(into: input, at: 16)  // 起点は開いた時刻 (秒。2 進数で割り切れる値にして、丸めの誤差を持ち込まない)
        func pump(_ time: Double) -> (from: Int, to: Int)? {
            source.pump(into: input, at: time)
            return input.take().map { ($0.from, $0.to) }
        }
        // 開いた時刻そのもの (経過 0) は標本が進まない
        #expect(pump(16) == nil)
        let first = try #require(pump(16.5))
        #expect(first == (0, 500))
        // 時間が止まっている (同じ時刻) 間は何も入れない
        #expect(pump(16.5) == nil)
        let second = try #require(pump(16.75))
        #expect(second == (500, 750))
        // 過去へ飛んだフレームは入れず、次のフレームがそこから始まる
        #expect(pump(16.25) == nil)
        let third = try #require(pump(16.375))
        #expect(third == (250, 375))
        // 終わりを越えたら始まりへ戻る (通し番号は戻らず、標本だけが読み直される)
        source.start(into: input, at: 0)
        let wrapped = try #require({ () -> AudioSpan? in
            source.pump(into: input, at: 5)
            return input.take()
        }())
        #expect(wrapped.from == AudioAnalysis.limited(from: 0, to: 5000) && wrapped.to == 5000)
        #expect(wrapped.samples.suffix(1000) == (4000..<5000).map { stream[$0 % 4000] })
    }

    // MARK: - マイクの環の取り出し (条件 4)

    @Test("マイクは、前に入れた区間の終わりから始まる区間を入れ、新しい標本が無ければ何も入れない")
    func microphoneSpansFollowTheRing() throws {
        let source = MicrophoneSource(device: nil)
        let input = ExternalInput<AudioSpan>(name: "microphone", state: .running)
        func write(_ count: Int, from base: Int) {
            source.ring.write(count: count, hostTime: 1) { Float((base + $0) % 97) / 100 }
        }
        // 最初の取り出しは、届いている全標本 (最初に受け取った標本が 0)
        write(1000, from: 0)
        source.pump(into: input, at: 0)
        let first = try #require(input.take())
        #expect(first.from == 0 && first.to == 1000)
        // 新しい標本が届かなかったフレームは何も入れない (値は前のまま)
        source.pump(into: input, at: 0)
        #expect(input.take() == nil)
        // 次は前の終わりから。届いた単位 (700 と 300) に依らず 1 つの区間
        write(700, from: 1000)
        write(300, from: 1700)
        source.pump(into: input, at: 0)
        let second = try #require(input.take())
        #expect(second.from == 1000 && second.to == 2000)
        #expect(second.base <= second.from && second.to - second.base <= 2000)
        for (offset, sample) in second.samples.enumerated() {
            #expect(sample == Float((second.base + offset) % 97) / 100)
        }
    }

    @Test("長く止まった後は、区間の終わりから上限までの標本だけを入れる。上限は合成の計器とマイクの環に収まる")
    func aLongStallIsCutAtTheLimit() throws {
        let source = MicrophoneSource(device: nil)
        let input = ExternalInput<AudioSpan>(name: "microphone", state: .running)
        func value(_ index: Int) -> Float { Float(index % 89) / 100 }
        source.ring.write(count: 500, hostTime: 1) { value($0) }
        source.pump(into: input, at: 0)
        _ = input.take()
        // 0.68 秒を超えて読まれなかった: 環より長く書く
        var total = 500
        for _ in 0..<4 {
            let base = total
            source.ring.write(count: 20_000, hostTime: 2) { value(base + $0) }
            total += 20_000
        }
        source.pump(into: input, at: 0)
        let stalled = try #require(input.take())
        #expect(stalled.to == total)
        #expect(stalled.from == total - AudioAnalysis.maxSpan, "区間は上限で切る")
        #expect(stalled.to - stalled.base <= AudioAnalysis.maxSpan + AudioAnalysis.windowSize + AudioAnalysis.hop)
        #expect(stalled.base >= total - source.ring.capacity, "環から溢れた標本は読まない")
        for (offset, sample) in stalled.samples.enumerated() {
            #expect(sample == value(stalled.base + offset), "標本 \(stalled.base + offset)")
        }
        // 上限は、どの供給元の容量にも収まる (区間の前の履歴を足しても)
        let slack = AudioAnalysis.maxSpan + AudioAnalysis.windowSize + AudioAnalysis.hop
        #expect(slack <= SynthRack.meterCapacity)
        #expect(slack <= source.ring.capacity)
    }

    @Test("上限を越えた区間の値は、上限で切った区間の値に等しい")
    func analysisOfALongSpanIsTheAnalysisOfItsTail() {
        let stream = Self.noise(count: 30_000)
        let long = AudioAnalysis.analyze(
            AudioSpan(base: 0, samples: Array(stream[0..<20_000]), from: 100))
        let tail = AudioAnalysis.analyze(span(of: stream, from: 20_000 - AudioAnalysis.maxSpan, to: 20_000))
        #expect(long.peak == tail.peak)
        #expect(abs(long.rms - tail.rms) < 1e-6)
        #expect(long.spectrum == tail.spectrum && long.spectrumLevels == tail.spectrumLevels)
    }

    // MARK: - 区間が hop より短いフレーム (条件 4)

    @Test("144 fps (1 フレーム 333 標本) では、窓が 0 本のフレームは前の窓の spectrum のまま。まだ 1 本も終わっていなければ 0")
    func framesShorterThanTheHop() {
        let stream = Self.noise(count: 48_000)
        let analyzer = AudioAnalyzer()
        var covered = 0
        var previous: AudioLevels?
        var zeroWindowFrames = 0
        for frame in 1...144 {
            let end = frame * 48_000 / 144  // 独立に整数で数えた ⌊N·48000/fps⌋
            let levels = analyzer.analyze(span(of: stream, from: covered, to: end))
            let windows = end / 512 - covered / 512
            if windows == 0 {
                zeroWindowFrames += 1
                if end < 512 {
                    #expect(levels.spectrum.allSatisfy { $0 == 0 }, "frame \(frame): まだ 1 本も終わっていない")
                } else {
                    #expect(levels.spectrum == previous?.spectrum, "frame \(frame): 前の窓のまま")
                    #expect(levels.spectrum.contains { $0 > 0 })
                }
            }
            // 区間が短くても rms・peak は区間の標本から出る
            #expect(levels.rms > 0 && levels.peak > 0, "frame \(frame)")
            covered = end
            previous = levels
        }
        // 333 標本のフレームは、3 フレームのうち 1 つほどが窓 0 本になる
        #expect(zeroWindowFrames > 40, "窓が 0 本のフレーム: \(zeroWindowFrames)")
    }

    // MARK: - ファイルの再生の区間

    @Test("再生の区間は、前の位置から今の位置まで。始まりより前は 0 (飛んで始めたときだけファイルの標本)、ループは通し番号のまま")
    func playheadSpans() {
        let file = (0..<2000).map { Float($0 + 1) }
        // 頭から鳴らす: 鳴った分だけが区間。始まりより前は 0
        var head = Playhead(length: file.count)
        head.play(looping: false)
        let first = head.span(of: file, from: 0, after: 800)
        #expect(first.from == 0 && first.to == 800 && first.base == 0)
        #expect(first.samples == Array(file[0..<800]))

        // 途中の位置から鳴らし始める (止めた位置から): 区間の前の窓の部分は鳴っていないので 0
        var resumed = Playhead(length: file.count)
        resumed.jump(to: 1200)
        resumed.play(looping: false)
        let after = resumed.span(of: file, from: 1200, after: 700)
        #expect(after.from == 1200 && after.to == 1900)
        #expect(after.samples.prefix(1200).allSatisfy { $0 == 0 })
        #expect(Array(after.samples.suffix(700)) == Array(file[1200..<1900]))

        // 鳴っている間に飛んだ区切り: 始まりより前もファイルの標本で埋める
        var leapt = Playhead(length: file.count)
        leapt.play(looping: false)
        leapt.jump(to: 1200)
        let landing = leapt.span(of: file, from: 1200, after: 700)
        #expect(landing.base == 0 && landing.samples == Array(file[0..<1900]))
        // 飛んだ最初のフレーム (まだ 1 標本も鳴っていない) の区間は空
        #expect(leapt.span(of: file, from: 1200, after: 0).isEmpty)

        // ループ: 通し番号は戻らず、標本だけが頭から読み直される
        var looped = Playhead(length: file.count)
        looped.play(looping: true)
        let seam = looped.span(of: file, from: 1600, after: 2400)
        #expect(seam.from == 1600 && seam.to == 2400)
        #expect(seam.samples.suffix(800) == (1600..<2400).map { file[$0 % 2000] })
    }

    // MARK: - 合成した音

    /// 持ち主のいないステージを固定の時計 (`fps`) で回す。
    private func makeStage(fps: Int, origin: Int = 0) -> SynthStage {
        let stage = SynthStage(owner: nil, flow: nil, now: { 0 }, warn: { _ in })
        stage.pace = .frames(perSecond: fps, origin: origin)
        return stage
    }

    @Test("24 fps で、1 フレームの頭に置いた 10 ms の音は、全部のフレームで peak に出る")
    func aShortBurstAtTheStartOfEachFrameIsSeen() {
        let stage = makeStage(fps: 24)
        let osc = SinOsc(stage: stage)
        osc.set(1000, 0.8)
        let env = Env()
        var peaks: [Float] = []
        for frame in 0..<12 {
            stage.frame = frame
            stage.supply()
            peaks.append(osc.peak)
            // 次の区間の頭に、1 ms で立ち上がり、8 ms 保ち、1 ms で消える 10 ms の音
            env.play(osc, 0.001, 0.008, 1, 0.001)
        }
        stage.close()
        // 最初のフレームは標本が進んでいない空の区間 (無音)
        #expect(peaks[0] == 0)
        #expect(peaks.dropFirst().allSatisfy { $0 > 0.5 }, "\(peaks)")
    }

    @Test("値を読まない音は解析されず、3 フレームに 1 度読む音は読んだ回数だけ解析される (読まれなかったフレームの区間は解かない)")
    func unreadFramesAreNotSolved() {
        let stage = makeStage(fps: 30)
        let always = PinkNoise(stage: stage)
        let sometimes = PinkNoise(stage: stage)
        let never = PinkNoise(stage: stage)
        always.play(0.5)
        sometimes.play(0.5)
        never.play(0.5)
        var reads = 0
        for frame in 0..<12 {
            stage.frame = frame
            stage.supply()
            _ = always.rms
            if frame % 3 == 0 {
                reads += 1
                _ = sometimes.rms
            }
        }
        stage.close()
        #expect(never.analyses == 0)
        // 最初のフレームは標本が進んでいない空の区間で、解く物が無い
        #expect(sometimes.analyses == reads - 1)
        #expect(always.analyses == 11)
    }

    @Test("同じ音を 2 つの時計で回して読む間隔だけ変えても、読んだフレームの値は同じ")
    func readingLessOftenDoesNotChangeTheValues() {
        func run(readEvery step: Int) -> [Int: AudioLevels] {
            let stage = makeStage(fps: 30)
            let osc = SinOsc(stage: stage)
            osc.play(700, 0.6)
            var levels: [Int: AudioLevels] = [:]
            for frame in 0..<12 {
                stage.frame = frame
                stage.supply()
                if frame % step == 0 {
                    levels[frame] = AudioLevels(
                        rms: osc.rms, decibels: osc.decibels, level: osc.level, peak: osc.peak,
                        spectrum: osc.spectrum, spectrumLevels: osc.spectrumLevels)
                }
            }
            stage.close()
            return levels
        }
        let every = run(readEvery: 1)
        let third = run(readEvery: 3)
        for (frame, levels) in third {
            #expect(levels == every[frame], "frame \(frame)")
        }
        #expect(third.count == 4)
    }

    // MARK: - 固定の時計の区間の境界 (条件 8)

    @Test("途中のフレームから始めたステージの標本は、絶対のフレーム番号の窓の継ぎ目に揃う (48000 Hz・144 fps)")
    func stagePositionsLineUpWithTheAbsoluteWindows() {
        let origin = 5
        let stage = makeStage(fps: 144, origin: origin)
        let osc = SinOsc(stage: stage)
        osc.play(440, 0.5)
        let base = origin * 48_000 / 144
        for frame in origin...(origin + 150) {
            stage.frame = frame
            stage.supply()
            // 始めた位置 (標本 base) + ラックが作った標本の数 = フレーム N の窓の先頭 ⌊N·sr/fps⌋ (整数で独立に数える)
            #expect(base + stage.rack.rendered == frame * 48_000 / 144, "frame \(frame)")
        }
        stage.close()
        // 丸めて足すと 1 秒で 48000 にならない (47952) — 直に求めれば 144 フレームで 48000 ちょうど
        #expect(FrameSamples.count(from: 0, to: 144, perSecond: 144, sampleRate: 48_000) == 48_000)
        #expect(144 * Int(48_000.0 / 144) == 47_952)
    }

    @Test("フレームの差から数える式は、origin が窓の継ぎ目の途中にあるとき、絶対の窓の継ぎ目と 1 標本ずれる")
    func countingFromTheDifferenceOfFramesDrifts() {
        // 反例: 差から数える旧式 ⌊(N - origin)·sr/fps⌋ は、絶対の式の差と食い違うフレームがある
        let origin = 5
        let drifting = (origin...(origin + 150)).filter { frame in
            let old = Int((Double(frame - origin) * 48_000 / 144).rounded(.down))
            return old != frame * 48_000 / 144 - origin * 48_000 / 144
        }
        #expect(!drifting.isEmpty, "旧式が食い違うフレームがあるから、式を替えた")
    }
}
