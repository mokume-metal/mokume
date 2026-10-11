// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation
import Testing

@testable import MokumeNetwork

/// 受け口が持つ送り元の台帳 (#2225)。繋ぎも時計も使わず、閉じる判断と数だけを見る。
@Suite("送り元の台帳")
struct SenderLedgerTests {
    /// 台帳に載せる送り元の代わり。
    final class Peer {
        let name: String
        init(_ name: String) { self.name = name }
    }

    @Test("まだ 1 度も読んでいない送り元は、受け入れから idleAfter 秒を越えても閉じない")
    func unreadSendersAreNotClosed() {
        var ledger = SenderLedger<Peer>(limit: 2, idleAfter: 1)
        let read = Peer("read")
        let unread = Peer("unread")
        let next = Peer("next")
        let last = Peer("last")
        #expect(ledger.admit(read, at: 0).isEmpty)
        #expect(ledger.admit(unread, at: 0).isEmpty)
        ledger.heard(read, at: 0)

        // 目安 (2) に達したところへ 5 秒後に新しい送り元が来たら、読んだうえで黙った送り元だけを
        // 閉じる。受け入れたまま読んでいない送り元 (待ち行列が混んでいるとき) には、読む前の
        // datagram がある — 閉じるとそれごと捨てる
        #expect(ledger.admit(next, at: 5).map(\.name) == ["read"])
        #expect(ledger.count == 2)

        // 読めば、そこから黙りを測る。ちょうど idleAfter 秒黙れば閉じる (読んでいない next は残る)
        ledger.heard(unread, at: 5)
        #expect(ledger.admit(last, at: 6).map(\.name) == ["unread"])
        #expect(ledger.count == 2)
        #expect(ledger.tally == SenderTally(accepted: 4, closedIdle: 2, ended: 0))
    }

    @Test("失敗・取り消しで外れた送り元を数え、黙りで閉じた後の取り消しの知らせは数え直さない")
    func endedSendersAreCountedOnce() {
        var ledger = SenderLedger<Peer>(limit: 1, idleAfter: 1)
        let first = Peer("first")
        let second = Peer("second")
        #expect(ledger.admit(first, at: 0).isEmpty)
        ledger.heard(first, at: 0)
        #expect(ledger.admit(second, at: 1).map(\.name) == ["first"])

        // 閉じた繋ぎからも「取り消された」が届く。台帳にはもう居ないので数えない
        ledger.ended(first)
        // 失敗で終わった繋ぎは外して数える
        ledger.ended(second)
        #expect(ledger.count == 0)
        #expect(ledger.tally == SenderTally(accepted: 2, closedIdle: 1, ended: 1))
    }

    @Test("持っているかは、受け入れから、黙りで閉じる・外れる・全部外すまでの間だけ真")
    func holdsOnlyAdmittedSenders() {
        // 受け口は、黙りで閉じた繋ぎの待っていた受けが空のように返るのを、これで見分ける
        var ledger = SenderLedger<Peer>(limit: 1, idleAfter: 1)
        let idle = Peer("idle")
        let ended = Peer("ended")
        let kept = Peer("kept")
        #expect(!ledger.holds(idle))
        #expect(ledger.admit(idle, at: 0).isEmpty)
        #expect(ledger.holds(idle))
        ledger.heard(idle, at: 0)
        #expect(ledger.admit(ended, at: 1).map(\.name) == ["idle"])
        #expect(!ledger.holds(idle))
        #expect(ledger.holds(ended))
        ledger.ended(ended)
        #expect(!ledger.holds(ended))
        #expect(ledger.admit(kept, at: 2).isEmpty)
        _ = ledger.removeAll()
        #expect(!ledger.holds(kept))
    }
}
