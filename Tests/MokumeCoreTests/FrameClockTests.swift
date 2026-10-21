// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation
import Testing

@testable import MokumeCore

/// 窓でもフレームの時計で回せる設定 (`SketchSettings(clock: .frames)`) と、処理落ちを見えるようにする
/// 仕組み ([#2601](https://github.com/mokume-metal/mokume/issues/2601))。
///
/// 時計 (`FrameTiming`) と入力の合流点 (`InputState`) を直に回すので、GPU を要さない。
@Suite("フレームの時計")
@MainActor
struct FrameClockTests {
    private let step = 1.0 / 60

    // MARK: - 窓の時計を設定から選ぶ (完了条件 1)

    @Test("窓の経路は、設定が .frames なら宣言の fps のフレーム番号、既定は実時間")
    func theWindowClockFollowsTheSetting() {
        #expect(Clock.launching(.frames, frameRate: 60) == .frameIndex(frameRate: 60))
        #expect(Clock.launching(.frames, frameRate: 30) == .frameIndex(frameRate: 30))
        #expect(Clock.launching(.wallClock, frameRate: 60) == .wallClock)
        #expect(SketchSettings().clock == .wallClock, "既定は変えない")
    }

    /// **完了条件 1 の本体。** 1 フレームに 30 ms かかる時計を差す。
    @Test("フレームの時計では 1 枚に 30 ms かかっても time は 1/60 ずつ、実時間の時計は 30 ms ずつ進む")
    func aSlowFrameAdvancesTheFrameClockByOneStep() {
        var now = 100.0
        let frames = FrameTiming(clock: .frameIndex(frameRate: 60), frameRate: 60, now: { now })
        let wall = FrameTiming(clock: .wallClock, frameRate: 60, now: { now })
        var seen: [(frames: (Float, Float, Int), wall: (Float, Float))] = []
        for _ in 0..<6 {
            now += 0.030
            frames.advance()
            wall.advance()
            seen.append(
                ((frames.time, frames.deltaTime, frames.frameCount), (wall.time, wall.deltaTime)))
        }
        for (index, row) in seen.enumerated() {
            #expect(row.frames.2 == index + 1)
            #expect(row.frames.0 == Float(Double(index) / 60), "\(index + 1) 枚目の time")
            #expect(row.frames.1 == Float(step), "\(index + 1) 枚目の deltaTime")
        }
        // 実時間の時計は最初の枚を起点に 30 ms ずつ進み、2 枚目からの経過は約 0.03
        for (index, row) in seen.enumerated().dropFirst() {
            #expect(abs(Double(row.wall.0) - Double(index) * 0.030) < 1e-4)
            #expect(abs(Double(row.wall.1) - 0.030) < 1e-4)
        }
    }

    // MARK: - 同じ入力から同じ状態 (完了条件 2)

    /// 跳ねる球の状態。`deltaTime` で積むので、刻みが揺れれば状態も揺れる。
    private struct Ball: Equatable {
        var y: Float = 200
        var vy: Float = 0
        var jumps = 0
    }

    /// フレーム番号つきの入力の列を流し、毎フレームの状態を返す。ランタイムと同じ順で回す —
    /// 時刻を進め、頭で入力を流し込み、`draw()` に当たる計算をし、終わりで端を消す。
    private func play(
        _ clock: Clock, inputs: [Int: [InputEvent]], frames: Int, jitter: @escaping (Int) -> Double
    ) -> [Ball] {
        var now = 0.0
        var frame = 0
        let timing = FrameTiming(clock: clock, frameRate: 60, now: { now })
        let input = InputState()
        var ball = Ball()
        var states: [Ball] = []
        for _ in 0..<frames {
            frame += 1
            now += jitter(frame)
            timing.advance()
            for event in inputs[timing.frameCount] ?? [] { input.enqueue(event) }
            input.beginFrame()
            let keyboard = Keyboard(state: input)
            let dt = timing.deltaTime
            if keyboard.justPressed(.space) {
                ball.vy = -480
                ball.jumps += 1
            }
            ball.vy += 1440 * dt
            ball.y += ball.vy * dt
            states.append(ball)
            input.endFrame()
        }
        return states
    }

