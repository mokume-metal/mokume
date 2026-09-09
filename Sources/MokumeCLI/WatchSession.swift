// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation
import mokume

/// 保存したら作り直して差し替える、その中身。
///
/// ループとシグナルの扱いは ``WatchCommand`` に置き、ここは判断だけを持つ —
/// 作り直しとプロセスの起動は差し替えられるようにしてあるので、検査は実際に
/// ビルドを走らせずに「何をどの順で決めるか」を確かめられる。
///
/// ## 所要時間を分けて測る
///
/// **合計だけを見ていると律速を推測で決めて外す。** 保存から気付くまで / 作り直し /
/// 差し替え の 3 つに分けて刻み、どの構成で測ったかも併せて出す。
@MainActor
final class WatchSession {
    /// 差し替えられる外側。
    struct Hooks {
        /// 作り直して、走らせるものの場所まで決める。
        ///
        /// **作り直しと解決を 1 本にしてある。** 別々の口にしていたときは、`live` が
        /// 一方にだけ構成や置き場を渡す形が書けてしまい、**名乗ったものと実際に起動する
        /// ものが食い違った** (#680 が構成で踏んだ形)。抱き合わせれば、その組み合わせを
        /// 書けなくできる。
        var rebuild: (URL) -> RunCommand.Rebuilt
        /// 走らせる。世代の刻印と、速さの名乗り (一緒に出す構成の名前) を渡す。
        var launch: (URL, URL, String?, String?) -> Process?
        /// いまの時刻 (秒)。
        var now: () -> Double
        /// 監視しているソースの世代。
        var stamp: (URL) -> String?

        /// - Parameter context: 1 度だけ決めた土台 (構成と置き場と product)。**作り直しと
        ///   実行ファイルの解決の両方が同じ値から出る** — 片方だけに渡すと、名乗った構成と
        ///   実際に起動するものが食い違う (#680)。
        static func live(context: BuildContext) -> Hooks {
            Hooks(
                rebuild: { directory in
                    // **起動できなかったことを、作り直しの失敗と同じ顔にする。**
                    // 道具立てを起こせないときは終了コードを 1 に倒す
                    (try? RunCommand.rebuild(in: directory, context: context, capturing: true))
                        ?? RunCommand.Rebuilt(
                            status: 1, output: "", executable: nil,
                            binPath: context.directory(under: directory))
                },
                launch: { executable, directory, stamp, rate in
                    let process = Process()
                    process.executableURL = executable
                    process.currentDirectoryURL = directory
                    // **管を 1 本引く。** 道具の窓が拾った出来事はここを通って子へ渡る
                    // ([ADR-0032] 決定 4)。継がずに親の標準入力を渡すと、書き込む先が
                    // 端末になってしまう
                    process.standardInput = Pipe()
                    // 観測は刻印を応答へそのまま載せる。読み手は刻印の変化で「保存した
                    // 内容が反映されたか」を待ち時間ではなく判定できる。組み立ては
                    // RunCommand が持つ — 子へ渡す環境の作り方を 2 通りにしない
                    process.environment = RunCommand.childEnvironment(
                        stamp: stamp, reportingRate: rate)
                    return (try? process.run()) == nil ? nil : process
                },
                now: { Date().timeIntervalSince1970 },
                stamp: { SourceStamp.current(for: $0) })
        }
    }

    /// 子を止めた結果。
    enum StopOutcome: Equatable {
        /// 居なかった (まだ起こしていない・既に死んでいた)。
        case notRunning
        /// 頼んだら止まった。
        case terminated
        /// 頼んでも止まらないので、期限で強制的に落とした。
        case killed
        /// **強制終了しても消えなかった。** 置いていくしかない。
        ///
        /// `SIGKILL` は捕まえられないが、割り込めない待ち (GPU の中で固まった子など) に
        /// 入っているものは即座には消えない。**ここを `killed` と名乗ると「置いていかない」
        /// が黙って破れる**ので、別の結果として持つ (#732)。
        ///
        /// 番号を載せるのは、**残ったものを人が落とせるようにする**ためである
        /// (`scripts/orphan-processes.sh` が出すものと同じ数字)。
        case abandoned(pid: Int32)
    }

    /// 子が、道具の知らないところで消えたこと。
    ///
    /// **道具が止めた終わり方 (``StopOutcome``) とは別の出来事である。** あちらは道具が
    /// 起こした結果を名乗るもので、こちらは**誰も頼んでいないのに居なくなった**ことを言う。
    struct Departure: Equatable {
        /// 終了コード。合図で落ちたときは合図の番号。
        var status: Int32
        /// 落ちたのか (`true`)、自分から終わったのか (`false`)。
        ///
        /// **読む人が次にすることが変わる。** 落ちたのなら端末を遡る先があり、自分から
        /// 終わったのならスケッチの側にそう書いてある。
        var wasSignalled: Bool
    }

