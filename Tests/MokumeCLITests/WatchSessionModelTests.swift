// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation
import MokumeProbe
import MokumeTestSupport
import Testing
import mokume

@testable import MokumeCLI

/// `mokume watch` の世代交代 (``WatchSession``) を、**生成した操作の列** で見る (#3218・#3207 の提案 3)。
///
/// ``WatchSessionTests`` は並びを 1 本ずつ手で書く。ここは、保存・ウィンドウの合図・子の消え方の列を seed つきで
/// 生成し、各操作の後に **事後条件** が成り立つかを見る。破れたら、縮めた列と破れた事後条件の番号を名乗る。
///
/// ## 約束 (事後条件)
///
/// 検査が子の生死を自分で数え (`Process.isRunning`)、台の役を自分で演じる (どの世代が映っているか・どの世代が
/// 乗り換えを待っているか)。**``WatchSession`` の内部の変数ではなく、外から見える生死と呼び出しの結果で比べる。**
///
/// 世代には **役** がある (#3565)。試聴に入っていなければ全部が本番の側で、入っている間は、保存で起こした子が試聴の側
/// (``WatchSession/auditionChild``) になる。事後条件は役ごとに書く。
///
/// 1. 生きている子は、**本番の側が 2 つまで** (2 つなら、一方は乗り換えを待っている・
///    ``WatchSession/waitingGeneration``・#2350)、**試聴の側が 1 つまで**。試聴に入っていなければ試聴の側は居ない。
///    乗り換えを待つ世代が無ければ、全体で「本番 + 試聴」の 2 つまで
/// 2. 入力 (``WatchSession/send(_:shownBy:)``) の宛先は、**ウィンドウが映している世代が生きていれば、その世代である**。
///    作品のウィンドウ (引数なし) は映っている本番の世代、プレビュー (その台の `displayedPID`) は試聴中なら映している試聴の世代
/// 3. 台へ手放した世代 (``WatchSession/relinquishesDisplay``): **映っていて、そこから去った世代は、かならず伝える**
///    (去るのは自分で終わる・畳まれる・倒れた知らせで前の世代になる回。#2983)。生きて映っている世代は伝えない。
///    試聴の子も同じ — プレビューが映した試聴の子が去る (自分で終わる・次の保存で止める・出る) 回は伝える。
///    **伝える回数は数えない** — 子の離脱 (`departed`)・映っている前の世代の離脱・次の保存の退役が同じ世代を重ねて
///    伝えうるが、台は番号を集合で覚える (`SharedFrameStage.relinquishSource` が `formUnion`) ので、重ねても同じ
/// 4. ウィンドウの合図は、待っている世代のものだけが待ちを下ろす。**ほかの世代の合図では、待ちも前の世代も動かず、合図された
///    世代は生きたまま** (#2982)。倒れた知らせ・受け取れない知らせは、生きて待っている世代のぶんだけ前の世代を畳み、
///    2 度目は何もしない (#2928・#2350)。**試聴の子の合図は、どの合図も本番の側の何も動かさない** (#3565)
/// 5. ``WatchSession/keepsPreviousRunning`` は「生きた世代がある」と一致する。1 度も起こしていなければ偽 (#2875)。
///    作り直しの失敗・起こせなかった失敗は、走っている世代を落とさない
/// 6. 終われと言われて ``WatchSession/end()`` を済ませた後は、子が 0 で、以後 `launch` が呼ばれない
/// 7. 試聴 (#3565): **入る要求は、試聴に入っておらず本番が走っているときだけ受け、受けても何も起こさない**。
///    **入っている間の保存は本番の側を動かさない** (本番の子は入れ替わらず、生きている本番は 1 つも落ちない)。
///    **出る要求は、入っているときだけ受け、試聴の子を止め、本番の側を動かさない**。試聴の子が自分で終わっても
///    本番の側は動かない。**保存の役は、その保存を拾った見張りの読みを始めた時点で決まる** (#3796・保存ごと): 見張りが
///    見る前の保存と要求が同じ拍に入ると、保存は要求の後に読まれる (入る要求なら試聴の版、出る要求なら本番の版)。
///    例外は、出る要求が「出た時点のソースを本番に作り直す」と決めた試聴 (本番が居ない・プレビューを戻せない) の版で、
///    本番の子として起きる。捨てた試聴の版は、捨てたことを名乗る
///
/// ## どこまで見て、どこで止めるか
///
/// **GPU もウィンドウも使わない。** 台 (`SharedFrameStage`) は作らず、台の合図 (乗り換え・倒れた・受け取れない・1 枚目)
/// は検査が ``WatchSession`` の口を直に呼んで模す。子は `/bin/sh` の替え玉 (`read line`) で、本物の子を起こす
/// (重なりは生きた子でしか見えない)。**台の側の約束 (頼みを下ろす・寸法) は範囲外**で、ここで見るのは
/// 台へ伝えたかどうか (事後条件 3) までである。ウィンドウの無い見張り (`overlapsGenerations == false`) は範囲外
/// (世代が重ならず、事後条件 1〜4 が空になる)。
///
/// 生成する操作は ``Op``。子が消える操作は終了コード 0 と非 0 (最初の絵の前に失敗で終わる・#3172) の 2 通り。
/// TERM を無視する子は起こさない (止めるのに期限を待つので、PR の経路には載せない・#3218 の条件 6)。
@Suite("見張りの世代交代は、生成した操作の列でも事後条件を破らない", .signalStateKept)
struct WatchSessionModelTests {
    /// 見張りと台の外側に起きる出来事。
    /// 作り直しを門で止めている間の出来事 (``Op/overlap(_:)``・#3796)。
    nonisolated enum Step: Sendable, Equatable, CustomStringConvertible {
        /// 保存して、見張りがそれを読む 1 拍を回す (作り直しの最中なので取りかからない)。
        case save
        /// 中身を 1 つ前の保存の中身へ戻して保存し、読む 1 拍を回す (#3796 の 2 回目の反証 6・7)。作り直しの最中に重ねた
        /// 保存が 2 つ以上あるときだけ演じる (作り直している版・本番の版へ戻す形は ``WatchAuditionRefutationTests`` が見る)。
        case revert
        /// 試聴に入る要求。
        case audition
        /// 試聴を出る要求。
        case leave
        /// プレビューを本番へ戻せない形で、試聴を出る要求 (出た時点のソースを本番に作り直す・#3796 の 2 回目の反証 7)。
        case leaveStuck
        /// 作品のウィンドウに映っている本番の子が自分で終わり、1 拍回す (#3796 の 2 回目の反証 3・7)。
        case exitShown
        /// 終われと言われ、作り直しを止めて終える (最後にだけ置く・#3796 の 2 回目の反証 7)。
        case stop
        /// 作り直す要求 (#3428)。中身は変えない。頼みを読んだ時点の役で、作り直しが済んだ後に 1 回だけ作り直す。
        case rebuild
        /// 起こし直す要求 (#3428)。作り直しが済んでから、頼みを読んだ時点の役で決めて行う。
        case restart

        var description: String {
            switch self {
            case .rebuild: "rebuild"
            case .restart: "restart"
            case .save: "save"
            case .revert: "revert"
            case .audition: "audition"
            case .leave: "leave"
            case .leaveStuck: "leave(stuck)"
            case .exitShown: "exit(shown)"
            case .stop: "stop"
            }
        }
    }

    nonisolated enum Op: Sendable, Equatable, CustomStringConvertible {
        /// 何もしない (縮める先)。
        case none
        /// 試聴に入る要求 (#3565)。
        case audition
        /// 試聴を出る要求。
        case leave
        /// 保存して、見張りがそれを見る前に試聴に入る要求を出す (#3794)。拍の中では要求が保存の検出より先に効く。
        case saveThenAudition
        /// 保存して、見張りがそれを見る前に試聴を出る要求を出す (#3796)。保存は出た後に読まれるので、本番の版である。
        case saveThenLeave
        /// 保存して、その作り直しを門で止め、止めている間に `Step` の出来事を順に起こしてから門を開ける (#3796 の反証)。
        /// 作り直しの最中に読んだ保存・出入りを、保存の役の規則 (その保存を拾った読みを始めた時点の役) で見る。
        case overlap([Step])
        /// ``overlap(_:)`` と同じだが、門で止めた作り直しは通らない (#3796 の 2 回目の反証 3・7)。
        case overlapFailing([Step])
        /// ``overlap(_:)`` と同じだが、門で止める作り直しは保存でなく作り直す要求で起こす (中身は変えない・#3428)。
        /// 頼んだ作り直しの最中に出る・入る形を見る。
        case rebuildOverlap([Step])
        /// 試聴の子が、自分から (終了コード 0 で) 終わる。
        case exitAudition
        /// 試聴の子が、最初の絵の前に失敗 (終了コード 3) で終わる。続けて 1 拍回る。
        case exitAuditionFailing
        /// プレビューが試聴の子へ乗り換えた合図 (本番の合図ではない)。
        case promoteAudition
        /// プレビューが試聴の子の絵を受け取れない知らせ。
        case undeliverableAudition
        /// 巡回の 1 拍。変化は無い。
        case beat
        /// 保存して、作り直しが通り、子を起こせる。
        case save
        /// 保存して、作り直しが通らない。
        case saveBuildFail
        /// 保存して、作り直しは通るが、子を起こせない。
        case saveLaunchFail
        /// 台が、乗り換えを待っている世代へ乗り換えた (合図は子の番号つき)。
        case promoteWaiting
        /// 台が、乗り換えを待っている世代へ乗り換えた (合図は番号を名乗らない・古いライブラリの子)。
        case promoteAnonymous
        /// 台が、待っていない世代 (前の世代など) へ乗り換えた合図。
        case promoteStale
        /// 乗り換えを待つ世代が倒れた (自分のウィンドウを開いた) 知らせ。
        case fellBack
        /// 待っていない世代が倒れた知らせ。
        case fellBackStale
        /// 乗り換えを待つ世代の絵を台が受け取れない知らせ。
        case undeliverable
        /// 待っていない世代の絵を台が受け取れない知らせ。
        case undeliverableStale
        /// 乗り換えを待つ世代が、自分から (終了コード 0 で) 終わる。
        case exitWaiting
        /// 乗り換えを待つ世代が、最初の絵の前に失敗 (終了コード 3) で終わる (#3172)。続けて 1 拍回る。
        case exitWaitingFailing
        /// 映っている世代が、自分から終わる。
        case exitShown
        /// 終われと言われ、終える (最後にだけ置く)。
        case stop
        /// 作り直す要求 (#3428)。中身を変えずに、保存と同じ作り直しが 1 回起きる。役は頼みを読んだ時点の試聴の状態。
        case rebuild
        /// 起こし直す要求 (#3428)。作り直さずに、頼みを読んだ時点の役の子を最初から起こし直す。
        case restart

        var description: String {
            switch self {
            case .rebuild: "rebuild"
            case .restart: "restart"
            case .none: "none"
            case .audition: "audition"
            case .leave: "leave"
            case .saveThenAudition: "save+audition"
            case .saveThenLeave: "save+leave"
            case .overlap(let steps): "overlap(\(steps.map(\.description).joined(separator: ",")))"
            case .overlapFailing(let steps): "overlap(failing;\(steps.map(\.description).joined(separator: ",")))"
            case .rebuildOverlap(let steps): "overlap(rebuild;\(steps.map(\.description).joined(separator: ",")))"
            case .exitAudition: "exit(audition)"
            case .exitAuditionFailing: "exit(audition,failing)"
            case .promoteAudition: "promote(audition)"
            case .undeliverableAudition: "undeliverable(audition)"
            case .beat: "beat"
            case .save: "save"
            case .saveBuildFail: "save(buildFail)"
            case .saveLaunchFail: "save(launchFail)"
            case .promoteWaiting: "promote(waiting)"
            case .promoteAnonymous: "promote(anonymous)"
            case .promoteStale: "promote(stale)"
            case .fellBack: "fellBack(waiting)"
            case .fellBackStale: "fellBack(stale)"
            case .undeliverable: "undeliverable(waiting)"
            case .undeliverableStale: "undeliverable(stale)"
            case .exitWaiting: "exit(waiting)"
            case .exitWaitingFailing: "exit(waiting,failing)"
            case .exitShown: "exit(shown)"
            case .stop: "stop"
            }
        }
    }

    /// 生成する値 (座標の値の範囲の目盛り) から操作への対応。**先頭が `none`** (縮める先)。出やすさは目盛りの数で
    /// 変える — 保存が列の骨で、ウィンドウの合図と子の消え方がそれを割る。
    nonisolated static let table: [Op] = [
        .none, .beat,
        .save, .save, .save, .save,
        .saveBuildFail, .saveLaunchFail,
        .promoteWaiting, .promoteWaiting, .promoteAnonymous, .promoteStale, .promoteStale, .promoteStale,
        .fellBack, .fellBackStale, .undeliverable, .undeliverableStale,
        .exitWaiting, .exitWaitingFailing, .exitShown,
        .audition, .audition, .audition, .leave, .exitAudition, .exitAuditionFailing,
        .promoteAudition, .undeliverableAudition,
        .saveThenAudition, .saveThenLeave,
        .overlap([.leave]), .overlap([.audition]), .overlap([.save, .leave]), .overlap([.save, .audition]),
        .overlap([.leave, .audition]), .overlap([.save, .save, .leave]), .overlap([.audition, .save, .leave]),
        .overlap([.save, .leaveStuck]), .overlap([.save, .save, .leave, .revert]), .overlap([.audition, .exitShown, .save, .leave]),
        .overlap([.save, .stop]), .overlapFailing([.audition, .save, .leave]), .overlapFailing([.save, .leaveStuck]),
        .overlapFailing([.audition, .exitShown, .save, .leave]),
        // 作り直す・起こし直す要求 (#3428)
        .rebuild, .rebuild, .restart, .restart, .restart,
        .overlap([.rebuild]), .overlap([.rebuild, .rebuild]), .overlap([.rebuild, .leave]), .overlap([.rebuild, .audition]),
        .overlap([.audition, .rebuild, .leave]), .overlap([.save, .rebuild]), .overlap([.rebuild, .save]),
        .overlapFailing([.rebuild]),
        .overlap([.restart]), .overlap([.restart, .leave]), .overlap([.audition, .restart]), .overlap([.restart, .audition]),
        .overlap([.leave, .restart]), .overlapFailing([.restart]),
        .rebuildOverlap([.leave]), .rebuildOverlap([.audition]), .rebuildOverlap([.rebuild]), .rebuildOverlap([.save, .leave]),
        .rebuildOverlap([.restart]),
        // 役ごと・頼みごとの控え (#3428 の反証 1・2・3)
        .overlap([.save, .audition, .rebuild]), .overlap([.audition, .save, .leave, .rebuild]),
        .overlap([.rebuild, .audition, .save]), .overlap([.rebuild, .restart]), .overlap([.restart, .rebuild]),
        .rebuildOverlap([.restart, .rebuild]), .overlap([.audition, .rebuild, .save]),
        // 出る要求が本番の版へ寄せた試聴の頼みを、次の試聴の保存が捨てる (#3428 の 2 回目の反証 5)
        .overlap([.rebuild, .leaveStuck, .audition, .save]),
    ]

    /// 列の長さ。縮めると `none` が並ぶので、実際の長さはこれ以下。
    nonisolated static let length = 8

    nonisolated static var axes: [ProbeAxis] {
        (0..<length).map { ProbeAxis("op\($0)", 0..<Double(table.count), simplest: 0, step: 1) }
            + [ProbeAxis("end", 0..<3, simplest: 0, step: 1)]
    }

