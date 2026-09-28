// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

nonisolated extension StringProtocol {
    /// 改行で行へ割る。**空行は落とさない。**
    ///
    /// **`split(separator: "\n")` で割ってはならない。** Swift の `Character` は書記素
    /// クラスタなので `"\r\n"` は**改行 1 つ**として並んでおり、`"\n"` とは一致しない。
    /// Windows 系の道具が書き出したファイルは改行が `\r\n` なので、その式では
    /// **全体が 1 行になったまま黙って通る** — OBJ なら先頭の `#` で全部がコメント扱いに
    /// なって頂点 0 のモデルが返り、文字なら 1 行として描かれる。どちらも落ちず、警告も
    /// 出ない ([#1301])。
    ///
    /// `Character.isNewline` で割ると `\r\n` も単独の `\r` も改行として扱われるので、
    /// **どこから来たファイルでも同じ行の並びになる**。
    ///
    /// [#1301]: https://github.com/mokume-metal/mokume/issues/1301
    var lines: [SubSequence] {
        split(omittingEmptySubsequences: false, whereSeparator: \.isNewlineQuickly)
    }
}

nonisolated extension Character {
    /// ``Character/isNewline`` と同じ答えを、**ASCII の字では性質表を引かずに**返す ([#1784])。
    ///
    /// `isNewline` は ASCII の字でも Unicode の性質表を引く。行へ割る・空白で割るのは
    /// 1 字ずつ全部を見るので、大きな OBJ や長い文章ではこの表引きが費用の大半になる。
    /// ASCII で改行なのは LF・VT・FF・CR (0x0A…0x0D) だけで、`"\r\n"` も
    /// `asciiValue` が 0x0A なので同じ答えになる。ASCII でない字は元の判定へ回す。
    ///
    /// [#1784]: https://github.com/mokume-metal/mokume/issues/1784
    var isNewlineQuickly: Bool {
        if let ascii = asciiValue { return (0x0A...0x0D).contains(ascii) }
        return isNewline
    }

    /// ``Character/isWhitespace`` と同じ答えを、**ASCII の字では性質表を引かずに**返す
    /// ([#1784])。ASCII で空白なのは空白 (0x20) と HT・LF・VT・FF・CR (0x09…0x0D) だけ。
    ///
    /// [#1784]: https://github.com/mokume-metal/mokume/issues/1784
    var isWhitespaceQuickly: Bool {
        if let ascii = asciiValue { return ascii == 0x20 || (0x09...0x0D).contains(ascii) }
        return isWhitespace
    }
}
