// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

/// OSC のバイト列とメッセージを行き来する。OSC 1.0 の形に、広く使われる型の印
/// (`h`・`d`・`S`・`T`・`F`・`N`・`I`) を足したものを読む。
///
/// ## 読めないところで打ち切る
///
/// **読めない部分に当たったら、そのパケットの残りを読まずに捨てる。** 知らない型の印があると、
/// その引数が何バイトなのかが分からない。推して読み進めると、後ろの引数も後ろのメッセージも
/// ずれた位置から読むことになり、**黙って間違った値を出す**。打ち切れば、出すのは読めた
/// ものだけになる (前身のライブラリの方針)。
///
/// 読めないとするもの:
///
/// - 宛名が `/` で始まらない・文字列が閉じていない (`0` が無い)・UTF-8 でない
/// - 型の印の列が `,` で始まらない・知らない型の印がある
/// - 引数の途中でバイトが尽きる・読み終えた後にバイトが余る
/// - 束 (bundle) の要素の長さが 4 の倍数でない・残りより長い・入れ子が深すぎる
///
/// 束の時刻は見ない。中のメッセージは、届いたときに並んでいた順で渡す。
nonisolated enum OSCCodec {
    /// 読んだ結果。``readable`` が偽なら、``messages`` の後ろは打ち切られている。
    struct Decoded: Equatable {
        /// 読めたメッセージ。届いた順。
        var messages: [OSCMessage]
        /// 終わりまで読めたか。
        var readable: Bool
    }

    /// 束の入れ子をどこまで開くか。これより深いものは読めないとする (際限の無い再帰を避ける)。
    static let maximumDepth = 16

    /// 束の印 (`#bundle` と終わりの 0)。
    private static let bundleMark: [UInt8] = Array("#bundle".utf8) + [0]

    /// 1 つの datagram を読む。
    static func decode(_ bytes: [UInt8]) -> Decoded {
        var reader = Reader(bytes: bytes, position: 0, end: bytes.count)
        var messages: [OSCMessage] = []
        let readable = element(&reader, into: &messages, depth: 0)
        return Decoded(messages: messages, readable: readable)
    }

    /// メッセージ 1 つを、送るバイト列にする。
    static func encode(_ message: OSCMessage) throws(EncodingProblem) -> [UInt8] {
        guard message.address.hasPrefix("/") else { throw .address(message.address) }
        var tags = ","
        var payload: [UInt8] = []
        for value in message.arguments {
            switch value {
            case .int(let number):
                tags += "i"
                payload += bigEndian(UInt32(bitPattern: number))
            case .float(let number):
                tags += "f"
                payload += bigEndian(number.bitPattern)
            case .string(let text):
                tags += "s"
                payload += try padded(text)
            case .blob(let bytes):
                guard let size = Int32(exactly: bytes.count) else { throw .blobTooLarge(bytes.count) }
                tags += "b"
                payload += bigEndian(UInt32(bitPattern: size))
                payload += bytes
                payload += Array(repeating: 0, count: (4 - bytes.count % 4) % 4)
            case .int64(let number):
                tags += "h"
                payload += bigEndian(UInt64(bitPattern: number))
            case .double(let number):
                tags += "d"
                payload += bigEndian(number.bitPattern)
            case .bool(let flag):
                tags += flag ? "T" : "F"
            case .null:
                tags += "N"
            case .impulse:
                tags += "I"
            }
        }
        return try padded(message.address) + padded(tags) + payload
    }

    /// 送れないメッセージの理由。
    enum EncodingProblem: Error, Equatable, CustomStringConvertible {
        /// 宛名が `/` で始まらない。
        case address(String)
        /// 文字列が 0 のバイトを含む (OSC の文字列は 0 で閉じるので、そこで切れてしまう)。
        case zeroInString(String)
        /// バイトの並びが長すぎて、長さを 32 bit で書けない。
        case blobTooLarge(Int)

        var description: String {
            switch self {
            case .address(let address):
                "the address \"\(address)\" does not start with \"/\""
            case .zeroInString(let text):
                "the string \"\(text)\" contains a zero byte, which would cut it short"
            case .blobTooLarge(let count):
                "the blob of \(count) bytes is too long for OSC"
            }
        }
    }

    // MARK: - 読む

    /// メッセージか束を 1 つ読む。読めないところに当たったら偽を返す (それまでに読めたものは残る)。
    private static func element(
        _ reader: inout Reader, into messages: inout [OSCMessage], depth: Int
    ) -> Bool {
        if reader.consume(bundleMark) {
            guard depth < maximumDepth, reader.skip(8) else { return false }  // 時刻は見ない
            while reader.remaining > 0 {
                guard let size = reader.int32(), size >= 0, size % 4 == 0,
                    Int(size) <= reader.remaining
                else { return false }
                var inner = reader.slice(Int(size))
                guard element(&inner, into: &messages, depth: depth + 1) else { return false }
            }
            return true
        }
        guard let message = message(&reader) else { return false }
        messages.append(message)
        return true
    }

    /// メッセージを 1 つ読む。読み終えたときにバイトが余っていれば、読めないとする。
    private static func message(_ reader: inout Reader) -> OSCMessage? {
        guard let address = reader.string(), address.hasPrefix("/") else { return nil }
        // 型の印の列を持たない古い形は、引数の無いメッセージとして読む
        guard reader.remaining > 0 else { return OSCMessage(address, arguments: []) }
        guard let tags = reader.string(), tags.hasPrefix(",") else { return nil }
        var values: [OSCValue] = []
        for tag in tags.utf8.dropFirst() {
            guard let value = argument(tag, from: &reader) else { return nil }
            values.append(value)
        }
        guard reader.remaining == 0 else { return nil }
        return OSCMessage(address, arguments: values)
    }

    /// 型の印 1 つぶんの引数を読む。知らない印・バイトが尽きたら `nil`。
    private static func argument(_ tag: UInt8, from reader: inout Reader) -> OSCValue? {
        switch tag {
        case UInt8(ascii: "i"): reader.int32().map { .int($0) }
        case UInt8(ascii: "f"): reader.uint32().map { .float(Float(bitPattern: $0)) }
        case UInt8(ascii: "s"), UInt8(ascii: "S"): reader.string().map { .string($0) }
        case UInt8(ascii: "b"): reader.blob().map { .blob($0) }
        case UInt8(ascii: "h"): reader.uint64().map { .int64(Int64(bitPattern: $0)) }
        case UInt8(ascii: "d"): reader.uint64().map { .double(Double(bitPattern: $0)) }
        case UInt8(ascii: "T"): .bool(true)
        case UInt8(ascii: "F"): .bool(false)
        case UInt8(ascii: "N"): .null
        case UInt8(ascii: "I"): .impulse
        default: nil
        }
    }

    // MARK: - 書く

    /// 0 で閉じ、4 バイトの倍数まで 0 で埋めた文字列。
    private static func padded(_ text: String) throws(EncodingProblem) -> [UInt8] {
        let bytes = Array(text.utf8)
        guard !bytes.contains(0) else { throw .zeroInString(text) }
        return bytes + Array(repeating: 0, count: 4 - bytes.count % 4)
    }

    private static func bigEndian(_ value: UInt32) -> [UInt8] {
        (0..<4).map { UInt8(truncatingIfNeeded: value >> (24 - 8 * $0)) }
    }

    private static func bigEndian(_ value: UInt64) -> [UInt8] {
        (0..<8).map { UInt8(truncatingIfNeeded: value >> (56 - 8 * $0)) }
    }
}

