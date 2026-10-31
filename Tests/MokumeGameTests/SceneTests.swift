// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation
import MokumeDiagnostics
import MokumeTestSupport
import Testing

@testable import MokumeCore
@testable import MokumeGame

enum Screen: String, Sendable {
    case title, game, result
}

/// `draw()` を始めた回数を直に渡して、場面の切り替えの約束を表で確かめる (#3588)。窓も GPU も要らない。
///
/// 回数 0 は `setup()` と最初の `draw()` の前、回数 1 が最初の `draw()`。`draw()` の中で頼んだ切り替えも、
/// `draw()` の前に走る入力のコールバック・`Task` が頼んだ切り替えも、頼んだ時点で始まっていた `draw()` の
/// 回数 k に紐づき、k + 1 回目の `draw()` で効く (どこから頼んでも同じ規則)。
@MainActor
struct SceneTableTests {
    /// 実行 `run` が `draw()` を `draws` 回始めたときの目盛り。
    private func at(_ draws: Int, run: Int = 1) -> DrawProgress {
        DrawProgress(run: run, draws: draws)
    }

    @Test("始まりの場面は、最初の draw() から入っていて、その draw() だけ justEntered")
    func startingSceneIsEnteredAtTheFirstDraw() {
        let scene = Scene(starting: Screen.title)
        #expect(scene.sceneVisible(at: at(0)) == .title)
        #expect(!scene.enteredAtDraw(at: at(0)), "setup() では入っていない")
        for draws in 1...3 { #expect(scene.sceneVisible(at: at(draws)) == .title) }
        #expect(scene.enteredAtDraw(at: at(1)))
        #expect(!scene.enteredAtDraw(at: at(2)))
        #expect(!scene.enteredAtDraw(at: at(3)))
    }

    @Test("10 回目の draw() で切り替えると、10 回目は最後まで元の場面、11 回目の頭から新しい場面で、11 回目だけ justEntered")
    func changeTakesEffectAtTheNextDraw() {
        let scene = Scene(starting: Screen.title)
        scene.requestChange(to: .game, at: at(10))
        #expect(scene.sceneVisible(at: at(10)) == .title, "呼んだ draw() は元の場面のまま")
        #expect(!scene.enteredAtDraw(at: at(10)))
        #expect(scene.sceneVisible(at: at(11)) == .game)
        #expect(scene.enteredAtDraw(at: at(11)))
        #expect(scene.sceneVisible(at: at(12)) == .game)
        #expect(!scene.enteredAtDraw(at: at(12)), "その 1 回だけ")
        #expect(scene.sceneVisible(at: at(500)) == .game)
    }

    @Test("同じ draw() で何度か切り替えると、最後に呼んだものが効く")
    func theLastChangeInADrawWins() {
        let scene = Scene(starting: Screen.title)
        scene.requestChange(to: .game, at: at(10))
        scene.requestChange(to: .result, at: at(10))
        #expect(scene.sceneVisible(at: at(10)) == .title)
        #expect(scene.sceneVisible(at: at(11)) == .result)
        #expect(scene.enteredAtDraw(at: at(11)))
    }

    @Test("立て続けに切り替えても、効いた場面に入った位置を失わない")
    func consecutiveChangesKeepEachEntry() {
        let scene = Scene(starting: Screen.title)
        scene.requestChange(to: .game, at: at(10))
        // 11 回目で game に入り、その draw() の中で次の切り替えを頼む
        #expect(scene.sceneVisible(at: at(11)) == .game)
        scene.requestChange(to: .result, at: at(11))
        #expect(scene.sceneVisible(at: at(11)) == .game, "頼んだ draw() は game のまま")
        #expect(scene.enteredAtDraw(at: at(11)), "game に入った最初の draw()")
        #expect(scene.sceneVisible(at: at(12)) == .result)
        #expect(scene.enteredAtDraw(at: at(12)))
        #expect(!scene.enteredAtDraw(at: at(13)))
    }

    @Test("setup() (回数 0) で切り替えると、最初の draw() で効いて justEntered")
    func changeInSetupTakesEffectAtTheFirstDraw() {
        let scene = Scene(starting: Screen.title)
        scene.requestChange(to: .game, at: at(0))
        #expect(scene.sceneVisible(at: at(0)) == .title, "setup() の間は元の場面")
        #expect(scene.sceneVisible(at: at(1)) == .game)
        #expect(scene.enteredAtDraw(at: at(1)))
        #expect(!scene.enteredAtDraw(at: at(2)))
    }

    @Test("同じ場面への切り替えは入り直しで、次の draw() で justEntered が真")
    func changingToTheSameSceneReentersIt() {
        let scene = Scene(starting: Screen.game)
        scene.requestChange(to: .game, at: at(20))
        #expect(!scene.enteredAtDraw(at: at(20)))
        #expect(scene.sceneVisible(at: at(21)) == .game)
        #expect(scene.enteredAtDraw(at: at(21)))
        #expect(!scene.enteredAtDraw(at: at(22)))
    }

    @Test("場面の値は Sendable で、隔離の外からも作れる")
    func sceneCanBeCreatedOutsideTheMainActor() async {
        let scene = await Task.detached { Scene(starting: Screen.title) }.value
        #expect(scene.sceneVisible(at: at(1)) == .title)
    }

    // MARK: - 読まれない draw()・止めている間 (頼んだ時点で効く draw() が決まる)

    @Test("読まれない draw() を挟んでも、入った最初の draw() は頼んだ回数で決まる。後で読んでも justEntered は偽")
    func theEntryDrawIsFixedWhenAskedNotWhenRead() {
        let scene = Scene(starting: Screen.title)
        for draws in 1...5 { #expect(scene.sceneVisible(at: at(draws)) == .title) }
        scene.requestChange(to: .game, at: at(5))  // 5 回目の draw() が返った後の Task
        // 6〜8 回目は誰も読まない
        #expect(scene.sceneVisible(at: at(9)) == .game)
        #expect(!scene.enteredAtDraw(at: at(9)), "game に入ったのは 6 回目。読んだ 9 回目ではない")
        #expect(scene.enteredAtDraw(at: at(6)), "入った最初の draw() は 6 回目で、後から引いても変わらない")
    }

    @Test("毎回読んでも、まばらにしか読まなくても、入った draw() が割れない")
    func skippingReadsDoesNotMoveTheEntry() {
        let readEveryDraw = Scene(starting: Screen.title)
        let readRarely = Scene(starting: Screen.title)
        for scene in [readEveryDraw, readRarely] { scene.requestChange(to: .game, at: at(5)) }
        for draws in 5...8 { _ = readEveryDraw.sceneVisible(at: at(draws)) }
        let every = (6...9).map { readEveryDraw.enteredAtDraw(at: at($0)) }
        let rarely = (6...9).map { readRarely.enteredAtDraw(at: at($0)) }
        #expect(every == [true, false, false, false])
        #expect(rarely == every)
    }

    @Test("頼んだ切り替えが効く前に、別の切り替えを頼んでも、後のものが効く")
    func aLaterRequestReplacesAPendingOne() {
        let scene = Scene(starting: Screen.title)
        scene.requestChange(to: .game, at: at(10))
        scene.requestChange(to: .result, at: at(10))  // 11 回目の前に走る Task
        #expect(scene.sceneVisible(at: at(11)) == .result)
        #expect(scene.enteredAtDraw(at: at(11)))
        #expect(!scene.enteredAtDraw(at: at(12)))
    }

    @Test("止めている間 (最後に描いたのは 10 回目) に頼んだ切り替えは、次に描く 11 回目で効く。それまで読む current は元の場面")
    func changeWhileStoppedTakesEffectOnTheNextDrawnFrame() {
        let scene = Scene(starting: Screen.title)
        for draws in 1...10 { _ = scene.sceneVisible(at: at(draws)) }  // 10 回目に noLoop()
        scene.requestChange(to: .game, at: at(10))  // 止めている間の Task
        #expect(scene.sceneVisible(at: at(10)) == .title, "止めている間のコールバックが読む current は元の場面")
        #expect(scene.sceneVisible(at: at(10)) == .title)
        #expect(!scene.enteredAtDraw(at: at(10)))
        #expect(scene.sceneVisible(at: at(11)) == .game, "redraw() で描く次の draw()")
        #expect(scene.enteredAtDraw(at: at(11)), "redraw() の draw() で justEntered")
    }

    // MARK: - 走っていない所で読む

    @Test("走っていない所で読むと、最後に描いた draw() で見えていた場面を返す。口の名前ごとに 1 度だけ、観測の応答にも載せて警告する")
    func readingOutsideARunReturnsTheLastVisibleScene() {
        let log = OutsideRun()
        let digest = WarningDigest()
        Diagnostics.$digest.withValue(digest) {
            OutsideRun.$current.withValue(log) {
                let scene = Scene(starting: Screen.title)
                #expect(
                    scene.lastDrawnScene(at: at(0), calledAs: "Scene.current") == .title, "まだ描いていなければ始まりの場面")
                scene.requestChange(to: .game, at: at(10))
                #expect(scene.sceneVisible(at: at(11)) == .game)
                for _ in 0..<3 {
                    #expect(
                        scene.lastDrawnScene(at: at(11), calledAs: "Scene.current") == .game,
                        "最後に描いた 11 回目で見えていた場面")
                    _ = scene.lastDrawnScene(at: at(11), calledAs: "Scene.justEntered")
                }
                #expect(log.messages.count == 2, "current と justEntered が 1 度ずつ")
                #expect(log.messageForRead(of: "Scene.current")?.hasPrefix("Scene.current ") == true)
                #expect(log.messageForRead(of: "Scene.justEntered")?.hasPrefix("Scene.justEntered ") == true)
                // 観測の応答の warnings に載る文面と同じ
                #expect(digest.takeUnreported() == log.messages)
            }
        }
    }