    /// 止まるのを待つ上限 (秒)。
    ///
    /// **3 秒という値に意味があるのではなく、桁が離れていることに意味がある** — 素直に
    /// 終わるスケッチは数ミリ秒で消え、応えないものは永久に消えない。人が「固まった」と
    /// 感じる前に決着する側へ寄せる。
    static let defaultStopTimeout: TimeInterval = 3

    /// 強制終了した後に、消えるのを待つ上限 (秒)。
    ///
    /// **短く取る。** `SIGKILL` は届けば即座に効くので、ここで長く待って得るものが無い —
    /// この待ちは差し替えのたびにも払うので、最悪値をそのぶん押し上げる。
    static let killGrace: TimeInterval = 0.5

    /// スケッチのパッケージの場所。ビルドと世代の判定はここで行う。
    let directory: URL
    /// 区画の基準。**パッケージの場所とは別の軸** — スケッチは `MOKUME_WORK_DIR` に従って
    /// 観測を書くので、作り直しの記録も同じ側へ置かないと読み手から見て割れる (#331)。
    let facetBase: URL
    /// 1 度だけ決めた土台 (構成と置き場と product)。
    ///
    /// **構成だけを持っていた頃は、置き場を足したときに片方だけ渡す形が書けた。**
    /// 抱き合わせた値で持てば、作り直しと解決が必ず同じものから出る。
    let context: BuildContext
    /// 名乗るときの構成の名前。選ばれていなければ既定の名前。
    var configurationName: String { context.configurationName }
    private var hooks: Hooks

    /// いま走らせている子。
    ///
    /// **入れ替わったら、消えたことの名乗りは畳む。** 止めるのも差し替えるのもここを通る
    /// ので、印を下ろす場所はこの 1 つで足りる (``departed()``)。
    private(set) var child: Process? {
        didSet { hasNamedDeparture = false }
    }

    /// 消えたことを既に名乗ったか。**子が入れ替わると下りる。**
    private var hasNamedDeparture = false
    /// 止まるのを待つ上限 (秒)。**検査から縮める** — 既定で待つと、期限を確かめる検査が
    /// そのぶん遅くなる。
    let stopTimeout: TimeInterval
    /// 直前に子を止めたときの結果。**差し替えのときも入る。**
    ///
    /// 名乗るのは口の側である — このクラスは判断だけを持ち、出力を持たない。期限に
    /// 掛かったことは保存のたびにも起こりうるので、終わるときだけ見ても足りない (#732)。
    private(set) var lastStop: StopOutcome?
    /// 最後に作り直したときのソースの世代。
    private(set) var lastStamp: String?
    /// 直近の作り直しの結果。
    private(set) var lastReport: BuildReport?
    /// 変化に気付いた時刻。作り直しの直前に消す。
    private var noticedAt: Double?

    /// 速さを名乗らせるか。**既定は名乗らせない** — 人が見ている前でだけ足す付け足しで、
    /// 機械が読む経路 (窓口) の出力は 1 バイトも変えない ([ADR-0029] 決定 5 の 2 番目)。
    let reportsRate: Bool

    /// 作り直しを**始めるとき**に呼ばれる。`initial` は最初の 1 回か。
    ///
    /// **知らせるだけで、判断も出力もここではしない。** 何を言うかは口の側が決める。
    ///
    /// なぜ要るか: 作り直しは終わってからしか名乗らないので、その間**画面が 1 文字も
    /// 動かない**。使う側からは「見張れていない」と「作り直している」の区別が付かず、
    /// 実際にそう読まれた ([#695](https://github.com/mokume-metal/mokume/issues/695))。
    var willRebuild: (_ initial: Bool) -> Void = { _ in }

    /// - Parameter hooks: 差し替える外側。**渡さなければ、決めてある土台から組む** —
    ///   既定引数では作れない (土台が決まるのは初期化の中である)。
    init(
        directory: URL, context: BuildContext, facetBase: URL? = nil,
        reportsRate: Bool = false, hooks: Hooks? = nil,
        stopTimeout: TimeInterval = WatchSession.defaultStopTimeout
    ) {
        self.directory = directory
        self.facetBase = facetBase ?? directory
        self.context = context
        self.reportsRate = reportsRate
        self.hooks = hooks ?? .live(context: context)
        self.stopTimeout = stopTimeout
    }

