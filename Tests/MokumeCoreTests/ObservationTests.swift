// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation
import Testing

@testable import MokumeCore

/// スケッチと繋いだ観測。GPU を要する。
@Suite(
    "スケッチを外から観測する",
    .enabled(
        if: RenderDevice.isAvailable,
        "この世代のコマンド構造に対応した GPU が無い実行環境ではスキップする")
)
struct ObservationTests {
    /// 左上に白い四角を置く。地は黒。
    final class Corner: Sketch {
        init() {}
        var settings: SketchSettings { SketchSettings(width: 32, height: 24) }
        func draw() {
            background(.display(red: 0, green: 0, blue: 0))
            fill(.display(red: 1, green: 1, blue: 1))
            rect(0, 0, 8, 6)
            expose("frame", frameCount)
            expose("label", "corner")
        }
    }

    /// 一様に塗るだけ。
    final class Flat: Sketch {
        init() {}
        var settings: SketchSettings { SketchSettings(width: 16, height: 16) }
        func draw() { background(.display(red: 0.2, green: 0.2, blue: 0.2)) }
    }

    private func makeFacet() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("mokume-observe-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func request(id: String, scale: Double? = nil, in facet: URL) throws {
        var body = #"{"id":"\#(id)""#
        if let scale { body += ",\"scale\":\(scale)" }
        body += "}"
        try AtomicFile.write(Data(body.utf8), to: facet.appendingPathComponent("request.json"))
    }

    private func readReport(in facet: URL) throws -> [String: Any] {
        let data = try Data(contentsOf: facet.appendingPathComponent("report.json"))
        return try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
    }

    private func makeRuntime(_ sketch: any Sketch, facet: URL, now: @escaping () -> Double = { 0 })
        throws -> SketchRuntime
    {
        try SketchRuntime(
            sketch: sketch, gpu: try RenderDevice(), clock: nil, now: now,
            observer: FrameObserver(directory: facet))
    }

    @Test("要求を置くと、絵と内訳が出てくる")
    func respondsWithAnImageAndItsAccount() throws {
        let facet = try makeFacet()
        let runtime = try makeRuntime(Corner(), facet: facet)
        try runtime.advance()
        try runtime.advance()

        try request(id: "a1", in: facet)
        try runtime.advance()

        let report = try readReport(in: facet)
        #expect(report["id"] as? String == "a1")
        #expect(report["frame"] as? Int == 3)
        #expect((report["size"] as? [String: Any])?["width"] as? Int == 32)
        #expect(report["image"] as? String == "frame.png")
        #expect(
            FileManager.default.fileExists(
                atPath: facet.appendingPathComponent("frame.png").path))
    }

    @Test("差し出した値が、その絵と同じ応答に載る")
    func carriesTheValuesTheSketchExposed() throws {
        let facet = try makeFacet()
        let runtime = try makeRuntime(Corner(), facet: facet)
        try runtime.advance()

        try request(id: "a1", in: facet)
        try runtime.advance()

        let values = try readReport(in: facet)["values"] as? [String: Any]
        let frame = values?["frame"] as? [String: Any]
        #expect(frame?["type"] as? String == "int")
        #expect(frame?["value"] as? Int == 2)
        let label = values?["label"] as? [String: Any]
        #expect(label?["type"] as? String == "string")
        #expect(label?["value"] as? String == "corner")
    }

    @Test("止めていても応答が返り、そのときフレームは進まない")
    func answersWhilePausedWithoutAdvancing() throws {
        let facet = try makeFacet()
        let runtime = try makeRuntime(Corner(), facet: facet)
        try runtime.advance()
        try runtime.advance()
        runtime.pause()

        try request(id: "a1", in: facet)
        try runtime.advance()

        let report = try readReport(in: facet)
        #expect(report["id"] as? String == "a1")
        // 止めた時点の絵をそのまま返す。観測がフレーム番号を動かさない
        #expect(report["frame"] as? Int == 2)
        #expect(runtime.frameCount == 2)
        #expect(report["image"] as? String == "frame.png")
    }

    @Test("まだ 1 枚も描いていなければ、1 枚描いてから応える")
    func drawsTheFirstFrameForTheFirstRequest() throws {
        let facet = try makeFacet()
        let runtime = try makeRuntime(Corner(), facet: facet)
        runtime.pause()

        try request(id: "a1", in: facet)
        try runtime.advance()

        let report = try readReport(in: facet)
        #expect(report["id"] as? String == "a1")
        #expect(report["frame"] as? Int == 1)
        #expect(
            FileManager.default.fileExists(
                atPath: facet.appendingPathComponent("frame.png").path))
    }

    @Test("絵の要約が、実際に描かれたものを映す")
    func summarizesWhatWasActuallyDrawn() throws {
        let facet = try makeFacet()
        let runtime = try makeRuntime(Corner(), facet: facet)
        try runtime.advance()
        try request(id: "a1", in: facet)
        try runtime.advance()

        let stats = try #require(try readReport(in: facet)["stats"] as? [String: Any])
        let fraction = try #require(stats["contentFraction"] as? Double)
        // 左上の 8x6 が白。面は 32x24 なので、地と違う点は全体の 1 割弱
        #expect(fraction > 0)
        #expect(fraction < 0.2)

        let bounds = try #require(stats["contentBounds"] as? [String: Any])
        #expect((bounds["x"] as? Double) == 0)
        #expect((bounds["y"] as? Double) == 0)
        #expect((bounds["width"] as? Double ?? 1) < 0.4)
    }

    @Test("一様な絵では、内容のある点が 0 になる")
    func reportsNoContentForAFlatImage() throws {
        let facet = try makeFacet()
        let runtime = try makeRuntime(Flat(), facet: facet)
        try runtime.advance()
        try request(id: "a1", in: facet)
        try runtime.advance()

        let stats = try #require(try readReport(in: facet)["stats"] as? [String: Any])
        #expect(stats["contentFraction"] as? Double == 0)
        #expect(stats["contentBounds"] == nil)
    }

    @Test("縮めて撮ると、小さい絵が出てくる")
    func honorsTheRequestedScale() throws {
        let facet = try makeFacet()
        let runtime = try makeRuntime(Corner(), facet: facet)
        try runtime.advance()
        try request(id: "a1", scale: 0.5, in: facet)
        try runtime.advance()

        let grid = try #require(try readReport(in: facet)["stats"] as? [String: Any])
        let sampleGrid = try #require(grid["sampleGrid"] as? [String: Any])
        // 32x24 を半分にした 16x12 を、64 点の格子で数えようとすると絵の大きさで頭打ちになる
        #expect(sampleGrid["width"] as? Int == 16)
        #expect(sampleGrid["height"] as? Int == 12)
        // 面の大きさは縮めない — 何を描いた面かは変わらないため
        #expect((try readReport(in: facet)["size"] as? [String: Any])?["width"] as? Int == 32)
    }

    @Test("走らせている重さが載る")
    func carriesTheRuntimeLoad() throws {
        let facet = try makeFacet()
        var clock = 0.0
        let runtime = try makeRuntime(Corner(), facet: facet, now: { clock })
        for _ in 0..<4 {
            clock += 0.016
            try runtime.advance()
        }
        try request(id: "a1", in: facet)
        clock += 0.016
        try runtime.advance()

        let load = try #require(try readReport(in: facet)["load"] as? [String: Any])
        let rate = try #require(load["frameRate"] as? Double)
        #expect(abs(rate - 62.5) < 0.5)
        #expect(load["thermalState"] as? String != nil)
        #expect((load["memoryMB"] as? Double ?? 0) > 0)
    }
}