    /// PR・queue で回す件数 (固定の seed)。定期の検査は `MOKUME_PROBE_SCALE` で増やす。
    nonisolated static let generatedCases = 96

    nonisolated static func sequence(of input: ProbeInput) -> (ops: [Op], ends: Bool) {
        let ops = (0..<length).map { table[min(Int(input["op\($0)"].rounded()), table.count - 1)] }
        return (ops, input["end"].rounded() >= 2)
    }

    /// 生成した操作の列で、世代交代が事後条件を破らない。
    ///
    /// 赤なら、縮めた列と seed を `[watch seed=…]` で名乗る。同じ赤は `MOKUME_PROBE_SEED=<その seed>` と `--filter` で
    /// その 1 件だけ再現する。**事後条件は緩めない** — 破れたら Bug として起票し、直るまでは `withKnownIssue` で残す。
    @Test("生成した操作の列で、世代交代は事後条件 1〜7 を破らない")
    nonisolated func successionKeepsItsPostconditions() async throws {
        let report = Probe.run(
            "watch", suite: "WatchSessionModelTests", key: "succession", axes: Self.axes,
            cases: Self.generatedCases
        ) { input in
            let (ops, ends) = Self.sequence(of: input)
            // **検査は main actor の外で回し、1 件ずつ main actor へ渡して待つ。** 子を畳む待ちは
            // 実行ループを使うので、main の上で同期に待つと進まない
            let done = DispatchSemaphore(value: 0)
            let outcome = Outcome()
            Task { @MainActor in
                outcome.value = await Driver.runCase(ops: ops, ends: ends)
                done.signal()
            }
            done.wait()
            return outcome.value
        }
        #expect(report.failure == nil, "\(report.failure ?? "")")
        // 生成した列が約束の外へ落ちて何も見ないことは無い (どの列も走る)
        #expect(report.skipped == 0 && report.ran >= 1, "走った列 \(report.ran) 件・約束の外 \(report.skipped) 件")
    }

    /// 生成が見つけて直した列 (#3481)。**生成する検査の seed に頼らず、決定的に回す。** 起こせなかった保存が
    /// 走っている世代の役を動かさない約束 (事後条件 3・4) を、3 つの形で見る。
    @Test(
        "起こせなかった保存の後の合図・保存は、事後条件 3・4 を破らない (#3481 の 3 列)",
        arguments: [
            [Op.save, .saveLaunchFail, .promoteWaiting],
            [.save, .promoteWaiting, .saveLaunchFail, .promoteStale],
            [.save, .promoteWaiting, .saveLaunchFail, .save],
        ])
    @MainActor
    func refusedLaunchColumnsKeepTheirPostconditions(_ ops: [Op]) async {
        let outcome = await Driver.runCase(ops: ops, ends: false)
        #expect(outcome == .pass, "\(outcome)")
    }

    /// 試聴の列 (#3565)。**生成する検査の seed に頼らず、決定的に回す。** 入る・保存・出る、試聴の子の離脱、
    /// 試聴中の本番の離脱、本番の乗り換え中に入る、の形で事後条件 1〜7 を見る。
    @Test(
        "試聴の列は、事後条件を破らない (#3565)",
        arguments: [
            [Op.save, .audition, .save, .leave],
            [.save, .audition, .save, .save, .save, .leave, .save],
            [.save, .promoteWaiting, .audition, .save, .exitAudition, .beat, .save],
            [.save, .promoteWaiting, .audition, .save, .exitAuditionFailing, .save, .leave],
            [.save, .save, .audition, .save, .promoteAudition, .undeliverableAudition, .promoteWaiting],
            [.save, .promoteWaiting, .audition, .save, .exitShown, .beat, .save, .leave],
            [.save, .promoteWaiting, .audition, .saveLaunchFail, .saveBuildFail, .save, .leave, .leave],
            [.save, .audition, .save, .stop],
            // 乗り換えを待つ間に入る → 保存 (前の本番を畳む) → 出る → 保存
            [.save, .save, .audition, .save, .save, .leave, .save],
            // 乗り換えを待つ間に入る → 保存 (試聴の子は保留) → 待つ世代が 1 枚目の前に落ちる / 映る → 試聴の子が起きる
            [.save, .promoteWaiting, .save, .audition, .save, .exitWaitingFailing, .beat, .leave],
            [.save, .promoteWaiting, .save, .audition, .save, .promoteWaiting, .beat, .save, .leave],
        ])
    @MainActor
    func auditionColumnsKeepTheirPostconditions(_ ops: [Op]) async {
        let outcome = await Driver.runCase(ops: ops, ends: false)
        #expect(outcome == .pass, "\(outcome)")
    }

    /// 本番を起こす口は保存だけではない (#3693)。**生成する検査の seed に頼らず、決定的に回す。** 試聴を出る要求が
    /// 本番を起こし直す回 (本番が試聴中に落ちた) は、起こした本番が乗り換えを待ち、その世代へのウィンドウの知らせは受ける。
    /// 保留していた試聴の子は、乗り換えが決着した後の最初の拍 (保存・入る要求の拍でも) で起きる。
    @Test(
        "本番を起こし直す口・保留していた試聴の子が起きる拍でも、事後条件を破らない (#3693)",
        arguments: [
            [Op.save, .audition, .exitWaiting, .leave, .fellBackStale],
            [.save, .audition, .exitWaiting, .leave, .undeliverableStale],
            [.save, .audition, .exitWaiting, .leave, .fellBack],
            [.save, .audition, .exitWaiting, .leave, .undeliverable],
            [.save, .audition, .exitWaiting, .leave, .promoteWaiting, .save],
            [.save, .audition, .save, .fellBack, .saveBuildFail],
            [.save, .audition, .save, .promoteWaiting, .audition],
        ])
    @MainActor
    func restartedProductionColumnsKeepTheirPostconditions(_ ops: [Op]) async {
        let outcome = await Driver.runCase(ops: ops, ends: false)
        #expect(outcome == .pass, "\(outcome)")
    }

    /// 保留していた試聴の子を起こした拍に重なった保存 (#3789)。**生成する検査の seed に頼らず、決定的に回す。** その拍は
    /// 作り直しに取りかからず、保存は次の拍に残る。残った保存の結果 (試聴の子の差し替え) を、次の操作 (入る・出る要求)
    /// の結果と取り違えない。保留していた版を起こせない・残った保存の版を起こせない・残った保存の作り直しが通らない形も見る。
    @Test(
        "保留していた試聴の子を起こした拍に重なった保存は、次の要求の結果と取り違えない (#3789)",
        arguments: [
            [Op.save, .audition, .save, .promoteWaiting, .save, .audition],
            [.save, .audition, .save, .promoteWaiting, .save, .leave],
            // 保留していた版 (s2) を起こせない。その拍は作り直しに取りかからず、試聴の子も起きない
            [.save, .audition, .saveLaunchFail, .promoteWaiting, .save, .leave],
            [.save, .audition, .saveLaunchFail, .promoteWaiting, .save, .audition],
            // 残った保存の版 (s3) を起こせない
            [.save, .audition, .save, .promoteWaiting, .saveLaunchFail, .audition],
            [.save, .audition, .save, .promoteWaiting, .saveLaunchFail, .leave],
            [.save, .audition, .save, .promoteWaiting, .saveBuildFail, .audition],
            // 縮める前の列
            [.promoteStale, .save, .save, .audition, .saveLaunchFail, .promoteWaiting, .save, .audition, .stop],
        ])
    @MainActor
    func saveOverlappingResumedAuditionColumnsKeepTheirPostconditions(_ ops: [Op]) async {
        let outcome = await Driver.runCase(ops: ops, ends: false)
        #expect(outcome == .pass, "\(outcome)")
    }

    /// 出た時点のソースのままの入り直し (#3794)。**生成する検査の seed に頼らず、決定的に回す。** 入り直しは何も起こさない。
    /// 見張りがまだ見ていない保存と入る要求が同じ拍に入っても、入った後の保存は試聴の版になり、本番は動かない。
    @Test(
        "出た時点のソースのままの入り直し・見ていない保存と同じ拍の入る要求は、事後条件を破らない (#3794)",
        arguments: [
            [Op.save, .promoteWaiting, .audition, .save, .leave, .audition],
            [.save, .audition, .save, .promoteWaiting, .leave, .audition],
            [.save, .promoteWaiting, .audition, .save, .leave, .audition, .save, .leave],
            [.save, .promoteWaiting, .audition, .save, .leave, .saveThenAudition],
            [.save, .audition, .save, .promoteWaiting, .saveThenAudition, .leave],
            // 入った拍の保存が試聴の子を起こす (本番が映っている)・保留に回る (本番が乗り換えを待つ) と、後の拍で起きる
            [.save, .promoteWaiting, .saveThenAudition, .leave],
            [.save, .saveThenAudition, .promoteWaiting, .beat, .audition, .leave],
            [.save, .saveThenAudition, .promoteWaiting, .audition, .leave],
            // 本番が居ないので入る要求は断られ、同じ拍の保存は普通の保存 (本番を起こす)
            [.saveThenAudition, .promoteWaiting, .audition, .leave],
        ])
    @MainActor
    func unadoptedSourceColumnsKeepTheirPostconditions(_ ops: [Op]) async {
        let outcome = await Driver.runCase(ops: ops, ends: false)
        #expect(outcome == .pass, "\(outcome)")
    }

    /// 保存の役は、保存を読んだ時点で決まる (#3796)。**生成する検査の seed に頼らず、決定的に回す。** 見張りが見る前の
    /// 保存と出る要求が同じ拍に入ると、保存は出た後に読まれて本番の版になる。出た直後の保存も本番の版。試聴の中で読んだ版は、
    /// 出入りを繰り返しても本番の版にならない。
    @Test(
        "見ていない保存と同じ拍の出る要求・出た直後の保存・保存せずに出入りを繰り返す列は、事後条件を破らない (#3796)",
        arguments: [
            [Op.save, .audition, .save, .saveThenLeave],
            [.save, .audition, .save, .saveThenLeave, .audition, .save, .leave],
            [.save, .audition, .save, .leave, .save],
            // 入っていないので出る要求は断られ、同じ拍の保存は普通の保存
            [.save, .promoteWaiting, .saveThenLeave],
            // 本番が乗り換えを待つ間 (試聴の保存は保留) に、見ていない保存と出る要求
            [.save, .promoteWaiting, .audition, .save, .save, .saveThenLeave],
            [.save, .audition, .save, .promoteWaiting, .saveThenLeave],
            // 試聴中に本番が落ちた後 (出ると本番を起こし直す) の、見ていない保存と出る要求
            [.save, .audition, .exitWaiting, .saveThenLeave],
            // 保存せずに出入りを繰り返す
            [.save, .promoteWaiting, .audition, .save, .leave, .audition, .leave, .beat],
            [.save, .promoteWaiting, .audition, .save, .leave, .audition, .leave, .audition, .leave],
        ])
    @MainActor
    func saveRoleColumnsKeepTheirPostconditions(_ ops: [Op]) async {
        let outcome = await Driver.runCase(ops: ops, ends: false)
        #expect(outcome == .pass, "\(outcome)")
    }

    /// 作り直しの最中に読んだ保存・出入り (#3796 の反証 1・2・5・6・7)。**生成する検査の seed に頼らず、決定的に回す。**
    /// 作り直しを門で止めている間に、別の保存を読ませ、出る・入る・出て入り直す。保存の役は、その保存を拾った読みを
    /// 始めた時点で決まる。
    @Test(
        "作り直しの最中に読んだ保存と出入りの列は、保存の役の規則と事後条件を破らない (#3796 の反証)",
        arguments: [
            // 試聴の中で、試聴の版の作り直しの最中に別の保存を読み、出る (1)
            [Op.save, .promoteWaiting, .audition, .save, .overlap([.save, .leave])],
            // 同じ順で、作り直しが済んでから出る (1)
            [.save, .promoteWaiting, .audition, .save, .overlap([.save]), .leave],
            // 本番の版の作り直しの最中に別の保存を読み、入る (2)
            [.save, .promoteWaiting, .overlap([.save, .audition])],
            // 入った後にさらに保存する: 新しい中身は、それを拾った読みの役 (試聴)
            [.save, .promoteWaiting, .overlap([.save, .audition, .save])],
            // 作り直しの最中に 2 つ続けて保存してから出る
            [.save, .promoteWaiting, .audition, .overlap([.save, .save, .leave])],
            // 試聴の版の作り直しの最中に出て入り直す (7)
            [.save, .promoteWaiting, .audition, .save, .overlap([.leave, .audition])],
            [.save, .promoteWaiting, .audition, .overlap([.save, .leave, .audition]), .save, .leave],
            // 本番の版の作り直しの最中に入って出る (5)
            [.save, .promoteWaiting, .overlap([.audition, .leave])],
            // 本番の版の作り直しの最中に入り、試聴の中で読んでから出る: 試聴の中で読んだ版は本番にならない (生成が見つけた)
            [.save, .promoteWaiting, .overlap([.audition, .save, .leave])],
            // 試聴中に本番が落ちた後、試聴の版の作り直しの最中に出る (出る要求が本番を起こし直す)
            [.save, .promoteWaiting, .audition, .exitShown, .overlap([.save, .leave])],
            // 2 回目の反証 1: 出た時点のソースを本番に作り直す出方は、進行中の試聴の版を引き継ぎ、捨てたと名乗らない
            [.save, .promoteWaiting, .audition, .exitShown, .overlap([.leave])],
            [.save, .promoteWaiting, .audition, .save, .overlap([.leaveStuck])],
            [.save, .promoteWaiting, .audition, .overlap([.save, .leaveStuck])],
            // 2 回目の反証 3: 本番の版の作り直しの最中に出て、その作り直しが通らない (本番が居る・試聴の間に落ちた)
            [.save, .promoteWaiting, .overlapFailing([.audition, .save, .leave])],
            [.save, .promoteWaiting, .overlapFailing([.audition, .exitShown, .save, .leave])],
            [.save, .promoteWaiting, .overlap([.audition, .exitShown, .save, .leave])],
            // 試聴の版の作り直しが通らない
            [.save, .promoteWaiting, .audition, .overlapFailing([.save, .leaveStuck])],
            [.save, .promoteWaiting, .audition, .overlapFailing([.leave])],
            // 2 回目の反証 6: 作り直しの最中に試聴の中で X・Y を読み、出た後に X へ戻す (戻した保存は出た後の読みの役)
            [.save, .promoteWaiting, .audition, .overlap([.save, .save, .leave, .revert])],
            [.save, .promoteWaiting, .audition, .overlap([.save, .save, .revert])],
            // 重なりの中の終わり (Ctrl-C)
            [.save, .promoteWaiting, .audition, .overlap([.save, .stop])],
            [.save, .promoteWaiting, .overlap([.audition, .save, .stop])],
        ])
    @MainActor
    func overlappingBuildColumnsKeepTheSaveRole(_ ops: [Op]) async {
        let outcome = await Driver.runCase(ops: ops, ends: false)
        #expect(outcome == .pass, "\(outcome)")
    }

