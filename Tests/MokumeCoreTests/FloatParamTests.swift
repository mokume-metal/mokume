// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation
import Testing

@testable import MokumeCore
@testable import mokume

/// `Float` で宣言した `@Param` が、`Double` と同じように面へ出て往復すること。
///
/// ``ParamValue`` の約束は「`Float` と `Double` はどちらも `float` を名乗る」で、面に出る
/// 形は数値の 1 つである。**往復の検査はどれも `Double` で書かれていた**ので、`Float` の
/// 写し (`ParamRepresentable` への適合) が別の型を名乗っても、読み戻しに失敗しても、
/// 緑のままだった ([#1386](https://github.com/mokume-metal/mokume/issues/1386))。
///
/// 値は 2 進で割り切れるもの (0.75・0.625) を選ぶ。`Float` と `Double` の間を往復する
/// だけで誤差が出る値だと、壊れたのか丸めなのかが見分けられない。
@Suite("Float で宣言した値の往復")
@MainActor
struct FloatParamTests {
    final class Tuned: Sketch {
        @Param(0...1) var gain: Float = 0.5
    }

    private func makeDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("mokume-float-param-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func entry(named name: String, in facet: URL) throws -> [String: Any]? {
        let data = try Data(contentsOf: facet.appendingPathComponent("report.json"))
        let report = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
        let entries = report["params"] as? [[String: Any]] ?? []
        return entries.first { $0["name"] as? String == name }
    }

    @Test("宣言は float を名乗り、面の応答にもそう載る")
    func floatNamesItselfFloat() throws {
        let sketch = Tuned()
        #expect(sketch.params.first { $0.name == "gain" }?.typeName == "float")

        // 書く側の綴りが応答まで届いていること (Schemas/params-report.schema.json の `type`)
        let facet = try makeDirectory()
        ParamSurface(directory: facet, sketch: sketch).start()
        let shown = try #require(try entry(named: "gain", in: facet))
        #expect(shown["type"] as? String == "float")
        #expect(shown["value"] as? Double == 0.5)
    }

    @Test("面から書いた値が、Float の値として届く")
    func aWriteFromTheFacetReachesTheFloat() throws {
        let facet = try makeDirectory()
        let sketch = Tuned()
        let surface = ParamSurface(directory: facet, sketch: sketch)
        surface.start()

        try #"{"id":"f1","values":[{"name":"gain","type":"float","value":0.75}]}"#.write(
            to: facet.appendingPathComponent("request.json"), atomically: true, encoding: .utf8)
        let report = try #require(surface.drain())

        #expect(sketch.gain == 0.75)
        // 型が合わないと弾かれた、ではないこと (弾かれると値は 0.5 のまま応答が返る)
        #expect(report.rejected.isEmpty)
    }

    @Test("動かした値が、次の起動で戻る")
    func theValueSurvivesARelaunch() async throws {
        let url = try makeDirectory().appendingPathComponent("params.json")
        let before = Tuned()
        let saving = ParamStore(registry: ParamRegistry(of: before), at: url)
        saving.restore()
        before.gain = 0.625
        // 値が変わった知らせは隔離をまたいで届くので、フレームを進める前に受け取らせる
        await Task.yield()
        for _ in 0...ParamStore.quietFrames { saving.tick() }
        #expect(saving.writeCount == 1)

        let after = Tuned()
        let restoration = ParamStore(registry: ParamRegistry(of: after), at: url).restore()
        #expect(after.gain == 0.625)
        #expect(restoration.discarded.isEmpty)
    }
}
