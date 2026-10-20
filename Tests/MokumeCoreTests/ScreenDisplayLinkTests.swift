// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation
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
        /// 進められた時刻 (`ProcessInfo.systemUptime`)。見張りがいつ引き受けたかを見る検査が読む。
        var times: [Double] = []
        func displayLinkFired() {
            advances += 1
            times.append(ProcessInfo.processInfo.systemUptime)
        }
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

    // MARK: - 見張りの形 (#2368)

    /// 窓も画面も使わない — 画面が無い駆動源 (`attach(to: nil)`) は予備だけが回る。
    ///
    /// **時計の速さを前提にしない。** 混んだ CI 機では、0.6 秒で 20 回の刻みが 12 回しか
    /// 来なかった (#2969 の run 39332498928)。回数が揃うまで回し、期限を越えたら止める。
    /// 刻みを送った時刻を返すので、見張りが起きてよい間 (閾値を越えた刻みの隙間) を
    /// 検査の側で数えられる。
    private func runMainLoop(
        until done: () -> Bool, deadline seconds: Double = 10,
        every tick: Double? = nil, _ body: (@MainActor @Sendable () -> Void)? = nil
    ) -> [Double] {
        let ticks = TickLog()
        var ticker: Timer?
        if let tick, let body {
            let timer = Timer(timeInterval: tick, repeats: true) { _ in
                MainActor.assumeIsolated {
                    ticks.times.append(ProcessInfo.processInfo.systemUptime)
                    body()
                }
            }
            RunLoop.main.add(timer, forMode: .common)
            ticker = timer
        }
        let end = Date(timeIntervalSinceNow: seconds)
        while !done(), Date() < end {
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.02))
        }
        ticker?.invalidate()
        return ticks.times
    }

    @MainActor private final class TickLog { var times: [Double] = [] }

    private var threshold: Double { FrameDriver.stallThreshold(frameRate: rate) }

    /// **見張りが起きてよい回数の上限。** 見張りは最後の刻みから閾値だけ経たないと起きないので、
    /// 隙間が閾値に届かない区間では 0 回、届いた隙間では間隔ごとに 1 回まで。
    /// 時計の読みの差を見込んで、閾値の 9 割から数える。
    private func allowedFallbackAdvances(between times: [Double]) -> Int {
        zip(times, times.dropFirst()).reduce(0) { sum, pair in
            let gap = pair.1 - pair.0
            guard gap >= threshold * 0.9 else { return sum }
            return sum + Int(gap / interval) + 1
        }
    }

    /// **健全な間、予備のタイマーは起きない。** 目標フレーム間隔で回して空振りさせていた頃は、
    /// 表示のリフレッシュの倍の起床だった (tolerance を持たせても減らなかった・#2368)。
    @Test("表示のリフレッシュが来ている間は、予備のタイマーが 1 回も起きない")
    func theWatchdogDoesNotWakeWhileTheDisplayLinkIsAlive() throws {
        let (link, counter) = makeLink()
        let start = ProcessInfo.processInfo.systemUptime
        link.attach(to: nil)
        defer { link.invalidate() }
        let ticks = runMainLoop(until: { counter.advances >= 20 }, every: interval) {
            link.advanceFromDisplayLink()
        }
        let stop = ProcessInfo.processInfo.systemUptime
        try #require(counter.advances >= 20, "期限までにリフレッシュの代わりが 20 回来なかった (\(counter.advances))")
        // 前提: 刻みの隙間 (繋いだ時点と止めた時点を含む) が閾値に届いたなら、そこで起きるのは正しい
        let allowed = allowedFallbackAdvances(between: [start] + ticks + [stop])
        #expect(
            counter.advances - ticks.count <= allowed,
            "健全なのに予備が \(counter.advances - ticks.count) 回進めた (隙間から許す数 \(allowed))")
        if allowed == 0 {
            #expect(link.fallbackFires == 0, "健全なのに予備のタイマーが \(link.fallbackFires) 回起きた")
        }
    }

    /// 途切れたら、閾値の後に起きて、以後は目標フレーム間隔より速くは進めない。戻ったら下りる。
    @Test("表示のリフレッシュが途切れたら、閾値の後に起きて目標フレーム間隔で進める")
    func theWatchdogTakesOverAfterTheThresholdAndKeepsTheRate() throws {
        let (link, counter) = makeLink()
        link.attach(to: nil)
        defer { link.invalidate() }
        // 途切れる前の健全な区間
        let healthy = runMainLoop(until: { counter.advances >= 10 }, every: interval) {
            link.advanceFromDisplayLink()
        }
        try #require(counter.advances >= 10, "期限までに健全な区間の刻みが揃わなかった (\(counter.advances))")
        let before = counter.advances
        let lastTick = try #require(healthy.last)

        // 途切れた。閾値を越えたら引き受けて進める。何回進めたかは時計の速さで変わるので、
        // 回数が揃うまで待ち、かかった時間から速すぎないことを見る
        _ = runMainLoop(until: { counter.advances - before >= 13 })
        let stalledFor = ProcessInfo.processInfo.systemUptime - lastTick
        let taken = counter.advances - before
        try #require(taken >= 13, "途切れた後に予備が引き受けていない (\(taken))")
        let firstTaken = counter.times[before]
        #expect(
            firstTaken - lastTick >= threshold * 0.9,
            "閾値 (\(threshold) 秒) より前に引き受けた (\(firstTaken - lastTick) 秒)")
        #expect(
            taken <= Int(stalledFor / interval) + 2,
            "予備が間隔より速く進めている (\(taken) 回 / \(stalledFor) 秒)")

        // 戻ったら下りる: 最初の刻みより後に進めた回数は、刻みの数と、刻みの隙間が閾値に
        // 届いた分だけに収まる。最初の刻みまでは引き受けたままなので、その間の分は数えない
        let driven = counter.advances
        let resumed = runMainLoop(until: { counter.advances - driven >= 15 }, every: interval) {
            link.advanceFromDisplayLink()
        }
        let stop = ProcessInfo.processInfo.systemUptime
        let firstTick = try #require(resumed.first, "期限までに刻みが戻らなかった")
        let afterReturn = counter.times[driven...].filter { $0 >= firstTick }.count
        try #require(resumed.count >= 10, "期限までに刻みが戻らなかった (\(resumed.count))")
        let allowed = allowedFallbackAdvances(between: resumed + [stop])
        #expect(
            afterReturn - resumed.count <= allowed,
            "表示のリフレッシュが戻ったのに予備も \(afterReturn - resumed.count) 回進めた (隙間から許す数 \(allowed))")
    }
}
