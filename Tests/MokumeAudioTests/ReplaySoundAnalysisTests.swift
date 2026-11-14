// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation
import MokumeTestSupport
import Testing

@testable import MokumeAudio
@testable import MokumeCore

/// 鳴らすだけの音は記録の保証の内で、**解析の値を読んだときだけ**名乗る (#3575 の完了条件 7)。音の待つ読み込みも名乗る。
///
/// ウィンドウの経路 (`onScreen: true`) は音を実時間で鳴らす。機材には出さず、manual rendering (offline) の流れを
/// 差し込んで回す。GPU を要する。
@Suite(
    "音の解析と記録",
    .serialized,
    .enabled(
        if: RenderDevice.isAvailable,
        "この世代のコマンド構造に対応した GPU が無い実行環境ではスキップする")
)
@MainActor
struct ReplaySoundAnalysisTests {
    /// 公開の解析の読み。**1 つずつ確かめる** — どれか 1 つの名乗りが外れても、その行だけが赤になる。
    enum Read: String, CaseIterable, Sendable {
        case rms, decibels, peak, spectrum, level, spectrumLevels, energy, waveform, isBeat
    }

    /// 読む音の出どころ。
    enum Source: String, CaseIterable, Sendable {
        /// 合成音 (``SynthSound``)。理由には型の名前 (`TriOsc`) が載る。
        case synth
        /// 音声ファイル (``SoundFile``)。
        case file

        var kind: String { self == .synth ? "TriOsc" : "SoundFile" }
    }

    /// 音を 1 つ鳴らし、`read` が立っていれば 2 枚目でそれを `times` 回読むスケッチ。
    final class Reader: Sketch {
        var source = Source.synth
        var read: Read?
        var times = 1
        var flow: SoundFlow?
        var file: URL?
        var tone: TriOsc?
        var sound: SoundFile?
        var settings: SketchSettings { SketchSettings(width: 8, height: 8, frameRate: 60) }
        init() {}
        convenience init(_ source: Source, read: Read?, times: Int = 1, flow: SoundFlow?, file: URL?) {
            self.init()
            self.source = source
            self.read = read
            self.times = times
            self.flow = flow
            self.file = file
        }
        func setup() throws {
            switch source {
            case .synth:
                let made = TriOsc(stage: SynthStage.stage(for: self, flow: flow))
                made.play(440, 0.3)
                tone = made
            case .file:
                let made = try loadSound(try #require(file).path, flow: flow)
                made.play()
                sound = made
            }
        }
        func draw() {
            background(0, 0, 0)
            guard let read, frameCount == 2 else { return }
            for _ in 0..<times { take(read) }
        }
        private func take(_ read: Read) {
            switch read {
            case .rms: _ = (tone?.rms, sound?.rms)
            case .decibels: _ = (tone?.decibels, sound?.decibels)
            case .peak: _ = (tone?.peak, sound?.peak)
            case .spectrum: _ = (tone?.spectrum, sound?.spectrum)
            case .level: _ = (tone?.level, sound?.level)
            case .spectrumLevels: _ = (tone?.spectrumLevels, sound?.spectrumLevels)
            case .energy: _ = (tone?.energy(from: 20, to: 140), sound?.energy(from: 20, to: 140))
            case .waveform: _ = (tone?.waveform, sound?.waveform)
            case .isBeat: _ = (tone?.isBeat, sound?.isBeat)
            }
        }
    }

    /// 録る。`onScreen` ならウィンドウの経路で、音は差し込んだ流れで鳴る。録り終えた実行も返す (音を読むため)。
    private func record(
        _ source: Source = .synth, read: Read?, times: Int = 1, onScreen: Bool, to url: URL, file: URL? = nil
    ) throws -> (record: ReplayRecord, sketch: Reader) {
        let flow = onScreen ? try SoundFlow.offline(sampleRate: 48_000, channels: 2, maximumFrames: 4096) : nil
        let sketch = Reader(source, read: read, times: times, flow: flow, file: file)
        let runtime = try SketchRuntime(
            sketch: sketch, gpu: RenderDevice(), clock: .frameIndex(frameRate: 60),
            now: { 0 }, onScreen: onScreen, persistsParams: false)
        try #require(runtime.startRecording(try #require(ReplayRequest(destination: url.path))))
        for _ in 0..<3 { try runtime.advance() }
        runtime.closePlugins()
        return (try ReplayRecord.read(from: url), sketch)
    }

    /// ウィンドウなしで流す。
    private func replay(read: Read?, _ url: URL) throws -> ReplayPlayer.Report {
        let record = try ReplayRecord.read(from: url)
        let player = ReplayPlayer(record: record, source: url.path, reportURL: nil)
        let runtime = try SketchRuntime(
            sketch: Reader(.synth, read: read, flow: nil, file: nil), gpu: RenderDevice(),
            clock: .frameIndex(frameRate: 60), now: { 0 }, onScreen: false, persistsParams: false, opensFacets: false,
            handover: nil)
        runtime.startReplaying(player)
        var advances = 0
        while !player.isFinished, advances < 20 {
            player.beginAdvance(at: Double(advances))
            try runtime.advance()
            advances += 1
        }
        let report = try #require(runtime.finishReplaying())
        runtime.closePlugins()
        return report
    }