    /// 作り直す・起こし直す要求 (#3428)。**生成する検査の seed に頼らず、決定的に回す。** 頼んだ作り直しの役は保存と同じ規則
    /// (頼みを読んだ時点の試聴の状態・#3796) で決まり、起こし直しは置き場の最後に通った作り直しの版が当たる子の版のときだけ
    /// 起きる (2026-11-14 の決定)。
    @Test(
        "作り直す・起こし直す要求の列は、保存の役の規則と起こし直しの規則と事後条件を破らない (#3428)",
        arguments: [
            // 中身が変わっていなくても 1 回作り直す。作り直しの最中に頼むと、済んだ後に 1 回だけ (何度頼んでも)
            [Op.save, .rebuild, .promoteWaiting, .rebuild],
            [.save, .promoteWaiting, .overlap([.rebuild, .rebuild])],
            [.save, .promoteWaiting, .rebuildOverlap([.rebuild])],
            // 決定的な 2 列 (2026-11-10 の決定): 試聴中に頼む → 最中に出る / 本番で頼む → 最中に入る
            [.save, .promoteWaiting, .audition, .save, .rebuildOverlap([.leave])],
            [.save, .promoteWaiting, .rebuildOverlap([.audition])],
            [.save, .promoteWaiting, .rebuildOverlap([.audition, .leave])],
            // 作り直しの最中に、頼みの後に中身を変えた保存を読むと、保存が頼みを追い越す (1 回だけ・新しい中身)
            [.save, .promoteWaiting, .overlap([.rebuild, .save])],
            [.save, .promoteWaiting, .overlap([.save, .rebuild])],
            // 試聴の中で頼んで出た版は、出た後の作り直しの要求で本番へ作り直せる
            [.save, .promoteWaiting, .audition, .save, .leave, .rebuild],
            // 頼んだ作り直しが通らない: 前の版が走り続ける
            [.save, .promoteWaiting, .overlapFailing([.rebuild])],
            // 起こし直す: 本番 / 試聴の子 / 当たる子が居ない (最初の作り直しの失敗・試聴に入って保存の前)
            [.save, .promoteWaiting, .restart],
            [.save, .restart, .promoteWaiting, .restart],
            [.save, .promoteWaiting, .audition, .save, .restart, .leave],
            [.saveBuildFail, .restart],
            [.save, .promoteWaiting, .audition, .restart],
            // 置き場の版が当たる子の版でない (決定の例: 試聴で作った版 Z の後に本番を起こし直す・起こせなかった版の後)
            [.save, .promoteWaiting, .audition, .save, .leave, .restart],
            [.save, .promoteWaiting, .saveLaunchFail, .restart],
            // 試聴の中で同じ中身を作り直した後も、置き場の実行ファイルは本番の子を起こした成果物でないので notBuilt (2 回目の反証 1:
            // 世代に入らない資材を変えて頼んだ作り直しは、同じ世代で中身の違う実行ファイルを作る)
            [.save, .promoteWaiting, .audition, .rebuild, .leave, .restart],
            [.save, .promoteWaiting, .audition, .save, .rebuild, .leave, .restart],
            // 本番の中で同じ中身を作り直した後は、その成果物の子が本番なので起こし直せる
            [.save, .promoteWaiting, .rebuild, .promoteWaiting, .restart],
            // 作り直しの最中の起こし直しは、済んでから決める (受けて名乗る)。試聴の中で頼んで出たら捨てる
            [.save, .promoteWaiting, .overlap([.restart])],
            [.save, .promoteWaiting, .audition, .save, .overlap([.restart, .leave])],
            [.save, .promoteWaiting, .audition, .save, .overlap([.leave, .restart])],
            [.save, .promoteWaiting, .overlapFailing([.restart])],
            [.save, .promoteWaiting, .rebuildOverlap([.restart])],
            // 反証 1: 本番で読んだ保存の後に試聴で頼んだ作り直しは、本番・試聴の 2 回 (逆向きは、捨てたことを名乗ってから本番)
            [.save, .promoteWaiting, .overlap([.save, .audition, .rebuild])],
            [.save, .promoteWaiting, .overlap([.audition, .save, .leave, .rebuild])],
            // 反証 2: 本番で頼んだ作り直しは、後から試聴の中の保存が中身を変えると捨てて名乗る
            [.save, .promoteWaiting, .overlap([.rebuild, .audition, .save])],
            // 反証 3: 作り直しと起こし直しは頼んだ順
            [.save, .promoteWaiting, .overlap([.rebuild, .restart])],
            [.save, .promoteWaiting, .overlap([.restart, .rebuild])],
            [.save, .promoteWaiting, .rebuildOverlap([.restart, .rebuild])],
            // 反証 4: 試聴で起こし直す → 出る → 本番の保存 / 試聴中に本番を起こし直す → 試聴の作り直し (時計の場所)
            [.save, .promoteWaiting, .audition, .save, .restart, .leave, .save],
            [.save, .overlap([.restart, .audition]), .promoteWaiting, .save, .leave, .save],
            // 反証 6: 起こし直した子が最初の絵の前に落ちる (本番・試聴)
            [.save, .promoteWaiting, .restart, .exitWaitingFailing, .save],
            [.save, .promoteWaiting, .audition, .save, .restart, .exitAuditionFailing, .save, .leave],
            // 反証 7: 通らなかった作り直しの後の起こし直しは notBuilt
            [.save, .promoteWaiting, .saveBuildFail, .restart],
            // 2 回目の反証 2・3: まとめた作り直しの記録は、最後に読んだものの回 (頼みの後の保存は保存の回・保存の後の頼みは
            // 頼まれた回)
            [.save, .promoteWaiting, .overlap([.rebuild, .save])],
            [.save, .promoteWaiting, .overlap([.save, .rebuild])],
            [.save, .promoteWaiting, .rebuildOverlap([.save])],
            [.save, .promoteWaiting, .rebuildOverlap([.save, .rebuild])],
            // 2 回目の反証 4: 終わった試聴で頼んだ作り直しだけを捨てた回は、頼みを捨てたと名乗る (進行中は上の
            // `rebuildOverlap([.leave])`・ここは取りかかる前)。保存も捨てた回は保存の版を捨てたと名乗る
            [.save, .promoteWaiting, .overlap([.audition, .rebuild, .leave])],
            [.save, .promoteWaiting, .overlap([.audition, .rebuild, .save, .leave])],
            // 2 回目の反証 5: 出る要求が本番の版へ寄せた試聴の頼みを、次の試聴の保存が捨てる (作品のウィンドウの頼みと名乗る)
            [.save, .promoteWaiting, .audition, .overlap([.rebuild, .leaveStuck, .audition, .save])],
        ])
    @MainActor
    func rebuildAndRestartColumnsKeepTheirRules(_ ops: [Op]) async {
        let outcome = await Driver.runCase(ops: ops, ends: false)
        #expect(outcome == .pass, "\(outcome)")
    }

    /// 検査の結果を main actor の隔離の外へ持ち出す箱。書くのは 1 つの仕事だけで、読むのは待ち終えた後。
    nonisolated final class Outcome: @unchecked Sendable {
        var value: Probe.Outcome = .pass
    }

    /// 破れた事後条件。
    struct Violation: CustomStringConvertible {
        let number: Int
        let text: String
        var description: String { "事後条件 \(number): \(text)" }
    }

    /// 1 件の列を走らせる、台と環境の替え玉。
    @MainActor
    final class Driver {
        let session: WatchSession
        /// 起こした順の子。**番号は世代の通し番号 (G0, G1, …)。**
        private(set) var gens: [Process] = []
        /// いま映っている世代 (台の役)。台が乗り換えた合図を出した世代。
        private var shown: Int?
        /// 乗り換えを待っている世代 (台の役)。起こしてから、台が乗り換え・倒れ・受け取れないのどれかを決めるまで。
        private var waiting: Int?
        /// 台が受け取れない・自分のウィンドウへ倒れたと知らせた世代。**台は乗り換えない** (目録を置かない・読めない)。
        private var silent: Set<Int> = []
        /// 自分のウィンドウへ倒れたと知らせた世代 (目印を置いた)。**自分のウィンドウに描いている**ので、1 枚目を出した世代と読まれる
        /// (台が受け取れない世代 (``silent``) も、台の知らせが無いので、起動中の印で読まれて同じになる)。
        private var marked: Set<Int> = []
        /// 台が 1 度でも映した世代。
        private var everShown: Set<Int> = []
        /// 手放したと伝えられた世代の延べ回数。
        private var relinquished: [Int: Int] = [:]
        /// 自分から終わらせたが、まだ巡回が見ていない世代。**見るまで、台へ手放したと伝える義務は生じない。**
        private var unseen: Set<Int> = []
        /// 試聴の側として起こした世代 (#3565)。
        private var auditionGens: Set<Int> = []
        /// 試聴に入っているか (見張りの答えから写す)。
        private var auditioning = false
        /// 自分から終わらせたが、まだ巡回が見ていない試聴の子。
        private var unseenAudition: Set<Int> = []
        private var requestCount = 0
        private var stampCount = 0
        private var buildStatus: Int32 = 0
        private var launchFails = false
        private var launches = 0
        /// 見張りが作り直しに取りかかった回数 (作り直しの口が呼ばれた回数)。
        private var rebuilds = 0
        /// 起こせない版 (`save(launchFail)` の保存の世代)。**起こせないのは版の性質で、起こす拍の性質ではない** —
        /// 保留していた版を後の拍で起こすときも、その版を作った保存で決まる (#3789)。
        private var refusedStamps: Set<String> = []
        private var stopped = false
        private var history: [String] = []

        /// 保存の役 (#3796)。**模型は規則から直に書く: その保存を拾った見張りの読みを始めた時点の、模型の側の試聴の状態。**
        /// 見張りの内部の変数は写さない。役は保存ごと — 前の中身へ戻した保存も、戻した保存を読んだ時点の役で上書きする。
        enum Role: Equatable {
            case production
            /// 何回目の試聴の中で読んだか (``auditionIndex``)。
            case audition(Int)
        }
        /// 中身ごとの、最後の保存の役。模型が「見張りがこの保存を読む」と分かる時点で控える (``noteRead(_:)``)。
        /// 作り直す要求 (#3428) も、頼みを読んだ時点の役でいまの中身を上書きする (中身の変わらない保存)。
        private var stampRoles: [String?: Role] = [:]
        /// 置き場に在る実行ファイル — 作り直しの替え玉が最後に通した作り直しの成果物の番号 (#3428)。起こし直す要求が当たれるのは、
        /// この成果物から起こした子だけ (規則)。**中身 (世代) では比べない** — 世代に入らない変化を拾う作り直しは、同じ世代でも
        /// 別の成果物を作る。1 度も通していない・作り直している間・通らなかった後は `nil`。
        private var builtArtifact: Int?
        /// 通した作り直しの数。成果物ごとの番号 (実行ファイルの名前 `build-<番号>` に載せて、起こされた子がどの成果物かを読む)。
        private var artifactCount = 0
        /// 起こした子ごとの、起こした実行ファイルの成果物の番号 (見張りが起こす口へ渡した実行ファイルから読む)。
        private var launchArtifacts: [Int: Int] = [:]
        /// 成果物の実行ファイルを置く場所。
        private let artifacts: URL
        /// 起こし直す要求で起きる子の役 (規則: 頼みを読んだ時点の役)。模型が「この拍の起こす子は起こし直しの子」と分かる
        /// 拍だけ立てる (#3428)。起こし直しは作り直さないので、版の役 (``stampRoles``) では決めない。
        private var restartRole: Role?
        /// 作り直しを始めた時点の、その中身の役 (規則: 作り直しは、始めるまでに最後に読んだ中身の役で起きる)。作り直しの
        /// 最中に同じ中身を頼み直しても (``Step/rebuild``)、進行中の作り直しの役は変わらない (#3428)。
        private var builtRoles: [String?: Role] = [:]
        /// 起こした子ごとの、起こした時点までに始めた作り直しの数。どの作り直しの子かを見分ける (#3428)。
        private var launchBuilds: [Int: Int] = [:]
        /// 起こし直しで起こした子 (作り直しの子ではない)。
        private var restartGens: Set<Int> = []
        /// 起こした子ごとの、起こした時点の役。
        private var launchRoles: [Int: Role] = [:]
        /// 規則に反して起こした子 (役を控えていない版・試聴の中で読んだ版を本番の子に)。どの操作の後も見る (事後条件 7)。
        private var launchViolation: String?
        /// 出る要求が「出た時点のソースを本番に作り直す」と決めた試聴の番号のうち、最も新しいもの (模型の側の規則)。
        /// **この番号までの試聴で読んだ版は、本番の版として起きてよい** — 本番が居ない・プレビューを戻せない出方 (#3565 の例外)。
        /// 本番の版の作り直しの最中に出た試聴は、その作り直しが済んで本番が走っていなければここへ足す (#3796 の 2 回目の反証 3)。
        private var sourceRebuildThrough = 0
        /// 本番の版の作り直しの最中に出た試聴の番号 (模型の側)。
        private var leftWhileBuilding: Int?
        /// 立てると、門で止めた作り直しは通らない (``Op/overlapFailing(_:)``)。
        private var heldFails = false
        /// 次に取りかかる作り直しの役 (控えの列の規則で模型が決めた順・#3428)。空なら、その中身を最後に読んだ役 (``stampRoles``)。
        private var pendingBuildRoles: [Role] = []

        // 時計の場所 (`--keep-time`・#3428)。**表から直に書く**: 本番の子は本番の番号、試聴の子は試聴の番号 (空なら本番と同じ)。
        // 起こし直した子は新しい番号を受け、起きたらその役の番号を替える (本番を替えるとき、試聴中で試聴の番号が空なら、前の
        // 本番の番号に留める)。最初の絵の前に落ちたら戻す。出ると試聴の番号は空に戻る
        private var productionClock = 0
        private var auditionClock: Int?
        private var clockCount = 0
        /// 見張りが最後に選んだ番号 (``WatchSession/Hooks/selectClock``)。
        private var selectedClock = 0
        /// 見張りが最後に選んだ時計を、読むだけにしたか。**規則: 本番の子と時計を分け持つ試聴の子だけが読むだけ** (#4070)。
        private var selectedReadsOnly = false
        /// この試聴の間に、試聴と本番の時計が分かれたか (操作の履歴から追う。場所の番号の比べからは導かない)。
        /// 試聴の起こし直しの子・試聴中の本番の起こし直しの子が起きると立ち、出ると下りる。起こし直しの子が最初の絵の前に
        /// 落ちたら、起こす前に戻す。
        private var clocksSplit = false
        /// 起こし直しの子ごとの、渡した番号と、起こす前のその役の番号。
        private var restartClocks: [Int: (audition: Bool, fresh: Int, previous: Int?)] = [:]
        /// 起こし直しの子ごとの、起こす前の ``clocksSplit``。
        private var restartSplits: [Int: Bool] = [:]
        /// プレビューへ出した行。
        private var previewLog: [String] = []
        /// 作り直しの口が呼ばれたときの、ソースの世代 (呼ばれた順)。
        private var rebuiltStamps: [String?] = []
        /// 受けた入る要求の回数。試聴の 1 回ごとの番号。
        private var auditionIndex = 0
        /// 出る要求を出した試聴の番号 (受けると見込んで、要求を置く前に控える)。
        private var endedAuditions: Set<Int> = []
        /// 立てると、次の作り直しは ``releaseRebuild()`` まで終わらない。
        private var holdRebuild = false
        private var rebuildGate: CheckedContinuation<Void, Never>?
        /// 門で止めた拍が済んだか。
        private var heldBeatDone = false

        private var currentRole: Role { auditioning ? .audition(auditionIndex) : .production }

