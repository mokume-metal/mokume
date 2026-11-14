// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import AppKit
import Foundation
import MokumeTestSupport
import Testing

@testable import MokumeCore
@testable import reference_sketches

/// 記録の読み手 (#3571)。GPU を要さない。
@Suite("記録を読む")
@MainActor
struct ReplayRecordReadingTests {
    private func record(_ text: String) throws(ReplayRecord.Unreadable) -> ReplayRecord {
        try ReplayRecord.decode(Data(text.utf8), from: "take.json")
    }

    private static let head =
        #""schemaVersion":1,"id":"r","clock":{"kind":"frames","frameRate":60},"size":{"width":16,"height":16},"#
        + #""window":false,"start":{"seed":0,"seconds":0,"paused":false,"params":[]}"#

    @Test("代表例を読み、入力は出来事に、expose は値に、有限でない開始のつまみは数に戻る")
    func theExampleIsRead() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Schemas/examples/replay-record.json")
        let record = try ReplayRecord.read(from: url)
        #expect(record.frameRate == 60 && record.width == 640 && record.window)
        #expect(record.steps[1].inputs.count == 2)
        #expect(record.steps[0].expose["score"] == .int(0))
        let gain = try #require(record.startParams.first { $0.name == "gain" })
        guard case .float(let value) = gain.value else {
            Issue.record("\(gain)")
            return
        }
        #expect(value.isNaN)
    }

    @Test("完成の印が無い・版が違う・知らない入力の記録は、理由つきで断る")
    func unreadableRecordsAreRefused() {
        #expect(throws: ReplayRecord.Unreadable.self) {
            try record("{" + Self.head + #","steps":[]}"#)
        }
        #expect(throws: ReplayRecord.Unreadable.self) {
            try record(#"{"schemaVersion":2,"complete":true}"#)
        }
        #expect(throws: ReplayRecord.Unreadable.self) {
            try record(
                "{" + Self.head + #","steps":[{"step":0,"frame":1,"drew":true,"inputs":[{"type":"warp"}]}],"complete":true}"#)
        }
        do {
            _ = try record(#"{"schemaVersion":2,"complete":true}"#)
        } catch {
            #expect(error.reason.contains("version 2"), "\(error.reason)")
        }
        // 読める最小の記録
        #expect((try? record("{" + Self.head + #","steps":[],"complete":true}"#)) != nil)
    }

    @Test("環境の合図は読んだら消し、絶対パスでない値・読めない記録は流さない理由を持つ")
    func theStartupSignal() {
        var unset: [String] = []
        #expect(ReplayPlayer.startup(environment: [:], unset: { unset.append($0) }, reportURL: nil) == nil)
        let relative = ReplayPlayer.startup(
            environment: [StartupReads.replay.key: "take.json"], unset: { unset.append($0) }, reportURL: nil)
        #expect(relative?.problem?.contains("absolute path") == true)
        #expect(unset == [StartupReads.replay.key])
        let missing = ReplayPlayer.startup(
            environment: [StartupReads.replay.key: "/nonexistent/take.json"], unset: { _ in }, reportURL: nil)
        #expect(missing?.problem != nil && missing?.isFinished == true)
        #expect(StartupReads.all.contains(StartupReads.replay))
    }
}

/// 記録を流して照らす (#3571)。記録は同じプロセスで ``SketchRuntime`` を直に回して取り、流す側も直に回す。GPU を要する。
@Suite(
    "記録を流して照らす",
    .serialized,
    .enabled(
        if: RenderDevice.isAvailable,
        "この世代のコマンド構造に対応した GPU が無い実行環境ではスキップする")
)
@MainActor
struct ReplayPlaybackTests {
    final class Playground: Sketch {
        @Param(0...300) var radius: Double = 100
        var settings: SketchSettings { SketchSettings(width: 16, height: 16, frameRate: 60) }
        func draw() {
            background(Float(radius / 300))
            expose("frame", frameCount)
            expose("radius", radius)
            expose("right", keyboard.isPressed(.arrowRight))
            expose("time", time)
        }
    }

    final class Stopper: Sketch {
        var settings: SketchSettings { SketchSettings(width: 16, height: 16, frameRate: 60) }
        func setup() { noLoop() }
        func draw() {
            background(0.2)
            expose("scroll", scrollY)
        }
        func mouseWheel(deltaX: Float, deltaY: Float) { redraw() }
    }

