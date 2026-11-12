// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation
import Testing

@testable import MokumeAudio
@testable import MokumeCore

/// 作者の時計が巨大な有限の秒を指したとき (`jumpTime(1e15)` など)、音の入力が時刻を標本の位置へ直すところで
/// 落ちないこと (#3997)。機材も GPU も使わず、``RecordedSource`` を直に回す。
///
/// **寄せる先は ±9 × 10¹⁸ 標本** (`Int.max` ≈ 9.22 × 10¹⁸ の手前)。48 kHz で 1e14 秒 (4.8 × 10¹⁸ 標本) まで、
/// いま落ちない入力の結果は 1 つも変えない。
@Suite("音の入力: 巨大な時刻")
struct AudioSourceHugeTimeTests {
    /// 寄せる先 (標本)。
    private static let bound = 9_000_000_000_000_000_000

    /// 時刻 0 で開き、1/60 秒・`seconds`・2/60 秒の順に取り出した区間の `(from, to)`。取り出した区間は
    /// 解析と拍の判定にも通す (寄せた位置の区間を、解析の側が数えても落ちない)。
    private func run(_ seconds: Double, perSecond: Int?) -> [(from: Int, to: Int)?] {
        let source = RecordedSource(samples: (0..<4800).map { Float($0 % 7) / 7 }, sampleRate: 48_000)
        let input = ExternalInput<AudioSpan>(name: "samples", state: .running)
        let analyzer = AudioAnalyzer()
        source.start(into: input, at: SourceClock(seconds: 0, perSecond: perSecond))
        return [1.0 / 60, seconds, 2.0 / 60].map { time in
            source.pump(into: input, at: SourceClock(seconds: time, perSecond: perSecond))
            guard let span = input.take() else { return nil }
            _ = analyzer.analyze(span)
            return (span.from, span.to)
        }
    }

