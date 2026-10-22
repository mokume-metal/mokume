// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation

/// GPU の待ちが期限を越えたことを、プロセスの外に 1 つだけ残す記録 ([#2235])。
///
/// ## なぜ要るか
///
/// ``CommandQueueGate`` の印はプロセスの中にしか無い。GPU の詰まりが画面の描画 (WindowServer) ごと
/// 機械を止める害は機械全体に及ぶので、印を立てたプロセスが終わった後に、`scripts/gpu-slot.py` が
/// 次の検査・計測を起こすと、まだ答えない GPU へ新しい関所が発行口を作る ([#2052])。この記録は、
/// その手前で `gpu-slot.py` が読んで止まるための印である。
///
/// ## どこへ書くか
///
/// **`scripts/gpu-slot.py` の下で走っているときだけ書く。** 書き先は `gpu-slot.py` が環境変数
/// (``variable``) で渡す。渡されていなければ何も書かない。利用者のスケッチ・`mokume run`・`mokume watch`
/// が、開発の道具の置き場へ書かないためである。
///
/// ## 何を書くか
///
/// 書くのは JSON 1 つ — 時刻・pid・cwd・コマンド・どの待ちがどの期限を越えたか・`gpu-slot.py` の pid。
/// 親プロセスの連鎖とエージェントの出所は、子からは引けないので `gpu-slot.py` が子の終わりの後に足す。
///
/// **記録は手で消すまで残る。** 下ろす条件は時間にも回数にも置かない (``CommandQueueGate`` の印が
/// 一方向なのと同じ理由で、回復を確かめること自体が答えない GPU への積み増しになる)。消すのは人で、
/// 消し方は `gpu-slot.py` が止まるときの文面に書く。
///
/// **書けなくても何も投げない。** 記録のために、期限切れの後始末を止めない。**既にあれば上書きしない**
/// (最初の 1 件を残す)。
///
/// [#2052]: https://github.com/mokume-metal/mokume/issues/2052
/// [#2235]: https://github.com/mokume-metal/mokume/issues/2235
nonisolated struct ExpiryRecord: Sendable, Equatable {
    /// 書き先を渡す環境変数 (`scripts/gpu-slot.py` が子へ渡す)。
    static let variable = "MOKUME_GPU_SLOT_EXPIRY_RECORD"
    /// 包みの pid を渡す環境変数。記録に載せ、包みが自分の子の記録かを見分ける。
    static let wrapperVariable = "MOKUME_GPU_SLOT_PID"

    let path: URL
    /// `gpu-slot.py` の pid。渡されていなければ `nil`。
    let wrapper: Int?

    /// 環境から作る。書き先が渡されていなければ `nil` (何も書かない)。
    static func fromEnvironment(_ environment: [String: String] = ProcessInfo.processInfo.environment) -> ExpiryRecord? {
        guard let path = environment[variable], !path.isEmpty else { return nil }
        return ExpiryRecord(path: URL(fileURLWithPath: path), wrapper: environment[wrapperVariable].flatMap { Int($0) })
    }

    /// 記録を書く。**書けたら `true`。** 既にある・書き先が使えないときは何もせず `false` を返す。
    @discardableResult
    func write(after wait: CommandQueueGate.Wait, limit: Duration, at date: Date = Date()) -> Bool {
        var entry: [String: Any] = [
            "event": "wait-expired",
            // gpu-slot の記録 (`$MOKUME_GPU_SLOT_LOG`) の `time` と同じ形 (`2026-10-22T09:00:00+0900`)
            "time": Self.timestamp(date),
            "pid": Int(ProcessInfo.processInfo.processIdentifier),
            "cwd": FileManager.default.currentDirectoryPath,
            "command": CommandLine.arguments,
            "wait": wait.phrase,
            "limit": "\(limit)",
        ]
        if let wrapper { entry["gpu_slot_pid"] = wrapper }
        guard
            let data = try? JSONSerialization.data(
                withJSONObject: entry, options: [.sortedKeys, .withoutEscapingSlashes])
        else { return false }
        // **上書きしない。** 最初の 1 件を残す (既にあれば、`gpu-slot.py` が先に止めているはず)
        return (try? data.write(to: path, options: [.withoutOverwriting])) != nil
    }

    /// 手元の時間帯の `2026-10-22T09:00:00+0900`。`gpu-slot.py` の `time.strftime("%Y-%m-%dT%H:%M:%S%z")` と揃える。
    static func timestamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ssZ"
        return formatter.string(from: date)
    }
}
