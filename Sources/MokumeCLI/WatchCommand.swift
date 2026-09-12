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
    /// **捕まえられるものだけを捕まえる。** 強制終了 (SIGKILL) と、親ごと消える終わり方は
    /// 受け取れないので、そこは直したふりをしない ([#681](https://github.com/mokume-metal/mokume/issues/681))。
    static let stopSignals: [Int32] = [SIGINT, SIGTERM, SIGHUP]

    /// - Parameter watching: 巡回のしかた。**検査から差し替える** — 既定は合図が来るまで
    ///   回り続けるので、始める前に止まることを確かめる検査がここで固まらないようにする。
    static func run(
        _ arguments: [String],
        watching: (WatchSession, Viewer?) -> Void = { watch($0, viewer: $1) }
    ) throws(CommandFailure) {
        let invocation = try Invocation.parse(arguments)
        let directory = invocation.directory
        guard FileManager.default.fileExists(
            atPath: directory.appendingPathComponent("Package.swift").path)
        else {
            throw .packageNotFound(path: directory.path)
        }

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
        let context = try RunCommand.context(in: directory, invocation: invocation)

        // 区画は環境変数が決める。走らせるスケッチは親の環境を引き継ぐので、記録を
        // パッケージの場所へ置くと観測とだけ場所が割れる (#331)。**計算は 1 つ** (#791)
        let session = WatchSession(
            directory: directory, context: context, facetBase: invocation.facetBase(),
            reportsRate: true)
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
            viewer?.preview.report(line, spinning: true)
        }

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
        let delegate = ApplicationDelegate { teardown(session, viewer, created: prepared) }
        NSApplication.shared.delegate = delegate

        watching(session, viewer)
        teardown(session, viewer, created: prepared)
    }

    /// 窓口が使う区画を、子を起こす前に置く。**窓も GPU も要さない。**
    ///
    /// 区画が在るかどうかを見るのは起動の瞬間だけなので、誰も置かないと窓口の道具は
    /// 初めて呼んだ回に必ず空振りし、道具ごとに 1 回ずつ起動し直すことになる ([#464])。
    /// 置くのは要求を置く側 (`Facets.exchange`) だが、それでは間に合わない。
    ///
    /// **`viewport` は入れない。** あれは在ると窓を開かず共有面へ差し出す区画なので、
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
        finish(session)
        viewer?.close()
        // **置いていかない。** 区画は「画面の出口は共有面」という合図なので、残すと
        // 次に `run` で走らせたスケッチまで窓を開かなくなる — しかも黙って開かない
        if viewer != nil { try? FileManager.default.removeItem(at: viewportFacet(for: session)) }
        for facet in created { try? FileManager.default.removeItem(at: facet) }
    }

    /// 後始末を済ませたか。**印は 1 プロセスに 1 つ** (終わりの合図と同じ扱い)。
    static var teardownDone = false

    /// 道具立ての終わり方を受ける。
    ///
    /// **窓を閉じる経路を通らない終わり方がある。** `NSApplication` を終わらせる経路
    /// (Dock の「終了」・ログアウト・システム終了) は `windowShouldClose` を問わず、
    /// `run()` からも戻らない — 後始末はここでしか通れない。
    final class ApplicationDelegate: NSObject, NSApplicationDelegate {
        private let teardown: () -> Void

        init(teardown: @escaping () -> Void) {
            self.teardown = teardown
            super.init()
        }

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
        window.onGenerationPromoted = { [weak session] in retire(after: session) }
        preview.onGenerationPromoted = { [weak session] in retire(after: session) }
        let viewer = Viewer(window: window, preview: preview)
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
    /// **綴りはここ 1 つ。** 置くのは見張りだが、`run` も「区画が残っていないか」を同じ
    /// 場所へ見に行く — 別々に組むと、片方だけが基準を取り違えても誰も気付けない
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

    /// 入れ替わった後ろの世代を畳み、期限に掛かったことがあれば名乗る。
    ///
    /// **名乗るのは口の側である** — ``WatchSession`` は判断だけを持ち、出力を持たない
    /// (#732 が終わり方について定めた分担を、差し替えの側でもそのまま使う)。
    static func retire(after session: WatchSession?) {
        guard let outcome = session?.retireOutgoing() else { return }
        switch outcome {
        case .killed: say(killedLine)
        case .abandoned(let pid): say(abandonedLine(pid: pid))
        default: break
        }
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
            retire(after: session)
            let line = departedLine(departure)
            say(line)
            viewer?.preview.report(line, spinning: false)
        }
        if let outcome = await session.tick() {
            report(outcome, on: viewer)
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
        let timer = Timer(timeInterval: interval, repeats: true) { _ in
            MainActor.assumeIsolated { () -> Void in
                // **1 拍を `Task` へ渡す。** 作り直しを待つのはこの中で、待っている間
                // main actor は空く — 窓の描き直しも × の問いもそこで捌かれる (#834)。
                // 待っている間に来た拍は `WatchSession` の印が弾く
                Task<Void, Never> {
                    if !state.started {
                        state.started = true
                        report(await session.start(), on: viewer)
                        return
                    }
                    if await step(session, viewer: viewer) { return }
                    guard !state.leaving else { return }
                    state.leaving = true
                    leave(application)
                }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        application.run()
        timer.invalidate()
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
    static func finish(_ session: WatchSession) {
        switch session.stop() {
        case .notRunning: say("Stopped watching")
        case .terminated: say("Stopped watching (the running sketch was stopped)")
        case .killed: say("Stopped watching (a sketch that would not stop was killed)")
        // **置いていくことを言う。** 黙って終わると「止めた」と見分けが付かず、残ったものが
        // #454 の孤児として次の人に渡る
        case .abandoned(let pid): say("Stopped watching — " + abandonedLine(pid: pid))
        }
    }

    private static func report(_ outcome: BuildReport, on viewer: Viewer?) {
        say(outcome.summary)
        if !outcome.ok, !outcome.output.isEmpty {
            say(outcome.output)
            say(holdingLine)
        }
        // **回っている印は止める。** 作り直しは終わっているので、回り続ける印は
        // 「まだ待たされている」と読める
        viewer?.preview.report(notice(for: outcome), spinning: false)
    }

    /// 作り直しが通らなかったとき、走り続けているものを名乗る行。
    static let holdingLine = "still running the version from before, and waiting"

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
    /// - Returns: 通ったら `nil` (畳む)。通らなかったら**出したままにする行** — 消すと
    ///   「保存したのに絵が変わらない」が「変えた結果が同じだった」と見分けられない。
    static func notice(for outcome: BuildReport) -> String? {
        outcome.ok ? nil : "The build failed — " + holdingLine
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

        func close() {
            window.close()
            preview.close()
        }
    }

    /// 最初の 1 回を始めるときの行。**いちばん長く待つのはここ**である (冷えた状態では
    /// 依存の解決から走る)。
    static let startingLine = "Building… (the first one takes a while)"

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
    static func line(_ text: String, isTerminal: Bool) -> String {
        isTerminal ? "\r\u{1B}[2K" + text : text
    }
}
