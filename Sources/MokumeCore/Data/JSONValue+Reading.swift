// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation

/// JSON の値を、取り出す口 (``JSONObject`` の `getFloat`・`getInt`・`getString`・`getBoolean` と、
/// ``JSONArray`` の番号で引く同じ口) が求める型で読む。
///
/// **口ごとに読み方を 2 か所に書かない。** キーで引く口と番号で引く口は、値の種類を決めるここを通り、
/// 違うのは「欠けたときに何を言うか」だけである。読めなければ `nil` で、空の値への倒し方と知らせは
/// 呼ぶ側が持つ。
extension JSONValue {
    /// 数として読む。数の値はそのまま、数の文字 (`"18.5"`) は 10 進の綴りだけを数として読む
    /// (``DecimalText/float(_:)``)。
    var asFloat: Float? {
        switch self {
        case .integer(let value): Float(value)
        case .number(let value): Float(value)
        case .string(let text): DecimalText.float(text)
        default: nil
        }
    }

    /// 整数の値として読む。**丸めない** — `2` と `2.0` は 2 で、`2.5` と `Int` に収まらない数は読めない。
    /// 数の文字は、10 進の綴りで整数の値のもの (`"3"`・`"3.0"`・`"1e3"`) だけを読む。
    var asInt: Int? {
        switch self {
        case .integer(let value):
            return value
        case .number(let value):
            return Self.exactInt(value)
        case .string(let text):
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            // `Double` を通すと 2⁵³ より大きな整数の桁が落ちるので、整数の綴りは先に `Int` で読む
            if let value = Int(trimmed) { return value }
            return DecimalText.double(text).flatMap(Self.exactInt)
        default:
            return nil
        }
    }

    /// 文字として読む。文字の値だけで、数や真偽を綴りにして返すことはしない。
    var asString: String? {
        if case .string(let text) = self { return text }
        return nil
    }

    /// 真偽として読む。`true` / `false` だけで、数の `1` / `0` や文字の `"true"` は読めない。
    var asBool: Bool? {
        if case .bool(let flag) = self { return flag }
        return nil
    }

    /// 整数の値である `Double` を `Int` にする。小数部があるか、`Int` に収まらなければ `nil`。
    private static func exactInt(_ value: Double) -> Int? {
        // 上端は含まない: 2⁶³ は `Int` に収まらない
        guard value.isFinite, value == value.rounded(.towardZero),
            value >= -9_223_372_036_854_775_808.0, value < 9_223_372_036_854_775_808.0
        else { return nil }
        return Int(value)
    }
}
