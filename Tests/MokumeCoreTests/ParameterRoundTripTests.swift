// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation
import SwiftUI
import Testing

@testable import MokumeCore
@testable import mokume

/// 同じ 1 つの値が、3 つの入口 (窓・面・保存) から往復すること。
///
/// 入口ごとの往復は `ParameterKnobTests` / `ParameterExchangeTests` /
/// `ParameterStoreTests` がそれぞれ見ている。**ここが見るのは 3 つをまたぐ側**である
/// ([#517](https://github.com/mokume-metal/mokume/issues/517) 出口条件 1) — 窓で動かした
/// 値が面から読め、面から書いた値が窓に出て、どちらで動かしても次の起動で戻ること。
///
/// これが成り立つのは値の実体が 1 つしかないから ([ADR-0013] 決定 3) で、いまは
/// 入口ごとの検査がどれも「同じ ``ParamBox`` を読んでいる」ことを前提にしている。
/// **前提が崩れても入口ごとの検査は緑のまま**なので、崩れたら落ちる検査をここに置く。
///
/// [ADR-0013]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0013-parameter-model.md
@Suite("同じ 1 つの値が、3 つの入口から往復する")
@MainActor
struct ParameterRoundTripTests {
    final class Knobbed: Sketch {
        @Param(0...200) var radius: Double = 80
        @Param(choices: ["circle", "square"]) var shape: String = "circle"
    }

    // MARK: - 置き場と起動

    /// 3 つの入口が指す置き場。**やりとりの区画と保存は別の場所** (ADR-0030 決定 6)。
    struct Workspace {
        let facet: URL
        let saved: URL
    }

    /// 1 回の起動。窓・面・保存は、どれもこの 1 つのスケッチを指す。
    struct Run {
        let sketch: Knobbed
        let store: ParamStore
        let surface: ParamSurface
    }

    private func makeWorkspace() throws -> Workspace {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("mokume-round-trip-\(UUID().uuidString)", isDirectory: true)
        let facet = root.appendingPathComponent("params", isDirectory: true)
        try FileManager.default.createDirectory(at: facet, withIntermediateDirectories: true)
        return Workspace(facet: facet, saved: root.appendingPathComponent("params.json"))
    }

    /// 起動する。保存から戻し、面を開く — 実際の起動と同じ順である。
    ///
    /// **面には保存を渡す。** 外からの書き込みが待たずに保存されるのは、この結びによる
    /// (ADR-0030 決定 6)。
    private func launch(in workspace: Workspace) -> Run {
        let sketch = Knobbed()
        let registry = ParamRegistry(of: sketch)
        let store = ParamStore(registry: registry, at: workspace.saved)
        let surface = ParamSurface(directory: workspace.facet, registry: registry, store: store)
        surface.start(after: store.restore())
        return Run(sketch: sketch, store: store, surface: surface)
    }

    // MARK: - 窓の入口

    private func knob(_ run: Run, _ name: String) throws -> any DeclaredParam {
        try #require(ParamCatalog.indexed(from: run.sketch).first { $0.name == name }).box
    }

    /// 窓のつまみを引く。**窓が値を書く口をそのまま通す** — ``DeclaredParam/write(_:)``
    /// を直に呼ぶと、窓が写しを持ち始めても気づけない。
    private func turn(_ run: Run, _ name: String, to value: Double) throws {
        let box = try knob(run, name)
        KnobBinding.number(box, box.declaration.value).wrappedValue = value
    }

    /// 窓で候補を選ぶ。
    private func choose(_ run: Run, _ name: String, _ text: String) throws {
        let box = try knob(run, name)
        KnobBinding.text(box, box.declaration.value).wrappedValue = text
    }

    /// 窓に出る文字。行が描くのと同じ組み立てを通して読む。
    private func shown(_ run: Run, _ name: String) throws -> String {
        KnobText.value(of: try knob(run, name).declaration.value)
    }