        /// 役 `role` の版を、いまどう扱うか (規則): 出る要求が本番の版へ寄せた試聴の版は本番。
        private func effective(_ role: Role) -> Role {
            if case .audition(let index) = role, index <= sourceRebuildThrough { return .production }
            return role
        }

        /// 見張りがいまの中身の保存を読むのは、役 `role` の時点である (保存ごとに上書きする)。
        private func noteRead(_ role: Role) {
            stampRoles[stamp] = role
        }

        func waitForRebuildGate() async {
            guard holdRebuild else { return }
            await withCheckedContinuation { rebuildGate = $0 }
        }

        private func releaseRebuild() {
            holdRebuild = false
            rebuildGate?.resume()
            rebuildGate = nil
        }

        init() throws {
            let directory = try TestScratch.directory("mokume-watch-model")
            artifacts = try TestScratch.directory("mokume-watch-model-artifacts")
            // 値を持つ前に自分を捕まえられないので、箱を挟む
            let box = Box()
            session = WatchSession(
                directory: directory, context: testContext(),
                hooks: WatchSession.Hooks(
                    rebuild: { directory in
                        let building = box.driver?.noteRebuild()
                        // 作り直しの途中で止めておく (作り直しの最中の出来事を演じる・``Op/overlap(_:)``)。止めた作り直しを
                        // 通らなくするかは門の後で読む
                        let held = box.driver?.holdRebuild ?? false
                        await box.driver?.waitForRebuildGate()
                        let status: Int32 = held && box.driver?.heldFails == true ? 1 : box.driver?.buildStatus ?? 0
                        let executable = status == 0 && building != nil ? box.driver?.noteBuilt() : nil
                        return RunCommand.Rebuilt(
                            status: status, output: "", executable: executable,
                            binPath: directory, product: "sketch")
                    },
                    launch: { executable, _, stamp, _ throws(CommandFailure) in
                        guard let driver = box.driver else { throw .cannotLaunch(tool: "sh", place: "", reason: "no driver") }
                        return try driver.launch(executable, stamp: stamp)
                    },
                    now: { 0 },
                    stamp: { _ in box.driver?.stamp },
                    selectClock: { choice in
                        box.driver?.selectedClock = choice.place
                        box.driver?.selectedReadsOnly = choice.readsOnly
                    }),
                stopTimeout: 0.5, finishTimeout: 0.5)
            session.overlapsGenerations = true
            box.driver = self
            session.relinquishesDisplay = { [unowned self] pids in
                for pid in pids { if let index = self.index(of: pid) { self.relinquished[index, default: 0] += 1 } }
            }
            // プレビューは本番へ戻れる役を演じる (戻れない回は `WatchAuditionRefutationTests` が見る)
            session.returnsPreviewToGeneration = { _ in true }
            // 作品のウィンドウは、いま走っている本番を映している (番号を名乗る子) 役を演じる
            session.windowShowsPID = { [unowned self] in
                (session.outgoing ?? session.child)?.processIdentifier
            }
            session.serveRequests()
        }

        final class Box { weak var driver: Driver? }

        /// 立てると、ソースの中身をこの世代にする (前の中身へ戻した保存・``Step/revert``)。新しい保存で下りる。
        private var stampOverride: String?

        private var stamp: String? { stampOverride ?? (stampCount == 0 ? nil : "s\(stampCount)") }

        /// 中身を変える (新しい世代)。
        private func changeSource() {
            stampCount += 1
            stampOverride = nil
        }

        /// 作り直しの口が呼ばれた。見張りは世代を取ってから作り直すので、作っているのはいまの世代の版である。
        @discardableResult
        private func noteRebuild() -> String?? {
            rebuilds += 1
            rebuiltStamps.append(stamp)
            builtRoles[stamp] = pendingBuildRoles.isEmpty ? stampRoles[stamp] : pendingBuildRoles.removeFirst()
            if launchFails, let stamp { refusedStamps.insert(stamp) }
            // 作り直している間・通らなかった後は、置き場の版が分からない (規則・#3428 の反証 7)
            builtArtifact = nil
            return .some(stamp)
        }

        /// 作り直しが通った。置き場の実行ファイルは、この作り直しの成果物になる (#3428)。成果物ごとに別の名前の実行ファイル
        /// (`/bin/sh` を指す記号のリンク) を返す。作れなければ `nil` (通ったが実行ファイルが無い回になる)。
        private func noteBuilt() -> URL? {
            artifactCount += 1
            let executable = artifacts.appendingPathComponent("build-\(artifactCount)")
            do {
                try FileManager.default.createSymbolicLink(atPath: executable.path, withDestinationPath: "/bin/sh")
            } catch {
                return nil
            }
            builtArtifact = artifactCount
            return executable
        }

        private func launch(_ executable: URL, stamp: String?) throws(CommandFailure) -> Process {
            launches += 1
            // 起こし直しの子は、新しい番号の時計の場所を受ける (起こせない回も番号は使い捨て)
            if restartRole != nil {
                clockCount += 1
                if selectedClock != clockCount {
                    launchViolation = launchViolation ?? "起こし直しの子に時計の場所 \(selectedClock) を渡した (規則では新しい番号 \(clockCount))"
                }
            }
            if let stamp, refusedStamps.contains(stamp) { throw .cannotLaunch(tool: "sh", place: "", reason: "the model refuses to start a child") }
            let process = Process()
            process.executableURL = executable
            // 1 行読んだら終わる子。`fail` を読むと終了コード 3 で終わる (最初の絵の前の失敗)
            process.arguments = ["-c", "read line; [ \"$line\" = fail ] && exit 3; exit 0"]
            process.standardInput = Pipe()
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            do {
                try process.run()
            } catch {
                throw .cannotLaunch(tool: "sh", place: "", reason: "\(error)")
            }
            // **試聴の子かは、その版の役で決める** (#3796)。試聴の中で読んだ版で、その試聴がまだ続いていれば試聴の子。
            // 試聴の子は、本番の乗り換えが決着してから起こされる (保存の拍とは限らない)。出た試聴の版が起きるのは、出る要求が
            // 本番を起こし直す回 (本番が居ない・プレビューを戻せない・#3565) だけで、それは本番の子である。**役は模型が控えた
            // ものだけを使う** — 控えていない版 (最初の 1 回の `nil` を除く) を起こしたら、それ自体を破れとして名乗る
            let role: Role
            if let restarting = restartRole {
                // 起こし直しの子は、頼みを読んだ時点の役 (#3428)
                role = restarting
                restartRole = nil
                restartGens.insert(gens.count)
                // 子が起きたので、その役の時計の場所を新しい番号へ替える (表)
                restartSplits[gens.count] = clocksSplit
                if restarting == .production {
                    if auditioning, auditionClock == nil { auditionClock = productionClock }
                    restartClocks[gens.count] = (false, clockCount, productionClock)
                    productionClock = clockCount
                    // 試聴の中で本番を起こし直すと、本番は新しい時計へ移り、試聴は前の時計に残る
                    if auditioning { clocksSplit = true }
                } else {
                    restartClocks[gens.count] = (true, clockCount, auditionClock)
                    auditionClock = clockCount
                    // 起こし直した試聴の子は、自分の新しい時計を持つ
                    clocksSplit = true
                }
            } else if let noted = builtRoles[stamp] ?? stampRoles[stamp] {
                role = noted
            } else if let stamp {
                role = .production
                launchViolation = launchViolation ?? "模型が役を控えていない版 \(stamp) を起こした"
            } else {
                role = .production
            }
            let isAudition: Bool
            switch role {
            case .audition(let index): isAudition = !endedAuditions.contains(index)
            case .production: isAudition = false
            }
            // 試聴の中で読んだ版を本番の子にしてよいのは、出る要求が本番の版へ寄せた試聴の版だけ
            if !isAudition, case .audition = effective(role) {
                launchViolation = launchViolation ?? "試聴の中で読んだ \(stamp ?? "-") (役 \(role)) を、本番の子として起こした"
            }
            // 作り直しの子は、その役の時計の場所を受ける (表)
            if !restartGens.contains(gens.count) {
                let expected = isAudition ? auditionClock ?? productionClock : productionClock
                if selectedClock != expected {
                    launchViolation = launchViolation ?? "\(isAudition ? "試聴" : "本番")の子 G\(gens.count) に時計の場所 \(selectedClock) を渡した (規則では \(expected))"
                }
            }
            // 本番の子と時計を分け持つ試聴の子だけが、時計を読むだけ。分け持つかは場所の番号でなく、この試聴の間の起こし直しの
            // 履歴 (``clocksSplit``) で決める
            let readsOnly = isAudition && !clocksSplit
            if selectedReadsOnly != readsOnly {
                launchViolation = launchViolation ?? "\(isAudition ? "試聴" : "本番")の子 G\(gens.count) の時計を\(selectedReadsOnly ? "読むだけ" : "書く") にした (規則では\(readsOnly ? "読むだけ" : "書く"))"
            }
            launchRoles[gens.count] = role
            launchBuilds[gens.count] = rebuilds
            if let artifact = Int(executable.lastPathComponent.replacingOccurrences(of: "build-", with: "")) {
                launchArtifacts[gens.count] = artifact
            } else {
                launchViolation = launchViolation ?? "作り直しの成果物でない実行ファイル \(executable.path) で G\(gens.count) を起こした"
            }
            if isAudition { auditionGens.insert(gens.count) }
            // **本番の子は、どの口で起こしても、起こした時点から乗り換えを待つ** (``WatchSession`` は新しい子を起こすたびに
            // 待ち印を立てる)。保存だけでなく、試聴を出る要求が本番を起こし直す回 (本番が居ない・#3565) や、
            // 進行中の作り直しが出た後に着く回も同じ
            if !isAudition { waiting = gens.count }
            if let stamp { launchStamps[gens.count] = stamp }
            gens.append(process)
            return process
        }

        private func index(of pid: Int32) -> Int? { gens.firstIndex { $0.processIdentifier == pid } }
        private func pid(_ index: Int) -> Int32 { gens[index].processIdentifier }
        private func isAlive(_ index: Int) -> Bool { gens[index].isRunning }
        private func alive() -> Set<Int> { Set(gens.indices.filter { isAlive($0) }) }
        /// 生きている世代のうち、本番の側。
        private func productionAlive() -> Set<Int> { alive().subtracting(auditionGens) }
        /// 生きている試聴の子。
        private func auditionAlive() -> Set<Int> { alive().intersection(auditionGens) }

        /// 子が消えるのを待つ (待つ側が期限を持つ)。
        private func waitUntilGone(_ index: Int, timeout: TimeInterval = 2) {
            let deadline = DispatchTime.now() + timeout
            while gens[index].isRunning, DispatchTime.now() < deadline { Thread.sleep(forTimeInterval: 0.002) }
        }

        private func finish(_ index: Int, line: String) {
            guard isAlive(index), let pipe = gens[index].standardInput as? Pipe else { return }
            try? pipe.fileHandleForWriting.write(contentsOf: Data((line + "\n").utf8))
            waitUntilGone(index)
        }

        /// 1 拍回し、**その拍で起きた試聴の子**を返す。**保留していた試聴の子は、本番の乗り換えが決着した後の最初の拍で
        /// 起きる** (``WatchSession/resumePendingAudition()``・その拍の保存の作り直しは次の拍に回るので、保存の操作は
        /// その次の拍まで回す)。保存でも入る要求でもない拍で生きている世代が増えるので、「この操作で世代が変わらない」
        /// 約束は、この戻り値を引いて比べる
        /// (引いてよいのは ``deferredStamp`` の版が保留にあり得る回の、その版の子だけ・``pendingLaunches(_:of:)``)。
        @discardableResult
        private func beat() async -> Set<Int> {
            let auditionsBefore = auditionGens
            await WatchCommand.step(session, stopped: { false }, preview: { [self] line, _ in
                if let line { previewLog.append(line) }
            })
            unseen = []
            unseenAudition = []
            let started = auditionGens.subtracting(auditionsBefore)
            // 試聴の子が起きれば、保留は済んだ。保存の操作は、この後で作り直しに取りかかった拍の結果から ``deferredStamp``
            // を決め直す (その保存の版が保留に回ったか)
            if !started.isEmpty { deferredStamp = nil }
            return started
        }

        /// 試聴中に、成功する保存が着いた (保留した試聴の子が居るかもしれない)。**保留の有無は ``WatchSession`` の内部の
        /// 事情なので、模型は「あり得る」だけを控える** — 試聴の子が起きるか、出る・入る要求を受ける・終えるまで立ったまま。
        /// 立っていない回の拍で試聴の子が起きたら、免除せずに破れとして見る。**控えるのは保留にあり得る版 (保存の世代)** で、
        /// 免除するのはその版の子だけ — 別の版の子が起きたら破れとして見る (#3794)。
        private var deferredStamp: String?

        /// 起こした子の版 (起こしたときに見張りが渡した世代)。番号は世代の通し番号。
        private var launchStamps: [Int: String] = [:]

        /// `started` のうち、保留にあり得た版 `deferred` の子。
        private func pendingLaunches(_ started: Set<Int>, of deferred: String?) -> Set<Int> {
            guard let deferred else { return [] }
            return started.filter { launchStamps[$0] == deferred }
        }

        /// 見張りが見る前に置いた保存 (`placed`) を、試聴に入っていない見張りが普通の保存として扱ったか (事後条件 5 の表)。
        /// 入る要求が断られた回 (本番が居ない) に使う。
        /// 作り直しが通り起こせる保存なので、`launchesBefore` より後に、その版の本番の子が起きていなければならない。
        private func checkPlacedSaveStartedProduction(placed: String?, launchesBefore: Int) -> Violation? {
            let launched = Set(launchesBefore..<gens.count).subtracting(auditionGens)
            if launched.isEmpty || launched.contains(where: { launchStamps[$0] != placed }) {
                return Violation(
                    number: 5,
                    text: "試聴に入っていない見張りの保存 (\(placed ?? "-")) が、その版の本番の子を起こさない (起きた子 \(launched.sorted().map { "G\($0)=\(launchStamps[$0] ?? "-")" }))")
            }
            return nil
        }

        /// 巡回がまだ見ていない子の離脱があれば、1 拍回して済ませる。**要求の前後を比べる操作は、離脱の後始末を
        /// 要求の結果と取り違えない**ために、先にこれを済ませる。
        private func settleUnseen() async {
            if !unseen.isEmpty || !unseenAudition.isEmpty { await beat() }
        }

        /// 区画 `watch` へ要求を置いて 1 拍回し、受けたかを返す。
        private func ask(_ action: String) async throws -> (accepted: Bool, started: Set<Int>) {
            let (report, started) = try await askReport(action)
            return (report["accepted"] as? Bool == true, started)
        }

        /// 区画 `watch` へ要求を置いて 1 拍回し、応答を返す。
        private func askReport(_ action: String) async throws -> (report: [String: Any], started: Set<Int>) {
            try placeRequest(action)
            let started = await beat()
            return (try lastReport(), started)
        }

        /// 区画 `watch` へ要求を置くが、拍は回さない。
        private func placeRequest(_ action: String) throws {
            requestCount += 1
            let request = #"{"id":"m\#(requestCount)","action":"\#(action)"}"#
            try AtomicFile.write(
                Data(request.utf8), to: WorkDirectory.requestURL(under: session.watchFacet))
        }

        /// 最後の応答。
        private func lastReport() throws -> [String: Any] {
            let data = try Data(contentsOf: WorkDirectory.reportURL(under: session.watchFacet))
            return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        }

