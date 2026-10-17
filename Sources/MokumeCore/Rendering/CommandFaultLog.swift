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
/// ## 打ち切りの後に取り戻すもの・取り戻さないもの ([#2199])
///
/// 投入の後に「届いた・焼けた・書き戻した・拡大した」と記す記帳は、結末を見ずに進む。打ち切られた
/// 投入の分は、**結末が届いた後の最初の描き切りの頭で取り消し**、その描き切り (拡大は出す先を読む口の
/// 追い付き) が普段の経路で届け直す (``RenderDevice/revokeDroppedDeliveries()``)。待たずに問うので
/// (``outcomes(of:into:)``)、結末が届くまでのフレームは古い中身のまま描く。
///
/// - **取り戻す** (CPU の側か入力の指紋に正本がある):
///   - 画像への書き込み (全体を届けた投入が打ち切られたら全体を、大きな入力は復号から。編集だけを
///     届けた投入なら編集を届け直す)
///   - 数の並びへの書き込み (打ち切られた投入が運んだ汚れ区間だけ。**打ち切りの後に計算がその並びへ
///     書いていれば届け直さない** — CPU の値へ戻すと計算の結果を潰す)
///   - 影の焼き付けの指紋 (足すだけの焼き付けの判定も)
///   - CPU が書いた画素の書き戻し (**打ち切りの後にその面へ書く投入が無かったときだけ**。あれば写しの
///     全面で巻き戻すので立て直さず、`set()` で書いた画素は失われうる)
///   - 写しの「映した」印 (読み戻しは面を書かないので、印を下ろせば次の読みが映し直す)
///   - 作ったときの面の塗り (**後にその面へ書く投入も、写しへ書いたまま戻していない画素も無かった
///     ときだけ**、透明な黒で塗り直す)
///   - 効果を通す前の絵の控えを戻す印 (控えへ写した投入が打ち切られたら下ろし、古い控えを戻さない)
///   - 粒の寿命を減らした量の累計 (打ち切られた進めの分を戻す)
///   - 細かさを下げた面の拡大の追い付き
/// - **取り戻さない** (正本が GPU にしか無い・その回の仕事そのもの・後の仕事が上に載った・1 フレーム
///   限り):
///   - 打ち切られた回に描いた絵・流した計算・粒の進め・持ち越した奥行き・効果を通す前の絵の控えの中身
///   - 上の「だけ」に当たらない書き戻し・塗り・数の並び
///   - 時間方向の拡大の控え (`StageImage`) の最初の塗り。拡大は毎フレーム前の控えと重み付きで混ぜて
///     書き直すので、塗りが無くても数フレームで薄れる
///   - 置いた時点の絵の写し (`keepPicture(placedFrom:)`)。写しはそのフレームの列だけが読み、境目で
///     手放すので、欠けるのはそのフレームの絵だけである
///
/// **取り消すのは、打ち切られたと確かめられた投入の記帳だけである** (``outcomes(of:into:)``)。結末が
/// 届かなかった投入 (知らせが失われただけで、仕事は走っているかもしれない) と、上限を越えて忘れた
/// 打ち切りに掛かりうる投入は取り消さない — 取り消すと、正しく済んだ中身を CPU の古い値で潰しうる。
/// 投げる読む口がこれらを打ち切りとして投げる倒し方 (#1932) は変えない。
///
/// [#1065]: https://github.com/mokume-metal/mokume/issues/1065
/// [#1932]: https://github.com/mokume-metal/mokume/issues/1932
/// [#2199]: https://github.com/mokume-metal/mokume/issues/2199
/// [ADR-0010]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0010-concurrency-model.md
nonisolated final class CommandFaultLog: Sendable {
    /// 打ち切られた投入 1 つ。
    struct Drop: Equatable, Sendable {
        /// 投入の番号。
        let submission: UInt64
        /// Metal が名乗った理由 (結末が届かなかったものは ``lostReason(after:)``・``skippedReason``)。
        let reason: String
        /// その投入が書いた描画先 (`RenderTarget`) の識別子。投げる読む口は、自分の面へ書いた投入の
        /// 打ち切りだけを持ち越す ([#1932])。結末が届かなかった投入は、何を書いたかを知らないので空。
        ///
        /// [#1932]: https://github.com/mokume-metal/mokume/issues/1932
        var wrote: [ObjectIdentifier] = []
        /// 結末が届かず、打ち切りとして記しただけか (``lostReason(after:)``・``skippedReason``)。
        ///
        /// 投げる読む口は打ち切りと同じに扱う (#1932)。届け直す口は扱わない — 知らせが失われただけで、
        /// 仕事は走っているかもしれないので、記帳を取り消すと正しく済んだ中身を潰しうる ([#2199])。
        ///
        /// [#2199]: https://github.com/mokume-metal/mokume/issues/2199
        var lost = false
    }

    /// 番号ごとの打ち切りを覚えておく上限。
    ///
    /// 壊れた GPU が毎フレーム打ち切り続けても、記録が際限なく伸びないための値である。越えたら
    /// 古いものから忘れ、忘れたうち最も新しい 1 つ (``State/forgotten``) だけを残す。**忘れた分は、
    /// 範囲に掛かれば打ち切りとして答える** — 黙った成功の側には倒さない。
    static let rememberedDrops = 256

    /// 順を飛ばして届いた番号を、前の番号の結末を待ちながら抱えておく上限。
    ///
    /// **結末の知らせが 1 本欠けても、以後の判定を汚さないための値である。** 欠けたまま待ち続けると、
    /// 1 から途切れずに届いた番号 (``State/arrivedThrough``) がそこで止まり、以後の読みがすべて期限
    /// まで待って投げ、抱える番号も際限なく伸びる。越えたら、間の欠けた番号は届かなかったものとして
    /// 打ち切りの側に記して先へ進む (``skippedReason``)。並びが前後するだけなら、この数には
    /// 届かない (知らせは投入の順にほぼ揃って届く)。
    static let aheadLimit = 1024

    /// 結末が届かなかった投入を、打ち切りとして記すときの理由。
    ///
    /// **打ち切りの側に倒す** — 仕上がったと確かめられない絵を、成功として返さない。投げる読む口は
    /// 合図を待ち終えてから結末を待つので、届かないのは仕事が走っている間ではなく、知らせが失われた
    /// ときである。
    static func lostReason(after limit: Duration) -> String {
        "the GPU never reported how this work ended (no outcome within \(limit) of waiting for it)"
    }

    /// 抱える番号が ``aheadLimit`` を越えて、欠けた番号を届かなかったものとして進めるときの理由。
    static let skippedReason =
        "the GPU never reported how this work ended (\(aheadLimit) later submissions reported first)"

    private struct State {
        var count = 0
        var last: String?
        var unresolved: String?
        var spoke = false
        /// 結末が 1 番から途切れずに届いている、最後の番号。
        var arrivedThrough: UInt64 = 0
        /// ``arrivedThrough`` より先に、順を飛ばして届いた番号。``CommandFaultLog/aheadLimit`` まで。
        var arrivedAhead: Set<UInt64> = []
        /// 打ち切られた投入。届いた順に並ぶ。
        var drops: [Drop] = []
        /// 上限を越えて忘れた打ち切りのうち、番号が最も大きいもの。
        var forgotten: Drop?

        mutating func arrive(_ submission: UInt64) {
            guard submission > arrivedThrough else { return }
            guard submission == arrivedThrough + 1 else {
                arrivedAhead.insert(submission)
                // 抱えすぎたら、いちばん前の抱えている番号の手前までを、届かなかったものとして進める
                if arrivedAhead.count > CommandFaultLog.aheadLimit, let first = arrivedAhead.min() {
                    loseMissing(through: first - 1, reason: CommandFaultLog.skippedReason)
                }
                return
            }
            arrivedThrough = submission
            while arrivedAhead.remove(arrivedThrough + 1) != nil { arrivedThrough += 1 }
        }

        /// `last` までで結末が届いていない番号を、届かなかった打ち切りとして記し、先へ進む。
        ///
        /// **土台の記録 (回数・最後の理由・``unresolved``) には数えない。** GPU が打ち切ったと
        /// 分かっているわけではないので、`faultNote()` や待ちの期限切れの名乗りを変えない。
        mutating func loseMissing(through last: UInt64, reason: String) {
            guard last > arrivedThrough else { return }
            var submission = arrivedThrough + 1
            while submission <= last {
                if arrivedAhead.remove(submission) == nil {
                    remember(Drop(submission: submission, reason: reason, lost: true))
                }
                submission += 1
            }
            arrivedThrough = last
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

        /// 番号 `submission` の結末。届いていなければ `nil`、**打ち切られたと確かめられれば** `true`。
        ///
        /// **確かめられないものは `false` に倒す** (``drops(after:through:)`` とは逆の倒し方・[#2199])。
        /// 結末が届かず打ち切りとして記しただけの番号 (``Drop/lost``) と、上限を越えて忘れた打ち切りに
        /// 掛かりうる番号 (忘れた分は最も新しい 1 つしか残していない) である。答えを使うのは記帳の
        /// 取り消しで、取り消しは正しく済んだ中身を潰しうるので、確かめられた打ち切りにだけ効かせる。
        ///
        /// [#2199]: https://github.com/mokume-metal/mokume/issues/2199
        func outcome(of submission: UInt64) -> Bool? {
            guard submission <= arrivedThrough || arrivedAhead.contains(submission) else { return nil }
            if let drop = drops.first(where: { $0.submission == submission }) { return !drop.lost }
            if let forgotten, forgotten.submission == submission { return !forgotten.lost }
            return false
        }

        /// 番号 `submission` の投入が、絵を届けられなかったか。届いていなければ `nil`。
        ///
        /// **確かめられないものは届けられなかった側へ倒す** (``outcome(of:)`` とは逆の倒し方・[#2735])。
        /// 結末を失った番号 (``Drop/lost``) と、忘れた打ち切りに掛かりうる番号 (忘れた分のうち最も
        /// 新しいもの以前で、覚えている打ち切りに無いもの) である。答えを使うのは同じ絵を出し直す・
        /// 焼いた面を名乗らない口で、倒し違えても絵を 1 回余計に出すか 1 枚見送るだけで済む。
        ///
        /// [#2735]: https://github.com/mokume-metal/mokume/issues/2735
        func undelivered(_ submission: UInt64) -> Bool? {
            guard submission <= arrivedThrough || arrivedAhead.contains(submission) else { return nil }
            if drops.contains(where: { $0.submission == submission }) { return true }
            if let forgotten, forgotten.submission >= submission { return true }
            return false
        }
    }

    private let state = Mutex(State())

    /// 検査が遅らせた結末 (`RenderDevice.holdsNextOutcomeForTesting`・[#2743])。正常に終わった投入の
    /// 番号を、記録へ書かずに置く。製品の経路では常に空。
    ///
    /// [#2743]: https://github.com/mokume-metal/mokume/issues/2743
    private let heldForTesting = Mutex<[UInt64]>([])

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
    /// 結末の 1 つとして数えるので、届くのを待っている読む口を起こす。`wrote` はその投入が書いた
    /// 描画先 (``Drop/wrote``)。
    func note(
        _ reason: String, droppedAt submission: UInt64, wrote: [ObjectIdentifier] = []
    ) -> Bool {
        arriving { state in
            state.arrive(submission)
            state.remember(Drop(submission: submission, reason: reason, wrote: wrote))
            return Self.count(reason, into: &state)
        }
    }

    /// 番号 `submission` の投入が正常に終わったことを、**記さずに抱える** (検査の差し込み・[#2743])。
    /// ``releaseHeldForTesting()`` が記す。
    ///
    /// [#2743]: https://github.com/mokume-metal/mokume/issues/2743
    func holdForTesting(_ submission: UInt64) {
        heldForTesting.withLock { $0.append(submission) }
    }

    /// 抱えた結末を、正常に終わったものとして記す (``holdForTesting(_:)``)。
    func releaseHeldForTesting() {
        let held = heldForTesting.withLock { held in
            defer { held.removeAll() }
            return held
        }
        for submission in held { noteFinished(submission) }
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
    /// **期限までに届かなかった結末は、打ち切りとして答えて先へ進む** (``lostReason(after:)``)。
    /// 欠けた番号で止まったままにすると、以後のどの読みも同じ期限まで待つことになる。
    ///
    /// - Returns: `drops` は範囲の打ち切り (届かなかったものを含む)。`waited` は実際に眠ったか
    ///   (呼んだ時点で揃っていなければ `true`)。`lost` は届かなかった結末があったか。
    func drops(
        after floor: UInt64, through last: UInt64, waitingUpTo limit: Duration
    ) -> (drops: [Drop], waited: Bool, lost: Bool) {
        // **期限は単調な時計で持つ。** 壁時計で持つと、時刻合わせで待ちが伸び縮みする
        let deadline = ContinuousClock.now + limit
        arrival.lock()
        defer { arrival.unlock() }
        var waited = false
        var lost = false
        while state.withLock({ $0.arrivedThrough < last }) {
            waited = true
            let remaining = deadline - ContinuousClock.now
            guard remaining > .zero else {
                state.withLock { $0.loseMissing(through: last, reason: Self.lostReason(after: limit)) }
                lost = true
                break
            }
            let (seconds, attoseconds) = remaining.components
            _ = arrival.wait(
                until: Date(timeIntervalSinceNow: Double(seconds) + Double(attoseconds) * 1e-18))
        }
        return (state.withLock { $0.drops(after: floor, through: last) }, waited, lost)
    }

    /// 番号ごとの結末を、**待たずに** `answers` へ書く ([#2199])。届いていない番号は `nil`、打ち切られた
    /// と確かめられた番号は `true`、それ以外 (正常に終わった・結末を失った・忘れた打ち切りに掛かりうる)
    /// は `false`。並びは `submissions` と揃う。
    ///
    /// 打ち切られた投入が届けたはずの中身を取り戻す口 (``RenderDevice/revokeDroppedDeliveries()``) が、
    /// 描き切りの頭で 1 度呼ぶ。待たないので、結末がまだ届いていない投入はその回には取り戻さない
    /// (次の回に問い直す)。**答えの置き場は呼び手が持ち回る** — 毎フレーム呼ぶ口で確保しない。
    ///
    /// [#2199]: https://github.com/mokume-metal/mokume/issues/2199
    func outcomes<Submissions: Sequence<UInt64>>(
        of submissions: Submissions, into answers: inout [Bool?]
    ) {
        answers.removeAll(keepingCapacity: true)
        state.withLock { state in
            for submission in submissions { answers.append(state.outcome(of: submission)) }
        }
    }

    /// 番号が `floor` より大きく `last` 以下の投入のうち打ち切られたもの (番号の昇順) を、**待たずに**
    /// 答える ([#2743])。範囲の結末がまだ全部届いていなければ `nil`。
    ///
    /// 答えは ``drops(after:through:waitingUpTo:)`` が届いた後に返すものと同じである (届かなかった結末・
    /// 忘れた打ち切りに掛かりうる番号を、打ち切りの側に倒す)。出口へ絵を配る口が、毎フレーム main
    /// actor で眠らずに問うために使う — 届いていなければ、配るのを次のフレームへ持ち越す。
    ///
    /// [#2743]: https://github.com/mokume-metal/mokume/issues/2743
    func settledDrops(after floor: UInt64, through last: UInt64) -> [Drop]? {
        state.withLock { state in
            guard state.arrivedThrough >= last else { return nil }
            return state.drops(after: floor, through: last)
        }
    }

    /// 番号 `submission` の投入が絵を届けられなかったかを、**待たずに**答える ([#2735])。届いていなければ
    /// `nil`、打ち切られた・結末を失った・忘れた打ち切りに掛かりうるなら `true` (``State/undelivered(_:)``)。
    ///
    /// [#2735]: https://github.com/mokume-metal/mokume/issues/2735
    func undelivered(_ submission: UInt64) -> Bool? {
        state.withLock { $0.undelivered(submission) }
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
