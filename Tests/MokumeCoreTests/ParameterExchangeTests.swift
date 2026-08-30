// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation
import Testing

@testable import MokumeCore
@testable import mokume

/// つまみの面 (`.mokume/params`) の往復。
///
/// 面の形は `Schemas/params-*.schema.json` が正典で、ここが見るのは**実装がその形を
/// 出し、その形を読めること**である ([ADR-0018](https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0018-observation-and-control-surface.md) 決定 4)。
@Suite("宣言した値を、外から読んで書き換えられる")
struct ParameterExchangeTests {
    final class Knobbed: Sketch {
        @Param(0...200) var radius: Double = 80
        @Param(1...8) var count: Int = 3
        @Param var spinning: Bool = true
        @Param(choices: ["circle", "square"]) var shape: String = "circle"
    }

    private func makeFacet() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("mokume-params-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func write(request: String, to facet: URL) throws {
        try request.write(
            to: facet.appendingPathComponent("request.json"), atomically: true, encoding: .utf8)
    }

    private func report(from facet: URL) throws -> [String: Any] {
        let data = try Data(contentsOf: facet.appendingPathComponent("report.json"))
        return try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
    }

    private func params(in report: [String: Any]) -> [String: [String: Any]] {
        let entries = report["params"] as? [[String: Any]] ?? []
        return Dictionary(uniqueKeysWithValues: entries.map { ($0["name"] as? String ?? "", $0) })
    }

    @Test("いまの値と宣言が、要求を出さなくても読める")
    func publishesOnStart() throws {
        let facet = try makeFacet()
        let sketch = Knobbed()
        ParamSurface(directory: facet, sketch: sketch).start()

        let report = try report(from: facet)
        #expect(report["schemaVersion"] as? Int == 1)
        #expect(report["revision"] as? Int == 1)
        #expect(report["id"] == nil)
        let entries = report["params"] as? [[String: Any]] ?? []
        // 並びは宣言した順 — 面の情報の一部として保つ
        #expect(entries.map { $0["name"] as? String } == ["radius", "count", "spinning", "shape"])
        #expect(entries[0]["min"] as? Double == 0)
        #expect(entries[0]["max"] as? Double == 200)
        #expect(entries[2]["min"] == nil)
        #expect(entries[3]["choices"] as? [String] == ["circle", "square"])
    }

    @Test("書き換えると値が入り、要求の識別子が返る")
    func appliesAWrite() throws {
        let facet = try makeFacet()
        let sketch = Knobbed()
        let surface = ParamSurface(directory: facet, sketch: sketch)
        surface.start()
        try write(
            request: #"{"id":"a1","values":[{"name":"radius","type":"float","value":120}]}"#,
            to: facet)
        surface.drain()

        #expect(sketch.radius == 120)
        let report = try report(from: facet)
        #expect(report["id"] as? String == "a1")
        #expect(params(in: report)["radius"]?["value"] as? Double == 120)
        #expect(report["rejected"] as? [Any] != nil)
    }