        /// 起こし直す要求を、いま行うとどうなるか (規則・#3428)。**見張りの内部の変数は写さない。**
        enum RestartExpectation: Equatable {
            /// 試聴の中で頼んだが、その試聴がもう終わっている。捨てて名乗る。
            case dropped
            /// 断る (当たる子が居ない・置き場の版が当たる子の版でない)。
            case declined(WatchReport.Reason)
            /// 役 `role` の側に、版 `stamp` の子を起こし直す。`target` は起こし直す相手の世代。
            case restarted(Role, stamp: String?, target: Int)
        }

        /// 規則: 役 `role` の起こし直しが当たる子は、試聴の版なら (その試聴が続いていれば) 試聴の子、本番の版なら本番の側の
        /// 新しい子。居なければ noTarget。置き場の実行ファイル (``builtArtifact``) が、当たる子を起こした作り直しの成果物で
        /// なければ notBuilt (中身が同じでも、別の作り直しの成果物なら断る)。
        private func expectedRestart(_ role: Role) -> RestartExpectation {
            let target: Int?
            switch role {
            case .audition(let index):
                guard auditioning, auditionIndex == index else { return .dropped }
                target = auditionAlive().max()
            case .production:
                target = productionAlive().max()
            }
            guard let target else { return .declined(.noTarget) }
            guard let builtArtifact, builtArtifact == launchArtifacts[target] else { return .declined(.notBuilt) }
            return .restarted(role, stamp: launchStamps[target], target: target)
        }

        /// 起こし直す要求の結末を名乗った行 (プレビュー)。
        private func restartLines(since start: Int) -> [String] {
            let lines = [
                WatchSession.restartLine(.restarted(audition: false)), WatchSession.restartLine(.restarted(audition: true)),
                WatchSession.restartLine(.dropped), WatchSession.restartLine(.declined(.noTarget)),
                WatchSession.restartLine(.declined(.notBuilt)),
            ]
            return previewLog[start...].filter { lines.contains($0) || $0.hasPrefix("Could not restart it: ") }
        }

        /// 起こし直す要求の結末の行の、規則どおりの文。
        private func restartLine(for expectation: RestartExpectation) -> String {
            switch expectation {
            case .dropped: WatchSession.restartLine(.dropped)
            case .declined(let reason): WatchSession.restartLine(.declined(reason))
            case .restarted(let role, _, _): WatchSession.restartLine(.restarted(audition: role != .production))
            }
        }

        private func placeFellBackMarker(of index: Int) throws {
            let facet = WatchCommand.viewportFacet(under: session.facetBase)
            try FileManager.default.createDirectory(at: facet, withIntermediateDirectories: true)
            try Data().write(to: WorkDirectory.fellBackURL(forProcess: pid(index), under: facet))
            marked.insert(index)
        }

        private func name(_ indices: Set<Int>) -> String {
            "{" + indices.sorted().map { "G\($0)" }.joined(separator: ",") + "}"
        }

        /// 世代の様子を 1 行で。赤の文面の材料。
        private func describe() -> String {
            gens.indices.map { index in
                var tags = [isAlive(index) ? "生" : "死"]
                if shown == index { tags.append("映") }
                if waiting == index { tags.append("待") }
                if session.child === gens[index] { tags.append("child") }
                if session.outgoing === gens[index] { tags.append("outgoing") }
                if auditionGens.contains(index) { tags.append("試聴") }
                if let count = relinquished[index] { tags.append("手放し×\(count)") }
                return "G\(index)[\(tags.joined(separator: "・"))]"
            }.joined(separator: " ")
        }

        /// 1 件の列を走らせる。
        static func runCase(ops: [Op], ends: Bool) async -> Probe.Outcome {
            let driver: Driver
            do { driver = try Driver() } catch { return .fail("検査の準備に失敗: \(error)") }
            defer { driver.teardown() }
            let sequence = ops + (ends ? [Op.stop] : [])
            for op in sequence {
                if op == .none { continue }
                driver.history.append(op.description)
                let violation: Violation?
                do { violation = try await driver.apply(op) ?? driver.checkAfter() } catch {
                    return .fail("操作 \(op) が投げた: \(error)")
                }
                if let violation {
                    let shownOps = sequence.filter { $0 != .none }.map(\.description).joined(separator: ",")
                    return .fail("\(violation) — ops=[\(shownOps)] 直前までの操作=\(driver.history.dropLast()) 世代: \(driver.describe())")
                }
            }
            if ends, let violation = await driver.checkNoLaunchAfterStop() {
                return .fail("\(violation) — ops=[\(driver.history.joined(separator: ","))]")
            }
            return driver.checkSend().map {
                .fail("\($0) — ops=[\(driver.history.joined(separator: ","))] 世代: \(driver.describe())")
            } ?? .pass
        }

        private func teardown() {
            session.stopBlocking()
            for process in gens where process.isRunning { process.terminate() }
        }

        // MARK: 操作

        /// 操作を行い、**その操作に固有の約束** (事後条件 4 と、作り直しの失敗が走る世代を落とさない約束) を見る。
        private func apply(_ op: Op) async throws -> Violation? {
            let before = alive()
            switch op {
            case .none: return nil
            case .beat:
                await beat()
                return nil

            case .save, .saveBuildFail, .saveLaunchFail, .rebuild:
                guard !stopped else { return nil }
                if op == .rebuild {
                    // 作り直す要求 (#3428): 中身は変えず、頼みを読む拍の役で、いまの中身を「読んだ」ことにする (中身の変わらない
                    // 保存)。要求は拍の頭で読まれ、同じ拍の読みが取りかかる
                    await settleUnseen()
                    try placeRequest("rebuild")
                } else {
                    changeSource()
                }
                // 要求の無い拍で読むので、いまの役 (作り直す要求も、頼みを読む拍のいまの役)
                noteRead(currentRole)
                buildStatus = op == .saveBuildFail ? 1 : 0
                launchFails = op == .saveLaunchFail
                let childBefore = session.child.flatMap { child in gens.firstIndex { $0 === child } }
                let unseenBefore = unseen
                let productionBefore = productionAlive()
                let auditioningBefore = auditioning
                let deferredBefore = deferredStamp
                let rebuildsBefore = rebuilds
                var started = await beat()
                var startedByRebuild = started
                // **保留していた試聴の子を起こしに行った拍は、作り直しに取りかからない** (``beat()``。起こせなかった回も
                // 同じ)。この保存は次の拍に残るので、取りかかる拍まで回してから比べる。模型の保存の操作は「保存を置き、
                // 見張りが作り直しに取りかかる」までを 1 つとし、残った保存を次の操作の拍へ持ち越さない — 1 拍の中では
                // 要求 (``WatchSession/answerRequests()``) が作り直し (``WatchSession/tick()``) より先に効くので、持ち越すと
                // 次の操作 (入る・出る要求) の結果に保存の結果が混ざる (#3789)。保存を見る前の要求が同じ拍に入る重なりは、
                // 保存と要求を 1 つにした操作 (入る要求は ``Op/saveThenAudition``・#3794、出る要求は ``Op/saveThenLeave``・
                // #3796) が生成する。
                // 模型では保存のたびに世代が変わるので、取りかからない拍は 1 つまで
                if rebuilds == rebuildsBefore, !stopped {
                    startedByRebuild = await beat()
                    started.formUnion(startedByRebuild)
                }
                // 作り直しが通った試聴中の保存は、取りかかった拍で試聴の子が起きなければ保留に回りうる
                if auditioningBefore, buildStatus == 0, !stopped { deferredStamp = startedByRebuild.isEmpty ? stamp : nil }
                // 作り直す要求は、いつも受け、中身が変わっていなくても 1 回だけ作り直す (#3428 の完了条件 1)
                if op == .rebuild {
                    if try lastReport()["accepted"] as? Bool != true {
                        return Violation(number: 7, text: "作り直す要求を断った")
                    }
                    if rebuilds != rebuildsBefore + 1 {
                        return Violation(number: 7, text: "作り直す要求で、作り直しが \(rebuilds - rebuildsBefore) 回 (1 回のはず)")
                    }
                }
                // 7. 試聴中の保存は、本番の側を動かさない (本番の子は入れ替わらず、生きている本番は落ちない)
                if auditioningBefore, unseenBefore.isEmpty {
                    let childAfter = session.child.flatMap { child in gens.firstIndex { $0 === child } }
                    if childAfter != childBefore {
                        return Violation(number: 7, text: "試聴中の保存で、本番の子が G\(childBefore.map(String.init) ?? "-") から G\(childAfter.map(String.init) ?? "-") へ入れ替わった")
                    }
                    if !productionBefore.isSubset(of: alive()) {
                        return Violation(number: 7, text: "試聴中の保存で、生きていた本番の側が落ちた (前 \(name(productionBefore)) → 後 \(name(alive())))")
                    }
                }
                guard unseenBefore.isEmpty else { return nil }
                switch op {
                case .saveBuildFail:
                    // 作り直しが通らない回は、走っている世代を 1 つも落とさない (事後条件 5 の裏)
                    if alive().subtracting(pendingLaunches(started, of: deferredBefore)) != before {
                        return Violation(number: 5, text: "作り直しが通らない保存で、走っている世代が変わった (前 \(name(before)) → 後 \(name(alive())))")
                    }
                case .saveLaunchFail:
                    // 起こせなかった回は、直前の世代 (映っている・乗り換えを待っている) を落とさない
                    if let childBefore, before.contains(childBefore), !isAlive(childBefore) {
                        return Violation(number: 5, text: "子を起こせなかった保存で、走っていた G\(childBefore) が落ちた")
                    }
                default: break
                }
                return nil

            case .promoteWaiting, .promoteAnonymous:
                guard let target = waiting, isAlive(target) else { return nil }
                await session.generationPromoted(pid: op == .promoteWaiting ? pid(target) : nil)
                session.generationShown(pid: pid(target))
                shown = target
                everShown.insert(target)
                waiting = nil
                if productionAlive() != [target] {
                    return Violation(
                        number: 4,
                        text: "待っている G\(target) の合図の後、生きている本番の側が \(name(productionAlive())) (待っている世代だけのはず。前の世代を畳んでいない)")
                }
                return nil

            case .promoteStale:
                guard
                    let stale = productionAlive().filter({
                        $0 != waiting && !silent.contains($0)
                    }).max()
                else { return nil }
                let waitingBefore = session.waitingGeneration
                await session.generationPromoted(pid: pid(stale))
                session.generationShown(pid: pid(stale))
                shown = stale
                everShown.insert(stale)
                // 合図された世代は、合図で落ちない (台が映した世代を道具が畳んではならない)
                if !isAlive(stale) {
                    return Violation(number: 4, text: "待っていない G\(stale) の乗り換えの合図で、合図された G\(stale) が落ちた")
                }
                if let waitingBefore, let target = gens.firstIndex(where: { $0 === waitingBefore }), target == waiting {
                    // 待っている世代 (別の世代) のまま、何も畳まない
                    if session.waitingGeneration !== waitingBefore {
                        return Violation(number: 4, text: "待っていない G\(stale) の合図で、G\(target) の待ちが下りた")
                    }
                    if alive() != before {
                        return Violation(number: 4, text: "待っていない G\(stale) の合図で、生きている世代が変わった (前 \(name(before)) → 後 \(name(alive())))")
                    }
                }
                return nil

            case .fellBack, .undeliverable:
                guard let target = waiting, isAlive(target) else { return nil }
                let label = op == .fellBack ? "倒れた知らせ" : "受け取れない知らせ"
                let first = try await notify(op, about: target)
                guard first else {
                    return Violation(number: 4, text: "待っている G\(target) の\(label)を受けなかった (待ち \(session.waitingGeneration == nil ? "なし" : "あり"))")
                }
                waiting = nil
                silent.insert(target)
                if productionAlive() != [target] {
                    return Violation(number: 4, text: "待っている G\(target) の\(label)の後、生きている本番の側が \(name(productionAlive())) (前の世代を畳んでいない)")
                }
                // 2 度目は何もしない (ウィンドウごとに知らせが来る)
                if try await notify(op, about: target) {
                    return Violation(number: 4, text: "待っている G\(target) の\(label)を 2 度受けた")
                }
                return nil

            case .fellBackStale, .undeliverableStale:
                guard let stale = productionAlive().filter({ $0 != waiting && !silent.contains($0) }).max() else { return nil }
                let waitingBefore = session.waitingGeneration
                let label = op == .fellBackStale ? "倒れた知らせ" : "受け取れない知らせ"
                if try await notify(op, about: stale, stale: true) {
                    return Violation(number: 4, text: "待っていない G\(stale) の\(label)を受けた")
                }
                if alive() != before || session.waitingGeneration !== waitingBefore {
                    return Violation(number: 4, text: "待っていない G\(stale) の\(label)で、世代が動いた (前 \(name(before)) → 後 \(name(alive())))")
                }
                return nil

            case .exitWaiting:
                guard let target = waiting, isAlive(target) else { return nil }
                finish(target, line: "bye")
                unseen.insert(target)
                return nil

            case .exitWaitingFailing:
                guard let target = waiting, isAlive(target), session.waitingGeneration === gens[target] else { return nil }
                let outgoing = session.outgoing.flatMap { outgoing in gens.firstIndex { $0 === outgoing } }
                let previous = outgoing.flatMap { index in
                    index != target && isAlive(index) && (shown == index || silent.contains(index)) ? index : nil
                }
                // **倒れた目印だけが 1 枚目の証拠の世代は、見ない。** 目印は新しい子を起こす前に掃かれるので、残っているかは
                // 子を起こした順に依る (置いた目印の寿命は ``WatchSession`` の内部の事情で、約束ではない)
                let ambiguous = outgoing.map { marked.contains($0) && !silent.contains($0) && shown != $0 } ?? false
                let reportBefore = session.lastReport
                let linesBefore = previewLog.count
                let restarted = revertRestartClock(of: target)
                finish(target, line: "fail")
                await beat()
                if restarted, let violation = checkRestartedChildFailed(target, reportBefore: reportBefore, linesBefore: linesBefore) {
                    return violation
                }
                if ambiguous { return nil }
                // 最初の絵を出す前に失敗で終わった回 (#3172)。前の版が映っていて生きていれば残し、そうでなければ畳む
                if let previous {
                    if productionAlive() != [previous] {
                        return Violation(
                            number: 5,
                            text: "最初の絵の前に失敗した G\(target) の後、映っていた G\(previous) が残らない (生きている本番の側は \(name(productionAlive())))")
                    }
                } else if !productionAlive().isEmpty {
                    return Violation(number: 5, text: "最初の絵の前に失敗した G\(target) の後、前の版が居ないのに生きている世代が残る (\(name(productionAlive())))")
                }
                return nil

            case .exitShown:
                guard let target = shown, isAlive(target) else { return nil }
                finish(target, line: "bye")
                unseen.insert(target)
                return nil

            case .audition, .saveThenAudition:
                guard !stopped else { return nil }
                await settleUnseen()
                let before = alive()
                let productionBefore = productionAlive()
                let expected = !auditioning && !productionAlive().isEmpty
                let deferredBefore = deferredStamp
                let withSave = op == .saveThenAudition
                let rebuildsBefore = rebuilds
                let launchesBefore = gens.count
                if withSave {
                    placeUnseenSave()
                    // 同じ拍の要求の後に読むので、受けると見込めば入った後の試聴の役
                    noteRead(expected ? .audition(auditionIndex + 1) : currentRole)
                }
                let placed = stamp
                let (accepted, startedByRequest) = try await ask("audition")
                var started = startedByRequest
                var startedByRebuild = startedByRequest
                // 保留していた試聴の子を起こしに行った拍は、同じ拍の保存に取りかからない (保存の操作と同じ)
                if withSave, rebuilds == rebuildsBefore, !stopped {
                    startedByRebuild = await beat()
                    started.formUnion(startedByRebuild)
                }
                if accepted != expected {
                    return Violation(
                        number: 7,
                        text: "入る要求を\(accepted ? "受けた" : "断った") (期待は\(expected ? "受ける" : "断る")・試聴中 \(auditioning)・本番の側 \(name(productionAlive())))")
                }
                if accepted {
                    auditioning = true
                    auditionIndex += 1
                    deferredStamp = nil
                }
                // **同じ拍の保存は、要求の後に効く。** 試聴に入っていれば (受けた・入っていて断った) 試聴の版になり、
                // 本番の側は動かない (事後条件 7 の後半)。入っておらず断った回 (本番が居ない) は、普通の保存である
                if withSave {
                    guard auditioning else {
                        return checkPlacedSaveStartedProduction(placed: placed, launchesBefore: launchesBefore)
                    }
                    if productionAlive() != productionBefore {
                        return Violation(
                            number: 7,
                            text: "入る要求と同じ拍の保存で、本番の側が動いた (前 \(name(productionBefore)) → 後 \(name(productionAlive())))")
                    }
                    // **入る要求そのものは何も起こさない。** 起きてよい試聴の子は、作り直しに取りかかった拍の同じ拍の保存の版と、
                    // 断った回に取りかからなかった拍で起きた、保留にあり得た版だけ
                    let resumed = started.subtracting(startedByRebuild)
                    let foreign =
                        startedByRebuild.filter { launchStamps[$0] != placed }
                        .union(resumed.subtracting(accepted ? [] : pendingLaunches(resumed, of: deferredBefore)))
                    if !foreign.isEmpty {
                        return Violation(
                            number: 7,
                            text: "入る要求の拍に、同じ拍の保存 (\(placed ?? "-")) でない版の試聴の子が起きた (\(foreign.sorted().map { "G\($0)=\(launchStamps[$0] ?? "-")" }))")
                    }
                    deferredStamp = startedByRebuild.isEmpty ? placed : nil
                    return nil
                }
                // **受理した回は保留を捨てる** (``WatchSession/enterAudition``)。受理した拍で試聴の子が起きれば破れ。
                // 断った回の拍だけ、保留していた版の試聴の子が起きうる
                if alive().subtracting(accepted ? [] : pendingLaunches(started, of: deferredBefore)) != before {
                    return Violation(number: 7, text: "入る要求で、生きている世代が変わった (前 \(name(before)) → 後 \(name(alive())))")
                }
                return nil

            case .leave, .saveThenLeave:
                guard !stopped else { return nil }
                await settleUnseen()
                let productionBefore = productionAlive()
                let withSave = op == .saveThenLeave
                let launchesBefore = gens.count
                if withSave {
                    placeUnseenSave()
                    // 同じ拍の要求の後に読むので、出た後の本番の役
                    noteRead(.production)
                }
                if auditioning {
                    endedAuditions.insert(auditionIndex)
                    // 本番が居なければ、出た時点のソースを本番に作り直す (この試聴の版は本番の子として起きてよい)
                    if productionBefore.isEmpty { sourceRebuildThrough = auditionIndex }
                }
                let placed = stamp
                let (accepted, _) = try await ask("leave")
                if accepted != auditioning {
                    return Violation(number: 7, text: "出る要求を\(accepted ? "受けた" : "断った") (試聴中 \(auditioning))")
                }
                if accepted {
                    auditioning = false
                    auditionClock = nil
                    clocksSplit = false
                    deferredStamp = nil
                    if !auditionAlive().isEmpty {
                        return Violation(number: 7, text: "出る要求の後に、試聴の子が残る (\(name(auditionAlive())))")
                    }
                }
                // **同じ拍の保存は、要求の後に読まれる。** 保存の役は読んだ時点で決まる (#3796) ので、試聴を出た後
                // (受けた・入っておらず断った) に読んだ保存は本番の版で、その版の本番の子が起きる。出る要求そのものは本番を
                // 動かさないが、この操作では同じ拍の保存が本番を入れ替える
                if withSave {
                    return checkPlacedSaveStartedProduction(placed: placed, launchesBefore: launchesBefore)
                }
                guard accepted else { return nil }
                // 本番が居ない回は、出た時点のソースで本番を起こし直す (守る相手が居ない)。居る回は動かさない
                if !productionBefore.isEmpty, productionAlive() != productionBefore {
                    return Violation(number: 7, text: "出る要求で、本番の側が動いた (前 \(name(productionBefore)) → 後 \(name(productionAlive())))")
                }
                return nil

            case .restart:
                guard !stopped else { return nil }
                await settleUnseen()
                let expectation = expectedRestart(currentRole)
                let before = alive()
                let productionBefore = productionAlive()
                let launchesBefore = gens.count
                let rebuildsBefore = rebuilds
                let reportBefore = session.lastReport
                let linesBefore = previewLog.count
                let deferredBefore = deferredStamp
                if case .restarted(let role, _, _) = expectation { restartRole = role }
                let (report, started) = try await askReport("restart")
                restartRole = nil
                let accepted = report["accepted"] as? Bool == true
                let lines = restartLines(since: linesBefore)
                if lines != [restartLine(for: expectation)] {
                    return Violation(number: 7, text: "起こし直す要求の名乗りが \(lines) (規則では \(restartLine(for: expectation)))")
                }
                if rebuilds != rebuildsBefore {
                    return Violation(number: 7, text: "起こし直す要求で作り直した")
                }
                // 記録は書かない (作り直しではない)。同じ拍の頭で保留していた試聴の子が起きた回は、その記録が書かれる
                if session.lastReport != reportBefore, pendingLaunches(started, of: deferredBefore).isEmpty {
                    return Violation(number: 7, text: "起こし直す要求で、区画 build の記録が変わった")
                }
                switch expectation {
                case .dropped:
                    return Violation(number: 7, text: "模型の外: 拍の頭の起こし直しで試聴が終わっていた")
                case .declined(let reason):
                    if accepted || report["reason"] as? String != reason.rawValue {
                        return Violation(number: 7, text: "起こし直す要求の応答が \(report) (規則では \(reason.rawValue) で断る)")
                    }
                    // 何もしない (断った回の拍で起きてよいのは、保留にあり得た試聴の子だけ)
                    if alive().subtracting(pendingLaunches(started, of: deferredBefore)) != before {
                        return Violation(number: 7, text: "断った起こし直しで、生きている世代が変わった (前 \(name(before)) → 後 \(name(alive())))")
                    }
                case .restarted(let role, let stamp, let target):
                    if !accepted {
                        return Violation(number: 7, text: "起こし直す要求を断った (\(report["reason"] ?? "-"))。規則では G\(target) を起こし直す")
                    }
                    let launched = Set(launchesBefore..<gens.count)
                    let side = role == .production ? launched.subtracting(auditionGens) : launched.intersection(auditionGens)
                    if launched.count != 1 || side.count != 1 || side.contains(where: { launchStamps[$0] != stamp }) {
                        return Violation(
                            number: 7,
                            text: "G\(target) の起こし直しで起きた子が \(launched.sorted().map { "G\($0)=\(launchStamps[$0] ?? "-")" }) (規則では \(role) の側に版 \(stamp ?? "-") の子が 1 つ)")
                    }
                    // 試聴の子の起こし直しは本番の側を動かさない。前の試聴の子は止まる
                    if role != .production {
                        if productionAlive() != productionBefore {
                            return Violation(number: 7, text: "試聴の子の起こし直しで、本番の側が動いた")
                        }
                        if isAlive(target) {
                            return Violation(number: 7, text: "起こし直した試聴の子 G\(target) が残る")
                        }
                    }
                }
                return nil

            case .overlap(let steps):
                return try await overlap(steps)

            case .overlapFailing(let steps):
                return try await overlap(steps, heldFails: true)

            case .rebuildOverlap(let steps):
                return try await overlap(steps, requested: true)

            case .exitAudition:
                guard let target = auditionAlive().first else { return nil }
                finish(target, line: "bye")
                unseenAudition.insert(target)
                if productionAlive() != before.subtracting(auditionGens) {
                    return Violation(number: 7, text: "試聴の子 G\(target) が自分で終わって、本番の側が動いた")
                }
                return nil

            case .exitAuditionFailing:
                guard let target = auditionAlive().first else { return nil }
                await settleUnseen()
                let productionBefore = productionAlive()
                let reportBefore = session.lastReport
                let linesBefore = previewLog.count
                let restarted = revertRestartClock(of: target)
                finish(target, line: "fail")
                await beat()
                if restarted, let violation = checkRestartedChildFailed(target, reportBefore: reportBefore, linesBefore: linesBefore) {
                    return violation
                }
                if productionAlive() != productionBefore {
                    return Violation(
                        number: 7,
                        text: "最初の絵の前に失敗した試聴の子 G\(target) の後、本番の側が動いた (前 \(name(productionBefore)) → 後 \(name(productionAlive())))")
                }
                if !auditioning { return Violation(number: 7, text: "試聴の子が落ちて、試聴が終わった") }
                return nil

            case .promoteAudition, .undeliverableAudition:
                guard let target = auditionAlive().first else { return nil }
                let waitingBefore = session.waitingGeneration
                let received: Bool
                if op == .promoteAudition {
                    received = await session.generationPromoted(pid: pid(target)) != nil
                    session.generationShown(pid: pid(target))
                    everShown.insert(target)
                } else {
                    received = await session.retireAfterUndeliverable(waiting: waitingBefore, pid: pid(target)) != nil
                }
                if received || alive() != before || session.waitingGeneration !== waitingBefore {
                    return Violation(number: 4, text: "試聴の子 G\(target) の合図 (\(op)) で、本番の側が動いた (前 \(name(before)) → 後 \(name(alive())))")
                }
                return nil

            case .stop:
                guard !stopped else { return nil }
                stopped = true
                deferredStamp = nil
                session.noteStopRequested()
                await session.end()
                return nil
            }
        }

