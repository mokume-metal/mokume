// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Testing

@testable import frame_rate_probe

/// 測り始める前の準備に失敗したとき、名乗って落ちること (#2541)。
///
/// 裸の `try` のままだと Swift ランタイムの既定処理へ落ち、`Fatal error: Error raised at top
/// level: …` と内部の姿をそのまま出して trap していた。
@Suite("frame-rate-probe の起動失敗")
struct ProbeStartupTests {
    /// 描画の土台が投げる失敗の代役。**中身を持つのは失敗の側** (`RenderFailure` は
    /// 何が足りないかと次にすることを自分の文面に持つ) なので、道具はそれを書き換えない。
    private struct Stub: Error, CustomStringConvertible {
        let description: String
    }

    @Test("見出しと失敗の中身を出し、ランタイムの既定の文面を使わない")
    func namesWhatFailedAndWhy() {
        let message = ProbeStartup.message(for: Stub(description: "Cannot find the source of a shader: probe.metal"))
        #expect(message.hasPrefix(ProbeStartup.headline + "\n"))
        // 失敗の中身 (何が足りないか) が、そのまま載る
        #expect(message.contains("Cannot find the source of a shader: probe.metal"))
        #expect(message.hasSuffix("\n"))
        #expect(!message.contains("Fatal error"))
        #expect(!message.contains("Error raised at top level"))
    }
}
