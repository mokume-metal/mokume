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
        _ arguments: [String], watching: (WatchSession) -> Void = { watch($0) }
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
        session.willRebuild = { initial in say(initial ? startingLine : rebuildingLine) }

        // **窓を先に出す。** 出せたときだけ区画ができ、子は窓を持たずに走る
        // ([ADR-0032] 決定 1)。子を起こしてからでは間に合わない — 区画は起動の瞬間に
        // しか読まれない
        //
        // [ADR-0032]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0032-window-ownership.md
        let viewer = openViewer(for: session)

        // 子を起こす前に受け口を置く。起こした後だと、その隙間に来た合図で
        // 既定の振る舞い (親だけが即座に終わる) に落ちて子が残る
        installStopHandlers()
        report(session.start())

        watching(session)
        finish(session)
        viewer?.close()
        // **置いていかない。** 区画は「画面の出口は共有面」という合図なので、残すと
        // 次に `run` で走らせたスケッチまで窓を開かなくなる — しかも黙って開かない
        if viewer != nil { try? FileManager.default.removeItem(at: viewportFacet(for: session)) }
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
    static func openViewer(for session: WatchSession) -> SharedFrameWindow? {
        NSApplication.shared.setActivationPolicy(.regular)
        let facet = viewportFacet(for: session)
        // **前の見張りが残したものを引き継がない。** 置かれている番号は死んだ面を指す
        try? FileManager.default.removeItem(at: facet)
        guard let gpu = try? RenderDevice(),
            let window = try? SharedFrameWindow(
                gpu: gpu, facet: facet, title: session.directory.lastPathComponent),
            (try? FileManager.default.createDirectory(
                at: facet, withIntermediateDirectories: true)) != nil
        else {
            say("窓は出せないので、スケッチに自分の窓を開かせる")
            return nil
        }
        window.open()
        return window
    }

    /// 絵を渡す区画の場所。**見張っているスケッチの側の基準へ置く** — 道具自身の作業
    /// ディレクトリへ置くと、子と別の区画を見ることになる (#331)。
    static func viewportFacet(for session: WatchSession) -> URL {
        WorkDirectory.facet(StartupReads.viewport.key, under: session.facetBase)
    }

    /// 終わりの合図の受け口を置く。
    ///
    /// **印を 0 に書いてから置く。** 置いた後の最初の書き込みがハンドラからだと、
    /// 変数の初期化がハンドラの中で起きうる。
    static func installStopHandlers() {
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
    static func step(_ session: WatchSession, stopped: () -> Bool = { watchStopRequested != 0 })
        -> Bool
    {
        if stopped() { return false }
        if let outcome = session.tick() { report(outcome) }
        return true
    }

    /// 巡回する。**終わりの合図が来るまで回り、来たら抜ける。**
    ///
    /// 眠って回るのではなく**アプリケーションの巡回に乗る**のは、道具が窓を持つように
    /// なったからである ([ADR-0032] 決定 1)。窓の描き直しも画面の切り替えも AppKit の
    /// 巡回の上で起きるので、そこを止めて眠ると窓が固まる。
    ///
    /// [ADR-0032]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0032-window-ownership.md
    static func watch(_ session: WatchSession) {
        let application = NSApplication.shared
        // **`.common` へ載せる。** `Timer.scheduledTimer` は `.default` にしか載らず、
        // 窓を掴んで動かしている間や大きさを変えている間は巡回が**止まる** — その間に
        // 保存しても作り直されない
        let timer = Timer(timeInterval: interval, repeats: true) { _ in
            MainActor.assumeIsolated {
                if !step(session) { leave(application) }
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

    private static func report(_ outcome: BuildReport) {
        say(outcome.summary)
        if !outcome.ok, !outcome.output.isEmpty {
            say(outcome.output)
            say("直前の版を走らせたまま待っている")
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