    @Test("走っている実行が無い所の current / justEntered は、場面と偽を返し、観測の応答に載る警告を言う")
    func publicReadsOutsideARunWarn() {
        let log = OutsideRun()
        let digest = WarningDigest()
        Diagnostics.$digest.withValue(digest) {
            OutsideRun.$current.withValue(log) {
                let scene = Scene(starting: Screen.title)
                #expect(scene.current == .title)
                #expect(!scene.justEntered)
                #expect(log.messages.count == 2)
                #expect(digest.takeUnreported().count == 2, "観測の応答に載る")
                // SwiftUI の body で読む場合にも実行できる助言にする: 「setup() の中で決めろ」とは言わない
                for message in log.messages {
                    #expect(message.contains("SwiftUI"), "\(message)")
                    #expect(message.contains("Read it inside draw()"), "\(message)")
                    #expect(!message.contains("Make anything that depends on it inside setup()"), "\(message)")
                }
            }
        }
    }

    @Test("切り替えはどこから頼んでも警告しない")
    func changingNeverWarns() {
        let log = OutsideRun()
        let digest = WarningDigest()
        Diagnostics.$digest.withValue(digest) {
            OutsideRun.$current.withValue(log) {
                let scene = Scene(starting: Screen.title)
                scene.change(to: .game)  // 走っていない所から
                scene.requestChange(to: .result, at: at(3))
                #expect(log.messages.isEmpty)
                #expect(digest.takeUnreported().isEmpty)
            }
        }
    }

