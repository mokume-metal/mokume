// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation
import MokumeTestSupport
import Testing

@testable import MokumeCamera
@testable import MokumeCore

/// カメラを使った実行は、記録と再生の両方でカメラを理由に「再現を保証しない」と名乗る (#3575 の完了条件 1・案 A)。
///
/// 機材は開かない。機材の代わりに、何も届けない出どころ (``SilentSource``) を持つ入り口を同じ名前で足す — 判定が見るのは
/// 出どころが記録した列 (`createCapture(frames:)`) かどうかで、届いた絵ではない。記録した列の側は
/// `ReplayUnreproducibleTests` が見る。GPU を要する。
@Suite(
    "カメラを使った記録と再生",
    .serialized,
    .enabled(
        if: RenderDevice.isAvailable,
        "この世代のコマンド構造に対応した GPU が無い実行環境ではスキップする")
)
@MainActor
struct CaptureReplayTests {
    /// 機材のカメラを開いた (つもりの) スケッチ。
    final class Live: Sketch {
        var settings: SketchSettings { SketchSettings(width: 8, height: 8, frameRate: 60) }
        init() {}
        func setup() throws {
            attach(
                Capture(
                    image: try createImage(4, 4), device: nil, name: "camera", source: SilentSource(.running),
                    owner: self))
        }
        func draw() { background(0, 0, 0) }
    }

    @Test("実カメラを使った実行は、記録も再生もカメラを理由に名乗る。再生は記録が名乗っていなくても自分で見つける")
    func aLiveCameraIsNamedInBoth() throws {
        let directory = try TestScratch.directory("mokume-capture-replay")
        let url = directory.appendingPathComponent("take.json")
        let recorder = try SketchRuntime(
            sketch: Live(), gpu: RenderDevice(), clock: .frameIndex(frameRate: 60), persistsParams: false)
        try #require(recorder.startRecording(try #require(ReplayRequest(destination: url.path))))
        for _ in 0..<3 { try recorder.advance() }
        recorder.closePlugins()
        let camera = ReplayRecorder.Reason.outsideInput("camera")
        #expect(try ReplayRecord.read(from: url).unreproducible == [camera])

        // 記録の理由を消した写しを流す。流す側が入り口を足したときに自分で名乗る
        var document = try #require(
            try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        document["unreproducible"] = nil
        let copy = directory.appendingPathComponent("stripped.json")
        try JSONSerialization.data(withJSONObject: document).write(to: copy)
        for source in [url, copy] {
            let record = try ReplayRecord.read(from: source)
            let player = ReplayPlayer(record: record, source: source.path, reportURL: nil)
            let runtime = try SketchRuntime(
                sketch: Live(), gpu: RenderDevice(), clock: .frameIndex(frameRate: 60), now: { 0 },
                onScreen: false, persistsParams: false, opensFacets: false, handover: nil)
            runtime.startReplaying(player)
            var advances = 0
            while !player.isFinished, advances < 20 {
                player.beginAdvance(at: Double(advances))
                try runtime.advance()
                advances += 1
            }
            let report = try #require(runtime.finishReplaying())
            runtime.closePlugins()
            #expect(report.unreproducible == [camera], "\(source.lastPathComponent): \(report.unreproducible)")
        }
    }
}
