// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

/// フレームがどれだけの速さで進んでいるかを数える、**ただ 1 つの集計器**。
///
/// 窓に出る数字も、観測の応答が返す数字も、ここから採る ([ADR-0030] 決定 7)。
/// **同じ意味の値を 2 か所で計算した時点で、いつか食い違う** — しかも食い違ったときに
/// 「どちらが正しいか」を決める根拠がどこにも無い。人が窓を見て話し、エージェントが面を
/// 読んで話すとき、2 人が違う数字を見ていて、どちらも「実測」と名乗ることになる。
///
/// **一致させるのは源であって経路ではない。** 窓は読み手であり、自分で平均を取らない。
///
/// ## 「測れていない」を 0 で表さない
///
/// 起点を 0 に置いたまま 1 枚目を迎えると、「1 枚 ÷ 起動からの長い時間」が窓 1 つぶんとして
/// 閉じ、**0.0 という嘘の数字**になる。0 は「測ったら 0 だった」と読めるが、実際はまだ
/// 測れていない。最初のフレームは**間隔を開くだけ**にする。
///
/// 止めたスケッチも同じで、最後に測った値が残り続ける。だから読むときに古さを見て、
/// 古ければ `nil` を返す — 応答は鍵ごと省き、窓は「—」と描く。
///
/// ## 時計を外から受け取る
///
/// 速さの測り方は「いつ測れていて、いつ測れていないか」が肝で、そこは実機を待たずに
/// 固定できる必要がある。
///
/// [ADR-0030]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0030-parameter-surfaces.md
struct FrameTempo {
    /// 何枚ぶん遡って平均するか。
    static let window = 60

    /// 最後に数えてからこれだけ過ぎたら、測れていないとみなす (秒)。
    static let staleAfter: Double = 2

    /// 直近のフレームの間隔 (秒)。
    private var intervals: [Double] = []
    /// 前のフレームが始まった時刻。**まだ 1 枚も来ていなければ無い。**
    private var previousStart: Double?

    /// フレームを 1 枚進めた。
    mutating func record(now: Double) {
        defer { previousStart = now }
        guard let previous = previousStart else { return }
        // 時間が巻き戻ったら数えない (時計を寄せ直した直後など)
        let interval = now - previous
        guard interval > 0 else { return }
        intervals.append(interval)
        if intervals.count > Self.window { intervals.removeFirst() }
    }

    /// いま名乗ってよい速さ。**測れていなければ `nil`。**
    func frameRate(now: Double) -> Double? {
        guard let mean = meanInterval(now: now), mean > 0 else { return nil }
        return 1 / mean
    }

    /// いま名乗ってよいフレーム時間 (ミリ秒)。**測れていなければ `nil`。**
    ///
    /// 最大を平均と別に持つのは、突っかかりが平均に埋もれるからである。
    func frameTimeMs(now: Double) -> (mean: Double, max: Double)? {
        guard let mean = meanInterval(now: now) else { return nil }
        return (mean: mean * 1000, max: (intervals.max() ?? mean) * 1000)
    }

    /// 平均の間隔。数えていない・古すぎるときは `nil`。
    private func meanInterval(now: Double) -> Double? {
        guard !intervals.isEmpty, let last = previousStart else { return nil }
        guard now - last < Self.staleAfter else { return nil }
        return intervals.reduce(0, +) / Double(intervals.count)
    }
}