        /// 門で止まらなかったこと。期限で門を開け、止めた拍を畳んでから投げる。
        struct GateTimeout: Error, CustomStringConvertible {
            let description: String
        }

        /// 保存して、その作り直しを門で止め、止めている間に `steps` を起こしてから門を開ける (#3796 の反証)。
        ///
        /// **期待は規則から書く: 保存の役は、その保存を拾った見張りの読みを始めた時点の試聴の状態。** 読んだ版は、役が本番なら
        /// 本番の子として、役の試聴が続いていれば試聴の子として起き (本番が乗り換えを待つ間は保留にあり得る)、役の試聴が
        /// 終わっていれば起きない。ただし出る要求が「出た時点のソースを本番に作り直す」と決めた試聴 (本番が居ない・プレビューを
        /// 戻せない) の版は、本番の子として起きる (``sourceRebuildThrough``)。本番の版の作り直しの最中に出た試聴の版は、その
        /// 作り直しが済んで本番が走っていなければ同じ扱い。作り直しの最中に重ねた保存のうち、最後の版だけが作り直される
        /// (途中の版は追い越される)。**捨てた版があれば、捨てたことを名乗り、無ければ名乗らない。**
        private func overlap(
            _ steps: [Step], heldFails: Bool = false, requested: Bool = false
        ) async throws -> Violation? {
            // 作り直す・起こし直す要求を含む重なりは、控えの列の規則で見る (#3428)
            if requested || steps.contains(where: { $0 == .rebuild || $0 == .restart }) {
                return try await requestOverlap(steps, heldFails: heldFails, requested: requested)
            }
            guard !stopped else { return nil }
            await settleUnseen()
            let launchesBefore = gens.count
            let linesBefore = previewLog.count
            let rebuildsBefore = rebuiltStamps.count
            placeUnseenSave()
            noteRead(currentRole)
            let heldStamp = stamp
            let heldRole = currentRole
            var placed = [stamp]
            holdRebuild = true
            self.heldFails = heldFails
            defer { self.heldFails = false }
            // 門で止まるまで拍を回す。保留していた試聴の子を起こした拍は作り直しに取りかからないので、2 拍まで。
            // **待つ側が期限を持つ** — 越えたら門を開け、止めた拍を畳んでから投げる
            var held: Task<Void, Never>?
            for _ in 0..<2 where rebuildGate == nil {
                heldBeatDone = false
                let beating = Task { [self] in
                    _ = await beat()
                    heldBeatDone = true
                }
                held = beating
                let deadline = Date().addingTimeInterval(5)
                while rebuildGate == nil && !heldBeatDone && Date() < deadline {
                    try? await Task.sleep(for: .milliseconds(1))
                }
                if rebuildGate == nil && !heldBeatDone {
                    releaseRebuild()
                    await beating.value
                    throw GateTimeout(description: "作り直しが期限 (5 秒) までに門に着かない")
                }
                if rebuildGate == nil { await beating.value }
            }
            guard rebuildGate != nil, let held else {
                // 作り直しに取りかからない (模型の外の形)。演じずに戻る
                holdRebuild = false
                await held?.value
                return nil
            }
            for step in steps {
                switch step {
                case .save:
                    placeUnseenSave()
                    noteRead(currentRole)
                    placed.append(stamp)
                    await beat()
                case .rebuild, .restart:
                    // 頼みを含む重なりは ``requestOverlap(_:heldFails:requested:)`` が見る (ここへは来ない)
                    return nil
                case .revert:
                    // 作り直しの最中に重ねた保存の 1 つ前の中身へ戻す。戻した保存の役は、それを読んだ時点の役 (保存ごと)
                    guard placed.count >= 3, let back = placed[placed.count - 2] else { continue }
                    stampOverride = back
                    noteRead(currentRole)
                    placed.append(back)
                    await beat()
                case .audition, .leave, .leaveStuck, .exitShown, .stop:
                    switch try await overlapCommonStep(step, heldRole: heldRole, held: held) {
                    case .next: break
                    case .ended: return nil
                    case .violation(let violation): return violation
                    }
                }
            }
            releaseRebuild()
            await held.value
            // 本番の版の作り直しの最中に出た試聴の版は、作り直しが済んで本番が走っていなければ本番の版として起きる (規則)
            if let left = leftWhileBuilding {
                leftWhileBuilding = nil
                if productionAlive().isEmpty { sourceRebuildThrough = max(sourceRebuildThrough, left) }
            }
            for _ in 0..<2 { await beat() }
            let launched = Set(launchesBefore..<gens.count)
            func label(_ index: Int) -> String { "G\(index)=\(launchStamps[index] ?? "-")" }
            // 見張りの役 (作品のウィンドウが採らない試聴の子か) と、規則の役が一致する。**見るのは生きている子だけ** — 出た後の
            // 通常の差し替えは、止めた試聴の子の覚えを捨てる (番号は使い回されるので、死んだ子の答えは約束の外)
            for index in launched.sorted() where isAlive(index) {
                let sessionSaysAudition = session.isAuditionGeneration(pid: pid(index))
                if sessionSaysAudition != auditionGens.contains(index) {
                    return Violation(
                        number: 7,
                        text: "\(label(index)) を、規則では\(auditionGens.contains(index) ? "試聴" : "本番")の版なのに\(sessionSaysAudition ? "試聴" : "本番")の子として起こした (役 \(String(describing: launchRoles[index])))")
                }
            }
            let currentAudition = auditioning ? auditionIndex : nil
            /// 役 `role` の版は、終わった試聴の版として捨てられる (規則)。
            func isDropped(_ role: Role?) -> Bool {
                if let role, case .audition(let index) = effective(role), index != currentAudition { return true }
                return false
            }
            // 最後の版の行き先
            let last = placed.last ?? nil
            if let last, let lastRole = stampRoles[last] {
                // 最後の版の子 (起こし直しの子と、重なりの前の作り直しの子 — 保留していた試聴の子が重なりの頭の拍で起きた — は除く)
                let ofLast = launched.filter {
                    launchStamps[$0] == last && !restartGens.contains($0)
                        && (launchBuilds[$0] ?? 0) > rebuildsBefore
                }
                if refusedStamps.contains(last) {
                    // 起こせない版 (``Op/saveLaunchFail`` の版) を頼み直しても、起こせないのは版の性質 (#3428)
                    if !ofLast.isEmpty {
                        return Violation(number: 5, text: "起こせない版の \(last) の子が起きた (\(ofLast.sorted().map(label)))")
                    }
                } else if heldFails && last == heldStamp {
                    // 門で止めた版が通らなかったなら、その版の子は起きない
                    if !ofLast.isEmpty {
                        return Violation(number: 5, text: "通らなかった \(last) の子が起きた (\(ofLast.sorted().map(label)))")
                    }
                } else {
                    switch effective(lastRole) {
                    case .production:
                        if ofLast.isEmpty || ofLast.contains(where: { auditionGens.contains($0) }) {
                            return Violation(number: 7, text: "本番の版の \(last) の本番の子が起きない (起きた子 \(launched.sorted().map(label)))")
                        }
                    case .audition(let index) where index == currentAudition:
                        if ofLast.isEmpty {
                            // 本番が乗り換えを待つ間は保留にあり得る
                            if session.waitingGeneration == nil {
                                return Violation(number: 7, text: "試聴の中で読んだ \(last) の試聴の子が起きない (起きた子 \(launched.sorted().map(label)))")
                            }
                            deferredStamp = last
                        }
                    case .audition:
                        if !ofLast.isEmpty {
                            return Violation(number: 7, text: "終わった試聴の中で読んだ \(last) の子が起きた (\(ofLast.sorted().map(label)))")
                        }
                    }
                }
            }
            // 捨てた版があれば名乗り、無ければ名乗らない (本番の版にした版を「捨てた」と言わない)。門で止めた版と最後の版の
            // どちらかが終わった試聴の版なら捨てる。途中の版は追い越されるだけで、名乗らない。**同じ試聴の版を続けて捨てるとき
            // は 1 行にまとめる** (門で止めた版を捨てるとき、同じ試聴で読んで控えた最後の版も一緒に捨てる)
            let lastRole = last.flatMap { stampRoles[$0] }
            let heldDropped = isDropped(heldRole)
            let lastDropped = last != heldStamp && isDropped(lastRole)
            let sameAudition = lastRole.map { effective($0) == effective(heldRole) } ?? false
            let expectedDrops = (heldDropped ? 1 : 0) + (lastDropped && !(heldDropped && sameAudition) ? 1 : 0)
            let dropLines = previewLog[linesBefore...].filter {
                $0 == WatchCommand.auditionDiscardedLine(productionRunning: true)
                    || $0 == WatchCommand.auditionDiscardedLine(productionRunning: false)
            }
            if dropLines.count != expectedDrops {
                return Violation(
                    number: 7,
                    text: "捨てたことを名乗った行が \(dropLines.count) 行 (規則では \(expectedDrops) 行。門で止めた版 \(heldStamp ?? "-") の役 \(heldRole)・最後の版 \(last ?? "-") の役 \(String(describing: lastRole)))")
            }
            // 同じ版を 2 度作り直さない (出る要求が引き継いだ版を、出た時点のソースとしてもう 1 度作らない)。重なりの中の
            // 保存はどれも新しい中身か、作り直していない中身へ戻す保存なので、1 つの中身の作り直しは 1 度まで
            let rebuilt = rebuiltStamps[rebuildsBefore...]
            if let twice = Set(rebuilt.compactMap { $0 }).first(where: { stamp in rebuilt.filter { $0 == stamp }.count > 1 }) {
                return Violation(number: 7, text: "同じ版 \(twice) を 2 度作り直した (作り直した順 \(rebuilt.map { $0 ?? "-" }))")
            }
            // 落ち着いた後の拍は何も起こさない (捨てた版を後から本番へ作り直さない)
            let settled = gens.count
            let started = await beat()
            let extra = Set(settled..<gens.count).subtracting(pendingLaunches(started, of: deferredStamp))
            if !extra.isEmpty {
                return Violation(number: 7, text: "落ち着いた後の拍で子が起きた (\(extra.sorted().map(label)))")
            }
            return nil
        }