    final class Timed: Sketch {
        var settings: SketchSettings { SketchSettings(width: 16, height: 16, frameRate: 60) }
        func draw() {
            background(0.1)
            expose("time", time)
        }
    }

    final class Mover: Sketch {
        var settings: SketchSettings { SketchSettings(width: 16, height: 16, frameRate: 60) }
        func draw() {
            background(0.1)
            expose("moved", movedX)
        }
    }

    private func scratch() throws -> URL { try TestScratch.directory("mokume-replay-play") }

    /// 記録する。`body` はフレームの番号ごとに、`advance()` の前に呼ぶ。
    private func record(
        _ sketch: any Sketch, frames: Int, to url: URL, observer: FrameObserver? = nil,
        handover: ClockHandover? = nil, _ body: (Int, SketchRuntime) throws -> Void = { _, _ in }
    ) throws {
        let runtime: SketchRuntime
        if let observer {
            runtime = try SketchRuntime(
                sketch: sketch, gpu: RenderDevice(), clock: .frameIndex(frameRate: 60), now: { 0 }, observer: observer)
        } else if let handover {
            runtime = try SketchRuntime(
                sketch: sketch, gpu: RenderDevice(), clock: .frameIndex(frameRate: 60), now: { 500 },
                persistsParams: false, handover: handover)
        } else {
            runtime = try SketchRuntime(
                sketch: sketch, gpu: RenderDevice(), clock: .frameIndex(frameRate: 60), persistsParams: false)
        }
        try #require(runtime.startRecording(try #require(ReplayRequest(destination: url.path))))
        for frame in 1...frames {
            try body(frame, runtime)
            try runtime.advance()
        }
        runtime.closePlugins()
    }

    /// 流す。**`SketchApplication` が流す子を組むのと同じ引数で** ランタイムを組み、終わるまで回す (期限は回数で持つ)。
    private func replay(
        _ sketch: any Sketch, _ url: URL, report: URL? = nil, _ during: (SketchRuntime) -> Void = { _ in }
    ) throws -> (ReplayPlayer.Report, SketchRuntime) {
        let record = try ReplayRecord.read(from: url)
        let player = ReplayPlayer(record: record, source: url.path, reportURL: report)
        let runtime = try SketchRuntime(
            sketch: sketch, gpu: RenderDevice(), clock: .frameIndex(frameRate: record.frameRate), now: { 0 },
            onScreen: false, persistsParams: false, opensFacets: false, handover: player.clockStart)
        runtime.startReplaying(player)
        var advances = 0
        while !player.isFinished, advances < record.steps.count * 2 + 10 {
            player.beginAdvance(at: Double(advances))
            during(runtime)
            try runtime.advance()
            advances += 1
        }
        let result = try #require(runtime.finishReplaying())
        runtime.closePlugins()
        return (result, runtime)
    }

