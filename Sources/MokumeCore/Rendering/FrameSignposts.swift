// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import os

/// フレームの区間を Instruments に見せる印 ([#2378](https://github.com/mokume-metal/mokume/issues/2378))。
///
/// **3 つの区間を張る**: `draw` (作者の `draw()` を呼んでいる間・CPU)・`flush` (描き切り — 積んだ図形を
/// コマンドへ組んで投入するまで・CPU)・`present` (描いた絵を窓または共有面へ差し出すまで・CPU)。
/// Instruments の「Points of Interest」に subsystem `mokume` で並び、フレームの CPU の時間をどこが
/// 食っているかを、同じ時間軸の上で GPU の仕事 (Metal System Trace) と見比べられる。
///
/// **GPU の時間ではない。** 区間が測るのは CPU が各段を抜けるまでで、GPU が走った幅は別に
/// ``RenderDevice/lastGPUFrameTime`` が持つ。
///
/// 張ること自体の代償は 1 フレームあたり数 µs で、予算の 0.02% 前後に収まる (#2378 の実測)。
nonisolated enum FrameSignposts {
    /// 区間の持ち主。`OSSignposter` は `Sendable` で、状態を持たない。
    static let signposter = OSSignposter(
        logHandle: OSLog(subsystem: "mokume", category: .pointsOfInterest))

    /// 作者の `draw()` を呼んでいる間。
    static func beginDraw() -> OSSignpostIntervalState {
        signposter.beginInterval("draw")
    }

    static func endDraw(_ state: OSSignpostIntervalState) {
        signposter.endInterval("draw", state)
    }

    /// 描き切り。
    static func beginFlush() -> OSSignpostIntervalState {
        signposter.beginInterval("flush")
    }

    static func endFlush(_ state: OSSignpostIntervalState) {
        signposter.endInterval("flush", state)
    }

    /// 描いた絵を差し出す。
    static func beginPresent() -> OSSignpostIntervalState {
        signposter.beginInterval("present")
    }

    static func endPresent(_ state: OSSignpostIntervalState) {
        signposter.endInterval("present", state)
    }
}