        /// これから最初の絵の前に失敗で終わらせる子が起こし直しの子なら、その役の時計の場所を、起こし直す前の番号へ戻す (表)。
        /// 見張りは離脱を名乗る拍の頭で戻すので、同じ拍で起きる子 (保留していた試聴の子) は戻した場所を受ける。
        /// - Returns: 起こし直しの子で、1 枚目を出していないか。
        private func revertRestartClock(of target: Int) -> Bool {
            // 1 枚目を出した子の終わりは、起動の失敗ではない
            guard !everShown.contains(target), let restarted = restartClocks.removeValue(forKey: target) else { return false }
            let splitBefore = restartSplits.removeValue(forKey: target)
            if restarted.audition {
                if auditionClock == restarted.fresh {
                    auditionClock = restarted.previous
                    if let splitBefore { clocksSplit = splitBefore }
                }
            } else if productionClock == restarted.fresh {
                productionClock = restarted.previous ?? 0
                if let splitBefore { clocksSplit = splitBefore }
            }
            return true
        }

        /// 最初の絵の前に失敗で終わった子が起こし直しの子なら (規則・#3428 の反証 6): 作り直しの記録を書き換えず、起こし直しの
        /// 失敗と名乗り、「作り直したが起こせなかった」とは名乗らない。
        private func checkRestartedChildFailed(
            _ target: Int, reportBefore: BuildReport?, linesBefore: Int
        ) -> Violation? {
            // 同じ拍で、保留していた試聴の子が起きて記録を書くことはある。起こし直した子の失敗を、作り直しの記録の「起こせなかった」
            // に書き換えていないかを見る
            if let report = session.lastReport, report != reportBefore,
                report.notStartedHead?.hasSuffix(BuildReport.firstFrameSuffix) == true
            {
                return Violation(number: 7, text: "起こし直した G\(target) が最初の絵の前に落ちて、作り直しの記録が書き換わった")
            }
            let lines = previewLog[linesBefore...]
            if !lines.contains(where: { $0.hasPrefix("Could not restart it: ") })
                || lines.contains(where: { $0.hasPrefix("Rebuilt, but could not start") })
            {
                return Violation(number: 7, text: "起こし直した G\(target) が最初の絵の前に落ちた名乗りが \(Array(lines)) (起こし直しの失敗のはず)")
            }
            return nil
        }

        /// 控えの列の 1 項目 (模型の側・#3428)。**表から直に書く** (見張りの内部の変数は写さない)。
        struct Pending: Equatable {
            enum Kind: Equatable { case save, rebuild, restart }
            let kind: Kind
            /// 保存は拾った読みを始めた時点の役、頼みは頼みを読んだ時点の役。
            let role: Role
        }

        /// 役 `role` の作り直し (保存・作り直す要求) の試聴が、もう終わったか (いまの扱いで比べる。本番の版へ寄せた試聴の版は終わらない)。
        private func buildEnded(_ role: Role) -> Bool {
            if case .audition(let index) = effective(role) { return !(auditioning && auditionIndex == index) }
            return false
        }

        /// 試聴の中で頼んだ起こし直しの試聴が、もう終わったか (起こし直しは生の番号で比べる・#3428 の決定 2)。
        private func restartEnded(_ role: Role) -> Bool {
            if case .audition(let index) = role { return !(auditioning && auditionIndex == index) }
            return false
        }

        /// 作り直す・起こし直す要求を含む重なり (#3428 の反証 1・2・3・11)。保存か作り直す要求で作り直しを門で止め、止めている間に
        /// `steps` を起こしてから門を開ける。
        ///
        /// **期待は控えの表から書く** (`tables.md`・``WatchSession`` の `Pending` の注釈):
        /// - 控えは読んだ・頼みを読んだ順の列。新しい中身の保存は前の保存に代わり (役を問わず)、それより前に頼んだ役の違う作り直す
        ///   要求を捨てて名乗る。続けて頼んだ同じ役の同じ頼みは 1 つ
        /// - 門を開けたら、門で止めた作り直しが済み、終わった試聴の保存・作り直す要求は捨てて 1 行で名乗り (門で止めた版を捨てる
        ///   ときと一緒に)、終わった試聴の起こし直しは捨てて名乗る。残りは列の順に 1 つずつ行い、続けて並ぶ同じ役の作り直しは 1 回
        /// - 起こし直しの結末は、行う時点の規則 (``expectedRestart(_:)``)。試聴の子の起こし直しは、本番が乗り換えを待つ間は待ち、
        ///   後ろの項目も待つ
        private func requestOverlap(_ steps: [Step], heldFails: Bool, requested: Bool) async throws -> Violation? {
            guard !stopped else { return nil }
            // 前の中身へ戻す保存は、頼みと混ぜない (模型の外)
            if steps.contains(.revert) { return nil }
            await settleUnseen()
            let launchesBefore = gens.count
            let linesBefore = previewLog.count
            let rebuildsBefore = rebuiltStamps.count
            if requested {
                // 門で止める作り直しを、作り直す要求で起こす (中身は変えない)。要求は門で止める拍の頭で読まれる
                buildStatus = 0
                launchFails = false
                try placeRequest("rebuild")
            } else {
                placeUnseenSave()
            }
            noteRead(currentRole)
            let heldRole = currentRole
            holdRebuild = true
            self.heldFails = heldFails
            defer { self.heldFails = false }
            guard let held = try await holdAtGate() else { return nil }
            var queue: [Pending] = []
            /// 捨てた作り直す要求ごとの、名乗りの向き (いまの扱いが試聴の頼みか)
            var droppedRebuilds: [Bool] = []
            for step in steps {
                switch step {
                case .save:
                    placeUnseenSave()
                    noteRead(currentRole)
                    await beat()
                    let role = currentRole
                    queue.removeAll { $0.kind == .save }
                    let superseded = { [self] (item: Pending) in
                        item.kind == .rebuild && !buildEnded(item.role) && effective(item.role) != effective(role)
                    }
                    droppedRebuilds += queue.filter(superseded).map { effective($0.role) != .production }
                    queue.removeAll(where: superseded)
                    queue.append(Pending(kind: .save, role: role))
                case .rebuild, .restart:
                    let kind: Pending.Kind = step == .rebuild ? .rebuild : .restart
                    let item = Pending(kind: kind, role: currentRole)
                    if queue.last != item { queue.append(item) }
                    let (accepted, _) = try await ask(step == .rebuild ? "rebuild" : "restart")
                    if !accepted { return Violation(number: 7, text: "作り直しの最中の \(step) の要求を断った") }
                case .revert:
                    return nil
                case .audition, .leave, .leaveStuck, .exitShown, .stop:
                    switch try await overlapCommonStep(step, heldRole: heldRole, held: held) {
                    case .next: break
                    case .ended: return nil
                    case .violation(let violation): return violation
                    }
                }
            }
            releaseRebuild()
            await held.value
            if let left = leftWhileBuilding {
                leftWhileBuilding = nil
                if productionAlive().isEmpty { sourceRebuildThrough = max(sourceRebuildThrough, left) }
            }
            // 終わった試聴の項目を捨てる (門で止めた版を捨てるときと一緒に 1 行・起こし直しは 1 行)
            let heldDropped = buildEnded(heldRole)
            // 記録は、門で止めた作り直しが頼みで起きたなら頼まれた作り直しの回 (`requested`)
            if !heldDropped, let violation = checkRequested(session.lastReport, expected: requested, what: "門で止めた作り直し") {
                return violation
            }
            let endedBuilds = queue.contains { $0.kind != .restart && buildEnded($0.role) }
            // 捨てたものに保存が 1 つも無ければ、頼んだ作り直しを捨てたと名乗る (2 回目の反証 4)
            let discardsSaved =
                (heldDropped && !requested) || queue.contains { $0.kind == .save && buildEnded($0.role) }
            let endedRestarts = queue.contains { $0.kind == .restart && restartEnded($0.role) }
            queue.removeAll { ($0.kind != .restart && buildEnded($0.role)) || ($0.kind == .restart && restartEnded($0.role)) }
            // 列の順に 1 つずつ。続けて並ぶ同じ役の作り直しは 1 回
            var gated = false
            var builds = 0
            /// いまの試聴の版を通る作り直しで作ったか (保留にあり得る版が変わる)
            var auditionBuilt = !heldFails && !buildEnded(heldRole) && effective(heldRole) != .production
            var index = 0
            while index < queue.count {
                let item = queue[index]
                if item.kind == .restart {
                    index += 1
                    let expectation = expectedRestart(item.role)
                    // 試聴の子を起こす起こし直しは、本番が乗り換えを待つ間は待つ (後ろも待つ)
                    if case .restarted = expectation, item.role != .production, let waiting, isAlive(waiting) {
                        gated = true
                        break
                    }
                    let launchesAt = gens.count
                    let linesAt = previewLog.count
                    let dropped = WatchSession.restartLine(.dropped)
                    func lines() -> [String] { restartLines(since: linesAt).filter { $0 != dropped } }
                    if case .restarted(let role, _, _) = expectation { restartRole = role }
                    for _ in 0..<3 where lines().isEmpty { await beat() }
                    restartRole = nil
                    if lines() != [restartLine(for: expectation)] {
                        return Violation(
                            number: 7,
                            text: "作り直しの最中に頼んだ起こし直し (役 \(item.role)) の名乗りが \(lines()) (規則では \(restartLine(for: expectation)))")
                    }
                    if case .restarted(let role, let stamp, _) = expectation {
                        let started = Set(launchesAt..<gens.count)
                        let side = role == .production ? started.subtracting(auditionGens) : started.intersection(auditionGens)
                        if side.count != 1 || side.contains(where: { launchStamps[$0] != stamp }) {
                            return Violation(
                                number: 7,
                                text: "作り直しの後の起こし直しで起きた子が \(started.sorted().map { "G\($0)=\(launchStamps[$0] ?? "-")" }) (規則では \(role) の側に版 \(stamp ?? "-") の子が 1 つ)")
                        }
                    }
                    continue
                }
                var end = index + 1
                while end < queue.count, queue[end].kind != .restart, effective(queue[end].role) == effective(item.role) { end += 1 }
                // まとめた中で最後に読んだものが頼みなら、頼まれた作り直しの回 (頼みの後に読んだ保存は頼みを追い越す・スキーマの
                // `requested`)
                let groupRequested = queue[end - 1].kind == .rebuild
                let group = queue[index..<end].map { "\($0.kind)" }
                index = end
                builds += 1
                if effective(item.role) != .production { auditionBuilt = true }
                pendingBuildRoles = [item.role]
                let before = rebuiltStamps.count
                for _ in 0..<3 where rebuiltStamps.count == before { await beat() }
                pendingBuildRoles = []
                if rebuiltStamps.count == before {
                    return Violation(number: 7, text: "控えた作り直し (役 \(item.role)) が行われない (列 \(queue))")
                }
                if let violation = checkRequested(
                    session.lastReport, expected: groupRequested, what: "控えた作り直し \(group)")
                {
                    return violation
                }
            }
            if !gated { for _ in 0..<2 { await beat() } }
            func label(_ index: Int) -> String { "G\(index)=\(launchStamps[index] ?? "-")" }
            let launched = Set(launchesBefore..<gens.count)
            for index in launched.sorted() where isAlive(index) {
                let sessionSaysAudition = session.isAuditionGeneration(pid: pid(index))
                if sessionSaysAudition != auditionGens.contains(index) {
                    return Violation(
                        number: 7,
                        text: "\(label(index)) を、規則では\(auditionGens.contains(index) ? "試聴" : "本番")の版なのに\(sessionSaysAudition ? "試聴" : "本番")の子として起こした (役 \(String(describing: launchRoles[index])))")
                }
            }
            // 門で止めた作り直しと、列の作り直しの数だけ作り直す (役の違う項目は互いを消さず、同じ役は 1 回にまとめる)
            if rebuiltStamps.count - rebuildsBefore != 1 + builds {
                return Violation(
                    number: 7,
                    text: "作り直しが \(rebuiltStamps.count - rebuildsBefore) 回 (規則では門で止めた 1 回と列の \(builds) 回。作り直した順 \(rebuiltStamps[rebuildsBefore...].map { $0 ?? "-" }))")
            }
            func count(_ line: String) -> Int { previewLog[linesBefore...].filter { $0 == line }.count }
            let savedDiscards =
                count(WatchCommand.auditionDiscardedLine(productionRunning: true))
                + count(WatchCommand.auditionDiscardedLine(productionRunning: false))
            let requestDiscards =
                count(WatchCommand.auditionRebuildDiscardedLine(productionRunning: true))
                + count(WatchCommand.auditionRebuildDiscardedLine(productionRunning: false))
            let discarded = heldDropped || endedBuilds
            let expectedDiscards = (saved: discarded && discardsSaved ? 1 : 0, requests: discarded && !discardsSaved ? 1 : 0)
            if savedDiscards != expectedDiscards.saved || requestDiscards != expectedDiscards.requests {
                return Violation(
                    number: 7,
                    text: "捨てた試聴の版を名乗った行が 保存の版 \(savedDiscards) 行・頼み \(requestDiscards) 行 (規則では \(expectedDiscards.saved) 行・\(expectedDiscards.requests) 行)")
            }
            // 捨てた作り直す要求は、頼みのいまの扱いの向きで名乗る (2 回目の反証 5)
            let rebuildDrops = (
                audition: count(WatchSession.rebuildDroppedLine(audition: true)),
                production: count(WatchSession.rebuildDroppedLine(audition: false)))
            let expectedDrops = (
                audition: droppedRebuilds.filter { $0 }.count, production: droppedRebuilds.filter { !$0 }.count)
            if rebuildDrops != expectedDrops {
                return Violation(number: 7, text: "捨てた作り直す要求を名乗った行が \(rebuildDrops) (規則では \(expectedDrops))")
            }
            if count(WatchSession.restartLine(.dropped)) != (endedRestarts ? 1 : 0) {
                return Violation(number: 7, text: "捨てた起こし直しを名乗った行が \(count(WatchSession.restartLine(.dropped))) 行 (規則では \(endedRestarts ? 1 : 0) 行)")
            }
            guard !gated else { return nil }
            // 本番が乗り換えを待つ間に作った試聴の版は、保留にあり得る
            if auditionBuilt, auditioning, let waiting, isAlive(waiting) { deferredStamp = stamp }
            // 落ち着いた後の拍は何も起こさない
            let settled = gens.count
            let started = await beat()
            let extra = Set(settled..<gens.count).subtracting(pendingLaunches(started, of: deferredStamp))
            if !extra.isEmpty {
                return Violation(number: 7, text: "落ち着いた後の拍で子が起きた (\(extra.sorted().map(label)))")
            }
            return nil
        }

