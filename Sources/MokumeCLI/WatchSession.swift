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
        reportsRate: Bool = false, hooks: Hooks? = nil
    ) {
        self.directory = directory
        self.facetBase = facetBase ?? directory
        self.configuration = configuration
        self.reportsRate = reportsRate
        self.hooks = hooks ?? .live(configuration: configuration)
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

    /// 走らせているものを終わらせる。
    ///
    /// - Returns: 実際に止めたか。**既に居ない・既に死んでいる**ときは `false` で、
    ///   呼ぶ側はそれを別の出来事として名乗れる (見張りの終わり方が 2 通りある)。
    @discardableResult
    func stop() -> Bool {
        guard let child, child.isRunning else { return false }
        child.terminate()
        child.waitUntilExit()
        self.child = nil
        return true
    }

    private func rebuildAndReplace(stamp: String?, initial: Bool = false) -> BuildReport {
        let detectMs = noticedAt.map { (hooks.now() - $0) * 1000 }
        noticedAt = nil

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
        let url = facetBase
            .appendingPathComponent(".mokume", isDirectory: true)
            .appendingPathComponent("build", isDirectory: true)
            .appendingPathComponent("status.json")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(report) else { return }
        try? AtomicWrite.write(data, to: url)
    }
}

/// 読み手が書きかけを掴まないように書く (ADR-0018 決定 3)。
///
/// ライブラリ側にも同じものがあるが、道具からは使えない (外へ出していない)。
/// 規約は文章で共有し、実装はそれぞれが持つ — 出すべきかどうかは、外から使う人が
/// 現れてから決める。
enum AtomicWrite {
    static func write(_ data: Data, to url: URL) throws {
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let temporary = directory.appendingPathComponent(
            ".\(url.lastPathComponent).tmp", isDirectory: false)
        try data.write(to: temporary)
        _ = try FileManager.default.replaceItemAt(url, withItemAt: temporary)
    }
}
