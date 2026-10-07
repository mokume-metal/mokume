// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation
import Synchronization

/// GPU が積んだ仕事を打ち切ったことを、隔離の外から受けて main actor から読む器。
///
/// **実行の結末は別の糸から届く。** この世代の Metal は投入の結末 (`MTL4CommitFeedback`)
/// を Metal 側の糸で呼ぶハンドラへ渡すので、`@MainActor` の ``RenderDevice`` の中へ直接は
/// 書けない。錠で守った器を 1 つ挟む — **escape hatch は使わない** ([ADR-0010] 決定 3)。
/// 中身が錠で守られていることを型として示す (`OutcomeSlot` と同じ作法)。
///
/// 打ち切られた仕事は 1 画素も書き残さないが、合図 (`MTLSharedEvent`) は投入の順に進むので、
/// **待ちの側からは打ち切りと正常が区別できない** — 空の絵がそのまま「正しい絵」として読める。
/// 拾わなければ、絵が出ない理由がどこにも残らない
/// ([#1065](https://github.com/mokume-metal/mokume/issues/1065))。
///
/// ## 投入ごとの結末と、届くのを待つ口 ([#1932])
///
/// 土台全体の記録 (回数・最後の理由・``unresolved``) のほかに、**番号ごとの結末**を持つ。投げる
/// 読む口 (`RenderTarget.readPixels()` ほか) は、返す絵が拠った範囲の投入に打ち切りがあれば
/// 絵を返さずに投げる。``unresolved`` は後の正常な結末で消えるので、それでは範囲を問えない。
///
/// **判定は結末が届いてから下す。** 合図が進んだ時点で、結末はまだ届いていないことがある
/// (`GPUFaultNote.swift` の実測: 絵が空で落ちた 4 回とも、読んだ時点では記録が 0 だった)。
/// 届く前に見ると「たまに投げる」になる — [#1065] の完了条件 5 が「読む口は投げない」を採った
/// 理由そのものである。そこで、読む側は ``drops(after:through:waitingUpTo:)`` で範囲の結末が
/// 揃うまで待つ。待つ側の眠りと目覚めは `NSCondition` が受け持ち、状態は錠 (`Mutex`) が守る。
/// 届けた側は、条件の錠を握ったまま状態を書いて起こすので、確かめてから眠るまでの間に届いた
/// 結末を取りこぼさない。
///
/// [#1065]: https://github.com/mokume-metal/mokume/issues/1065
/// [#1932]: https://github.com/mokume-metal/mokume/issues/1932
/// [ADR-0010]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0010-concurrency-model.md
nonisolated final class CommandFaultLog: Sendable {
    /// 打ち切られた投入 1 つ。
    struct Drop: Equatable, Sendable {
        /// 投入の番号。
        let submission: UInt64
        /// Metal が名乗った理由。
        let reason: String
    }

    /// 番号ごとの打ち切りを覚えておく上限。
    ///
    /// 壊れた GPU が毎フレーム打ち切り続けても、記録が際限なく伸びないための値である。越えたら
    /// 古いものから忘れ、忘れたうち最も新しい 1 つ (``State/forgotten``) だけを残す。**忘れた分は、
    /// 範囲に掛かれば打ち切りとして答える** — 黙った成功の側には倒さない。
    static let rememberedDrops = 256

    private struct State {
        var count = 0
        var last: String?
        var unresolved: String?
        var spoke = false
        /// 結末が 1 番から途切れずに届いている、最後の番号。
        var arrivedThrough: UInt64 = 0
        /// ``arrivedThrough`` より先に、順を飛ばして届いた番号。
        var arrivedAhead: Set<UInt64> = []
        /// 打ち切られた投入。届いた順に並ぶ。
        var drops: [Drop] = []
        /// 上限を越えて忘れた打ち切りのうち、番号が最も大きいもの。
        var forgotten: Drop?

        mutating func arrive(_ submission: UInt64) {
            guard submission > arrivedThrough else { return }
            guard submission == arrivedThrough + 1 else {
                arrivedAhead.insert(submission)
                return
            }
            arrivedThrough = submission
            while arrivedAhead.remove(arrivedThrough + 1) != nil { arrivedThrough += 1 }
        }

        mutating func remember(_ drop: Drop) {
            drops.append(drop)
            guard drops.count > CommandFaultLog.rememberedDrops else { return }
            let oldest = drops.removeFirst()
            if oldest.submission > forgotten?.submission ?? 0 { forgotten = oldest }
        }

        /// 番号が `floor` より大きく `last` 以下の打ち切り。番号の昇順。
        ///
        /// **忘れた分は、範囲の始まりがそれより前なら打ち切りとして答える** (最も新しい 1 つを載せる)。
        /// 忘れた分の番号は 1 つしか残していないので、範囲に入ったかを確かめられない側は打ち切りに
        /// 倒す。読む口が問う範囲は常に「いま積んである最後の投入まで」なので、忘れた分が範囲の終わり
        /// より後ろにあることは無く、この倒し方が実際に余計に投げることは無い。
        func drops(after floor: UInt64, through last: UInt64) -> [Drop] {
            var found = drops.filter { $0.submission > floor && $0.submission <= last }
            if let forgotten, forgotten.submission > floor { found.append(forgotten) }
            return found.sorted { $0.submission < $1.submission }
        }
    }

    private let state = Mutex(State())

    /// 結末の到着を待つ側を眠らせ、起こす。**状態はここに置かない** (上の `state` が守る)。
    private let arrival = NSCondition()

    /// 1 つ数える。**言うべきなら `true`** — 2 度目からは `false` を返す。
    ///
    /// **言うのは最初の 1 回だけ。** GPU の打ち切りは連鎖する — 打ち切られた仕事の後に積んだ
    /// ものも続けて転ぶので、毎回流すと本当に読むべき 1 行が埋まる (`FrameFailureLog` と
    /// 同じ判断)。回数は数え続けるので、何回起きたかは ``count`` から読める。
    ///
    /// **言う文句はここに持たない。** この型は隔離の外から呼ばれる器で、どう言うかは
    /// 呼び出し側 (``RenderDevice``) が決める。
    ///
    /// **番号を持たない記録は、投げる読む口の範囲に入らない。** 番号を渡さずに呼ぶのは、検査が
    /// 土台の記録だけを作る差し込み (`RenderDevice.recordCommandFaultForTesting(_:)`) である。
    func note(_ reason: String) -> Bool {
        state.withLock { state in Self.count(reason, into: &state) }
    }

    /// 番号 `submission` の投入が打ち切られたことを記す。**言うべきなら `true`** (``note(_:)`` と同じ)。
    ///
    /// 結末の 1 つとして数えるので、届くのを待っている読む口を起こす。
    func note(_ reason: String, droppedAt submission: UInt64) -> Bool {
        arriving { state in
            state.arrive(submission)
            state.remember(Drop(submission: submission, reason: reason))
            return Self.count(reason, into: &state)
        }
    }

    /// 番号 `submission` の投入が正常に終わったことを記す。``unresolved`` を消す。
    ///
    /// **回数と最後の理由は消さない。** そちらは「この GPU で何が起きたか」の記録で、
    /// 消すのは「いま打ち切られたままか」の印だけである。番号ごとの打ち切りも消さない —
    /// 後の投入が正常に終わっても、前の投入が書かなかった絵は戻らない。
    func noteFinished(_ submission: UInt64) {
        arriving { state in
            state.arrive(submission)
            state.unresolved = nil
        }
    }

    /// 番号が `floor` より大きく `last` 以下の投入のうち、打ち切られたもの (番号の昇順)。
    /// **その範囲の結末がすべて届くまで、最長 `limit` 待つ。**
    ///
    /// - Returns: `drops` は届いたときの答えで、期限までに届かなければ `nil`。`waited` は
    ///   実際に眠ったか (呼んだ時点で揃っていなければ `true`)。
    func drops(
        after floor: UInt64, through last: UInt64, waitingUpTo limit: Duration
    ) -> (drops: [Drop]?, waited: Bool) {
        // **期限は単調な時計で持つ。** 壁時計で持つと、時刻合わせで待ちが伸び縮みする
        let deadline = ContinuousClock.now + limit
        arrival.lock()
        defer { arrival.unlock() }
        var waited = false
        while state.withLock({ $0.arrivedThrough < last }) {
            waited = true
            let remaining = deadline - ContinuousClock.now
            guard remaining > .zero else { return (nil, waited) }
            let (seconds, attoseconds) = remaining.components
            _ = arrival.wait(
                until: Date(timeIntervalSinceNow: Double(seconds) + Double(attoseconds) * 1e-18))
        }
        return (state.withLock { $0.drops(after: floor, through: last) }, waited)
    }

    /// 結末を 1 つ書き、待っている側を起こす。**条件の錠を握ったまま書く** — 待つ側は同じ錠を
    /// 握って確かめてから眠るので、その間に書かれて起こし損ねることが無い。
    private func arriving<Value: Sendable>(_ write: (inout State) -> Value) -> Value {
        arrival.lock()
        defer {
            arrival.broadcast()
            arrival.unlock()
        }
        return state.withLock { write(&$0) }
    }

    private static func count(_ reason: String, into state: inout State) -> Bool {
        state.count += 1
        state.last = reason
        state.unresolved = reason
        defer { state.spoke = true }
        return !state.spoke
    }

    /// 打ち切られた回数。
    var count: Int { state.withLock { $0.count } }

    /// **直近に届いた結末が打ち切りなら、その理由。** 正常な結末が後から届けば `nil` に戻る。
    ///
    /// 待ちが期限を越えたときに、それを打ち切りのせいと名乗るかを決める
    /// (``RenderDevice/waitFailure(faults:)``)。``last`` で決めると、打ち切りから回復した後の
    /// 本当の描きすぎまで打ち切りのせいにしてしまう
    /// ([#1343](https://github.com/mokume-metal/mokume/issues/1343))。
    var unresolved: String? { state.withLock { $0.unresolved } }

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
