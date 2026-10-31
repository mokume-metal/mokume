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
nonisolated struct SceneTableTests {
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
        var scene = Scene(starting: Screen.title)
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
        var scene = Scene(starting: Screen.title)
        scene.change(to: .game, at: 10)
        scene.change(to: .result, at: 10)
        #expect(scene.current(at: 10) == .title)
        #expect(scene.current(at: 11) == .result)
        #expect(scene.justEntered(at: 11))
    }

    @Test("立て続けに切り替えても、効いた場面に入った位置を失わない")
    func consecutiveChangesKeepEachEntry() {
        var scene = Scene(starting: Screen.title)
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
        var scene = Scene(starting: Screen.title)
        scene.change(to: .game, at: 0)
        #expect(scene.current(at: 0) == .title)
        #expect(scene.current(at: 1) == .game)
        #expect(scene.justEntered(at: 1))
        #expect(!scene.justEntered(at: 2))
    }

    @Test("同じ場面への切り替えは入り直しで、次のフレームで justEntered が真")
    func changingToTheSameSceneReentersIt() {
        var scene = Scene(starting: Screen.game)
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
        var scene = Scene(starting: Screen.title)
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

    @Test("陰性対照: Enter を注入しなければ、場面は切り替わらない")
    func withoutTheKeyTheSceneStays() throws {
        let run = try play(frames: 14, enterAt: 0)
        #expect(Set(run.observed) == ["title"])
    }
}
