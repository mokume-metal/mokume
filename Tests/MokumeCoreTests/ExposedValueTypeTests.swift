// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation
import Testing

@testable import MokumeCore

/// ``Sketch/expose(_:_:)-(_,Double)`` が差し出した値が、観測の応答に**型と値の組のまま**、
/// **そのフレームの値として**載ること。GPU を要する。
///
/// 差し出す口は型ごとに 5 本あり、`ObservationTests` が通しているのは `Int` と `String`
/// だけだった。`Float` の口が `int` を名乗っても、`Bool` の口が文字列で差し出しても、
/// 緑のままになる ([#1386](https://github.com/mokume-metal/mokume/issues/1386))。
///
/// 綴りは `Schemas/observe-report.schema.json` の `values` が正典で、`Float` と `Double`
/// はどちらも `float` を名乗る (``ExposedValue``)。
@Suite(
    "差し出した値の型と、フレームの境目",
    .enabled(
        if: RenderDevice.isAvailable,
        "この世代のコマンド構造に対応した GPU が無い実行環境ではスキップする")
)
struct ExposedValueTypeTests {
    /// 3 つの型を毎フレーム差し出し、**最初のフレームだけ** もう 1 つ差し出す。
    final class Exposing: Sketch {
        init() {}
        var settings: SketchSettings { SketchSettings(width: 16, height: 16) }
        func draw() {
            background(.display(red: 0, green: 0, blue: 0))
            // 2 進で割り切れる値を選ぶ。Float から Double へ移るだけで誤差が出る値だと、
            // 型が違うのか丸めなのかが見分けられない
            expose("ratio", 0.25 as Double)
            expose("gain", 0.75 as Float)
            expose("lit", true)
            if frameCount == 1 { expose("once", 1.5 as Double) }
        }
    }

    private func makeFacet() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("mokume-exposed-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
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

    @Test("Double・Float・Bool が、型と値の組で応答に載る")
    func eachTypeArrivesWithItsName() throws {
        let facet = try makeFacet()
        let runtime = try SketchRuntime(
            sketch: Exposing(), gpu: try RenderDevice(), clock: nil, now: { 0 },
            observer: FrameObserver(directory: facet))
        try request(id: "e1", in: facet)
        try runtime.advance()

        let values = try answer(in: facet).values
        #expect(values["ratio"]?["type"] as? String == "float")
        #expect(values["ratio"]?["value"] as? Double == 0.25)
        #expect(values["gain"]?["type"] as? String == "float")
        #expect(values["gain"]?["value"] as? Double == 0.75)
        #expect(values["lit"]?["type"] as? String == "bool")
        #expect(values["lit"]?["value"] as? Bool == true)
    }

    /// 応答に載るのは**その絵を描いたフレームで差し出した値**である (``Sketch/expose(_:_:)-(_,Double)``)。
    /// 前のフレームの値が残ると、読み手は「いまも差し出されている」と読み違える —
    /// 条件の中でだけ差し出す値 (`if` の中の `expose`) で起きる。
    @Test("フレーム 1 だけで差し出した値は、フレーム 2 の応答に残らない")
    func aValueFromTheLastFrameDoesNotLinger() throws {
        let facet = try makeFacet()
        let runtime = try SketchRuntime(
            sketch: Exposing(), gpu: try RenderDevice(), clock: nil, now: { 0 },
            observer: FrameObserver(directory: facet))

        // まずフレーム 1 を撮る。**差し出したことは応答に載る** — ここで載っていなければ、
        // 下の「残らない」は何も見ていない
        try request(id: "e1", in: facet)
        try runtime.advance()
        let first = try answer(in: facet)
        #expect(first.frame == 1)
        #expect(first.values["once"]?["value"] as? Double == 1.5)

        try request(id: "e2", in: facet)
        try runtime.advance()
        let second = try answer(in: facet)
        #expect(second.frame == 2)
        #expect(second.values["once"] == nil)
        // 毎フレーム差し出している値は残っている (値ごと消えたわけではない)
        #expect(second.values["ratio"]?["value"] as? Double == 0.25)
    }
}
