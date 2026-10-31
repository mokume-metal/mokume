// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation
import MokumeTestSupport
import Testing

@testable import MokumeCore
@testable import MokumeGame

enum Screen: String, Sendable {
    case title, game, result
}

/// フレーム番号を直に渡して、場面の切り替えの約束を表で確かめる (#3588)。窓も GPU も要らない。
///
/// フレーム 0 は `setup()` (最初の `draw()` の前)、フレーム 1 が最初の `draw()`。
@MainActor
struct SceneTableTests {
    @Test("始まりの場面は、最初のフレームから入っていて、そのフレームだけ justEntered")
    func startingSceneIsEnteredAtTheFirstFrame() {
        let scene = Scene(starting: Screen.title)
        #expect(scene.current(at: 0) == .title)
        #expect(!scene.justEntered(at: 0), "setup() では入っていない")
        for frame in 1...3 { #expect(scene.current(at: frame) == .title) }
        #expect(scene.justEntered(at: 1))
        #expect(!scene.justEntered(at: 2))
        #expect(!scene.justEntered(at: 3))
    }

    @Test("フレーム 10 で切り替えると、10 は最後まで元の場面、11 の頭から新しい場面で、11 だけ justEntered")
    func changeTakesEffectAtTheNextFrame() {
        let scene = Scene(starting: Screen.title)
        scene.change(to: .game, at: 10)
        #expect(scene.current(at: 10) == .title, "呼んだフレームは元の場面のまま")
        #expect(!scene.justEntered(at: 10))
        #expect(scene.current(at: 11) == .game)
        #expect(scene.justEntered(at: 11))
        #expect(scene.current(at: 12) == .game)
        #expect(!scene.justEntered(at: 12), "その 1 フレームだけ")
        #expect(scene.current(at: 500) == .game)
    }

    @Test("同じフレームで何度か切り替えると、最後に呼んだものが効く")
    func theLastChangeInAFrameWins() {
        let scene = Scene(starting: Screen.title)
        scene.change(to: .game, at: 10)
        scene.change(to: .result, at: 10)
        #expect(scene.current(at: 10) == .title)
        #expect(scene.current(at: 11) == .result)
        #expect(scene.justEntered(at: 11))
    }

    @Test("立て続けに切り替えても、効いた場面に入った位置を失わない")
    func consecutiveChangesKeepEachEntry() {
        let scene = Scene(starting: Screen.title)
        scene.change(to: .game, at: 10)
        // 11 で game に入り、その draw() の中で次の切り替えを頼む
        #expect(scene.current(at: 11) == .game)
        scene.change(to: .result, at: 11)
        #expect(scene.current(at: 11) == .game, "頼んだフレームは game のまま")
        #expect(scene.justEntered(at: 11), "game に入った最初のフレーム")
        #expect(scene.current(at: 12) == .result)
        #expect(scene.justEntered(at: 12))
        #expect(!scene.justEntered(at: 13))
    }

    @Test("setup() (フレーム 0) で切り替えると、最初のフレームで効いて justEntered")
    func changeInSetupTakesEffectAtTheFirstFrame() {
        let scene = Scene(starting: Screen.title)
        scene.change(to: .game, at: 0)
        #expect(scene.current(at: 0) == .title)
        #expect(scene.current(at: 1) == .game)
        #expect(scene.justEntered(at: 1))
        #expect(!scene.justEntered(at: 2))
    }

    @Test("同じ場面への切り替えは入り直しで、次のフレームで justEntered が真")
    func changingToTheSameSceneReentersIt() {
        let scene = Scene(starting: Screen.game)
        scene.change(to: .game, at: 20)
        #expect(!scene.justEntered(at: 20))
        #expect(scene.current(at: 21) == .game)
        #expect(scene.justEntered(at: 21))
        #expect(!scene.justEntered(at: 22))
    }

    @Test("場面の値は Sendable で、隔離の外からも作れる")
    func sceneCanBeCreatedOutsideTheMainActor() async {
        let scene = await Task.detached { Scene(starting: Screen.title) }.value
        #expect(scene.current(at: 1) == .title)
    }

    // MARK: - 描いている最中でない所から (Task・コールバック・止めている間)

    @Test("フレームが分からない所 (Task の中) から切り替えると、次に読まれたフレームの頭で効き、そのフレームだけ justEntered")
    func changeFromWhereTheFrameIsUnknownTakesEffectAtTheNextRead() {
        let scene = Scene(starting: Screen.title)
        for frame in 1...5 { #expect(scene.current(at: frame) == .title) }
        scene.change(to: .game, at: nil)  // フレーム 5 を描き終えた後の Task
        #expect(scene.current(at: 6) == .game)
        #expect(scene.justEntered(at: 6), "効いたフレームで 1 度は真になる")
        #expect(scene.current(at: 7) == .game)
        #expect(!scene.justEntered(at: 7), "1 度だけ")
    }

    @Test("描く前 (プロパティの初期値・setup() の前) から切り替えても、最初のフレームで効いて justEntered")
    func changeBeforeTheFirstFrame() {
        let scene = Scene(starting: Screen.title)
        scene.change(to: .game, at: nil)
        #expect(scene.current(at: 0) == .game || scene.current(at: 0) == .title)  // setup() の中。どちらでも約束しない
        #expect(scene.current(at: 1) == .game)
        #expect(scene.justEntered(at: 1))
        #expect(!scene.justEntered(at: 2))
    }

    @Test("頼んだ切り替えが読まれる前に、別の切り替えを Task から頼んでも、古い場面で潰さず、後のものが効く")
    func aPendingChangeIsNotOverwrittenByTheSettledScene() {
        let scene = Scene(starting: Screen.title)
        scene.change(to: .game, at: 10)
        scene.change(to: .result, at: nil)  // 11 を読む前の Task
        #expect(scene.current(at: 11) == .result)
        #expect(scene.justEntered(at: 11))
        #expect(!scene.justEntered(at: 12))
    }

    @Test("効いた後に Task から次の切り替えを頼むと、効いた場面に入った位置を失わず、次のフレームで次の場面に入る")
    func aTaskChangeAfterAnEffectiveOneKeepsBoth() {
        let scene = Scene(starting: Screen.title)
        scene.change(to: .game, at: 10)
        #expect(scene.current(at: 11) == .game && scene.justEntered(at: 11))
        scene.change(to: .result, at: nil)
        #expect(scene.current(at: 12) == .result)
        #expect(scene.justEntered(at: 12))
        #expect(scene.current(at: 13) == .result && !scene.justEntered(at: 13))
    }

    @Test("止めている間のコールバックで切り替えても、次に描くフレームの頭で効く。それまで読む current は元の場面")
    func changeWhileStoppedTakesEffectOnTheNextDrawnFrame() {
        let scene = Scene(starting: Screen.title)
        for frame in 1...10 { _ = scene.current(at: frame) }  // 10 で noLoop()
        scene.change(to: .game, at: 10)  // 止めている間のコールバック (最後に描いたのは 10)
        #expect(scene.current(at: 10) == .title, "止めている間の読みは元の場面")
        #expect(scene.current(at: 10) == .title)
        #expect(scene.current(at: 11) == .game, "redraw() で描く次のフレーム")
        #expect(scene.justEntered(at: 11))
    }

    // MARK: - 走っていない所で読む

    @Test("走っていない所で読むと、最後に描いたフレームで見えていた場面を返し、justEntered は偽。口の名前で 1 度だけ警告する")
    func readingOutsideARunReturnsTheLastVisibleScene() {
        let notices = SceneNotices()
        SceneNotices.$override.withValue(notices) {
            let scene = Scene(starting: Screen.title)
            #expect(scene.current(at: nil) == .title, "まだ描いていなければ始まりの場面")
            scene.change(to: .game, at: 10)
            #expect(scene.current(at: 11) == .game)
            for _ in 0..<3 {
                #expect(scene.current(at: nil) == .game, "最後に描いた 11 で見えていた場面")
                #expect(!scene.justEntered(at: nil))
            }
            #expect(notices.messages.count == 2, "current と justEntered が 1 度ずつ")
            #expect(notices.messages.contains { $0.hasPrefix("Scene.current ") })
            #expect(notices.messages.contains { $0.hasPrefix("Scene.justEntered ") })
            #expect(!notices.messages.contains { $0.contains("frameCount") }, "作者の frameCount の警告と鍵を共有しない")
        }
    }

    @Test("切り替えはどこから頼んでも警告しない")
    func changingNeverWarns() {
        let notices = SceneNotices()
        SceneNotices.$override.withValue(notices) {
            let scene = Scene(starting: Screen.title)
            scene.change(to: .game, at: nil)
            scene.change(to: .result, at: 3)
            #expect(notices.messages.isEmpty)
        }
    }

    // MARK: - フレーム番号が戻る (別の実行)

    @Test("読んだ番号が戻ったら新しい実行とみなし、頼んであった切り替えを確定して、最初のフレームで justEntered")
    func aFrameNumberThatGoesBackStartsANewRun() {
        let scene = Scene(starting: Screen.title)
        for frame in 1...400 { _ = scene.current(at: frame) }
        scene.change(to: .game, at: 400)  // 効く前に実行が終わる
        // 別の実行 (同じ値を static に置いて持ち越した)
        #expect(scene.current(at: 1) == .game, "頼んでいた切り替えは確定する")
        #expect(scene.justEntered(at: 1), "新しい実行の最初のフレーム")
        #expect(!scene.justEntered(at: 2))
        #expect(scene.current(at: 401) == .game, "401 フレーム目に突然何かが効くことはない")
        #expect(!scene.justEntered(at: 401))
    }

    @Test("新しい実行の setup() (フレーム 0) で読んでも、最初の draw() で justEntered")
    func aNewRunReadInSetup() {
        let scene = Scene(starting: Screen.title)
        for frame in 1...5 { _ = scene.current(at: frame) }
        _ = scene.current(at: 0)  // 新しい実行の setup()
        #expect(scene.justEntered(at: 1))
    }

    // MARK: - 複製は同じ場面を指す

    @Test("Scene を複製して渡した先で切り替えると、元の Scene も切り替わる")
    func copiesShareTheScene() {
        let scene = Scene(starting: Screen.title)
        let handedToAPart = scene
        handedToAPart.change(to: .game, at: 3)
        #expect(scene.current(at: 4) == .game)
        #expect(scene.justEntered(at: 4))
        // 別の場面は Scene(starting:) で作る
        let other = Scene(starting: Screen.title)
        #expect(other.current(at: 4) == .title)
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

    /// 検査が渡した手続きを `draw()` で走らせる、場面を持つスケッチ。
    final class Hooked: Sketch {
        var scene = Scene(starting: Screen.title)
        nonisolated(unsafe) static var onDraw: (Hooked) -> Void = { _ in }
        /// 各フレームの `draw()` で見えた (フレーム番号, 場面の名前, justEntered)。
        nonisolated(unsafe) static var seen: [(frame: Int, name: String, entered: Bool)] = []
        init() {}
        var settings: SketchSettings { SketchSettings(width: 16, height: 16, clock: .frames) }
        func draw() {
            background(0, 0, 0)
            Self.seen.append((frameCount, scene.current.rawValue, scene.justEntered))
            Self.onDraw(self)
        }
    }

    @Test("Task の中 (draw() が返った後) から切り替えると、次に描くフレームから効き、そのフレームだけ justEntered")
    func changeFromATaskTakesEffectAtTheNextDrawnFrame() async throws {
        Hooked.seen = []
        Hooked.onDraw = { sketch in
            if sketch.frameCount == 5 {
                // 読み込みが終わった、のつもり。draw() が返った後に走る (このとき runningSketch は外れている)
                Task { sketch.scene.change(to: .game) }
            }
        }
        let runtime = try SketchRuntime(sketch: Hooked(), gpu: try RenderDevice(), clock: .frameIndex(frameRate: 60))
        for frame in 1...8 {
            try runtime.advance()
            if frame == 5 { try await Task.sleep(for: .milliseconds(30)) }
        }
        let seen = Hooked.seen
        #expect(seen.map(\.frame) == Array(1...8))
        #expect(seen.map(\.name) == Array(repeating: "title", count: 5) + Array(repeating: "game", count: 3), "\(seen)")
        #expect(seen.enumerated().filter { $0.element.entered }.map { $0.offset + 1 } == [1, 6], "最初のフレームと、game に入った 6 だけ")
    }

    @Test("noLoop() で止めている間に切り替えても、redraw() で描く次のフレームの頭で効く。止めている間に読んだ current は元の場面")
    func changeWhileStoppedTakesEffectAtTheRedrawnFrame() throws {
        Hooked.seen = []
        Hooked.onDraw = { sketch in
            if sketch.frameCount == 3 { sketch.noLoop() }
        }
        let hooked = Hooked()
        let runtime = try SketchRuntime(sketch: hooked, gpu: try RenderDevice(), clock: .frameIndex(frameRate: 60))
        for _ in 1...5 { try runtime.advance() }  // 3 で止まり、4・5 は描かない
        #expect(Hooked.seen.map(\.frame) == [1, 2, 3])
        // 止めている間のコールバックの代わり。走っている最中ではないので、フレームは分からない
        let notices = SceneNotices()
        SceneNotices.$override.withValue(notices) {
            hooked.scene.change(to: .game)
            #expect(hooked.scene.current == .title, "止めている間に読む current は元の場面")
        }
        Hooked.onDraw = { _ in }
        runtime.redraw()
        try runtime.advance()
        #expect(Hooked.seen.map(\.frame) == [1, 2, 3, 4])
        #expect(Hooked.seen.last?.name == "game" && Hooked.seen.last?.entered == true)
    }

    @Test("陰性対照: Enter を注入しなければ、場面は切り替わらない")
    func withoutTheKeyTheSceneStays() throws {
        let run = try play(frames: 14, enterAt: 0)
        #expect(Set(run.observed) == ["title"])
    }
}
