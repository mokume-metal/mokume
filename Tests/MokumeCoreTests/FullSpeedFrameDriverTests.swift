// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation
import Testing

@testable import MokumeCore

/// 画面を持たない全速の駆動 ([#3474](https://github.com/mokume-metal/mokume/issues/3474))。
///
/// **画面も GPU も要らない。** 進められた回数を数える持ち主を渡し、main の run loop を回して見る。
/// 書き出しの経路に繋いだときの振る舞い (宣言に縛られない・途中で止められる) は
/// `SketchApplicationRenderTests` が見る。
@Suite("画面を持たない全速の駆動")
@MainActor
struct FullSpeedFrameDriverTests {
    /// 進められた回数だけ数える持ち主。
    @MainActor private final class Counter: ScreenDisplayLinkOwner {
        var advances = 0
        /// 運ばれた表示の予定の時刻。全速の駆動は持たないので、全部 `nil` のはず。
        var displayTimes: [Double?] = []
        func displayLinkFired(at displayTime: Double?) {
            advances += 1
            displayTimes.append(displayTime)
        }
    }

    /// run loop の 1 回ごとに数える見張り。**`beforeTimers` は眠らずに回る回にも出る**
    /// (`beforeWaiting` / `afterWaiting` は眠る回にしか出ない)。
    @MainActor private final class PassCounter {
        var passes = 0
    }

    /// 条件が揃うまで main の run loop を回す。**待つ側が期限を持つ。**
    private func runMainLoop(until done: () -> Bool, deadline seconds: Double = 10) {
        let end = Date(timeIntervalSinceNow: seconds)
        while !done(), Date() < end {
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.01))
        }
    }

    /// **1 枚ごとに run loop へ戻る。** 1 回の発火で何枚も進める密なループにすると、終わりの合図
    /// (`pollStopSignal()`) も AppKit の終わりの経路も、ループを抜けるまで回らない (ADR-0032 決定 1)。
    @Test("run loop の 1 回に 1 度だけ進め、表示の予定の時刻は渡さない")
    func itAdvancesOncePerRunLoopPass() throws {
        let driver = FullSpeedFrameDriver()
        let counter = Counter()
        driver.owner = counter
        let passes = PassCounter()
        let observer = try #require(
            CFRunLoopObserverCreateWithHandler(
                nil, CFRunLoopActivity.beforeTimers.rawValue, true, 0
            ) { _, _ in MainActor.assumeIsolated { passes.passes += 1 } })
        CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
        defer { CFRunLoopRemoveObserver(CFRunLoopGetMain(), observer, .commonModes) }

        driver.start()
        // **2 度据えても 2 本にしない** — 2 本回ると、1 回の run loop で 2 枚進む
        driver.start()
        defer { driver.invalidate() }
        #expect(driver.isAttached)
        runMainLoop(until: { counter.advances >= 200 })
        let advanced = counter.advances
        let passed = passes.passes

        try #require(advanced >= 200, "期限までに 200 回進めていない (\(advanced))")
        #expect(
            advanced <= passed,
            "run loop の \(passed) 回のうちに \(advanced) 回進めた — 1 回に 2 度以上進めている")
        #expect(counter.displayTimes.allSatisfy { $0 == nil }, "全速の駆動が表示の予定の時刻を渡した")
    }

    @Test("畳んだら、run loop を回しても進めない")
    func itStopsWhenInvalidated() {
        let driver = FullSpeedFrameDriver()
        let counter = Counter()
        driver.owner = counter
        driver.start()
        runMainLoop(until: { counter.advances >= 5 })
        driver.invalidate()
        #expect(!driver.isAttached)
        let stopped = counter.advances
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
        #expect(counter.advances == stopped, "畳んだ後に \(counter.advances - stopped) 回進めた")
        // 何度畳んでもよい
        driver.invalidate()
    }

    /// **持ち主を弱く持つ** (``ScreenDisplayLink/owner`` と同じ理由・#738)。持ち主が消えても、
    /// 回り続けて落ちることはない。
    @Test("持ち主が消えたら、進める先は無くなり、回しても落ちない")
    func itDoesNotKeepItsOwnerAlive() {
        let driver = FullSpeedFrameDriver()
        var counter: Counter? = Counter()
        driver.owner = counter
        counter = nil
        #expect(driver.owner == nil)
        driver.start()
        defer { driver.invalidate() }
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.02))
    }
}
