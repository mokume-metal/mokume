// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation
import MokumeDiagnostics

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
    /// 持ち出した組の置き場 (`.mokume/kept`・[#2618](https://github.com/mokume-metal/mokume/issues/2618))。
    /// 持ち出しを頼まれるまで作らない。
    let keptDirectory: URL
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

    /// 区画の隣の `kept`。区画を外から渡したときも、持ち出しは同じ `.mokume` の下に置く。
    static func keptDirectory(beside facet: URL) -> URL {
        facet.deletingLastPathComponent().appendingPathComponent(keptFacetName, isDirectory: true)
    }

    /// 持ち出しの置き場の名前 (`.mokume/kept`)。
    static let keptFacetName = "kept"

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

    init(directory: URL, writesInBackground: Bool = false, keptDirectory: URL? = nil) {
        self.directory = directory
        self.keptDirectory = keptDirectory ?? Self.keptDirectory(beside: directory)
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
    /// 逆にすると、古い目録が指す絵だけが消えた状態を読み手が掴むウィンドウが空く。目録が
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
            outcome.fail(Self.reason(placing: error, at: url), at: url.path)
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
                outcome.fail(Self.reason(placing: error, at: url), at: url.path)
            }
            release()
        }
        return name
    }

    /// 絵を置けなかった事情の文。**書く失敗の口 (``Diagnostics/writingPosixReason(_:at:)``) を先に通す** —
    /// 置き換えて書く (`.atomic`) と、見てから置き換えるまでの間に行き先がディレクトリになった失敗は、
    /// 下の番号が ENOENT になり、そのまま言うと在るものを無いと言う (#2839)。`reason` でなく
    /// `failureText` に落とすのは、`Could not take the image: <事情>` に埋まる文で、`reason` の型名の前置きが
    /// `ImageWriteFailure` の既存の文面を変えるため (#3211)。
    nonisolated private static func reason(placing error: any Error, at url: URL) -> String {
        Diagnostics.writingPosixReason(error, at: url) ?? Diagnostics.failureText(error)
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

    // MARK: - 持ち出す ([#2618])

    /// 書き途中の置き場の名前の尾。記録の書き途中 (``ReplayClaim/partialSuffix``) と同じ綴り。
    static let keptPartialSuffix = ReplayClaim.partialSuffix
    /// 持ち出した絵の名前。
    static let keptImageName = "frame.png"
    /// 持ち出した目録の名前。
    static let keptManifestName = "kept.json"

    /// 持ち出しのどの段で転ばせるか。**検査だけが立てる** (書き込みの失敗を、置き場を壊さずに起こすため)。
    enum KeepStep: Equatable {
        case image, manifest, rename
    }

    /// 検査が立てる、持ち出しを転ばせる段。走らせる側は立てない。
    var keepFault: KeepStep?

    /// 検査が立てる、完成の名前へ移す直前に呼ぶ手 (確かめてから移すまでの間に名前を置かれる形を作る)。
    /// 走らせる側は立てない。
    var keepWillPlace: (() -> Void)?

    /// 持ち出せなかったことを名乗る警告の頭。持ち出しを頼んだのに持ち出さなかった道は、どれもこの頭で 1 つ名乗る。
    static let notKeptPrefix = "The shot was not kept: "

    /// 区画に置き終えた絵 (`image`) を、目録 (`manifest`) と組にして `.mokume/kept/<id>/` へ持ち出す。
    ///
    /// **置き場の扱いは記録 (``ReplayRecorder``・``ReplayClaim``) の守りに揃える**:
    ///
    /// - **書き途中の名前にプロセス番号を入れる** (`<id>.<pid>.partial/`・記録の `<行き先>.<pid>.partial` と同じ形)。
    ///   絵と目録を置いて同期し、置き終えてから `<id>/` へ移す。途中で転んだら書き途中を残して名乗る
    /// - **完成の印は置き場の名前 (`<id>/`) である。** 目録の `complete` は「置き終えた組のものとして書いた」ことしか
    ///   言わない — 書き途中の置き場の中にも `complete: true` の目録が残りうるので、書き途中の中の目録を読まない
    /// - **片付けてよいのは、名前の形が合い (``ReplayClaim/isPartial(_:of:)``)、持ち主のプロセスがもう居ない
    ///   (``AtomicFile/isRunning(_:)``) か自分の、中身もこの手が置く形 (絵と目録のファイルだけ) の書き途中だけ**。
    ///   中身は `unlink(2)` で 1 つずつ外し、最後に空のフォルダを `rmdir(2)` する — 名前の形だけで選ぶと、たまたま
    ///   同じ形の名前のフォルダが中身ごと消える (記録の [#3943] と同じ理由)。生きている他の実行の書き途中には触れない
    /// - **完成の名前への移しは、既に在れば失敗する改名** (`renamex_np` の `RENAME_EXCL`)。既に在る `<id>` は、空の
    ///   フォルダでも、大文字小文字だけが違う名前 (大文字小文字を区別しないボリューム) でも、上書きも削除もしない。
    ///   書いている間に置かれて改名が断られたら、自分の書き途中をその場で片付けて名乗る。**`RENAME_EXCL` を持たない
    ///   ボリュームでは、確かめてから移すまでの間に置かれた空のフォルダは置き換わりうる** (``placeExclusively(_:at:)``)
    /// - **置き場 (`.mokume/kept`) がシンボリックリンク・ファイルなら、たどらず消さず、持ち出さない**
    ///
    /// どれも「消さない・上書きしない・理由を名乗る」の側に倒す。
    ///
    /// **呼ぶのは区画の書き込みが決着した後、次の要求を拾う前** (``SketchRuntime`` が ``settleWrites(_:)`` の
    /// `.written` の後に呼ぶ)。次の撮影の掃除 (``clearProducts()``) が区画の絵を消すのはその後なので、持ち出す
    /// 絵は必ずこの要求の絵である。
    ///
    /// [#3943]: https://github.com/mokume-metal/mokume/issues/3943
    ///
    /// - Returns: 置けたなら、応答からの相対の置き場 (`../kept/<id>`)。置けなければ `nil` と理由。
    func keep(_ manifest: KeptFrame, image name: String) -> (kept: String?, warning: String?) {
        func refused(_ reason: String) -> (kept: String?, warning: String?) {
            (nil, Self.notKeptPrefix + reason)
        }
        if let reason = KeptFrame.refusal(forDirectoryNamed: manifest.id) { return refused(reason) }
        if let reason = Self.prepareKeptDirectory(keptDirectory) { return refused(reason) }
        let destination = keptDirectory.appendingPathComponent(manifest.id, isDirectory: true)
        // 完成品を指す名前は、壊れた symlink も含めて「在る」と読む (行き先を辿らない)。書く前に断る早道で、
        // 守りそのものは下の `RENAME_EXCL`
        if Self.lexists(destination) {
            return refused("\(destination.path) already exists, and it is not overwritten")
        }
        Self.sweepAbandonedPartials(of: manifest.id, in: keptDirectory)
        let partial = Self.partialURL(of: manifest.id, in: keptDirectory, writer: getpid())
        let files = FileManager.default
        do {
            try files.createDirectory(at: partial, withIntermediateDirectories: false)
            let image = partial.appendingPathComponent(Self.keptImageName)
            if keepFault == .image { throw CocoaError(.fileWriteUnknown) }
            // 同じバイト列を写す (APFS では複製の印だけで済む)。符号化し直さない — 区画の絵と画素も属性も揃う
            try files.copyItem(at: directory.appendingPathComponent(name), to: image)
            try Self.synchronize(image)
            let catalogue = partial.appendingPathComponent(Self.keptManifestName)
            if keepFault == .manifest { throw CocoaError(.fileWriteUnknown) }
            try AtomicFile.writeJSON(manifest, to: catalogue)
            try Self.synchronize(catalogue)
            if keepFault == .rename { throw POSIXError(.EIO) }
            keepWillPlace?()
        } catch {
            return refused(
                "writing \(partial.path) failed, so it is left unfinished: \(Diagnostics.reason(error))")
        }
        do {
            try Self.placeExclusively(partial, at: destination)
        } catch let error as POSIXError where error.code == .EEXIST {
            // 書いている間に `<id>` を置かれた。置かれたものは上書きせず、自分の書き途中はその場で片付ける — 残すと、
            // 次に同じ id を頼んでも完成品が在るかの確かめで先に断るので、片付けまで進まず溜まる
            Self.discardPartial(partial)
            return refused(
                "\(destination.path) already exists (it was placed while the shot was being written), "
                    + "and it is not overwritten")
        } catch {
            return refused(
                "writing \(partial.path) failed, so it is left unfinished: \(Diagnostics.reason(error))")
        }
        return ("../\(Self.keptFacetName)/\(manifest.id)", nil)
    }

    /// 書き途中の置き場 (`<id>.<pid>.partial`)。記録の書き途中 (``ReplayRecorder``) と同じ形。
    static func partialURL(of id: String, in kept: URL, writer: pid_t) -> URL {
        kept.appendingPathComponent("\(id).\(writer)\(keptPartialSuffix)", isDirectory: true)
    }

    /// 置き場 (`.mokume/kept`) を用意する。**シンボリックリンク・ファイルなら、たどらず消さず、理由を返す。**
    ///
    /// 作るのはこの 1 段だけ (親の `.mokume` は区画が在るので在る)。作った直後にも確かめ直す。
    ///
    /// - Returns: 用意できなかった理由。用意できたら `nil`。
    private static func prepareKeptDirectory(_ kept: URL) -> String? {
        if mkdir(kept.path, 0o755) != 0 {
            let code = errno
            if code != EEXIST { return "could not make \(kept.path): \(String(cString: strerror(code)))" }
        }
        guard AtomicFile.isDirectory(kept, following: false) else {
            return "\(kept.path) is not a folder (a symbolic link or a file there is left as it is)"
        }
        return nil
    }

    /// その名前に何か在るか。**リンクはたどらない** (壊れたリンクも「在る」)。
    private static func lexists(_ url: URL) -> Bool {
        var status = stat()
        return lstat(url.path, &status) == 0
    }

    /// 同じ識別子の書き途中のうち、**持ち主がもう居ないか自分の**ものを片付ける。
    ///
    /// 選ぶのは名前の形が合うもの (``ReplayClaim/isPartial(_:of:)``・大文字小文字も区別する) だけで、中身が
    /// この手の置く形でなければ (``discardPartial(_:)``) 残す。生きている他の実行の書き途中には触れない — 観測の
    /// 区画の錠 (``FacetClaim``) は確かめられないとき「持っていることにする」ので、2 つの実行が同時に応えうる。
    private static func sweepAbandonedPartials(of id: String, in kept: URL) {
        let me = getpid()
        let prefix = id + "."
        for entry in (try? FileManager.default.contentsOfDirectory(atPath: kept.path)) ?? []
        where ReplayClaim.isPartial(entry, of: id) {
            let digits = entry.dropFirst(prefix.count).dropLast(keptPartialSuffix.count)
            // pid が使い回されて別のプロセスが持っていると、死んだ回の書き途中でも残り続ける (記録の ``ReplayClaim`` と
            // 同じ限界で、消さない側に倒れる。新しい持ち出しは自分の pid の名前で書くので失敗はしない)
            guard let writer = pid_t(digits), writer == me || !AtomicFile.isRunning(writer) else { continue }
            discardPartial(kept.appendingPathComponent(entry, isDirectory: true))
        }
    }

    /// 書き途中の置き場を 1 つ片付ける。**この手が置く形 (絵と目録の、ふつうのファイルだけ) のときだけ。**
    ///
    /// フォルダ (リンクでないもの) の中身が絵・目録の名前だけなら 1 つずつ `unlink(2)` し、空のフォルダを
    /// `rmdir(2)` する。他の名前が在れば何も消さない。`unlink` はフォルダを消さず、`rmdir` は空でないフォルダを
    /// 消さないので、見てから消すまでの間に中身が増えても、中身ごと消す窓が無い。
    private static func discardPartial(_ partial: URL) {
        guard AtomicFile.isDirectory(partial, following: false),
            let entries = try? FileManager.default.contentsOfDirectory(atPath: partial.path),
            entries.allSatisfy({ [keptImageName, keptManifestName].contains($0) })
        else { return }
        for entry in entries {
            guard AtomicFile.remove(partial.appendingPathComponent(entry)) else { return }
        }
        rmdir(partial.path)
    }

    /// `from` を `to` へ移す。**行き先に在れば断る** (`renamex_np` の `RENAME_EXCL`)。ボリュームが `RENAME_EXCL` を
    /// 持たなければ、在るかを確かめてからの素の `rename(2)` に倒す (`mokume bundle` の置き方と同じ。確かめてから
    /// 移すまでの間は守らない — その間に置かれた空のフォルダは、`rename(2)` が置き換える)。在って断ったときは
    /// `EEXIST` を投げる。
    private static func placeExclusively(_ from: URL, at to: URL) throws {
        if renamex_np(from.path, to.path, UInt32(RENAME_EXCL)) == 0 { return }
        let code = errno
        guard [ENOTSUP, EINVAL, EOPNOTSUPP].contains(code) else {
            throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
        }
        guard !lexists(to) else { throw POSIXError(.EEXIST) }
        guard rename(from.path, to.path) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }

    /// 置いたファイルを同期する (`fsync`)。改名の後に電源が落ちても、完成の名前の下が空のまま残らない。
    private static func synchronize(_ url: URL) throws {
        let handle = try FileHandle(forUpdating: url)
        defer { try? handle.close() }
        try handle.synchronize()
    }
}
