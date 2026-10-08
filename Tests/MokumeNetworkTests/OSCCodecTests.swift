// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Testing

@testable import MokumeNetwork

/// バイト列を組み立てる道具。
nonisolated enum Wire {
    /// 0 で閉じ、4 バイトの倍数まで埋めた文字列。
    static func string(_ text: String) -> [UInt8] {
        let bytes = Array(text.utf8)
        return bytes + Array(repeating: 0, count: 4 - bytes.count % 4)
    }

    static func int32(_ value: Int32) -> [UInt8] {
        let bits = UInt32(bitPattern: value)
        return (0..<4).map { UInt8(truncatingIfNeeded: bits >> (24 - 8 * $0)) }
    }

    static func float32(_ value: Float) -> [UInt8] {
        int32(Int32(bitPattern: value.bitPattern))
    }

    /// 束 (bundle)。要素はそれぞれ長さを前に付ける。
    static func bundle(_ elements: [[UInt8]]) -> [UInt8] {
        string("#bundle") + Array(repeating: 0, count: 7) + [1]
            + elements.flatMap { int32(Int32($0.count)) + $0 }
    }

    static func encoded(_ message: OSCMessage) throws -> [UInt8] {
        try OSCCodec.encode(message)
    }

    /// 部品をつなぐ。
    static func join(_ parts: [UInt8]...) -> [UInt8] { parts.flatMap { $0 } }

    /// 読めない形 1 つ。
    struct Malformed: Sendable, CustomTestStringConvertible {
        let what: String
        let bytes: [UInt8]
        var testDescription: String { what }
    }

    /// 読めないとすべき形。どれも値を 1 つも出さない。
    static let malformed: [Malformed] = [
        Malformed(what: "引数の途中でバイトが尽きる", bytes: join(string("/n"), string(",i"), [0, 0])),
        Malformed(what: "文字列が閉じていない", bytes: Array("/open".utf8)),
        Malformed(what: "宛名が / で始まらない", bytes: join(string("size"), string(",i"), int32(1))),
        Malformed(what: "型の印の列が , で始まらない", bytes: join(string("/n"), string("i"), int32(1))),
        Malformed(
            what: "読み終えた後にバイトが余る", bytes: join(string("/n"), string(",i"), int32(1), int32(2))),
        Malformed(
            what: "blob の長さが残りより長い", bytes: join(string("/b"), string(",b"), int32(8), [1, 2, 3, 4])),
        Malformed(
            what: "UTF-8 でない文字列", bytes: join(string("/s"), string(",s"), [0xFF, 0xFE, 0x00, 0x00])),
        Malformed(
            what: "束の要素の長さが 4 の倍数でない",
            bytes: join(string("#bundle"), [UInt8](repeating: 0, count: 8), int32(3), [1, 2, 3])),
        Malformed(
            what: "束の要素の長さが残りより長い",
            bytes: join(string("#bundle"), [UInt8](repeating: 0, count: 8), int32(64), string("/a"))),
        Malformed(what: "束の時刻が途中で尽きる", bytes: join(string("#bundle"), [0, 0, 0])),
        Malformed(what: "空", bytes: []),
    ]
}

/// OSC のバイト列とメッセージの行き来 (#1962)。GPU も通信も要らない。
///
/// **読めないところで打ち切ることが約束である。** 知らない型の印や途中で尽きたバイト列に
/// 当たったら、そこから後ろを捨て、読めたものだけを返す。推して読み進めて、ずれた位置から
/// 間違った値を出してはいけない。
@Suite("OSC の読み書き")
struct OSCCodecTests {
    // MARK: - 書いた形が仕様どおりか

    @Test("小数 1 つのメッセージは、仕様の並びのバイト列になる")
    func floatMessageBytes() throws {
        // "/size" + 0 + 埋め 2 / ",f" + 0 + 埋め 1 / 0.5 (ビッグエンディアン)
        let expected: [UInt8] = [
            0x2F, 0x73, 0x69, 0x7A, 0x65, 0x00, 0x00, 0x00,
            0x2C, 0x66, 0x00, 0x00,
            0x3F, 0x00, 0x00, 0x00,
        ]
        #expect(try Wire.encoded(OSCMessage("/size", Float(0.5))) == expected)
        #expect(OSCCodec.decode(expected) == .init(messages: [OSCMessage("/size", Float(0.5))], readable: true))
    }

    @Test("読める型はすべて、書いて読むと同じメッセージに戻る")
    func everyTypeRoundTrips() throws {
        let message = OSCMessage(
            "/all",
            arguments: [
                .int(-7), .float(1.25), .string("fade"), .blob([1, 2, 3, 4, 5]), .int64(1 << 40),
                .double(0.1), .bool(true), .bool(false), .null, .impulse,
            ])
        let bytes = try Wire.encoded(message)
        #expect(bytes.count % 4 == 0)
        #expect(OSCCodec.decode(bytes) == .init(messages: [message], readable: true))
    }

    @Test("記号 (S) は文字列として読む")
    func symbolReadsAsString() {
        let bytes = Wire.string("/name") + Wire.string(",S") + Wire.string("tag")
        #expect(OSCCodec.decode(bytes).messages == [OSCMessage("/name", "tag")])
    }

    // MARK: - 境界

    @Test("引数の無いメッセージ・型の印の列を持たない古い形・宛名が / だけのもの")
    func emptyArguments() {
        let none = OSCMessage("/", arguments: [])
        #expect(OSCCodec.decode(Wire.string("/") + Wire.string(",")) == .init(messages: [none], readable: true))
        #expect(OSCCodec.decode(Wire.string("/")) == .init(messages: [none], readable: true))
    }

