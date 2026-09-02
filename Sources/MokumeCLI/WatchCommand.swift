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

        // 区画は環境変数が決める。走らせるスケッチは親の環境を引き継ぐので、記録を
        // パッケージの場所へ置くと観測とだけ場所が割れる (#331)
        let session = WatchSession(
            directory: directory, facetBase: WorkDirectory.given ?? directory,
            configuration: invocation.configuration, reportsRate: true)
        say("見張っている: \(directory.path)")
        // どの道具で見張っているかを名乗る。**いちばん長く見ている画面に無いと、手元
        // ビルドと配布版の取り違えに気付けない** (#633 が実際にそうなった・#684)
        say("道具: \(ToolVersion.describe())")
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
        watching(session, viewer)
        finish(session)
        viewer?.close()
        // **置いていかない。** 区画は「画面の出口は共有面」という合図なので、残すと
        // 次に `run` で走らせたスケッチまで窓を開かなくなる — しかも黙って開かない
        if viewer != nil { try? FileManager.default.removeItem(at: viewportFacet(for: session)) }
        if viewer?.createdParams == true {
            try? FileManager.default.removeItem(at: paramsFacet(for: session))
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
        // **つまみの区画は、無ければこちらで作る。** 走らせている子は区画が在るときだけ
        // 宣言を差し出すので ([ADR-0030] 決定 2)、作らないとプレビューに並べるものが
        // 何も来ない。**元から在ったものは畳まない** — 外から動かすために人が置いた
        // 区画かもしれない
        let params = paramsFacet(for: session)
        let paramsWasThere = FileManager.default.fileExists(atPath: params.path)
        try? FileManager.default.createDirectory(at: params, withIntermediateDirectories: true)

        let name = session.directory.lastPathComponent
        guard let gpu = try? RenderDevice(),
            let window = try? SharedFrameWindow(gpu: gpu, facet: facet, title: name),
            let preview = try? SharedFramePreview(
                gpu: gpu, facet: facet, params: params, title: "\(name) — プレビュー"),
            (try? FileManager.default.createDirectory(
                at: facet, withIntermediateDirectories: true)) != nil
        else {
            say("窓は出せないので、スケッチに自分の窓を開かせる")
            return nil
        }
        // **どちらの窓で触っても、同じ作品へ届く。** 送る前にキャンバスの座標へ写して
        // あるので、窓の大きさの違いはそこで吸収されている — 指は 1 本しかないので、
        // 2 つの窓が「いまの値」を同時に持つことにはならない ([ADR-0032] 決定 4)
        window.onInput = { [weak session] in session?.send($0) }
        preview.onInput = { [weak session] in session?.send($0) }
        // **プレビューを先に出す。** 後に出すと作品の窓の上に重なるので、本番へ送る
        // ほうを掴み直す手間がいちばん最初に生まれる
        preview.open()
        window.open()
        return Viewer(window: window, preview: preview, createdParams: !paramsWasThere)
    }

    /// 絵を渡す区画の場所。**見張っているスケッチの側の基準へ置く** — 道具自身の作業
    /// ディレクトリへ置くと、子と別の区画を見ることになる (#331)。
    static func viewportFacet(for session: WatchSession) -> URL {
        WorkDirectory.facet(StartupReads.viewport.key, under: session.facetBase)
    }

    /// つまみの区画の場所。**絵を渡す区画と同じ基準へ置く** — 走らせている子が書く先と
    /// 揃っていないと、宣言が 1 つも見えない (#331)。
    static func paramsFacet(for session: WatchSession) -> URL {
        WorkDirectory.facet(StartupReads.params.key, under: session.facetBase)
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
    /// - Parameter stopped: 終わりの合図が来たか。検査から差し替える。
    /// - Returns: 続けるなら `true`。**合図を見てからは作り直さない** — 見ないと、
    ///   終われと言われた後に 1 回だけ作り直して子を起こすことになる。
    @discardableResult
    static func step(
        _ session: WatchSession, viewer: Viewer? = nil,
        stopped: () -> Bool = { watchStopRequested != 0 }
    ) -> Bool {
        if stopped() { return false }
        if let outcome = session.tick() { report(outcome, on: viewer) }
        return true
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
        var started = false
        // **`.common` へ載せる。** `Timer.scheduledTimer` は `.default` にしか載らず、
        // 窓を掴んで動かしている間や大きさを変えている間は巡回が**止まる** — その間に
        // 保存しても作り直されない
        let timer = Timer(timeInterval: interval, repeats: true) { _ in
            MainActor.assumeIsolated {
                if !started {
                    started = true
                    report(session.start(), on: viewer)
                    return
                }
                if !step(session, viewer: viewer) { leave(application) }
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
    /// 止めたかどうかを名乗る — 子が既に死んでいた場合と、止めた場合は別の出来事である。
    static func finish(_ session: WatchSession) {
        say(session.stop() ? "見張りを終える (走らせていたスケッチを止めた)" : "見張りを終える")
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
    static let holdingLine = "直前の版を走らせたまま待っている"

    /// プレビューへ重ねる 1 行。**端末に出ている言葉だけで組む** — プレビューは端末の
    /// 代わりではないので、ここだけで名乗る事実を作らない。
    ///
    /// - Returns: 通ったら `nil` (畳む)。通らなかったら**出したままにする行** — 消すと
    ///   「保存したのに絵が変わらない」が「変えた結果が同じだった」と見分けられない。
    static func notice(for outcome: BuildReport) -> String? {
        outcome.ok ? nil : "作り直しに失敗 — " + holdingLine
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
        /// つまみの区画をこちらで作ったか。**作ったものだけ畳む。**
        let createdParams: Bool

        func close() {
            window.close()
            preview.close()
        }
    }

    /// 最初の 1 回を始めるときの行。**いちばん長く待つのはここ**である (冷えた状態では
    /// 依存の解決から走る)。
    static let startingLine = "作っている… (初めの 1 回は時間がかかる)"

    /// 変化を見つけて作り直すときの行。
    static let rebuildingLine = "変更を見つけた — 作り直している…"

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
    /// 現れてから決める (`AtomicWrite` と同じ扱い)。
    static func line(_ text: String, isTerminal: Bool) -> String {
        isTerminal ? "\r\u{1B}[2K" + text : text
    }
}
