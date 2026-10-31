// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation
import MokumeDiagnostics
import mokume

/// 区画への読み書き。
///
/// **窓口は決して起こさない** — 走っているスケッチを立ち上げることも、作り直すことも
/// しない。所有はいつでも見張っている道具の側にあり、ここは区画のファイルを読み書き
/// するだけの薄い層である。
///
/// その代わり**待ちの上限はここにだけ置く**。ADR-0018 が「壁時計で完了を判断しない」と
/// 決めているのは応答する相手が居る前提の話で、誰も走っていない場合は待つ以外に
/// 知る方法が無い。
struct Facets {
    /// 見に行く間隔。
    static let pollInterval: TimeInterval = 0.05
    /// 走っているスケッチを待つ既定の上限。
    static let defaultWaitLimit: TimeInterval = 5
    /// 期限へ足す待ちの長さの上限 (秒)。1 日。
    ///
    /// 窓口が待つ本番の最長 (撮る列の上限 120 枚 × 間隔 60 フレームを 30fps で換算して約 4 分)
    /// より十分大きく、`DispatchTime` のナノ秒 (Int64) に収まる。**呼び手が渡す待ちは
    /// 外から来る値で足されるので**、無限・巨大・NaN・負が `DispatchTime` の期限の計算へ
    /// 届かないよう、足す前にここで丸める ([#1940](https://github.com/mokume-metal/mokume/issues/1940))
    static let longestWaitSeconds: TimeInterval = 86_400

    /// 待ちの長さを、`DispatchTime` へ足せる範囲 (0 以上・``longestWaitSeconds`` 以下) へ丸める。
    ///
    /// 範囲の外を `DispatchTime` が黙って `.forever` などへ丸める挙動は、文書に無い。
    /// NaN と負は 0 へ — 壁時計の期限 (`Date`) だった頃も、そのときは待たずに戻っていた。
    static func boundedWait(_ seconds: TimeInterval) -> TimeInterval {
        guard !seconds.isNaN else { return 0 }
        return min(max(seconds, 0), longestWaitSeconds)
    }

    let directory: URL
    /// 走っているスケッチを待つ上限。検査からは短くする。
    var waitLimit: TimeInterval = defaultWaitLimit
    /// 区画の基準を `MOKUME_WORK_DIR` が決めたか。
    ///
    /// **応えないときの案内が名乗る。** 走らせる側と食い違っていても症状は「誰も応えない」
    /// でしかなく、それは「まだ起動していない」と見分けが付かない (#380 着手条件 2)。
    var workDirectoryGiven: Bool = false
    /// 窓口を立てた場所と、そこがスケッチか (``InterfacePlace``)。
    ///
    /// **``workDirectoryGiven`` と同じく、起動の時点で決まる事実として持つ** (#2487)。窓口は
    /// 在る場所なら受ける (#2321) ので、スケッチでない場所でも立つ。応えないときの案内は
    /// 「窓口の場所 = スケッチの場所」を前提にせず、この事実から組む。`nil` は場所を知らない
    /// 呼び手で、場所の話をしない (``Tools`` は組むときに必ず埋める)。
    var place: InterfacePlace?
    /// 区画の基準に、作り直しを見張っている見張り (`watch`) が今居るか。**検査から差し替える。**
    ///
    /// 作り直しの記録を「いまの話」として読んでよいかを決める (``notStartedAnswer()``)。既定は
    /// 場所の錠を見る (``WatchPlaceLock/isHeld(under:)``)。
    var isWatching: @Sendable (URL) -> Bool = { WatchPlaceLock.isHeld(under: $0) }

    /// 区画の基準が、スケッチでない窓口の場所に落ちているか。
    ///
    /// `MOKUME_WORK_DIR` があれば基準は窓口の場所に依らないので、窓口をどこで立てたかは
    /// 応えない原因にならない。無ければ基準は窓口を立てた場所で、そこにスケッチが無ければ、
    /// 自分の場所で走るスケッチ (`watch`) とは噛み合わない。区画を読み書きする答え
    /// (応えない・作り直しの記録が無い・置けない) が、場所の手を添えるのはこのときだけである。
    var facetsOutsideSketch: Bool { !workDirectoryGiven && place?.isSketch == false }

