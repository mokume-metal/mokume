// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

/// 別のプロセスが数えた速さを、道具の側で保つ。
///
/// ## なぜ要るか
///
/// 見張り (`watch`) が出すプレビューは走っているスケッチのオブジェクトを持っていないので、
/// 集計器 (``FrameTempo``) を直に読めない。読めるのは、走らせている側が絵と同じ面へ載せた
/// 数字だけである ([ADR-0032] 決定 3 / ``SharedFrameSurface/TempoAttribute``)。
///
/// **ここも自分では数えない** ([ADR-0030] 決定 7)。持つのは「最後に受け取った数字」と
/// 「いつ受け取ったか」の 2 つで、平均を取り直すことはしない。
///
/// ## 止まったら名乗るのをやめる
///
/// 面に載った数字は、書いた側が消えても残り続ける — 子が死んでも、固まっても、最後の
/// 数字はそこに在る。だから受け取ってからの古さを見て、古ければ「測れていない」へ戻す。
/// **しきい値は ``FrameTempo/staleAfter`` を使い回す** — 同じ問い (この数字はまだ生きて
/// いるか) に 2 つのしきい値を持つと、片方だけ直した日に窓と応答が違うことを言い始める。
///
/// [ADR-0030]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0030-parameter-surfaces.md
/// [ADR-0032]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0032-window-ownership.md
struct RemoteTempo {
    /// 最後に受け取った数字。**まだ 1 つも来ていなければ無い。**
    private var latest: FrameNumbers?
    /// それを受け取った時刻。
    private var receivedAt: Double?

    /// 新しい絵から読んだ数字を受け取る。
    mutating func record(_ numbers: FrameNumbers, at now: Double) {
        latest = numbers
        receivedAt = now
    }

    /// いま名乗ってよい数字。**古ければ `nil`。**
    func numbers(now: Double) -> FrameNumbers? {
        guard let latest, let receivedAt else { return nil }
        guard now - receivedAt < FrameTempo.staleAfter else { return nil }
        return latest
    }
}