    @Test("改訂番号は、内容が変わるたびに進む")
    func revisionAdvances() throws {
        let facet = try makeFacet()
        let sketch = Knobbed()
        let surface = ParamSurface(directory: facet, sketch: sketch)
        surface.start()
        #expect(try report(from: facet)["revision"] as? Int == 1)

        try write(
            request: #"{"id":"a1","values":[{"name":"count","type":"int","value":5}]}"#, to: facet)
        surface.drain()
        #expect(try report(from: facet)["revision"] as? Int == 2)
    }

    @Test("拒否は 3 つとも理由が面に出る")
    func rejectionsCarryTheirReason() throws {
        let facet = try makeFacet()
        let sketch = Knobbed()
        let surface = ParamSurface(directory: facet, sketch: sketch)
        surface.start()
        try write(
            request: """
                {"id":"a2","values":[
                  {"name":"radiu","type":"float","value":1},
                  {"name":"radius","type":"string","value":"おおきい"},
                  {"name":"shape","type":"string","value":"triangle"}
                ]}
                """, to: facet)
        surface.drain()

        let report = try report(from: facet)
        let rejected = report["rejected"] as? [[String: Any]] ?? []
        let reasons = Dictionary(
            uniqueKeysWithValues: rejected.map {
                ($0["name"] as? String ?? "", $0["reason"] as? String ?? "")
            })
        #expect(reasons["radiu"] == "unknownName")
        #expect(reasons["radius"] == "typeMismatch")
        #expect(reasons["shape"] == "notInChoices")
        // 1 つも入らなくても応答は書かれ、識別子が返る (届いていないことと区別できる)
        #expect(report["id"] as? String == "a2")
        #expect(sketch.radius == 80)
        #expect(sketch.shape == "circle")
    }

    @Test("範囲の外は収めて入れ、収めたことを面に出す")
    func clampsAndSaysSo() throws {
        let facet = try makeFacet()
        let sketch = Knobbed()
        let surface = ParamSurface(directory: facet, sketch: sketch)
        surface.start()
        try write(
            request: #"{"id":"a3","values":[{"name":"radius","type":"float","value":999}]}"#,
            to: facet)
        surface.drain()

        #expect(sketch.radius == 200)
        let clamped = try report(from: facet)["clamped"] as? [[String: Any]] ?? []
        #expect(clamped.count == 1)
        #expect(clamped.first?["name"] as? String == "radius")
        #expect(clamped.first?["requested"] as? Double == 999)
        #expect(clamped.first?["value"] as? Double == 200)
    }

    @Test("コードからの代入は、範囲へ収められない")
    func codeAssignmentIsNotClamped() throws {
        // 範囲は面のための宣言であって、値の不変条件ではない (ADR-0030 決定 3)
        let facet = try makeFacet()
        let sketch = Knobbed()
        ParamSurface(directory: facet, sketch: sketch).start()
        sketch.radius = 999
        #expect(sketch.radius == 999)
    }

    @Test("同じ要求は二度当たらない")
    func appliesARequestOnlyOnce() throws {
        let facet = try makeFacet()
        let sketch = Knobbed()
        let surface = ParamSurface(directory: facet, sketch: sketch)
        surface.start()
        try write(
            request: #"{"id":"a4","values":[{"name":"count","type":"int","value":7}]}"#, to: facet)
        surface.drain()
        sketch.count = 2
        surface.drain()
        #expect(sketch.count == 2, "同じ要求が二度当たっている")
    }

    @Test("1 つの要求の中は、名前順に当たる")
    func appliesInNameOrder() throws {
        // 辞書の並びに依ると、同じ要求で結果が揺れ、しかも環境で再現しない
        let facet = try makeFacet()
        let sketch = Knobbed()
        let surface = ParamSurface(directory: facet, sketch: sketch)
        surface.start()
        try write(
            request: """
                {"id":"a5","values":[
                  {"name":"radius","type":"float","value":10},
                  {"name":"count","type":"int","value":2},
                  {"name":"radius","type":"float","value":30}
                ]}
                """, to: facet)
        surface.drain()
        // 同じ名前が並んだら後のほうが残る (名前順に安定して当たる)
        #expect(sketch.radius == 30)
        #expect(sketch.count == 2)
    }

    @Test("値が変わっていないフレームは、要求のファイルを 1 回見るだけ")
    func costsOneLookWhenNothingChanged() throws {
        let facet = try makeFacet()
        let surface = ParamSurface(directory: facet, sketch: Knobbed())
        surface.start()
        let before = try FileManager.default.attributesOfItem(
            atPath: facet.appendingPathComponent("report.json").path)[.modificationDate] as? Date

        for _ in 0..<10 { surface.drain() }

        let after = try FileManager.default.attributesOfItem(
            atPath: facet.appendingPathComponent("report.json").path)[.modificationDate] as? Date
        #expect(before == after, "何も変わっていないのに応答を書き直している")
    }

    @Test("値が変われば、要求が無くても応答が書き直される")
    func republishesWhenAValueChanges() async throws {
        // 変わったことは Observation が知らせる (ADR-0013 決定 1)。フレームごとに
        // 値を数え直さずに、変わったときだけ書き直せる
        let facet = try makeFacet()
        let sketch = Knobbed()
        let surface = ParamSurface(directory: facet, sketch: sketch)
        surface.start()

        sketch.radius = 42
        await Task.yield()
        surface.drain()

        let report = try report(from: facet)
        #expect(report["revision"] as? Int == 2)
        #expect(params(in: report)["radius"]?["value"] as? Double == 42)
    }

    @Test("区画が無ければ働かない")
    func staysOffWithoutTheFacet() throws {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("mokume-params-absent-\(UUID().uuidString)", isDirectory: true)
        #expect(ParamSurface.makeIfEnabled(for: Knobbed(), at: missing) == nil)
    }

    @Test("応答の形が、代表例と食い違わない")
    func matchesTheExample() throws {
        let facet = try makeFacet()
        let surface = ParamSurface(directory: facet, sketch: Knobbed())
        surface.start()
        try write(
            request: #"{"id":"agent-4711","values":[{"name":"radius","type":"float","value":120}]}"#,
            to: facet)
        surface.drain()

        let produced = try report(from: facet)
        let exampleURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // MokumeCoreTests
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // リポジトリ直下
            .appendingPathComponent("Schemas/examples/params-report.json")
        let example =
            try JSONSerialization.jsonObject(with: Data(contentsOf: exampleURL)) as? [String: Any]
                ?? [:]
        #expect(Set(produced.keys) == Set(example.keys))

        let producedParam = params(in: produced)["radius"] ?? [:]
        let exampleParam = params(in: example)["radius"] ?? [:]
        #expect(Set(producedParam.keys) == Set(exampleParam.keys))
    }
}
