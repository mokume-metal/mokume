// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation

/// JSON の値。読み解いた中身を、Foundation の型 (`NSNumber` や `NSNull`) を持たずに運ぶ。
///
/// **数は `Double` で持つ。** 取り出す口が ``JSONObject/getFloat(_:)`` だけなので、それで
/// 足りる。整数を桁を落とさずに取り出す口が要ったら、ここに整数の case を足す (内部の形で、
/// 面には出ない)。
nonisolated enum JSONValue: Equatable, Sendable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    /// 知らせる文面に載せる、値の短い言い方 (`true`・`18.5`・`"N/A"`・`an object`)。
    var spoken: String {
        switch self {
        case .null: "null"
        case .bool(let value): value ? "true" : "false"
        case .number(let value): String(value)
        case .string(let value): "\"\(value)\""
        case .array: "an array"
        case .object: "an object"
        }
    }
}

/// JSON の文字を値へ読み解く。
///
/// ## 読み方
///
/// - 読み解くのは `JSONSerialization` で、その読み方に従う。文字は UTF-8 (呼ぶ側が
///   ``TextFile/text(of:path:)`` で解いてから渡す)
/// - 入れ子は、最上位の下に 512 段まで (`JSONSerialization` の上限)。`1e400` のように
///   `Double` に収まらない数は読めない
/// - `true` / `false` は真偽で、数の `1` / `0` とは分けて持つ
///
/// ## 壊れた JSON は投げる
///
/// 閉じない括弧・不正な文字・空の文字・深すぎる入れ子は ``DataFailure/malformed(path:line:reason:)``
/// で、**壊れていた箇所の行**を添えて投げる。最上位がオブジェクトでない文字を
/// ``Sketch/loadJSONObject(_:)`` で読んだときも同じ case で、最上位の値が始まる行を添える。
///
/// 隔離の外で走れる形にしてあるのは、待たない読み込みが読み解きを別の仕事として回すため
/// ([ADR-0010] 決定 6)。
///
/// [ADR-0010]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0010-concurrency-model.md
nonisolated enum JSONFile {
    /// JSON の文字を読み解き、最上位のオブジェクトの中身を返す。
    ///
    /// - Parameter path: 失敗を名乗るための名前。
    static func parseObject(_ text: String, path: String) throws(DataFailure) -> [String: JSONValue] {
        let value = try parse(text, path: path)
        guard case .object(let members) = value else {
            throw .malformed(
                path: path, line: firstValueLine(of: text),
                reason: "the top level is \(value.spoken), not an object ({…})")
        }
        return members
    }

    /// JSON の文字を値へ読み解く。最上位はどの値でもよい。
    static func parse(_ text: String, path: String) throws(DataFailure) -> JSONValue {
        let data = Data(text.utf8)
        let object: Any
        do {
            object = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        } catch {
            let info = (error as NSError).userInfo
            // **行は自分で数える。** `JSONSerialization` は壊れた箇所をバイトの位置
            // (`NSJSONSerializationErrorIndex`) で持つ。行の数え方 (LF・CRLF・CR) を
            // ``TextFile/lines(of:)`` と揃えるために、文面の「line N」は使わない
            let offset = info["NSJSONSerializationErrorIndex"] as? Int ?? data.count
            let place = position(of: offset, in: data)
            // 行は文字の行の数を越えない。最後の改行の後ろ (行を作らない) で起きた壊れ方は、
            // 最後の行のものとして名乗る (XML と同じ — ``XMLFile``)
            let last = max(1, TextFile.lines(of: text).count)
            let spot = place.line > last ? "at the end of the text" : "column \(place.column)"
            throw .malformed(
                path: path, line: min(place.line, last), reason: "\(complaint(info)) (\(spot))")
        }
        return value(of: object)
    }

    /// `JSONSerialization` の返した値を、本体の値にする。
    ///
    /// **真偽を先に見分ける。** `true` も `1` も `NSNumber` で届き、Swift の `as? Bool` は
    /// `1` も真偽として通すので、型の印 (`CFBoolean`) で分ける。
    private static func value(of object: Any) -> JSONValue {
        switch object {
        case let members as [String: Any]:
            .object(members.mapValues(value(of:)))
        case let items as [Any]:
            .array(items.map(value(of:)))
        case let string as String:
            .string(string)
        case let number as NSNumber:
            CFGetTypeID(number) == CFBooleanGetTypeID()
                ? .bool(number.boolValue) : .number(number.doubleValue)
        default:
            .null
        }
    }

    /// 壊れていた事情の 1 文。`JSONSerialization` の文面から、位置の部分を落としたもの。
    private static func complaint(_ info: [String: Any]) -> String {
        let said = (info[NSDebugDescriptionErrorKey] as? String) ?? "the JSON could not be read"
        let trimmed = said.replacing(/\s*around line \d+, column \d+\.?$/, with: "")
        return trimmed.hasSuffix(".") ? String(trimmed.dropLast()) : trimmed
    }

    /// バイトの位置を、行と列 (どちらも 1 から) にする。列は文字 (Unicode のスカラー) で数える。
    private static func position(of offset: Int, in data: Data) -> (line: Int, column: Int) {
        var line = 1
        var column = 1
        var afterCarriageReturn = false
        for byte in data.prefix(max(0, offset)) {
            switch byte {
            case 0x0A where afterCarriageReturn:
                afterCarriageReturn = false
            case 0x0A, 0x0D:
                line += 1
                column = 1
                afterCarriageReturn = byte == 0x0D
            default:
                // UTF-8 の続きのバイト (10xxxxxx) は、前の文字の一部なので数えない
                if byte & 0xC0 != 0x80 { column += 1 }
                afterCarriageReturn = false
            }
        }
        return (line, column)
    }

    /// 最初の値が始まる行。空白しか無ければ最後の行。
    private static func firstValueLine(of text: String) -> Int {
        let data = Data(text.utf8)
        let start = data.firstIndex { ![0x20, 0x09, 0x0A, 0x0D].contains($0) } ?? data.endIndex
        return position(of: start - data.startIndex, in: data).line
    }
}
