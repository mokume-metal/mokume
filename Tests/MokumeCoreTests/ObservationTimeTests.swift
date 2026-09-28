// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation
import Testing

@testable import MokumeCore

@Suite("指定した秒で1枚観測する", .enabled(if: RenderDevice.isAvailable, "対応する GPU が必要"))
struct ObservationTimeTests {
    final class Scene: Sketch {
        init() {}
        let settings = SketchSettings(width: 64, height: 48)
        var stop = false
        var blue = false
        var startRecording: String?
        var draws = 0
        var times: [Float] = []
        var deltas: [Float] = []
        func setup() { if stop { noLoop() } }
        func draw() {
            draws += 1
            times.append(time)
            deltas.append(deltaTime)
            if let startRecording { beginRecord(startRecording) }
            background(0)
            noStroke()
            if blue { fill(30, 80, 250) } else { fill(250, 80, 30) }
            circle(32 + cos(time) * 20, 24, 12)
        }
    }

    private func facet() throws -> URL {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("mokume-time-\(UUID())")
        try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
        return path
    }

    private func request(_ body: String, to path: URL) throws {
        try AtomicFile.write(Data(body.utf8), to: path.appendingPathComponent("request.json"))
    }

    private func report(_ path: URL) throws -> [String: Any] {
        try #require(JSONSerialization.jsonObject(with: Data(contentsOf: path.appendingPathComponent("report.json"))) as? [String: Any])
    }

    private func runtime(_ scene: Scene, _ path: URL, clock: Clock? = nil, now: @escaping () -> Double = { 0 }) throws -> SketchRuntime {
        try SketchRuntime(sketch: scene, gpu: RenderDevice(), clock: clock, now: now, observer: FrameObserver(directory: path))
    }

    @Test("同じ秒の絵は一致し、秒と色の編集はそれぞれ絵を変える")
    func sameTimeAndEdits() throws {
        let path = try facet(), scene = Scene()
        let runtime = try runtime(scene, path)
        var images: [Data] = []
        for (index, time) in [3.0, 3.0, 4.0, 3.0].enumerated() {
            scene.blue = index == 3
            try request("{\"id\":\"\(index)\",\"time\":\(time)}", to: path)
            try runtime.advance()
            let response = try report(path)
            #expect(response["appliedTime"] as? Double == time)
            #expect(response["time"] as? Double == time)
            #expect(response["frame"] as? Int == index + 1)
            #expect(response["schemaVersion"] as? Int == 2)
            images.append(try Data(contentsOf: path.appendingPathComponent("frame-000.png")))
        }
        #expect(images[0] == images[1])
        #expect(images[0] != images[2])
        #expect(images[0] != images[3])
        #expect(scene.draws == 4)
        #expect(scene.deltas == [0, 0, 0, 0])
        try runtime.advance()
        #expect(scene.draws == 5)
        #expect(scene.times.last == Float(4.0 / 60))
        #expect(scene.deltas.last == Float(1.0 / 60))
    }

