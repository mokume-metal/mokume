// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Testing

@testable import MokumeCore

/// 駆動源と、その予備 ([#874](https://github.com/mokume-metal/mokume/issues/874)・
/// [#1279](https://github.com/mokume-metal/mokume/issues/1279))。
///
/// **画面も GPU も要らない。** 表示のリフレッシュと予備の機会を時刻付きで叩けるので、
/// ディスプレイを実際にスリープさせずにここで固定できる — 実機の確認は
/// `scripts/check-observation-roundtrip.sh --display-asleep` と、見張りの入れ替わりの
/// 実測 (#1279 の PR) が担う。
///
/// 判断そのもの (`FrameDriver`) は `FrameDriverTests` が見る。こちらが見るのは**回す側**で、
/// 持ち主がいつ進められるかである。
@Suite("フレームの駆動源")
@MainActor
struct ScreenDisplayLinkTests {
    /// 進められた回数だけ数える持ち主。
    @MainActor private final class Counter: ScreenDisplayLinkOwner {
        var advances = 0
        func displayLinkFired() { advances += 1 }
    }

    private let rate = 60
    private var interval: Double { FrameDriver.fallbackInterval(frameRate: 60) }

    /// 駆動源と持ち主を組にして返す。**持ち主はこちらで持つ** (駆動源は弱く持つ)。
    private func makeLink(frameRate: Float? = 60) -> (ScreenDisplayLink, Counter) {
        let link = ScreenDisplayLink(frameRate: frameRate)
        let counter = Counter()
        link.owner = counter
        return (link, counter)
    }

    /// **二重に回ると、絵を出す枚数と入れ替わりの判定が二重になる。** 予備は表示の
    /// リフレッシュと同じ間隔で機会を得るので、そこで進めないことがこの機構の前提である。
    @Test("表示のリフレッシュが来ている間、予備は 1 回も進めない")
    func theFallbackStaysQuietWhileTheDisplayLinkIsAlive() {
        let (link, counter) = makeLink()
        var now = 100.0
        for _ in 0..<60 {
            link.advanceFromDisplayLink(at: now)
            // 同じ刻みで予備にも機会が回る (どちらも目標フレーム間隔で叩かれる)
            link.advanceFromFallbackIfStalled(at: now)
            now += interval
        }
        #expect(counter.advances == 60, "表示のリフレッシュの回数より多く進めている")
    }

    /// 画面が眠ると垂直同期ごと止まる。**進んでいなければ、予備が進める。**
    @Test("表示のリフレッシュが途切れたら、予備が引き受ける")
    func theFallbackTakesOverWhenTheDisplayLinkStops() {
        let (link, counter) = makeLink()
        link.advanceFromDisplayLink(at: 100)
        #expect(counter.advances == 1)

        // まだ 1 枚ぶんしか経っていない = 止まっていない
        link.advanceFromFallbackIfStalled(at: 100 + interval)
        #expect(counter.advances == 1)

        let threshold = FrameDriver.stallThreshold(frameRate: rate)
        link.advanceFromFallbackIfStalled(at: 100 + threshold * 2)
        #expect(counter.advances == 2, "止まっているのに誰も進めていない")
    }

    /// **引き受けている間は、目標フレーム間隔ごとに進める。** 経過だけで判断すると、
    /// 自分が進めた直後は必ず「進んでいる」になり、止まっている間のフレームレートが
    /// 閾値ぶんに落ちる (60 fps を求めたスケッチが 15 fps になる)。
    @Test("引き受けている間は、目標フレーム間隔ごとに進み続ける")
    func theFallbackKeepsTheTargetFrameRateWhileItDrives() {
        let (link, counter) = makeLink()
        link.advanceFromDisplayLink(at: 100)
        var now = 100 + FrameDriver.stallThreshold(frameRate: rate) * 2
        for _ in 0..<30 {
            link.advanceFromFallbackIfStalled(at: now)
            now += interval
        }
        #expect(counter.advances == 31, "予備が間隔ぶん進めていない")
    }

    /// 画面が戻れば、そちらが進める。**下りないと二重に回る。**
    @Test("表示のリフレッシュが戻ったら、予備は下りる")
    func theFallbackStepsDownWhenTheDisplayLinkReturns() {
        let (link, counter) = makeLink()
        link.advanceFromDisplayLink(at: 100)
        link.advanceFromFallbackIfStalled(at: 100 + FrameDriver.stallThreshold(frameRate: rate) * 2)
        #expect(counter.advances == 2)

        var now = 200.0
        link.advanceFromDisplayLink(at: now)
        #expect(counter.advances == 3)
        for _ in 0..<10 {
            link.advanceFromFallbackIfStalled(at: now)
            now += interval
            link.advanceFromDisplayLink(at: now)
        }
        #expect(counter.advances == 13, "表示のリフレッシュが戻ったのに予備も進めている")
    }

    /// **速さを据えないのは絵を作っていない側** (別のプロセスの絵を出す台) である。画面が
    /// 眠っている間は任せる先が無いので、そこでも予備は回る — 見張りの世代の入れ替わりが
    /// この駆動に載っている (#1279)。
    @Test("速さを据えていない駆動源でも、止まれば予備が引き受ける")
    func theFallbackDrivesLinksThatFollowTheScreensRate() {
        let (link, counter) = makeLink(frameRate: nil)
        link.advanceFromDisplayLink(at: 100)
        let threshold = FrameDriver.stallThreshold(frameRate: FrameDriver.unspecifiedFrameRate)
        link.advanceFromFallbackIfStalled(at: 100 + threshold / 2)
        #expect(counter.advances == 1, "止まっていないのに割り込んでいる")
        link.advanceFromFallbackIfStalled(at: 100 + threshold * 2)
        #expect(counter.advances == 2, "止まっているのに誰も進めていない")
    }

    /// **持ち主を弱く持つ。** 環になると、手放した持ち主が解放されないまま駆動源が
    /// 回り続ける ([#738](https://github.com/mokume-metal/mokume/issues/738))。
    @Test("持ち主が消えたら、進める先は無くなる")
    func theLinkDoesNotKeepItsOwnerAlive() {
        let link = ScreenDisplayLink(frameRate: 60)
        var counter: Counter? = Counter()
        link.owner = counter
        counter = nil
        #expect(link.owner == nil)
        // 進める先が無くても落ちない (予備の刻みはタイマーから来るので、ここを通りうる)
        link.advanceFromFallbackIfStalled(at: 1_000)
    }
}
