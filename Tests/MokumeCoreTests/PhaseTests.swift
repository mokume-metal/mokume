// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation
import MokumeDiagnostics
import Testing

@testable import MokumeCore

/// 周期の位相 `phase(period:)` の式 ([#2415](https://github.com/mokume-metal/mokume/issues/2415))。
/// 時計を介さない純粋な計算なので、GPU は要らない。
@Suite("周期の位相の式")
struct PhaseFormulaTests {
    @Test("秒を周期で割った余りを、周期で割って返す")
    func foldsTheSecondsIntoOnePeriod() {
        #expect(periodPhase(ofSeconds: 0, period: 4) == 0)
        #expect(periodPhase(ofSeconds: 1, period: 4) == 0.25)
        #expect(periodPhase(ofSeconds: 5, period: 4) == 0.25)
        #expect(periodPhase(ofSeconds: 7.5, period: 2.5) == 0)
    }

    @Test("負の秒も 0 以上へ巡る")
    func negativeSecondsWrapForward() {
        #expect(periodPhase(ofSeconds: -1, period: 4) == 0.75)
        #expect(periodPhase(ofSeconds: -4, period: 4) == 0)
        #expect(periodPhase(ofSeconds: -5, period: 4) == 0.75)
    }

    @Test("周期ちょうどと、周期に丸まる負の微小値は 1 ではなく 0")
    func neverReachesOne() {
        #expect(periodPhase(ofSeconds: 4, period: 4) == 0)
        // 4 に足すと周期ちょうどに丸まる値。1 を返すと 1 周ぶんずれて読まれる
        #expect(periodPhase(ofSeconds: -1e-20, period: 4) == 0)
        // 周期の終わりに近く、`Float` の比が 1 に丸まる値
        #expect(periodPhase(ofSeconds: 4 - 1e-12, period: 4) == 0)
        for seconds in stride(from: -10.0, through: 10.0, by: 0.37) {
            let phase = periodPhase(ofSeconds: seconds, period: 4)
            #expect(phase >= 0 && phase < 1, "\(seconds) -> \(phase)")
        }
    }

    /// 本題 — `Float` の `time` を剰余に通すと、約 6 日後には段になる。倍精度の秒から取れば段にならない。
    @Test("6.5 日ぶん進んだ秒でも、60 fps の各フレームが違う位相になる")
    func staysFineAfterDays() {
        let start = 6.5 * 86_400.0  // `Float` の刻みが 62.5 ms になっている
        var phases: [Float] = []
        var floatPhases: [Float] = []
        for frame in 0..<30 {
            let seconds = start + Double(frame) / 60
            phases.append(periodPhase(ofSeconds: seconds, period: 4))
            // 変更前の書き方: `Float` の time から剰余を取る
            floatPhases.append(Float(seconds).truncatingRemainder(dividingBy: 4) / 4)
        }
        #expect(Set(phases).count == 30, "各フレームで違う値")
        #expect(Set(floatPhases).count < 15, "`Float` の time から取ると段になる: \(Set(floatPhases).count)")
        for (frame, phase) in phases.enumerated() {
            let expected = Float(Double(frame) / 60 / 4).truncatingRemainder(dividingBy: 1)
            #expect(abs(phase - expected) < 1e-6, "\(frame): \(phase) と \(expected)")
        }
    }

    @Test("1 か月走った後も、周期の刻みは 1 µs より細かい")
    func keepsMicrosecondsAfterAMonth() {
        let month = 30 * 86_400.0
        let one = periodPhase(ofSeconds: month + 1.000_000, period: 4)
        let other = periodPhase(ofSeconds: month + 1.000_001, period: 4)
        #expect(other > one)
    }

    @Test("周期が 0 以下・非有限なら 0 を返し、事情ごとに 1 度だけ知らせる")
    func anUnusablePeriodReturnsZero() {
        #expect(periodPhase(ofSeconds: 3, period: 0) == 0)
        #expect(periodPhase(ofSeconds: 3, period: -4) == 0)
        #expect(periodPhase(ofSeconds: 3, period: .nan) == 0)
        #expect(periodPhase(ofSeconds: 3, period: .infinity) == 0)
        #expect(NumberValues.warnings.message(for: .emptyRange(.phase))?.hasPrefix("phase()") == true)
        #expect(NumberValues.warnings.message(for: .notANumber(.phase))?.hasPrefix("phase()") == true)
        let first = NumberValues.warnings.message(for: .emptyRange(.phase))
        for _ in 0..<5 { #expect(periodPhase(ofSeconds: 3, period: 0) == 0) }
        #expect(NumberValues.warnings.message(for: .emptyRange(.phase)) == first)
    }
}

/// 周期の位相を、走っているスケッチの中で読む。時計を差し替えて回すので、GPU を要する。
@Suite(
    "周期の位相を時計から読む", .serialized,
    .enabled(if: RenderDevice.isAvailable, "この世代のコマンド構造に対応した GPU が無い実行環境ではスキップする"))
struct PhaseRuntimeTests {
    final class Scene: Sketch {
        init() {}
        let settings = SketchSettings(width: 16, height: 16)
        var phases: [Float] = []
        var times: [Float] = []
        var jumpTo: Float?
        func draw() {
            phases.append(phase(period: 4))
            times.append(time)
            if let jumpTo {
                jumpTime(jumpTo)
                self.jumpTo = nil
            }
            background(0)
        }
    }

