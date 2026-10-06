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
/// ## 同じ行き先には、最後に頼んだ絵が残る
///
/// 書き込みは 1 枚ずつ並行に走る。**同じ行き先への書き込みだけは 1 本ずつ書き、書いている
/// 間に頼まれたものは最後の 1 つだけを残して畳む** (``WriteLanes``)。並行のままだと後に
/// 頼んだ絵が先に書き終わり、前の絵が後から置き換える — 同じ名前へ毎フレーム `save()` すると、
/// 最後に残るのが最後のフレームの絵にならない ([#1627])。
///
/// **待たせずに畳む。** 前の書き込みの後ろに並べて待たせると、同じ名前へ毎フレーム書く
/// 使い方ではフレームの速さが 1 枚を書く時間で決まり、1 本返らない書き込みがあるだけで
/// 背圧の枠が埋まって main が止まる。畳めば同じ行き先が持つ枠は高々 2 つ (書いている 1 つと
/// 控えの 1 つ) で、残りの枠は違う行き先 (連番) が並行に使う。
///
/// 順番待ちは**プロセスで 1 つ**である。撮る係を作り直した後 (閉じ終えた後の `save()`) も、
/// 前の係の書き込みが走っていれば同じ行き先はその後ろに並ぶ。
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
    /// 行き先ごとの、書き込みの順番待ち。**プロセスで 1 つ** — 係を作り直しても、前の係の
    /// 書き込みが走っている行き先はその後ろに並ぶ (``WriteLanes``)。
    private static let lanes = WriteLanes()

    /// 抱えている枚数の上限。
    var limit: Int { pressure.limit }
    /// いま抱えている枚数 (取り込み済みの完了を差し引いたもの)。
    var outstanding: Int { pressure.outstanding }
    /// 抱えた枚数の最大。**背圧が効いたことを検査から見るための目印。**
    var peakOutstanding: Int { pressure.peak }
    /// 頼まれた総数。
    private(set) var requested = 0
    /// この行き先への書き込みが、まだ走っているか控えているか。**控えが残らないことを検査から
    /// 見るための目印。**
    static func isBusy(_ path: String) -> Bool { lanes.isBusy(destination(of: path)) }
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
    ///
    /// - Parameter slot: 決着を置く器。`nil` ならこの係の器 (``takeOutcome()``)。**数え方の
    ///   違う書き込みを分けて置くためにある** — 1 度きりの `save()` と流れで書く連番
    ///   (``FrameRecorder``・[#1626])。
    ///
    /// [#1626]: https://github.com/mokume-metal/mokume/issues/1626
    func write(_ image: DisplayImage, to path: String, settlingInto slot: OutcomeSlot? = nil) {
        // 背圧。ここで待つのは main actor なので、フレームが遅くなる代わりに
        // 抱える枚数は上限を超えない
        pressure.take()
        requested += 1

        let url = URL(fileURLWithPath: path)
        let release = pressure.release
        let lastOutcome = slot ?? lastOutcome
        let path = path
        let encode = encode
        // **同じ行き先へは 1 本ずつ書き、書いている間に頼まれたものは最後の 1 つを残して
        // 畳む** (#1627)。畳まれた頼みは書かずに枠を返す — 後に頼んだ絵が残るので、書く
        // 必要が無い
        let destination = Self.destination(of: path)
        Self.lanes.enqueue(destination, drop: { release() }) {
            // **結果は枠を返す前に置く。** 背圧で待っていた側は、返ってきた時点で
            // 少なくとも 1 つの結果が置かれていると当てにできる
            do {
                try FileManager.default.createDirectory(
                    at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try encode(image, url)
                lastOutcome.succeed()
            } catch {
                lastOutcome.fail("Could not write \(path): \(error)", at: destination)
            }
            release()
        }
    }

    /// 同じファイルを指す綴りを 1 つに揃えた、行き先の名前 ([#1627])。
    ///
    /// 揃えるのは 3 つ — `..` と `.` (綴りの上の同一)、途中のシンボリックリンク (`/tmp` と
    /// `/private/tmp`)、大文字と小文字と Unicode の正規化 (ボリュームが区別しないとき。
    /// 既定の APFS は区別しない)。まだ無いファイルを指すことが多いので、在るところまで
    /// 遡って確かめる。
    ///
    /// [#1627]: https://github.com/mokume-metal/mokume/issues/1627
    nonisolated static func destination(of path: String) -> String {
        let url = URL(fileURLWithPath: path).standardizedFileURL
        // 在るところまで遡り、そこだけリンクを解く (無いものは解けない)。残りは綴りのまま継ぐ
        var existing = url
        var rest: [String] = []
        while !FileManager.default.fileExists(atPath: existing.path), existing.path != "/" {
            rest.insert(existing.lastPathComponent, at: 0)
            existing = existing.deletingLastPathComponent()
        }
        let resolved = rest.reduce(existing.resolvingSymlinksInPath()) {
            $0.appendingPathComponent($1)
        }
        let caseSensitive =
            (try? existing.resourceValues(forKeys: [.volumeSupportsCaseSensitiveNamesKey]))?
            .volumeSupportsCaseSensitiveNames ?? true
        let name = resolved.path.precomposedStringWithCanonicalMapping
        return caseSensitive ? name : name.lowercased()
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

    /// 前に取り出してから決着した書き込みの結果を取り出す (転んだものがあれば書き損じ・``OutcomeSlot``)。
    /// **取り出したら消える。**
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

/// 行き先ごとに書き込みを 1 本ずつ走らせ、**書いている間に頼まれたものは最後の 1 つに畳む。**
/// 違う行き先どうしは待ち合わない。
///
/// 行き先ごとに持つのは、書いている仕事が在るかと、次に書く控え 1 つだけである。書いている
/// 間に頼まれた仕事は控えを置き換え、置き換えられた仕事は書かずに `drop` を呼ぶ (背圧の枠を
/// 返す)。書き終えた仕事は控えがあればそれを書き、無ければ行き先ごと消える — 控えは走って
/// いる行き先の数までしか伸びない。
///
/// **待たせない** ([#1627] の反証)。後ろに並べて待たせると、同じ行き先への頼みが 1 つずつ
/// 背圧の枠を持ったまま待ち、フレームの速さが 1 枚を書く時間で決まる。1 本返らない仕事が
/// あると、その後ろに並んだ頼みで枠が埋まり、頼む側 (main actor) が止まる。畳めば 1 つの
/// 行き先が持つ枠は高々 2 つである。
///
/// [#1627]: https://github.com/mokume-metal/mokume/issues/1627
nonisolated final class WriteLanes: Sendable {
    /// 1 つの頼み。書く仕事と、書かずに畳まれたときに呼ぶもの。
    struct Job: Sendable {
        let work: @Sendable () -> Void
        let drop: @Sendable () -> Void
    }

    /// 書いている行き先ごとの、次に書く控え。**鍵が在ることが「書いている」を表す。**
    private let lanes = Mutex<[String: Job?]>([:])

    /// `work` を走らせる。同じ行き先を書いている最中なら、控えを置き換えて返る。**待たない。**
    func enqueue(
        _ destination: String, drop: @escaping @Sendable () -> Void,
        _ work: @escaping @Sendable () -> Void
    ) {
        let job = Job(work: work, drop: drop)
        let (start, superseded): (Job?, Job?) = lanes.withLock { lanes in
            guard let pending = lanes[destination] else {
                lanes[destination] = .some(nil)
                return (job, nil)
            }
            lanes[destination] = job
            return (nil, pending)
        }
        // **錠の外で呼ぶ。** 畳んだ頼みの後始末 (枠を返す) は錠と無関係である
        superseded?.drop()
        guard let start else { return }
        Task.detached(priority: .utility) { [self] in
            var next: Job? = start
            while let job = next {
                job.work()
                next = lanes.withLock { lanes in
                    // 控えがあれば取り出して続けて書き、無ければ行き先ごと消す
                    guard let pending = lanes[destination] ?? nil else {
                        lanes[destination] = nil
                        return nil
                    }
                    lanes[destination] = .some(nil)
                    return pending
                }
            }
        }
    }

    /// この行き先を書いているか、控えているか。
    func isBusy(_ destination: String) -> Bool { lanes.withLock { $0[destination] != nil } }
}

/// 書き込み 1 つの決着。
nonisolated enum WriteOutcome: Equatable, Sendable {
    /// 書けた。
    case succeeded
    /// 書けなかった。**同じ間に転んだ全部を、転んだ順に持つ** (``OutcomeSlot``・[#1709])。
    ///
    /// [#1709]: https://github.com/mokume-metal/mokume/issues/1709
    case failed([WriteFailure])

    /// 書けなかった理由。書けたなら `nil`。幾つかあるときは並べて 1 つにする。
    var failure: String? {
        let reasons = failures.map(\.reason)
        return reasons.isEmpty ? nil : reasons.joined(separator: " / ")
    }

    /// 書けなかった 1 枚ずつ。書けたなら空。
    var failures: [WriteFailure] {
        guard case .failed(let failures) = self else { return [] }
        return failures
    }
}

/// 書けなかった 1 枚。**行き先を持つ** — 名乗りは行き先ごとに 1 度である
/// (``FrameRecorder``・[#1709])。
///
/// [#1709]: https://github.com/mokume-metal/mokume/issues/1709
nonisolated struct WriteFailure: Equatable, Sendable {
    /// 同じファイルを指す綴りを揃えた行き先 (``FrameWriter/destination(of:)``)。
    let destination: String
    /// 名乗る文面。
    let reason: String
}

/// 隔離の外から書かれ、main actor から読まれる、前に取り出してから決着した結果。
///
/// **成功も置く** ([#1272])。失敗だけを置く器だと、取り出して空だったときに
/// 「書けた」と「まだ決着していない」を分けられず、後者を順調と数えてしまう。
///
/// **読まれていない書き損じは、後の成功で消さない** ([#1626])。同じ間に決着したものの
/// どれかが転んでいれば、取り出すのは書き損じである。成功で上書きすると、同じフレームに
/// 頼んだ 2 枚 (`save` を 2 つ・連番と `save`) の片方が転んでも、後に決着したほうが書けて
/// いれば誰も名乗らず、書き出しの穴 (``FrameRecorder/hasFailedToWrite``) も立たない。
///
/// 錠そのもの (`Mutex`) は複製できないので、閉じた先の仕事へ渡すには参照になる器が要る。
/// **escape hatch は使わない** ([ADR-0010] 決定 3) — 中身が錠で守られていることを
/// 型として示す。
///
/// [#1272]: https://github.com/mokume-metal/mokume/issues/1272
/// [ADR-0010]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0010-concurrency-model.md
nonisolated final class OutcomeSlot: Sendable {
    private let value = Mutex<WriteOutcome?>(nil)

    /// 書けたことを置く。**まだ読まれていない書き損じは上書きしない。**
    func succeed() {
        value.withLock { stored in
            if case .failed = stored { return }
            stored = .succeeded
        }
    }

    /// 書き損じを置く。**まだ読まれていない書き損じに足す。**
    ///
    /// 書き損じどうしで上書きしない ([#1709])。後から来たものが前を消すと、同じ取り出しの
    /// 間に違う行き先で 2 枚転んだとき、前の 1 枚が名乗られずに消える。溜まるのは取り出す
    /// 間に決着した数までで、それは抱える枚数の上限 (背圧) で抑えられている。
    ///
    /// - Parameters:
    ///   - message: 名乗る文面。
    ///   - destination: 行き先 (``WriteFailure/destination``)。
    ///
    /// [#1709]: https://github.com/mokume-metal/mokume/issues/1709
    func fail(_ message: String, at destination: String) {
        let failure = WriteFailure(destination: destination, reason: message)
        value.withLock { stored in
            stored = .failed((stored?.failures ?? []) + [failure])
        }
    }

    /// 置かれているものを取り出す。**取り出したら消える。**
    func take() -> WriteOutcome? {
        value.withLock { stored in
            defer { stored = nil }
            return stored
        }
    }
}
