// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation
import MokumeTestSupport
import Testing

@testable import MokumeCore

/// ``Sketch/expose(_:_:)-(_,Double)`` に非有限の数 (NaN・無限) を差し出しても、観測の応答が止まらない
/// こと ([#2271](https://github.com/mokume-metal/mokume/issues/2271))。GPU を要する。
///
/// 応答は JSON で、非有限の数を符号化できない。差し出した値をそのまま溜めると、その枚の応答が
/// まるごと置けなくなる (``AtomicFile/publishJSON(_:to:_:)`` は同じ置き場所の 2 回目以降の失敗を
/// 言わないので、黙ったまま続く)。差し出さなかった値は応答の `values` に載らず、**他の値は載る**。
/// 1 度だけ標準エラーへ名乗る ([ADR-0030] 決定 3)。
///
/// [ADR-0030]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0030-parameter-surfaces.md
@Suite(
    "非有限の値は観測へ差し出されない",
    .enabled(
        if: RenderDevice.isAvailable,
        "この世代のコマンド構造に対応した GPU が無い実行環境ではスキップする")
)
struct ExposeNonFiniteTests {
    /// 有限の値 2 つの間に、非有限を 3 つ (Float の NaN・Double の無限・Float の負の無限) 差し出す。
    final class Exposing: Sketch {
        init() {}
        var settings: SketchSettings { SketchSettings(width: 16, height: 16) }
        func draw() {
            background(.display(red: 0, green: 0, blue: 0))
            expose("ratio", 0.25 as Double)
            expose("gain", Float.nan)
            expose("big", Double.infinity)
            expose("low", -Float.infinity)
            // 有限の端 (陰性対照)。Float の最大も、0 に近い Double も差し出せる
            expose("edge", Float.greatestFiniteMagnitude)
            expose("tiny", 1e-300 as Double)
        }
    }

    /// 有限の値だけを差し出す。
    final class Finite: Sketch {
        init() {}
        var settings: SketchSettings { SketchSettings(width: 16, height: 16) }
        func draw() {
            background(.display(red: 0, green: 0, blue: 0))
            expose("ratio", 0.25 as Double)
            expose("edge", Float.greatestFiniteMagnitude)
        }
    }

    /// 1 枚目に `measure` で測り、2 枚目に同じ名前へ非有限を差し出す。
    final class Remeasuring: Sketch {
        init() {}
        var settings: SketchSettings { SketchSettings(width: 16, height: 16) }
        func draw() {
            background(.display(red: 0, green: 0, blue: 0))
            if frameCount == 1 {
                measure("ms") {}
            } else {
                expose("ms", Double.nan)
            }
        }
    }

    private func makeFacet() throws -> URL {
        let directory = try TestScratch.directory("mokume-exposed-nonfinite")
        return directory
    }

    private func request(id: String, in facet: URL) throws {
        try AtomicFile.write(
            Data(#"{"id":"\#(id)"}"#.utf8), to: facet.appendingPathComponent("request.json"))
    }

    /// 応答の `frame` と `values`。
    private func answer(in facet: URL) throws -> (frame: Int?, values: [String: [String: Any]]) {
        let data = try Data(contentsOf: facet.appendingPathComponent("report.json"))
        let report = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
        return (
            report["frame"] as? Int,
            report["values"] as? [String: [String: Any]] ?? [:]
        )
    }

    @Test("非有限を差し出しても、その枚の応答は他の値を載せて置かれる")
    func theReplyIsStillPlaced() throws {
        let facet = try makeFacet()
        let runtime = try SketchRuntime(
            sketch: Exposing(), gpu: try RenderDevice(), clock: nil, now: { 0 },
            observer: FrameObserver(directory: facet))
        try request(id: "n1", in: facet)
        try runtime.advance()

        let reply = try answer(in: facet)
        #expect(reply.frame == 1)
        // 有限の値は載る
        #expect(reply.values["ratio"]?["value"] as? Double == 0.25)
        #expect(reply.values["edge"]?["type"] as? String == "float")
        #expect(reply.values["tiny"]?["value"] as? Double == 1e-300)
        // 非有限は載らない (差し出されなかった)
        #expect(reply.values["gain"] == nil)
        #expect(reply.values["big"] == nil)
        #expect(reply.values["low"] == nil)
        #expect(Set(reply.values.keys) == ["ratio", "edge", "tiny"])
    }

    @Test("非有限を差し出した枚が続いても、応答は毎枚置かれ、名乗るのは 1 度だけ")
    func itIsSaidOnce() throws {
        let facet = try makeFacet()
        let runtime = try SketchRuntime(
            sketch: Exposing(), gpu: try RenderDevice(), clock: nil, now: { 0 },
            observer: FrameObserver(directory: facet))
        #expect(!runtime.warnings.hasWarned(.nonFiniteExposed), "何も差し出していないのに名乗った")

        try request(id: "s1", in: facet)
        try runtime.advance()
        let first = try #require(runtime.warnings.message(for: .nonFiniteExposed), "差し出されなかったのに黙っていた")
        // 最初に非有限を差し出した名前と、渡された値を言う (3 つのうち最初の `gain`・NaN)
        #expect(first.contains("\"gain\""))
        #expect(first.contains("nan"))
        #expect(!first.contains("\n"))

        // 次の枚でも置かれる。控えた文面は変わらない (言い直していない)
        try request(id: "s2", in: facet)
        try runtime.advance()
        let second = try answer(in: facet)
        #expect(second.frame == 2)
        #expect(second.values["ratio"]?["value"] as? Double == 0.25)
        #expect(runtime.warnings.message(for: .nonFiniteExposed) == first)
        #expect(runtime.warnings.count(where: { $0 == .nonFiniteExposed }) == 1)
    }

    @Test("有限の値だけなら、何も名乗らない")
    func finiteValuesSayNothing() throws {
        let facet = try makeFacet()
        let runtime = try SketchRuntime(
            sketch: Finite(), gpu: try RenderDevice(), clock: nil, now: { 0 },
            observer: FrameObserver(directory: facet))
        try request(id: "f1", in: facet)
        try runtime.advance()

        let reply = try answer(in: facet)
        #expect(Set(reply.values.keys) == ["ratio", "edge"])
        #expect(!runtime.warnings.hasWarned(.nonFiniteExposed))
    }

    /// 測った値は測り直すまで、フレームの頭で差し出し直される。同じ名前に非有限を差し出しても
    /// 差し出されないので、測った値が載ったまま残る (説明文が名乗る例外)。
    @Test("measure した名前に非有限を差し出すと、測った値が残る")
    func aMeasuredNameKeepsItsMeasurement() throws {
        let facet = try makeFacet()
        let runtime = try SketchRuntime(
            sketch: Remeasuring(), gpu: try RenderDevice(), clock: nil, now: { 0 },
            observer: FrameObserver(directory: facet))

        try request(id: "m1", in: facet)
        try runtime.advance()
        let first = try answer(in: facet)
        #expect(first.values["ms"]?["value"] as? Double == 0)

        try request(id: "m2", in: facet)
        try runtime.advance()
        let second = try answer(in: facet)
        #expect(second.frame == 2)
        #expect(second.values["ms"]?["type"] as? String == "float")
        #expect(second.values["ms"]?["value"] as? Double == 0, "測った値が残る")
        #expect(runtime.warnings.hasWarned(.nonFiniteExposed))
    }
}
