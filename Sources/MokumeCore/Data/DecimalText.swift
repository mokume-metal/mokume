// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation

/// 値を数として取り出す口 (``JSONObject/getFloat(_:)``・``XML/getFloat(_:)``・
/// ``TableRow/getFloat(_:)-(String)``) が共有する、文字を数にする読み方 (#2330)。
///
/// - **前後の空白は落とす。** 空白には改行 (LF・CR・U+2028 など) も含める — 表のセルや
///   JSON の文字の末尾に改行が残っていても、数として読む (Processing の `getFloat` と同じ)
/// - **数とするのは 10 進の綴りだけ**: 符号 (`+` / `-`、無くてよい)、数字と小数点 (数字は
///   1 つ以上。`.5`・`5.` も数)、任意で `e` / `E` と、符号を付けてもよい数字。数字は ASCII の
///   `0`…`9` だけ
/// - それ以外は数でない文字である。Swift の `Float(String)` が受ける `nan`・`inf`・`Infinity`・
///   16 進 (`0x10`) も、数としない — 「数にならないときは NaN を返して知らせる」口が、文字の
///   `"NaN"` を黙って NaN にしたり、`"inf"` を無限として絵に入れたりしないように
/// - 10 進だが `Float` に収まらない数 (`"1e39"`) は ±無限大。数の値 (`{"max": 1e300}`) を
///   ``JSONObject/getFloat(_:)`` が無限大で返すのと揃える
///
/// 綴りの照合は手で書いた ASCII の照合で、照合を通った綴りだけを `Float(String)` に渡す。
/// 表の行を毎フレーム読む作品があるので、正規表現は使わない。
nonisolated enum DecimalText {
    /// 文字を数にする。10 進の綴りでなければ `nil`。
    static func float(_ text: String) -> Float? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isDecimal(trimmed.utf8) else { return nil }
        return Float(trimmed)
    }

    /// 綴りが `[+-]?([0-9]+\.?[0-9]*|\.[0-9]+)([eE][+-]?[0-9]+)?` に丸ごと合うか。
    private static func isDecimal(_ bytes: String.UTF8View) -> Bool {
        var index = bytes.startIndex
        func skip(_ accepted: (UInt8) -> Bool) -> Int {
            var count = 0
            while index < bytes.endIndex, accepted(bytes[index]) {
                index = bytes.index(after: index)
                count += 1
            }
            return count
        }
        func isDigit(_ byte: UInt8) -> Bool { (0x30...0x39).contains(byte) }
        func isSign(_ byte: UInt8) -> Bool { byte == 0x2B || byte == 0x2D }

        if index < bytes.endIndex, isSign(bytes[index]) { index = bytes.index(after: index) }
        var digits = skip(isDigit)
        if index < bytes.endIndex, bytes[index] == 0x2E {
            index = bytes.index(after: index)
            digits += skip(isDigit)
        }
        guard digits > 0 else { return false }
        if index < bytes.endIndex, bytes[index] == 0x65 || bytes[index] == 0x45 {
            index = bytes.index(after: index)
            if index < bytes.endIndex, isSign(bytes[index]) { index = bytes.index(after: index) }
            guard skip(isDigit) > 0 else { return false }
        }
        return index == bytes.endIndex
    }
}
