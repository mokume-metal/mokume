// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation
import MokumeTestSupport
import Testing

@testable import MokumeCore
@testable import reference_sketches

/// 実行を頭から終わりまで 1 本の記録にする ([#3570])。
///
/// 形式・頼み方・終わり方・開始の状態は GPU を要らない部分 (``ReplayRecordFormatTests``) で、記録点が実行の
/// どこに在るか (入力の束・つまみ・時刻を指定した観測・照合の値) は GPU を要する部分
/// (``ReplayRecordingRuntimeTests``) で確かめる。
///
/// [#3570]: https://github.com/mokume-metal/mokume/issues/3570
@Suite("記録の頼みと書式")
@MainActor
struct ReplayRecordFormatTests {
    private func scratch() throws -> URL {
        try TestScratch.directory("mokume-replay-record")
    }

    private func object(at url: URL) throws -> [String: Any] {
        let data = try Data(contentsOf: url)
        return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    // MARK: - 頼み

    @Test("頼みは絶対パスだけを受け、世代ごとの行き先は拡張子の前に番号を挟む")
    func theRequestTakesAnAbsolutePath() {
        #expect(ReplayRequest(destination: "/tmp/take.json")?.environmentValue == "/tmp/take.json")
        #expect(ReplayRequest(destination: "take.json") == nil, "相対の値は読む側の作業ディレクトリで別の場所になる")
        #expect(ReplayRequest(destination: "") == nil)
        #expect(ReplayRequest(destination: "/") == nil)
        #expect(ReplayRequest.generation(of: "/tmp/out/take.json", number: 2) == "/tmp/out/take-2.json")
        #expect(ReplayRequest.generation(of: "/tmp/out/take", number: 1) == "/tmp/out/take-1")
        #expect(ReplayRequest.generation(of: "/tmp/a.b/take.rec.json", number: 3) == "/tmp/a.b/take.rec-3.json")
    }

    @Test("起動で読んだ合図は環境から消し、読めない値は言って記録しない")
    func startupConsumesTheEnvironment() {
        var unset: [String] = []
        var said: [String] = []
        let request = ReplayRequest.startup(
            environment: [StartupReads.record.key: "/tmp/take.json"], unset: { unset.append($0) },
            say: { said.append($0) })
        #expect(request?.destination.path == "/tmp/take.json")
        #expect(unset == [StartupReads.record.key], "子がさらに起こす子へ継がせない")
        #expect(said.isEmpty)

        unset = []
        let relative = ReplayRequest.startup(
            environment: [StartupReads.record.key: "take.json"], unset: { unset.append($0) },
            say: { said.append($0) })
        #expect(relative == nil)
        #expect(unset == [StartupReads.record.key], "読めない値も残さない")
        #expect(said.count == 1 && said[0].contains(StartupReads.record.key), "理由を 1 度言う: \(said)")

        #expect(ReplayRequest.startup(environment: [:], unset: { _ in }, say: { _ in }) == nil, "合図が無ければ何もしない")
    }

    @Test("一覧が鍵を名乗り、読み場所は実在する")
    func theListNamesTheKey() {
        #expect(StartupReads.record.key == "MOKUME_RECORD")
        #expect(StartupReads.all.contains(StartupReads.record))
        #expect(StartupReads.record.decidedBy == .tool)
    }

    // MARK: - 記録器 (GPU なし)

    @Test("閉じ終えた記録だけが行き先に在り、書き途中は .partial で、完成の印は最後に書かれる")
    func onlyAFinishedRecordIsAtTheDestination() throws {
        let directory = try scratch()
        let destination = directory.appendingPathComponent("take.json")
        let (opened, failure) = ReplayRecorder.open(destination: destination)
        let recorder = try #require(opened, "開けなかった: \(failure ?? "")")
        let partial = directory.appendingPathComponent("take.json.partial")
        #expect(FileManager.default.fileExists(atPath: partial.path))
        #expect(!FileManager.default.fileExists(atPath: destination.path), "書き終えるまで行き先は作られない")

        recorder.noteStart(seed: 0, params: [], frameRate: 60, width: 4, height: 2)
        recorder.noteStartClock(seconds: 8, paused: true)
        recorder.beginStep()
        recorder.endStep(frame: 1, drew: true) { nil }
        // 書き途中は完成として読めない (閉じていない JSON で、完成の印も無い)
        let partway = try String(contentsOf: partial, encoding: .utf8)
        #expect(!partway.contains("\"complete\""))

        recorder.finish(last: (1, String(repeating: "a", count: 64)))
        #expect(!FileManager.default.fileExists(atPath: partial.path), ".partial は行き先へ改名される")
        let record = try object(at: destination)
        #expect(record["complete"] as? Bool == true)
        #expect(record["schemaVersion"] as? Int == 1)
        #expect(record["id"] as? String == recorder.id)
        let start = try #require(record["start"] as? [String: Any])
        #expect(start["seconds"] as? Double == 8)
        #expect(start["paused"] as? Bool == true, "止めたまま作り直した世代は止めているかが真")
        #expect(start["seed"] as? Int == 0)
        let steps = try #require(record["steps"] as? [[String: Any]])
        #expect(steps.count == 1 && steps[0]["frame"] as? Int == 1 && steps[0]["drew"] as? Bool == true)
        #expect((record["last"] as? [String: Any])?["frame"] as? Int == 1)
        #expect(recorder.isFinished)
    }

    @Test("落ちた回は .partial のまま残り、行き先は作られず、前の回の完成品も残らない")
    func aCrashedRunLeavesNoRecord() throws {
        let directory = try scratch()
        let destination = directory.appendingPathComponent("take.json")
        // 前の回が残した完成品は、今回の回が落ちたときに取り違えられないよう、開始で消える
        try Data("{\"complete\":true}".utf8).write(to: destination)
        var recorder: ReplayRecorder? = ReplayRecorder.open(destination: destination).recorder
        #expect(recorder != nil)
        #expect(!FileManager.default.fileExists(atPath: destination.path), "前の回の完成品は消す")
        recorder?.noteStart(seed: 0, params: [], frameRate: 60, width: 4, height: 2)
        recorder?.beginStep()
        recorder?.endStep(frame: 1, drew: true) { nil }
        recorder = nil  // finish を呼ばずに手放す = 終わりの経路を通らなかった
        #expect(!FileManager.default.fileExists(atPath: destination.path), "完成として読まれるものが無い")
        #expect(FileManager.default.fileExists(atPath: destination.path + ".partial"))
    }

    @Test("行き先がフォルダなら開かず、理由を返す")
    func aDirectoryIsNotADestination() throws {
        let directory = try scratch()
        let (recorder, failure) = ReplayRecorder.open(destination: directory)
        #expect(recorder == nil)
        #expect(failure?.contains("directory") == true, "理由: \(failure ?? "nil")")
    }

    @Test("回は溜めた入力・つまみ・観測をその回へ持ち込み、同じ理由の再現を保証しない印は 1 度だけ書く")
    func aStepCarriesWhatPiledUp() throws {
        let directory = try scratch()
        let destination = directory.appendingPathComponent("take.json")
        let recorder = try #require(ReplayRecorder.open(destination: destination).recorder)
        recorder.noteStart(seed: 0, params: [], frameRate: 60, width: 4, height: 2)
        recorder.noteInput(.keyDown(code: .arrowRight, characters: "", isRepeat: false))
        recorder.noteInput(.mouseMovedBy(dx: .nan, dy: 1))
        recorder.noteInput(.mouseMovedBy(dx: .infinity, dy: 1))
        recorder.noteParam("radius", .float(150))
        recorder.noteTimedObservation(2.5)
        recorder.beginStep()
        recorder.noteExposed("score", .int(3))
        recorder.endStep(frame: 1, drew: true) { nil }
        // 何も起きなかった止めた回は載らない
        recorder.beginStep()
        recorder.endStep(frame: 1, drew: false) { nil }
        // 束は畳まない: 同じフレーム番号の 2 つの束はそれぞれの回に載る
        recorder.noteInput(.scrolled(dx: 0, dy: 5))
        recorder.beginStep()
        recorder.endStep(frame: 1, drew: false) { nil }
        recorder.noteInput(.scrolled(dx: 0, dy: 3))
        recorder.beginStep()
        recorder.endStep(frame: 1, drew: false) { nil }
        recorder.finish(last: nil)

        let record = try object(at: destination)
        let steps = try #require(record["steps"] as? [[String: Any]])
        try #require(steps.map { $0["step"] as? Int } == [0, 2, 3], "止めた何も無い回(1)は番号の欠けで表す")
        let first = steps[0]
        let inputs = try #require(first["inputs"] as? [[String: Any]])
        #expect(inputs.map { $0["type"] as? String } == ["keyDown", "mouseMovedBy", "mouseMovedBy"])
        #expect(inputs.first?["code"] as? Int == 124)
        #expect((first["params"] as? [[String: Any]])?.first?["name"] as? String == "radius")
        #expect((first["observe"] as? [String: Any])?["time"] as? Double == 2.5)
        #expect(((first["expose"] as? [String: Any])?["score"] as? [String: Any])?["value"] as? Int == 3)
        #expect(steps[1]["frame"] as? Int == 1 && steps[2]["frame"] as? Int == 1, "同じフレーム番号の束が並ぶ")
        #expect(((steps[1]["inputs"] as? [[String: Any]])?.first?["dy"] as? Double) == 5)
        #expect(((steps[2]["inputs"] as? [[String: Any]])?.first?["dy"] as? Double) == 3)
        let notes = try #require(record["unreproducible"] as? [[String: Any]])
        #expect(notes.count == 1, "NaN と無限は同じ理由で、1 度だけ: \(notes)")
        #expect(notes.first?["reason"] as? String == ReplayRecorder.Reason.nonFiniteInput)
        #expect(record["last"] == nil, "1 枚も描いていなければ最後の絵は無い")
    }

    @Test("画素のハッシュは、フレーム番号が 60 の倍数の描いた回にだけ付く")
    func theHashIsTakenEverySixtyFrames() throws {
        let directory = try scratch()
        let destination = directory.appendingPathComponent("take.json")
        let recorder = try #require(ReplayRecorder.open(destination: destination).recorder)
        recorder.noteStart(seed: 0, params: [], frameRate: 60, width: 4, height: 2)
        var asked: [Int] = []
        for frame in 1...120 {
            recorder.beginStep()
            recorder.endStep(frame: frame, drew: true) {
                asked.append(frame)
                return "h\(frame)"
            }
        }
        recorder.finish(last: nil)
        #expect(asked == [60, 120])
        let steps = try #require(try object(at: destination)["steps"] as? [[String: Any]])
        let hashed = steps.compactMap { $0["pixelHash"] != nil ? $0["frame"] as? Int : nil }
        #expect(hashed == [60, 120])
    }

    @Test("有限でない数を持つ出来事を見分ける")
    func nonFiniteEventsAreRecognised() {
        #expect(InputEvent.mouseMoved(x: .nan, y: 0).hasNonFiniteNumber)
        #expect(InputEvent.mouseDown(x: 0, y: .infinity, button: .left).hasNonFiniteNumber)
        #expect(InputEvent.scrolled(dx: 0, dy: -.infinity).hasNonFiniteNumber)
        #expect(InputEvent.pinched(amount: .nan).hasNonFiniteNumber)
        #expect(!InputEvent.mouseMovedBy(dx: 3e38, dy: 3e38).hasNonFiniteNumber, "極端でも有限なら生の形で残せる")
        #expect(!InputEvent.keyUp(code: .a).hasNonFiniteNumber)
    }
}

/// 記録点が実行のどこに在るか。GPU を要する。**記録を頼まない実行が変わらない**ことも、同じ組み方で見る。
@Suite(
    "実行の記録",
    .serialized,
    .enabled(
        if: RenderDevice.isAvailable,
        "この世代のコマンド構造に対応した GPU が無い実行環境ではスキップする")
)
@MainActor
struct ReplayRecordingRuntimeTests {
    /// つまみ 1 つで状態が変わり、押されたキーとフレーム番号を `expose` する検査用のスケッチ。
    final class Playground: Sketch {
        @Param(0...300) var radius: Double = 100
        var settings: SketchSettings { SketchSettings(width: 16, height: 16, frameRate: 60) }
        func draw() {
            background(Float(radius / 300))
            expose("frame", frameCount)
            expose("radius", radius)
            expose("right", keyboard.isPressed(.arrowRight))
        }
    }