    @Test("つまみの書き込み・時刻を指定した観測・キーを含む記録を流すと、照合がすべて一致する")
    func knobsAndTimedObservationsMatch() throws {
        let directory = try scratch()
        let url = directory.appendingPathComponent("take.json")
        let facet = directory.appendingPathComponent("observe", isDirectory: true)
        try FileManager.default.createDirectory(at: facet, withIntermediateDirectories: true)
        try record(Playground(), frames: 130, to: url, observer: FrameObserver(directory: facet)) { frame, runtime in
            if frame == 5 { _ = runtime.paramRegistry.write(.float(250), to: "radius") }
            if frame == 10 { runtime.input.enqueue(.keyDown(code: .arrowRight, characters: "", isRepeat: false)) }
            if frame == 12 {
                try AtomicFile.write(
                    Data(#"{"id":"t1","time":2.5}"#.utf8), to: facet.appendingPathComponent("request.json"))
            }
            if frame == 40 { runtime.input.enqueue(.keyUp(code: .arrowRight)) }
        }
        let read = try ReplayRecord.read(from: url)
        try #require(read.steps.contains { $0.observeTime == 2.5 } && read.steps.contains { !$0.params.isEmpty })

        let report = directory.appendingPathComponent("replay/report.json")
        let (result, _) = try replay(Playground(), url, report: report)
        #expect(result.matched, "\(String(describing: result.firstMismatch))")
        #expect(result.problem == nil && result.mismatches == 0 && result.steps == 130 && result.frames == 130)
        #expect(result.timing.frames.count == 0 || result.timing.heaviest != nil)
        // 結果のファイル
        let written = try #require(
            try JSONSerialization.jsonObject(with: Data(contentsOf: report)) as? [String: Any])
        #expect(written["matched"] as? Bool == true && written["schemaVersion"] as? Int == 1)
    }

    @Test("作例 BricksAndBall の 3600 フレームの記録が一致し、→ を押し始める枚を 1 枚遅らせると、そのフレームを名乗る")
    func bricksAndBallMatchesAndAShiftIsNamed() throws {
        let directory = try scratch()
        let url = directory.appendingPathComponent("bricks.json")
        try record(BricksAndBall(), frames: 3600, to: url) { frame, runtime in
            if frame == 100 { runtime.input.enqueue(.keyDown(code: .arrowRight, characters: "", isRepeat: false)) }
            if frame == 130 { runtime.input.enqueue(.keyUp(code: .arrowRight)) }
        }
        let (matched, _) = try replay(BricksAndBall(), url)
        #expect(matched.matched, "\(String(describing: matched.firstMismatch))")
        #expect(matched.frames == 3600 && matched.steps == 3600)

        // 入力を 1 枚遅らせた記録 (step 99 の keyDown を step 100 へ)
        var document = try #require(
            try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        var steps = try #require(document["steps"] as? [[String: Any]])
        let inputs = try #require(steps[99]["inputs"])
        steps[99]["inputs"] = nil
        steps[100]["inputs"] = inputs
        document["steps"] = steps
        let shifted = directory.appendingPathComponent("shifted.json")
        try JSONSerialization.data(withJSONObject: document).write(to: shifted)
        let (differed, _) = try replay(BricksAndBall(), shifted)
        #expect(!differed.matched)
        #expect(differed.firstMismatch?.frame == 100, "\(String(describing: differed.firstMismatch))")
        #expect(differed.firstMismatch?.what == "expose")
        #expect(ReplayPlayer.summary(of: differed).contains("at frame 100"))
    }

    @Test("止めた作品の記録 (回の欠けを含む) が一致する")
    func aStoppedSketchMatches() throws {
        let url = try scratch().appendingPathComponent("take.json")
        try record(Stopper(), frames: 6, to: url) { frame, runtime in
            if frame == 3 { runtime.input.enqueue(.scrolled(dx: 0, dy: 5)) }
            if frame == 5 { runtime.input.enqueue(.scrolled(dx: 0, dy: 3)) }
        }
        let (result, _) = try replay(Stopper(), url)
        #expect(result.matched, "\(String(describing: result.firstMismatch))")
    }

    @Test("watch --keep-time の世代の記録は、最初の枚の time が記録と同じで一致し、止めたままの世代は止まったまま")
    func aKeptClockIsReplayed() throws {
        var kept: URL?
        for held in [false, true] {
            let snapshot = ClockHandover.Snapshot(
                seconds: 8, isHeld: held, isStill: false, rate: 1, at: 490, writer: 1, generation: 1)
            let handover = ClockHandover(
                read: { .found(snapshot) }, write: { _ in }, isAlive: { _ in true }, warn: { _ in })
            let url = try scratch().appendingPathComponent("kept.json")
            try record(Timed(), frames: 5, to: url, handover: handover)
            if !held { kept = url }
            let read = try ReplayRecord.read(from: url)
            #expect(read.startSeconds != 0 && read.startPaused == held)
            let (result, _) = try replay(Timed(), url)
            #expect(result.matched, "held \(held): \(String(describing: result.firstMismatch))")
            let first = try #require(read.steps.first?.expose["time"])
            let last = try #require(read.steps.last?.expose["time"])
            #expect((first == last) == held, "止めた世代は time が動かない")
        }
        // 開始の秒を当てずに流すと、最初の枚から食い違う (当てていることを見る)
        let url = try #require(kept)
        let player = ReplayPlayer(record: try ReplayRecord.read(from: url), source: url.path, reportURL: nil)
        let runtime = try SketchRuntime(
            sketch: Timed(), gpu: RenderDevice(), clock: .frameIndex(frameRate: 60), now: { 0 },
            onScreen: false, persistsParams: false, opensFacets: false, handover: nil)
        runtime.startReplaying(player)
        try runtime.advance()
        _ = runtime.finishReplaying()
        runtime.closePlugins()
        #expect(player.firstMismatch?.frame == 1 && player.firstMismatch?.name == "time")
    }

    @Test("区画から送った極端な有限の値 2 件は、流す側でも同じ層で 2 件目を捨て、警告が出て、照合が一致する")
    func extremeInputsAreDroppedInTheSameLayer() throws {
        let url = try scratch().appendingPathComponent("take.json")
        try record(Mover(), frames: 3, to: url) { frame, runtime in
            if frame == 2 {
                runtime.input.enqueue(.mouseMovedBy(dx: 3e38, dy: 0))
                runtime.input.enqueue(.mouseMovedBy(dx: 3e38, dy: 0))
            }
        }
        let (result, runtime) = try replay(Mover(), url)
        #expect(result.matched, "\(String(describing: result.firstMismatch))")
        #expect(runtime.input.warnings.hasWarned(.nonFiniteEvent), "警告は流す側でも出る")
    }

    @Test("流している間に入力を送っても混ざらない: 流す側の合流点の外から来たものは照合を崩す (混ざれば食い違う)")
    func outsideInputWouldShowAsAMismatch() throws {
        // 区画は開かない (opensFacets: false) ので、外から入る道は無い。ここでは、混ざれば照合が名乗ることを確かめる
        let url = try scratch().appendingPathComponent("take.json")
        try record(Playground(), frames: 20, to: url)
        let (clean, _) = try replay(Playground(), url)
        #expect(clean.matched)
        var injected = false
        let (mixed, _) = try replay(Playground(), url) { runtime in
            if !injected, runtime.frameCount == 10 {
                injected = true
                runtime.input.enqueue(.keyDown(code: .arrowRight, characters: "", isRepeat: false))
            }
        }
        #expect(!mixed.matched && mixed.firstMismatch?.frame == 11 && mixed.firstMismatch?.name == "right")
    }

    @Test("記録と描く大きさが違えば、流さずに理由を書く")
    func aDifferentSizeIsNotReplayed() throws {
        final class Wide: Sketch {
            var settings: SketchSettings { SketchSettings(width: 32, height: 16, frameRate: 60) }
            func draw() { background(0) }
        }
        let url = try scratch().appendingPathComponent("take.json")
        try record(Timed(), frames: 2, to: url)
        let (result, _) = try replay(Wide(), url)
        #expect(!result.matched && result.problem?.contains("16×16") == true)
        #expect(result.frames == 0, "1 枚も進めない")
    }
}

/// 流す子の起こし方 (`SketchApplication`) — ウィンドウも区画も開かず、全速の駆動で回り、結果と終了コードを返す (#3571)。
@Suite(
    "流す子の起こし方",
    .serialized,
    .enabled(
        if: RenderDevice.isAvailable,
        "この世代のコマンド構造に対応した GPU が無い実行環境ではスキップする")
)
@MainActor
struct ReplayChildTests {
    private func run(_ application: SketchApplication, fires: Int) -> (finished: Bool, exit: Int32?) {
        var finished = false
        var exit: Int32?
        application.onRenderFinished = { finished = true }
        application.onStopSignal = {}
        application.exitProcess = { exit = $0 }
        application.resolveOutlet()
        application.didFinishLaunching()
        for _ in 0..<fires where !finished { application.displayLinkFired() }
        application.willTerminate()
        return (finished, exit)
    }

