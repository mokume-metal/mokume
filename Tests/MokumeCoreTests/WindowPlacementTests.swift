// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Testing

@testable import MokumeCore

/// 窓の出し方 (#679)。GPU も画面も要らない — 起動の性質から決まるところだけを見る。
///
/// **位置そのものは見ない。** 覚えるのも復元するのも AppKit が持っており、こちらは
/// 「覚えているものがあればそれを使う」と書いただけである。実際に動かないことは
/// 動きの証跡が担う ([ADR-0019](https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0019-drawing-verification.md) 決定 1 と同じ分担)。
@Suite("窓の出し方")
struct WindowPlacementTests {
    /// **合図は版の刻印 1 つ。** 道具が渡すもので、新しい合図を作っていない。
    @Test("刻印が渡されていれば、見張りが起こした入れ替えとみなす")
    func theStampMarksARelaunch() {
        #expect(WindowPlacement.isRelaunch(stamp: "abc123"))
        #expect(!WindowPlacement.isRelaunch(stamp: nil))
    }

    /// **入れ替えでは前面を取らない。** 保存のたびに前面が移ると、打っている手が止まる。
    @Test("前面を取るのは、初めての起動のときだけ")
    func onlyTheFirstLaunchTakesFocus() {
        #expect(WindowPlacement.takesFocus(isRelaunch: false))
        #expect(!WindowPlacement.takesFocus(isRelaunch: true))
    }
}
