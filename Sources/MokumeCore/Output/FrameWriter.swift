// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation
import MokumeDiagnostics
import Synchronization

/// 絵をファイルにする係。**符号化と書き込みをフレームの外で行う。**
///
/// フレームの中で払うのは読み戻しだけである。符号化と書き込みまでフレームに載せると、
/// **ディスクの速さがフレームレートを縛る** — 撮っている間だけ絵が遅くなり、撮り終えると
/// 直る、という切り分けの難しい症状になる。
///
/// ## 抱える枚数に上限がある
///
/// 上限と待ち方は ``Backpressure`` が持つ。上限に達すると ``write(_:to:)`` が返らなく
/// なるので、遅いディスクではフレームが遅くなる。**代わりにメモリは伸びない。**
///
/// ## 同じ行き先へは頼んだ順に書く
///
/// 書き込みは 1 枚ずつ並行に走る。**同じ行き先への書き込みだけは、前に頼んだものが終わって
/// から書く** (``WriteLanes``)。そうしないと後に頼んだ絵が先に書き終わり、前の絵が後から
/// 置き換える — 同じ名前へ毎フレーム `save()` すると、最後に残るのが最後のフレームの絵に
/// ならない ([#1627])。違う行き先どうし (連番) は待ち合わない。
///
/// ## 待ち方
///
/// 走らせる側は `Task.detached` で main actor の外へ出す ([ADR-0010] 決定 4)。
/// **待つ側は semaphore である** — 完了を待つのは main actor の上なので `await` が
/// 使えない (`endRecord()` が同期の `draw()` から呼ばれる public API なので、`await` は
/// 利用者のスケッチに現れてしまう。同 決定 1)。`DispatchQueue` は足さない (同 決定 4)。
///
/// **塞いで待つのは `endRecord()` の経路だけである。** 終わりの経路は同じ合図を塞がずに
/// 見に来る (``Patience/peek``・[#978])。
///
/// [#978]: https://github.com/mokume-metal/mokume/issues/978
/// [#1627]: https://github.com/mokume-metal/mokume/issues/1627
/// [ADR-0010]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0010-concurrency-model.md
/// [ADR-0023]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0023-frame-stages-and-outputs.md
final class FrameWriter {
    /// 同時に抱える枚数の既定の上限。
    static let defaultLimit = Backpressure.defaultLimit

    /// 抱える枚数の上限と、終わったものの数え方。
    private let pressure: Backpressure
    /// 最後に決着した書き込みの結果。**隔離の外から書かれる**ので錠で守る。
    private let lastOutcome = OutcomeSlot()
    /// 行き先ごとの、書き込みの順番待ち。
    private let lanes = WriteLanes()

    /// 抱えている枚数の上限。
    var limit: Int { pressure.limit }
    /// いま抱えている枚数 (取り込み済みの完了を差し引いたもの)。
    var outstanding: Int { pressure.outstanding }
    /// 抱えた枚数の最大。**背圧が効いたことを検査から見るための目印。**
    var peakOutstanding: Int { pressure.peak }
    /// 頼まれた総数。
    private(set) var requested = 0
    /// 順番待ちの控えを持つ行き先の数。**控えが伸びないことを検査から見るための目印。**
    var pendingDestinations: Int { lanes.pendingDestinations }
    /// 1 枚をファイルにする関数。**フレームの外で呼ばれる。**
    ///
    /// 差し替えられるのは検査のためである。書き込みの決着の順は機械の混み具合で決まるので、
    /// 順序の検査は、書く関数の側で 1 枚を遅らせて崩れる状況を作る ([#1627])。
    ///
    /// [#1627]: https://github.com/mokume-metal/mokume/issues/1627
    typealias Encode = @Sendable (DisplayImage, URL) throws -> Void
    private let encode: Encode

    init(
        limit: Int = FrameWriter.defaultLimit,
        encode: @escaping Encode = { image, url in try PNGFile.write(image, to: url) }
    ) {
        pressure = Backpressure(limit: limit)
        self.encode = encode
    }

