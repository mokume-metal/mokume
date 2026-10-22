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
/// **同じ記録を、`gpu-slot.py` の下で走るプロセスの関所も読む。** `gpu-slot.py` が読むのは起こす
/// ときだけなので、包んだ実行の中で後から起きるプロセス (exit test の子・`mokume watch` の世代) や、
/// 既に走っている別の枠の検査は、起こすときの検めを通らない。そこで関所 (``CommandQueueGate``) が、
/// 発行口を作る前に記録の有無を見て (`stat` 1 回)、あれば期限切れと同じく作らない。
///
/// ## どこへ書くか
///
/// **`scripts/gpu-slot.py` の下で走っているときだけ書く。** 書き先は `gpu-slot.py` が環境変数
/// (``variable``) で渡す。渡されていなければ何も書かず、何も読まない。利用者のスケッチ・`mokume run`・
/// `mokume watch` が、開発の道具の置き場へ書かないためである。読む場所は
/// ``StartupReads/gpuSlotExpiryRecord`` が名乗る (起動の瞬間に決まる)。
///
/// ## 何を書くか
///
/// 書くのは JSON 1 つ — 時刻・pid・cwd・コマンド・どの待ちがどの期限を越えたか・`gpu-slot.py` の pid。
/// 親プロセスの連鎖とエージェントの出所は、子からは引けないので `gpu-slot.py` が子の終わりの後に足す。
///
/// **記録は手で消すまで残る。** 下ろす条件は時間にも回数にも置かない (``CommandQueueGate`` の印が
/// 一方向なのと同じ理由で、回復を確かめること自体が答えない GPU への積み増しになる)。消すのは人で、
/// 何を確かめてから消すかは `gpu-slot.py` が止まるときの文面に書く。
///
/// **書けなかったときは 1 度名乗る** (``CommandQueueGate/close(after:limit:at:writesRecord:)``)。
/// 記録が無いと次の検査・計測は止まらないので、黙って消えると守りが無いことに誰も気付かない。
/// **既にあれば上書きしない** (最初の 1 件を残す)。
///
/// **ディスクまで落とす。** 書いた直後に機械が落ちる (パニックになる) ことがあるので、`gpu-slot.py`
/// 自身の記録と同じく `F_FULLFSYNC` する。**書けない経路もある** — 待ちが期限 (5 秒) を越えて
/// 戻る前に、プロセスが殺される (watchdog・`kill`) と、この記録は書かれない。その回の守りは
/// `gpu-slot.py` の起動元の記録 (`take` の行) と人の目に任せる。
///
/// [#2052]: https://github.com/mokume-metal/mokume/issues/2052
/// [#2235]: https://github.com/mokume-metal/mokume/issues/2235
nonisolated struct ExpiryRecord: Sendable, Equatable {
    /// 書き先を渡す環境変数 (`scripts/gpu-slot.py` が子へ渡す)。
    static let variable = StartupReads.gpuSlotExpiryRecord.key
    /// 包みの pid を渡す環境変数。記録に載せ、包みが自分の子の記録かを見分ける。
    static let wrapperVariable = "MOKUME_GPU_SLOT_PID"

    let path: URL
    /// `gpu-slot.py` の pid。渡されていなければ `nil`。
    let wrapper: Int?

    /// 書いた結果。
    enum Outcome: Equatable {
        /// 書けた。
        case written
        /// 既にあった (上書きしない)。
        case alreadyThere
        /// 書けなかった。`reason` は人が読む理由。
        case failed(reason: String)
    }

    /// 環境から作る。書き先が渡されていなければ `nil` (何も書かず、何も読まない)。
    ///
    /// **読む場所は ``StartupReads/gpuSlotExpiryRecord``** — 鍵は一覧が正典である。
    static func fromEnvironment(_ given: [String: String]? = nil) -> ExpiryRecord? {
        let environment = given ?? ProcessInfo.processInfo.environment
        let entry = StartupReads.gpuSlotExpiryRecord
        guard let path = environment[entry.key], !path.isEmpty else { return nil }
        return ExpiryRecord(
            path: URL(fileURLWithPath: path), wrapper: environment[wrapperVariable].flatMap { Int($0) })
    }

    /// 記録が在るか。**`stat` 1 回で、中身は読まない。** リンクも在るものとして数える (壊れていても)。
    var exists: Bool {
        var status = stat()
        return lstat(path.path, &status) == 0
    }

    /// 記録を書く。**上書きせず** (`O_EXCL`)、**ディスクまで落とす** (`F_FULLFSYNC`)。投げない。
    @discardableResult
    func write(after wait: CommandQueueGate.Wait, limit: Duration, at date: Date = Date()) -> Outcome {
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
        else { return .failed(reason: "could not encode the record") }

        let descriptor = open(path.path, O_WRONLY | O_CREAT | O_EXCL, 0o644)
        guard descriptor >= 0 else {
            if errno == EEXIST { return .alreadyThere }
            return .failed(reason: Self.reason(errno))
        }
        defer { close(descriptor) }
        var written = 0
        let failure: Int32? = data.withUnsafeBytes { raw in
            while written < raw.count {
                let count = Foundation.write(descriptor, raw.baseAddress! + written, raw.count - written)
                if count < 0 {
                    if errno == EINTR { continue }
                    return errno
                }
                written += count
            }
            return nil
        }
        if let failure { return .failed(reason: Self.reason(failure)) }
        // macOS の `fsync` はドライブのキャッシュに留まりうるので `F_FULLFSYNC` を試す
        if fcntl(descriptor, F_FULLFSYNC) != 0 { _ = fsync(descriptor) }
        return .written
    }

    private static func reason(_ code: Int32) -> String { String(cString: strerror(code)) }

    /// 手元の時間帯の `2026-10-22T09:00:00+0900`。`gpu-slot.py` の `time.strftime("%Y-%m-%dT%H:%M:%S%z")` と揃える。
    static func timestamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ssZ"
        return formatter.string(from: date)
    }
}