    @Test("文字列の長さが 4 の倍数の前後でも、埋めを正しく読み書きする", arguments: [
        "", "a", "abc", "abcd", "abcdefg", "abcdefgh",
    ])
    func stringPadding(text: String) throws {
        let message = OSCMessage("/t", text, 1)
        let bytes = try Wire.encoded(message)
        // 宛名 4 + 型の印 4 + 文字列 + 整数 4
        #expect(bytes.count == 4 + 4 + (text.utf8.count / 4 + 1) * 4 + 4)
        #expect(OSCCodec.decode(bytes).messages == [message])
    }

    @Test("長さ 0 の blob と、32 bit の整数の両端")
    func blobAndIntegerEdges() throws {
        let message = OSCMessage(
            "/edge", arguments: [.blob([]), .int(.min), .int(.max), .blob([9])])
        #expect(OSCCodec.decode(try Wire.encoded(message)).messages == [message])
    }

    @Test("Int は 32 bit に収まれば i、収まらなければ h で送る。小数を書いた値は f で送る")
    func argumentConversions() {
        #expect(Int(Int32.max).oscValue == .int(.max))
        #expect(Int(Int32.min).oscValue == .int(.min))
        #expect((Int(Int32.max) + 1).oscValue == .int64(Int64(Int32.max) + 1))
        #expect(0.5.oscValue == .float(0.5))
        #expect(true.oscValue == .bool(true))
        #expect("a".oscValue == .string("a"))
    }

    // MARK: - 束

    @Test("束は中を開き、入れ子も含めて並んだ順に渡す")
    func bundlesOpenInOrder() throws {
        let first = OSCMessage("/a", 1)
        let second = OSCMessage("/b", 2)
        let third = OSCMessage("/c", 3)
        let bytes = Wire.bundle([
            try Wire.encoded(first), Wire.bundle([try Wire.encoded(second)]), try Wire.encoded(third),
        ])
        #expect(OSCCodec.decode(bytes) == .init(messages: [first, second, third], readable: true))
        #expect(OSCCodec.decode(Wire.bundle([])) == .init(messages: [], readable: true))
    }

    @Test("束の入れ子は決めた深さまで開き、それより深いものは読めないとする")
    func bundleDepthLimit() throws {
        let leaf = try Wire.encoded(OSCMessage("/deep", 1))
        func nested(_ count: Int) -> [UInt8] {
            (0..<count).reduce(leaf) { inner, _ in Wire.bundle([inner]) }
        }
        #expect(OSCCodec.decode(nested(OSCCodec.maximumDepth)).readable)
        #expect(OSCCodec.decode(nested(OSCCodec.maximumDepth + 1)) == .init(messages: [], readable: false))
    }

    // MARK: - 読めないものは打ち切る

    @Test("知らない型の印があれば、そのメッセージを読まずに捨てる")
    func unknownTypeTagIsUnreadable() {
        // `x` は何バイトか分からない。0 バイトと推せば、この並びは「1・空・1.5」と読めてしまう。
        // 4 バイトの値だったなら、1.5 の位置には `x` の中身がある — どちらなのかを決める手掛かりは無い
        let bytes = Wire.string("/x") + Wire.string(",ixf") + Wire.int32(1) + Wire.float32(1.5)
        #expect(OSCCodec.decode(bytes) == .init(messages: [], readable: false))
    }

    @Test("束の途中で読めない要素に当たったら、そこから後ろを捨てる")
    func bundleCutsOffTheRest() throws {
        let before = OSCMessage("/before", 1)
        let after = OSCMessage("/after", 2)
        let unreadable = Wire.string("/bad") + Wire.string(",q")
        let bytes = Wire.bundle([try Wire.encoded(before), unreadable, try Wire.encoded(after)])
        #expect(OSCCodec.decode(bytes) == .init(messages: [before], readable: false))
    }

    @Test("読めない形はどれも、値を出さずに読めないとする", arguments: Wire.malformed)
    func malformedIsUnreadable(case: Wire.Malformed) {
        #expect(OSCCodec.decode(`case`.bytes) == .init(messages: [], readable: false))
    }

    // MARK: - 取り出す口

    @Test("取り出す口は、型が合わない・番号が無いときに nil を返す")
    func accessorsRefuseMismatches() {
        let message = OSCMessage("/m", 3, Float(0.5), "x", OSCValue.int64(-2), OSCValue.double(0.25))
        #expect(message.float(0) == 3)
        #expect(message.float(1) == 0.5)
        #expect(message.float(2) == nil)
        #expect(message.float(4) == 0.25)
        #expect(message.int(0) == 3)
        #expect(message.int(1) == nil)  // 小数を丸めない
        #expect(message.int(3) == -2)
        #expect(message.string(2) == "x")
        #expect(message.string(0) == nil)
        #expect(message.float(5) == nil)
        #expect(message.float(-1) == nil)
    }

    // MARK: - 送れないもの

    @Test("宛名が / で始まらない・文字列が 0 を含むメッセージは送れない")
    func encodingRefusesBrokenMessages() {
        #expect(throws: OSCCodec.EncodingProblem.address("size")) {
            try OSCCodec.encode(OSCMessage("size", 1))
        }
        #expect(throws: OSCCodec.EncodingProblem.zeroInString("a\u{0}b")) {
            try OSCCodec.encode(OSCMessage("/s", "a\u{0}b"))
        }
    }
}