    private static let space = InputEvent.keyDown(code: .space, characters: " ", isRepeat: false)
    private static let inputs: [Int: [InputEvent]] = [
        3: [space], 4: [.keyUp(code: .space)],
        20: [space, .keyUp(code: .space)],
        41: [space], 55: [.keyUp(code: .space)],
    ]

    @Test("同じ入力の列を揺れ方の違う実時間で 2 回流すと、フレームの時計では毎フレームの状態が一致する")
    func theSameInputsReachTheSameStateOnTheFrameClock() {
        let steady = play(.frameIndex(frameRate: 60), inputs: Self.inputs, frames: 80) { _ in 1.0 / 60 }
        let jittery = play(.frameIndex(frameRate: 60), inputs: Self.inputs, frames: 80) { frame in
            frame % 7 == 0 ? 0.045 : 0.011 + Double(frame % 3) * 0.004
        }
        #expect(steady.count == 80)
        #expect(steady.last?.jumps == 3)
        for (index, pair) in zip(steady, jittery).enumerated() {
            #expect(pair.0 == pair.1, "\(index + 1) フレーム目の後で食い違った")
        }
    }

    /// 陰性対照: 実時間の時計では、同じ入力でも刻み方で状態が割れる (検査が空振りしていない)。
    @Test("陰性対照: 実時間の時計では、揺れ方が違えば状態が食い違う")
    func theWallClockDiverges() {
        let steady = play(.wallClock, inputs: Self.inputs, frames: 80) { _ in 1.0 / 60 }
        let jittery = play(.wallClock, inputs: Self.inputs, frames: 80) { frame in
            frame % 7 == 0 ? 0.045 : 0.011 + Double(frame % 3) * 0.004
        }
        #expect(steady.last?.jumps == jittery.last?.jumps, "入力の届き方は時計によらない")
        #expect(steady != jittery)
    }

    // MARK: - 止める口の表 (完了条件 5)

    /// 実時間を大きく揺らした時計。フレームの時計はこれを読まないことを、各行で確かめる。
    private func framesClock() -> (FrameTiming, (Double) -> Void) {
        var now = 500.0
        let timing = FrameTiming(clock: .frameIndex(frameRate: 60), frameRate: 60, now: { now })
        return (timing, { now += $0 })
    }

    @Test("何もしない: 毎フレーム +1・time は進む・deltaTime は 1/fps")
    func nothingAdvancesByOneStep() {
        let (timing, pass) = framesClock()
        for frame in 1...5 {
            pass(Double(frame) * 0.013)
            timing.advance()
            #expect(timing.frameCount == frame)
            #expect(timing.time == Float(Double(frame - 1) / 60))
            #expect(timing.deltaTime == Float(step))
        }
    }

    @Test("pauseTime() の間: +1・time は止まる・deltaTime は 0")
    func pausingHoldsTimeButCountsFrames() {
        let (timing, pass) = framesClock()
        for _ in 0..<3 { pass(0.02); timing.advance() }
        let held = timing.time
        timing.pauseTime()
        for frame in 4...7 {
            pass(0.05)
            timing.advance()
            #expect(timing.frameCount == frame)
            #expect(timing.time == held)
            #expect(timing.deltaTime == 0)
        }
    }

    @Test("jumpTime(t) の枚: +1・t へ跳ぶ・deltaTime は 0。次の枚から 1/fps で進む")
    func jumpingLandsWithZeroStep() {
        let (timing, pass) = framesClock()
        for _ in 0..<3 { pass(0.02); timing.advance() }
        timing.jumpTime(4)
        pass(0.3)
        timing.advance()
        #expect(timing.frameCount == 4)
        #expect(timing.time == 4)
        #expect(timing.deltaTime == 0)
        pass(0.3)
        timing.advance()
        #expect(abs(Double(timing.time) - (4 + step)) < 1e-6)
        #expect(timing.deltaTime == Float(step))
    }

    @Test("時刻を指定した観測の 1 枚: +1・その枚だけ指定の秒・deltaTime は 0。次の枚は元の時計")
    func anObservedFrameShowsTheRequestedSecondOnly() {
        let (timing, pass) = framesClock()
        for _ in 0..<3 { pass(0.02); timing.advance() }
        timing.advance(at: 9)
        #expect(timing.frameCount == 4)
        #expect(timing.time == 9)
        #expect(timing.deltaTime == 0)
        timing.advance()
        #expect(timing.time == Float(4.0 / 60))
        #expect(timing.deltaTime == Float(step))
    }

