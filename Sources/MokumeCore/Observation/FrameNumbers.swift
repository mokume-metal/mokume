// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

/// 窓に出す警告の控え ([#3087](https://github.com/mokume-metal/mokume/issues/3087))。
///
/// 走らせている子 1 つが起動から言った警告の数と、最後の 1 行。**速さの数字と違い、新しい絵が来なくなっても
/// 消さない** — `noLoop()` で絵を書かない間に言った警告は、次に絵を書くまで出ないが、出たら子が入れ替わるまで残る。
struct WarningSummary: Equatable {
    /// 言った警告の数。1 以上 (言っていなければこの型の値を作らない)。
    let count: Int
    /// 最後に言った警告の文面。
    let last: String

    /// 警告の 1 行を省かずに載せ・出す長さ。**書き手 (``SharedFrameSurface``) の切り方と読み手
    /// (``KnobText/warnings(_:)``) の切り方は、この 1 つの定数と ``line(_:)`` を共有する** — 別々に持つと
    /// 片方だけ直したとき、載せる長さと出す長さが静かに食い違う。
    static let lineLimit = 140

    /// 窓に載せ・出す 1 行にする。改行は畳み、長ければ末尾を省く (``lineLimit``)。
    ///
    /// **書き手が載せる前にも通す** ([#3087](https://github.com/mokume-metal/mokume/issues/3087))。警告の文面は
    /// 上限が無く (`Diagnostics.warn` に渡る文は呼ぶ側が決める)、面の属性は毎フレーム書き直すので、無制限の
    /// 文面を載せ続けない。通しても結果は変わらない (読み手が通した結果を、もう一度通しても同じ)。
    static func line(_ text: String) -> String {
        let flat = text.split(whereSeparator: \.isNewline).joined(separator: " ")
        return flat.count > lineLimit ? String(flat.prefix(lineLimit - 1)) + "…" : flat
    }
}

/// 窓に出す数字。
///
/// **速さ・時刻・予算を越えたフレームは、観測の応答と同じ集計器から採る** ([ADR-0030] 決定 7)。窓は読み手であり、
/// 自分で平均を取らない — 一致させるのは源であって経路ではない。**警告の件数と最後の 1 行だけは別の源**で、
/// 観測の `warnings` が持っていく行の控え (``Diagnostics/takeUnreported()``) ではなく、
/// ``Diagnostics/warningSummary()`` から採る ([#3087](https://github.com/mokume-metal/mokume/issues/3087))。
/// 観測の側の控えは読むと空になるので、窓が同じ控えを読むと観測から行を奪う。
///
/// ファイルの応答を窓に読ませる形は採らない。応答を組む手間 (メモリ・熱の問い合わせ)
/// が毎フレームの描画に乗るためである。**同じ源を 2 人が読む**のであって、片方が
/// もう片方の出力を読むのではない。
///
/// ## 測れていない値は持たない
///
/// 速さもフレーム時間も、起動直後と止めている間は測れていない。**それを 0 で表さない** —
/// 測れた 0 と区別が付かなくなる。応答が鍵ごと省くのと同じ形にし、窓は「—」と描く。
///
/// [ADR-0030]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0030-parameter-surfaces.md
struct FrameNumbers: Equatable {
    /// 進めた枚数。
    let frameCount: Int
    /// スケッチの時刻 (秒)。
    let time: Double
    /// 直近で実際に出ている速さ。**測れていなければ `nil`。**
    let frameRate: Double?
    /// 直近のフレーム時間の平均 (ミリ秒)。**測れていなければ `nil`。**
    let frameTimeMs: Double?
    /// 1 フレームの予算 (1 / fps 秒) を越えたフレームの数 (``FrameBudget``)。数え上げなので常に測れている。
    var overBudgetFrames = 0
    /// いちばん重かったフレームの番号。**まだ 1 枚も測っていなければ `nil`。**
    var heaviestFrame: Int?
    /// このプロセス (走らせている子 1 つ) が起動から言った警告の数 (``Diagnostics/warningSummary()``)。
    ///
    /// **速さの数字と違い、測れていないことは無い** (数え上げ) が、窓は古くなっても消さない
    /// (``SharedFrameStage/warnings``)。観測の `warnings` が持っていく行 (``Diagnostics/takeUnreported()``) とは
    /// 別に数えるので、窓に出しても観測の側から行が消えない ([#3087](https://github.com/mokume-metal/mokume/issues/3087))。
    var warningCount = 0
    /// 最後に言った警告の文面。**まだ何も言っていなければ `nil`。**
    var lastWarning: String?
}
