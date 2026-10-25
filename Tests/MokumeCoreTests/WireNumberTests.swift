// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation
import Testing

@testable import MokumeCore

/// 型に収まらない数の読み分け (#2805)。Foundation の内部の誤りの字面に頼るので、
/// その形が変わったら、ここが赤くなって気付く。
@Suite("外から置かれた数の読み分け")
nonisolated struct WireNumberTests {
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