    /// つまみを掴む。**掴んだ後に外から値が変われば、掴んだ口はその値を返す** —
    /// 口が値を持たず、読むたびに正典を読み直すからである。写しを持てばここが古い値を
    /// 返し続ける。
    private func grip(_ run: Run, _ name: String) throws -> Binding<Double> {
        let box = try knob(run, name)
        return KnobBinding.number(box, box.declaration.value)
    }

    // MARK: - 面の入口

    private func write(request: String, to workspace: Workspace) throws {
        try request.write(
            to: workspace.facet.appendingPathComponent(ParamSurface.requestFileName),
            atomically: true, encoding: .utf8)
    }

    private func report(from workspace: Workspace) throws -> [String: Any] {
        let data = try Data(
            contentsOf: workspace.facet.appendingPathComponent(ParamSurface.reportFileName))
        return try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
    }

    private func params(in report: [String: Any]) -> [String: [String: Any]] {
        let entries = report["params"] as? [[String: Any]] ?? []
        return Dictionary(uniqueKeysWithValues: entries.map { ($0["name"] as? String ?? "", $0) })
    }

    /// 静かになるまで進める (窓で動かした値が書かれるのは、手が止まってから)。
    private func settle(_ store: ParamStore) async {
        await Task.yield()
        for _ in 0...ParamStore.quietFrames { store.tick() }
    }

    // MARK: - 往復

    @Test("窓で動かした値が、面の応答から読める")
    func theWindowReachesTheFacet() async throws {
        let workspace = try makeWorkspace()
        let run = launch(in: workspace)
        let first = try #require(try report(from: workspace)["revision"] as? Int)

        try turn(run, "radius", to: 120)
        try choose(run, "shape", "square")
        // 値が変わった知らせは隔離をまたいで届く
        await Task.yield()
        run.surface.drain()

        let report = try report(from: workspace)
        let values = params(in: report)
        #expect(values["radius"]?["value"] as? Double == 120)
        #expect(values["shape"]?["value"] as? String == "square")
        // 内容が変われば番号も進む (ADR-0030 決定 2)
        #expect((report["revision"] as? Int ?? 0) > first)
    }

    @Test("面から書いた値が、窓に出る")
    func theFacetReachesTheWindow() throws {
        let workspace = try makeWorkspace()
        let run = launch(in: workspace)
        // **書かれる前に掴んでおく。** 掴んだ後に正典が動くことを見たいので、
        // 書き込みの後に作り直しては口が値を持っているかどうかが分からない
        let dial = try grip(run, "radius")

        try write(
            request: """
                {"id":"r1","values":[
                  {"name":"radius","type":"float","value":45.5},
                  {"name":"shape","type":"string","value":"square"}
                ]}
                """, to: workspace)
        run.surface.drain()

        // 窓が読むのは正典そのもの。写しを持てば、ここが古い値のまま残る
        #expect(try shown(run, "radius") == "45.50")
        #expect(try shown(run, "shape") == "square")
        #expect(dial.wrappedValue == 45.5, "窓のつまみが正典を読み直していない")
    }

    @Test("どちらの入口で動かしても、次の起動で戻る")
    func bothEntrancesSurviveARestart() async throws {
        let workspace = try makeWorkspace()
        let first = launch(in: workspace)

        // 窓で動かす — 手が止まってから 1 回書かれる
        try turn(first, "radius", to: 120)
        await settle(first.store)
        // 面から書く — 書いた側が反映を見に来るので、待たずにその場で書かれる
        try write(
            request: """
                {"id":"r1","values":[{"name":"shape","type":"string","value":"square"}]}
                """, to: workspace)
        first.surface.drain()

        // 次の起動。置き場を指すだけで、両方の入口で動かした値が戻っている
        let second = launch(in: workspace)
        #expect(second.sketch.radius == 120)
        #expect(second.sketch.shape == "square")
        // 戻った値は、窓からも面からも同じに読める
        #expect(try shown(second, "radius") == "120.00")
        #expect(try shown(second, "shape") == "square")
        let values = params(in: try report(from: workspace))
        #expect(values["radius"]?["value"] as? Double == 120)
        #expect(values["shape"]?["value"] as? String == "square")
    }
}
