// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation

/// JSON の値。読み解いた中身を、Foundation の型 (`NSNumber` や `NSNull`) を持たずに運ぶ。
///
/// **数は `Double` で持ち、有限である** (収まらない数は ``JSONFile`` が読まずに断る)。
/// 取り出す口が ``JSONObject/getFloat(_:)`` だけなので、それで足りる。整数を桁を落とさずに
/// 取り出す口が要ったら、ここに整数の case を足す (内部の形で、面には出ない)。
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
/// - 入れ子は、最上位の下に 512 段まで (`JSONSerialization` の上限)
/// - `1e400`・`-1e400` のように `Double` に収まらない数は、符号によらず読めない。値が木に
///   残らない数 (重複したキーの後ろの値) も同じ
/// - `true` / `false` は真偽で、数の `1` / `0` とは分けて持つ
///
/// ## 壊れた JSON は投げる
///
/// 閉じない括弧・不正な文字・空の文字・深すぎる入れ子・`Double` に収まらない数は
/// ``DataFailure/malformed(path:line:reason:)`` で、**壊れていた箇所の行**を添えて投げる。
/// 壊れた箇所が複数あれば、文字の中で最初のものを名乗る。最上位がオブジェクトでない文字を
/// ``SketchPart/loadJSONObject(_:)`` で読んだときも同じ case で、最上位の値が始まる行を添える。
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
    ///
    /// **`Double` に収まらない数は、`JSONSerialization` に任せず本体が文字から探す。** 任せると
    /// 符号で割れる — 正の側 (`1e400`) は位置つきで投げるが、負の側 (`-1e400`) は投げずに
    /// `-inf` を返し、重複したキーの後ろにあれば木から落とす。探す所を文字の 1 か所にすると、
    /// 符号によらず同じ文面で、文字の中の最初の 1 つを名乗れる (``firstUnfitNumber(in:through:)``)。
    static func parse(_ text: String, path: String) throws(DataFailure) -> JSONValue {
        let data = Data(text.utf8)
        let bytes = [UInt8](data)
        let object: Any
        do {
            object = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        } catch {
            let info = (error as NSError).userInfo
            // **行は自分で数える。** `JSONSerialization` は壊れた箇所をバイトの位置
            // (`NSJSONSerializationErrorIndex`) で持つ。行の数え方 (LF・CRLF・CR) を
            // ``TextFile/lines(of:)`` と揃えるために、文面の「line N」は使わない
            let offset = info["NSJSONSerializationErrorIndex"] as? Int ?? data.count
            // 壊れた箇所までに収まらない数があれば、そちらが最初の壊れ方である (壊れた箇所
            // そのものが正の側の収まらない数のときも、ここで同じ文面になる)
            if let unfit = firstUnfitNumber(in: bytes, through: offset) {
                throw unfitFailure(unfit, in: data, path: path)
            }
            let place = position(of: offset, in: data)
            // 行は文字の行の数を越えない。最後の改行の後ろ (行を作らない) で起きた壊れ方は、
            // 最後の行のものとして名乗る (XML と同じ — ``XMLFile``)
            let last = max(1, TextFile.lines(of: text).count)
            let spot = place.line > last ? "at the end of the text" : "column \(place.column)"
            throw .malformed(
                path: path, line: min(place.line, last), reason: "\(complaint(info)) (\(spot))")
        }
        if let unfit = firstUnfitNumber(in: bytes, through: bytes.count) {
            throw unfitFailure(unfit, in: data, path: path)
        }
        var leaked = false
        let value = value(of: object, nonFinite: &leaked)
        // 文字から探して見つからなかった非有限の数が木にある。読み手と探し方が食い違った
        // ときだけで起きないはずだが、無限を黙って通すよりは、最初の値の行で断る
        if leaked {
            throw .malformed(
                path: path, line: firstValueLine(of: text), reason: "a number does not fit in a Double")
        }
        return value
    }

    /// `JSONSerialization` の返した値を、本体の値にする。有限でない数に出会ったら `nonFinite` を
    /// 立てる。
    ///
    /// **真偽を先に見分ける。** `true` も `1` も `NSNumber` で届き、Swift の `as? Bool` は
    /// `1` も真偽として通すので、型の印 (`CFBoolean`) で分ける。
    private static func value(of object: Any, nonFinite: inout Bool) -> JSONValue {
        switch object {
        case let members as [String: Any]:
            return .object(members.mapValues { value(of: $0, nonFinite: &nonFinite) })
        case let items as [Any]:
            return .array(items.map { value(of: $0, nonFinite: &nonFinite) })
        case let string as String:
            return .string(string)
        case let number as NSNumber:
            if CFGetTypeID(number) == CFBooleanGetTypeID() { return .bool(number.boolValue) }
            if !number.doubleValue.isFinite { nonFinite = true }
            return .number(number.doubleValue)
        default:
            return .null
        }
    }

    /// 収まらない数を、それが書かれた行と列を添えた失敗にする。行と列の数え方は、他の壊れ方と
    /// 同じ (``position(of:in:)``)。
    private static func unfitFailure(
        _ unfit: (offset: Int, literal: String), in data: Data, path: String
    ) -> DataFailure {
        let place = position(of: unfit.offset, in: data)
        return .malformed(
            path: path, line: place.line,
            reason: "Number \(unfit.literal) does not fit in a Double (column \(place.column))")
    }

    /// `limit` のバイトの位置までに始まる数の綴りのうち、`Double` に収まらない最初のものと、
    /// それが始まるバイトの位置。
    ///
    /// `limit` までの文字は、`JSONSerialization` が読み進められた (壊れていない) 文字である。
    /// 数の綴りは文字列の外にしか現れないので、文字列 (`"…"`。`\` の次の 1 文字では閉じない) を
    /// 飛ばしながら、`-` か数字で始まる綴りを切り出す。
    ///
    /// **収まるかどうかは、綴りの大きさで絞ってから `JSONSerialization` 自身に読ませて決める。**
    /// 最上位の桁が 10³⁰⁸ に届かない数は必ず収まるので、読ませるのは届く数 (と、JSON の数の
    /// 形に合わない綴りは読ませない) だけで、大きな文字でも探す手間は綴りを舐める 1 回で済む。
    /// 読ませて投げるか有限でない数を返せば、収まらない — 読み手が同じなので、境目
    /// (`-1.8e308` は収まらず、`-1.7976931348623157e308` は収まる) の判断が木と食い違わない。
    private static func firstUnfitNumber(in bytes: [UInt8], through limit: Int) -> (offset: Int, literal: String)? {
        var index = 0
        while index < bytes.count, index <= limit {
            switch bytes[index] {
            case 0x22:  // "
                index += 1
                while index < bytes.count, bytes[index] != 0x22 {
                    index += bytes[index] == 0x5C ? 2 : 1  // \ は次の 1 バイトごと飛ばす
                }
                index += 1
            case 0x2D, 0x30...0x39:  // - と 0…9
                let start = index
                while index < bytes.count, isNumberByte(bytes[index]) { index += 1 }
                let literal = bytes[start..<index]
                guard let power = leadingPower(of: literal), power >= 308 else { continue }
                let read = try? JSONSerialization.jsonObject(with: Data(literal), options: [.fragmentsAllowed])
                if (read as? NSNumber)?.doubleValue.isFinite != true {
                    return (start, String(decoding: literal, as: UTF8.self))
                }
            default:
                index += 1
            }
        }
        return nil
    }

    /// 綴りが JSON の数の形 (`-?(0|[1-9][0-9]*)(\.[0-9]+)?([eE][+-]?[0-9]+)?`) なら、最上位の
    /// 桁の 10 の冪 (`-1.8e308` は 308、`0.05` は -2)。形が崩れている・値が 0 なら `nil`。
    private static func leadingPower(of literal: ArraySlice<UInt8>) -> Int? {
        var index = literal.startIndex
        func digits() -> Range<Int> {
            let start = index
            while index < literal.endIndex, (0x30...0x39).contains(literal[index]) { index += 1 }
            return start..<index
        }
        if index < literal.endIndex, literal[index] == 0x2D { index += 1 }
        let whole = digits()
        guard !whole.isEmpty, whole.count == 1 || literal[whole.lowerBound] != 0x30 else { return nil }
        var fraction = index..<index
        if index < literal.endIndex, literal[index] == 0x2E {
            index += 1
            fraction = digits()
            guard !fraction.isEmpty else { return nil }
        }
        var exponent = 0
        if index < literal.endIndex, literal[index] == 0x65 || literal[index] == 0x45 {
            index += 1
            let negative = index < literal.endIndex && literal[index] == 0x2D
            if index < literal.endIndex, literal[index] == 0x2B || literal[index] == 0x2D { index += 1 }
            let power = digits()
            guard !power.isEmpty else { return nil }
            // 桁の多い指数でも溢れないよう、判断に足りる大きさで止める
            for position in power { exponent = min(exponent * 10 + Int(literal[position] - 0x30), 1_000_000) }
            if negative { exponent = -exponent }
        }
        guard index == literal.endIndex else { return nil }
        if let first = whole.first(where: { literal[$0] != 0x30 }) {
            return whole.upperBound - first - 1 + exponent
        }
        if let first = fraction.first(where: { literal[$0] != 0x30 }) {
            return fraction.lowerBound - first - 1 + exponent
        }
        return nil
    }

    /// 数の綴りに現れるバイト (`0…9`・`-`・`+`・`.`・`e`・`E`)。
    private static func isNumberByte(_ byte: UInt8) -> Bool {
        switch byte {
        case 0x30...0x39, 0x2D, 0x2B, 0x2E, 0x65, 0x45: true
        default: false
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
