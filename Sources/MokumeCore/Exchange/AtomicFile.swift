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
/// [ADR-0018]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0018-observation-and-control-surface.md
enum AtomicFile {
    /// 中身を原子的に置く。途中のディレクトリは必要なら作る。
    static func write(_ data: Data, to url: URL) throws {
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let temporary = directory.appendingPathComponent(
            ".\(url.lastPathComponent).tmp", isDirectory: false)
        try data.write(to: temporary)
        // 置換は 1 回の syscall で済ませる。先に消してから rename すると、
        // その隙間に読み手が「ファイルが無い」状態を見る
        _ = try FileManager.default.replaceItemAt(url, withItemAt: temporary)
    }

    /// 書き手にファイルを作らせて、出来上がりを原子的に置く。
    ///
    /// URL にしか書けない道具 (画像の書き出しなど) を、同じ規約に乗せるための入口。
    static func write(to url: URL, using body: (URL) throws -> Void) throws {
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let temporary = directory.appendingPathComponent(
            ".\(url.lastPathComponent).tmp", isDirectory: false)
        try body(temporary)
        _ = try FileManager.default.replaceItemAt(url, withItemAt: temporary)
    }

    /// 消す。無ければ何もしない。
    static func remove(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }

    // MARK: - 区画へ JSON を置く

    /// 値を JSON にして原子的に置く。**区画へ置くものはここを通る。**
    ///
    /// ## 形はここが決める
    ///
    /// かつては置く側が銘々 `JSONEncoder` を組んでいて、**同じ規約に乗っている面の
    /// 応答なのに鍵の並びが面ごとに違った** (整列するもの・しないもの・整形すら
    /// しないもの)。差分を取る読み手 — 人も道具も — には効く違いで、しかも
    /// 「なぜここだけ違うのか」に答えられる理由が無かった。
    ///
    /// 並べ替えるのは、**読み手が並びに依存していないから**でもある
    /// ([#992](https://github.com/mokume-metal/mokume/issues/992) で測った — 照合は
    /// すべて集合比較、窓口は `pretty()` で刷り直す)。並びが意味を持つのは人が読むときだけで、
    /// そこでは整列しているほうがよい。
    static func write(json value: some Encodable, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes, .sortedKeys]
        try write(try encoder.encode(value), to: url)
    }

    /// 置き続ける口。**置けなくなったことを 1 度だけ名乗り、また置けたら 1 度だけ名乗る。**
    ///
    /// 投げないのは、呼ぶ側が伝える先を持たないためである — 毎フレーム・毎要求で呼ばれ、
    /// 返り値を読む人が居ない。**だからといって黙って捨てない**。黙ると残るのは
    /// 「触っても効かない」だけで、区画が無いときと見分けが付かなくなる。
    ///
    /// ## なぜ数え方まで畳むのか
    ///
    /// 「置けなくなったら 1 度言う」だけなら呼ぶ側に書けるが、対になる**「回復したら
    /// 0 へ戻す」を落とすと以後 1 度も言わなくなる** (``FrameFailureLog``) — 症状は
    /// [#221](https://github.com/mokume-metal/mokume/issues/221) が塞いだ穴に戻る。
    /// 落としてもコンパイルは通り、検査も通る。
    ///
    /// **差し込むのは主語だけである。** 動詞や語幹を組み立てると、組んだ文のほうが
    /// 壊れる ([#947](https://github.com/mokume-metal/mokume/issues/947) の「頼んた」)。
    ///
    /// - Returns: 置けたら `true`。
    @discardableResult
    static func place(
        json value: some Encodable, to url: URL, naming what: String,
        noting log: inout FrameFailureLog
    ) -> Bool {
        do {
            try write(json: value, to: url)
            if let skipped = log.recovered() {
                Diagnostics.warn("\(what)をまた置けるようになりました (置けなかったのは \(skipped) 回)")
            }
            return true
        } catch {
            if log.note() {
                Diagnostics.warn("\(what)を置けません (\(url.path)): \(error)")
            }
            return false
        }
    }
}