    @Test("鳴らすだけの音は、ウィンドウで録っても名乗らない。level を 1 度読むと、音の印が 1 つ付き、流す側も名乗る")
    func onlyAnAnalysisReadIsNamed() throws {
        let directory = try TestScratch.directory("mokume-replay-sound")
        let analysis = ReplayRecorder.Reason.soundAnalysis("TriOsc")

        let quiet = directory.appendingPathComponent("quiet.json")
        let plain = try record(read: nil, onScreen: true, to: quiet).record
        #expect(plain.window && plain.unreproducible.isEmpty, "\(plain.unreproducible)")
        #expect(try replay(read: nil, quiet).unreproducible.isEmpty)

        let read = directory.appendingPathComponent("read.json")
        let named = try record(read: .level, onScreen: true, to: read).record
        #expect(named.unreproducible == [analysis], "\(named.unreproducible)")
        #expect(try replay(read: .level, read).unreproducible == [analysis])

        // 記録の理由を消しても、ウィンドウで録った記録を流す側が、読んだときに自分で名乗る
        var document = try #require(
            try JSONSerialization.jsonObject(with: Data(contentsOf: read)) as? [String: Any])
        document["unreproducible"] = nil
        let copy = directory.appendingPathComponent("stripped.json")
        try JSONSerialization.data(withJSONObject: document).write(to: copy)
        #expect(try replay(read: .level, copy).unreproducible == [analysis])
    }

    @Test(
        "合成音と音声ファイルの公開の解析の読みは、どれを読んでもウィンドウで録った記録が音の解析を名乗る",
        arguments: Source.allCases, Read.allCases)
    func everyAnalysisReadIsNamed(source: Source, read: Read) throws {
        let directory = try TestScratch.directory("mokume-replay-sound")
        let file = source == .file ? try writeWAV(chord, sampleRate: 48_000) : nil
        defer { if let file { try? FileManager.default.removeItem(at: file) } }
        let url = directory.appendingPathComponent("\(source)-\(read).json")
        let named = try record(source, read: read, onScreen: true, to: url, file: file).record
        #expect(
            named.unreproducible == [ReplayRecorder.Reason.soundAnalysis(source.kind)],
            "\(source).\(read): \(named.unreproducible)")
    }

    @Test("1 フレームに解析の値を何百回読んでも、名乗りの理由を組むのは実行ごとに 1 回で、記録の理由も 1 つ")
    func manyReadsBuildTheReasonOnce() throws {
        let url = try TestScratch.directory("mokume-replay-sound").appendingPathComponent("many.json")
        let (taken, sketch) = try record(read: .level, times: 300, onScreen: true, to: url)
        #expect(taken.unreproducible == [ReplayRecorder.Reason.soundAnalysis("TriOsc")], "\(taken.unreproducible)")
        #expect(sketch.tone?.replayReasonsBuilt == 1)
    }

    @Test("ウィンドウなしで録った記録は、解析の値を読んでも名乗らない (流す側と同じくフレームの数で進む)")
    func aHeadlessRecordIsNotNamed() throws {
        let url = try TestScratch.directory("mokume-replay-sound").appendingPathComponent("headless.json")
        let (taken, sketch) = try record(read: .level, onScreen: false, to: url)
        #expect(!taken.window && taken.unreproducible.isEmpty, "\(taken.unreproducible)")
        #expect(sketch.tone?.replayReasonsBuilt == 0, "名乗らない実行では理由を組まない")
        let report = try replay(read: .level, url)
        #expect(report.unreproducible.isEmpty && report.matched, "\(report.unreproducible)")
    }

    // MARK: - 待つ読み込み

    /// `setup()` で起こした `Task` から、在らない音声ファイルを `requestSound(_:)` で頼むスケッチ。
    final class SoundRequester: Sketch {
        var loading: Task<Void, Never>?
        var settings: SketchSettings { SketchSettings(width: 8, height: 8, frameRate: 60) }
        init() {}
        func setup() {
            // 在らない名前でよい。名乗るのは、待つ読み込みの API を使ったことである
            loading = Task { [self] in _ = try? await requestSound("missing.wav") }
        }
        func draw() { background(0, 0, 0) }
    }

    @Test("requestSound(_:) を使うと、記録が「待つ読み込み」を名乗る")
    func requestSoundIsNamed() async throws {
        let url = try TestScratch.directory("mokume-replay-sound").appendingPathComponent("request.json")
        let sketch = SoundRequester()
        let runtime = try SketchRuntime(
            sketch: sketch, gpu: RenderDevice(), clock: .frameIndex(frameRate: 60), now: { 0 }, onScreen: false,
            persistsParams: false)
        try #require(runtime.startRecording(try #require(ReplayRequest(destination: url.path))))
        for frame in 1...3 {
            try runtime.advance()
            if frame == 1 { await sketch.loading?.value }
        }
        runtime.closePlugins()
        let record = try ReplayRecord.read(from: url)
        #expect(record.unreproducible == [ReplayRecorder.Reason.waitingLoad], "\(record.unreproducible)")
    }
}
