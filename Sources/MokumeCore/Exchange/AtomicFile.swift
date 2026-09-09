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

    /// 中身を原子的に置く。途中のディレクトリは必要なら作る。
    package static func write(_ data: Data, to url: URL) throws {
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
