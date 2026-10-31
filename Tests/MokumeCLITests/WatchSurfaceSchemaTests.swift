// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation
import Testing
import mokume

@testable import MokumeCLI

/// 区画 `watch` の要求と応答の綴りが、`Schemas/` の正典と割れていないか (#3565)。
///
/// 正典は JSON Schema で、Swift は従う側である (ADR-0018 決定 4)。代表例との照合は `make schemas` が見る。ここは
/// それが見ない向き — **Swift が出す・読む綴りの全集合** — を突き合わせる。
@Suite("区画 watch の要求と応答は、スキーマと同じ綴りを使う")
@MainActor
struct WatchSurfaceSchemaTests {
    private static func schema(_ name: String) throws -> [String: Any] {
        let file = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Schemas/\(name).schema.json")
        return try #require(
            try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
    }

    private static func properties(_ object: [String: Any]) throws -> [String: Any] {
        try #require(object["properties"] as? [String: Any])
    }

    @Test("応答が断る理由の綴りは、スキーマの enum と一致する")
    func reasonsMatchTheSchema() throws {
        let schema = try Self.schema("watch-report")
        let reason = try #require(try Self.properties(schema)["reason"] as? [String: Any])
        let declared = try #require(reason["enum"] as? [String])
        #expect(Set(WatchReport.Reason.allCases.map(\.rawValue)) == Set(declared))
        #expect(declared.count == WatchReport.Reason.allCases.count)
    }

    @Test("応答が書く鍵は、すべてスキーマの欄にあり、必須の欄を落とさない")
    func reportKeysAreDeclared() throws {
        let schema = try Self.schema("watch-report")
        let declared = Set(try Self.properties(schema).keys)
        let required = Set(try #require(schema["required"] as? [String]))

        // 全部の欄が埋まった応答と、必須の欄だけの応答
        let full = WatchReport(
            id: "x", action: "audition", accepted: false, reason: .unreadable, detail: "why",
            auditioning: true, production: .init(pid: 1, stamp: "s1"),
            audition: .init(pid: 2, stamp: "s2"))
        let bare = WatchReport(
            id: "x", action: nil, accepted: true, reason: nil, detail: nil, auditioning: false,
            production: nil, audition: nil)
        for report in [full, bare] {
            let data = try JSONEncoder().encode(report)
            let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
            #expect(Set(object.keys).isSubset(of: declared), "スキーマに無い鍵: \(Set(object.keys).subtracting(declared))")
            #expect(required.isSubset(of: Set(object.keys)), "必須の鍵が無い: \(required.subtracting(Set(object.keys)))")
            #expect((object["schemaVersion"] as? Int) == 1)
        }
        // 全部の欄を埋めた応答が、スキーマの欄を使い切っている (スキーマにだけ有る欄が残らない)
        let fullData = try JSONEncoder().encode(full)
        let fullObject = try #require(try JSONSerialization.jsonObject(with: fullData) as? [String: Any])
        #expect(Set(fullObject.keys) == declared)
    }

    @Test("世代の名乗りの鍵は、スキーマの定義と一致する")
    func generationKeysMatchTheDefinition() throws {
        let schema = try Self.schema("watch-report")
        let defs = try #require(schema["$defs"] as? [String: Any])
        let generation = try #require(defs["generation"] as? [String: Any])
        let declared = Set(try Self.properties(generation).keys)
        let data = try JSONEncoder().encode(WatchReport.Generation(pid: 1, stamp: "s"))
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(Set(object.keys) == declared)
    }

    @Test("要求が読む動作の綴りは、スキーマの例に挙がり、代表例は読める")
    func actionsAreListedAndTheExampleDecodes() throws {
        let schema = try Self.schema("watch-request")
        let action = try #require(try Self.properties(schema)["action"] as? [String: Any])
        let examples = Set(try #require(action["examples"] as? [String]))
        #expect(Set([WatchRequest.Action.audition, .leave].map(\.rawValue)) == examples)
        #expect(Set(try Self.properties(schema).keys) == ["id", "action"])

        let file = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Schemas/examples/watch-request.json")
        let request = try JSONDecoder().decode(WatchRequest.self, from: Data(contentsOf: file))
        #expect(request.known == .audition)
    }
}