    @Test("実時間の時計を 6.5 日進めても、60 fps の各フレームが違う位相を返し、time は段になる")
    func eachFrameDiffersOnAWeekLongRun() throws {
        var now = 0.0
        let scene = Scene()
        let runtime = try SketchRuntime(sketch: scene, gpu: RenderDevice(), clock: .wallClock, now: { now })
        defer { runtime.closePlugins() }
        try runtime.advance()  // 起点
        now = 6.5 * 86_400
        for _ in 0..<20 {
            try runtime.advance()
            now += 1.0 / 60
        }
        let phases = Array(scene.phases.dropFirst())
        let times = Array(scene.times.dropFirst())
        #expect(Set(phases).count == phases.count, "位相は各フレームで違う: \(phases)")
        #expect(Set(times).count < phases.count / 2, "対照: Float の time は段になっている: \(Set(times).count)")
        for (frame, phase) in phases.enumerated() {
            #expect(abs(phase - Float(frame) / 240) < 1e-5, "\(frame): \(phase)")
        }
    }

    @Test("jumpTime(-1) の次のフレームは 0.75")
    func negativeJumpWraps() throws {
        let scene = Scene()
        let runtime = try SketchRuntime(
            sketch: scene, gpu: RenderDevice(), clock: .frameIndex(frameRate: 60), now: { 0 })
        defer { runtime.closePlugins() }
        try runtime.advance()
        scene.jumpTo = -1
        try runtime.advance()
        try runtime.advance()
        #expect(scene.times.last == -1)
        #expect(scene.phases.last == 0.75)
    }

    /// `mokume render --seconds 4` の 240 枚は、位相 0 から 1 の手前までを覆い、次の周の頭 (0) へ継ぎ目なく続く。
    @Test("フレームの時計では、4 秒ぶんの枚が位相 0 から 1 の手前までを等間隔に覆う")
    func aFrameClockCoversOneLoop() throws {
        let scene = Scene()
        let runtime = try SketchRuntime(
            sketch: scene, gpu: RenderDevice(), clock: .frameIndex(frameRate: 60), now: { 0 })
        defer { runtime.closePlugins() }
        for _ in 0..<241 { try runtime.advance() }
        #expect(scene.phases.first == 0)
        for index in 0..<240 {
            #expect(abs(scene.phases[index] - Float(index) / 240) < 1e-6, "\(index)")
        }
        #expect(scene.phases[240] == 0, "次の周の頭は位相 0 に戻る")
    }

    @Test("時刻を指定した観測の枚の draw() は観測の秒から巡り、draw() の外と次の枚は作者の時計から巡る")
    func anObservedFrameFollowsTheObservedSecond() throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("mokume-phase-\(UUID())")
        try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: path) }
        let scene = Scene()
        let runtime = try SketchRuntime(
            sketch: scene, gpu: RenderDevice(), clock: .frameIndex(frameRate: 60), now: { 0 },
            observer: FrameObserver(directory: path))
        defer { runtime.closePlugins() }
        for _ in 0..<2 { try runtime.advance() }  // 作者の時計は 1/60 秒
        try AtomicFile.write(Data(#"{"id":"o","time":3}"#.utf8), to: path.appendingPathComponent("request.json"))
        try runtime.advance()
        #expect(scene.phases.last == 0.75, "観測の秒 3 は 4 秒周期の 0.75")
        try runtime.advance()
        #expect(abs(scene.phases.last! - Float(3.0 / 60 / 4)) < 1e-6, "次の枚は作者の時計から続く")
    }

    @Test("走っていない間に読むと 0 を返す")
    func outsideARunReturnsZero() {
        #expect(Scene().phase(period: 4) == 0)
    }
}
