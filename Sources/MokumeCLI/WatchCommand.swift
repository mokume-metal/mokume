// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import AppKit
import Foundation
import mokume

/// 終わりの合図を受けたか。
///
/// **シグナルのハンドラでは、この 1 バイトを立てるだけにする。** ハンドラの中で安全に
/// できることは限られており (再入しうる)、出力も後始末もそこでは行わない。実際に終える
/// のは巡回の側で、印を見て抜ける。
///
/// `private` にしないのは検査から読むため。合図は 1 プロセスに 1 つしかないので、
/// 置き場も 1 つにする。
nonisolated(unsafe) var watchStopRequested: sig_atomic_t = 0

/// 保存したら作り直して差し替える。
enum WatchCommand {
    /// 見に行く間隔。**素朴に見に行く形で始める** — 監視の仕組みを先に入れると、
    /// それが要るのかどうかを確かめないまま持つことになる (ADR-0008)。分解した
    /// 所要時間に検出の時間が出るので、足りなければ実測を根拠に差し替えられる。
    static let interval: TimeInterval = 0.25

    /// 終わりの合図として受けるもの。
    ///
    /// **端末が消える形 (SIGHUP) がいちばん多い。** 見張りを起こした端末やセッションが
    /// 終わると、既定ではその場で親だけが消え、子が離れる — [#454](https://github.com/mokume-metal/mokume/issues/454)
    /// が記録した孤児はこの形をしている ([#691](https://github.com/mokume-metal/mokume/issues/691))。
    ///
    /// **時間切れで畳む形 (SIGALRM) も受ける。** `perl -e 'alarm 120; exec …'` のように期限を
    /// 付けて見張りを起こすと、期限で届くのはこれである。受けないと既定の動作でその場で消え、
    /// 子も作り直し中の `swift build` も置いていく ([#1427](https://github.com/mokume-metal/mokume/issues/1427))。
    /// 既定で終わる合図はほかにもあるが (SIGUSR1 など)、踏まれていないので足さない (ADR-0008)。
    ///
    /// **捕まえられないものは、子の側が拾う。** 強制終了 (SIGKILL) と、親ごと消える終わり方は
    /// ここでは受け取れない ([#681](https://github.com/mokume-metal/mokume/issues/681))。そこで
    /// 見張りが消えると子への管が畳まれるので、子はそれを見て自分で終わる (#1427)。
    /// 作り直し中の `swift build` は拾えない (#1147 の残り)。
    static let stopSignals: [Int32] = [SIGINT, SIGTERM, SIGHUP, SIGALRM]

    /// - Parameter watching: 巡回のしかた。**検査から差し替える** — 既定は合図が来るまで
    ///   回り続けるので、始める前に止まることを確かめる検査がここで固まらないようにする。
    static func run(
        _ arguments: [String],
        watching: (WatchSession, Viewer?) -> Void = { watch($0, viewer: $1) }
    ) throws(CommandFailure) {
        let invocation = try Invocation.parse(arguments)
        let directory = try invocation.directory
        guard FileManager.default.fileExists(
            atPath: directory.appendingPathComponent("Package.swift").path)
        else {
            throw .packageNotFound(path: directory.path)
        }

        // **場所を 1 本のものとして取る。何かに触れる前に、いちばん先に** ([#2093](https://github.com/mokume-metal/mokume/issues/2093))。
        // 見張りは場所の区画を自分 1 本のものとして作り直し・畳むので、同じ場所に 2 本目が居ると
        // 1 本目の窓が 2 本目の子を映し、止めると 1 本目の次の世代が自分の窓を開く。先客が居れば
        // ここで断って終わる — 区画も、作り直しも、子の起動も、何も始めない。錠は終わりまで持つ
        // (後始末の後に手放す)。区画の基準は環境変数が決める (走らせるスケッチは親の環境を
        // 引き継ぐので、記録をパッケージの場所へ置くと観測とだけ場所が割れる・#331)。**計算は 1 つ** (#791)
        let facetBase = try invocation.facetBase()
        let place = try WatchPlaceLock.claim(under: facetBase)
        defer { place.release() }

        // **見張り始める前に見る。** 宣言の抜けはビルドを通ってしまうので、後では
        // 「作り直しは通ったのに絵が出ない」形になる。`run` と同じ関数を同じ位置で呼ぶ
        //
        // **見るのはここ 1 度きりで、作り直しのたびには見ない** (#682)。毎回見る形は
        // 「走っているものは落とさない」という作り直しの失敗の扱いへ合流させることになり、
        // 作り直しの記録が運ぶ終了コードにビルド以外のものが混じる。踏まれてから足す
        // (ADR-0008) — 見張ったまま資材を足して絵にならない理由へ辿れなかった実例が出た日に
        try ResourceDeclaration.check(in: directory)

        // **置き場は見張り始める前に 1 度だけ決める。** 作り直しのたびに決め直すと、
        // 途中で先客が現れたときに作り直しと解決が別の置き場を指しうる (#1055)
        //
        // **導き手は 1 つを分け持つ。** ここで導いたものを作り直しがそのまま使うので、
        // 宣言が変わるまで `swift` は 1 本も起きない — 別々に組むと、初回だけ
        // `dump-package` と `--show-bin-path` が二重に走る (#1067)
        let running = RunningBuild()
        let resolver = BuildResolver.live(
            in: directory, invocation: invocation, running: running)
        let context = try resolver.current().context

        let session = WatchSession(
            directory: directory, context: context, facetBase: facetBase,
            reportsRate: true, hooks: .live(resolver: resolver, running: running))
        say("Watching: \(directory.path)")
        if let notice = context.place.notice { say(notice) }
        // どの道具で見張っているかを名乗る。**いちばん長く見ている画面に無いと、手元
        // ビルドと配布版の取り違えに気付けない** (#633 が実際にそうなった・#684)
        say("Tool: \(ToolVersion.describe())")
        // **常に名乗る。** 以前は基準がスケッチの場所と違うときだけ出していたが、それだと
        // 窓口の側にだけ MOKUME_WORK_DIR が効いている向きで比べる材料が出ない (#380)
        say(
            StartupReadsReport.baseLine(
                base: session.facetBase, given: WorkDirectory.given != nil))
        // **作り直している間も、状態が読めるようにする。** 作り直しは終わってからしか
        // 名乗らないので、これが無いと待っている間は画面が 1 文字も動かない (#695)
        //
        // **端末が正で、プレビューはそれを映す。** 同じ 1 本の文言を両方へ渡すので、
        // 二か所で別のことを言う形にはならない (#705 の未決だったところ)
        var viewer: Viewer?
        session.willRebuild = { initial in
            let line = initial ? startingLine : rebuildingLine
            say(line)
            // **作り直しが始まったら、前の子の 1 枚目を待たない。** 遅れて来た合図がこの行を畳む
            viewer?.firstFrame.settle()
            viewer?.preview.report(line, spinning: true)
        }
        // **長く待つ間を無言にしない。** 終えるときは撮っていた動画を閉じ終えるまで待つので
        // (#1219)、黙っていると固まったと読まれる
        session.willWaitForFinish = { say(finishWaitLine(remaining: $0)) }

        // **窓口が使う区画は、窓より先に置く。** 窓が出せるかどうかと関係が無いうえ、
        // 置き損ねると道具ごとに 1 回ずつ起動し直させることになる (#464)
        let prepared = prepareFacets(under: session.facetBase)

        // **窓を先に出す。** 出せたときだけ区画ができ、子は窓を持たずに走る
        // ([ADR-0032] 決定 1)。子を起こしてからでは間に合わない — 区画は起動の瞬間に
        // しか読まれない
        //
        // [ADR-0032]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0032-window-ownership.md
        viewer = openViewer(for: session)

        // 子を起こす前に受け口を置く。起こした後だと、その隙間に来た合図で
        // 既定の振る舞い (親だけが即座に終わる) に落ちて子が残る
        installStopHandlers()

        // **最初の作り直しも巡回の中で始める。** ここで直に呼ぶと、窓が画面に出るのは
        // 作り直しが終わってからになる — いちばん長く待つのが初回なのに、待っている間
        // だけ状態がどこにも出ない (#695 が端末で直したことが、窓では直らない)
        // **道具立ての終わり方も受ける。** Dock からの終了・ログアウト・システム終了は
        // 窓を閉じる経路を通らない (`windowShouldClose` も巡回も通らない) ので、受けないと
        // 子と区画が置き去りになる — 窓を持つ道具は `.regular` なので Dock に出ている
        // ([#826](https://github.com/mokume-metal/mokume/issues/826))
        let delegate = ApplicationDelegate(
            stopRequested: {
                requestStop()
                session.noteStopRequested()
            },
            isFinished: { session.finishStage == .done },
            teardown: { teardown(session, viewer, created: prepared) })
        NSApplication.shared.delegate = delegate

        // **巡回に入る前に断る。** 窓が覆われてから立てるのでは遅い — App Nap は
        // 起動から 30〜60 秒で入る (#1199)
        refuseThrottling()
        watching(session, viewer)
        teardown(session, viewer, created: prepared)
    }