    // 区画の名前も ``StartupReads`` から取る。窓口の側で綴りを持つと、スケッチが見る
    // 場所と黙って食い違いうる (#380)
    var observeFacet: URL { facet(StartupReads.observe) }
    var inputFacet: URL { facet(StartupReads.input) }

    // 区画の URL の組み立ても ``WorkDirectory`` を通す。`.mokume` の綴りをここに持つと、
    // スケッチが書く場所と黙って割れうる (#814)
    func facet(_ entry: StartupReads.Entry) -> URL {
        WorkDirectory.facet(entry.key, under: directory)
    }
    // 作り直しの記録の在処も、書く側と同じ綴りから出す (#730)
    var buildStatus: URL { BuildReport.statusURL(under: directory) }

    /// 要求を置いて待った結果。
    ///
    /// 区画は応答も要求も 1 枚しか持たないので、**別の書き手が居ると、自分の識別子は応答に二度と現れ
    /// ない**ことがある。「応えなかった」と「取り合った」は打つ手が違う (起動し直しても、取り合いは
    /// 直らない) ので、分けて持つ ([#2857](https://github.com/mokume-metal/mokume/issues/2857))。
    enum Exchange {
        /// 自分の識別子の応答が返った。
        case answered([String: Any])
        /// 期限まで応答が返らなかった。`replaced` は、**期限の時点で `request.json` が自分の要求でなく
        /// なっていた**か (別の書き手が置き換えた。応えなかった理由は同じ形で添える)。
        case timedOut(replaced: Bool)
        /// 別の書き手が `request.json` を置き換え、自分の要求を置く前には無かった応答が書かれた。面は
        /// 要求を 1 枚ずつ拾い、応え終えるまで次を拾わないので、**自分の識別子の応答はもう来ない**。
        /// 当たった後に上書きされたのか、読まれる前に置き換えられたのかは、応答だけからは分からない。
        case contested
        /// 取り消された ([#2355](https://github.com/mokume-metal/mokume/issues/2355))。
        /// `placed` は、要求を区画へ置いた後か。**置いた後なら要求は区画に残り**、スケッチはそれに
        /// 応え続けうる (取り消しはスケッチへは届かない・#3030)。置く前なら何も置いていない。
        case cancelled(placed: Bool)
    }

