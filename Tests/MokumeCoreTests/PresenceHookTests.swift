// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Testing

@testable import MokumeCore

/// メニューバーの名乗りの係は外枠が ``SketchRuntime/makePresence`` で差し込む (#3804)。ランタイムは差し込みより
/// 先に触られても、作れなかったことを覚えず、差し込んだ後の読みで作る。
@Suite(
    "名乗りの係を作る口",
    .enabled(if: RenderDevice.isAvailable, "ランタイムを組むのに Metal の装置が要る"))
@MainActor
struct PresenceHookTests {
    @Test("差し込む前に触っても、差し込んだ後の読みで係を作り、作れた係は 2 度作らない")
    func presenceIsMadeAfterALateInstall() throws {
        let saved = SketchRuntime.makePresence
        defer { SketchRuntime.makePresence = saved }
        SketchRuntime.makePresence = { _ in nil }
        let runtime = try SketchRuntime(sketch: Blank(), gpu: RenderDevice())
        defer { runtime.closePlugins() }
        // 差し込む前に触る
        #expect(!runtime.isPresenceAnnounced)

        let made = Counter()
        SketchRuntime.makePresence = { _ in
            made.count += 1
            return Announced()
        }
        #expect(runtime.isPresenceAnnounced, "差し込む前に触ったことで、差し込んだ係が使われなくなった")
        #expect(runtime.isPresenceAnnounced)
        #expect(made.count == 1, "作れた係を覚えず、読むたびに作った")
    }

    @MainActor
    private final class Counter {
        var count = 0
    }

    /// いつも名乗っている係。
    @MainActor
    private final class Announced: PresenceAnnouncing {
        var isAnnounced: Bool { true }
        var receivers: [String] = []
        func advanced(runningFor elapsed: Double) {}
    }

    private final class Blank: Sketch {
        init() {}
        let settings = SketchSettings(width: 16, height: 16)
    }
}
