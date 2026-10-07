// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Testing

@testable import MokumeCore

/// `setup()` で読んだ時刻の出どころを控えるスケッチ。
private final class ClockReading: Sketch {
    nonisolated(unsafe) static var seen: [Clock] = []
    init() {}
    var settings: SketchSettings { SketchSettings(width: 8, height: 8) }
    func setup() { Self.seen.append(clock) }
    func draw() {}
}

/// 時刻の出どころを読む口 (#1979)。走っているスケッチの中で読むので GPU を要する。
@Suite(
    "時刻の出どころ",
    .serialized,
    .enabled(
        if: RenderDevice.isAvailable,
        "この世代のコマンド構造に対応した GPU が無い実行環境ではスキップする")
)
struct SketchClockTests {
    @Test("窓を開かずに回すとフレームの数え方を、差し替えた時計ならその時計を名乗る")
    func clockNamesTheSource() throws {
        ClockReading.seen = []
        for clock in [nil, Clock.frameIndex(frameRate: 24), .wallClock] {
            let runtime = try SketchRuntime(sketch: ClockReading(), gpu: try RenderDevice(), clock: clock)
            try runtime.advance()
            runtime.closePlugins()
        }
        #expect(ClockReading.seen == [.frameIndex(frameRate: 60), .frameIndex(frameRate: 24), .wallClock])
    }
}
