// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation
import Synchronization

/// GPU が積んだ仕事を打ち切ったことを、隔離の外から受けて main actor から読む器。
///
/// **実行の結末は別の糸から届く。** この世代の Metal は投入の結末 (`MTL4CommitFeedback`)
/// を Metal 側の糸で呼ぶハンドラへ渡すので、`@MainActor` の ``RenderDevice`` の中へ直接は
/// 書けない。錠で守った器を 1 つ挟む — **escape hatch は使わない** ([ADR-0010] 決定 3)。
/// 中身が錠で守られていることを型として示す (`FailureSlot` と同じ作法)。
///
/// 打ち切られた仕事は 1 画素も書き残さないが、合図 (`MTLSharedEvent`) は投入の順に進むので、
/// **待ちの側からは打ち切りと正常が区別できない** — 空の絵がそのまま「正しい絵」として読める。
/// 拾わなければ、絵が出ない理由がどこにも残らない
/// ([#1065](https://github.com/mokume-metal/mokume/issues/1065))。
///
/// [ADR-0010]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0010-concurrency-model.md
nonisolated final class CommandFaultLog: Sendable {
    private struct State {
        var count = 0
        var last: String?
        var spoke = false
    }

    private let state = Mutex(State())

    /// 1 つ数える。**言うべきなら `true`** — 2 度目からは `false` を返す。
    ///
    /// **言うのは最初の 1 回だけ。** GPU の打ち切りは連鎖する — 打ち切られた仕事の後に積んだ
    /// ものも続けて転ぶので、毎回流すと本当に読むべき 1 行が埋まる (`FrameFailureLog` と
    /// 同じ判断)。回数は数え続けるので、何回起きたかは ``count`` から読める。
    ///
    /// **言う文句はここに持たない。** この型は隔離の外から呼ばれる器で、どう言うかは
    /// 呼び出し側 (``RenderDevice``) が決める。
    func note(_ reason: String) -> Bool {
        state.withLock { state in
            state.count += 1
            state.last = reason
            defer { state.spoke = true }
            return !state.spoke
        }
    }

    /// 打ち切られた回数。
    var count: Int { state.withLock { $0.count } }

    /// 最後に打ち切られた理由。
    var last: String? { state.withLock { $0.last } }

    /// 届いた失敗から、名乗るのに使う理由を取り出す。
    ///
    /// **理由は入れ子の真ん中にある。** 実測した打ち切りは 3 段だった:
    ///
    /// ```
    /// MTL4CommandQueueErrorDomain Code=1 "(null)"                   ← 束。理由を持たない
    ///   └ MTL4CommandQueueErrorDomain Code=1 "Caused GPU Hang Error (…kIOGPUCommandBufferCallbackErrorHang)"
    ///       └ IOGPUCommandQueueErrorDomain Code=3 "(null)"          ← 番号だけ
    /// ```
    ///
    /// 一番外は束なので理由を持たず、一番奥は番号しか持たない。**どちらを読んでも
    /// 「操作を完了できませんでした」という、原因を 1 つも含まない行になる** — 投入は
    /// 複数のコマンドをまとめて受け付けるので、外側は入れ物として作られている。
    /// 取るべきは**自分で名乗っている一番浅いもの**である。
    static func reason(of error: any Error) -> String {
        stated(in: error) ?? (error as NSError).localizedDescription
    }

    /// 自分と子孫のうち、**自分で理由を名乗っている一番浅いもの**。誰も名乗っていなければ `nil`。
    ///
    /// 名乗っているかは `NSLocalizedDescriptionKey` を自分で持っているかで見る —
    /// `localizedDescription` は持っていなくても既定の文言を作ってしまうので、
    /// 「名乗っていない」を判定できない。
    private static func stated(in error: any Error) -> String? {
        let failure = error as NSError
        if let stated = failure.userInfo[NSLocalizedDescriptionKey] as? String { return stated }
        for underlying in failure.underlyingErrors {
            if let stated = stated(in: underlying) { return stated }
        }
        return nil
    }
}
