// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Synchronization

/// 隔離の外から届く知らせを、main actor へ渡す前に**合体する**器 ([#1594])。
///
/// **知らせは事象ごとに届くが、main actor へ積むのは 1 本まででよい。** 受ける側が知りたいのは
/// 「どこまで終わったか」「変わったか」だけで、途中を 1 つずつ受け取る必要は無い。事象ごとに
/// `Task` を 1 本積むと、main actor を譲らずにフレームを回す経路 (窓を出さない書き出しや
/// 検査のループ) では 1 本も走れず、フレームに比例して溜まり続けた。「誰が `advance()` を
/// 叩くかは外側の話」(``SketchRuntime``) と食い違う。
///
/// **合体するのは溜まらないようにするためで、譲らない間に届けるためではない。** 積んだ 1 本も
/// 譲るまでは走らない。譲らない間にも届いてほしい知らせは、受ける側が別の口で取る。
/// ``FileWatcher`` は、フレームの頭で印を取る ([#1830])。``RenderDevice`` は、待つ口 (`settle()`) が
/// 合図を直に読む。
///
/// 使うのは 2 か所である。
///
/// | 使い手 | 知らせ | 番号 |
/// | --- | --- | --- |
/// | ``RenderDevice`` | 投入の完了 (Metal 側の糸) | 投入の番号 |
/// | ``FileWatcher`` | ファイルの変化 (見張りの待ち行列) | 使わない (0) |
///
/// **控えるのは届いた最大の番号である。** 先に積んだ知らせの番号のまま刈ると、後から届いた
/// 投入を刈り残す。刈る側は番号と合図 (`MTLSharedEvent`) の進んでいるほうまで刈るが、合図は
/// コマンドの後にキューが進めるので、知らせが届いた時点でまだ上がっていないことがある
/// ([#1076] の保持環が 1 フレームぶん戻る)。
///
/// 知らせは別の糸から届くので、錠で守る (``CommandFaultLog`` と同じ作法)。
///
/// [#1076]: https://github.com/mokume-metal/mokume/issues/1076
/// [#1594]: https://github.com/mokume-metal/mokume/issues/1594
/// [#1830]: https://github.com/mokume-metal/mokume/issues/1830
nonisolated final class CoalescedNotices: Sendable {
    private struct State {
        var newest: UInt64 = 0
        var queued = 0
        var arrived = 0
    }

    private let state = Mutex(State())

    /// 番号 `submission` の投入の知らせが届いた。**main actor へ新しく積むべきなら `true`**
    /// — 積んだまま走っていない知らせがあれば、それが走るときにこの番号も読むので積まない。
    ///
    /// `true` を返したら、呼び出し側は必ず 1 本積み、それが走るときに ``take()`` を呼ぶ。
    func arrive(_ submission: UInt64) -> Bool {
        state.withLock { state in
            state.arrived += 1
            state.newest = max(state.newest, submission)
            guard state.queued == 0 else { return false }
            state.queued += 1
            return true
        }
    }

    /// 積んだ知らせが走る。**届いている最大の番号を返し、積んだ印を下ろす。**
    ///
    /// 下ろした後に届いた知らせは、改めて 1 本積む (``arrive(_:)`` が `true` を返す)。
    func take() -> UInt64 {
        state.withLock { state in
            state.queued -= 1
            return state.newest
        }
    }

    /// 届いた知らせの数。
    var arrived: Int { state.withLock { $0.arrived } }

    /// main actor へ積んだまま、まだ走っていない知らせの数。**1 を超えない。**
    var queued: Int { state.withLock { $0.queued } }
}
