// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation

/// 観測の区画 (`.mokume/observe`) を見張り、要求に応える。
///
/// ## 有効になる条件はファイルシステムに置く
///
/// **区画のディレクトリがあるときだけ観測が働く。** 要求を出す側がそれを作ることが、
/// そのまま観測の意思表示になる。環境変数を増やさずに済み、面がファイルだけで完結する
/// という [ADR-0018] 決定 1 とも揃う。無ければ何も見ない — 走っているスケッチは
/// 観測の存在を一切払わない。
///
/// ## 要求が無いフレームのコスト
///
/// ``pendingRequest()`` は要求ファイルの最終更新時刻を 1 回見るだけで返る。中身を読むのも、
/// JSON を解くのも、更新されていたときだけである。
///
/// ## 書く順序
///
/// 1 枚でも続けて撮るときでも順序は同じ。**先に前回の成果物を消し、絵を 1 枚ずつ置き、
/// 目録 (`report.json`) を最後に原子的に書く** ([ADR-0018] 決定 3)。読み手は目録の
/// 識別子が一致した時点で、そこに並んだ絵が揃っていると判定してよい。
///
/// **絵を置くのはフレームの外である** ([#2381](https://github.com/mokume-metal/mokume/issues/2381))。
/// 読み戻した絵の PNG の符号化とファイルの置き換えは裏で走り (``enqueueFrame(_:at:)``)、抱える枚数に
/// 上限がある。順序は変わらない — 目録は**全枚の書き込みが決着した後**に書き、置けなかった枚があれば
/// その枚の手前で終え、次の撮影の掃除は前の撮影の決着の後に行う。
///
/// [ADR-0018]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0018-observation-and-control-surface.md
@MainActor
final class FrameObserver {
    /// 撮った絵の名前の頭。
    static let imagePrefix = "frame-"

    /// 撮った順の絵の名前。
    ///
    /// **桁を揃える。** 名前順に並べたときが撮った順になるので、目録を読まずに
    /// ディレクトリを覗いた人も列を取り違えない。
    static func imageFileName(at index: Int) -> String {
        String(format: "%@%03d.png", imagePrefix, index)
    }

    let directory: URL
    private let requests: RequestFile<ObservationRequest>
    private let reportURL: URL

    /// 最終更新時刻を見た回数。要求が無いフレームのコストを検査が測るために持つ。
    var pollCount: Int { requests.pollCount }
    /// 要求ファイルを実際に読んだ回数。
    var readCount: Int { requests.readCount }

    /// 区画があるときだけ作る。**区画の名前は ``StartupReads`` が正典** (#380)。
    static func makeIfEnabled(
        at directory: URL = WorkDirectory.facet(StartupReads.observe.key)
    ) -> FrameObserver? {
        guard WorkDirectory.directoryExists(at: directory) else { return nil }
        return FrameObserver(directory: directory, writesInBackground: true)
    }

    /// 絵の書き込みを、撮り終えた後もフレームの外で続けるか ([#2381])。
    ///
    /// `true` なら、撮り終えても書き込みの決着を待たずにフレームを進め、目録は決着した後のフレームで
    /// 書く。`false` なら、撮り終えたそのフレームの中で決着まで待って目録を書く (書き込み自体は
    /// フレームの外の係が行うが、待つのは main) — **目録が撮り終えたフレームのうちに在る**、同期のころの
    /// 形である。走らせる側 (``makeIfEnabled(at:)``) は `true`、検査が直に作るときの既定は `false`
    /// (撮った直後に目録を読む検査が多い。裏で走る形は専用の検査が見る)。
    ///
    /// [#2381]: https://github.com/mokume-metal/mokume/issues/2381
    let writesInBackground: Bool

    init(directory: URL, writesInBackground: Bool = false) {
        self.directory = directory
        self.writesInBackground = writesInBackground
        self.requests = RequestFile(facet: directory, handover: .rereadsReport)
        self.reportURL = requests.reportURL
    }

    /// まだ応えていない要求があれば返す。規約は ``RequestFile`` が守る。
    ///
    /// **`id` だけ読めた要求も返す** (``PendingRequest/unreadable(id:reason:)``)。撮らずに
    /// ``refuse(id:reason:report:)`` で応える。
    func pendingRequest() -> PendingRequest<ObservationRequest>? {
        requests.pending()
    }