    /// 要求を置き、同じ識別子の応答が返るまで待つ。
    ///
    /// 待つ間は**応答に加えて `request.json` も見る**。自分の識別子の応答なら返す。`request.json` が
    /// 自分の要求でなくなっていて (別の識別子・識別子が無い・壊れた中身)、応答が**自分の要求を置く
    /// 直前の応答でも自分の応答でもない**ものを echo したら、取り合いとして返す。つまみ側
    /// (``RemoteParams``) の「置く直前の echo と自分の要求以外を echo したら決着」と同じ規則で、
    /// **別の書き手の要求が続けて置かれても** (b1 の後にすぐ b2 が置かれて、自分には `report=b1`・
    /// `request=b2` しか見えなくても) 見逃さない。`request.json` が自分の要求のままの間は決着にしない
    /// — 別の書き手へ応えている途中の応答は、その後に自分の要求へも応えうる。時計では見切らない
    /// (「自分の echo が N ms 来なければ取り合い」は、壁時計で完了を判断しない ADR-0018 決定 3 に反する)。
    /// `request.json` が無い・読めない回は判定を飛ばして待ち続ける。
    ///
    /// - Returns: ``Exchange``。
    /// - Parameter extraWait: 応答が返るまでにフレームが何枚も進む要求 (続けて撮る観測
    ///   など) で、``waitLimit`` に**足す**ぶん。上書きではなく加算にしてある —
    ///   上書きにすると、検査が短く設定した上限を呼ぶ側が知らずに戻してしまう。
    /// - Parameter isCancelled: 巡回のたびに見る。立っていれば待ちを切って ``Exchange/cancelled`` で返す。
    /// - Parameter now: 期限を測る時計。**眠っている間は進まない `DispatchTime` で測る** —
    ///   壁時計 (`Date`) だと、待っている最中に機械が眠ると起きた瞬間に期限を越えて、
    ///   スケッチの応答を待たずに「誰も応えない」を返す ([#1940](https://github.com/mokume-metal/mokume/issues/1940))。
    /// - Throws: 置けなかったときだけ。**型が付いているので、窓口は `\(error)` を
    ///   そのまま返さずに済む** — untyped だったころは `NSCocoaErrorDomain Code=513 …`
    ///   がエージェントへ届いていた。`CommandFailure` は「どの失敗にも次に何をすれば
    ///   よいかを書く」と宣言しているのに、窓口の 2 箇所だけがその規律の外だった。
    func exchange(
        facet: URL, request: [String: Any], id: String, extraWait: TimeInterval = 0,
        isCancelled: () -> Bool = { false },
        sleep: (TimeInterval) -> Void = { Thread.sleep(forTimeInterval: $0) },
        now: () -> DispatchTime = { DispatchTime.now() }
    ) throws(CommandFailure) -> Exchange {
        let waitLimit = self.waitLimit + max(0, extraWait)
        let requestURL = WorkDirectory.requestURL(under: facet)
        let reportURL = WorkDirectory.reportURL(under: facet)
        // **置く直前に echo されていた識別子。** 置いた後に別の識別子の応答が現れたら、自分の要求を
        // 置いた後に面が別の要求へ応えたと読める (取り合いの判定・``Exchange/contested``)
        let echoedBefore = read(reportURL)?["id"] as? String
        // **置く前にも見る。** 取り消しが読み取りの手で先に立っていたら、要求を置かずに戻る
        // (置いてから見るだけだと、取り消された入力が区画へ届いてしまう)
        if isCancelled() { return .cancelled(placed: false) }
        do {
            try FileManager.default.createDirectory(at: facet, withIntermediateDirectories: true)
            // 鍵の並びは ``AtomicFile/writeJSON(_:to:)`` と揃える。ここは辞書を直に
            // 書くので `Encodable` の口を通せない (#989)。**置き方は揃えない**: 区画の JSON (`writeJSON`・
            // プロセス内の `RemoteParams.send` の `publishJSON`) は毎フレームも書くので `rename(2)` で置くが、
            // 窓口の要求は決定の 6 種に入らず、毎フレーム書かないので `AtomicFile.write` (`replaceItemAt`) のまま (#2382)。**形を先に見る** — JSON に
            // できない値を渡すと `JSONSerialization` は Swift の error ではなく ObjC の
            // 例外を出すので、`try` では捕まらず窓口ごと落ちる
            guard JSONSerialization.isValidJSONObject(request) else {
                throw CommandFailure.facetUnwritable(
                    path: requestURL.path, reason: "the request is not in a shape that turns into JSON")
            }
            let data = try JSONSerialization.data(withJSONObject: request, options: [.sortedKeys])
            try AtomicFile.write(data, to: requestURL)
        } catch let failure as CommandFailure {
            throw failure
        } catch {
            throw CommandFailure.facetUnwritable(path: requestURL.path, reason: Diagnostics.reason(error))
        }

        let deadline = now() + Self.boundedWait(waitLimit)
        while now() < deadline {
            if isCancelled() { return .cancelled(placed: true) }
            if let report = read(reportURL) {
                let echoed = report["id"] as? String
                if echoed == id { return .answered(report) }
                if let echoed, echoed != echoedBefore, requestIsNotMine(requestURL, id) == true {
                    return .contested
                }
            }
            sleep(Self.pollInterval)
        }
        return .timedOut(replaced: requestIsNotMine(requestURL, id) == true)
    }

    /// `request.json` が自分の要求でなくなっているか。**中身が自分の識別子でなければ、別の識別子でも、
    /// 識別子が無くても、JSON として壊れていても `true`** (別の書き手が置き換えた)。自分の要求のままなら
    /// `false`。ファイルが無い・読めないときは `nil` (判定を飛ばす)。
    private func requestIsNotMine(_ requestURL: URL, _ id: String) -> Bool? {
        guard let data = try? Data(contentsOf: requestURL) else { return nil }
        let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        return object?["id"] as? String != id
    }