    /// 1 枚を書くよう頼む。**上限に達していたら、空くまで返らない。**
    ///
    /// 途中のディレクトリはここで作る — 撮る先を先に用意させると、名前を組み立てた
    /// 側と作る側が二重になる。
    func write(_ image: DisplayImage, to path: String) {
        // 背圧。ここで待つのは main actor なので、フレームが遅くなる代わりに
        // 抱える枚数は上限を超えない
        pressure.take()
        requested += 1

        let url = URL(fileURLWithPath: path)
        let release = pressure.release
        let lastOutcome = lastOutcome
        let path = path
        let encode = encode
        // **同じ行き先へは、前に頼んだ書き込みの後に書く** (#1627)。行き先は綴りを揃えて
        // 比べる — `out/../a.png` と `a.png` は同じファイルである
        lanes.enqueue(url.standardizedFileURL.path) {
            // **結果は枠を返す前に置く。** 背圧で待っていた側は、返ってきた時点で
            // 少なくとも 1 つの結果が置かれていると当てにできる
            do {
                try FileManager.default.createDirectory(
                    at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try encode(image, url)
                lastOutcome.succeed()
            } catch {
                lastOutcome.fail("Could not write \(path): \(error)")
            }
            release()
        }
    }

    /// 頼んだ全部が**ファイルになるまで**待つ。
    ///
    /// 「呼んだら書かれる」ように見える面が「あとで書かれる」実装だと、止めるときに
    /// 壊れる。**始まりだけでなく終わりも面の一部**なので、待てる形をここに置く。
    ///
    /// 2 度呼んでも安全 (抱えている枚数が 0 なら何もしない)。
    ///
    /// **1 枚も進まなくなったら諦める** (``Backpressure/drain(_:)``)。返らないディスクを
    /// 相手に永久に待つと、main actor が固まって絵も観測も入力も一緒に黙る。諦めても
    /// 書き込みは走り続けるので、失うのは「返ってきた時点で書けている」という保証だけ。
    ///
    /// - Parameter patience: まだ書けていないとき、塞いで待つか、その場で返るか。
    /// - Returns: 決着したか (全部書けた・諦めた)。``Patience/block`` なら必ず `true`。
    @discardableResult
    func drain(_ patience: Patience = .block) -> Bool {
        guard pressure.drain(patience) else { return false }
        if pressure.outstanding > 0 {
            Diagnostics.warn(
                "Writing images has not moved for \(Int(pressure.stallLimitSeconds)) seconds "
                    + "(\(pressure.outstanding) are still waiting) — no longer waiting for it. "
                    + "Writing is still going")
        }
        return true
    }

    /// 前に取り出してから決着した書き込みの、最後の結果を取り出す。**取り出したら消える。**
    ///
    /// 書き込みは隔離の外で走るので、結果が分かるのは頼んだフレームより後になる。
    /// 呼んだ側 (``FrameRecorder``) はこれを差込口の ``Outlet/failure`` へ載せ、
    /// 続けて転んだら外れる形へつなぐ ([ADR-0024] 決定 7)。**`nil` は「順調」ではなく
    /// 「まだ何も決着していない」である** ([#1272])。
    ///
    /// [#1272]: https://github.com/mokume-metal/mokume/issues/1272
    /// [ADR-0024]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0024-extension-seams.md
    func takeOutcome() -> WriteOutcome? { lastOutcome.take() }

    /// 最後の結果が書き損じなら、その理由を取り出す。**取り出したら消える。**
    ///
    /// 閉じる経路のように「言い残しが無いか」だけを見る読み手のためにある。
    func takeFailure() -> String? { takeOutcome()?.failure }
}

/// 行き先ごとに、書き込みを頼んだ順に並べる。**違う行き先どうしは待ち合わない。**
///
/// 行き先ごとに、最後に頼んだ仕事だけを控える。新しい仕事は、同じ行き先の控えが終わるのを
/// 待ってから走る — 控えも自分の前を待っているので、同じ行き先の仕事は頼んだ順に 1 本ずつ
/// 走る。待つのは隔離の外の仕事で、頼む側 (main actor) は待たない。
///
/// **控えは、その仕事が終わったときに消す** (後から同じ行き先が頼まれていなければ)。
/// 連番のように毎回違う名前へ書いても、控えは走っている仕事の数までしか伸びない。
///
/// 仕事を作るのは錠の中である。錠の外で作ると、仕事が控えを置く前に終わって消そうとし、
/// 終わった仕事の控えが残る。
///
/// [#1627]: https://github.com/mokume-metal/mokume/issues/1627
nonisolated final class WriteLanes: Sendable {
    private struct Tail {
        let ticket: Int
        let task: Task<Void, Never>
    }

    private struct State {
        var issued = 0
        var tails: [String: Tail] = [:]
    }

    private let state = Mutex(State())

    /// 同じ行き先の前の仕事が終わってから `work` を走らせる。**待たずに返る。**
    func enqueue(_ destination: String, _ work: @escaping @Sendable () -> Void) {
        state.withLock { state in
            let previous = state.tails[destination]?.task
            state.issued += 1
            let ticket = state.issued
            let task = Task.detached(priority: .utility) { [self] in
                await previous?.value
                work()
                finish(destination, ticket)
            }
            state.tails[destination] = Tail(ticket: ticket, task: task)
        }
    }

    /// 行き先ごとの控えの数。**検査が、控えが伸びないことを見るための目印。**
    var pendingDestinations: Int { state.withLock { $0.tails.count } }

    /// 終わった仕事の控えを消す。後から同じ行き先が頼まれていれば、そちらが控えなので残す。
    private func finish(_ destination: String, _ ticket: Int) {
        state.withLock { state in
            if state.tails[destination]?.ticket == ticket { state.tails[destination] = nil }
        }
    }
}

/// 書き込み 1 つの決着。
enum WriteOutcome: Equatable, Sendable {
    /// 書けた。
    case succeeded
    /// 書けなかった。理由を持つ。
    case failed(String)

