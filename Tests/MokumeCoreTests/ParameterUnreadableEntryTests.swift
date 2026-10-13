// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation
import Testing

@testable import MokumeCore
@testable import mokume

/// 要求の中の 1 件が読めなくても、要求ごと黙って捨てずに応答すること
/// ([#2496](https://github.com/mokume-metal/mokume/issues/2496))。
///
/// つまみの面は、`id` を読める要求には必ず応答し、当てなかった 1 件ごとに理由を載せる
/// ([ADR-0030] 決定 2)。要求を 1 件ずつ緩く読まないころは、`1e400` (`Double` に収まらない数)・
/// 知らない `type`・型に合わない値のどれか 1 件で `JSONDecoder` が要求ごと断り、
/// `RequestFile.pending()` が読めなかった要求を確定させて捨てていた。書いた側には何も返らず、
/// 同じ要求の他の値も入らない。入力の面は同じ形を #1132 で「解けない 1 件だけ外して残りは通す」
/// に直した ([#1186](https://github.com/mokume-metal/mokume/issues/1186))。
///
/// [ADR-0030]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0030-parameter-surfaces.md
@Suite("読めない 1 件は、その 1 件だけ rejected に載る")
@MainActor
struct ParameterUnreadableEntryTests {
    final class Pair: Sketch {
        @Param var gain: Float = 0.5
        @Param var count: Int = 3
        @Param var pair: SIMD2<Float> = SIMD2(1, 2)
        @Param var tint: LinearRGBA = LinearRGBA(premultipliedRed: 0.25, green: 0.5, blue: 0.75, alpha: 1)
    }

    private func makeDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("mokume-unreadable-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func jsonObject(at url: URL) throws -> [String: Any] {
        let data = try Data(contentsOf: url)
        return try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
    }

    private func place(_ request: String, in facet: URL) throws {
        try request.write(
            to: facet.appendingPathComponent("request.json"), atomically: true, encoding: .utf8)
    }

    /// 要求を置いて、応えを取る。**応えが無ければ、要求が黙って捨てられたということ。**
    private func answer(_ request: String, from surface: ParamSurface, in facet: URL) throws
        -> ParamReport
    {
        try place(request, in: facet)
        return try #require(surface.drain(), "要求が無言で捨てられた: \(request)")
    }

    private func pairSurface() throws -> (Pair, ParamSurface, URL) {
        let facet = try makeDirectory()
        let sketch = Pair()
        let surface = ParamSurface(directory: facet, sketch: sketch)
        surface.start()
        return (sketch, surface, facet)
    }

    // MARK: - Double に収まらない数 (完了条件 1・2)

    @Test("Double に収まらない数は、その 1 件だけ notFinite で拒み、他は当たる", arguments: ["1e400", "-1e400"])
    func anOverflowingNumberIsRefusedAlone(number: String) throws {
        let (sketch, surface, facet) = try pairSurface()

        let report = try answer(
            #"{"id":"p2","values":[{"name":"count","type":"int","value":8},{"name":"gain","type":"float","value":\#(number)}]}"#,
            from: surface, in: facet)

        #expect(sketch.count == 8, "同じ要求の他の値は入る")
        #expect(sketch.gain == 0.5, "拒んだ値は置かない")
        #expect(report.rejected == [.init(name: "gain", reason: .notFinite)])
        #expect(report.clamped.isEmpty)
        // 応答は置かれ、要求の識別子を echo する
        let reply = try jsonObject(at: facet.appendingPathComponent("report.json"))
        #expect(reply["id"] as? String == "p2")
        let rejected = reply["rejected"] as? [[String: Any]] ?? []
        #expect(rejected.count == 1)
        #expect(rejected.first?["name"] as? String == "gain")
        #expect(rejected.first?["reason"] as? String == "notFinite")
    }