    /// `id` は読めたが解けなかった要求に、**撮らずに**応える ([#2550])。
    ///
    /// 手順は撮れなかった応答と同じで、**前回の成果物を先に消し**、絵を持たない目録に理由を
    /// `warnings` へ載せて書く ([ADR-0018] 決定 3「失敗しても必ず応答する」)。応えないと、型の
    /// 違う値 (`"scale":"0.5"`) を書いた書き手には「走っていない」と見分けが付かない。目録の
    /// 中身 (フレーム・時刻・大きさ) は走らせている側が持つので、`report` で受け取る。
    ///
    /// [#2550]: https://github.com/mokume-metal/mokume/issues/2550
    /// [ADR-0018]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0018-observation-and-control-surface.md
    func refuse(
        id: String, reason: String,
        report: (_ id: String, _ warnings: [String]) -> ObservationReport
    ) {
        clearProducts()
        finish(report(id, ["The request could not be read, so nothing was taken: \(reason)"]))
    }

    /// 前回の成果物を消す。**目録を先に、絵を後に**消す。
    ///
    /// 逆にすると、古い目録が指す絵だけが消えた状態を読み手が掴む窓が空く。目録が
    /// 無ければ、読み手は識別子の一致を待ち続けるだけで済む ([ADR-0018] 決定 3)。
    ///
    /// - Returns: 消した順。**消しながら並べている**ので、検査はこの並びで順序を見られる。
    ///   ディレクトリの書き込みを塞いで観察しようとしても、そのときは目録も絵も等しく
    ///   消せないため順序が現れない。
    ///
    /// **世代は見ない。** 撮り始めは要求を拾えたときだけで、拾えるのは区画の権利
    /// (``FacetClaim``) を持つプロセスだけである。重なっている前の世代が撮っている列を、
    /// 次の世代がここで消すことは起きない ([#1162](https://github.com/mokume-metal/mokume/issues/1162))。
    ///
    /// [ADR-0018]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0018-observation-and-control-surface.md
    @discardableResult
    func clearProducts() -> [URL] {
        // **前の撮影の書き込みが決着してから消す** (古い絵と新しい目録を組にしない・[#2381])。呼び手
        // (``SketchRuntime``) は、決着するまで次の要求を拾わない
        var removed: [URL] = []
        // ディレクトリは消さずに残すので、消した並びには入れない (``AtomicFile/remove(_:)``)
        if AtomicFile.remove(reportURL) { removed.append(reportURL) }
        let names =
            (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        for name in names.sorted() where name.hasPrefix(Self.imagePrefix) && name.hasSuffix(".png")
        {
            let url = directory.appendingPathComponent(name)
            if AtomicFile.remove(url) { removed.append(url) }
        }
        return removed
    }

    // MARK: - 絵を置く (フレームの外)

    /// 頼んだ絵 1 枚と、その書き込みの決着を置く器。
    private struct Write {
        let name: String
        let outcome: OutcomeSlot
    }

    /// 撮っている列の、頼んだ書き込み。**撮り始め (``clearProducts()``) で空になり、全部が決着した
    /// とき (``settleWrites(_:)``) に空になる。**
    private var writes: [Write] = []
    /// 抱える枚数の上限と、終わったものの数え方。**録画の連番と同じ部品** (``FrameWriter``)。
    /// 4K 原寸は 1 枚 33 MB なので、無制限に溜めない — 上限に達したら ``enqueueFrame(_:at:)`` が
    /// 空くまで返らない ([#2381](https://github.com/mokume-metal/mokume/issues/2381))。
    private let pressure = Backpressure()
    private let lanes = WriteLanes()

    /// 抱えた書き込みの数の最大。**背圧が効いたことを検査から見るための目印。**
    var peakPendingWrites: Int { pressure.peak }

    /// 頼んだ書き込みが、まだ決着していないかもしれないか。
    var hasPendingWrites: Bool { !writes.isEmpty }

    /// 絵を 1 枚置くよう頼む。**PNG の符号化とファイルの置き換えは、フレームの外で走る。** 名前を返す。
    ///
    /// 同期にしていた頃は、4K 原寸の 1 枚で撮る間の `advance` が 44.4 ms、うち 40.4 ms が main で走る
    /// PNG の符号化と置き換えだった ([#2381](https://github.com/mokume-metal/mokume/issues/2381))。
    /// 置き方は同期のときと同じ ``AtomicFile`` の 1 つの方法 (``AtomicFile/Placement``) で、読み手から
    /// 見えるのは前の中身か新しい中身だけである。
    ///
    /// **抱える枚数には上限がある。** 上限に達していたら、書き込みが 1 つ終わるまで返らない。
    ///
    /// **決着は ``settleWrites(_:)`` で見る。** 目録 (``finish(_:)``) は全部が決着した後に書く
    /// ([ADR-0018] 決定 3 — 読み手は目録の識別子が一致した時点で絵が揃っていると判定してよい)。
    ///
    /// [ADR-0018]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0018-observation-and-control-surface.md
    func enqueueFrame(_ image: DisplayImage, at index: Int) -> String {
        let name = Self.imageFileName(at: index)
        let url = directory.appendingPathComponent(name)
        let outcome = OutcomeSlot()
        writes.append(Write(name: name, outcome: outcome))
        let placement: AtomicFile.Placement
        do {
            placement = try AtomicFile.reserve(url)
        } catch {
            // 置く準備で転んだ (書く先がディレクトリ・ディレクトリを作れない)。頼まずに決着を置く
            outcome.fail("\(error)", at: url.path)
            return name
        }
        // 背圧。ここで待つのは main actor なので、フレームが遅くなる代わりに抱える枚数は上限を超えない
        pressure.take()
        let release = pressure.release
        lanes.enqueue(url.path, drop: { release() }) {
            // **結果は枠を返す前に置く** (``FrameWriter/write(_:to:settlingInto:)`` と同じ順)
            do {
                try placement.place { try PNGFile.write(image, to: $0) }
                outcome.succeed()
            } catch {
                outcome.fail("\(error)", at: url.path)
            }
            release()
        }
        return name
    }

    /// 頼んだ書き込みの決着。
    enum Settlement: Equatable {
        /// 全部置けた。
        case written
        /// `index` 枚目が置けなかった。`reason` は名乗る文面。**その手前までは置けている。**
        case failed(index: Int, reason: String)
    }

    /// 頼んだ書き込みが全部決着したかを、選んだ待ち方で見る。
    ///
    /// **決着していなければ `nil`** (``Patience/peek`` のとき。呼び直せば続きから見る)。決着したら、
    /// 頼んだ列を空にして結果を返す。1 枚も進まなくなったら (``Backpressure/defaultStallLimitSeconds``)
    /// 諦め、決着していない枚を置けなかったものとして数える。
    func settleWrites(_ patience: Patience) -> Settlement? {
        guard !writes.isEmpty else { return .written }
        guard pressure.drain(patience) else { return nil }
        let settled = writes
        writes = []
        for (index, write) in settled.enumerated() {
            switch write.outcome.take() {
            case .succeeded?:
                continue
            case .failed(let failures)?:
                return .failed(index: index, reason: failures.map(\.reason).joined(separator: " / "))
            case nil:
                return .failed(
                    index: index,
                    reason: "Writing \(write.name) has not finished for "
                        + "\(Int(pressure.stallLimitSeconds)) seconds — no longer waiting for it")
            }
        }
        return .written
    }

    /// 目録を書いて、この要求を終える。
    ///
    /// 応えようとしたことは、**書き込みに失敗しても**記録する。記録しないと同じ要求を
    /// 毎フレーム拾い直し、壊れた書き込み先の上でループになる。
    ///
    /// **投げない。** かつては `throws` だったが、唯一の呼び手 (``SketchRuntime``) が
    /// `try?` で握り潰しており、目録を置けなかったことがどこにも現れなかった。判断の
    /// 余地が呼び手に無い以上、名乗るのは置く側の仕事である
    /// ([#989](https://github.com/mokume-metal/mokume/issues/989))。
    func finish(_ report: ObservationReport) {
        defer { requests.markHandled(report.id) }
        AtomicFile.publishJSON(report, to: reportURL, "the observation catalogue")
    }
}
