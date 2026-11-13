// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation

/// 値を数として取り出す口 (``JSONObject/getFloat(_:)``・``JSONObject/getInt(_:)``・``XML/getFloat(_:)``・
/// ``TableRow/getFloat(_:)-(String)``) が共有する、文字を数にする読み方 (#2330)。OBJ の読み手
/// (``ModelFile/parse(_:)``) も頂点の数をこれで読む (#2514)。
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
///
/// SVG の値の数 (長さ・不透明度・`rgb()` の成分) も同じ綴りの規則で読む (#2513)。そちらは
/// 前後の空白を落とさない `spelled(_:)` を使う。
nonisolated enum DecimalText {
    /// 文字を数にする。10 進の綴りでなければ `nil`。
    static func float(_ text: String) -> Float? {
        spelled(text.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// 文字を整数にする。綴りの決まりは ``float(_:)`` と同じ (前後の空白を落とし、10 進の綴りだけを
    /// 数とする) で、**綴りの値が整数で `Int` に収まるときだけ**返す (`"3"`・`"3.0"`・`"1e3"`・`"100e-2"`)。
    /// 端数がある (`"2.5"`・`"1.0000000000000001"`) か、`Int` に収まらなければ `nil`。
    ///
    /// **`Double` を通さない (#3950)。** 通すと 2⁵³ を越える整数の桁が落ち (`"9007199254740993.0"` が
    /// 9007199254740992 になる)、小さな端数が消え (`"1.0000000000000001"` が 1 になる)、`Int.min` の
    /// 1 つ外が `Int.min` に丸まる。綴りの数字と指数から、値を桁のまま組み立てる。
    /// 整数を丸めずに読む口 (``JSONObject/getInt(_:)``・``JSONArray/getInt(_:)``・
    /// ``TableRow/getInt(_:)-(String)``・``Table/getInt(_:_:)-(_,String)``) が使う。
    static func int(_ text: String) -> Int? {
        let string = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let bytes = Array(string.utf8)
        guard isDecimal(bytes) else { return nil }
        func isDigit(_ byte: UInt8) -> Bool { (0x30...0x39).contains(byte) }

        var index = 0
        var negative = false
        if bytes[index] == 0x2B || bytes[index] == 0x2D {
            negative = bytes[index] == 0x2D
            index += 1
        }
        // 小数点を除いた数字の並びと、その並びに掛かる 10 の冪 (小数点より後ろの数字の数だけ負へ)
        var digits: [UInt8] = []
        var power = 0
        while index < bytes.count, isDigit(bytes[index]) {
            digits.append(bytes[index] - 0x30)
            index += 1
        }
        if index < bytes.count, bytes[index] == 0x2E {
            index += 1
            while index < bytes.count, isDigit(bytes[index]) {
                digits.append(bytes[index] - 0x30)
                power -= 1
                index += 1
            }
        }
        if index < bytes.count {  // e / E と、符号を付けてもよい数字 (照合は済んでいる)
            index += 1
            var exponentNegative = false
            if bytes[index] == 0x2B || bytes[index] == 0x2D {
                exponentNegative = bytes[index] == 0x2D
                index += 1
            }
            // 指数は桁あふれしない所で止める。2 つの冪を足しても Int に収まり、結果は収まらない側に倒れる
            var exponent = 0
            while index < bytes.count {
                exponent = min(exponent * 10 + Int(bytes[index] - 0x30), 1_000_000_000)
                index += 1
            }
            power += exponentNegative ? -exponent : exponent
        }

        // 0 は指数によらず 0 (`"-0"`・`"0.0e999"`)。先頭の 0 を落とし、末尾の 0 は冪へ移す
        guard let first = digits.firstIndex(where: { $0 != 0 }) else { return 0 }
        var last = digits.count - 1
        while digits[last] == 0 {
            last -= 1
            power += 1
        }
        let significant = digits[first...last]
        // 末尾が 0 でない数字の並びに負の冪が掛かれば、端数が残る
        guard power >= 0 else { return nil }
        // Int.max は 19 桁。それより長い整数は収まらない
        guard significant.count + power <= 19 else { return nil }

        var magnitude: UInt64 = 0
        for digit in significant {
            magnitude = magnitude * 10 + UInt64(digit)  // 19 桁までは UInt64 に収まる
        }
        for _ in 0..<power {
            let (scaled, overflow) = magnitude.multipliedReportingOverflow(by: 10)
            guard !overflow else { return nil }
            magnitude = scaled
        }
        if negative {
            // Int.min の大きさ (2⁶³) は Int の正の側に収まらない
            if magnitude == UInt64(Int.max) + 1 { return Int.min }
            return Int(exactly: magnitude).map { -$0 }
        }
        return Int(exactly: magnitude)
    }

    /// 前後の空白を落とさずに、文字が丸ごと 10 進の綴りのときだけ数にする。
    ///
    /// 数と単位が隣り合う書式 (SVG / CSS の `10px`・`50%`) が使う。そこでは数と単位のあいだに
    /// 空白を置けない (`"10 px"` は読めない値) ので、空白を落とすのは値の前後を知る呼ぶ側に任せる。
    static func spelled(_ text: some StringProtocol) -> Float? {
        let string = String(text)
        guard isDecimal(string.utf8) else { return nil }
        return Float(string)
    }

    /// 綴りが `[+-]?([0-9]+\.?[0-9]*|\.[0-9]+)([eE][+-]?[0-9]+)?` に丸ごと合うか。
    ///
    /// **文字の STL の通読** (``ModelFile/scanDecimal(_:from:end:)``) は、速さのために同じ文法を手で写している。
    /// 検査が、この照合と突き合わせる (`STLModelTests`)。
    static func isDecimal<Bytes: Collection>(_ bytes: Bytes) -> Bool where Bytes.Element == UInt8 {
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