    /// `noLoop()` の間と外からの停止はランタイムが `advance()` を呼ばない。止めていた長さ (実時間) は、
    /// 再開した枚 (`loop()` / `redraw()` は ``FrameTiming/stepOneFrameNext()``、外からの停止は
    /// ``FrameTiming/resync()`` を通る) に乗らない。
    @Test("noLoop()・外からの停止の間は止まり、redraw()・再開の枚は 1/fps だけ進む")
    func stoppingAndRedrawingAdvanceByOneStep() {
        let (timing, pass) = framesClock()
        for _ in 0..<3 { pass(0.02); timing.advance() }
        // noLoop() の間: 呼ばれない。実時間だけが 2 秒流れる
        pass(2)
        #expect(timing.frameCount == 3)
        // redraw() の 1 枚
        timing.stepOneFrameNext()
        timing.advance()
        #expect(timing.frameCount == 4)
        #expect(timing.time == Float(3.0 / 60))
        #expect(timing.deltaTime == Float(step))
        // 外からの停止 (watch・MCP) の後の再開: 5 秒止まっていても 1/fps
        pass(5)
        timing.resync()
        timing.advance()
        #expect(timing.frameCount == 5)
        #expect(timing.time == Float(4.0 / 60))
        #expect(timing.deltaTime == Float(step))
    }

    // MARK: - 処理落ちを見えるようにする (完了条件 3)

    @Test("1 フレームに 30 ms かかると予算超過が 1 増え、その番号がいちばん重いフレームになる")
    func aThirtyMillisecondFrameIsCounted() {
        var budget = FrameBudget(frameRate: 60)
        #expect(budget.overBudgetFrames == 0)
        #expect(budget.heaviest == nil)
        budget.record(frame: 1, seconds: 0.004)
        budget.record(frame: 2, seconds: 0.010)
        #expect(budget.overBudgetFrames == 0)
        #expect(budget.heaviest?.frame == 2)
        budget.record(frame: 3, seconds: 0.030)
        budget.record(frame: 4, seconds: 0.005)
        #expect(budget.overBudgetFrames == 1)
        #expect(budget.heaviest == FrameBudget.Heaviest(frame: 3, seconds: 0.030))
    }

    @Test("予算ちょうどは越えていない。同じ長さなら先のフレームが残る")
    func theBudgetItselfIsNotOver() {
        var budget = FrameBudget(frameRate: 60)
        budget.record(frame: 1, seconds: 1.0 / 60)
        #expect(budget.overBudgetFrames == 0)
        budget.record(frame: 2, seconds: 0.020)
        budget.record(frame: 3, seconds: 0.020)
        #expect(budget.overBudgetFrames == 2)
        #expect(budget.heaviest?.frame == 2)
    }

    @Test("観測の重さに、予算を越えた数といちばん重いフレームが載る")
    func theRuntimeLoadCarriesTheBudget() throws {
        var budget = FrameBudget(frameRate: 60)
        let fresh = RuntimeLoad.sample(tempo: FrameTempo(), budget: budget, now: 0)
        #expect(fresh.overBudgetFrames == 0)
        #expect(fresh.heaviestFrame == nil)
        budget.record(frame: 7, seconds: 0.030)
        let load = RuntimeLoad.sample(tempo: FrameTempo(), budget: budget, now: 0)
        #expect(load.overBudgetFrames == 1)
        #expect(load.heaviestFrame?.frame == 7)
        #expect(abs((load.heaviestFrame?.ms ?? 0) - 30) < 1e-9)
        // 鍵の綴りは Schemas/observe-report.schema.json と同じ
        let json = try #require(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(load)) as? [String: Any])
        #expect(json["overBudgetFrames"] as? Int == 1)
        let heaviest = try #require(json["heaviestFrame"] as? [String: Any])
        #expect(heaviest["frame"] as? Int == 7)
        let freshJSON = try #require(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(fresh)) as? [String: Any])
        #expect(freshJSON["heaviestFrame"] == nil, "測る前は鍵ごと省く")
    }

    // MARK: - draw() の中の同期の読み込み (完了条件 4)

