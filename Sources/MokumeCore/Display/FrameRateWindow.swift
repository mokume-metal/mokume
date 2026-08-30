// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

/// 1 秒ごとに閉じる窓で、進めたフレームを数える。
///
/// **時計を外から受け取る。** 速さの測り方は「いつ測れていて、いつ測れていないか」が
/// 肝で、そこは実機を待たずに固定できる必要がある。
///
/// ## 起点を 0 のままにしない
///
/// 起点を 0 に置いたまま 1 枚目を迎えると、「1 枚 ÷ 起動からの長い時間」が窓 1 つぶんとして
/// 閉じ、**0.0 という嘘の数字**になる。0 は「測ったら 0 だった」と読めるが、実際はまだ
/// 測れていない。最初のフレームは**窓を開くだけ**にする。
struct FrameRateWindow {
    /// 窓が閉じる長さ (秒)。
    static let length: Double = 1

    /// 測ってからこれだけ過ぎたら、測れていないとみなす (秒)。窓 1 つぶんの
    /// 取りこぼしでは欠測にしない。
    static let staleAfter: Double = 2

    /// いま開いている窓の起点。**まだ 1 枚も来ていなければ無い。**
    ///
    /// 「無い」を 0 で表さない — 時計の原点は値として有効でありうるし、この型が扱って
    /// いるのは**まさに「測れていないことを数字に化けさせない」**という話である。
    private var start: Double?
    private var count = 0

    /// 直近に閉じた窓の速さ。測る道具が読む。
    private(set) var rate: Double = 0
    /// 直近に窓を閉じた時刻。まだ 1 つも閉じていなければ無い。
    private(set) var measuredAt: Double?

    /// フレームを 1 枚進めた。
    mutating func advance(now: Double) {
        guard let opened = start else {
            start = now
            return
        }
        count += 1
        let elapsed = now - opened
        guard elapsed >= Self.length else { return }
        rate = Double(count) / elapsed
        measuredAt = now
        count = 0
        start = now
    }

    /// 名乗ってよい速さ。**測れていなければ `nil`。**
    ///
    /// 止まったスケッチは最後の値を残し続けるので、時刻で古さを見る。
    func current(now: Double) -> Double? {
        guard let measuredAt, now - measuredAt < Self.staleAfter else { return nil }
        return rate
    }
}
