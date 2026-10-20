// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Synchronization

/// 投入ごとに GPU が仕事を始めた時刻と終えた時刻を、隔離の外から受けて main actor から読む器
/// ([#2378](https://github.com/mokume-metal/mokume/issues/2378))。
///
/// **時刻は投入の結末 (`MTL4CommitFeedback`) が運んでくる。** 結末は Metal 側の糸で呼ぶハンドラへ
/// 渡されるので、`@MainActor` の ``RenderDevice`` へ直には書けない。錠で守った器を 1 つ挟む
/// (``CommandFaultLog`` と同じ作法・[ADR-0010] 決定 3)。**書く側は待たず、main actor へも渡さない** —
/// ハンドラの先頭で 1 行を記すだけで、新しい待ちを作らない。
///
/// ## 「フレームの GPU 時間」の定義
///
/// **そのフレームの投入すべての `min(start)`〜`max(end)` の幅である** (``Span/width``)。投入ごとの
/// `end − start` の和ではない — 重なった投入を二重に数えないので、「そのフレームのために GPU が
/// 占められていた幅」として 16.7 ms の予算と並べられる。
///
/// **この幅は GPU の稼働時間でも使用率でもない。** 投入と投入の隙間 (たとえば 3 本目のコミットまでの
/// 待ち) も含む。投入ごとの時間の和も、依存の待ちや重なりを含みうるので使用率にはならない。
/// 名前も説明も「幅」と書く (#2378 の 2026-10-17 の補足)。
///
/// ## 届くのは遅れる
///
/// 結末は投入より後に届き、**フレームの値は 1〜2 フレーム遅れて揃う**。範囲の投入が 1 つでも届いて
/// いなければ、幅は返さない (``span(of:)`` は `nil`)。届かなかった投入 (知らせが失われた) があれば、
/// 上限 (``remembered``) を越えて忘れられるまで、そのフレームの幅は返らない — 欠けたまま小さな幅を
/// 返すと、実際より軽く見える。
///
/// [ADR-0010]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0010-concurrency-model.md
nonisolated final class GPUTimeLog: Sendable {
    /// 範囲の投入の、始めた最も早い時刻から終えた最も遅い時刻までの幅。
    struct Span: Equatable, Sendable {
        /// 範囲の投入のうち、時刻が使えたものの数。
        let submissions: Int
        /// 始めた最も早い時刻 (秒・GPU の時計)。
        let start: Double
        /// 終えた最も遅い時刻 (秒・GPU の時計)。
        let end: Double

        /// `end − start` (秒)。**投入の幅であって、GPU の稼働時間でも使用率でもない。**
        var width: Double { end - start }
    }

    /// 投入 1 つぶんの記録。時刻が使えなければ `nil` (打ち切られた・時刻が 0・逆転)。
    private struct Entry {
        let times: (start: Double, end: Double)?
    }

    /// 覚えておく投入の数の上限。越えたら番号の小さいものから忘れる。
    ///
    /// 毎フレーム数投入でも数十フレーム分で、フレームの幅を問うのは 1〜2 フレーム前までなので、
    /// 十分に大きい。際限なく伸びないための値である。
    static let remembered = 1024

    private struct State {
        var entries: [UInt64: Entry] = [:]
        /// 届いた番号の最大。
        var newest: UInt64 = 0
        /// 忘れた番号の最大。これ以前の範囲は、揃っていたかを確かめられないので `nil` を返す。
        var forgottenThrough: UInt64 = 0
    }

    private let state = Mutex(State())

    /// 番号 `submission` の投入が終わり、時刻が届いた。**ハンドラから呼ぶ。待たない。**
    ///
    /// - Parameters:
    ///   - start: GPU が仕事を始めた時刻 (秒)。
    ///   - end: 終えた時刻 (秒)。
    ///   - failed: 結末がエラーだったか。打ち切られた投入の時刻は信用しない。
    func note(_ submission: UInt64, start: Double, end: Double, failed: Bool) {
        let usable = !failed && start.isFinite && end.isFinite && start > 0 && end >= start
        state.withLock { state in
            // 忘れた範囲の投入が遅れて届いても、記録に戻さない (揃っていたかを確かめられないまま)
            guard submission > state.forgottenThrough else { return }
            state.entries[submission] = Entry(times: usable ? (start, end) : nil)
            state.newest = max(state.newest, submission)
            // **番号の古いほうから忘れる。** 並べ替えず、忘れる範囲の番号を 1 つずつ外す (1 つの番号は
            // 1 度しか外さないので、1 回あたりの費用は一定)。ハンドラは Metal 側の糸で毎投入走る
            let keep = UInt64(Self.remembered)
            guard state.newest > keep else { return }
            let limit = state.newest - keep
            guard limit > state.forgottenThrough else { return }
            for key in (state.forgottenThrough + 1)...limit { state.entries.removeValue(forKey: key) }
            state.forgottenThrough = limit
        }
    }

    /// 番号の範囲の投入の幅。**範囲の投入がすべて届いていなければ `nil`。**
    ///
    /// 時刻が使えなかった投入 (打ち切られたものなど) は数えずに飛ばす。範囲が空・全部が使えない・
    /// 忘れた番号を含む・まだ届いていない投入があるときは `nil`。
    func span(of range: Range<UInt64>) -> Span? {
        guard !range.isEmpty else { return nil }
        return state.withLock { state in
            guard range.lowerBound > state.forgottenThrough else { return nil }
            var count = 0
            var start = Double.infinity
            var end = -Double.infinity
            for submission in range {
                guard let entry = state.entries[submission] else { return nil }
                guard let times = entry.times else { continue }
                count += 1
                start = min(start, times.start)
                end = max(end, times.end)
            }
            return count > 0 ? Span(submissions: count, start: start, end: end) : nil
        }
    }

    /// 記録している投入の数。
    var count: Int { state.withLock { $0.entries.count } }
}