    @Test("実時計へ戻った枚は指定秒との差を経過にせず、実時間を読む")
    func wallClockResumes() throws {
        let path = try facet(), scene = Scene()
        var now = 100.0
        let runtime = try runtime(scene, path, clock: .wallClock, now: { now })
        now = 105
        try request(#"{"id":"a","time":0.1}"#, to: path)
        try runtime.advance()
        #expect(try report(path)["appliedTime"] as? Double == Double(Float(0.1)))
        now = 105.01
        try runtime.advance()
        #expect(scene.times.last == Float(5.01))
        #expect(abs(scene.deltas.last! - 0.01) < 0.00001)
    }

    @Test("noLoop の最初の観測も1枚だけ描き、停止を保つ")
    func preservesNoLoop() throws {
        let path = try facet(), scene = Scene()
        scene.stop = true
        let runtime = try runtime(scene, path)
        try request(#"{"id":"a","time":3}"#, to: path)
        try runtime.advance()
        #expect(scene.draws == 1)
        #expect(!runtime.isLooping)
        try runtime.advance()
        #expect(scene.draws == 1)
        try request(#"{"id":"b"}"#, to: path)
        try runtime.advance()
        #expect(scene.draws == 1)
        #expect(try report(path)["appliedTime"] == nil)
        try request(#"{"id":"c","time":4}"#, to: path)
        try runtime.advance()
        #expect(scene.draws == 2)
        #expect(!runtime.isLooping)
    }

    @Test("無効な時刻や複数撮影を、通常の成功へ落とさない", arguments: [
        #""time":-1"#, #""time":1e39"#, #""time":null"#, #""time":"three""#,
        #""time":true"#, #""time":3,"count":2"#, #""time":3,"every":2"#,
    ])
    func refusesInvalidFields(_ fields: String) throws {
        let path = try facet(), scene = Scene()
        let runtime = try runtime(scene, path)
        try request("{\"id\":\"bad\",\(fields)}", to: path)
        try runtime.advance()
        let response = try report(path)
        #expect(response["id"] as? String == "bad")
        #expect(response["image"] == nil)
        #expect(response["appliedTime"] == nil)
        #expect(!(response["warnings"] as? [String] ?? []).isEmpty)
        #expect(scene.draws == 0)
    }

    @Test("外部停止と録画中は描き直さず理由を返す", arguments: [false, true])
    func refusesWhileUnavailable(recording: Bool) throws {
        let path = try facet(), scene = Scene()
        let runtime = try runtime(scene, path)
        try runtime.advance()
        if recording { runtime.beginRecord(path.appendingPathComponent("shot-###.png").path) }
        else { runtime.pause() }
        try request(#"{"id":"a","time":3}"#, to: path)
        try runtime.advance()
        let response = try report(path)
        #expect(scene.draws == 1)
        #expect(response["image"] == nil)
        #expect(response["appliedTime"] == nil)
        #expect(!(response["warnings"] as? [String] ?? []).isEmpty)
        if recording { runtime.endRecord() }
    }

    @Test("指定した枚が描けなければ古い絵を成功として返さない")
    func drawFailureIsNotSuccess() throws {
        let path = try facet(), scene = Scene()
        let runtime = try runtime(scene, path)
        try runtime.advance()
        runtime.canvas.failureForTesting = .encoderUnavailable
        try request(#"{"id":"a","time":3}"#, to: path)
        #expect(throws: RenderFailure.self) { try runtime.advance() }
        let response = try report(path)
        #expect(response["image"] == nil)
        #expect(response["appliedTime"] == nil)
    }

    @Test("指定の枚で連続録画を始めず、通常の枚で始められる")
    func recordingCannotBeginAtAnOverride() throws {
        let path = try facet(), scene = Scene()
        scene.startRecording = path.appendingPathComponent("shot-###.png").path
        let runtime = try runtime(scene, path)
        try request(#"{"id":"a","time":3}"#, to: path)
        try runtime.advance()
        #expect(runtime.recorderWarnings == nil)
        try runtime.advance()
        #expect(runtime.recorderWarnings != nil)
        runtime.endRecord()
    }
    @Test("単発の保存予約は妨げず、指定した枚も保存できる")
    func permitsAStillSave() throws {
        let path = try facet(), scene = Scene()
        scene.stop = true
        let runtime = try runtime(scene, path)
        let saved = path.appendingPathComponent("still.png")
        runtime.save(saved.path)
        try request(#"{"id":"a","time":3}"#, to: path)
        try runtime.advance()
        #expect(try report(path)["appliedTime"] as? Double == 3)
        let deadline = Date().addingTimeInterval(5)
        var closed = runtime.closePlugins(.peek)
        while !closed, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.005)
            closed = runtime.closePlugins(.peek)
        }
        try #require(closed)
        #expect(FileManager.default.fileExists(atPath: saved.path))
        #expect(try Data(contentsOf: saved) == Data(contentsOf: path.appendingPathComponent("frame-000.png")))
    }

}