    // MARK: - 実行の識別 (別の実行)

    @Test("実行が変わったら新しい実行とみなし、頼んであった切り替えを確定して、その実行の最初の draw() で justEntered")
    func aDifferentRunStartsOver() {
        let scene = Scene(starting: Screen.title)
        for draws in 1...400 { _ = scene.sceneVisible(at: at(draws)) }
        scene.requestChange(to: .game, at: at(400))  // 効く前に実行が終わる
        // 別の実行 (同じ値を static に置いて持ち越した)
        #expect(scene.sceneVisible(at: at(1, run: 2)) == .game, "頼んでいた切り替えは確定する")
        #expect(scene.enteredAtDraw(at: at(1, run: 2)), "新しい実行の最初の draw()")
        #expect(!scene.enteredAtDraw(at: at(2, run: 2)))
        #expect(scene.sceneVisible(at: at(401, run: 2)) == .game, "401 回目に突然何かが効くことはない")
        #expect(!scene.enteredAtDraw(at: at(401, run: 2)))
    }

    @Test("新しい実行の最初の読みが前の実行の回数以上でも、別の実行と分かる (番号の大小で推し量らない)")
    func aLaterFirstReadInTheNewRunIsStillANewRun() {
        let scene = Scene(starting: Screen.title)
        for draws in 1...3 { _ = scene.sceneVisible(at: at(draws)) }
        scene.requestChange(to: .game, at: at(3))  // 前の実行の 4 回目で効くはずだった
        // 前の実行は 3 回で終わり、新しい実行が 4 回目の draw() で初めて読む。番号は前の実行の 3 より大きい
        #expect(scene.sceneVisible(at: at(4, run: 2)) == .game, "頼んでいた切り替えは確定する")
        #expect(!scene.enteredAtDraw(at: at(4, run: 2)), "前の実行で頼んだ 4 回目の入りを、新しい実行の 4 回目に持ち越さない")
        #expect(scene.sceneVisible(at: at(5, run: 2)) == .game)
    }

