// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation

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
        /// 作り直す。
        var build: (URL) -> (status: Int32, output: String)
        /// 走らせるものの場所を決める。
        var resolveExecutable: (URL) -> URL?
        /// 走らせる。世代の刻印と、速さの名乗り (一緒に出す構成の名前) を渡す。
        var launch: (URL, URL, String?, String?) -> Process?
        /// いまの時刻 (秒)。
        var now: () -> Double
        /// 監視しているソースの世代。
        var stamp: (URL) -> String?

        /// - Parameter configuration: 走らせる構成。**作り直しと実行ファイルの解決の両方へ
        ///   渡す** — 片方だけに渡すと、名乗った構成と実際に起動するものが食い違う (#680)。
        static func live(configuration: String? = nil) -> Hooks {
            Hooks(
                build: { directory in
                    let result = try? RunCommand.swift(
                        ["build"] + RunCommand.configurationArguments(configuration),
                        in: directory, capturing: true)
                    return (result?.status ?? 1, result?.output ?? "")
                },
                resolveExecutable: { directory in
                    try? RunCommand.executablePath(in: directory, configuration: configuration)
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
    /// 選ばれた構成。**渡されなければ道具立ての既定に任せる** — ここで既定の名前を
    /// 書き固めると、道具立てが既定を変えた日に黙ってずれる。
    let configuration: String?
    /// 名乗るときの構成の名前。選ばれていなければ既定の名前。
    var configurationName: String { configuration ?? RunCommand.defaultConfigurationName }
    private var hooks: Hooks

    /// いま走らせている子。
    private(set) var child: Process?
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

    /// - Parameter hooks: 差し替える外側。**渡さなければ、選ばれた構成から組む** —
    ///   既定引数では作れない (構成が決まるのは初期化の中である)。
    init(
        directory: URL, facetBase: URL? = nil, configuration: String? = nil,
        reportsRate: Bool = false, hooks: Hooks? = nil,
        stopTimeout: TimeInterval = WatchSession.defaultStopTimeout
    ) {
        self.directory = directory
        self.facetBase = facetBase ?? directory
        self.configuration = configuration
        self.reportsRate = reportsRate
        self.hooks = hooks ?? .live(configuration: configuration)
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
        let (status, output) = hooks.build(directory)
        let buildMs = (hooks.now() - buildStarted) * 1000
        // 壊れたままのソースで作り直しを繰り返さない。直したら世代が変わるので、
        // そのとき次の作り直しが走る
        lastStamp = stamp

        guard status == 0 else {
            // **走っているものは落とさない。** 直前の版が動き続けるのが、
            // 作り直しが失敗したときに最も助かる振る舞いである
            return finish(
                BuildReport(
                    ok: false, status: status, output: output, stamp: stamp,
                    configuration: configurationName,
                    timings: .init(detectMs: detectMs, buildMs: buildMs, relaunchMs: nil)))
        }

        let relaunchStarted = hooks.now()
        stop()
        if let executable = hooks.resolveExecutable(directory) {
            child = hooks.launch(
                executable, directory, stamp, reportsRate ? configurationName : nil)
        }
        let relaunchMs = (hooks.now() - relaunchStarted) * 1000

        return finish(
            BuildReport(
                ok: true, status: 0, output: output, stamp: stamp,
                configuration: configurationName,
                timings: .init(detectMs: detectMs, buildMs: buildMs, relaunchMs: relaunchMs)))
    }

    private func finish(_ report: BuildReport) -> BuildReport {
        lastReport = report
        write(report)
        return report
    }

    /// 結果を区画へ置く。観測と同じ流儀 (原子的に書く)。
    private func write(_ report: BuildReport) {
        let url = BuildReport.statusURL(under: facetBase)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(report) else { return }
        try? AtomicWrite.write(data, to: url)
    }
}