        /// 作り直しの記録が、規則どおりに頼まれた作り直しの回か (`requested`) を見る。
        private func checkRequested(_ report: BuildReport?, expected: Bool, what: String) -> Violation? {
            let actual = report?.requested == .rebuild
            guard actual != expected else { return nil }
            return Violation(
                number: 7,
                text: "\(what) の記録の requested が \(actual ? "rebuild" : "無い") (規則では \(expected ? "rebuild" : "無い"))")
        }

        /// 作り直しが門に着くまで拍を回し、止めた拍の `Task` を返す。保留していた試聴の子を起こした拍は作り直しに取りかからない
        /// ので 2 拍まで。取りかからなければ `nil` (模型の外の形)。**待つ側が期限を持つ** — 越えたら門を開け、止めた拍を畳んで
        /// から投げる。
        private func holdAtGate() async throws -> Task<Void, Never>? {
            var held: Task<Void, Never>?
            for _ in 0..<2 where rebuildGate == nil {
                heldBeatDone = false
                let beating = Task { [self] in
                    _ = await beat()
                    heldBeatDone = true
                }
                held = beating
                let deadline = Date().addingTimeInterval(5)
                while rebuildGate == nil && !heldBeatDone && Date() < deadline {
                    try? await Task.sleep(for: .milliseconds(1))
                }
                if rebuildGate == nil && !heldBeatDone {
                    releaseRebuild()
                    await beating.value
                    throw GateTimeout(description: "作り直しが期限 (5 秒) までに門に着かない")
                }
                if rebuildGate == nil { await beating.value }
            }
            guard rebuildGate != nil, let held else {
                holdRebuild = false
                await held?.value
                return nil
            }
            return held
        }

        /// 重なりの中の出来事のうち、保存の重なりと頼みの重なりで同じもの — 出入り・本番の終わり・終わり (#3796・#3428)。
        enum CommonStep { case next, ended, violation(Violation) }

        private func overlapCommonStep(_ step: Step, heldRole: Role, held: Task<Void, Never>) async throws -> CommonStep {
            switch step {
            case .audition:
                let wasAuditioning = auditioning
                let (accepted, _) = try await ask("audition")
                if accepted && wasAuditioning {
                    return .violation(Violation(number: 7, text: "試聴に入っているのに、入る要求を受けた"))
                }
                if accepted {
                    auditioning = true
                    auditionIndex += 1
                    deferredStamp = nil
                }
            case .leave, .leaveStuck:
                let wasAuditioning = auditioning
                let productionBefore = productionAlive()
                if auditioning {
                    endedAuditions.insert(auditionIndex)
                    // 出方 (規則): 門で止めた作り直しの版が本番の版なら、それが本番になり、この試聴の版は作り直しが済んで
                    // から決まる。そうでなく本番が居ない・プレビューを戻せないなら、出た時点のソースを本番に作り直す
                    if effective(heldRole) == .production {
                        leftWhileBuilding = max(leftWhileBuilding ?? 0, auditionIndex)
                    } else if productionBefore.isEmpty || step == .leaveStuck {
                        sourceRebuildThrough = auditionIndex
                    }
                }
                if step == .leaveStuck { session.returnsPreviewToGeneration = { _ in false } }
                let (accepted, _) = try await ask("leave")
                session.returnsPreviewToGeneration = { _ in true }
                if accepted != wasAuditioning {
                    return .violation(Violation(number: 7, text: "出る要求を\(accepted ? "受けた" : "断った") (試聴中 \(wasAuditioning))"))
                }
                if accepted {
                    auditioning = false
                    auditionClock = nil
                    clocksSplit = false
                    deferredStamp = nil
                }
            case .exitShown:
                let candidates = (shown.map { [$0] } ?? []) + productionAlive().sorted().reversed()
                guard let target = candidates.first(where: { isAlive($0) && !auditionGens.contains($0) }) else {
                    return .next
                }
                finish(target, line: "bye")
                unseen.insert(target)
                await beat()
            case .stop:
                // 終われと言われた口 (``WatchCommand``) と同じ順: 作り直しを止め、子を畳む。止めた作り直しは門を開けると戻る
                stopped = true
                deferredStamp = nil
                session.noteStopRequested()
                _ = await session.stopRebuilding()
                await session.end()
                releaseRebuild()
                await held.value
                return .ended
            default:
                break
            }
            return .next
        }

        /// 作り直しが通り子を起こせる保存を置くが、拍は回さない (見張りはまだ見ていない)。
        private func placeUnseenSave() {
            changeSource()
            buildStatus = 0
            launchFails = false
        }

        /// ウィンドウの知らせを 1 度送る。**受けたか** を返す。
        private func notify(_ op: Op, about index: Int, stale: Bool = false) async throws -> Bool {
            switch op {
            case .fellBack, .fellBackStale:
                try placeFellBackMarker(of: index)
                return await session.retireAfterFallback() != nil
            default:
                // ウィンドウは知らせを受けた時点の「待っている世代」を控えて、その世代と目録が名乗った番号で渡す
                return await session.retireAfterUndeliverable(waiting: session.waitingGeneration, pid: pid(index)) != nil
            }
        }

        // MARK: 事後条件 (どの操作の後も)

        private func checkAfter() -> Violation? {
            // 7. 起こした子の役は規則どおり (``launch(_:stamp:)`` が控える)
            if let launchViolation { return Violation(number: 7, text: launchViolation) }
            let living = alive()
            // 1. 生きている子は、本番の側が 2 つまで (2 つなら一方は乗り換えを待っている)・試聴の側が 1 つまで。
            //    乗り換えを待つ世代が無ければ、全体で 2 つまで
            let productionLiving = productionAlive()
            if productionLiving.count > 2 {
                return Violation(number: 1, text: "生きている本番の側が \(productionLiving.count) 個 (\(name(productionLiving)))")
            }
            if productionLiving.count == 2, session.waitingGeneration == nil {
                return Violation(number: 1, text: "生きている本番の側が 2 つ (\(name(productionLiving))) なのに、乗り換えを待つ世代が無い")
            }
            if auditionAlive().count > 1 {
                return Violation(number: 1, text: "生きている試聴の子が \(auditionAlive().count) 個 (\(name(auditionAlive())))")
            }
            // 試聴の子が居る間の本番の側は 1 つまで、本番が乗り換えを待つこともない — 試聴の子は、本番の乗り換えが
            // 決着してから起こす (前の本番を畳んで起こすと、乗り換えを待つ本番が 1 枚目の前に落ちたとき戻る先が無い)。
            // 3 つ (本番 2 つ + 試聴) 生きる形も作らない (決定「本番 + 試聴の 2 つまで」)
            if !auditionAlive().isEmpty, session.waitingGeneration != nil {
                return Violation(
                    number: 1,
                    text: "試聴の子 \(name(auditionAlive())) が居るのに、本番が乗り換えを待っている (G\(session.waitingGeneration.flatMap { w in gens.firstIndex { $0 === w } }.map(String.init) ?? "-"))")
            }
            if !auditionAlive().isEmpty, productionLiving.count > 1 {
                return Violation(
                    number: 1,
                    text: "試聴の子 \(name(auditionAlive())) が居るのに、本番の側が \(productionLiving.count) 個 (\(name(productionLiving))) 生きている")
            }
            if !auditioning, !auditionAlive().isEmpty {
                return Violation(number: 1, text: "試聴に入っていないのに、試聴の子が生きている (\(name(auditionAlive())))")
            }
            if session.waitingGeneration == nil, living.count > 2 {
                return Violation(number: 1, text: "乗り換えを待つ世代が無いのに、生きている子が \(living.count) 個 (\(name(living)))")
            }
            // 3. 台へ手放した世代: 生きて映っている世代は渡らず、去った世代は 1 度だけ渡る
            if let shown, isAlive(shown), (relinquished[shown] ?? 0) > 0 {
                return Violation(number: 3, text: "生きて映っている G\(shown) を、台へ手放したと伝えた")
            }
            // 終わるとき (ウィンドウごと閉じる) は、台へ伝える相手が居ない
            if !stopped, let shown, !isAlive(shown), !unseen.contains(shown),
                (relinquished[shown] ?? 0) == 0
            {
                return Violation(number: 3, text: "映っていた G\(shown) が居なくなったのに、台へ手放したと伝えていない")
            }
            // 3. (試聴の子も同じ) 生きて映っている試聴の子は伝えず、去った試聴の子は伝える
            for index in auditionGens {
                if isAlive(index), (relinquished[index] ?? 0) > 0 {
                    return Violation(number: 3, text: "生きて映っている試聴の G\(index) を、台へ手放したと伝えた")
                }
                if !stopped, !isAlive(index), !unseenAudition.contains(index), (relinquished[index] ?? 0) == 0 {
                    return Violation(number: 3, text: "映っていた試聴の G\(index) が居なくなったのに、台へ手放したと伝えていない")
                }
            }
            // 5. 前の版が走っていると名乗る口は、生きた世代の有無と一致する
            let running = !living.isEmpty && !session.stopRequested
            if session.keepsPreviousRunning != running {
                return Violation(
                    number: 5, text: "keepsPreviousRunning が \(session.keepsPreviousRunning) (生きている世代 \(name(living)))")
            }
            if let report = session.lastReport, !report.ok,
                WatchCommand.notice(for: report, holdingPrevious: session.keepsPreviousRunning)?.contains(
                    WatchCommand.holdingLine) == true, !running
            {
                return Violation(number: 5, text: "走っている世代が無いのに、作り直しの失敗が前の版が動いていると名乗る")
            }
            // 6. 終えた後は子が無い
            if stopped, !living.isEmpty {
                return Violation(number: 6, text: "終えた後に生きている世代が残る (\(name(living)))")
            }
            return nil
        }

        /// 2. 入力の宛先は、ウィンドウが映している世代が生きていれば、その世代である。
        ///
        /// 作品のウィンドウは映っている本番の世代。プレビューは、試聴中なら映している試聴の世代 (その台の `displayedPID`)。
        private func checkSend() -> Violation? {
            guard !stopped else { return nil }
            // プレビュー: 試聴の子が生きていれば、その子へ。本番の側へは届かない
            if auditioning, let audition = auditionAlive().first {
                let before = alive()
                session.send("probe\n", shownBy: pid(audition))
                waitUntilGone(audition, timeout: 1)
                if isAlive(audition) {
                    return Violation(number: 2, text: "プレビューで触った出来事が、映している試聴の G\(audition) へ届かない")
                }
                if alive() != before.subtracting([audition]) {
                    return Violation(number: 2, text: "プレビューで触った出来事が、試聴の G\(audition) のほかの世代にも届いた")
                }
            }
            // 作品のウィンドウ: 映っている本番の世代へ
            guard let target = shown, isAlive(target) else { return nil }
            let before = alive()
            session.send("probe\n")
            waitUntilGone(target, timeout: 1)
            if isAlive(target) {
                return Violation(number: 2, text: "入力が、映っている G\(target) へ届かない (宛先 \(describeTarget()))")
            }
            if alive() != before.subtracting([target]) {
                return Violation(number: 2, text: "入力が、映っている G\(target) のほかの世代にも届いた")
            }
            return nil
        }

        private func describeTarget() -> String {
            let target = session.outgoing ?? session.child
            return gens.firstIndex { $0 === target }.map { "G\($0)" } ?? "なし"
        }

        /// 終わった後の確認 (事後条件 6 の後半): 終われと言われた後は、保存があっても起こさない。
        func checkNoLaunchAfterStop() async -> Violation? {
            guard stopped else { return nil }
            let before = launches
            changeSource()
            await session.tick()
            return launches == before ? nil : Violation(number: 6, text: "終えた後の保存で launch が呼ばれた")
        }
    }
}
