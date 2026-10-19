// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation
import MokumeDiagnostics
import Testing

@testable import MokumeCore

@Suite(
    "指定した秒で1枚観測する", .enabled(if: RenderDevice.isAvailable, "対応する GPU が必要"),
    .ownWarningDigest)
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
        // 起点は最初の枚 (観測の枚・105 秒) で、指定秒でも起動からの経過でもない (#2413)
        #expect(abs(scene.times.last! - 0.01) < 0.00001)
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
        #""time":-1"#, #""time":1e39"#, #""time":"three""#,
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

    /// 知らない鍵は要求を失敗させず、**撮ったうえで**応答の `warnings` で名乗る (#2392)。
    @Test("知らない鍵があっても等倍で撮り、warnings で名乗る")
    func namesAnUnknownKeyAndStillTakesTheShot() throws {
        let path = try facet(), scene = Scene()
        let runtime = try runtime(scene, path)
        try request(#"{"id":"x3","sacle":0.5}"#, to: path)
        try runtime.advance()
        let response = try report(path)
        #expect(response["id"] as? String == "x3")
        #expect(response["image"] != nil, "撮らずに断った")
        let warnings = response["warnings"] as? [String] ?? []
        #expect(warnings.contains { $0.contains("sacle") }, "\(warnings)")
    }

    @Test("断る応答にも、知らない鍵の名乗りが載る")
    func namesAnUnknownKeyInARefusal() throws {
        let path = try facet(), scene = Scene()
        let runtime = try runtime(scene, path)
        try request(#"{"id":"bad","time":-1,"sacle":0.5}"#, to: path)
        try runtime.advance()
        let response = try report(path)
        #expect(response["image"] == nil)
        let warnings = response["warnings"] as? [String] ?? []
        #expect(warnings.count == 2, "\(warnings)")
        #expect(warnings.contains { $0.contains("sacle") }, "\(warnings)")
    }

    /// 並んで走る別の検査が、同じ時に警告を言う形 (#2903)。別のタスクの警告は、検査が差した自分の
    /// 溜め場には入らず、応答の数は変わらない。溜め場を差さないと、プロセスの溜め場に居たその警告が
    /// 応答に混ざって数が増える。
    @Test("別のタスクが警告を言っていても、断る応答の警告の数は変わらない")
    func ignoresWarningsSaidByAnotherTask() async throws {
        let path = try facet(), scene = Scene()
        let runtime = try runtime(scene, path)
        // 別の検査のように、この検査のタスクローカル値を持たないタスクから言う
        await Task.detached {
            for number in 0..<5 { Diagnostics.warn("said by another test \(number)") }
        }.value
        try request(#"{"id":"bad","time":-1,"sacle":0.5}"#, to: path)
        try runtime.advance()
        let warnings = try report(path)["warnings"] as? [String] ?? []
        #expect(warnings.count == 2, "\(warnings)")
        #expect(!warnings.contains { $0.hasPrefix("said by another test") }, "\(warnings)")
    }

    @Test("この検査が言った警告は、プロセスの溜め場には入らず、並んで走る別の検査へ漏れない")
    func keepsItsWarningsOutOfTheSharedDigest() {
        // 差してあるのは、プロセスの溜め場とは別の、この検査だけの溜め場。共有の方は読まない
        // (読むと、まだ差していない別の検査の警告を持っていく)
        #expect(Diagnostics.digest != nil)
        #expect(Diagnostics.digest !== Diagnostics.sharedDigest)
        Diagnostics.warn("said by the observation time test")
        #expect(Diagnostics.takeUnreported() == ["said by the observation time test"])
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
        let deadline = DispatchTime.now() + 5
        var closed = runtime.closePlugins(.peek)
        while !closed, DispatchTime.now() < deadline {
            Thread.sleep(forTimeInterval: 0.005)
            closed = runtime.closePlugins(.peek)
        }
        try #require(closed)
        #expect(FileManager.default.fileExists(atPath: saved.path))
        #expect(try Data(contentsOf: saved) == Data(contentsOf: path.appendingPathComponent("frame-000.png")))
    }

    // MARK: - 観測の秒は draw() の外に残らない (#2357)

    /// `TimeAndScrub` の形: 矢印キーで `jumpTime(time + 0.25)` する作品。
    final class Scrubs: Sketch {
        init() {}
        let settings = SketchSettings(width: 32, height: 24)
        var callbackTimes: [Float] = []
        var drawTimes: [Float] = []
        func draw() {
            drawTimes.append(time)
            background(0)
        }
        func keyPressed() {
            callbackTimes.append(time)
            jumpTime(time + 0.25)
        }
    }

    private static let arrowRight = InputEvent.keyDown(
        code: .arrowRight, characters: "\u{F703}", isRepeat: false)

    /// 観測の枚に当たった矢印キーの `jumpTime(time + 0.25)` が、作者の時計を観測の秒 (5.25) へ飛ばしていた。
    @Test("観測の枚に当たった入力のコールバックは作者の時計の秒を読み、観測の後に時計が飛ばない")
    func callbacksReadTheAuthorsClockOnAnObservedFrame() throws {
        let path = try facet(), scene = Scrubs()
        let runtime = try SketchRuntime(
            sketch: scene, gpu: RenderDevice(), clock: .frameIndex(frameRate: 60), now: { 0 },
            observer: FrameObserver(directory: path))
        for _ in 0..<3 { try runtime.advance() }  // 作者の時計は 3 枚目 = 2/60 秒
        // 矢印キーを、時刻 5 の観測の枚に当てる (4 枚目 = 作者の時計では 3/60 秒)
        runtime.input.enqueue(Self.arrowRight)
        try request(#"{"id":"o","time":5}"#, to: path)
        try runtime.advance()

        let author = Float(3.0 / 60)
        #expect(scene.drawTimes.last == 5, "同じ枚の draw() は観測の秒を読む")
        #expect(scene.callbackTimes == [author], "コールバックが観測の秒を読んだ: \(scene.callbackTimes)")
        // draw() の外では作者の時計の秒 (観測の秒が残らない)
        #expect(runtime.time == author)

        try runtime.advance()
        #expect(scene.drawTimes.last == author + 0.25, "観測の後の時計は 当てる前の秒 + 0.25 に飛ぶ: \(scene.drawTimes)")
    }

    /// 陰性対照: 観測でない枚の入力のコールバックは、これまでどおり `draw()` と同じ秒を読む。
    @Test("観測でない枚では、コールバックも draw() も同じ秒を読む")
    func callbacksAndDrawAgreeOffObservation() throws {
        let path = try facet(), scene = Scrubs()
        let runtime = try SketchRuntime(
            sketch: scene, gpu: RenderDevice(), clock: .frameIndex(frameRate: 60), now: { 0 },
            observer: FrameObserver(directory: path))
        for _ in 0..<3 { try runtime.advance() }
        runtime.input.enqueue(Self.arrowRight)
        try runtime.advance()
        #expect(scene.callbackTimes == [Float(3.0 / 60)])
        #expect(scene.drawTimes.last == Float(3.0 / 60))
        try runtime.advance()
        #expect(scene.drawTimes.last == Float(3.0 / 60) + 0.25)
    }
}
