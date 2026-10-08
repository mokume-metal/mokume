// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Metal
import Testing

@testable import MokumeCore

/// GPU の待ちが期限を越えたプロセスでは、新しい発行口を作らない
/// ([#2052](https://github.com/mokume-metal/mokume/issues/2052))。GPU を要する。
///
/// #2052 の手順は次の 3 つで、これが約 5 分繰り返されて、止まった発行口が溜まった。
///
/// 1. 待ちを期限で打ち切る
/// 2. 土台を畳む
/// 3. 次の検査が新しい土台 (= 新しい発行口) を作る
///
/// ここでは 1・2 を差し込みで起こし、3 が起きないことを見る。
///
/// **GPU には何も投入しない。** 期限切れは、番号だけを進めた答えの来ない投入
/// (`addUnansweredSubmissionForTesting()`) を待たせて作る。GPU を本当に詰まらせる検査は書かない
/// (#1999・#2052 で、手元機ごと落ちた)。
///
/// **関所は検査ごとに作る。** プロセスで 1 つの関所 (`CommandQueueGate.process`) に印を立てると、
/// 同じプロセスの残りの GPU の検査が、すべて断られる。
@Suite(
    "待ちの期限切れの後の発行口",
    .enabled(
        if: RenderDevice.isAvailable,
        "この世代のコマンド構造に対応した GPU が無い実行環境ではスキップする")
)
struct CommandQueueGateTests {
    @Test("待ちを打ち切って畳んだ後は、2 つ目の土台を作らず、理由を名乗って断る")
    func noSecondFoundationAfterAWaitGaveUp() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw RenderFailure.deviceUnavailable }
        let gate = CommandQueueGate()
        try takeDownWithoutAnAnswer(on: device, through: gate)

        #expect(gate.isClosed, "土台が待ちを打ち切って畳まれたのに、印が立っていない")
        let failure = #expect(throws: RenderFailure.self) {
            _ = try RenderDevice(device: device, slotCount: 1, queueGate: gate)
        }
        #expect(failure == .gpuNotResponding, "名乗りが違う: \(String(describing: failure))")
        // 投げたことだけを見ると、作ってから投げる形に崩れても緑のままになる
        #expect(gate.queuesMade == 1, "印が立った後に発行口を作った (計 \(gate.queuesMade) 本)")

        // 検査の条件 (`isAvailable`) を評価し直しても、使い捨ての発行口を作らない
        #expect(!RenderDevice.isAvailable(on: device, through: gate))
        #expect(gate.queuesMade == 1, "使える環境かを問うだけで発行口を作った (計 \(gate.queuesMade) 本)")
    }

    /// 土台を作り、答えの来ない投入を 1 本足して手放す。`deinit` が待ちを打ち切る (上の手順 1・2)。
    ///
    /// 手放すのは、この関数を抜けるときである。検査は main actor で走るので、`isolated deinit` は
    /// その場で走り終わる。
    private func takeDownWithoutAnAnswer(on device: any MTLDevice, through gate: CommandQueueGate) throws {
        let gpu = try RenderDevice(device: device, slotCount: 1, queueGate: gate)
        gpu.signalWaitLimit = .milliseconds(50)
        gpu.addUnansweredSubmissionForTesting()
        #expect(!gpu.isIdle, "答えの来ない投入を足したのに、終わっていると読める — 畳むときに待たない")
        #expect(gate.queuesMade == 1)
        #expect(!gate.isClosed, "まだ何も待っていないのに、印が立っている")
    }
}