    @Test("組と色の成分が Double に収まらなくても、その 1 件だけ notFinite", arguments: [
        (#"{"type":"vec2","value":[1e400,0]}"#, "pair"),
        (#"{"type":"vec2","value":[0,-1e400]}"#, "pair"),
        (#"{"type":"color","value":{"red":1e400,"green":0,"blue":0,"alpha":1}}"#, "tint"),
    ])
    func anOverflowingComponentIsRefusedAlone(wire: String, name: String) throws {
        let (sketch, surface, facet) = try pairSurface()

        let report = try answer(
            #"{"id":"c1","values":[{"name":"count","type":"int","value":7},{"name":"\#(name)",\#(wire.dropFirst())]}"#,
            from: surface, in: facet)

        #expect(sketch.count == 7)
        #expect(report.rejected == [.init(name: name, reason: .notFinite)])
    }

    // MARK: - 形の違う 1 件 (完了条件 3)

    @Test("形の違う 1 件は typeMismatch で rejected に載り、同じ要求の他の値は当たる", arguments: [
        #"{"name":"gain","type":"float","value":"abc"}"#,
        #"{"name":"count","type":"int","value":3.5}"#,
        #"{"name":"count","type":"int","value":1e400}"#,
        #"{"name":"count","type":"int","value":9223372036854775808}"#,
        #"{"name":"gain","type":"hologram","value":1}"#,
        #"{"name":"gain","type":"float"}"#,
        #"{"name":"pair","type":"vec2","value":[1,2,3]}"#,
        #"{"name":"pair","type":"vec2","value":[1,"a"]}"#,
        #"{"name":"tint","type":"color","value":{"red":1}}"#,
        #"{"name":"gain","value":1}"#,
    ])
    func aMalformedEntryIsRefusedAlone(entry: String) throws {
        let (sketch, surface, facet) = try pairSurface()
        // 1e400 を含む 1 件は JSONSerialization も読めないので、名前は綴りから取る
        let name = try #require(entry.firstMatch(of: #/"name":"([^"]*)"/#)?.output.1).description

        // 他の値は、読めない 1 件の前にも後ろにも置く
        let report = try answer(
            #"{"id":"m1","values":[{"name":"aaa","type":"float","value":1},\#(entry),{"name":"count","type":"int","value":8}]}"#,
            from: surface, in: facet)

        #expect(sketch.count == 8, "読めた値は、読めない 1 件の前後どちらにあっても当たる")
        #expect(sketch.gain == 0.5)
        #expect(sketch.pair == SIMD2(1, 2))
        #expect(
            report.rejected.contains(.init(name: name, reason: .typeMismatch)),
            "読めなかった 1 件が理由つきで載る: \(report.rejected)")
        // 要求の識別子は読めるので、応答は返る
        let reply = try jsonObject(at: facet.appendingPathComponent("report.json"))
        #expect(reply["id"] as? String == "m1")
    }

    @Test("名前を読めない 1 件は、名前を空にして typeMismatch で載る。他の値は当たる", arguments: [
        #"{"type":"float","value":1}"#,
        #"{"name":5,"type":"float","value":1}"#,
        #"5"#,
        #"null"#,
    ])
    func anEntryWithoutAReadableNameIsRefusedAlone(entry: String) throws {
        let (sketch, surface, facet) = try pairSurface()

        let report = try answer(
            #"{"id":"n1","values":[\#(entry),{"name":"count","type":"int","value":8}]}"#,
            from: surface, in: facet)

        #expect(sketch.count == 8)
        #expect(report.rejected == [.init(name: "", reason: .typeMismatch)])
    }

    @Test("読める要求は今までどおり当たり、何も拒まない")
    func aWellFormedRequestIsUntouched() throws {
        let (sketch, surface, facet) = try pairSurface()

        let report = try answer(
            #"{"id":"ok","values":[{"name":"count","type":"int","value":8},{"name":"gain","type":"float","value":0.75},{"name":"pair","type":"vec2","value":[3,4]}]}"#,
            from: surface, in: facet)

        #expect(sketch.count == 8)
        #expect(sketch.gain == 0.75)
        #expect(sketch.pair == SIMD2(3, 4))
        #expect(report.rejected.isEmpty)
        #expect(report.clamped.isEmpty)
    }

    // MARK: - 名前が先 (反証 5)

    /// 綴りを間違えた書き手には、中身の誤りより先に名前の誤りを伝える。
    @Test("宣言に無い名前は、中身が読めなくても unknownName が先になる", arguments: [
        #"{"name":"nonexistent","type":"float","value":1e400}"#,
        #"{"name":"nonexistent","type":"hologram","value":1}"#,
        #"{"name":"nonexistent","type":"int","value":3.5}"#,
        #"{"name":"nonexistent","type":"vec2","value":[1,2,3]}"#,
        #"{"name":"nonexistent"}"#,
    ])
    func anUnknownNameComesFirst(entry: String) throws {
        let (sketch, surface, facet) = try pairSurface()

        let report = try answer(
            #"{"id":"u1","values":[\#(entry),{"name":"count","type":"int","value":8}]}"#,
            from: surface, in: facet)

        #expect(report.rejected == [.init(name: "nonexistent", reason: .unknownName)])
        #expect(sketch.count == 8)
    }

    @Test("宣言のある名前は、中身が読めないときの理由のまま")
    func aDeclaredNameKeepsTheReadingReason() throws {
        let (_, surface, facet) = try pairSurface()

        let report = try answer(
            #"{"id":"d1","values":[{"name":"gain","type":"float","value":1e400},{"name":"count","type":"hologram","value":1}]}"#,
            from: surface, in: facet)

        #expect(
            report.rejected == [
                .init(name: "count", reason: .typeMismatch), .init(name: "gain", reason: .notFinite),
            ])
    }

    // MARK: - 外枠が読めない要求 (完了条件 4・反証 7)

    /// **外枠は据え置き。** `id` が読めても `values` が配列でない・欠けた要求は応答しない
    /// ([#2550](https://github.com/mokume-metal/mokume/issues/2550) が ADR-0030 決定 2 との
    /// 食い違いを持つ)。この検査は、決まるまで今の形を固定する。
    @Test("外枠が読めない要求は、これまでどおり応答せず捨てる", arguments: [
        #"{"id":"x","values":5}"#,
        #"{"id":"x"}"#,
        #"{"id":"x","values":null}"#,
        #"{"values":[{"name":"count","type":"int","value":8}]}"#,
        #"{"id":5,"values":[{"name":"count","type":"int","value":8}]}"#,
        #"{"id":"x","values":[{"name":"count","type":"int","value":8}"#,
        #"not json"#,
    ])
    func aRequestWithAnUnreadableFrameIsDropped(request: String) throws {
        let (sketch, surface, facet) = try pairSurface()
        let before = try Data(contentsOf: facet.appendingPathComponent("report.json"))

        try place(request, in: facet)

        #expect(surface.drain() == nil, "外枠が読めない (echo する id か、書く values が無い) ので、応答しない")
        #expect(sketch.count == 3)
        #expect(try Data(contentsOf: facet.appendingPathComponent("report.json")) == before)
    }
}
