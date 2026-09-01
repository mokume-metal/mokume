// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

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
    /// **捕まえられるものだけを捕まえる。** 強制終了 (SIGKILL) と、親ごと消える終わり方は
    /// 受け取れないので、そこは直したふりをしない ([#681](https://github.com/mokume-metal/mokume/issues/681))。
    static let stopSignals: [Int32] = [SIGINT, SIGTERM]

    /// - Parameter watching: 巡回のしかた。**検査から差し替える** — 既定は合図が来るまで
    ///   回り続けるので、始める前に止まることを確かめる検査がここで固まらないようにする。
    static func run(
        _ arguments: [String], watching: (WatchSession) -> Void = { watch($0) }
    ) throws(CommandFailure) {
        let directory = URL(
            fileURLWithPath: arguments.first ?? FileManager.default.currentDirectoryPath,
            isDirectory: true)
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
            directory: directory, facetBase: WorkDirectory.given ?? directory, reportsRate: true)
        print("見張っている: \(directory.path)")
        // **常に名乗る。** 以前は基準がスケッチの場所と違うときだけ出していたが、それだと
        // 窓口の側にだけ MOKUME_WORK_DIR が効いている向きで比べる材料が出ない (#380)
        print(
            StartupReadsReport.baseLine(
                base: session.facetBase, given: WorkDirectory.given != nil))
        // 子を起こす前に受け口を置く。起こした後だと、その隙間に来た合図で
        // 既定の振る舞い (親だけが即座に終わる) に落ちて子が残る
        installStopHandlers()
        report(session.start())

        watching(session)
        finish(session)
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

    /// 巡回する。**終わりの合図が来るまで回り、来たら抜ける。**
    ///
    /// 合図を別のキューで受けて `WatchSession` を触る形は採らない — main actor 既定
    /// ([ADR-0010]) の上で隔離を跨ぐことになる。印を見て抜けるだけなら、終わらせる処理は
    /// 巡回と同じところに残る。遅れは間隔 (`interval`) の範囲に収まる。
    ///
    /// [ADR-0010]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0010-concurrency-model.md
    ///
    /// - Parameters:
    ///   - sleep: 待ち方。検査から差し替える。
    ///   - stopped: 終わりの合図が来たか。検査から差し替える。
    static func watch(
        _ session: WatchSession,
        sleep: (TimeInterval) -> Void = { Thread.sleep(forTimeInterval: $0) },
        stopped: () -> Bool = { watchStopRequested != 0 }
    ) {
        while !stopped() {
            sleep(interval)
            // **待っている間に来た合図は、作り直しより先に効く。** ここを見ないと、
            // 終われと言われた後に 1 回だけ作り直して子を起こすことになる
            if stopped() { break }
            if let outcome = session.tick() { report(outcome) }
        }
    }

    /// 終わる。**走らせていたものを置いていかない。**
    ///
    /// 止めたかどうかを名乗る — 子が既に死んでいた場合と、止めた場合は別の出来事である。
    static func finish(_ session: WatchSession) {
        print(session.stop() ? "見張りを終える (走らせていたスケッチを止めた)" : "見張りを終える")
    }

    private static func report(_ outcome: BuildReport) {
        print(outcome.summary)
        if !outcome.ok, !outcome.output.isEmpty {
            print(outcome.output)
            print("直前の版を走らせたまま待っている")
        }
    }
}