    /// 止めて、入力の束ごとに描き直す検査用のスケッチ。
    final class Stopper: Sketch {
        var scrolled: [Float] = []
        var settings: SketchSettings { SketchSettings(width: 16, height: 16, frameRate: 60) }
        func setup() { noLoop() }
        func draw() {
            background(0.2)
            expose("scroll", scrollY)
        }
        func mouseWheel(deltaX: Float, deltaY: Float) { redraw() }
    }

    private func scratch() throws -> URL { try TestScratch.directory("mokume-replay-runtime") }

    private func makeRuntime(
        _ sketch: any Sketch, to destination: URL, clock: Clock = .frameIndex(frameRate: 60),
        observer: FrameObserver? = nil, handover: ClockHandover? = nil
    ) throws -> SketchRuntime {
        let runtime: SketchRuntime
        if let handover {
            runtime = try SketchRuntime(
                sketch: sketch, gpu: RenderDevice(), clock: clock, now: { 500 }, persistsParams: false,
                handover: handover)
        } else if let observer {
            runtime = try SketchRuntime(
                sketch: sketch, gpu: RenderDevice(), clock: clock, now: { 0 }, observer: observer)
        } else {
            runtime = try SketchRuntime(
                sketch: sketch, gpu: RenderDevice(), clock: clock, persistsParams: false)
        }
        let request = try #require(ReplayRequest(destination: destination.path))
        runtime.startRecording(request)
        return runtime
    }

