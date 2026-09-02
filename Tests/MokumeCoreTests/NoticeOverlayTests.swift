// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import AppKit
import Foundation
import Testing

@testable import MokumeCore

/// 絵に重ねる 1 行の置き方。
///
/// **窓を立てずに検められる形にしてある。** 大きさと置き場所を決める規則を AppKit の
/// 描画の中へ埋めると、正しいかどうかは画面を見るまで分からなくなる (`KnobOverlay` と同じ)。
@Suite("重ねる 1 行 (置き方)")
@MainActor
struct NoticeOverlayLayoutTests {
    @Test("回っている印を出さないなら、その幅も間も取らない")
    func withoutMarkTakesNoRoom() {
        let with = NoticeOverlay.size(textWidth: 100, textHeight: 14, spinning: true)
        let without = NoticeOverlay.size(textWidth: 100, textHeight: 14, spinning: false)
        #expect(with.width - without.width == NoticeOverlay.markSide + NoticeOverlay.gap)
    }

    @Test("下の左に留まる")
    func sitsAtBottomLeft() {
        let host = NSRect(x: 0, y: 0, width: 400, height: 300)
        let frame = NoticeOverlay.frame(in: host, size: NSSize(width: 180, height: 30))
        #expect(frame.minX == NoticeOverlay.inset)
        #expect(frame.minY == NoticeOverlay.inset)
    }

    /// **窓を縮めても、はみ出さない。** つまみ (`KnobOverlay`) が丈を詰めるのと同じ理由で、
    /// 幅を詰める。
    @Test("窓より広くはならない")
    func neverWiderThanTheWindow() {
        let host = NSRect(x: 0, y: 0, width: 120, height: 300)
        let frame = NoticeOverlay.frame(in: host, size: NSSize(width: 400, height: 30))
        #expect(frame.maxX <= host.width - NoticeOverlay.inset)
    }
}

/// 出す・畳むの切り替え。
@Suite("重ねる 1 行 (出し入れ)")
@MainActor
struct NoticeOverlayVisibilityTests {
    @Test("行を渡すと出て、渡さないと畳む")
    func showsAndHides() {
        let notice = NoticeOverlay()
        #expect(notice.isHidden)
        notice.show("作っている…", spinning: true)
        #expect(!notice.isHidden)
        #expect(notice.line == "作っている…")
        notice.show(nil, spinning: false)
        #expect(notice.isHidden)
    }

    /// **回るかどうかは呼ぶ側が決める。** 終わったのに回り続ける印は、作り直しが
    /// 終わっていないと読める。
    @Test("回っている印は、言われたときだけ出る")
    func spinsOnlyWhenAsked() {
        let notice = NoticeOverlay()
        notice.show("作り直している…", spinning: true)
        #expect(notice.isSpinning)
        notice.show("作り直しに失敗", spinning: false)
        #expect(!notice.isSpinning)
    }
}
