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
        split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
    }
}