    @Test("draw() の中で何度呼んでも、口ごとに 1 度だけ知らせる")
    func aLoadInsideDrawIsNoticedOnce() {
        let loads = BlockingLoads()
        for _ in 0..<3 {
            loads.isDrawing = true
            loads.notice("loadImage(_:)", instead: "requestImage(_:)")
            loads.isDrawing = false
        }
        let message = loads.message(for: "loadImage(_:)")
        #expect(message == BlockingLoads.notice("loadImage(_:)", instead: "requestImage(_:)"))
        #expect(message?.contains("setup()") == true)
        #expect(message?.contains("requestImage(_:)") == true)
        #expect(loads.message(for: "loadModel(_:normalize:)") == nil, "口ごとに数える")
    }

    @Test("draw() の外 (setup()・入力のコールバック) では知らせない")
    func aLoadOutsideDrawIsQuiet() {
        let loads = BlockingLoads()
        loads.notice("loadImage(_:)", instead: "requestImage(_:)")
        #expect(loads.message(for: "loadImage(_:)") == nil)
    }

    @Test("待たずに読む口が無ければ、setup() だけを案内する")
    func aLoadWithoutARequestPointsAtSetupOnly() {
        let text = BlockingLoads.notice("loadSound(_:)", instead: nil)
        #expect(text.contains("setup()"))
        #expect(!text.contains("Task"))
    }

    // MARK: - 音を鳴らすか

    @Test("音を数で進めるのは、フレームの時計で画面へ出していないときだけ")
    func soundIsPacedByFramesOnlyOffScreen() {
        #expect(Clock.frameIndex(frameRate: 30).soundFrameRate(onScreen: false) == 30)
        #expect(Clock.frameIndex(frameRate: 60).soundFrameRate(onScreen: true) == nil, "フレームの時計の窓は鳴らす")
        #expect(Clock.wallClock.soundFrameRate(onScreen: true) == nil)
        #expect(Clock.wallClock.soundFrameRate(onScreen: false) == nil)
    }
}

/// フレームの時計を、実際のスケッチと窓の経路で回す (#2601)。走っているスケッチの中で回すので GPU を要する。
@Suite(
    "フレームの時計 (スケッチから)",
    .serialized,
    .enabled(
        if: RenderDevice.isAvailable,
        "この世代のコマンド構造に対応した GPU が無い実行環境ではスキップする")
)
@MainActor
struct SketchFrameClockTests {
    final class Probe: Sketch {
        var settings = SketchSettings(width: 8, height: 4)
        var onSetup: (Probe) -> Void = { _ in }
        var onDraw: (Probe) -> Void = { _ in }
        init() {}
        func setup() { onSetup(self) }
        func draw() {
            background(0)
            onDraw(self)
        }
    }

    @Test("設定が .frames なら、窓の経路は宣言の fps のフレーム番号の時計で、画面へ出す扱いになる")
    func theWindowPathHonoursTheSetting() throws {
        let sketch = Probe()
        sketch.settings = SketchSettings(width: 8, height: 4, frameRate: 30, clock: .frames)
        let application = try SketchApplication(sketch: sketch, gpu: RenderDevice(), render: nil)
        defer { application.willTerminate() }
        #expect(application.clock == .frameIndex(frameRate: 30))
        #expect(application.isOnScreen)
    }

