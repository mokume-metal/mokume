// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation
import Testing

@testable import MokumeCore

/// 外から届くものを受ける入り口の状態が、観測の応答の `inputs` に載ること
/// (ADR-0028 決定 4・#1988)。GPU を要する。
///
/// 「なぜ値が来ないか」(許可を待っている・機材が無い) と、最後に値が届いたフレームを、
/// 絵を開かずに読めることが約束である。
@Suite(
    "入り口の状態と観測",
    .serialized,
    .enabled(
        if: RenderDevice.isAvailable,
        "この世代のコマンド構造に対応した GPU が無い実行環境ではスキップする")
)
struct InletObservationTests {
    /// 名乗る入り口。値はフレーム 2 で 1 つだけ届く。
    final class Reporting: Inlet {
        let input = ExternalInput<Int>(name: "probe", state: .waitingForPermission)
        func supply() { _ = input.take() }
        var report: SourceReport? { input.report }
    }

    /// 名乗らない入り口 (既存の入り口の形)。
    final class Silent: Inlet {
        func supply() {}
    }

    struct Both: Plugin {
        let reporting: Reporting
        func register(into registry: PluginRegistry) {
            registry.add(inlet: reporting)
            registry.add(inlet: Silent())
        }
    }

    final class Observed: Sketch {
        nonisolated(unsafe) static var declared: [any Plugin] = []
        init() {}
        var settings: SketchSettings { SketchSettings(width: 16, height: 16) }
        var plugins: [any Plugin] { Self.declared }
        func draw() { background(0, 0, 0) }
    }

    private func makeFacet() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("mokume-inlet-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func observe(id: String, in facet: URL, with runtime: SketchRuntime) throws -> [String: Any] {
        try AtomicFile.write(
            Data(#"{"id":"\#(id)"}"#.utf8), to: facet.appendingPathComponent("request.json"))
        try runtime.advance()
        let data = try Data(contentsOf: facet.appendingPathComponent("report.json"))
        return try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
    }

    @Test("名乗る入り口だけが、状態と最後に届いたフレームとともに載る")
    func reportingInletsAppear() throws {
        let reporting = Reporting()
        Observed.declared = [Both(reporting: reporting)]
        let facet = try makeFacet()
        let runtime = try SketchRuntime(
            sketch: Observed(), gpu: try RenderDevice(), clock: nil, now: { 0 },
            observer: FrameObserver(directory: facet))

        // フレーム 1: まだ何も届いていない
        let first = try observe(id: "i1", in: facet, with: runtime)
        let firstInputs = first["inputs"] as? [[String: Any]]
        #expect(firstInputs?.count == 1)
        #expect(firstInputs?.first?["name"] as? String == "probe")
        #expect(firstInputs?.first?["state"] as? String == "waitingForPermission")
        #expect(firstInputs?.first?["lastFrame"] == nil)

        // フレーム 2 の前に届く
        reporting.input.setState(.running)
        reporting.input.send(1)
        let second = try observe(id: "i2", in: facet, with: runtime)
        let secondInputs = second["inputs"] as? [[String: Any]]
        #expect(secondInputs?.first?["state"] as? String == "running")
        #expect(secondInputs?.first?["lastFrame"] as? Int == 2)
        runtime.closePlugins()
    }

    @Test("名乗る入り口が無ければ、鍵ごと載らない")
    func noReportingInletsNoKey() throws {
        Observed.declared = []
        let facet = try makeFacet()
        let runtime = try SketchRuntime(
            sketch: Observed(), gpu: try RenderDevice(), clock: nil, now: { 0 },
            observer: FrameObserver(directory: facet))
        let report = try observe(id: "n1", in: facet, with: runtime)
        #expect(report["inputs"] == nil)
        runtime.closePlugins()
    }
}

/// 名乗りの 1 行の鍵が、正典の代表例の 1 行と一致する。GPU は要らない。
@Suite("入り口の名乗りの形")
struct SourceReportShapeTests {
    @Test("届いた後の名乗りの鍵が、代表例の 1 行目と一致する")
    func staysInStepWithTheCanonicalExample() throws {
        let report = SourceReport(
            name: "camera", state: .running, lastArrival: Arrival(frame: 3, time: 0.05, hostTime: 99))
        let produced =
            try JSONSerialization.jsonObject(with: JSONEncoder().encode(report)) as? [String: Any]
        let exampleURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Schemas/examples/observe-report.json")
        let example =
            try JSONSerialization.jsonObject(with: Data(contentsOf: exampleURL)) as? [String: Any]
        let row = (example?["inputs"] as? [[String: Any]])?.first
        #expect(Set(produced?.keys ?? [:].keys) == Set(row?.keys ?? [:].keys))
        // 届いた瞬間の host time は機械ごとの起点に依るので、応答には出さない
        #expect(produced?["hostTime"] == nil)
    }
}
