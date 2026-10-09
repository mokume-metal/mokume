// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation
import GameController
import Testing

@testable import MokumeCore
@testable import MokumeGamepad

/// 実機の配線を、GameController の仮の機材 (`GCController.withExtendedGamepad()`) で回す。
/// 本物のパッドは要らない。
///
/// 仮の機材は接続の知らせを出さないので、係 (``GamepadHub``) の抜き差しの口を直に呼ぶ。
/// 値は本物と同じく、釦とスティックの handler を通って届く。係は検査ごとに作り、プロセスの
/// 係 (``GamepadHub/shared``) には触れない。
@Suite("ゲームパッドの実機の配線 (仮の機材)", .serialized)
struct GamepadHubTests {
    /// handler は main の待ち行列へ後から積まれる。`condition` が成り立つまで待ち行列を回す。
    ///
    /// **待つ側が期限を持つ** (2 秒)。越えたら偽を返し、検査はそこで落ちる。
    private func settle(_ pad: Gamepad, until condition: () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + .seconds(2)
        while ContinuousClock.now < deadline {
            await withCheckedContinuation { done in DispatchQueue.main.async { done.resume() } }
            pad.supply()
            if condition() { return true }
        }
        return false
    }

    private func pad(_ id: String, on hub: GamepadHub) throws -> Gamepad {
        let pad = Gamepad(id: id, name: "gamepad: \(id)", source: ControllerSource(id: id, hub: hub))
        try pad.open()
        return pad
    }

    @Test("繋がった機材の釦とスティックが、handler を通って入り口へ届く。縦軸は下向きになる")
    func valuesFlowThroughHandlers() async throws {
        let hub = GamepadHub(watches: false)
        let controller = GCController.withExtendedGamepad()
        hub.connected(controller)
        let id = try #require(hub.slots.known.first)
        #expect(id.hasSuffix(" #1"))
        let pad = try pad(id, on: hub)
        #expect(pad.state == .running)

        let gamepad = try #require(controller.extendedGamepad)
        gamepad.buttonA.setValue(1)
        gamepad.leftThumbstick.setValueForXAxis(0.5, yAxis: 0.25)
        #expect(await settle(pad) { pad.isPressed(.a) && pad.leftStick == [0.5, -0.25] })

        gamepad.buttonA.setValue(0)
        #expect(await settle(pad) { !pad.isPressed(.a) })
    }

    @Test("抜くと切断を名乗り、押していた釦は離れる。挿し直すと同じ識別子の同じ入り口が戻る")
    func unplugAndReplug() async throws {
        let hub = GamepadHub(watches: false)
        let first = GCController.withExtendedGamepad()
        hub.connected(first)
        let id = try #require(hub.slots.known.first)
        let pad = try pad(id, on: hub)
        try #require(first.extendedGamepad).buttonA.setValue(1)
        #expect(await settle(pad) { pad.isPressed(.a) })

        hub.disconnected(first)
        pad.supply()
        #expect(pad.state == .disconnected)
        #expect(!pad.isPressed(.a))
        #expect(pad.leftStick == .zero)
        #expect(!hub.slots.isConnected(id))

        // 同じ機種の機材を挿し直す (仮の機材は毎回別の物なので、本物の挿し直しと同じく別の機材として届く)
        let again = GCController.withExtendedGamepad()
        hub.connected(again)
        #expect(hub.slots.known == [id])
        pad.supply()
        #expect(pad.state == .running)
        try #require(again.extendedGamepad).buttonB.setValue(1)
        #expect(await settle(pad) { pad.isPressed(.b) })
    }

    @Test("挿したとき・挿し直したときに押していた釦は、知らせを待たずに押されていると読める")
    func heldWhenPluggedIn() async throws {
        let hub = GamepadHub(watches: false)
        let controller = GCController.withExtendedGamepad()
        try #require(controller.extendedGamepad).buttonX.setValue(1)
        // 押した handler はまだ付いていない。押した知らせが来ないまま繋がる
        await withCheckedContinuation { done in DispatchQueue.main.async { done.resume() } }
        hub.connected(controller)
        let pad = try pad(try #require(hub.slots.known.first), on: hub)
        pad.supply()
        #expect(pad.isPressed(.x))

        // 入り口が繋がったまま抜いて、Y を押したまま挿し直す。押した知らせは来ない
        hub.disconnected(controller)
        pad.supply()
        #expect(!pad.isPressed(.x))
        let again = GCController.withExtendedGamepad()
        try #require(again.extendedGamepad).buttonY.setValue(1)
        await withCheckedContinuation { done in DispatchQueue.main.async { done.resume() } }
        hub.connected(again)
        pad.supply()
        #expect(pad.isPressed(.y))
    }

    @Test("繋がっていない識別子の入り口は、一覧にあれば切断、無ければ機材なしを名乗る")
    func stateOfAbsentPads() throws {
        let hub = GamepadHub(watches: false)
        let controller = GCController.withExtendedGamepad()
        hub.connected(controller)
        let id = try #require(hub.slots.known.first)
        hub.disconnected(controller)
        #expect(try pad(id, on: hub).state == .disconnected)
        #expect(try pad("Nothing #1", on: hub).state == .unavailable)
    }

    @Test("同じ機材の知らせが 2 度来ても、識別子は 1 つ")
    func duplicateConnectIsIgnored() {
        let hub = GamepadHub(watches: false)
        let controller = GCController.withExtendedGamepad()
        hub.connected(controller)
        hub.connected(controller)
        #expect(hub.slots.known.count == 1)
    }

    @Test("閉じた入り口には、その後の値が入らない")
    func closedPadStopsReceiving() async throws {
        let hub = GamepadHub(watches: false)
        let controller = GCController.withExtendedGamepad()
        hub.connected(controller)
        let pad = try pad(try #require(hub.slots.known.first), on: hub)
        let other = try self.pad(try #require(hub.slots.known.first), on: hub)
        pad.close()
        try #require(controller.extendedGamepad).buttonA.setValue(1)
        // もう 1 つの入り口に届くまで待ち、閉じたほうに届いていないことを見る
        #expect(await settle(other) { other.isPressed(.a) })
        pad.supply()
        #expect(!pad.isPressed(.a))
        #expect(pad.state == .stopped)
    }
}
