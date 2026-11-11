// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation
import Testing

@testable import MokumeCore

/// 型に収まらない数の読み分け (#2805)。Foundation の内部の誤りの字面に頼るので、
/// その形が変わったら、ここが赤くなって気付く。
@Suite("外から置かれた数の読み分け")
struct WireNumberTests {
    private enum Key: String, CodingKey { case number }

    private struct Read<Number: Decodable & Equatable>: Decodable {
        let reading: WireNumber<Number>
        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: Key.self)
            reading = try container.decodeWireNumber(Number.self, forKey: .number)
        }
    }

    private func read<Number: Decodable & Equatable>(
        _ type: Number.Type, _ json: String
    ) throws -> WireNumber<Number> {
        try JSONDecoder().decode(Read<Number>.self, from: Data(json.utf8)).reading
    }

    @Test("整数に読める数は値になり、鍵が無い・null は省略")
    func readsWholeNumbersAndOmissions() throws {
        #expect(try read(Int.self, #"{"number":3}"#) == .value(3))
        #expect(try read(Int.self, #"{"number":1e2}"#) == .value(100))
        #expect(try read(Int.self, #"{"number":2.0}"#) == .value(2))
        #expect(try read(Int.self, "{}") == .absent)
        #expect(try read(Int.self, #"{"number":null}"#) == .absent)
        #expect(try read(Double.self, #"{"number":0.25}"#) == .value(0.25))
    }

    @Test(
        "Int に収まらない大きな数は、符号つきの桁あふれ",
        arguments: [
            (#"{"number":1e19}"#, false),
            (#"{"number":-1e19}"#, true),
            (#"{"number":1e400}"#, false),
            (#"{"number":-1e400}"#, true),
            (#"{"number":123456789012345678901234567890}"#, false),
            (#"{"number":-123456789012345678901234567890}"#, true),
            // `Int` の端の 1 つ外 (#3959。`Decimal` で読む段が寄せる)
            (#"{"number":9223372036854775808}"#, false),
            (#"{"number":-9223372036854775809}"#, true),
            (#"{"number":100000000000000000000000000000.0}"#, false),
        ] as [(String, Bool)])
    func readsABigIntegerAsAnOverflowWithItsSign(_ json: String, _ negative: Bool) throws {
        #expect(try read(Int.self, json) == .overflow(negative: negative))
    }

    @Test("Double に収まらない大きな数は、符号つきの桁あふれ", arguments: [("1e400", false), ("-1e400", true)])
    func readsABigDoubleAsAnOverflowWithItsSign(_ number: String, _ negative: Bool) throws {
        #expect(try read(Double.self, #"{"number":\#(number)}"#) == .overflow(negative: negative))
    }

    @Test("整数でない数は、桁あふれにしない", arguments: ["2.5", "-0.5", "1e-3"])
    func readsAFractionAsNotWhole(_ number: String) throws {
        #expect(try read(Int.self, #"{"number":\#(number)}"#) == .notWhole)
    }

    /// **桁の多い数も、整数かは 10 進の値で決める** ([#3959](https://github.com/mokume-metal/mokume/issues/3959))。
    /// `JSONDecoder` の `Int` への読みは `1.00000000000000000000001` を 1 に、`12345678901234567.5` を
    /// 12345678901234567 にし、`Int` に収まらない数の誤りの字面を `Double` に丸めると
    /// `100000000000000000000000000000.5` を整数の桁あふれと読む。
    @Test(
        "桁の多い端数つきの数は、整数でない",
        arguments: [
            "1.00000000000000000000001", "12345678901234567.5", "-0.00000000000000000000001",
            "0.99999999999999999999999", "9007199254740993.5", "9223372036854775807.5",
            "100000000000000000000000000000.5",
        ])
    func readsALongFractionAsNotWhole(_ number: String) throws {
        #expect(try read(Int.self, #"{"number":\#(number)}"#) == .notWhole, "\(number)")
    }

    @Test(
        "Int に収まる整数は、綴りによらずその値",
        arguments: [
            ("12345678901234567.0", 12_345_678_901_234_567), ("1.00000000000000000000000", 1),
            ("9223372036854775807", .max), ("-9223372036854775808", .min),
            ("-0", 0), ("-0.0", 0), ("1E+2", 100), ("10e-1", 1),
        ] as [(String, Int)])
    func readsAWholeNumberInAnySpelling(_ number: String, _ value: Int) throws {
        #expect(try read(Int.self, #"{"number":\#(number)}"#) == .value(value), "\(number)")
    }

    /// 10 進の値の判定は、JSON から届かない値 (`NaN`) も整数と読まない。MCP サーバの引数の読み
    /// (`JSONRPC.wholeNumber`) は、入口で有限でない数を断るので、ここで直に固定する。
    @Test("10 進の NaN は整数でない")
    func refusesADecimalNaN() {
        #expect(WholeDecimal.integer(.nan) == nil)
        #expect(WholeDecimal.integer(Decimal(string: "1e30")!) == .max)
        #expect(WholeDecimal.integer(Decimal(string: "-1e30")!) == .min)
    }

    @Test("型の違う値は、場所つきの DecodingError で投げる", arguments: [#""0.5""#, "true", "[]", "{}"])
    func throwsATypeMismatchWithItsPlace(_ value: String) throws {
        do {
            _ = try read(Int.self, #"{"number":\#(value)}"#)
            Issue.record("型の違う値が読めた")
        } catch let error as DecodingError {
            guard case .typeMismatch(_, let context) = error else {
                Issue.record("\(error)")
                return
            }
            #expect(context.codingPath.map(\.stringValue) == ["number"])
        }
    }

    @Test("DecodingError でない誤りだけを桁あふれと読む")
    func readsOnlyANonDecodingErrorAsAnOverflow() {
        struct Other: Error {}
        #expect(DecodingError.isNumberOverflow(Other()))
        #expect(!DecodingError.isNumberOverflow(DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: ""))))
    }
}