    /// 1 巡する。変化が無ければ何もしない。
    @discardableResult
    func tick() -> BuildReport? {
        let stamp = hooks.stamp(directory)
        guard stamp != lastStamp else { return nil }
        if noticedAt == nil { noticedAt = hooks.now() }
        return rebuildAndReplace(stamp: stamp)
    }

    /// 最初の 1 回。変化を待たずに作って走らせる。
    @discardableResult
    func start() -> BuildReport {
        rebuildAndReplace(stamp: hooks.stamp(directory), initial: true)
    }

    /// 走らせている子へ 1 行渡す。
    ///
    /// **書けなくても何も起きない。** 見張りは子を頻繁に入れ替えるので、既に居ない相手へ
    /// 書くことは必ず起きる。溜めて後から流す形は採らない — 入力は古くなると意味が
    /// 変わる (どこを指していたかは、いまの絵に対してしか意味が無い)。
    ///
    /// 呼ぶ側は既定で `SIGPIPE` を無視しておく必要がある ([WatchCommand] が置く) —
    /// 無視しないと、畳まれた管へ書いた**こちらが死ぬ**。
    func send(_ line: String) {
        guard let pipe = child?.standardInput as? Pipe, let data = line.data(using: .utf8) else {
            return
        }
        // **失敗を握り潰す。** 相手が畳んだ (EPIPE)・管が一杯 (EAGAIN) のどちらでも、
        // することは同じ「この 1 件を捨てる」である
        try? pipe.fileHandleForWriting.write(contentsOf: data)
    }

    /// 子が、道具の知らないところで消えていたら 1 度だけ返す。
    ///
    /// **見張りは子の生死を見ていなかった。** 見ていたのは世代の刻印だけなので、走らせて
    /// いるスケッチが自分で終わっても落ちても、道具は何も言わずに回り続ける — 窓は道具の
    /// ものなので画面には残り、止まった絵のまま次の保存を待つ
    /// ([#1103](https://github.com/mokume-metal/mokume/issues/1103))。
    ///
    /// **道具が自分で止めた回は返らない。** 終わるときも保存による差し替えも ``stop()``
    /// を通り、そこは必ず ``child`` を `nil` にする。だから**「子は居るのに走っていない」
    /// だけが、誰も頼んでいない消え方**である。
    ///
    /// **1 度きりなのは、巡回が 0.25 秒ごとに回るからである。** 消えた状態はそのまま続く
    /// ので、印を持たないと同じ 1 行を毎秒 4 回出し続ける。印は子が入れ替われば下りる。
    ///
    /// 名乗るのは口の側である — このクラスは判断だけを持ち、出力を持たない。
    func departed() -> Departure? {
        guard let gone = child, !gone.isRunning, !hasNamedDeparture else { return nil }
        hasNamedDeparture = true
        return Departure(
            status: gone.terminationStatus, wasSignalled: gone.terminationReason == .uncaughtSignal)
    }

    /// 走らせているものを終わらせる。
    ///
    /// **期限を持つ。** 頼んで止まらなければ強制的に落とす — 子は人が書いたスケッチなので、
    /// `SIGTERM` を捕まえて戻らない形はいつでも作れる。期限が無いと**終われないだけでなく、
    /// 保存のたびに固まる**: 差し替えもこの経路を通るからである
    /// ([#732](https://github.com/mokume-metal/mokume/issues/732))。
    ///
    /// - Returns: 3 通りの結果。呼ぶ側はそれぞれを別の出来事として名乗れる。
    @discardableResult
    func stop() -> StopOutcome {
        guard let running = child, running.isRunning else {
            child = nil
            lastStop = .notRunning
            return .notRunning
        }
        running.terminate()
        if waitForExit(running, timeout: stopTimeout) {
            child = nil
            lastStop = .terminated
            return .terminated
        }
        // **宛先を確かめてから撃つ。** 起動していない `Process` の番号は 0 で、
        // `kill(0, …)` は**自分のプロセスグループごと**落とす。上の guard が弾いている
        // 形だが、暗黙に頼らない
        let pid = running.processIdentifier
        if pid > 0, running.isRunning { kill(pid, SIGKILL) }
        // **消えたことを確かめる。** 捕まえられない合図でも、割り込めない待ちに入って
        // いるものは即座には消えない — 確かめずに名乗ると、置いていったものを
        // 「止めた」と言うことになる (#732)
        let gone = waitForExit(running, timeout: Self.killGrace)
        child = nil
        let outcome: StopOutcome = gone ? .killed : .abandoned(pid: pid)
        lastStop = outcome
        return outcome
    }