    private func read(_ url: URL) throws -> [String: Any] {
        let data = try Data(contentsOf: url)
        return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    @Test("キーを送った回のフレーム番号に wireLine の 1 行で並び、毎フレームの expose と 60 フレームごと・最後の画素のハッシュがある")
    func inputsAndCheckValuesLandOnTheirFrames() throws {
        let directory = try scratch()
        let destination = directory.appendingPathComponent("take.json")
        let runtime = try makeRuntime(Playground(), to: destination)
        #expect(runtime.recordingStatus?.frame == 0, "記録中は識別子といまのフレーム番号が読める")
        let id = try #require(runtime.recordingStatus?.id)
        for frame in 1...130 {
            if frame == 10 { runtime.input.enqueue(.keyDown(code: .arrowRight, characters: "", isRepeat: false)) }
            if frame == 40 { runtime.input.enqueue(.keyUp(code: .arrowRight)) }
            try runtime.advance()
        }
        #expect(runtime.recordingStatus?.frame == 130)
        runtime.closePlugins()
        #expect(runtime.recordingStatus == nil, "閉じ終えた記録は記録中ではない")

        let record = try read(destination)
        #expect(record["id"] as? String == id)
        #expect(record["complete"] as? Bool == true)
        let steps = try #require(record["steps"] as? [[String: Any]])
        try #require(steps.count == 130)
        func step(_ frame: Int) -> [String: Any] { steps[frame - 1] }
        func exposed(_ frame: Int, _ name: String) -> Any? {
            ((step(frame)["expose"] as? [String: Any])?[name] as? [String: Any])?["value"]
        }
        let down = try #require(step(10)["inputs"] as? [[String: Any]])
        #expect(down.count == 1 && down[0]["type"] as? String == "keyDown" && down[0]["code"] as? Int == 124)
        let up = try #require(step(40)["inputs"] as? [[String: Any]])
        #expect(up.count == 1 && up[0]["type"] as? String == "keyUp")
        #expect(steps.filter { $0["inputs"] != nil }.count == 2, "送っていない回に入力は載らない")
        for (index, entry) in steps.enumerated() {
            #expect(entry["frame"] as? Int == index + 1)
            let exposed = try #require(entry["expose"] as? [String: Any], "毎フレームの expose がある")
            #expect(Set(exposed.keys) == ["frame", "radius", "right"])
        }
        #expect(exposed(9, "right") as? Bool == false && exposed(10, "right") as? Bool == true)
        #expect(exposed(39, "right") as? Bool == true && exposed(40, "right") as? Bool == false)
        let hashed = steps.compactMap { $0["pixelHash"] != nil ? $0["frame"] as? Int : nil }
        #expect(hashed == [60, 120], "60 フレームごと")
        let last = try #require(record["last"] as? [String: Any])
        #expect(last["frame"] as? Int == 130)
        #expect((last["pixelHash"] as? String)?.count == 64)
        let start = try #require(record["start"] as? [String: Any])
        #expect(start["seed"] as? Int == 0 && start["seconds"] as? Double == 0 && start["paused"] as? Bool == false)
        let params = try #require(start["params"] as? [[String: Any]])
        #expect(params.first?["name"] as? String == "radius" && params.first?["value"] as? Double == 100)
    }

    @Test("作例 BricksAndBall を 3600 フレーム記録する: → を 30 フレーム押す操作が送った回に並び、4 値と画素のハッシュが揃う")
    func bricksAndBallIsRecordedFromTheFirstFrame() throws {
        let directory = try scratch()
        let destination = directory.appendingPathComponent("bricks.json")
        let runtime = try makeRuntime(BricksAndBall(), to: destination)
        for frame in 1...3600 {
            if frame == 100 { runtime.input.enqueue(.keyDown(code: .arrowRight, characters: "", isRepeat: false)) }
            if frame == 130 { runtime.input.enqueue(.keyUp(code: .arrowRight)) }
            try runtime.advance()
        }
        runtime.closePlugins()

        let record = try read(destination)
        #expect(record["complete"] as? Bool == true)
        let steps = try #require(record["steps"] as? [[String: Any]])
        try #require(steps.count == 3600)
        let withInputs = steps.filter { $0["inputs"] != nil }
        try #require(withInputs.map { $0["frame"] as? Int } == [100, 130], "送った回のフレーム番号に並ぶ")
        let down = try #require(withInputs[0]["inputs"] as? [[String: Any]])
        #expect(down.map { $0["type"] as? String } == ["keyDown"] && down[0]["code"] as? Int == 124)
        let up = try #require(withInputs[1]["inputs"] as? [[String: Any]])
        #expect(up.map { $0["type"] as? String } == ["keyUp"])
        for entry in steps {
            let exposed = try #require(entry["expose"] as? [String: Any])
            #expect(Set(exposed.keys) == ["score", "paddleX", "ballY", "balls"], "毎フレームの 4 値")
        }
        func paddle(_ frame: Int) -> Double? {
            ((steps[frame - 1]["expose"] as? [String: Any])?["paddleX"] as? [String: Any])?["value"] as? Double
        }
        let moved = try #require(paddle(129)) - #require(paddle(99))
        #expect(moved == 150, "押している 30 枚で 5 ずつ進む: \(moved)")
        let hashed = steps.compactMap { $0["pixelHash"] != nil ? $0["frame"] as? Int : nil }
        #expect(hashed == Array(stride(from: 60, through: 3600, by: 60)), "60 フレームごと")
        let last = try #require(record["last"] as? [String: Any])
        #expect(last["frame"] as? Int == 3600 && (last["pixelHash"] as? String)?.count == 64)
        #expect(
            last["pixelHash"] as? String == steps[3599]["pixelHash"] as? String, "最後の枚が 60 の倍数なら、同じ絵の同じハッシュ")
        #expect(record["unreproducible"] == nil, "鳴らすだけの合成音は保証の内")
    }

