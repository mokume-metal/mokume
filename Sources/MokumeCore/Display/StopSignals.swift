// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Darwin

/// 終わりの合図を受けたか。**受けていなければ 0。**
///
/// **シグナルのハンドラから書くので、置き場はグローバルに 1 つ。** ハンドラは文脈を
/// 捕まえられない (道具の側の `runStopSignal` / `watchStopRequested` と同じ作法)。
nonisolated(unsafe) var sketchStopRequested: sig_atomic_t = 0

/// 終わりの合図 (`SIGTERM` / `SIGINT`) を、AppKit の終わりの経路へ運ぶ受け口
/// ([#1219](https://github.com/mokume-metal/mokume/issues/1219))。
///
/// **受け口が無ければ、合図を受けた瞬間にプロセスが消える。** 後始末
/// (``SketchApplication/shouldTerminate()`` → ``SketchApplication/willTerminate()``) を
/// 通らないので、撮っていた動画は末尾のメタデータ (`moov`) を持たないまま残り、開けない
/// ファイルになる。道具は子を `SIGTERM` で止める (`mokume run` の中継・見張りの停止) ので、
/// 撮っているスケッチを道具から止めるたびに踏んでいた。
///
/// ## ハンドラは旗を立てるだけ
///
/// ハンドラの中で呼んでよいのは async-signal-safe なものだけで、`terminate(_:)` はそうでない。
/// だから旗を立てるだけにして、main の run loop から ``takeRequest()`` で見に来る。
///
/// **待ち行列を増やさない。** `DispatchSource.makeSignalSource` でも運べるが、待ち行列を
/// 引数に取るので [ADR-0010] 決定 4 の例外 (いまは `FileWatcher` の 1 本だけ) が増える。
/// 見に来る側 (予備の駆動源) は既に run loop に載っているので、旗で足りる。
///
/// ## 継いだ無視は上書きしない
///
/// 背面 (`&`) で起こされた子は `SIGINT` を無視 (`SIG_IGN`) で継ぐ — 端末の Control + C を
/// 前面の仕事にだけ届けるための、シェルの約束である。受け口を置くとその約束を壊すので、
/// 無視で継いだ合図には何も置かない (`SIGTERM` も同じ規則に従う)。
///
/// [ADR-0010]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0010-concurrency-model.md
package nonisolated enum StopSignals {
    /// 受け口を置く合図。
    ///
    /// **`SIGHUP` は入れない。** 端末が閉じたときに届くもので、道具はスケッチを止めるのに
    /// 使わない (`mokume run` は自分で受けて子へ `SIGTERM` を渡す)。
    static let numbers: [Int32] = [SIGTERM, SIGINT]

    /// 受け口を置く。**無視で継いだ合図には置かない。**
    ///
    /// - Returns: 置き換えた合図と、置き換える前の受け口。``restore(_:)`` へ渡す
    ///   (本番のスケッチは戻さない — 戻すのは検査のため)。
    @discardableResult
    static func install() -> [(number: Int32, previous: sigaction)] {
        numbers.compactMap { number in
            var previous = sigaction()
            sigaction(number, nil, &previous)
            guard !isIgnored(previous) else { return nil }
            var action = sigaction()
            action.__sigaction_u.__sa_handler = { _ in sketchStopRequested = 1 }
            // 受け口が待ちへ割り込んでも、呼び出しが `EINTR` で失敗して見えないようにする
            action.sa_flags = SA_RESTART
            sigaction(number, &action, nil)
            return (number, previous)
        }
    }

    /// ``install()`` が置き換えた受け口を戻す。
    static func restore(_ replaced: [(number: Int32, previous: sigaction)]) {
        for (number, previous) in replaced {
            var previous = previous
            sigaction(number, &previous, nil)
        }
    }

    /// 合図を受けていたか。**読んだら下ろす** — 1 度の合図で終わりを 1 度だけ頼む。
    static func takeRequest() -> Bool {
        guard sketchStopRequested != 0 else { return false }
        sketchStopRequested = 0
        return true
    }

    /// その受け口が「無視」か。
    ///
    /// `SIG_IGN` は `(void (*)(int))1` という番地の約束なので、関数ポインタとしては比べられず、
    /// 番地で比べる。
    ///
    /// **道具も同じ判定を使う** (`mokume render` が SIGINT を受けるか決める)。番地の比べ方を
    /// 写さないために、パッケージの中へ開けてある。
    package static func isIgnored(_ action: sigaction) -> Bool {
        address(of: action) == address(of: SIG_IGN)
    }

    /// その受け口が「既定」(受け口が無い) か。
    static func isDefault(_ action: sigaction) -> Bool {
        address(of: action) == address(of: SIG_DFL)
    }

    private static func address(of action: sigaction) -> Int {
        address(of: action.__sigaction_u.__sa_handler)
    }

    private static func address(of handler: (@convention(c) (Int32) -> Void)?) -> Int {
        unsafeBitCast(handler, to: Int.self)
    }
}