    /// 終わるのを、期限まで待つ。
    ///
    /// **時計は ``Hooks`` に載せない。** 差し替えられた時計で測ると、期限が永久に来ないか
    /// 即座に来るかのどちらかになる (検査の時計は 0 を返す) — ここで見ているのは
    /// 「実際にどれだけ待ったか」であって、記録に載る所要時間ではない。
    ///
    /// - Parameter timeout: 待つ上限 (秒)。
    /// - Returns: 期限までに終わったか。
    private func waitForExit(_ child: Process, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while child.isRunning {
            if Date() >= deadline { return false }
            // **細かく刻む。** 差し替えのときもここを通るので、粗いと保存の反映が
            // そのぶん遅れて見える
            Thread.sleep(forTimeInterval: 0.005)
        }
        return true
    }

    private func rebuildAndReplace(stamp: String?, initial: Bool = false) -> BuildReport {
        let detectMs = noticedAt.map { (hooks.now() - $0) * 1000 }
        noticedAt = nil
        // **前の巡回の止め方を持ち越さない。** 作り直しが通らなければこの回は子を止めない
        // ので、消さずにおくと**何も止めていない回に**「強制終了した」と名乗ることになる
        lastStop = nil

        // **始めることを、始める前に言う。** 作り直しはこの流れを塞ぐので、後から言うと
        // 待っている間が無言になる (#695)
        willRebuild(initial)

        let buildStarted = hooks.now()
        let rebuilt = hooks.rebuild(directory)
        let buildMs = (hooks.now() - buildStarted) * 1000
        // 壊れたままのソースで作り直しを繰り返さない。直したら世代が変わるので、
        // そのとき次の作り直しが走る
        lastStamp = stamp

        // **通ったことと、走らせるものが在ることは別である。** 置き場を他の誰かと
        // 共有していると、作り直しが「通った」のに実行ファイルが建っていないことが
        // 起きる (#1055)。そこを成功として記録すると、症状は「作り直したと出たのに
        // 絵が止まっている」になり、**記録のどこにも理由が出ない** (#1066)
        guard rebuilt.status == 0, let executable = rebuilt.executable else {
            // **走っているものは落とさない。** 直前の版が動き続けるのが、
            // 作り直しが失敗したときに最も助かる振る舞いである
            return finish(
                BuildReport(
                    ok: false, status: rebuilt.status,
                    output: unbuiltNotice(rebuilt) ?? rebuilt.output, stamp: stamp,
                    configuration: configurationName, launched: false,
                    timings: .init(detectMs: detectMs, buildMs: buildMs, relaunchMs: nil)))
        }

        let relaunchStarted = hooks.now()
        stop()
        child = hooks.launch(executable, directory, stamp, reportsRate ? configurationName : nil)
        let relaunchMs = (hooks.now() - relaunchStarted) * 1000

        return finish(
            BuildReport(
                ok: true, status: 0, output: rebuilt.output, stamp: stamp,
                configuration: configurationName, launched: child != nil,
                timings: .init(detectMs: detectMs, buildMs: buildMs, relaunchMs: relaunchMs)))
    }

    /// 「通ったのに建っていない」ことを、記録の中で名乗る。
    ///
    /// **終了コードだけでは区別が付かない。** 作り直しが 0 で終わったのに実行ファイルが
    /// 無い回は、出力に `Build complete!` としか書かれていない — 読み手 (切り分けの口と
    /// 窓口) がそれを見ても、何が起きたのか分からない。
    private func unbuiltNotice(_ rebuilt: RunCommand.Rebuilt) -> String? {
        guard rebuilt.status == 0, rebuilt.executable == nil else { return nil }
        guard let product = context.product else {
            return """
                作り直しは通ったが、走らせるものを決められない: \(directory.path)
                Package.swift の products に実行ファイルが宣言されているか確かめる

                \(rebuilt.output)
                """
        }
        return """
            The build succeeded, but \(product) was never built: \(rebuilt.binPath.path)
            置き場に残っている古い計画が原因のことがある — その置き場を消してやり直す

            \(rebuilt.output)
            """
    }

    private func finish(_ report: BuildReport) -> BuildReport {
        lastReport = report
        write(report)
        return report
    }

    /// 結果を区画へ置く。観測と同じ流儀 (原子的に書く)。
    private func write(_ report: BuildReport) {
        AtomicFile.publishJSON(report, to: BuildReport.statusURL(under: facetBase), "the build record")
    }
}