    /// 書けなかった理由。書けたなら `nil`。
    var failure: String? {
        guard case .failed(let reason) = self else { return nil }
        return reason
    }
}

/// 隔離の外から書かれ、main actor から読まれる、最後に決着した結果。
///
/// **成功も置く** ([#1272])。失敗だけを置く器だと、取り出して空だったときに
/// 「書けた」と「まだ決着していない」を分けられず、後者を順調と数えてしまう。
///
/// 錠そのもの (`Mutex`) は複製できないので、閉じた先の仕事へ渡すには参照になる器が要る。
/// **escape hatch は使わない** ([ADR-0010] 決定 3) — 中身が錠で守られていることを
/// 型として示す。
///
/// [#1272]: https://github.com/mokume-metal/mokume/issues/1272
/// [ADR-0010]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0010-concurrency-model.md
nonisolated final class OutcomeSlot: Sendable {
    private let value = Mutex<WriteOutcome?>(nil)

    /// 書けたことを置く。
    func succeed() { value.withLock { $0 = .succeeded } }

    /// 書き損じを置く。
    ///
    /// **成功も失敗も、後から来たものが前を上書きする** — 置くのは「最後に決着した結果」
    /// である。続けて転んでいることは差込口の健康状態が数えるので、ここに溜める理由が無い。
    /// 書き損じの後に成功が決着すれば、その書き損じは読まれずに消える (直ったので)。
    func fail(_ message: String) { value.withLock { $0 = .failed(message) } }

    /// 置かれているものを取り出す。**取り出したら消える。**
    func take() -> WriteOutcome? {
        value.withLock { stored in
            defer { stored = nil }
            return stored
        }
    }
}