/// バイト列を前から読む。``end`` より先は読まない (束の要素の長さで区切るため)。
private nonisolated struct Reader {
    let bytes: [UInt8]
    var position: Int
    let end: Int

    var remaining: Int { end - position }

    /// 先頭が `mark` なら読み進めて真を返す。
    mutating func consume(_ mark: [UInt8]) -> Bool {
        guard remaining >= mark.count, bytes[position..<position + mark.count].elementsEqual(mark)
        else { return false }
        position += mark.count
        return true
    }

    /// `count` バイト読み飛ばす。足りなければ偽。
    mutating func skip(_ count: Int) -> Bool {
        guard remaining >= count else { return false }
        position += count
        return true
    }

    /// ここから `count` バイトを区切った読み手を返し、自分はその先へ進む。
    mutating func slice(_ count: Int) -> Reader {
        defer { position += count }
        return Reader(bytes: bytes, position: position, end: position + count)
    }

    mutating func uint32() -> UInt32? {
        guard remaining >= 4 else { return nil }
        defer { position += 4 }
        return bytes[position..<position + 4].reduce(0) { $0 << 8 | UInt32($1) }
    }

    mutating func int32() -> Int32? { uint32().map { Int32(bitPattern: $0) } }

    mutating func uint64() -> UInt64? {
        guard remaining >= 8 else { return nil }
        defer { position += 8 }
        return bytes[position..<position + 8].reduce(0) { $0 << 8 | UInt64($1) }
    }

    /// 0 で閉じ、4 バイトの倍数まで埋められた文字列。閉じていない・UTF-8 でなければ `nil`。
    mutating func string() -> String? {
        guard let zero = bytes[position..<end].firstIndex(of: 0) else { return nil }
        let length = (zero - position + 4) & ~3
        guard length <= remaining,
            let text = String(validating: bytes[position..<zero], as: UTF8.self)
        else { return nil }
        position += length
        return text
    }

    /// 長さ (32 bit) と中身と、4 バイトの倍数までの埋め。
    mutating func blob() -> [UInt8]? {
        guard let size = int32(), size >= 0 else { return nil }
        let count = Int(size)
        let length = (count + 3) & ~3
        guard length <= remaining else { return nil }
        defer { position += length }
        return Array(bytes[position..<position + count])
    }
}