    /// 窓口が使う区画を、子を起こす前に置く。**窓も GPU も要さない。**
    ///
    /// 区画が在るかどうかを見るのは起動の瞬間だけなので、誰も置かないと窓口の道具は
    /// 初めて呼んだ回に必ず空振りし、道具ごとに 1 回ずつ起動し直すことになる ([#464])。
    /// 置くのは要求を置く側 (`Facets.exchange`) だが、それでは間に合わない。
    ///
    /// **`viewport` は入れない。** 見張りの子はあれが在ると窓を開かず共有面へ差し出すので、
    /// 窓が出せなかった回に置くと絵がどこにも出ない ([ADR-0032] 決定 1)。置く場所は
    /// `openViewer` の中が正しい。
    ///
    /// - Returns: **こちらが作ったものだけ。** 元から在ったものは含めない — 人が置いた
    ///   区画を後始末で畳まないためである。
    ///
    /// [#464]: https://github.com/mokume-metal/mokume/issues/464
    /// [ADR-0032]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0032-window-ownership.md
    static func prepareFacets(under base: URL) -> [URL] {
        var created: [URL] = []
        for entry in StartupReads.all
        where entry.origin == .facet && entry.key != StartupReads.viewport.key {
            let facet = WorkDirectory.facet(entry.key, under: base)
            guard !WorkDirectory.directoryExists(at: facet) else { continue }
            guard
                (try? FileManager.default.createDirectory(
                    at: facet, withIntermediateDirectories: true)) != nil
            else { continue }
            created.append(facet)
        }
        return created
    }

    /// 後始末。**走らせていたものも、置いた区画も残さない。**
    ///
    /// **2 度通っても、言うことは 1 度きり。** 巡回を抜けた後と、道具立てが終わるとき
    /// (Dock・ログアウト) の両方から呼ばれうるので、片方だけを正しい順序にしても足りない。
    ///
    /// - Parameter created: `prepareFacets(under:)` が置いた区画。**畳むのはこれだけ** —
    ///   人が置いたものは残す。
    static func teardown(_ session: WatchSession, _ viewer: Viewer?, created: [URL] = []) {
        guard !teardownDone else { return }
        teardownDone = true
        // **断りを返す。** 終わりの経路は 2 つある (巡回が抜けた / 道具立てが終わらせた)
        // が、どちらもここを通る
        allowThrottling()
        // **待つ手続きは、窓を開いたまま済んでいる。** ここは窓を閉じる前の取りこぼしを拾うだけで、
        // 通常は何もしない (``finishBlocking(_:)``)
        finishBlocking(session)
        viewer?.close()
        // **置いていかない。** 区画は面の番号を置く場所で、置いた見張りが居なくなれば
        // 指す先も無い (同じ場所に別の見張りは居ない — ``WatchPlaceLock`` が断っている・#2093)。残っても居合わせた実行は窓を開くが、開くたびに「区画が在るのに
        // 窓の持ち主から起こされていない」と名乗らせることになる (#2028)
        if viewer != nil { try? FileManager.default.removeItem(at: viewportFacet(for: session)) }
        for facet in created { try? FileManager.default.removeItem(at: facet) }
    }

    /// 後始末を済ませたか。**印は 1 プロセスに 1 つ** (終わりの合図と同じ扱い)。
    static var teardownDone = false

    // MARK: - 間引きを断る (#1199)

    /// 間引きを断っている宣言。**見張っている間だけ持つ。**
    private static var throttleRefusal: (any NSObjectProtocol)?

    /// いま断っているか。**検査から読む** — 宣言そのものは外から見えない。
    static var refusesThrottling: Bool { throttleRefusal != nil }

