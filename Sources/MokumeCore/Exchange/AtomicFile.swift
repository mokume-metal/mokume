// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation
import MokumeDiagnostics

/// 読み手が書きかけを掴まないように書く ([ADR-0018] 決定 3)。
///
/// 同じディレクトリの一時ファイルへ書いてから `rename` で所定の名前にする。
/// `rename(2)` は同一ボリューム内で不可分なので、読み手から見えるのは「前の内容」か
/// 「新しい内容」のどちらかだけになる。**別のディレクトリの一時ファイルからでは
/// この保証が無い** (ボリュームをまたぐとコピーになる) ので、必ず隣に作る。
///
/// ## 一時ファイルの名前は書き込みごとに変える
///
/// 名前は `.<名前>.<pid>-<連番>.tmp`。**かつては `.<名前>.tmp` に固定していた**が、2 つの
/// プロセスが同じ名前へ同時に書くと、後から作った側が先に作った側の一時ファイルを上書きして
/// 持ち去り、先の側の置く段が「一時ファイルが無い」で投げた。見張りは切り替えの瞬間だけ
/// 2 世代を重ねる ([#1150]) のでそこで起き、手元の 2 プロセスの実測では書き込みの 4 割強が
/// 失敗した ([#1198])。読み手から見た不可分性はその頃も保たれていて、壊れていたのは書き手の
/// 側である。
///
/// - **pid を入れる**のは、落ちた書き手の残りを片付けるときに持ち主の生死を引くため
/// - **連番を足す**のは、同じプロセスの中で書き込みが入れ子になっても名前が割れないため
///
/// ## 残った一時ファイルは誰が片付けるか
///
/// **置けなかった分は、書いた側がその場で消す。** 名前が書き込みごとに違うので誰も上書き
/// しない — 残せば、そのまま溜まる。
///
/// **書いている途中に落とされた書き手の分は、次に同じ名前を書くプロセスが消す。** スケッチは
/// `SIGTERM` を受けると後始末を済ませてから終わるが ([#1219])、見張りの差し替えは 3 秒で
/// 待つのをやめて `SIGKILL` へ進むので、保存のたびに起こりうる。消すのは
/// **持ち主がもう居ないと言い切れるもの**だけで、重なっている別の世代が書いている途中の
/// ものには触れない。一覧を引くのはプロセスごと・名前ごとに 1 度だけにしてある — 観測の列は
/// 毎フレーム書くので、書くたびに引くとその分だけ撮影が遅れる。
///
/// [#1150]: https://github.com/mokume-metal/mokume/pull/1150
/// [#1219]: https://github.com/mokume-metal/mokume/issues/1219
/// [#1198]: https://github.com/mokume-metal/mokume/issues/1198
///
/// ## JSON を置く口は 2 つで、名前が失敗の扱いを決める
///
/// **`throws` を選べるのは判断が呼び手にあるときだけ**にしてある。かつては同じ処理が
/// 8 箇所にあり、`try?` で黙って捨てる・`Diagnostics.warn` で名乗る・`throws` で投げるの
/// 3 通りが混ざっていた ([#989])。投げていた 2 つのうち片方は呼び手が `try?` で完全に
/// 握り潰しており、**目録が書けなかったことは標準エラーにも応答にも現れなかった**。
///
/// 入口が名前で分かれていれば、書く側は「呼び手に判断があるか」だけを決めればよく、
/// `try?` を選ぶ余地が残らない。
///
/// [ADR-0018]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0018-observation-and-control-surface.md
/// [#989]: https://github.com/mokume-metal/mokume/issues/989
package enum AtomicFile {
    /// 置けなかったことを 1 度だけ名乗るための控え。
    ///
    /// **鍵は置き場所。** 面ごとに 1 度ずつ言えば足りる。言い続けないのは、つまみを
    /// ドラッグしている間のように**入力のたびに書く経路がある**ためで
    /// (``RemoteParams``)、そこで毎回言うと標準エラーが流れて他の注意が読めなくなる。
    ///
    /// 静的に持つのは、書く口に持ち主の面が無いからである。この型は隔離を外していない (パッケージの
    /// 既定隔離の main actor・ADR-0010 決定 1) ので、共有しても競合しない。
    /// 隔離の外から呼ばれる口の控えは、`Mutex` で守る `SharedWarningLog` に置く
    /// (`NumberValues`・`ColorValues`・`PaletteValues`・#2389)。ただし鍵が**値を持たない有限の enum**
    /// の口に限る — ここの鍵のような置き場所 (`URL`) は数に上限が無いので、`SharedWarningLog` に
    /// 置かない (公開した鍵を返さないため)。
    private static var failures = WarningLog<URL>()

    /// 一時ファイルの名前に足す連番。**共有しても競合しない** (``failures`` と同じ理由)。
    private static var sequence = 0

    /// 落とされた書き手の一時ファイルを、既に片付けた置き場所。
    ///
    /// 控えるのは高々名前の種類の数 (目録・撮った絵の番号・つまみの状態など) で、書くたびには
    /// 増えない。
    private static var swept = Set<URL>()

    /// 中身を原子的に置く。途中のディレクトリは必要なら作る。
    package static func write(_ data: Data, to url: URL) throws {
        try write(to: url) { try data.write(to: $0) }
    }

    /// 書き手にファイルを作らせて、出来上がりを原子的に置く。
    ///
    /// URL にしか書けない道具 (画像の書き出しなど) を、同じ規約に乗せるための入口。
    /// ``write(_:to:)`` もここを通るので、一時ファイルの名前と後始末は 1 か所で決まる。
    static func write(to url: URL, using body: (URL) throws -> Void) throws {
        try reserve(url).place(using: body)
    }

    /// 置く場所と一時ファイルの名前を決めた、これから置く 1 回。**隔離の外へ渡せる。**
    ///
    /// 準備 (ディレクトリを作る・断る・落とされた書き手の片付け・連番) は静的な状態に触るので main actor で
    /// 済ませ、**中身を作って置き換える段 (``place(using:)``) だけを隔離の外で走らせられる**。置き方
    /// (一時ファイルへ書いて 1 回の置き換え) は同期の ``write(to:using:)`` と同じ 1 つで、裏で
    /// 走らせても読み手から見えるのは前の中身か新しい中身だけである ([#2381])。
    ///
    /// [#2381]: https://github.com/mokume-metal/mokume/issues/2381
    nonisolated struct Placement: Sendable {
        let url: URL
        let temporary: URL

        /// 書き手にファイルを作らせて、出来上がりを原子的に置く。**呼んだ場所で走る** (隔離の外でよい)。
        func place(using body: (URL) throws -> Void) throws {
            do {
                try body(temporary)
                // 置換は 1 回の syscall で済ませる。先に消してから rename すると、
                // その隙間に読み手が「ファイルが無い」状態を見る
                // 本体を走らせている間に置かれたものも見る。見てから置き換えるまでの窓は縮めるだけで、
                // ゼロにはならない (``AtomicFile/refuseDirectory(_:)``)
                try AtomicFile.refuseDirectory(url)
                _ = try FileManager.default.replaceItemAt(url, withItemAt: temporary)
            } catch {
                // **自分の分は自分で消す。** 名前が書き込みごとに違うので、誰も上書きしない
                try? FileManager.default.removeItem(at: temporary)
                throw error
            }
        }
    }

    /// 置く準備をする。途中のディレクトリを作り、書く先がディレクトリなら断り、一時ファイルの名前を決める。
    ///
    /// **書く先がディレクトリなら置かない** (本体を走らせる前に断る)。`replaceItemAt` は行き先の種類を
    /// 見ず、ディレクトリを中身ごと消してファイルに置き換える (#2859)
    static func reserve(_ url: URL) throws -> Placement {
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try refuseDirectory(url)
        sweepAbandonedTemporaries(of: url)
        sequence += 1
        return Placement(
            url: url, temporary: temporaryURL(for: url, writer: getpid(), sequence: sequence))
    }

    /// 書く先がディレクトリなら、`EISDIR` (`Is a directory`) で断る。
    ///
    /// **symlink は辿って見る (`stat`)。** 辿った先がディレクトリなら、置かない向きに倒す。宛先の無い
    /// symlink は辿れない (`stat` が失敗する) ので断らず、そのあとの置き方に任せる (従来どおり)。
    ///
    /// **窓が残る。** 見てから `replaceItemAt` までは別の syscall なので、その間に別の主体が同じ
    /// 場所へディレクトリを置けば、いままでどおり置き換わる。`rename(2)` を直に呼べば窓は閉じる
    /// (ファイルからディレクトリへの `rename` は `EISDIR` で原子的に失敗する) が、**既存のファイルへ
    /// 置くときの属性が変わる**: 実測では `replaceItemAt` は既存のファイルの権限 (0640)・拡張属性・
    /// 作成日時を新しい中身へ引き継ぎ、`rename(2)` はそのどれも引き継がず、権限は一時ファイルの
    /// 既定 (0644) になり、拡張属性は消える。ファイル・無い場合の振る舞いを変えない (#2859 の完了条件 4)
    /// ので、窓を狭める直前の検査にとどめた。
    nonisolated fileprivate static func refuseDirectory(_ url: URL) throws {
        guard isDirectory(url, following: true) else { return }
        throw POSIXError(.EISDIR)
    }

    /// その場所がディレクトリか。**消す・置き換える前に、中身ごと失う相手でないかを見るのに使う**
    /// (``write(to:using:)``・``remove(_:)``・`MovieFile`)。
    ///
    /// - Parameter following: symlink を辿るか (`stat`)。辿らなければ symlink 自身を見る (`lstat`) —
    ///   消す側は symlink を外すだけで指す先は壊さないので辿らず、置き換える側 (`replaceItemAt`) は
    ///   辿った先を見る。
    nonisolated static func isDirectory(_ url: URL, following: Bool) -> Bool {
        var status = stat()
        let found = following ? stat(url.path, &status) : lstat(url.path, &status)
        return found == 0 && status.st_mode & S_IFMT == S_IFDIR
    }

    /// 一時ファイルの場所。**置き場所の隣に作る** (冒頭の `rename(2)` の理由)。
    static func temporaryURL(for url: URL, writer: pid_t, sequence: Int) -> URL {
        url.deletingLastPathComponent().appendingPathComponent(
            ".\(url.lastPathComponent).\(writer)-\(sequence).tmp", isDirectory: false)
    }

    /// 一時ファイルの名前から、書いたプロセスの番号を引く。
    ///
    /// - Returns: その置き場所の一時ファイルでなければ `nil`。**名前の形が違うものは
    ///   片付けの対象にしない** — 誰が置いたか分からないものは消さない。
    nonisolated static func writer(ofTemporary name: String, for url: URL) -> pid_t? {
        let prefix = ".\(url.lastPathComponent)."
        let suffix = ".tmp"
        guard name.count > prefix.count + suffix.count, name.hasPrefix(prefix),
            name.hasSuffix(suffix)
        else { return nil }
        let parts = name.dropFirst(prefix.count).dropLast(suffix.count)
            .split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 2, let writer = pid_t(parts[0]), writer > 0, Int(parts[1]) != nil
        else { return nil }
        return writer
    }

    /// 書いている途中に落とされた書き手の一時ファイルを消す。**プロセスごと・名前ごとに 1 度だけ。**
    ///
    /// **呼んだ糸が読むのは最初の ``syncSweepBudget`` 件まで。** 残りは裏の列で続ける
    /// ([#3176](https://github.com/mokume-metal/mokume/issues/3176))。ここは `reserve` から main で
    /// 同期に呼ばれ、置き場所のディレクトリを全件引く。`$TMPDIR` のように物の溜まった所 (14 万件) だと、
    /// その 1 回が約 1 秒、窓の最初の枚を詰まらせた。
    private static func sweepAbandonedTemporaries(of url: URL) {
        guard swept.insert(url).inserted else { return }
        guard let rest = beginSweep(of: url, budget: syncSweepBudget) else { return }
        sweepQueue.async { rest.finish() }
    }

    /// 呼んだ糸で片付ける件数の上限。**小さなディレクトリ (今の区画はすべてここ) は、戻る前に片付け終わる**
    /// ので、書いた直後に残りを読む検査も、従来の振る舞いのままである。検査だけが下げる。
    static var syncSweepBudget = 1024

    /// 裏で続ける片付けを走らせる列。直列にするのは、大きなディレクトリを名前ごとに引き直す呼び手
    /// (``FrameObserver`` の枚ごとの名前) の読み出しが、並んで機械を占めないため。
    static let sweepQueue = DispatchQueue(label: "mokume.atomic-file.sweep", qos: .utility)

    /// 裏の片付けが済むまで待つ。**検査だけが呼ぶ。**
    static func settleSweeps() { sweepQueue.sync {} }

    /// 片付けを始める。最初の `budget` 件までを呼んだ糸で読み、読み切れなければ続きを返す。
    ///
    /// - Returns: 読み切ったら `nil`。続きがあれば、その続きを ``Sweep/finish()`` で終えられる。
    nonisolated static func beginSweep(of url: URL, budget: Int) -> Sweep? {
        guard let sweep = Sweep(of: url, me: getpid()) else { return nil }
        return sweep.read(upTo: budget) ? nil : sweep
    }

    /// ディレクトリを `readdir` で 1 件ずつ見て、落とされた書き手の一時ファイルを消す途中の状態。
    ///
    /// **名前の文字列は、`.…tmp` の形をしたものだけ作る** — 全件分を作ると、`contentsOfDirectory` は
    /// 14 万件で約 340 ms、名前の頭と尻を先に見る読み方は約 59 ms だった (どちらも件数に比例する。呼んだ糸の
    /// 上限を決めているのは ``AtomicFile/syncSweepBudget`` である)。消す条件は変えない: 持ち主の名前の形を
    /// 満たし、自分のものでなく、もう居ないと言い切れるものだけ。
    ///
    /// 呼んだ糸と裏の列が順に使う (同時には使わない) ので、`@unchecked Sendable` で足りる。
    nonisolated final class Sweep: @unchecked Sendable {
        private let url: URL
        private let directory: URL
        private let me: pid_t
        private var handle: UnsafeMutablePointer<DIR>?
        /// ここまでに読んだ件数。**検査が、呼んだ糸の読みに上限があることを見る。**
        private(set) var entriesRead = 0

        init?(of url: URL, me: pid_t) {
            let directory = url.deletingLastPathComponent()
            guard let handle = opendir(directory.path) else { return nil }
            self.url = url
            self.directory = directory
            self.me = me
            self.handle = handle
        }

        deinit { if let handle { closedir(handle) } }

        /// 最大 `limit` 件を読んで片付ける。
        ///
        /// - Returns: ディレクトリを読み切ったか。
        func read(upTo limit: Int) -> Bool {
            guard let handle else { return true }
            var remaining = limit
            while remaining > 0 {
                guard let entry = readdir(handle) else {
                    closedir(handle)
                    self.handle = nil
                    return true
                }
                remaining -= 1
                entriesRead += 1
                visit(entry)
            }
            return false
        }

        /// 残りを読み切る。
        func finish() { _ = read(upTo: .max) }

        private func visit(_ entry: UnsafeMutablePointer<dirent>) {
            let length = Int(entry.pointee.d_namlen)
            // `.<名前>.<pid>-<連番>.tmp` は、点で始まり `.tmp` で終わる。それ以外は文字列にしない
            let name: String? = withUnsafePointer(to: &entry.pointee.d_name) {
                $0.withMemoryRebound(to: UInt8.self, capacity: length + 1) { bytes in
                    guard length > 5, bytes[0] == UInt8(ascii: "."),
                        bytes[length - 4] == UInt8(ascii: "."), bytes[length - 3] == UInt8(ascii: "t"),
                        bytes[length - 2] == UInt8(ascii: "m"), bytes[length - 1] == UInt8(ascii: "p")
                    else { return nil }
                    return String(decoding: UnsafeBufferPointer(start: bytes, count: length), as: UTF8.self)
                }
            }
            guard let name, let writer = AtomicFile.writer(ofTemporary: name, for: url), writer != me,
                !AtomicFile.isRunning(writer)
            else { return }
            try? FileManager.default.removeItem(at: directory.appendingPathComponent(name))
        }
    }

    /// そのプロセスがまだ居るか。**確かめられなければ居ることにする** — 消してよいのは、
    /// 持ち主がもう居ないと言い切れるものだけである。
    ///
    /// 合図 0 は何も送らず、宛先が在るかだけを問う。他の利用者のプロセスは `EPERM` で
    /// 返るが、それも「居る」である。
    nonisolated static func isRunning(_ pid: pid_t) -> Bool {
        // **宛先を確かめてから問う。** 0 以下は自分のプロセスグループや全体を指す
        guard pid > 0 else { return true }
        return kill(pid, 0) == 0 || errno != ESRCH
    }

    /// 消す。無ければ何もしない。
    ///
    /// **ディレクトリは消さずに残す** (symlink は外すだけで、指す先は壊さない)。`removeItem` は
    /// ディレクトリを中身ごと消すので、置き場の名前をたまたまディレクトリが使っていると、利用者の
    /// ものが黙って消える ([#2859](https://github.com/mokume-metal/mokume/issues/2859))。
    /// **名乗らない** — 消せなかったことはその後の書き込みが同じ場所で `Is a directory` と
    /// 1 度名乗る (``publishJSON(_:to:_:)``)。ここで言うと、掃除のたびに同じ場所を言い直す。
    ///
    /// - Returns: 消した (または無かった) なら `true`。ディレクトリなので残したなら `false`。
    @discardableResult
    static func remove(_ url: URL) -> Bool {
        guard !isDirectory(url, following: false) else { return false }
        try? FileManager.default.removeItem(at: url)
        return true
    }

    /// JSON を組んで原子的に置く。**判断が呼び手にあるときだけこちら。**
    ///
    /// **書き方はここに固定する。** `.sortedKeys` を付けないと `JSONEncoder` は辞書の
    /// 走査順で書くので、**並びはプロセスごとに変わる** — 手書きの `encode(to:)` が
    /// `CodingKeys` の順に並べていても、届く並びはその順ではない ([#854] の実測)。面ごとに
    /// 設定が割れていた頃は、応答の鍵の並びが面ごとに違ううえ、どの面も安定していなかった。
    ///
    /// [#854]: https://github.com/mokume-metal/mokume/issues/854
    package static func writeJSON(_ value: some Encodable, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes, .sortedKeys]
        try write(encoder.encode(value), to: url)
    }

    /// JSON を組んで原子的に置く。**置けなければ 1 度だけ名乗って捨てる。**
    ///
    /// 区画へ応答を置く経路はほぼこちらである — 置けなかったことを呼び手が判断できる
    /// 場面が無いためで、できるのは「名乗って続ける」だけである。
    ///
    /// - Parameter what: 置こうとしたものの名前 (「合わせた値」など)。文面の組み立ては
    ///   ここが持つので、呼ぶ側は短い名詞だけを渡す。
    /// - Returns: 置けたか。**捨てたかどうかで続きが変わる呼び手が居る** — 応答を置けた
    ///   ときだけ識別子を控える (``RemoteParams``)、数を進める (``ParamStore``) など。
    @discardableResult
    package static func publishJSON(_ value: some Encodable, to url: URL, _ what: String) -> Bool {
        do {
            try writeJSON(value, to: url)
            return true
        } catch {
            failures.warnOnce(
                url,
                "Could not place \(what) (\(url.path)): \(Diagnostics.reason(error))"
                    + " — further failures at the same place will not be reported")
            return false
        }
    }

    /// その置き場所の失敗を既に名乗ったか。**検査が読む。**
    static func hasWarned(about url: URL) -> Bool { failures.hasWarned(url) }

    /// その置き場所の失敗で出した文面。**検査が文言を読む。**
    static func warning(about url: URL) -> String? { failures.message(for: url) }
}