    @Test("流す子は画面に出さず、区画を開かず、全速の駆動で回り、一致すれば 0 で終わり、食い違えば 1 で終わる")
    func theChildRunsHeadlessAndExits() throws {
        let kept = SignalState.current()
        defer { kept.restore() }
        sketchStopRequested = 0
        let directory = try TestScratch.directory("mokume-replay-child")
        let url = directory.appendingPathComponent("take.json")
        let runtime = try SketchRuntime(
            sketch: ReplayPlaybackTests.Playground(), gpu: RenderDevice(), clock: .frameIndex(frameRate: 60),
            persistsParams: false)
        runtime.startRecording(try #require(ReplayRequest(destination: url.path)))
        for frame in 1...30 {
            if frame == 7 { runtime.input.enqueue(.keyDown(code: .arrowRight, characters: "", isRepeat: false)) }
            try runtime.advance()
        }
        runtime.closePlugins()

        let report = directory.appendingPathComponent("report.json")
        let player = try #require(
            ReplayPlayer.startup(
                environment: [StartupReads.replay.key: url.path], unset: { _ in }, reportURL: report))
        let application = try SketchApplication(
            sketch: ReplayPlaybackTests.Playground(), gpu: RenderDevice(), render: nil, replay: player)
        #expect(!application.isOnScreen && !application.holdsDisplayAwake)
        #expect(application.activationPolicy == .accessory && !application.endsAfterLastWindowClosed)
        let ran = run(application, fires: 100)
        #expect(ran.finished && ran.exit == nil, "一致すれば 0 で終わる")
        #expect(!application.fullSpeedDriver.isAttached, "流し終えたら駆動を畳む")
        #expect(player.report?.matched == true && player.report?.frames == 30)
        #expect(FileManager.default.fileExists(atPath: report.path))

        // 読めない記録: 作品を 1 枚も進めず、結果を書いて 1 で終わる
        let broken = directory.appendingPathComponent("broken.json")
        try Data("{}".utf8).write(to: broken)
        let refused = try #require(
            ReplayPlayer.startup(
                environment: [StartupReads.replay.key: broken.path], unset: { _ in }, reportURL: report))
        let second = try SketchApplication(
            sketch: ReplayPlaybackTests.Playground(), gpu: RenderDevice(), render: nil, replay: refused)
        let failed = run(second, fires: 5)
        #expect(failed.exit == 1 && refused.report?.frames == 0)
        #expect(refused.report?.problem != nil)
    }

