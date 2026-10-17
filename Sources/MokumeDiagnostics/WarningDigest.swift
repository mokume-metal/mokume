// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation

/// スケッチのプロセスが言った警告の、**次の観測までの溜め場** ([#2761])。
///
/// 標準エラーの 1 行は MCP から読めない。観測の応答の `warnings` へ載せるために、
/// ``Diagnostics/warn(_:)`` が書いた文面をここへも控える。**口ごとに載せる仕組みを持たない** —
/// 言う口は MokumeCore・MokumeAudio・MokumeCamera・MokumeNetwork に 90 行あり、その全部が
/// ``Diagnostics/warn(_:)`` を通るので、通り道の 1 か所で拾えば足りる。
///
/// ## 1 度だけ載る
///
/// ``takeUnreported()`` は溜めた行を言った順に返して空にする。「1 度しか言わない」は呼ぶ側の
/// 控え (`WarningLog`) が守っていて、ここは**言われた数のぶんだけ**溜める。載せ終えた行は
/// 次の観測には出ない — 毎回載せると、`init` で 1 度踏んだ古い警告が、後の無関係な観測の
/// 失敗の理由 (時刻を指定した観測は `warnings` をそのまま理由にする) に混ざり続ける ([#2685])。
///
/// ## 上限がある
///
/// ``Diagnostics/warn(_:)`` の呼び出しには、控えを持たず毎フレーム同じ文を言いうる口がある。
/// 次の観測まで無制限に溜めると、応答もメモリも際限なく伸びる。**最初の ``limit`` 行を残し**、
/// それを越えた分は数だけを持って、返すときに 1 行で名乗る。残すのが最初の側なのは、
/// 毎フレーム言う口が後から来て、最初に起きた原因の行を押し出さないためである。
///
/// ## 隔離を持たない
///
/// ``Diagnostics`` と同じく、フレームの外へ逃がした仕事 (書き出し・符号化・受信) からも
/// 言われる ([ADR-0010] 決定 4)。持っている状態はロック 1 つで守る。
///
/// [#2685]: https://github.com/mokume-metal/mokume/issues/2685
/// [#2761]: https://github.com/mokume-metal/mokume/issues/2761
/// [ADR-0010]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0010-concurrency-model.md
package nonisolated final class WarningDigest: @unchecked Sendable {
    /// 溜める行の既定の上限。
    package static let defaultLimit = 20

    /// 溜める行の上限。
    package let limit: Int
    private let lock = NSLock()
    private var lines: [String] = []
    /// 上限を越えて、溜めなかった数。
    private var dropped = 0

    package init(limit: Int = WarningDigest.defaultLimit) {
        precondition(limit > 0, "a digest that keeps nothing cannot name what it left out")
        self.limit = limit
    }

    /// 言われた文面を 1 つ控える。上限を越えていたら、数だけ数える。
    package func record(_ message: String) {
        lock.lock()
        defer { lock.unlock() }
        if lines.count < limit {
            lines.append(message)
        } else {
            dropped += 1
        }
    }

    /// 溜めた行を言った順に返して、空にする。上限を越えていたら、最後に越えた数を名乗る 1 行を足す。
    package func takeUnreported() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        var taken = lines
        if dropped > 0 { taken.append(Self.overflowNotice(kept: limit, dropped: dropped)) }
        lines.removeAll()
        dropped = 0
        return taken
    }

    /// 溜められなかった数を名乗る行。**完全な文として持つ** (ADR-0038 決定 3 — 数だけを差し込み、
    /// 単複で語を選ばない)。標準エラーには全部が出ていることも言う。
    package static func overflowNotice(kept: Int, dropped: Int) -> String {
        "Only the first \(kept) warnings said since the last observation are listed here. "
            + "Left out: \(dropped). All of them were written to the sketch's standard error"
    }
}
