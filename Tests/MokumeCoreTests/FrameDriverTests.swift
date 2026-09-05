// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Testing

@testable import MokumeCore

/// 表示のリフレッシュが止まっても進め続けるための判断
/// ([#874](https://github.com/mokume-metal/mokume/issues/874))。
///
/// **GPU も画面も要らない。** 判断だけを純関数に切り出してあるので、ディスプレイを
/// 実際にスリープさせずにここで固定できる — 実機の確認は
/// `scripts/check-observation-roundtrip.sh --display-asleep` が担う。
@Suite("フレームの駆動")
struct FrameDriverTests {
    private let rate = 60
    private var threshold: Double { FrameDriver.stallThreshold(frameRate: rate) }

    @Test("表示のリフレッシュが生きている間、予備は何もしない")
    func staysQuietWhileTheDisplayLinkIsAlive() {
        // 1 フレームぶんしか経っていない = 誰かが進めている
        #expect(
            !FrameDriver.shouldAdvanceFromFallback(
                now: 100 + 1 / Double(rate), lastAdvancedAt: 100,
                stallThreshold: threshold, isAlreadyDriving: false))
    }

    @Test("誰も進めなくなったら、予備が引き受ける")
    func takesOverWhenNothingHasAdvanced() {
        #expect(
            FrameDriver.shouldAdvanceFromFallback(
                now: 100 + threshold * 2, lastAdvancedAt: 100,
                stallThreshold: threshold, isAlreadyDriving: false))
    }

    /// **一度引き受けたら、経過によらず進め続ける。** 経過だけで判断すると、自分が
    /// 進めた直後は必ず「進んでいる」になるので、止まっている間のフレームレートが
    /// 閾値ぶんに落ちる (60 fps を求めたスケッチが 15 fps になる)。
    @Test("引き受けている間は、進めた直後でも続ける")
    func keepsDrivingOnceItTookOver() {
        #expect(
            FrameDriver.shouldAdvanceFromFallback(
                now: 100.001, lastAdvancedAt: 100,
                stallThreshold: threshold, isAlreadyDriving: true))
    }

    /// 固定値にすると、遅いフレームレートを求めたスケッチで**1 枚ぶんの間隔が閾値を
    /// 越えて**しまい、表示のリフレッシュが生きていても予備が割り込む。
    @Test(
        "止まったとみなす間は、目標フレームレートに追随する",
        arguments: [10, 24, 30, 60, 120])
    func stallThresholdFollowsTheTargetFrameRate(frameRate: Int) {
        let interval = 1 / Double(frameRate)
        let threshold = FrameDriver.stallThreshold(frameRate: frameRate)
        // 1 枚ぶん遅れただけでは割り込まない
        #expect(
            !FrameDriver.shouldAdvanceFromFallback(
                now: 100 + interval, lastAdvancedAt: 100,
                stallThreshold: threshold, isAlreadyDriving: false))
        // 予備が回る間隔は、そのまま止まっている間のフレームレートになる
        #expect(abs(FrameDriver.fallbackInterval(frameRate: frameRate) - interval) < 1e-9)
    }

    @Test("フレームレートに 0 以下が来ても、判断は壊れない")
    func survivesNonsenseFrameRates() {
        #expect(FrameDriver.stallThreshold(frameRate: 0) > 0)
        #expect(FrameDriver.fallbackInterval(frameRate: -1) > 0)
    }
}
