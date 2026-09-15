// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation

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
/// `SIGTERM` の受け口を持たず即座に終わるので、見張りの差し替えのたびに起こりうる。消すのは
/// **持ち主がもう居ないと言い切れるもの**だけで、重なっている別の世代が書いている途中の
/// ものには触れない。一覧を引くのはプロセスごと・名前ごとに 1 度だけにしてある — 観測の列は
/// 毎フレーム書くので、書くたびに引くとその分だけ撮影が遅れる。
///
/// [#1150]: https://github.com/mokume-metal/mokume/pull/1150
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
    /// 静的に持つ形は ``ColorSurface`` と ``NumberSurface`` に前例がある。パッケージの
    /// 既定隔離が main actor なので (ADR-0010 決定 1)、共有しても競合しない。
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
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        sweepAbandonedTemporaries(of: url)
        sequence += 1
        let temporary = temporaryURL(for: url, writer: getpid(), sequence: sequence)
        do {
            try body(temporary)
            // 置換は 1 回の syscall で済ませる。先に消してから rename すると、
            // その隙間に読み手が「ファイルが無い」状態を見る
            _ = try FileManager.default.replaceItemAt(url, withItemAt: temporary)
        } catch {
            // **自分の分は自分で消す。** 名前が書き込みごとに違うので、誰も上書きしない
            try? FileManager.default.removeItem(at: temporary)
            throw error
        }
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
    static func writer(ofTemporary name: String, for url: URL) -> pid_t? {
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
    private static func sweepAbandonedTemporaries(of url: URL) {
        guard swept.insert(url).inserted else { return }
        let directory = url.deletingLastPathComponent()
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        let me = getpid()
        for name in names {
            guard let writer = writer(ofTemporary: name, for: url), writer != me,
                !isRunning(writer)
            else { continue }
            try? FileManager.default.removeItem(at: directory.appendingPathComponent(name))
        }
    }

    /// そのプロセスがまだ居るか。**確かめられなければ居ることにする** — 消してよいのは、
    /// 持ち主がもう居ないと言い切れるものだけである。
    ///
    /// 合図 0 は何も送らず、宛先が在るかだけを問う。他の利用者のプロセスは `EPERM` で
    /// 返るが、それも「居る」である。
    static func isRunning(_ pid: pid_t) -> Bool {
        // **宛先を確かめてから問う。** 0 以下は自分のプロセスグループや全体を指す
        guard pid > 0 else { return true }
        return kill(pid, 0) == 0 || errno != ESRCH
    }

    /// 消す。無ければ何もしない。
    static func remove(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
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
                "Could not place \(what) (\(url.path)): \(error.localizedDescription)"
                    + " — further failures at the same place will not be reported")
            return false
        }
    }

    /// その置き場所の失敗を既に名乗ったか。**検査が読む。**
    static func hasWarned(about url: URL) -> Bool { failures.hasWarned(url) }

    /// その置き場所の失敗で出した文面。**検査が文言を読む。**
    static func warning(about url: URL) -> String? { failures.message(for: url) }
}