    /// JSON を読む。無い・壊れているときは `nil`。
    func read(_ url: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: url),
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return object
    }

    /// 区画がディレクトリとして在るか。
    ///
    /// **要求を置く前に見る。** ``exchange`` は待つ前に区画を自分で作るので、後から見ても
    /// 必ず在る。走っているスケッチが観測を持っているかどうかは、**この呼び出しが区画を
    /// 作ったのかどうか**にそのまま出る。
    ///
    /// 判定そのものは ``WorkDirectory/directoryExists(at:)`` が持つ — かつてここは
    /// 「`FrameObserver.makeIfEnabled` と同じ形にする」と文章で約束していたが、守る機械は
    /// 居なかった (#814)。**道具とライブラリで割れると下の `notRunning` が嘘をつく** —
    /// `existed` は区画を作ったのがこの呼び出し自身かどうかで案内を出し分けるので、割れた
    /// 側では「起動し直せ」と言われた先で「まだ立ち上がっていない」と言われる (#380 の形)。
    func hasFacet(_ facet: URL) -> Bool {
        WorkDirectory.directoryExists(at: facet)
    }

    /// 別の書き手と区画を取り合ったときの答え。
    ///
    /// **応えなかったとは言わない** — スケッチは別の書き手の要求に応えている。起動し直しも勧めない
    /// (取り合いは起動し直しでは直らない)。自分の要求が当たったかは分からないと言い、次の手を添える。
    /// 入力は当たっているかもしれないので、送り直す前に状態を確かめさせる。観測は撮り直してよい。
    func contested(_ entry: StartupReads.Entry, repeatable: Bool) -> String {
        """
        Another writer placed a request in this facet while this one was waiting, so \(Self.outcome(entry)).

        The facet keeps one request and one report. This request was either applied and then
        overwritten by the other writer's, or replaced before the sketch read it — from here the
        two cannot be told apart. The sketch itself is running and answering.

        \(Self.nextMove(entry, repeatable: repeatable))
        """
    }

    /// 応答は自分のものだったが、絵を写している間に別の書き手の撮り始めが応答を消した (または別の
    /// 識別子に書き換えた) ときの答え ([#2992](https://github.com/mokume-metal/mokume/issues/2992))。
    ///
    /// **写した絵は渡さない。** 掃除は応答を先に消すので、写し終えた後に応答が自分のものでなければ、
    /// 写している間に別の書き手の撮影が始まっていて、写した絵に別の書き手のものが混ざらないとは
    /// 言えない。待っている間の取り合い (``contested(_:repeatable:)``) とは違い、自分の応答は一度
    /// 返っている — 撮り直しの手の案内は同じ (``nextMove``)。
    func contestedWhileCopying(_ entry: StartupReads.Entry, repeatable: Bool) -> String {
        """
        Another writer started its own request in this facet while the picture was being copied out, so \
        the copy cannot be trusted as this request's picture and none is returned.

        The facet keeps one request and one report, and the next request clears the report and rewrites \
        the pictures under the same names. The sketch itself is running and answering.

        \(Self.nextMove(entry, repeatable: repeatable))
        """
    }

    /// 期限まで待っても応答が返らず、その間に別の書き手が要求を置き換えていたときの答え。
    ///
    /// **走っていないとは言わない** — 置き換えた要求が長い列の観測なら、スケッチは走って撮っている。
    /// 自分の要求が当たったかは分からないと言い、次の手を添える (``contested(_:repeatable:)`` と同じ
    /// 趣旨)。応えなかった理由 (``notRunning(_:existed:)``) の案内は付けない — 取り合いの後に
    /// 起動し直しを勧めても直らない。次に呼んで、誰も置き換えていないのに応えなければ、そのとき
    /// 応えなかった理由を言う。
    func replacedAtDeadline(_ entry: StartupReads.Entry, repeatable: Bool) -> String {
        """
        Another writer replaced this request in the facet before the time ran out, so \(Self.outcome(entry)).

        No answer to this request, or to the one that replaced it, showed in the report within the time.
        The sketch may be busy with the other writer's request (a long series, for one), or it may not
        be running — from here the two cannot be told apart.

        \(Self.nextMove(entry, repeatable: repeatable))
        """
    }

    private static func outcome(_ entry: StartupReads.Entry) -> String {
        entry == StartupReads.input
            ? "what became of the events is not known" : "what became of the picture is not known"
    }

    /// 次の手。**入力は当たっているかもしれないので、送り直す前に状態を確かめさせる。** 観測は撮り直して
    /// よいが、`time` 付きの観測は 1 フレームを描き直して副作用を残すので、入力と同じに確かめさせる。
    private static func nextMove(_ entry: StartupReads.Entry, repeatable: Bool) -> String {
        if entry == StartupReads.input {
            return "Call `observe` to see where things stand before sending the events again — they may already have taken effect."
        }
        return repeatable
            ? "Taking the picture again is safe: call `observe` again."
            : "A shot with time redraws one frame and keeps what the sketch's draw left behind, and "
                + "that frame may already have been drawn. Call `observe` without time to see where "
                + "things stand before asking for it again."
    }

    /// 走っているスケッチが応えないときの答え。**その場で直せるところまで書く。**
    ///
    /// 応えない理由は**打つ手の違う 4 つ**に分かれる (4 つ目は窓口がスケッチでない場所で立った
    /// ときだけ)。`existed` (要求を置く前に区画が在ったか) が 1 つ目を絞る:
    ///
    /// - **在らせたのがこの呼び出し自身** — 走っているスケッチは区画を持っていない。
    ///   区画を見るのは起動の瞬間だけなので、**起動し直す**以外に直らない
    ///   ([#227](https://github.com/mokume-metal/mokume/issues/227))
    /// - **元から在った** — 区画を作る順序は合っているので、走っていないか応答が止まっている
    ///
    /// **2 つ目はどちらの側でも起きる** — 走らせる側と窓口で区画の基準が割れていると、互いに
    /// 別の区画を見る。症状は上のどちらとも同じ形で出るのに、**起動し直しても直らない**
    /// ([#380](https://github.com/mokume-metal/mokume/issues/380))。実際に踏むと、案内どおり
    /// 起動し直した先で「まだ立ち上がっていない」と言われる — `watch` は走っているのに、である。
    ///
    /// 文面は読む時点ごとに書き足さず、**起動の瞬間に決まるものの一覧を名指す**。一覧
    /// (``StartupReads``) に増えたものは `reference` の `startup` に自動で並ぶ。
    ///
    /// **文面は窓口の場所の事実 (``place``・``workDirectoryGiven``) から組む** ([#2487](https://github.com/mokume-metal/mokume/issues/2487))。
    /// 「窓口の場所 = スケッチの場所」を前提に書くと、スケッチでない場所で立った窓口では
    /// 1 (起動し直せば区画を拾う) と 2 (基準が割れているなら `MOKUME_WORK_DIR` を揃える) が
    /// 偽になり、4 と食い違う:
    ///
    /// - **2 には、`MOKUME_WORK_DIR` が無ければ「窓口をスケッチの場所で起こす」を常に載せる。**
    ///   本当の条件は「窓口と走っているスケッチの区画の基準が割れている」で、`Package.swift` の
    ///   有無はその代理でしかない — 別のスケッチの場所で立った窓口も同じ形で割れる
    /// - **区画の基準がスケッチでない場所に落ちていれば (``facetsOutsideSketch``)、1 をその場所の
    ///   話として言い直し、4 つ目の可能性として場所の手を言う。** 区画は今どおり作る (#2487 の
    ///   案 B) — 組み上げた実行ファイルをその場所から起こすと、スケッチの区画もそこに置かれて
    ///   正しく繋がるので、断らずに候補の 1 つとして並べる
    func notRunning(_ entry: StartupReads.Entry, existed: Bool) -> String {
        // **見張りが、起こせなかったと記録に書いていれば、4 つの候補を並べずにそれを言う** (#3169)。
        // 「応えない」と案内すると、作者は端末を見に行かないと何が起きたか分からない
        if let notStarted = notStartedAnswer() { return notStarted }
        // **読めたなら原因は確定している。** 候補を並べる前に、そう言う
        if let package = place?.directory,
            DependencyFacets.lacks(entry, forPackageAt: package) == true
        {
            return lacksFacet(entry)
        }
        let path = facet(entry).path
        let outside = facetsOutsideSketch ? place : nil
        let count = outside == nil ? "three" : "four"
        let opening = existed
            ? """
            The running sketch did not answer. \(entry.name) (\(path)) was already there
            before the request was placed, so this is not about the order facets are created in.
            There are \(count) possibilities, and each takes a different move.
            """
            : """
            The running sketch did not answer. \(entry.name) (\(path)) was not there when
            the request was placed, so this call created it.
            There are \(count) possibilities, and each takes a different move.
            """
        var items = [
            firstPossibility(entry, existed: existed, outside: outside),
            secondPossibility(),
            """
            3. The mokume the sketch depends on is a version without \(entry.name)
               Facets have been added over time, so a sketch pinned to an older version can
               be missing one. **Restarting will not fix that one either.** Which facets the
               pinned version lacks is named by

                   \(Command.name) doctor <sketch directory>
            """,
        ]
        if let outside {
            items.append("4. \(InterfacePlace.notASketchHeading)\n" + Self.indented(outside.restartMove))
        }
        return ([opening] + items + [
            "What gets decided at launch is listed in `reference`, under `\(Tools.startupDocument)`."
        ]).joined(separator: "\n\n")
    }

    /// 作り直しの記録が、子を起こせなかったと名乗っているときの答え ([#3169](https://github.com/mokume-metal/mokume/issues/3169))。
    /// **そうでなければ `nil`** (元の案内へ落ちる)。
    ///
    /// 組み立ての失敗も `setup()` が投げた失敗も、見張りは起動できなかった回として記録に書く (`ok: true`・
    /// `launched: false`・`notStartedReason`)。理由をここで言い、子が自分で渡した言葉があれば (理由に
    /// ``BuildReport/sketchReportedPrefix`` の行がある) 全文は記録の `output` で読めるので、`build_status` を指す。
    /// **子の標準エラーは読まない** — 理由は区画を通って届く。
    ///
    /// **答えるのは、次の 3 つが揃うときだけである。**
    /// - **記録を書いた見張りが今も居る** (``isWatching``)。記録は見張りが終わっても残る。見張りを止めた後に
    ///   手で起こし直した作品が応えないとき、止まる前の記録で「見張りが作り直す」と答えると、起動し直しを
    ///   勧める元の案内 (#227) も、依存の不足 (``DependencyFacets``) の案内も隠れる
    /// - **終われと言われて起こさなかった回ではない** (``BuildReport/stopRequestedNotice``)。起動の失敗ではなく、
    ///   「save すれば作り直す」とも言えない
    /// - 理由が空でない
    ///
    /// **走っていないとは断定しない。** 見張りは前の版を残して走らせ続けることがある (#3172)。記録からは
    /// その有無が読めないので、新しい版が起動しなかったことと、この呼び出しに誰も応えなかったことだけを言う。
    /// **無い言葉を約束しない** — 子が理由を置けなかった回 (落ちた・実行できない成果物) には、子の言葉が無い。
    /// 次の作り直しが通れば記録は起動した回に書き換わり、この答えは出なくなる。
    func notStartedAnswer() -> String? {
        guard let status = read(buildStatus), status["ok"] as? Bool == true,
            status["launched"] as? Bool == false,
            let reason = status["notStartedReason"] as? String, !reason.isEmpty,
            !reason.hasPrefix(BuildReport.stopRequestedNotice), isWatching(directory)
        else { return nil }
        let hasSketchAccount = reason.split(whereSeparator: \.isNewline)
            .contains { $0.hasPrefix(BuildReport.sketchReportedPrefix) }
        let account =
            hasSketchAccount
            ? """
                The sketch's own account of what went wrong follows the reason in `output` of \
                `build_status` (\(BuildReport.statusRelativePath)).
                """
            : """
                The sketch left no account of its own; what it printed before it ended is in the \
                terminal that runs `\(Command.name) watch`.
                """
        return """
            The newest version of the sketch was not started, and nothing answered this request. The last build \
            passed, but starting it failed.

            \(reason)

            \(account)

            The version from before keeps running if it had drawn (see `build_status`); otherwise nothing is \
            running. If one is running but gave no answer, it is busy rather than gone.

            Fix the cause and save: the watching `\(Command.name) watch` rebuilds and starts it again, and this \
            answer goes away once it does.
            """
    }

    /// 1 つ目の可能性。区画の基準がスケッチでない場所に落ちていれば (`outside`)、その場所の話と
    /// して言う — `watch` は自分のスケッチの場所で走るので、そこを起動し直しても窓口の区画は
    /// 見ない。この場所を見るのは、ここから起こした (組み上げた実行ファイルの) スケッチだけである。
    /// 前に取り消した要求を、スケッチがまだ撮っているときの答え。
    ///
    /// **取り消しは窓口の待ちを切るだけで、スケッチへは届かない** (#3030)。続けて撮る観測 (最長で
    /// 約 4 分) は撮り終えるまで区画を塞ぎ、その間に置いた次の要求は拾われない。置いた要求は
    /// 自分のまま残るので、取り合いとも見えず、「応えない」と案内すると、起動し直しを勧めて
    /// 撮っている最中のスケッチを止めさせる。
    func stillTaking(_ entry: StartupReads.Entry, cancelledID: String) -> String {
        """
        The sketch did not answer yet, but it is most likely still working on a request this interface \
        cancelled earlier (id \(cancelledID)). Cancelling stopped this interface from waiting; it did not \
        reach the sketch, which keeps taking the shots it was asked for (a long series can take minutes) \
        and takes the next request in \(entry.name) only after that.

        This request was placed and is waiting behind it. Nothing needs restarting: try again once the \
        earlier one is done. If the sketch was stopped in the meantime, start it again.
        """
    }

    private func firstPossibility(
        _ entry: StartupReads.Entry, existed: Bool, outside: InterfacePlace?
    ) -> String {
        switch (existed, outside) {
        case (true, nil):
            return """
                1. Nothing is running yet, or it has stopped answering
                   Start `\(Command.name) watch` in the sketch's directory, then call again.
                """
        case (false, nil):
            return """
                1. The sketch launched without \(entry.name)
                   \(entry.note).
                   **Restart it.** The facet is there now, so it does not need creating again.

                       \(Command.name) watch <sketch directory>
                """
        case (true, let place?):
            return """
                1. Nothing started from this interface's directory is running, or it has stopped answering
                   Only a sketch started from that directory itself (a built app run there) uses
                   the facets here: \(place.directory.path)
                   `\(Command.name) watch` runs a sketch in its own directory instead, which is 4 below.
                """
        case (false, let place?):
            return """
                1. A sketch started from this interface's directory launched without \(entry.name)
                   \(entry.note).
                   What this call created is under the directory this interface was started in,
                   not under a sketch's directory: \(place.directory.path)
                   If a built app was started from there, **restart it** — the facet is there now.
                   A sketch run from its own directory does not look here at all, which is 4 below.
                """
        }
    }

    /// 2 つ目の可能性。基準の 1 行は `watch` と同じ言葉で名乗る (#380) ので、ここでは変えない。
    /// **`MOKUME_WORK_DIR` が無ければ、窓口をスケッチの場所で起こす手を常に載せる** — 基準は
    /// それぞれが立った場所なので、窓口をスケッチの場所で起こせば揃う (#2487)。
    private func secondPossibility() -> String {
        var text = """
            2. The interface and the sketch disagree on the facet base
               What this interface is looking at:

                   \(StartupReadsReport.baseLine(base: directory, given: workDirectoryGiven))

               If the "\(StartupReads.workDirectory.name)" that `watch` names as it starts
               differs from that, the two are looking at different facets.
               **Restarting will not fix that one.** Start both `watch` and the interface
               under the same \(StartupReads.workDirectory.key).
            """
        if !workDirectoryGiven {
            text += "\n" + """
                   With \(StartupReads.workDirectory.key) unset, each uses the directory it was started for,
                   so starting this interface in the sketch's directory also makes them agree:

                       \(Command.name) mcp <sketch directory>
                """
        }
        return text
    }

    /// 見出しの下に並べる本文を、1〜3 と同じ 3 字に下げる。複数行の文字列へ差し込んだ値は
    /// 字下げされないので、ここで下げる。空行は下げない。
    private static func indented(_ body: String) -> String {
        body.split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.isEmpty ? "" : "   \($0)" }.joined(separator: "\n")
    }
    /// 依存がその面を持たないと読めたときの答え。
    ///
    /// **候補を並べない。** 原因が確定しているので、並べると読み手に選ばせることになる。
    /// 書くのは打つ手だけで、どちらも走らせる側を変えるものである — 窓口の側では直らない。
    func lacksFacet(_ entry: StartupReads.Entry) -> String {
        """
        The running sketch did not answer. **The mokume this sketch depends on does not have
        \(entry.name)** — that facet arrived in a later version, and it is not in the spec
        (`Schemas/`) of the version pinned here.

        **Restarting will not fix this.** There are two moves, and both change the running side.

        1. Raise the sketch's mokume dependency to a version that has this facet
        2. Do without this facet

        `\(Command.name) doctor <sketch directory>` lists which facets the pinned version lacks.
        """
    }
}

