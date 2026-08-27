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
        /// 走らせる。世代の刻印を渡す。
        var launch: (URL, URL, String?) -> Process?
        /// いまの時刻 (秒)。
        var now: () -> Double
        /// 監視しているソースの世代。
        var stamp: (URL) -> String?

        static func live() -> Hooks {
            Hooks(
                build: { directory in
                    let result = try? RunCommand.swift(["build"], in: directory, capturing: true)
                    return (result?.status ?? 1, result?.output ?? "")
                },
                resolveExecutable: { directory in try? RunCommand.executablePath(in: directory) },
                launch: { executable, directory, stamp in
                    let process = Process()
                    process.executableURL = executable
                    process.currentDirectoryURL = directory
                    var environment = ProcessInfo.processInfo.environment
                    // 観測はこれを応答へそのまま載せる。読み手は刻印の変化で
                    // 「保存した内容が反映されたか」を待ち時間ではなく判定できる
                    if let stamp { environment["MOKUME_SOURCE_STAMP"] = stamp }
                    process.environment = environment
                    return (try? process.run()) == nil ? nil : process
                },
                now: { Date().timeIntervalSince1970 },
                stamp: { SourceStamp.current(for: $0) })
        }
    }

    let directory: URL
    let configuration: String
    private var hooks: Hooks

    /// いま走らせている子。
    private(set) var child: Process?
    /// 最後に作り直したときのソースの世代。
    private(set) var lastStamp: String?
    /// 直近の作り直しの結果。
    private(set) var lastReport: BuildReport?
    /// 変化に気付いた時刻。作り直しの直前に消す。
    private var noticedAt: Double?

    init(directory: URL, configuration: String = "debug", hooks: Hooks = .live()) {
        self.directory = directory
        self.configuration = configuration
        self.hooks = hooks
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
        rebuildAndReplace(stamp: hooks.stamp(directory))
    }

    /// 走らせているものを終わらせる。
    func stop() {
        guard let child, child.isRunning else { return }
        child.terminate()
        child.waitUntilExit()
        self.child = nil
    }

    private func rebuildAndReplace(stamp: String?) -> BuildReport {
        let detectMs = noticedAt.map { (hooks.now() - $0) * 1000 }
        noticedAt = nil

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
                    configuration: configuration,
                    timings: .init(detectMs: detectMs, buildMs: buildMs, relaunchMs: nil)))
        }

        let relaunchStarted = hooks.now()
        stop()
        if let executable = hooks.resolveExecutable(directory) {
            child = hooks.launch(executable, directory, stamp)
        }
        let relaunchMs = (hooks.now() - relaunchStarted) * 1000

        return finish(
            BuildReport(
                ok: true, status: 0, output: output, stamp: stamp,
                configuration: configuration,
                timings: .init(detectMs: detectMs, buildMs: buildMs, relaunchMs: relaunchMs)))
    }

    private func finish(_ report: BuildReport) -> BuildReport {
        lastReport = report
        write(report)
        return report
    }

    /// 結果を区画へ置く。観測と同じ流儀 (原子的に書く)。
    private func write(_ report: BuildReport) {
        let url = directory
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
