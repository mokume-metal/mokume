// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation
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
        // 最初の赤から原因を辿れるよう、どの待ちがどの期限を越えたかを控える。畳む時の待ちは投げない
        // ので、控えが無いと原因の検査は緑のまま埋もれる
        #expect(gate.closure?.wait == .takingDown, "控えた待ちの種類が違う: \(String(describing: gate.closure))")
        #expect(gate.closure?.limit == .milliseconds(50))
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

/// 印を立てた後の名乗り。GPU は要らない (関所だけを相手にする)。
///
/// 見ているのは 2 つ (#2052 の反証)。
/// - **描きすぎの場合もあると名乗る。** 期限を越えた待ちからは、重い 1 フレームと答えない GPU を
///   見分けられない。同じ期限切れで `.timedOut` が「描きすぎ」と言うので、片方だけを言い切ると食い違う
/// - **最初に期限を越えた待ちを添える。** 印が立つと、以後の GPU の検査はすべて同じ断りで赤になる。
///   どの赤からも、原因の待ちの種類・期限・時刻が読めなければならない
///
/// `RenderFailure.gpuNotResponding.description` がプロセスの関所を読むことは、ここでは確かめない。
/// 確かめるにはプロセスの関所に印を立てることになり、同じプロセスの残りの GPU の検査が断られる。
@Suite("期限切れの後の名乗り")
struct CommandQueueGateWordingTests {
    private static let first = Date(timeIntervalSince1970: 1_791_000_000)

    @Test("関所が控えるのは最初に期限を越えた待ちだけ")
    func theGateKeepsTheFirstWaitOnly() {
        let gate = CommandQueueGate()
        #expect(gate.closure == nil)
        #expect(gate.close(after: .finishing, limit: .seconds(5), at: Self.first))
        #expect(!gate.close(after: .takingDown, limit: .seconds(5), at: Self.first + 60))
        #expect(gate.closure == .init(wait: .finishing, limit: .seconds(5), date: Self.first))
        #expect(gate.isClosed)
    }

    @Test("断りの 1 行目が、最初に期限を越えた待ちの種類・期限・時刻を名乗る")
    func theRefusalNamesTheFirstWait() {
        let closure = CommandQueueGate.Closure(wait: .takingDown, limit: .seconds(5), date: Self.first)
        let text = RenderFailure.notResponding(after: closure)
        let headline = String(text.prefix { $0 != "\n" })
        #expect(headline.contains("while taking down a drawing foundation"), "\(headline)")
        #expect(headline.contains("past \(Duration.seconds(5))"), "\(headline)")
        #expect(
            headline.contains(Self.first.formatted(Date.ISO8601FormatStyle(timeZone: .current))), "\(headline)")
        // 控えが無ければ、添えるものは無い
        #expect(!RenderFailure.notResponding(after: nil).contains("the first was"))
    }

    @Test("断りも印を立てた時の 1 行も、描きすぎの場合もあると名乗って起こし直しへ送る")
    func bothSidesNameTheHeavyFrameToo() {
        let refusal = RenderFailure.notResponding(after: nil)
        let notice = RenderDevice.closingNotice(after: .finishing, limit: .seconds(5))
        for text in [refusal, notice] {
            #expect(text.contains("one frame drawing too much"), "\(text)")
            #expect(text.contains("stopped answering"), "\(text)")
            #expect(text.contains("start"), "\(text)")
        }
        #expect(notice.contains("while waiting for the GPU to finish"))
        #expect(!notice.contains("\n"), "印を立てた時の警告が 1 行に収まっていない")
    }

    @Test("描けるようになっても、印が残っていれば言い添える")
    func theRecoveryNoticeMentionsTheMark() {
        let plain = SketchApplication.recoveryNotice(skipped: 3, gate: nil)
        #expect(plain == "Drawing has recovered (3 frames were skipped)")
        let closure = CommandQueueGate.Closure(wait: .finishing, limit: .seconds(5), date: Self.first)
        let marked = SketchApplication.recoveryNotice(skipped: 3, gate: closure)
        #expect(marked.hasPrefix(plain))
        #expect(marked.contains("still sets up no new drawing foundation"), "\(marked)")
        #expect(!marked.contains("\n"))
    }
}