    /// 省電力の間引きを断る。
    ///
    /// **窓が覆われて前面から降りると、道具は App Nap に入る。** そこでは実行ループの
    /// タイマーの断り (`PreventTimerThrottleTier0`) だけでなく、CPU の優先度の断り
    /// (`PreventSuppressedCPU` / `PreventLowPriorirtyCPU`) も外れる — 機械が混んでいると
    /// **走れる状態のまま順番が回ってこない** (`pri` が 46 から 4 へ落ちる)。入れ替わり
    /// (`SharedFrameStage.displayLinkFired` → `promoteIfReady`)・保存の検出・終わりの
    /// 合図は同じ実行ループに載っているので、揃って数秒途切れる
    /// ([#1199](https://github.com/mokume-metal/mokume/issues/1199) に交互の実測)。
    ///
    /// **スケッチの宣言 ([ADR-0012] 決定 5・`SketchApplication.run()`) とは強さを分ける。**
    /// あちらは `[.userInitiated, .latencyCritical]` で、絵を出し続けるために機械を
    /// 寝かせないことまで引き受けている。こちらは**間引きを断るだけで足りる** —
    /// 実測では弱い宣言でも App Nap に入らず、遅れは 0 だった。道具が「機械を寝かせない」
    /// という約束を足さないので、ビルドが失敗したまま置いた見張りが夜通し機械を
    /// 起こし続けることもない。走っているスケッチが在る間は、子の側の宣言がその役を持つ。
    ///
    /// [ADR-0012]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0012-view-layer.md
    static func refuseThrottling() {
        guard throttleRefusal == nil else { return }
        throttleRefusal = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiatedAllowingIdleSystemSleep],
            reason: "keeping the watch loop and generation swaps on time")
    }

    /// 断りを返す。**何度呼んでもよい** (後始末の経路は 2 つある)。
    static func allowThrottling() {
        guard let refusal = throttleRefusal else { return }
        ProcessInfo.processInfo.endActivity(refusal)
        throttleRefusal = nil
    }

    /// 道具立ての終わり方を受ける。
    ///
    /// **窓を閉じる経路を通らない終わり方がある。** `NSApplication` を終わらせる経路
    /// (Dock の「終了」・ログアウト・システム終了) は `windowShouldClose` を問わず、
    /// `run()` からも戻らない — 後始末はここでしか通れない。
    final class ApplicationDelegate: NSObject, NSApplicationDelegate {
        private let stopRequested: () -> Void
        private let isFinished: () -> Bool
        private let teardown: () -> Void
        private let reply: (Bool) -> Void
        /// 子を止め終えるのを見に来る Timer。**待たせているときだけ持つ。**
        private var poll: Timer?

        /// 見に来る間隔 (秒)。
        static let pollInterval: TimeInterval = 0.1

        /// - Parameter stopRequested: 終われと言われたことを、窓の × と同じ印で伝える
        ///   (``requestStop()`` と ``WatchSession/noteStopRequested()``)。**返事より先に呼ぶ** —
        ///   止めている間も巡回は回り続けるので、覚えさせないと新しい作り直しを始める。
        /// - Parameter isFinished: 走らせていたものを止め終えたか (``WatchSession/finishStage``)。
        /// - Parameter teardown: 窓を閉じる・区画を片付ける。
        /// - Parameter reply: 終わってよいと返す。**検査が差し替える** — 実際に返すと、走者ごと終わる。
        init(
            stopRequested: @escaping () -> Void, isFinished: @escaping () -> Bool,
            teardown: @escaping () -> Void,
            reply: @escaping (Bool) -> Void = {
                NSApplication.shared.reply(toApplicationShouldTerminate: $0)
            }
        ) {
            self.stopRequested = stopRequested
            self.isFinished = isFinished
            self.teardown = teardown
            self.reply = reply
            super.init()
        }

        /// **子を止め終えてから終わると返す。** 同期の `applicationWillTerminate` で眠って待つと、
        /// 撮っていた動画を閉じ終えるまで (最大 38 秒) 窓が開いたまま止まる
        /// ([#2576](https://github.com/mokume-metal/mokume/issues/2576))。
        ///
        /// **止める仕事はここでは起こさず、窓の × と同じ道に任せる。** 印を立てれば、巡回が抜けて
        /// (`finish` で子を止め、`leave` する) 道が既にある。**main actor の仕事 (`Task`) で待たない**
        /// — `terminate(_:)` が main actor の仕事から呼ばれると、`await` の続きが永久に来ず終わりが
        /// 保留されたまま固まる (実測・`SketchApplicationDelegate.shouldTerminate` と同じ作法)。
        /// 済んだかは `.common` の Timer から見に来る。
        func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
            stopRequested()
            guard !isFinished() else { return .terminateNow }
            // **返事は 1 回だけ。** 既に待たせているなら、見に来る仕掛けがそのまま返す
            guard poll == nil else { return .terminateLater }
            let timer = Timer(timeInterval: Self.pollInterval, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.pollFinish() }
            }
            RunLoop.main.add(timer, forMode: .common)
            poll = timer
            return .terminateLater
        }

        /// 止め終えたかを 1 回だけ見に来る。**塞がない。** 済んでいたら「終わってよい」と返す。
        ///
        /// 待たせていなければ何もしない。検査は run loop を回さないので、Timer に代わってここを
        /// 直に呼ぶ。
        func pollFinish() {
            guard let timer = poll, isFinished() else { return }
            timer.invalidate()
            poll = nil
            reply(true)
        }

        /// 待たせているか。**検査から読む。**
        var isWaitingToTerminate: Bool { poll != nil }

        func applicationWillTerminate(_ notification: Notification) {
            teardown()
        }
    }

    /// 作品の窓を出し、絵を渡す区画を置く。
    ///
    /// **順序に意味がある。** 区画を先に作ると、窓を出せなかったときに子も窓を開かず、
    /// **どこにも絵が出ない実行**になる。出せたときだけ区画を作るので、失敗はいままでの
    /// 振る舞い (スケッチが自分の窓を開く) に落ちる。
    ///
    /// 窓には**道具の都合を何も載せない** ([ADR-0032] 決定 1)。つまみも作り直しの状態も
    /// 回っている印も、別に立てるプレビューの仕事である。
    ///
    /// [ADR-0032]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0032-window-ownership.md
    static func openViewer(for session: WatchSession) -> Viewer? {
        NSApplication.shared.setActivationPolicy(.regular)
        let facet = viewportFacet(for: session)
        // **前の見張りが残したものを引き継がない。** 置かれている番号は死んだ面を指す
        //
        // **居るのは死んだ前任だけだと、錠で確かめてある** (#2093)。同じ場所を見張る生きた先客が居れば、
        // ``run(_:watching:)`` が ``WatchPlaceLock`` で断っていて、ここへは来ない。後始末を通らずに消えた
        // 前任 (`SIGKILL`) の錠はカーネルが外しているので、残った区画は作り直してよい
        try? FileManager.default.removeItem(at: facet)
        // つまみの区画は `prepareFacets(under:)` が既に置いている (#464)。走らせている子は
        // 区画が在るときだけ宣言を差し出すので ([ADR-0030] 決定 2)、無いとプレビューに
        // 並べるものが何も来ない
        let params = paramsFacet(for: session)

        let name = session.directory.lastPathComponent
        guard let gpu = try? RenderDevice(),
            let window = try? SharedFrameWindow(gpu: gpu, facet: facet, title: name),
            let preview = try? SharedFramePreview(
                gpu: gpu, facet: facet, params: params, title: "\(name) — Preview"),
            (try? FileManager.default.createDirectory(
                at: facet, withIntermediateDirectories: true)) != nil
        else {
            say("No window can open here, so the sketch will open its own")
            return nil
        }
        // **どちらの窓で触っても、同じ作品へ届く。** 送る前にキャンバスの座標へ写して
        // あるので、窓の大きさの違いはそこで吸収されている — 指は 1 本しかないので、
        // 2 つの窓が「いまの値」を同時に持つことにはならない ([ADR-0032] 決定 4)
        window.onInput = { [weak session] in session?.send($0) }
        preview.onInput = { [weak session] in session?.send($0) }
        // **窓が出せたときだけ世代を重ねる。** 前の世代を畳む合図はこの窓から来るので、
        // 出せなかった実行で重ねると、止める者の居ない子が残る (#1142)
        session.overlapsGenerations = true
        // **2 つの窓は独立に入れ替わりを見る**ので合図は 2 度来る。退役は冪等である
        //
        // **止める待ちは main actor を塞がない** ([#2576](https://github.com/mokume-metal/mokume/issues/2576))。
        // 合図は窓の側の同期の呼び出しなので、待つ仕事は `Task` へ渡す
        let viewer = Viewer(window: window, preview: preview)
        let firstFrame = viewer.firstFrame
        window.onGenerationPromoted = { [weak session] in
            firstFrame.promoted(.window)
            Task { @MainActor in await retire(after: session) }
        }
        preview.onGenerationPromoted = { [weak session] in
            firstFrame.promoted(.preview)
            Task { @MainActor in await retire(after: session) }
        }
        // **どちらの窓が先に出しても畳む。** 2 つの窓は独立に 1 枚目を出すので合図は 2 度来るが、
        // 畳むのは待っている間の 1 度だけである (``FirstFrameWait/shown(_:)``)
        window.onGenerationShown = { [weak preview] in
            if firstFrame.shown(.window) { preview?.report(nil, spinning: false) }
        }
        preview.onGenerationShown = { [weak preview] in
            if firstFrame.shown(.preview) { preview?.report(nil, spinning: false) }
        }
        // **出す前に繋ぐ。** 出してから繋ぐと、その隙間に閉じられたぶんが素通りする
        // (窓の中身を繋ぐ順序と同じ理由)
        askBeforeClosing(viewer)
        // **プレビューを先に出す。** 後に出すと作品の窓の上に重なるので、本番へ送る
        // ほうを掴み直す手間がいちばん最初に生まれる
        preview.open()
        window.open()
        return viewer
    }

    /// 絵を渡す区画の場所。**見張っているスケッチの側の基準へ置く** — 道具自身の作業
    /// ディレクトリへ置くと、子と別の区画を見ることになる (#331)。
    static func viewportFacet(for session: WatchSession) -> URL {
        viewportFacet(under: session.facetBase)
    }

    /// 与えた基準の下の、絵を渡す区画の場所。
    ///
    /// **綴りはここ 1 つ。** 区画の基準を取り違えると、子は見張りと別の場所を見る
    /// ([#791](https://github.com/mokume-metal/mokume/issues/791))。
    static func viewportFacet(under base: URL) -> URL {
        WorkDirectory.facet(StartupReads.viewport.key, under: base)
    }

    /// つまみの区画の場所。**絵を渡す区画と同じ基準へ置く** — 走らせている子が書く先と
    /// 揃っていないと、宣言が 1 つも見えない (#331)。
    static func paramsFacet(for session: WatchSession) -> URL {
        WorkDirectory.facet(StartupReads.params.key, under: session.facetBase)
    }

    /// 窓から終わりを頼まれた。
    ///
    /// **合図の置き場を増やさない。** シグナルと同じ印を立てるだけなので、この後は既に
    /// ある道 (巡回が抜ける → 子を止める → 窓を畳む → 区画を片付ける) がそのまま通る。
    /// 窓を閉じるのもここではない — 順序は `run` の後始末が持っている ([#826])。
    ///
    /// [#826]: https://github.com/mokume-metal/mokume/issues/826
    static func requestStop() {
        watchStopRequested = 1
    }

    /// 窓の × を押した人に問うことを、2 つの窓へ同じように繋ぐ。
    ///
    /// **作品の窓とプレビューで意味を分けない** ([ADR-0032] 決定 7)。プレビューだけが
    /// 消える形は、決定 7 が作らないと決めた「既定を外す口」そのものである。
    ///
    /// [ADR-0032]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0032-window-ownership.md
    static func askBeforeClosing(_ viewer: Viewer) {
        viewer.window.askBeforeClosing(
            message: closeMessage, detail: closeDetail, confirm: closeConfirm,
            cancel: closeCancel, then: { requestStop() })
        viewer.preview.askBeforeClosing(
            message: closeMessage, detail: closeDetail, confirm: closeConfirm,
            cancel: closeCancel, then: { requestStop() })
    }

    /// 入れ替わりを知らせ、後ろの世代を畳み、期限に掛かったことがあれば名乗る。
    ///
    /// **名乗るのは口の側である** — ``WatchSession`` は判断だけを持ち、出力を持たない
    /// (#732 が終わり方について定めた分担を、差し替えの側でもそのまま使う)。新しい絵が
    /// 出るまでの記録もこの合図で足される (#930)。
    static func retire(after session: WatchSession?) async {
        announce(await session?.generationPromoted())
    }

    /// 前の世代を畳んだ結果のうち、人が知るべきもの (期限に掛かった) だけを名乗る。
    private static func announce(_ outcome: WatchSession.StopOutcome?) {
        switch outcome {
        case .killed: say(killedLine)
        case .abandoned(let pid): say(abandonedLine(pid: pid))
        default: break
        }
    }

    /// 作り直した子が共有面を作れず自分の窓を開いたとき、見張りが名乗る行 (#2350)。
    ///
    /// **子が名乗る理由** (`Could not place …` / `Could not make …`) は端末に既に出ているので、
    /// ここは見張りの側で起きたこと — 絵と入力が子の窓へ移り、前の世代を畳んだこと — を言う。
    /// 前の世代が居なかった回 (最初の子) は畳んでいないので、言わない。
    static func fellBackLine(replacing: Bool) -> String {
        replacing
            ? "The new version could not hand its frames to this window, so it opened its own — "
                + "the previous version is stopped"
            : "The sketch could not hand its frames to this window, so it opened its own"
    }

    /// 終わりの合図の受け口を置く。
    ///
    /// **印を 0 に書いてから置く。** 置いた後の最初の書き込みがハンドラからだと、
    /// 変数の初期化がハンドラの中で起きうる。
    static func installStopHandlers() {
        // **畳まれた管へ書いても死なないようにする。** 道具は窓が拾った出来事を子へ
        // 書くが、子は保存のたびに入れ替わる — 既定のままだと、入れ替えの隙間に触った
        // だけで**見張りごと消える** ([ADR-0032] 決定 4)
        signal(SIGPIPE, SIG_IGN)
        watchStopRequested = 0
        for number in stopSignals {
            signal(number, { _ in watchStopRequested = 1 })
        }
    }

    /// 1 巡ぶんの判断。**駆動のしかたから切り離してある。**
    ///
    /// 合図を別のキューで受けて `WatchSession` を触る形は採らない — main actor 既定
    /// ([ADR-0010]) の上で隔離を跨ぐことになる。印を見て抜けるだけなら、終わらせる処理は
    /// 巡回と同じところに残る。遅れは間隔 (`interval`) の範囲に収まる。
    ///
    /// [ADR-0010]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0010-concurrency-model.md
    ///
    /// **作り直しの最中でも、抜けるのは即座である。** 作り直しは main actor の外で走る
    /// ようになったので (#834)、ここで終わりを待つと「押したのに終わらない」時間が
    /// ビルドの長さぶん残る — いちばん長いのは冷えた初回で、そこがまさに #834 が直した
    /// 場面である。代わりに**終われと言われたことを ``WatchSession`` へ覚えさせ**、
    /// 走っている作り直しが終わっても子を起こさないようにする。
    ///
    /// - Parameter stopped: 終わりの合図が来たか。検査から差し替える。
    /// - Returns: 続けるなら `true`。**合図を見てからは作り直さない** — 見ないと、
    ///   終われと言われた後に 1 回だけ作り直して子を起こすことになる。
    @discardableResult
    static func step(
        _ session: WatchSession, viewer: Viewer? = nil,
        stopped: () -> Bool = { watchStopRequested != 0 }
    ) async -> Bool {
        if stopped() {
            session.noteStopRequested()
            return false
        }
        // **作り直しの契機より先に見る。** 保存と同時に消えた回では、後に置くと新しい子が
        // 起きて印が下り、消えたことを見逃す。名乗った行は作り直しが始まれば
        // `willRebuild` が上書きする (#1103)
        if let departure = session.departed() {
            // **絵を出さずに消えた世代の後ろで、前の世代を待たせたままにしない。** 入れ替わりの
            // 合図はもう来ないので、ここで畳む (#1142)
            await retire(after: session)
            let line = departedLine(departure)
            say(line)
            viewer?.firstFrame.settle()
            viewer?.preview.report(line, spinning: false)
        }
        // **倒れた子は、乗り換えの合図が来ないので、ここで見つける** (#2350)。作り直した子が共有面を
        // 作れず自分の窓を開いた回は、前の世代が道具の窓に映ったまま並走する
        if let fallen = await session.retireAfterFallback() {
            announce(fallen.outcome)
            let line = fellBackLine(replacing: fallen.replaced)
            say(line)
            viewer?.firstFrame.settle()
            viewer?.preview.report(line, spinning: false)
        }
        if let outcome = await session.tick() {
            // **終われと言われた後に戻ってきた結果は名乗らない** (最初の 1 回と同じ規律)。どう
            // 終えたかは ``finish(_:)`` が名乗る — ここで名乗ると、止めた作り直しを「直して保存
            // し直せ」と案内することになる (#2875 の反証)
            guard !session.stopRequested else { return true }
            report(outcome, holdingPrevious: session.keepsPreviousRunning, on: viewer)
            // **差し替えで期限に掛かったことも名乗る。** 止め方は終わるときと同じ経路を
            // 通るので、保存のたびにも起こりうる (#732)
            switch session.lastStop {
            case .killed: say(killedLine)
            case .abandoned(let pid): say(abandonedLine(pid: pid))
            default: break
            }
        }
        return true
    }

    /// 巡回が持つ印。
    ///
    /// **1 拍を `Task` へ渡すので、手続きの中の `var` では持てない** (送れる値ではない)。
    /// どちらも 1 度きりの出来事を表す — 最初の作り直しを始めたか、抜ける手続きに入ったか。
    @MainActor
    final class LoopState {
        /// 最初の作り直しを始めたか。
        var started = false
        /// 抜ける手続きに入ったか。**合図が立った後も拍は来続ける。**
        var leaving = false
    }

    /// 巡回する。**終わりの合図が来るまで回り、来たら抜ける。**
    ///
    /// 眠って回るのではなく**アプリケーションの巡回に乗る**のは、道具が窓を持つように
    /// なったからである ([ADR-0032] 決定 1)。窓の描き直しも画面の切り替えも AppKit の
    /// 巡回の上で起きるので、そこを止めて眠ると窓が固まる。
    ///
    /// [ADR-0032]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0032-window-ownership.md
    static func watch(_ session: WatchSession, viewer: Viewer? = nil) {
        let application = NSApplication.shared
        // **最初の 1 拍で子を起こす。** 巡回に入る前に起こすと、窓が出るのは初回の
        // 作り直しが終わってからになる
        let state = LoopState()
        // **`.common` へ載せる。** `Timer.scheduledTimer` は `.default` にしか載らず、
        // 窓を掴んで動かしている間や大きさを変えている間は巡回が**止まる** — その間に
        // 保存しても作り直されない
        let timer = loopTimer { _ in
            MainActor.assumeIsolated { () -> Void in
                // **1 拍を `Task` へ渡す。** 作り直しを待つのはこの中で、待っている間
                // main actor は空く — 窓の描き直しも × の問いもそこで捌かれる (#834)。
                // 待っている間に来た拍は `WatchSession` の印が弾く
                Task<Void, Never> {
                    if !state.started {
                        state.started = true
                        let outcome = await session.start()
                        // **終われと言われた後に戻ってきた最初の結果は名乗らない。** どう
                        // 終えたかは抜ける側 (``finish(_:)``) が名乗る — ここでも言うと、
                        // 始めなかった・止めた作り直しを「Build failed」と言うことになる
                        guard !session.stopRequested else { return }
                        report(outcome, holdingPrevious: session.keepsPreviousRunning, on: viewer)
                        return
                    }
                    if await step(session, viewer: viewer) { return }
                    guard !state.leaving else { return }
                    state.leaving = true
                    // **窓を開いたまま、走らせていたものを止める。** 実行ループを抜けてから
                    // 止めると、撮っていた動画を閉じ終えるまで (最大 38 秒) 窓が固まって見える。
                    // 待つあいだ main actor は空く ([#2576](https://github.com/mokume-metal/mokume/issues/2576))
                    await finish(session)
                    leave(application)
                }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        application.run()
        timer.invalidate()
    }

    /// 巡回の拍を刻むタイマー。**最初の拍は巡回に入った直後に来る** ([#1789])。
    ///
    /// `Timer(timeInterval:repeats:block:)` の最初の発火は「作った時刻 + 間隔」で、初回の
    /// 作り直しは最初の拍で始まるので、窓が出てから必ず 1 拍 (0.25 秒) 空で待っていた。
    /// 発火の時刻を今にしておけば、`application.run()` の最初の周回で拍が来る。作り直し
    /// は拍の中から `Task` へ渡すので、巡回はすぐ空く — 窓を先に出す順序は変わらない。
    ///
    /// [#1789]: https://github.com/mokume-metal/mokume/issues/1789
    static func loopTimer(_ tick: @escaping @Sendable (Timer) -> Void) -> Timer {
        Timer(fire: Date(), interval: interval, repeats: true, block: tick)
    }

    /// アプリケーションの巡回を抜けさせる。
    ///
    /// **空のイベントを 1 つ投げる。** `stop(_:)` は次のイベントを処理したときに効くので、
    /// 何も起きていない画面では合図を出しただけでは終わらない。
    private static func leave(_ application: NSApplication) {
        application.stop(nil)
        guard
            let wake = NSEvent.otherEvent(
                with: .applicationDefined, location: .zero, modifierFlags: [], timestamp: 0,
                windowNumber: 0, context: nil, subtype: 0, data1: 0, data2: 0)
        else { return }
        application.postEvent(wake, atStart: true)
    }

    /// 終わる。**走らせていたものを置いていかない。**
    ///
    /// どう止まったかを名乗る — 既に死んでいた・頼んで止まった・期限で落とした の 3 つは
    /// 別の出来事である。とくに 3 つ目は子の側の事情なので、黙って終わると
    /// 「止めた」と見分けが付かない (#732)。
    ///
    /// **待つあいだ main actor を塞がない** ([#2576](https://github.com/mokume-metal/mokume/issues/2576))。
    /// 撮っていた動画を閉じ終えるまで最大 38 秒かかり、窓を閉じるのはこの後なので、塞ぐと
    /// その間は窓が開いたまま止まって見える。**窓を閉じる前に済ませる順序は変えない** —
    /// 呼ぶ側 (巡回を抜けるとき・道具立ての終了) が、窓を開いたままこれを待ってから窓を畳む。
    ///
    /// **2 度呼ばれても、止めて名乗るのは 1 度きり。** 終わりの経路は 2 つあり (巡回を抜けた・
    /// 道具立てが終わらせた)、後から来た呼び手は、先の手続きが済むまで待って戻る。
    static func finish(_ session: WatchSession) async {
        switch session.finishStage {
        case .done: return
        case .running:
            while session.finishStage == .running { try? await Task.sleep(for: .milliseconds(5)) }
            return
        case .idle: session.finishStage = .running
        }
        // **終わりの意味を先に立てる。** 待つあいだ巡回は回り続けるので、立てないと新しい作り直しを
        // 始めて子を起こす (起こしても、止める者がもう居ない — #454)
        session.noteStopRequested()
        // **作り直しを先に止める。** 見張りは作り直しを待たずに終われるので、止めないと
        // `swift build` が残って `.build` の鍵を握り、起こし直した見張りを待たせる (#1147)
        if let line = stoppedRebuildLine(await session.stopRebuilding()) { say(line) }
        say(stoppedWatchingLine(await session.end()))
        session.finishStage = .done
    }

    /// ``finish(_:)`` の、main actor を塞ぐ版。**プロセスが終わる直前の後始末だけが使う。**
    ///
    /// 通常の終わり方は ``finish(_:)`` を窓を開いたまま済ませてから抜けるので、ここへ来るのは
    /// 先に済んでいない場合 (検査が見張りの口だけを通した・想定外の経路) だけである。それでも
    /// 置いていかないために、残っているものを同じ手順で止める。
    static func finishBlocking(_ session: WatchSession) {
        guard session.finishStage != .done else { return }
        session.finishStage = .done
        session.noteStopRequested()
        say(stoppedWatchingLine(session.stopBlocking(timeout: session.finishTimeout)))
    }

    /// 終えたときの、子の止まり方の名乗り。
    static func stoppedWatchingLine(_ outcome: WatchSession.StopOutcome) -> String {
        switch outcome {
        case .notRunning: "Stopped watching"
        case .terminated: "Stopped watching (the running sketch was stopped)"
        case .killed: "Stopped watching (a sketch that would not stop was killed)"
        // **置いていくことを言う。** 黙って終わると「止めた」と見分けが付かず、残ったものが
        // #454 の孤児として次の人に渡る
        case .abandoned(let pid): "Stopped watching — " + abandonedLine(pid: pid)
        }
    }

    /// 作り直しを途中で止めたことを名乗る行。**作り直していなければ `nil`。**
    ///
    /// **スケッチを止めた言葉を使い回さない。** 期限に掛かった回も「スケッチ」と言うと、
    /// 落としたのが何だったかを読み違える (#732 の規律を作り直しにも効かせる)。
    ///
    /// - Parameter outcome: ``WatchSession/stopRebuilding()`` の結果。
    static func stoppedRebuildLine(_ outcome: WatchSession.StopOutcome?) -> String? {
        switch outcome {
        case nil: nil
        case .notRunning, .terminated: WatchSession.stoppedRebuildNotice
        case .killed:
            WatchSession.stoppedRebuildNotice + " (it did not answer SIGINT and was killed)"
        case .abandoned(let pid):
            WatchSession.stoppedRebuildNotice
                + " — but the build outlived being killed (PID \(pid)) and has to be brought down by hand"
        }
    }

    private static func report(
        _ outcome: BuildReport, holdingPrevious: Bool, on viewer: Viewer?
    ) {
        for line in reportLines(outcome, holdingPrevious: holdingPrevious) { say(line) }
        guard let viewer else { return }
        // **起こせた回は、新しい子の 1 枚目が出るまで畳まない** ([#2875])。子の起動と
        // `setup()` の間は長いことがあり (初回はとくに)、ここで畳むと作品の窓もプレビューも
        // 何も言わない時間ができる。畳むのは窓が 1 枚目を出した合図 (``Viewer/firstFrame``)
        //
        // [#2875]: https://github.com/mokume-metal/mokume/issues/2875
        if outcome.ok && outcome.launched {
            viewer.firstFrame.wait()
            viewer.preview.report(startingSketchLine, spinning: true)
            return
        }
        viewer.firstFrame.settle()
        // **回っている印は止める。** 作り直しは終わっているので、回り続ける印は
        // 「まだ待たされている」と読める
        viewer.preview.report(
            notice(for: outcome, holdingPrevious: holdingPrevious), spinning: false)
    }

    /// 1 回の作り直しの結果として端末に出す行。
    ///
    /// **起こさなかった回も理由を出す** ([#2521](https://github.com/mokume-metal/mokume/issues/2521))。
    /// 作り直しが通って子を起こせなかった回 (`ok: true, launched: false`) は、要約が
    /// `Rebuilt, but could not start it` と言うだけで、理由は記録の本文の頭にしか無い —
    /// 通らなかった回だけ本文を出していた頃は、端末には理由が 1 行も出なかった。
    ///
    /// **出すのは理由 (本文の最初の空行まで) だけである。** 作り直しは通っているので、その
    /// 出力 (`[n/m] Compiling…` の行) を端末へ流しても読む人のすることは変わらない。全文は
    /// 記録 (`status.json`) に在る。
    ///
    /// - Parameter holdingPrevious: 前の版が走り続けているか (``WatchSession/keepsPreviousRunning``)。
    ///   起こせなかった回に、そうであるときだけ ``holdingLine`` を名乗る — 窓のある見張りは前の
    ///   世代を残してから起こし、窓の無い見張りは起こす前に止める。**通らなかった回も同じ口で
    ///   分ける** ([#2875](https://github.com/mokume-metal/mokume/issues/2875)) — 最初の 1 回と、
    ///   子が自分で消えた後の回には前の版が居ないので、``holdingLine`` は偽になる。
    static func reportLines(_ outcome: BuildReport, holdingPrevious: Bool) -> [String] {
        var lines = [outcome.summary]
        guard !outcome.output.isEmpty else { return lines }
        if !outcome.ok {
            lines.append(outcome.output)
            lines.append(holdingPrevious ? holdingLine : nothingRunningLine)
        } else if let reason = outcome.notStartedReason {
            lines.append(reason)
            if holdingPrevious { lines.append(holdingLine) }
        }
        return lines
    }

    /// 作り直しが通らなかったとき、走り続けているものを名乗る行。
    static let holdingLine = "still running the version from before, and waiting"
    /// 作り直しが通らなかったとき、走っている版が無いことを名乗る行 (#2875)。**次の一手まで
    /// 言う** — 何も走っていないとだけ言うと、もう一度起こし直す必要があると読める。
    static let nothingRunningLine = "nothing is running yet — fix it and save to rebuild"

    /// 窓を閉じようとした人に問う言葉。
    ///
    /// **窓に出る言葉も、端末に出ている言葉と同じ側で持つ** (#695 が `startingLine` で
    /// 定めた規律)。窓の側 (`SharedFrame*`) は出し方だけを持ち、何と言うかは決めない。
    static let closeMessage = "Stop watching?"
    /// 押した後どうなるか。**両方の窓が畳まれることを言う** — 押した人が閉じようとしたのは
    /// 片方だが、終わるのは見張りごとである。
    static let closeDetail = "The running sketch stops too, and both the work's window and the preview close."
    /// 終わる側の押しどころ。
    static let closeConfirm = "Stop"
    /// 続ける側の押しどころ。**「キャンセル」と言わない** — 押した人が取り消すのは「閉じる」
    /// ことであって、走っているものは続く。
    static let closeCancel = "Keep going"

    /// 差し替えのときに、頼んでも止まらない子を強制終了したと名乗る行。
    ///
    /// **終わるときだけの話ではない。** 止め方は終わるときと同じ経路なので、期限に
    /// 掛かったことは保存のたびにも起こりうる
    /// ([#732](https://github.com/mokume-metal/mokume/issues/732))。
    static let killedLine = "Killed a sketch that would not stop (it does not answer SIGTERM)"

    /// 終えるときに、子が閉じ終えるのを待っていると名乗る行
    /// ([#1219](https://github.com/mokume-metal/mokume/issues/1219))。
    ///
    /// **何を待っているかと、いつまで待つかを言う。** 待っているのは後始末 (撮っていた動画を
    /// 閉じる) で、越えたら強制終了する — 押した人がもう一度押すべきかを読めるように。
    static func finishWaitLine(remaining: TimeInterval) -> String {
        "Waiting for the sketch to finish writing (up to \(Int(remaining.rounded(.up))) more seconds, "
            + "then it is killed)"
    }

    /// 走らせていたスケッチが、誰も頼んでいないのに消えたことを名乗る行。
    ///
    /// **道具が止めた終わり方とは別の言葉にする。** ここに来るのは道具が何もしていない回で、
    /// 起きたことはスケッチの側にしかない — 混ぜると、押した人は「道具が止めたのか」を
    /// 読み取れない ([#1103](https://github.com/mokume-metal/mokume/issues/1103))。
    ///
    /// **終わり方と数字を載せる。** 落ちたのなら端末を遡る先があり、自分から終わったのなら
    /// スケッチの側にそう書いてある — 読む人が次にすることが変わる。
    ///
    /// **次の一手まで言う。** 起こし直しはしないと決めてあるので (#1103)、黙って名乗るだけ
    /// では「もう戻らない」と読める。絵は保存すれば戻る。
    static func departedLine(_ departure: WatchSession.Departure) -> String {
        // **どちらも完全な文で持つ。** 文の途中で語を選ぶ形は、語順の違う言語で
        // 組み替えられなくなる (ADR-0038 決定 3)
        return departure.wasSignalled
            ? "The running sketch crashed (signal \(departure.status)) — the drawing is "
                + "frozen where it stopped. Save and it gets rebuilt and started again"
            : "The running sketch exited on its own (code \(departure.status)) — the drawing "
                + "is frozen where it stopped. Save and it gets rebuilt and started again"
    }

    /// 強制終了しても消えなかったことを名乗る行。
    ///
    /// **番号を出す。** ここまで来ると道具にできることは無いので、落とすのは人である —
    /// 番号は `scripts/orphan-processes.sh` が出すものと同じ (#454)。
    static func abandonedLine(pid: Int32) -> String {
        "A sketch outlived being killed (PID \(pid)) — it has to be brought down by hand"
    }

    /// プレビューへ重ねる 1 行。**端末に出ている言葉だけで組む** — プレビューは端末の
    /// 代わりではないので、ここだけで名乗る事実を作らない。
    ///
    /// - Parameter holdingPrevious: 前の版が走り続けているか (``reportLines(_:holdingPrevious:)``
    ///   と同じ口)。
    /// - Returns: 通って起こせたら `nil` (``startingSketchLine`` は出し手の ``report`` が置く)。通らなかったら**出したままにする行** — 消すと
    ///   「保存したのに絵が変わらない」が「変えた結果が同じだった」と見分けられない。
    ///   **通って起こせなかった回も同じ理由で出す** — 畳むと、窓の側では「保存した → 絵が
    ///   止まっている → 何も出ない」になる ([#2574](https://github.com/mokume-metal/mokume/issues/2574))。
    static func notice(for outcome: BuildReport, holdingPrevious: Bool) -> String? {
        guard outcome.ok else {
            return "The build failed — " + (holdingPrevious ? holdingLine : nothingRunningLine)
        }
        return outcome.notStartedNotice
    }

    /// 道具が出す窓。
    ///
    /// **作品の窓とプレビューは兄弟**で、同じ区画を独立に見る ([ADR-0032] 決定 1)。
    /// 親子にしないのは、作品が窓を持たない日 (Syphon で外へ流すなど) にプレビューだけを
    /// 出せる形にしておくためである。
    ///
    /// [ADR-0032]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0032-window-ownership.md
    struct Viewer {
        /// 作品の窓。**道具の都合を何も載せない。**
        let window: SharedFrameWindow
        /// 制作を助ける窓。状態と印とつまみが載る。
        let preview: SharedFramePreview
        /// 起こした子の 1 枚目を待っているか (#2875)。
        let firstFrame = FirstFrameWait()

        func close() {
            window.close()
            preview.close()
        }
    }

    /// 最初の 1 回を始めるときの行。**いちばん長く待つのはここ**である (冷えた状態では
    /// 依存の解決から走る)。
    static let startingLine = "Building… (the first one takes a while)"

    /// 作り直しが通って子を起こし、その 1 枚目を待つ間にプレビューへ出す行 (#2875)。
    ///
    /// **端末の要約 (`Rebuilt: …`) と同じ事実だけを言う。** 起こしたことは要約の頭が名乗って
    /// おり、ここが足すのは「絵はまだ出ていない」ことで、それは作品の窓を見れば分かる。
    static let startingSketchLine = "Rebuilt — starting the sketch…"

    /// 変化を見つけて作り直すときの行。
    static let rebuildingLine = "Change spotted — rebuilding…"

    /// 見張りが自分の行を書く。
    ///
    /// **端末では、速さの行を消してから書く。** 走らせているスケッチは同じ 1 行を書き換え
    /// 続けているので (`FrameRateNotice`)、消さずに書くと作り直しの記録がその行の**途中から
    /// 続く**形になり読めなくなる ([#685](https://github.com/mokume-metal/mokume/issues/685))。
    static func say(_ text: String, isTerminal: Bool = isatty(STDOUT_FILENO) != 0) {
        print(line(text, isTerminal: isTerminal))
    }

    /// 書く 1 行。
    ///
    /// ライブラリ側にも同じ綴りがあるが、道具からは使えない (外へ出していない)。
    /// 規約は文章で共有し、実装はそれぞれが持つ — 出すべきかどうかは、外から使う人が
    /// 現れてから決める。**同じ扱いだった `AtomicWrite` は、道具の側に使い手が 3 人
    /// 現れた時点で畳んだ** ([#989](https://github.com/mokume-metal/mokume/issues/989))。
    ///
    /// **行ごとに消す** (#2521)。理由のように複数行を 1 度に書くと、先頭の行しか消さない形では
    /// 2 行目以降に速さの行の残りが重なる。
    static func line(_ text: String, isTerminal: Bool) -> String {
        guard isTerminal else { return text }
        return text.split(separator: "\n", omittingEmptySubsequences: false)
            .map { "\r\u{1B}[2K" + $0 }.joined(separator: "\n")
    }
}

/// 起こした子の 1 枚目を待っているか ([#2875](https://github.com/mokume-metal/mokume/issues/2875))。
///
/// **畳むのは、待ちを置いた後にその窓が乗り換えた世代の 1 枚目だけである。** 窓の 1 枚目の合図は
/// 世代の印を持たない (目録も同じ)。最初の世代は絵が来る前に採用されるので、`setup()` の最中に
/// 保存すると、前の子が遅れて出した 1 枚目の合図が、新しい子を待っている間に来る。待ちを置いた後の
/// 乗り換えを窓ごとに見ていれば、それは新しい子の世代である — 子を起こしてから待ちを置くまでの
/// 間に中断点は無く、新しい子の目録がそれより先に採用されることはない。
///
/// 作り直しが始まった後に前の子の合図が遅れて来ても畳まない。畳むと、作り直しの行が消える。
@MainActor
final class FirstFrameWait {
    /// 合図を出す窓。2 つの窓は独立に世代を乗り換える。
    enum Pane: Hashable { case window, preview }

    private(set) var waiting = false
    /// 待ちを置いた後に世代を乗り換えた窓。
    private var promoted: Set<Pane> = []

    /// 子を起こした。1 枚目が出るまで、起こしている行を残す。
    func wait() {
        waiting = true
        promoted = []
    }

    /// 別の行が上書きした (作り直しが始まった・結果を名乗った・子が消えた)。もう待たない。
    func settle() { waiting = false }

    /// 窓が出す世代を乗り換えた。
    func promoted(_ pane: Pane) {
        if waiting { promoted.insert(pane) }
    }

    /// 窓が 1 枚目を出した。**待ちを置いた後にその窓が乗り換えた世代のときだけ `true`** を返し、
    /// 待ちを下ろす。
    func shown(_ pane: Pane) -> Bool {
        guard waiting, promoted.contains(pane) else { return false }
        waiting = false
        return true
    }
}
