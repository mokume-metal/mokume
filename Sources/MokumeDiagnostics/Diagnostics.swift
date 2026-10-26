// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation

/// 基盤層 — 何にも依存しない要素だけを置く ([ADR-0016] 決定 1 の最下層)。
///
/// ライブラリが人へ伝えることを 1 箇所に集める。**素の `print` で書かない** —
/// 出力先はスケッチの標準出力であり、そこはスケッチ自身のものだからである。
///
/// 持っているのは ``warn(_:)`` と、その文面に失敗を埋める ``reason(_:)`` と、言った文面を
/// 次の観測まで溜める ``takeUnreported()`` だけで、段階も分類もまだ無い。**要るものが
/// 分かった時点で足す** ([ADR-0001] 原則 4 / [ADR-0008] 決定 2)。
///
/// [ADR-0001]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0001-founding-principles.md
/// [ADR-0008]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0008-mechanism-needs-demonstrated-harm.md
/// [ADR-0016]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0016-package-structure.md
///
/// **隔離の外からも言える** ([ADR-0010] 決定 4)。フレームの外へ逃がした仕事 —
/// 書き出しや符号化 — も、気付いたことを人へ伝える必要がある。持っているのは
/// 標準エラーへの 1 行だけで、共有する状態が無いので、隔離に縛る理由が無い。
///
/// [ADR-0010]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0010-concurrency-model.md
public nonisolated enum Diagnostics {
    /// 名乗り。どの出力がライブラリのものかを、行を見ただけで分かるようにする。
    static let prefix = "mokume"

    /// ライブラリからの注意を 1 行、標準エラーへ書く。
    ///
    /// **標準出力ではなく標準エラーへ書く。** 標準出力はスケッチが自分の用途で使う
    /// ものなので、ライブラリの都合で混ぜない。見張っている道具が出力を読んでいても、
    /// 注意は別の流れで届く。
    ///
    /// 何度も言うかどうかは呼び出し側が決める — 毎フレーム起きうることをそのまま
    /// 流すと、本当に読むべき 1 行が埋まる。
    ///
    /// **同じ文面を次の観測の応答にも載せるため、溜め場にも控える** (``WarningDigest``・#2761)。
    /// 標準エラーの 1 行は MCP から読めないので、スケッチが言った警告を観測で辿れるようにする。
    /// 言う口は呼び出し側のまま — 文面と頻度は変わらない。
    public static func warn(_ message: String) {
        FileHandle.standardError.write(Data("\(prefix): \(message)\n".utf8))
        (digest ?? sharedDigest).record(message)
    }

    /// 検査が自分の溜め場を差す先。差していなければ ``sharedDigest``。
    ///
    /// 溜め場はプロセスで 1 つなので、並んで走る検査が観測の応答を読むと、互いの警告を取り合う。
    /// 差しておけば、その検査の中で言われた警告だけを数えられる。**フレームの外へ逃がした仕事
    /// (`Task.detached` など) にはタスクローカル値が届かない**ので、そこから言われた分は
    /// プロセスの溜め場へ入る。
    @TaskLocal package static var digest: WarningDigest?

    /// プロセスの溜め場。
    package static let sharedDigest = WarningDigest()

    /// 言ったままで、まだ観測の応答に載せていない警告を、言った順に返して空にする。
    package static func takeUnreported() -> [String] {
        (digest ?? sharedDigest).takeUnreported()
    }

    /// このプロセスが言った警告の数と最後の 1 行。**読んでも空にならない** (``takeUnreported()`` とは別)。
    ///
    /// 子が絵と同じ面へ載せ、道具の窓が件数と最後の 1 行を出す ([#3087](https://github.com/mokume-metal/mokume/issues/3087))。
    package static func warningSummary() -> (count: Int, last: String?) {
        (digest ?? sharedDigest).summary()
    }

    /// 失敗を、**型と理由の 1 行**にする。``warn(_:)`` の文面に埋める (#2263)。
    ///
    /// **符号化・復号の失敗に `localizedDescription` を使わない** — `EncodingError` /
    /// `DecodingError` では「正しい形式でない」とだけ言い、どの値が何で拒まれたかを落とす。
    /// それらは文脈の説明と、拒まれた場所 (`values[1].value` の形) を出す。他の失敗
    /// (ファイルの読み書きなど) は、下に POSIX の事情があればその番号の C の文面
    /// (``posixReason(_:)``)、無ければ `localizedDescription` が人の読む理由を持っている。
    package static func reason(_ error: any Error) -> String {
        let detail: String
        switch error {
        case EncodingError.invalidValue(_, let context):
            detail = described(context)
        case DecodingError.dataCorrupted(let context),
            DecodingError.keyNotFound(_, let context),
            DecodingError.typeMismatch(_, let context),
            DecodingError.valueNotFound(_, let context):
            detail = described(context)
        default:
            detail = failureText(error)
        }
        let line = detail.split(whereSeparator: \.isNewline).joined(separator: " ")
        return "\(kind(of: error)): \(line)"
    }

    /// POSIX の失敗の番号 (`errno`) を、人が読む短い句にする (`Is a directory`・`Permission denied`)。
    /// 引けなければ `error <番号>`。
    ///
    /// **OS の事情を文にするのはここだけにする** ([#2839](https://github.com/mokume-metal/mokume/issues/2839))。
    /// 口ごとに作り方が割れると、同じ事情が口によって別の文面になる。
    ///
    /// **C の文面 (`strerror_r`) で引く。** Foundation の説明 (`localizedDescription`) は言語の
    /// 設定に左右されうるが、道具が話す言葉は英語で、設定で切り替えない ([ADR-0038] 決定 1・2)。
    /// `strerror` ではなく `strerror_r` なのは、待たない読み込みや見張りの作り直しが別の糸から
    /// 呼ぶため。
    ///
    /// [ADR-0038]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0038-language-of-the-tool.md
    package static func posixReason(_ code: Int32) -> String {
        var text = [CChar](repeating: 0, count: 256)
        guard strerror_r(code, &text, text.count) == 0 else { return "error \(code)" }
        return text.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
    }

    /// 失敗そのものか、`NSUnderlyingErrorKey` を辿った先が POSIX の失敗なら、その番号。無ければ `nil`。
    ///
    /// Foundation のファイルの失敗は、Cocoa の失敗の下に POSIX の失敗を持つ形で届く
    /// (`NSCocoaErrorDomain 512` の下に `NSPOSIXErrorDomain 21`)。下の下まで辿る。
    package static func posixCode(in error: any Error) -> Int32? {
        var current: NSError? = error as NSError
        // 自分を指す下の失敗で回り続けないよう、辿る深さに上限を置く
        for _ in 0..<8 {
            guard let failure = current else { return nil }
            // 番号が `Int32` に収まらないものは、POSIX の番号として読まない (落とさない)
            if failure.domain == NSPOSIXErrorDomain { return Int32(exactly: failure.code) }
            current = failure.userInfo[NSUnderlyingErrorKey] as? NSError
        }
        return nil
    }

    /// 失敗の理由の句。``reason(_:)`` と違い、型の名乗りを前に付けない —
    /// 口ごとの失敗の型 (`unreachable(url:reason:)` など) の `reason` に、そのまま入れる句である。
    ///
    /// 読む順は 4 段で、**`NSError` は構造体のダンプ (`Error Domain=… UserInfo={… 0x…}`) になるので、自前の
    /// 説明より先に外す** ([#2401])。
    /// 1. 下に POSIX の事情があれば、その番号の C の文面 (``posixReason(_:)``)
    /// 2. `NSError` (Foundation が返す失敗) は `localizedDescription`
    /// 3. 自前の `CustomStringConvertible` (mokume の公開の失敗はこれ) は、その説明
    /// 4. `LocalizedError` は、説明・理由・次の一手を改行でつないだもの。無ければ `localizedDescription`
    ///
    /// 3・4 は複数行になりうる。1 行にしたい呼び手は ``reason(_:)`` を使う (改行を畳む)。
    ///
    /// [#2401]: https://github.com/mokume-metal/mokume/issues/2401
    package static func failureText(_ error: any Error) -> String {
        if let code = posixCode(in: error) { return posixReason(code) }
        if type(of: error) is NSError.Type { return error.localizedDescription }
        if let described = error as? any CustomStringConvertible { return described.description }
        if let localized = error as? any LocalizedError, let text = localized.errorDescription {
            return [text, localized.failureReason, localized.recoverySuggestion]
                .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: "\n")
        }
        return error.localizedDescription
    }

    /// 書けなかった失敗の、POSIX の事情の句。POSIX の事情が無ければ `nil` (呼び手が今の文面に落とす)。
    ///
    /// **置き換えて書く (`.atomic`) と、行き先がディレクトリのときの下の失敗は ENOENT になる**
    /// (#2839 の実測)。そのまま `No such file or directory` と言うと、在るものを無いと言ってしまう。
    /// だから下の番号が ENOENT で、行き先**そのもの**がディレクトリなら EISDIR (`Is a directory`) を
    /// 名乗る。
    ///
    /// - 呼ぶのは**書くのに失敗したときだけ**にする (書けた経路に判定を足さない)
    /// - 行き先は **symlink を辿らずに** (`lstat`) 見る。ディレクトリを指す symlink への書き込みが
    ///   別の理由 (書く権利が無い・EACCES) で失敗したのを、`Is a directory` と偽らない
    package static func writingPosixReason(_ error: any Error, at url: URL) -> String? {
        guard let code = posixCode(in: error) else { return nil }
        guard code == ENOENT else { return posixReason(code) }
        var status = stat()
        let isDirectory = lstat(url.path, &status) == 0 && status.st_mode & S_IFMT == S_IFDIR
        return posixReason(isDirectory ? EISDIR : code)
    }

    /// 失敗の型。**Foundation が返す失敗は `NSError` としか名乗らない**ので、領域と番号
    /// (`NSCocoaErrorDomain 513` の形) を出す — 型の名前だけでは何の失敗か分からない。
    private static func kind(of error: any Error) -> String {
        guard type(of: error) is NSError.Type else { return "\(type(of: error))" }
        let bridged = error as NSError
        return "\(bridged.domain) \(bridged.code)"
    }

    private static func described(_ context: EncodingError.Context) -> String {
        context.debugDescription + place(context.codingPath)
    }

    private static func described(_ context: DecodingError.Context) -> String {
        context.debugDescription + place(context.codingPath)
    }

    /// 拒まれた場所。配列の要素は `[n]`、鍵は `.name` で綴る。根なら何も足さない。
    private static func place(_ path: [any CodingKey]) -> String {
        guard !path.isEmpty else { return "" }
        let spelled = path.enumerated().map { offset, key in
            if let index = key.intValue { return "[\(index)]" }
            return offset == 0 ? key.stringValue : ".\(key.stringValue)"
        }
        return " (at \(spelled.joined()))"
    }
}
