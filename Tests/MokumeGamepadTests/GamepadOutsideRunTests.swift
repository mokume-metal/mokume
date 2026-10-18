// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import GameController
import Testing

@testable import MokumeCore
@testable import MokumeGamepad

/// 走っている実行へ足せない所 (`setup()`・`draw()`・入力のコールバックの外) から、ゲームパッドの口を呼ぶ ([#2837])。
///
/// **呼んだ口の名前で言う。** 以前は作る口の中の ``SketchPart/attach(_:)-(Inlet)`` が黙って `false` を返し、
/// 警告は利用者が呼んでいない `attach()` を名乗っていた。音と通信の作る口 ([#2740]) と同じ形に揃える。
/// ゲームパッドの口は投げない — 今までどおり足されていないパッドを返し、口の名前で 1 度だけ言う。
///
/// 走らせずに警告することを見るので、GPU は要らない。機材も要らない (仮の機材と記録した入力を使う)。
///
/// [#2740]: https://github.com/mokume-metal/mokume/issues/2740
/// [#2837]: https://github.com/mokume-metal/mokume/issues/2837
@MainActor
@Suite("走っている実行の外から呼んだゲームパッドの口")
struct GamepadOutsideRunTests {
    /// 走らせないスケッチ。
    final class Bare: Sketch {
        init() {}
        func draw() {}
    }

    @Test("createGamepad(inputs:) は、足されていないパッドを返し、呼んだ口の名前で 1 度だけ警告する")
    func recordedPadWarnsByItsOwnName() {
        let log = OutsideRun()
        OutsideRun.$current.withValue(log) {
            let sketch = Bare()
            for _ in 0..<2 {
                let pad = sketch.createGamepad(inputs: [GamepadInput(pressed: [.a])])
                // 足されていないので回されず、何も入らない (今までどおり)
                #expect(!pad.isPressed(.a))
                #expect(pad.state == .unavailable)
            }
            #expect(log.messages.count == 1, "2 度呼んでも 1 行")
            let message = log.message(for: "createGamepad(inputs:)")
            #expect(message?.hasPrefix("createGamepad(inputs:) only works inside setup()") == true)
            #expect(message?.contains("was returned instead") == true)
            #expect(log.message(for: "attach") == nil)
            #expect(!log.messages.contains { $0.contains("attach()") })
        }
    }

    @Test("繋がっているパッドが 0 台でも、外で呼んだ gamepads() は 1 度だけ警告する")
    func emptyRosterStillWarns() {
        let hub = GamepadHub(watches: false)
        let log = OutsideRun()
        OutsideRun.$current.withValue(log) {
            let sketch = Bare()
            for _ in 0..<2 {
                let pads = GamepadRoster.roster(for: sketch).gamepads(
                    for: sketch, from: hub, calledAs: "gamepads()")
                #expect(pads.isEmpty)
            }
            #expect(log.messages.count == 1, "2 度呼んでも 1 行")
            let message = log.message(for: "gamepads()")
            #expect(message?.hasPrefix("gamepads() only works inside setup()") == true)
            #expect(message?.contains("was returned instead") == true)
        }
    }

    @Test("gamepads() の一覧は、足されていないパッドを返し、口の名前を渡されて 1 度だけ警告する")
    func rosterWarnsByTheNameItIsGiven() throws {
        let hub = GamepadHub(watches: false)
        hub.connected(GCController.withExtendedGamepad())
        let log = OutsideRun()
        try OutsideRun.$current.withValue(log) {
            let sketch = Bare()
            for _ in 0..<2 {
                let pads = GamepadRoster.roster(for: sketch).gamepads(
                    for: sketch, from: hub, calledAs: "gamepads()")
                #expect(pads.count == 1)
                let pad = try #require(pads.first)
                #expect(pad.state == .unavailable)
            }
            #expect(log.messages.count == 1, "2 度呼んでも 1 行")
            let message = log.message(for: "gamepads()")
            #expect(message?.hasPrefix("gamepads() only works inside setup()") == true)
            #expect(message?.contains("was returned instead") == true)
            #expect(log.message(for: "attach") == nil)
            #expect(!log.messages.contains { $0.contains("attach()") })
        }
    }
}