/// 窓口を立てた場所と、そこがスケッチか。**起動の時点で決まる事実** ([#2487](https://github.com/mokume-metal/mokume/issues/2487))。
///
/// 窓口は在る場所なら受ける (`claude mcp add mokume -- mokume mcp` は打った場所で起こす・#2321)
/// ので、スケッチでない場所でも立つ。答えの文面は「窓口の場所 = スケッチの場所」を前提にせず、
/// この事実から組む — 前提にしたまま 1 行を足すと、同じ答えの中で行どうしが食い違う。
///
/// **起動の時点で 1 度だけ見る。** 立てた後に `new` で `Package.swift` が置かれても追わない —
/// 区画の基準 (``Facets/workDirectoryGiven``) と同じく、起動の瞬間に決まるものとして扱う。
struct InterfacePlace: Equatable {
    /// 窓口を立てた場所 (パッケージの場所)。
    let directory: URL
    /// そこに `Package.swift` があるか。`run`・`watch` が場所を受けるときと同じ見方。
    let isSketch: Bool

    /// 場所を見て決める。
    static func at(_ directory: URL) -> InterfacePlace {
        InterfacePlace(
            directory: directory,
            isSketch: FileManager.default.fileExists(
                atPath: directory.appendingPathComponent("Package.swift").path))
    }

