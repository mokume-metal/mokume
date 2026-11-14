// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation
import MokumeTestSupport
import Testing

@testable import MokumeAudio
@testable import MokumeCore

/// 鳴らすだけの合成音は記録の保証の内で、**解析の値を読んだときだけ**名乗る (#3575 の完了条件 7)。
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
    /// 三角波を鳴らし、`reads` が立っていれば 2 枚目で `level` を 1 度読むスケッチ。
    final class Beeper: Sketch {
        var reads = false
        var flow: SoundFlow?
        var tone: TriOsc?
        var settings: SketchSettings { SketchSettings(width: 8, height: 8, frameRate: 60) }
        init() {}
        convenience init(reads: Bool, flow: SoundFlow?) {
            self.init()
            self.reads = reads
            self.flow = flow
        }
        func setup() {
            let made = TriOsc(stage: SynthStage.stage(for: self, flow: flow))
            made.play(440, 0.3)
            tone = made
        }
        func draw() {
            background(0, 0, 0)
            if reads, frameCount == 2 { _ = tone?.level }
        }
    }

    /// 録る。`onScreen` ならウィンドウの経路で、音は差し込んだ流れで鳴る。
    private func record(reads: Bool, onScreen: Bool, to url: URL) throws -> ReplayRecord {
        let flow = onScreen ? try SoundFlow.offline(sampleRate: 48_000, channels: 2, maximumFrames: 4096) : nil
        let runtime = try SketchRuntime(
            sketch: Beeper(reads: reads, flow: flow), gpu: RenderDevice(), clock: .frameIndex(frameRate: 60),
            now: { 0 }, onScreen: onScreen, persistsParams: false)
        try #require(runtime.startRecording(try #require(ReplayRequest(destination: url.path))))
        for _ in 0..<3 { try runtime.advance() }
        runtime.closePlugins()
        return try ReplayRecord.read(from: url)
    }

    /// ウィンドウなしで流す。
    private func replay(reads: Bool, _ url: URL) throws -> ReplayPlayer.Report {
        let record = try ReplayRecord.read(from: url)
        let player = ReplayPlayer(record: record, source: url.path, reportURL: nil)
        let runtime = try SketchRuntime(
            sketch: Beeper(reads: reads, flow: nil), gpu: RenderDevice(), clock: .frameIndex(frameRate: 60),
            now: { 0 }, onScreen: false, persistsParams: false, opensFacets: false, handover: nil)
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
        let plain = try record(reads: false, onScreen: true, to: quiet)
        #expect(plain.window && plain.unreproducible.isEmpty, "\(plain.unreproducible)")
        #expect(try replay(reads: false, quiet).unreproducible.isEmpty)

        let read = directory.appendingPathComponent("read.json")
        let named = try record(reads: true, onScreen: true, to: read)
        #expect(named.unreproducible == [analysis], "\(named.unreproducible)")
        #expect(try replay(reads: true, read).unreproducible == [analysis])

        // 記録の理由を消しても、ウィンドウで録った記録を流す側が、読んだときに自分で名乗る
        var document = try #require(
            try JSONSerialization.jsonObject(with: Data(contentsOf: read)) as? [String: Any])
        document["unreproducible"] = nil
        let copy = directory.appendingPathComponent("stripped.json")
        try JSONSerialization.data(withJSONObject: document).write(to: copy)
        #expect(try replay(reads: true, copy).unreproducible == [analysis])
    }

    @Test("ウィンドウなしで録った記録は、解析の値を読んでも名乗らない (流す側と同じくフレームの数で進む)")
    func aHeadlessRecordIsNotNamed() throws {
        let url = try TestScratch.directory("mokume-replay-sound").appendingPathComponent("headless.json")
        let record = try record(reads: true, onScreen: false, to: url)
        #expect(!record.window && record.unreproducible.isEmpty, "\(record.unreproducible)")
        let report = try replay(reads: true, url)
        #expect(report.unreproducible.isEmpty && report.matched, "\(report.unreproducible)")
    }
}