    @Test("つまみの書き込みと時刻を指定した観測が、起きた回のフレーム番号に載る。作者の代入は載らない")
    func knobWritesAndTimedObservationsLandOnTheirFrames() throws {
        let directory = try scratch()
        let destination = directory.appendingPathComponent("take.json")
        let facet = directory.appendingPathComponent("observe", isDirectory: true)
        try FileManager.default.createDirectory(at: facet, withIntermediateDirectories: true)
        let sketch = Playground()
        let runtime = try makeRuntime(sketch, to: destination, observer: FrameObserver(directory: facet))
        for frame in 1...20 {
            if frame == 5 {
                // 窓のつまみも区画も `ParamBox.write` を通る。範囲の外は収めた値が載る
                #expect(runtime.paramRegistry.write(.float(400), to: "radius") != nil)
            }
            if frame == 12 {
                try AtomicFile.write(
                    Data(#"{"id":"t1","time":2.5}"#.utf8), to: facet.appendingPathComponent("request.json"))
            }
            if frame == 15 { sketch.radius = 7 }  // 作者の代入
            try runtime.advance()
        }
        runtime.closePlugins()

        let record = try read(destination)
        let steps = try #require(record["steps"] as? [[String: Any]])
        let written = steps.filter { $0["params"] != nil }
        try #require(written.count == 1, "作者の代入(frame 15)は載らない: \(written)")
        #expect(written[0]["frame"] as? Int == 5)
        try #require(written.count == 1)
        let write = try #require((written[0]["params"] as? [[String: Any]])?.first)
        #expect(write["name"] as? String == "radius" && write["value"] as? Double == 300, "収めた後の値")
        let observed = steps.filter { $0["observe"] != nil }
        try #require(observed.count == 1)
        #expect((observed[0]["observe"] as? [String: Any])?["time"] as? Double == 2.5)
        #expect(observed[0]["frame"] as? Int == 12)
    }

    /// 作者の時計の秒を `expose` する検査用のスケッチ。
    final class Timed: Sketch {
        var settings: SketchSettings { SketchSettings(width: 16, height: 16, frameRate: 60) }
        func draw() {
            background(0.1)
            expose("time", time)
        }
    }

    private func handover(_ snapshot: ClockHandover.Snapshot) -> ClockHandover {
        ClockHandover(
            read: { .found(snapshot) }, write: { _ in }, isAlive: { _ in true }, warn: { _ in })
    }

    @Test("watch --keep-time で作り直した世代は、開始の秒が 0 でなく、止めたまま作り直した世代は止めているかが真")
    func aKeptClockIsTheStartOfTheRecord() throws {
        // 動いていた前の世代: 8 秒で、実時間 1 秒で 1 秒進む。最初の枚はその少し先から始まる
        let running = ClockHandover.Snapshot(
            seconds: 8, isHeld: false, isStill: false, rate: 1, at: 490, writer: 1, generation: 1)
        let directory = try scratch()
        let movingFile = directory.appendingPathComponent("moving.json")
        let moving = try makeRuntime(Timed(), to: movingFile, handover: handover(running))
        for _ in 0..<3 { try moving.advance() }
        moving.closePlugins()
        let movingRecord = try read(movingFile)
        let movingStart = try #require(movingRecord["start"] as? [String: Any])
        let seconds = try #require(movingStart["seconds"] as? Double)
        #expect(seconds > 8 && movingStart["paused"] as? Bool == false, "0 でない秒から始まった: \(seconds)")
        // 記録の開始の秒は、最初の枚が実際に使った値 (流すときに setup() の前へ当てると、同じ秒から始まる)
        let steps = try #require(movingRecord["steps"] as? [[String: Any]])
        let first = try #require(
            ((steps.first?["expose"] as? [String: Any])?["time"] as? [String: Any])?["value"] as? Double)
        #expect(abs(first - seconds) < 1e-4, "最初の枚の time \(first) と開始の秒 \(seconds)")

        // 止めたまま作り直した世代
        let held = ClockHandover.Snapshot(
            seconds: 8, isHeld: true, isStill: false, rate: 1, at: 490, writer: 1, generation: 1)
        let heldFile = directory.appendingPathComponent("held.json")
        let paused = try makeRuntime(Timed(), to: heldFile, handover: handover(held))
        for _ in 0..<3 { try paused.advance() }
        paused.closePlugins()
        let pausedStart = try #require(try read(heldFile)["start"] as? [String: Any])
        #expect(pausedStart["seconds"] as? Double == 8 && pausedStart["paused"] as? Bool == true)

        // 引き継ぎの無い実行は 0 秒から
        let plainFile = directory.appendingPathComponent("plain.json")
        let plain = try makeRuntime(Timed(), to: plainFile)
        try plain.advance()
        plain.closePlugins()
        let plainStart = try #require(try read(plainFile)["start"] as? [String: Any])
        #expect(plainStart["seconds"] as? Double == 0 && plainStart["paused"] as? Bool == false)
    }

    @Test("開始の状態に、保存から戻した @Param の値が入り、戻す書き込み自体は束に載らない")
    func theStartHoldsTheRestoredParams() throws {
        let directory = try scratch()
        let destination = directory.appendingPathComponent("take.json")
        let saved = directory.appendingPathComponent("params.json")
        try Data(#"{"values":[{"name":"radius","type":"float","value":250}]}"#.utf8).write(to: saved)
        let sketch = Playground()
        let store = ParamStore(registry: ParamRegistry(of: sketch), at: saved, warn: { _ in })
        let runtime = try SketchRuntime(
            sketch: sketch, gpu: RenderDevice(), clock: .frameIndex(frameRate: 60), now: { 0 },
            observer: nil, paramStore: store)
        runtime.startRecording(try #require(ReplayRequest(destination: destination.path)))
        try runtime.advance()
        runtime.closePlugins()
        let record = try read(destination)
        let start = try #require(record["start"] as? [String: Any])
        let params = try #require(start["params"] as? [[String: Any]])
        #expect(params.map { $0["name"] as? String } == ["radius"], "\(params)")
        #expect(params.first?["value"] as? Double == 250, "保存から戻した値が開始の値")
        let steps = try #require(record["steps"] as? [[String: Any]])
        #expect(steps.allSatisfy { $0["params"] == nil }, "戻す書き込みは束に載らない")
        let exposed = (steps.first?["expose"] as? [String: Any])?["radius"] as? [String: Any]
        #expect(exposed?["value"] as? Double == 250, "最初の枚も戻した値で描く")
    }

    @Test("止めた作品は回ごとに束を配り、同じフレーム番号の束を畳まずに載せる")
    func aStoppedSketchKeepsOneBundlePerAdvance() throws {
        let directory = try scratch()
        let destination = directory.appendingPathComponent("take.json")
        let sketch = Stopper()
        let runtime = try makeRuntime(sketch, to: destination)
        try runtime.advance()  // 最初の 1 枚 (setup() が noLoop() を呼んでも描く)
        runtime.input.enqueue(.scrolled(dx: 0, dy: 5))
        try runtime.advance()
        runtime.input.enqueue(.scrolled(dx: 0, dy: 3))
        try runtime.advance()
        runtime.closePlugins()

        let steps = try #require(try read(destination)["steps"] as? [[String: Any]])
        let scrolls = steps.compactMap { ($0["inputs"] as? [[String: Any]])?.first?["dy"] as? Double }
        #expect(scrolls == [5, 3], "束は回ごとに別: \(steps)")
        let frames = steps.filter { $0["inputs"] != nil }.map { $0["frame"] as? Int }
        #expect(frames.count == 2)
        // 最後に描いた枚の scrollY は 3 (8 ではない) — 束を畳むと量が変わる
        let lastDrew = steps.last { $0["drew"] as? Bool == true }
        let scroll = ((lastDrew?["expose"] as? [String: Any])?["scroll"] as? [String: Any])?["value"] as? Double
        #expect(scroll == 3)
    }

    @Test("実時間の時計なら記録を始めず、ファイルは作らず、走り続ける")
    func aWallClockSketchIsNotRecorded() throws {
        let directory = try scratch()
        let destination = directory.appendingPathComponent("take.json")
        let runtime = try makeRuntime(Playground(), to: destination, clock: .wallClock)
        #expect(runtime.replay == nil && runtime.recordingStatus == nil)
        for _ in 0..<3 { try runtime.advance() }
        runtime.closePlugins()
        #expect(!FileManager.default.fileExists(atPath: destination.path))
        #expect(!FileManager.default.fileExists(atPath: destination.path + ".partial"))
    }

    @Test("記録を頼まない実行は、記録の係も入力の聴き手も持たない")
    func withoutARequestNothingIsHooked() throws {
        let runtime = try SketchRuntime(
            sketch: Playground(), gpu: RenderDevice(), clock: .frameIndex(frameRate: 60), persistsParams: false)
        #expect(runtime.replay == nil && runtime.input.enqueueObserver == nil)
        for knob in runtime.paramRegistry.knobs { knob.observeWrites(nil) }  // 聴き手が無くても外せる
        #expect(runtime.recordingStatus == nil)
        try runtime.advance()
    }

    @Test("非有限の入力を enqueue すると、記録に理由つきで書く。極端な有限の値は生の形で 2 件残る")
    func nonFiniteAndExtremeInputs() throws {
        let directory = try scratch()
        let destination = directory.appendingPathComponent("take.json")
        let runtime = try makeRuntime(Playground(), to: destination)
        runtime.input.enqueue(.mouseMovedBy(dx: 3e38, dy: 0))
        runtime.input.enqueue(.mouseMovedBy(dx: 3e38, dy: 0))
        try runtime.advance()
        #expect(runtime.input.warnings.hasWarned(.nonFiniteEvent), "和が溢れて 2 件目を捨てる警告は記録時に出る")
        runtime.input.enqueue(.mouseMoved(x: .nan, y: 1))
        try runtime.advance()
        runtime.closePlugins()

        let record = try read(destination)
        let steps = try #require(record["steps"] as? [[String: Any]])
        try #require(steps.count >= 1)
        let first = try #require(steps[0]["inputs"] as? [[String: Any]])
        #expect(first.count == 2, "2 件とも生の形で残る")
        #expect(first.allSatisfy { abs(($0["dx"] as? Double ?? 0) - 3e38) < 1e31 })
        #expect(record["unreproducible"] != nil, "NaN は理由つき")
        let notes = try #require(record["unreproducible"] as? [[String: Any]])
        #expect(notes.map { $0["reason"] as? String } == [ReplayRecorder.Reason.nonFiniteInput])
        #expect(notes.first?["step"] as? Int == 1, "NaN を入れた回")
    }

    @Test("途中で落ちた回は完成の印が無い形で残る")
    func aRunThatEndsWithoutClosingIsNotComplete() throws {
        let directory = try scratch()
        let destination = directory.appendingPathComponent("take.json")
        var runtime: SketchRuntime? = try makeRuntime(Playground(), to: destination)
        for _ in 0..<70 { try runtime?.advance() }
        runtime = nil  // 終わりの経路 (closePlugins) を通らずに手放す
        #expect(!FileManager.default.fileExists(atPath: destination.path), "完成として読まれるものが無い")
        let partial = try String(contentsOfFile: destination.path + ".partial", encoding: .utf8)
        #expect(!partial.contains("\"complete\""))
    }
}