    @Test("新しい実行の setup() (回数 0) で読んでも、最初の draw() で justEntered")
    func aNewRunReadInSetup() {
        let scene = Scene(starting: Screen.title)
        for draws in 1...5 { _ = scene.sceneVisible(at: at(draws)) }
        _ = scene.sceneVisible(at: at(0, run: 2))  // 新しい実行の setup()
        #expect(scene.enteredAtDraw(at: at(1, run: 2)))
    }

    // MARK: - 複製は同じ場面を指す

    @Test("Scene を複製して渡した先で切り替えると、元の Scene も切り替わる")
    func copiesShareTheScene() {
        let scene = Scene(starting: Screen.title)
        let handedToAPart = scene
        handedToAPart.requestChange(to: .game, at: at(3))
        #expect(scene.sceneVisible(at: at(4)) == .game)
        #expect(scene.enteredAtDraw(at: at(4)))
        // 別の場面は Scene(starting:) で作る
        let other = Scene(starting: Screen.title)
        #expect(other.sceneVisible(at: at(4)) == .title)
    }
}

/// `Scene` を走っているスケッチの中で回す (#3588)。GPU を要する。
///
/// 完了条件の例どおり: フレーム 10 の `draw()` で Enter を受けて切り替えると、観測が読む公開値の場面は
/// フレーム 10 で `title`、フレーム 11 で `game` になる。フレームの時計に注入した入力で、2 回流しても同じ。
@Suite(
    "場面の切り替え (走っているスケッチ)",
    .serialized,
    .enabled(
        if: RenderDevice.isAvailable,
        "この世代のコマンド構造に対応した GPU が無い実行環境ではスキップする")
)
struct SceneSketchTests {
    /// 場面を持ち、Enter で `title` → `game` へ切り替え、場面の名前を公開するスケッチ。
    final class Platformer: Sketch {
        let scene = Scene(starting: Screen.title)
        /// 各フレームの `draw()` の頭で見えた (場面の名前, justEntered)。
        nonisolated(unsafe) static var seen: [(name: String, entered: Bool)] = []
        init() {}
        var settings: SketchSettings { SketchSettings(width: 16, height: 16, clock: .frames) }
        func draw() {
            background(0, 0, 0)
            Self.seen.append((scene.current.rawValue, scene.justEntered))
            if keyboard.justPressed(.enter) { scene.change(to: .game) }
            expose("scene", scene.current.rawValue)
        }
    }