    /// スケッチの場所で立っていないことの名乗り。
    static let notASketchHeading = "This interface was not started in a sketch's directory"

    /// スケッチの場所で立っていないときの一手。**文の正典はここ 1 つ**で、応えないときの 4 つ目と、
    /// 作り直しの記録が無い・置けない・版が引けないときの答えが使う。
    var restartMove: String {
        """
        There is no Package.swift in \(directory.path).
        If the sketch is in another directory, start this interface there instead:

            \(Command.name) mcp <sketch directory>
        """
    }

    /// 答えの後に添える段落。
    var note: String { "\(Self.notASketchHeading). \(restartMove)" }

    /// `initialize` の応えの `instructions` に載せる文 ([#2797](https://github.com/mokume-metal/mokume/issues/2797))。
    ///
    /// **繋いだ側へ、最初の `observe` が答えるのを待たずに場所を名乗る。** スケッチの場所で立って
    /// いれば場所を言う 1 行だけ (繋いだ全セッションのシステムプロンプトに入りうるので、足さない)。
    /// スケッチでなければ、答えと同じ ``note`` (見出しと手) を続ける — 文の正典は ``restartMove``
    /// の 1 つで、ここでは写さない。
    var instructions: String {
        let serving = "This interface serves \(directory.path)"
        return isSketch ? "\(serving), a sketch's directory." : "\(serving). \(note)"
    }
}