    @Test("区画 input / params / observe に要求が在っても、流す子は読まず応えず、照合が一致する")
    func theChildLeavesTheFacetsAlone() throws {
        let kept = SignalState.current()
        defer { kept.restore() }
        sketchStopRequested = 0
        let directory = try TestScratch.directory("mokume-replay-facets")
        let url = directory.appendingPathComponent("take.json")
        let runtime = try SketchRuntime(
            sketch: ReplayPlaybackTests.Playground(), gpu: RenderDevice(), clock: .frameIndex(frameRate: 60),
            persistsParams: false)
        runtime.startRecording(try #require(ReplayRequest(destination: url.path)))
        for _ in 1...20 { try runtime.advance() }
        runtime.closePlugins()

        // 本番と同じ場所 (既定引数が見る `WorkDirectory.facet`) に要求を置く。元から在ったものは退かせて戻す
        let manager = FileManager.default
        let root = WorkDirectory.root
        let hadRoot = WorkDirectory.directoryExists(at: root)
        let places = ["observe", "input", "params"].map { WorkDirectory.facet($0) }
        var aside: [(URL, URL)] = []
        for place in places where WorkDirectory.directoryExists(at: place) {
            let moved = root.appendingPathComponent("aside-\(UUID().uuidString)", isDirectory: true)
            try manager.moveItem(at: place, to: moved)
            aside.append((place, moved))
        }
        defer {
            for place in places { try? manager.removeItem(at: place) }
            for (place, moved) in aside { try? manager.moveItem(at: moved, to: place) }
            if !hadRoot, (try? manager.contentsOfDirectory(atPath: root.path))?.isEmpty == true {
                try? manager.removeItem(at: root)
            }
        }
        for place in places { try manager.createDirectory(at: place, withIntermediateDirectories: true) }
        try Data(#"{"id":"o1"}"#.utf8).write(to: WorkDirectory.facet("observe").appendingPathComponent("request.json"))
        try Data(#"{"id":"i1","events":[{"type":"keyDown","code":124}]}"#.utf8)
            .write(to: WorkDirectory.facet("input").appendingPathComponent("request.json"))
        try Data(#"{"id":"p1","values":[{"name":"radius","type":"float","value":7}]}"#.utf8)
            .write(to: WorkDirectory.facet("params").appendingPathComponent("request.json"))

        let player = try #require(
            ReplayPlayer.startup(environment: [StartupReads.replay.key: url.path], unset: { _ in }, reportURL: nil))
        let application = try SketchApplication(
            sketch: ReplayPlaybackTests.Playground(), gpu: RenderDevice(), render: nil, replay: player)
        let ran = run(application, fires: 60)
        #expect(ran.finished && ran.exit == nil)
        #expect(player.report?.matched == true, "\(String(describing: player.report?.firstMismatch))")
        for key in ["observe", "input", "params"] {
            let reply = WorkDirectory.facet(key).appendingPathComponent("report.json")
            #expect(!manager.fileExists(atPath: reply.path), "\(key) の要求に応えた")
        }
    }
}