    @Test(
        "書き出しの頼みがあれば、設定が .frames でも頼みの刻みで、画面へ出さない扱い",
        .enabled(if: MovieFile.isAvailable, "この機械には ProRes 4444 の符号化器が無い"))
    func aRenderRequestWins() throws {
        let sketch = Probe()
        sketch.settings = SketchSettings(width: 8, height: 4, frameRate: 30, clock: .frames)
        let request = try #require(
            RenderRequest(frameRate: 24, frameCount: 1, destination: "/tmp/mokume-never-written.mov"))
        let application = try SketchApplication(sketch: sketch, gpu: RenderDevice(), render: request)
        // 畳むと書き出しの経路は終了コードを出してプロセスを終えるので、検査では受け取るだけにする
        application.exitProcess = { _ in }
        defer { application.willTerminate() }
        #expect(application.clock == .frameIndex(frameRate: 24))
        #expect(!application.isOnScreen)
    }

    @Test("窓を持たずに直に回す実行は、画面へ出さない扱い (音を数で進める)")
    func aBareRuntimeIsOffScreen() throws {
        let runtime = try SketchRuntime(sketch: Probe(), gpu: RenderDevice())
        #expect(!runtime.isOnScreen)
        let wall = try SketchRuntime(sketch: Probe(), gpu: RenderDevice(), clock: .wallClock)
        #expect(wall.isOnScreen, "実時間の時計は今までどおり鳴らす")
    }

    @Test("draw() の中で 30 ms かかったフレームが、窓の数字に予算超過として出る")
    func aSlowDrawShowsInTheNumbers() throws {
        var now = 0.0
        let sketch = Probe()
        sketch.onDraw = { probe in
            now += probe.frameCount == 3 ? 0.030 : 0.002
        }
        let runtime = try SketchRuntime(
            sketch: sketch, gpu: RenderDevice(), clock: .frameIndex(frameRate: 60), now: { now })
        for _ in 0..<5 { try runtime.advance() }
        let numbers = runtime.frameNumbers
        #expect(numbers.overBudgetFrames == 1)
        #expect(numbers.heaviestFrame == 3)
    }

    @Test("setup() で setup の重さは数えない")
    func setupIsNotCounted() throws {
        var now = 0.0
        let sketch = Probe()
        sketch.onSetup = { _ in now += 1 }
        let runtime = try SketchRuntime(
            sketch: sketch, gpu: RenderDevice(), clock: .frameIndex(frameRate: 60), now: { now })
        try runtime.advance()
        #expect(runtime.frameNumbers.overBudgetFrames == 0)
    }

    /// 1 画素の PNG を書く。
    private func writePicture() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("mokume-frame-clock-\(UUID().uuidString).png")
        try PNGFile.write(DisplayImage(width: 1, height: 1, bytes: [255, 0, 0, 255]), to: url)
        return url
    }

    @Test("draw() の中の loadImage は 1 度だけ知らせ、setup() の中では知らせない")
    func loadImageInDrawIsNoticed() throws {
        let url = try writePicture()
        defer { try? FileManager.default.removeItem(at: url) }

        let inSetup = Probe()
        inSetup.onSetup = { _ = try? $0.loadImage(url.path) }
        let quiet = try SketchRuntime(sketch: inSetup, gpu: RenderDevice())
        for _ in 0..<3 { try quiet.advance() }
        #expect(quiet.blockingLoads.message(for: "loadImage(_:)") == nil)

        var loaded = 0
        let inDraw = Probe()
        inDraw.onDraw = { probe in
            if (try? probe.loadImage(url.path)) != nil { loaded += 1 }
        }
        let noisy = try SketchRuntime(sketch: inDraw, gpu: RenderDevice())
        for _ in 0..<3 { try noisy.advance() }
        #expect(loaded == 3, "知らせても読み込みは止めない")
        #expect(
            noisy.blockingLoads.message(for: "loadImage(_:)")
                == BlockingLoads.notice("loadImage(_:)", instead: "requestImage(_:)"))
    }

    /// 書体の読み込み (#2445)。待たない口 (`requestFont`) はまだ無いので、案内は `setup()` で読むことだけ。
    @Test("draw() の中の loadFont は口の名前で 1 度だけ知らせ、setup() の中では知らせない")
    func loadFontInDrawIsNoticed() throws {
        let path = "/System/Library/Fonts/Helvetica.ttc"

        let inSetup = Probe()
        inSetup.onSetup = { _ = try? $0.loadFont(path) }
        let quiet = try SketchRuntime(sketch: inSetup, gpu: RenderDevice())
        for _ in 0..<3 { try quiet.advance() }
        #expect(quiet.blockingLoads.message(for: "loadFont(_:)") == nil)

        var loaded = 0
        let inDraw = Probe()
        inDraw.onDraw = { probe in
            if (try? probe.loadFont(path)) != nil { loaded += 1 }
        }
        let noisy = try SketchRuntime(sketch: inDraw, gpu: RenderDevice())
        for _ in 0..<3 { try noisy.advance() }
        #expect(loaded == 3, "知らせても読み込みは止めない")
        let message = try #require(noisy.blockingLoads.message(for: "loadFont(_:)"))
        #expect(message == BlockingLoads.notice("loadFont(_:)", instead: nil))
        #expect(message.hasPrefix("loadFont(_:) was called inside draw()."), "\(message)")
        #expect(!message.contains("requestFont"), "まだ無い口を案内した: \(message)")
    }

    /// 最上位が配列の JSON を読む口 (#2466)。待たない口 `requestJSONArray` を案内する。文字から読む口
    /// (`parseJSONObject`・`parseJSONArray`) はファイルを読まないので、`draw()` の中でも知らせない。
    @Test("draw() の中の loadJSONArray は口の名前で 1 度だけ requestJSONArray を案内し、setup() の中と parse は知らせない")
    func loadJSONArrayInDrawIsNoticed() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("mokume-frame-clock-\(UUID().uuidString).json")
        try Data("[1, 2, 3]".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let inSetup = Probe()
        inSetup.onSetup = { _ = try? $0.loadJSONArray(url.path) }
        let quiet = try SketchRuntime(sketch: inSetup, gpu: RenderDevice())
        for _ in 0..<3 { try quiet.advance() }
        #expect(quiet.blockingLoads.message(for: "loadJSONArray(_:)") == nil)

        var loaded = 0
        let inDraw = Probe()
        inDraw.onDraw = { probe in
            if (try? probe.loadJSONArray(url.path)) != nil { loaded += 1 }
            _ = try? probe.parseJSONObject("{}")
            _ = try? probe.parseJSONArray("[]")
        }
        let noisy = try SketchRuntime(sketch: inDraw, gpu: RenderDevice())
        for _ in 0..<3 { try noisy.advance() }
        #expect(loaded == 3, "知らせても読み込みは止めない")
        let message = try #require(noisy.blockingLoads.message(for: "loadJSONArray(_:)"))
        #expect(message == BlockingLoads.notice("loadJSONArray(_:)", instead: "requestJSONArray(_:)"))
        #expect(message.contains("requestJSONArray(_:)"), "\(message)")
        #expect(noisy.blockingLoads.message(for: "parseJSONObject(_:)") == nil)
        #expect(noisy.blockingLoads.message(for: "parseJSONArray(_:)") == nil)
    }

    /// 書体の読み込みは走っている面を使わないので、走っていなくても読め、走っていない口の警告も出ない。
    @Test("走っていない所でも loadFont は読め、走っていない口の警告を出さない")
    func loadFontWorksOutsideARun() throws {
        let log = OutsideRun()
        let probe = Probe()
        var font: Font?
        OutsideRun.$current.withValue(log) {
            font = try? probe.loadFont("/System/Library/Fonts/Helvetica.ttc")
        }
        #expect(font != nil)
        #expect(log.messages.isEmpty, "\(log.messages)")
    }

    /// **1 回の呼び出しで言うのは 1 行だけ** — `draw()` の中は走っているので、走っていない口の警告
    /// (`OutsideRun`・#2683) は出ず、同期の読み込みの警告だけが出る。外 (`init` など) から呼ぶと、
    /// 走っていない口の警告だけが出て、同期の読み込みの警告は出ない。
    @Test("draw() の中では同期の読み込みの警告だけ、外では走っていない口の警告だけが 1 行出る")
    func eachCallSaysOneLine() throws {
        let url = try writePicture()
        defer { try? FileManager.default.removeItem(at: url) }
        let inDraw = Probe()
        inDraw.onDraw = { _ = try? $0.loadImage(url.path) }
        let runtime = try SketchRuntime(sketch: inDraw, gpu: RenderDevice())

        let insideLog = OutsideRun()
        try OutsideRun.$current.withValue(insideLog) {
            for _ in 0..<3 { try runtime.advance() }
        }
        #expect(insideLog.messages.isEmpty, "draw() の中で走っていない口の警告が出た")
        #expect(runtime.blockingLoads.message(for: "loadImage(_:)") != nil)

        // 外から呼ぶ (走っていない)。同期の読み込みの控えには何も増えない
        let outsideLog = OutsideRun()
        OutsideRun.$current.withValue(outsideLog) {
            for _ in 0..<3 { _ = try? inDraw.loadModel(url.path) }
        }
        #expect(outsideLog.messages.count == 1, "外の 3 回で \(outsideLog.messages.count) 行")
        #expect(runtime.blockingLoads.message(for: "loadModel(_:normalize:)") == nil)
    }
}