    @Test(
        "固定の時計 (60 fps) で巨大な秒を指しても落ちず、区間の終わりは寄せた位置になり、戻った後も続く",
        arguments: [1e15, 3e38, -1e15, -3e38, Double.greatestFiniteMagnitude])
    func theFixedClockClampsHugeTimes(_ seconds: Double) {
        let spans = run(seconds, perSecond: 60)
        #expect(spans[0]?.from == 0 && spans[0]?.to == 800)
        if seconds > 0 {
            #expect(spans[1]?.to == Self.bound, "\(seconds)")
        } else {
            // 過去へ飛んだ枚は入れない
            #expect(spans[1] == nil, "\(seconds)")
        }
        // 戻った枚: 巨大な先から過去へ飛んだ (入れない) か、0 から数え直して 1600 まで
        if seconds > 0 { #expect(spans[2] == nil) } else { #expect(spans[2]?.to == 1600) }
    }

    @Test(
        "実時間の時計で巨大な秒を指しても落ちず、区間の終わりは寄せた位置になる",
        arguments: [1e15, 3e38, -1e15, -3e38, Double.greatestFiniteMagnitude])
    func theRealTimeClockClampsHugeTimes(_ seconds: Double) {
        let spans = run(seconds, perSecond: nil)
        #expect(spans[0]?.from == 0 && spans[0]?.to == 800)
        if seconds > 0 {
            #expect(spans[1]?.to == Self.bound, "\(seconds)")
        } else {
            #expect(spans[1] == nil, "\(seconds)")
        }
    }

    /// 直す前の式 (#3997 の前の `FrameSamples.start(ofPosition:)`・`AudioSource.index(at:)`)。
    private func formerStart(_ frames: Double, perSecond: Int) -> Int {
        let position = frames * 48_000 / Double(perSecond)
        let snapped = position.rounded()
        return Int((abs(position - snapped) < 1e-6 ? snapped : position).rounded(.down))
    }

    private func formerIndex(_ time: Double) -> Int {
        max(0, Int((time * 48_000).rounded(.down)))
    }

    /// ±1e14 秒までの秒。0 の近く・フレームの途中・桁ごと・端そのもの。
    private static let ordinarySeconds: [Double] = {
        var values: [Double] = [0, 1.0 / 60, 0.1, 5.1, 1e14, 1e14.nextDown]
        var power = 1.0
        while power <= 1e14 {
            values += [power, power * 1.37, power / 60 * 59, (power * 3).nextUp]
            power *= 10
        }
        values = values.filter { $0 <= 1e14 }
        return values + values.map { -$0 }
    }()

    @Test("±1e14 秒までの秒では、標本の位置と数が直す前の式と 1 つも変わらない (24・60・144 fps と実時間)")
    func ordinaryTimesAreUnchanged() {
        for seconds in Self.ordinarySeconds {
            for fps in [24, 60, 144] {
                let frames = seconds * Double(fps)
                #expect(
                    FrameSamples.start(ofPosition: frames, perSecond: fps, sampleRate: 48_000)
                        == formerStart(frames, perSecond: fps), "\(seconds) s・\(fps) fps")
                let origin = 0.5 * Double(fps)
                #expect(
                    FrameSamples.count(
                        fromPosition: origin, toPosition: frames, perSecond: fps, sampleRate: 48_000)
                        == formerStart(frames, perSecond: fps) - formerStart(origin, perSecond: fps))
            }
            #expect(RecordedSource.index(at: seconds, sampleRate: 48_000) == formerIndex(seconds), "\(seconds) s")
        }
    }

    @Test("開いた時刻が負の巨大な秒でも、差を数えるところで落ちず、寄せた位置どうしの差に寄せる")
    func aHugeNegativeOriginDoesNotOverflowTheCount() {
        let count = FrameSamples.count(
            fromPosition: -3e38, toPosition: 3e38, perSecond: 60, sampleRate: 48_000)
        #expect(count == Int.max)
        let back = FrameSamples.count(
            fromPosition: 3e38, toPosition: -3e38, perSecond: 60, sampleRate: 48_000)
        #expect(back == Int.min)
    }

    @Test("寄せる境目: ちょうど 9e18 はそのまま整数になり、その 1 つ上 (nextUp) と負の側も境目に寄る")
    func theBoundaryConvertsToInt() {
        #expect(FrameSamples.sampleIndex(FrameSamples.reach) == Self.bound)
        #expect(FrameSamples.sampleIndex(FrameSamples.reach.nextUp) == Self.bound)
        #expect(FrameSamples.sampleIndex(-FrameSamples.reach) == -Self.bound)
        #expect(FrameSamples.sampleIndex(-FrameSamples.reach.nextUp) == -Self.bound)
    }

    // MARK: - 寄せた区間を解析まで実走する

    /// 走らせた結果。区間ごとの `(from, to, 標本の数)` と、観測の区間の標本の数。
    private struct Walk {
        var spans: [(from: Int, to: Int, count: Int)] = []
        var observed: [Int] = []
    }

    /// `body` を走らせ、取り出した区間を ``AudioAnalyzer`` に通す。**出どころも解析も main actor に属するので、
    /// 別のスレッドへ出して待つ形にできない。** 代わりに、かかった時間 (10 秒まで) と区間の大きさ
    /// (``largest`` まで) を縛る — 寄せた位置から先の標本を数え上げる形 (`from..<to` を 1 つずつ作る) に
    /// 戻ると、どちらかで赤になる。
    private func walk(
        _ label: String, _ body: (_ take: (ExternalInput<AudioSpan>) -> Void) -> Void
    ) -> Walk? {
        var walk = Walk()
        let analyzer = AudioAnalyzer()
        let clock = ContinuousClock()
        let elapsed = clock.measure {
            body { input in
                guard let span = input.take() else { return }
                _ = analyzer.analyze(span)
                walk.spans.append((span.from, span.to, span.samples.count))
                if let shown = span.observation {
                    _ = analyzer.analyze(shown.span)
                    walk.observed.append(shown.samples.count)
                }
            }
        }
        #expect(elapsed < .seconds(10), "\(label): \(elapsed)")
        return walk
    }

    /// 区間の標本の数の上限 (解析の上限の区間 + ウィンドウ 1 本 + 格子へ揃えるぶん)。巨大な確保をしていないことを見る。
    private static let largest = AudioAnalysis.maxSpan + AudioAnalysis.windowSize + AudioAnalysis.hop

    @Test(
        "開いた時刻が -1e15 秒で、その後 +1e15 秒を取り出しても、解析まで落ちず固まらず、区間は上限の大きさに収まる",
        arguments: [60, nil] as [Int?])
    func aWalkFromAHugeNegativeOpeningToAHugeTimeIsAnalyzed(_ perSecond: Int?) {
        let walked = walk("\(String(describing: perSecond))") { take in
            let source = RecordedSource(samples: (0..<4800).map { Float($0 % 7) / 7 }, sampleRate: 48_000)
            let input = ExternalInput<AudioSpan>(name: "samples", state: .running)
            source.start(into: input, at: SourceClock(seconds: -1e15, perSecond: perSecond))
            for seconds in [-1e15 + 1, 1e15, 1e15 + 1.0 / 60, 3e38] {
                source.pump(into: input, at: SourceClock(seconds: seconds, perSecond: perSecond))
                take(input)
            }
        }
        guard let walked else { return }
        #expect(!walked.spans.isEmpty)
        #expect(walked.spans.allSatisfy { $0.count <= Self.largest && $0.from <= $0.to }, "\(walked.spans)")
        if perSecond != nil {
            // 固定の時計: 開いた位置 (-9e18) から寄せた位置 (9e18) までの差があふれて、Int.max に寄る
            #expect(walked.spans.contains { $0.to == Int.max }, "\(walked.spans)")
        }
    }

    @Test(
        "開き直した時刻 (start) と観測の秒 (observed) が巨大でも、解析まで落ちず、区間は上限の大きさに収まる",
        arguments: [60, nil] as [Int?])
    func hugeReopeningAndObservedTimesAreAnalyzed(_ perSecond: Int?) {
        let walked = walk("\(String(describing: perSecond))") { take in
            let source = RecordedSource(samples: (0..<4800).map { Float($0 % 7) / 7 }, sampleRate: 48_000)
            let input = ExternalInput<AudioSpan>(name: "samples", state: .running)
            source.start(into: input, at: SourceClock(seconds: 0, perSecond: perSecond))
            source.pump(into: input, at: SourceClock(seconds: 1.0 / 60, perSecond: perSecond))
            take(input)
            // 開き直す (起点は最初に開いたときのまま。巨大な時刻から数え直す)
            source.start(into: input, at: SourceClock(seconds: 1e15, perSecond: perSecond))
            source.pump(into: input, at: SourceClock(seconds: 1e15 + 1.0 / 60, perSecond: perSecond))
            take(input)
            source.start(into: input, at: SourceClock(seconds: -3e38, perSecond: perSecond))
            // 観測の秒が巨大 (正と負)
            for shown in [1e15, -1e15, 3e38, -3e38] {
                source.pump(
                    into: input, at: SourceClock(seconds: 2.0 / 60, perSecond: perSecond, observed: shown))
                take(input)
            }
        }
        guard let walked else { return }
        #expect(walked.spans.allSatisfy { $0.count <= Self.largest && $0.from <= $0.to }, "\(walked.spans)")
        #expect(walked.observed.allSatisfy { $0 <= Self.largest }, "\(walked.observed)")
        // 実時間の時計は、前の区間の長さぶんを見せる (固定の時計は、寄せた端どうしで 1 フレーム前と同じ位置になり、見せる区間が空)
        if perSecond == nil { #expect(!walked.observed.isEmpty, "観測の区間が 1 つも出ない") }
    }
}
