// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Testing

@testable import MokumeCore

/// 速さの測り方 (#510)。時計を渡せる形にしてあるので、実機を待たずに固定できる。
@Suite("速さを測る窓")
struct FrameRateWindowTests {
    /// **起動直後に 0.0 と名乗らせない。** これは実測で踏んだ形で、窓の起点を待つ前に
    /// 閉じると「1 枚 ÷ 待っていた時間」が 0.0 として出てしまう。
    @Test("1 つも窓が閉じていないうちは、測れていない")
    func nothingIsReportedBeforeTheFirstWindowCloses() {
        var window = FrameRateWindow()
        #expect(window.current(now: 100) == nil)

        window.advance(now: 100)  // 最初の 1 枚は窓を開くだけ
        #expect(window.current(now: 100) == nil, "起点を置いただけで測れたことにしない")

        window.advance(now: 100.5)
        #expect(window.current(now: 100.5) == nil, "窓が閉じる前は測れていない")
    }

    @Test("窓が閉じたら、その間の速さが測れる")
    func aClosedWindowGivesTheRate() {
        var window = FrameRateWindow()
        window.advance(now: 0)
        for index in 1...30 {
            window.advance(now: Double(index) / 30)
        }
        let rate = try? #require(window.current(now: 1))
        #expect(rate.map { abs($0 - 30) < 0.001 } == true, "1 秒で 30 枚 → 30 fps")
    }

    /// **止まったスケッチが古い数字を名乗らない。**
    @Test("進まなくなったら、測れていないへ戻る")
    func aStoppedSketchFallsBackToNothing() {
        var window = FrameRateWindow()
        window.advance(now: 0)
        for index in 1...60 { window.advance(now: Double(index) / 60) }
        #expect(window.current(now: 1) != nil)

        #expect(window.current(now: 1.5) != nil, "窓 1 つぶんの取りこぼしでは欠測にしない")
        #expect(window.current(now: 4) == nil, "進んでいないまま過ぎたら測れていない")
    }
}