    private static let enterDown = InputEvent.keyDown(code: .enter, characters: "\r", isRepeat: false)

    private func request(id: String, in facet: URL) throws {
        try AtomicFile.write(
            Data(#"{"id":"\#(id)"}"#.utf8), to: facet.appendingPathComponent("request.json"))
    }

    /// 応答の `values.scene.value`。
    private func sceneName(in facet: URL) throws -> String? {
        let data = try Data(contentsOf: facet.appendingPathComponent("report.json"))
        let report = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
        let values = report["values"] as? [String: [String: Any]] ?? [:]
        return values["scene"]?["value"] as? String
    }

    /// フレーム 1〜`frames` を流し、`enterAt` のフレームの頭に Enter を注入する。観測が読んだ場面の名前の列を返す。
    private func play(frames: Int, enterAt: Int) throws -> (observed: [String?], seen: [(name: String, entered: Bool)]) {
        Platformer.seen = []
        let facet = try TestScratch.directory("mokume-game-scene")
        let runtime = try SketchRuntime(
            sketch: Platformer(), gpu: try RenderDevice(), clock: .frameIndex(frameRate: 60),
            now: { 0 }, observer: FrameObserver(directory: facet))
        var observed: [String?] = []
        for frame in 1...frames {
            if frame == enterAt { runtime.input.enqueue(Self.enterDown) }
            try request(id: "f\(frame)", in: facet)
            try runtime.advance()
            observed.append(try sceneName(in: facet))
        }
        return (observed, Platformer.seen)
    }

    @Test("フレーム 10 の draw() で Enter を受けて切り替えると、公開値の場面はフレーム 10 で title・11 で game")
    func exposedSceneChangesAtTheNextFrame() throws {
        let run = try play(frames: 14, enterAt: 10)
        #expect(run.observed.count == 14)
        for frame in 1...10 { #expect(run.observed[frame - 1] == "title", "フレーム \(frame)") }
        for frame in 11...14 { #expect(run.observed[frame - 1] == "game", "フレーム \(frame)") }
        // draw() の頭で見えた場面も同じ。game に入った最初のフレームだけ justEntered
        #expect(run.seen.map(\.name) == Array(repeating: "title", count: 10) + Array(repeating: "game", count: 4))
        #expect(run.seen.enumerated().filter { $0.element.entered }.map { $0.offset + 1 } == [1, 11])
    }

    @Test("同じ入力を 2 回流しても、同じフレームで切り替わる")
    func theSameInputsSwitchAtTheSameFrame() throws {
        let first = try play(frames: 14, enterAt: 10)
        let second = try play(frames: 14, enterAt: 10)
        #expect(first.observed == second.observed)
        #expect(first.seen.map(\.name) == second.seen.map(\.name))
        #expect(first.seen.map(\.entered) == second.seen.map(\.entered))
    }

    /// 部品。`Scene` を複製して渡された先から切り替える。
    struct Gate: SketchPart {
        let scene: Scene<Screen>
        func open() { scene.change(to: .game) }
    }

    /// 検査が渡した手続きを `draw()`・キーのコールバックで走らせる、場面を持つスケッチ。
    final class Probe: Sketch {
        let scene = Scene(starting: Screen.title)
        let gate: Gate
        /// `draw()` の頭に走る手続き。
        nonisolated(unsafe) static var onDraw: (Probe) -> Void = { _ in }
        /// `keyPressed()` で走る手続き。
        nonisolated(unsafe) static var onKey: (Probe) -> Void = { _ in }
        /// `draw()` の頭で読む回数の絞り込み (`nil` は毎回読む)。読まない `draw()` の挟み方を作る。
        nonisolated(unsafe) static var readOnly: Set<Int>?
        /// 各フレームの `draw()` で見えた (フレーム番号, 場面の名前, justEntered)。
        nonisolated(unsafe) static var seen: [(frame: Int, name: String, entered: Bool)] = []
        /// `keyPressed()` が読んだ (フレーム番号, 場面の名前)。
        nonisolated(unsafe) static var seenInCallback: [(frame: Int, name: String)] = []
        init() { gate = Gate(scene: scene) }
        var settings: SketchSettings { SketchSettings(width: 16, height: 16, clock: .frames) }
        static func reset() {
            onDraw = { _ in }
            onKey = { _ in }
            readOnly = nil
            seen = []
            seenInCallback = []
        }
        func draw() {
            background(0, 0, 0)
            if Self.readOnly?.contains(frameCount) ?? true {
                Self.seen.append((frameCount, scene.current.rawValue, scene.justEntered))
            }
            Self.onDraw(self)
        }
        func keyPressed() {
            Self.seenInCallback.append((frameCount, scene.current.rawValue))
            Self.onKey(self)
        }
    }

    private func makeProbe() throws -> (Probe, SketchRuntime) {
        let probe = Probe()
        let runtime = try SketchRuntime(sketch: probe, gpu: try RenderDevice(), clock: .frameIndex(frameRate: 60))
        return (probe, runtime)
    }

    private func enteredFrames() -> [Int] {
        Probe.seen.filter(\.entered).map(\.frame)
    }

    @Test("Task の中 (draw() が返った後) から切り替えると、次に描くフレームから効き、そのフレームだけ justEntered")
    func changeFromATaskTakesEffectAtTheNextDrawnFrame() async throws {
        Probe.reset()
        let (probe, runtime) = try makeProbe()
        Probe.onDraw = { sketch in
            // 読み込みが終わった、のつもり。draw() が返った後に走る (このとき runningSketch は外れている)
            if sketch.frameCount == 5 { Task { sketch.scene.change(to: .game) } }
        }
        for frame in 1...8 {
            try runtime.advance()
            if frame == 5 { try await Task.sleep(for: .milliseconds(30)) }
        }
        #expect(Probe.seen.map(\.frame) == Array(1...8))
        #expect(
            Probe.seen.map(\.name) == Array(repeating: "title", count: 5) + Array(repeating: "game", count: 3),
            "\(Probe.seen)")
        #expect(enteredFrames() == [1, 6], "最初のフレームと、game に入った 6 だけ")
        _ = probe
    }

    @Test("読まれないフレームを挟んでも、Task が頼んだ切り替えで入ったフレームは、頼んだ次のフレームに決まる")
    func unreadFramesDoNotMoveTheEntryFrame() async throws {
        Probe.reset()
        Probe.readOnly = [1, 2, 3, 4, 5, 9, 10]  // 6〜8 は誰も読まない
        let (_, runtime) = try makeProbe()
        Probe.onDraw = { sketch in
            if sketch.frameCount == 5 { Task { sketch.scene.change(to: .game) } }
        }
        for frame in 1...10 {
            try runtime.advance()
            if frame == 5 { try await Task.sleep(for: .milliseconds(30)) }
        }
        let late = Probe.seen.filter { $0.frame >= 9 }
        #expect(late.map(\.name) == ["game", "game"])
        #expect(late.map(\.entered) == [false, false], "game に入ったのは 6 回目で、読んだ 9 回目ではない")
    }

    @Test("noLoop() で止めている間、Task が切り替えを頼んでも、止めている間のコールバックが読む current は元の場面。redraw() の draw() で効く")
    func aTaskChangeWhileStoppedWaitsForTheRedraw() async throws {
        Probe.reset()
        let (probe, runtime) = try makeProbe()
        Probe.onDraw = { sketch in
            if sketch.frameCount == 3 { sketch.noLoop() }
        }
        for _ in 1...5 { try runtime.advance() }  // 3 で止まり、4・5 は描かない
        #expect(Probe.seen.map(\.frame) == [1, 2, 3])
        Task { probe.scene.change(to: .game) }  // 止めている間に走る Task
        try await Task.sleep(for: .milliseconds(30))
        // 止めている間のコールバック (実行は差さっている)。Task が頼んだ切り替えは、まだ効かない
        runtime.input.enqueue(Self.enterDown)
        try runtime.advance()
        #expect(Probe.seenInCallback.map(\.name) == ["title"], "redraw() を待たずに効いてはいけない")
        #expect(Probe.seen.map(\.frame) == [1, 2, 3], "止めている間は描かない")
        Probe.onDraw = { _ in }
        runtime.redraw()
        try runtime.advance()
        #expect(Probe.seen.map(\.frame) == [1, 2, 3, 4])
        #expect(Probe.seen.last?.name == "game" && Probe.seen.last?.entered == true)
    }

    @Test("ループ中の入力のコールバックが切り替えると、直後の draw() で効く。コールバックが読む current は元の場面")
    func aCallbackChangeInTheLoopTakesEffectAtTheFollowingDraw() throws {
        Probe.reset()
        let (_, runtime) = try makeProbe()
        Probe.onKey = { sketch in sketch.scene.change(to: .game) }
        for frame in 1...12 {
            if frame == 10 { runtime.input.enqueue(Self.enterDown) }
            try runtime.advance()
        }
        #expect(Probe.seenInCallback.map(\.name) == ["title"], "コールバックが読むのは元の場面")
        #expect(Probe.seen.map(\.name) == Array(repeating: "title", count: 9) + Array(repeating: "game", count: 3))
        #expect(enteredFrames() == [1, 10], "コールバックの直後の draw() で効き、1 枚遅れない")
    }

    @Test("止めている間のコールバックが切り替えても、redraw() の draw() で効く (ループ中と同じく、直後の draw())")
    func aCallbackChangeWhileStoppedTakesEffectAtTheRedraw() throws {
        Probe.reset()
        let (_, runtime) = try makeProbe()
        Probe.onDraw = { sketch in
            if sketch.frameCount == 3 { sketch.noLoop() }
        }
        Probe.onKey = { sketch in sketch.scene.change(to: .game) }
        for _ in 1...5 { try runtime.advance() }
        runtime.input.enqueue(Self.enterDown)
        try runtime.advance()  // 止めている間にコールバックが配られる
        #expect(Probe.seenInCallback.map(\.name) == ["title"])
        #expect(Probe.seen.map(\.frame) == [1, 2, 3])
        Probe.onDraw = { _ in }
        runtime.redraw()
        try runtime.advance()
        #expect(Probe.seen.map(\.frame) == [1, 2, 3, 4])
        #expect(Probe.seen.last?.name == "game" && Probe.seen.last?.entered == true)
    }

    @Test("部品 (SketchPart の struct) へ渡した複製から、走っているスケッチの draw() の中で切り替えると、元の Scene が切り替わる")
    func aCopyHandedToAPartSwitchesTheSketchScene() throws {
        Probe.reset()
        let (_, runtime) = try makeProbe()
        Probe.onDraw = { sketch in
            if sketch.frameCount == 4 { sketch.gate.open() }
        }
        for _ in 1...7 { try runtime.advance() }
        #expect(Probe.seen.map(\.name) == Array(repeating: "title", count: 4) + Array(repeating: "game", count: 3))
        #expect(enteredFrames() == [1, 5])
    }

    @Test("陰性対照: Enter を注入しなければ、場面は切り替わらない")
    func withoutTheKeyTheSceneStays() throws {
        let run = try play(frames: 14, enterAt: 0)
        #expect(Set(run.observed) == ["title"])
    }
}
