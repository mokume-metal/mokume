// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation
import Testing

@testable import MokumeCore

/// つまみの目録 (`params/report.json`) は、区画の権利 (`FacetClaim`) を持つ実行だけが書く
/// ([#2227](https://github.com/mokume-metal/mokume/issues/2227))。
///
/// 目録は見張りのプレビューがつまみを並べる元で、書き込みは権利を持つ実行へ届く。権利を持たない実行
/// (見張りの居る場所で別に起こした `run` / `swift run`・重なっている間の次の世代) が書くと、並ぶつまみ
/// と効く先が割れる。**権利は別のプロセスの世代を `OtherGenerationFixture` で表して取り合う。**
/// GPU は要らない。
@Suite("つまみの目録は、権利を持つ実行だけが書く")
@MainActor
struct ParamReportClaimTests {
    final class Knobbed: Sketch {
        @Param(0...200) var radius: Double = 80
    }

    private static let sentinel = #"{"sentinel":"the holder's catalogue"}"#

    private func makeFacet() throws -> URL {
        let facet = FileManager.default.temporaryDirectory
            .appendingPathComponent("mokume-claim-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("params", isDirectory: true)
        try FileManager.default.createDirectory(at: facet, withIntermediateDirectories: true)
        try Data(Self.sentinel.utf8).write(to: WorkDirectory.reportURL(under: facet))
        return facet
    }

    private func reportText(_ facet: URL) throws -> String {
        try String(contentsOf: WorkDirectory.reportURL(under: facet), encoding: .utf8)
    }

    private func reportObject(_ facet: URL) throws -> [String: Any] {
        let data = try Data(contentsOf: WorkDirectory.reportURL(under: facet))
        return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    /// 起動する。保存から戻し、面を開く (実際の起動と同じ順)。
    private func launch(
        _ sketch: Knobbed, in facet: URL, saved: URL? = nil
    ) -> (surface: ParamSurface, store: ParamStore) {
        let registry = ParamRegistry(of: sketch)
        let store = ParamStore(
            registry: registry,
            at: saved
                ?? facet.deletingLastPathComponent().appendingPathComponent("params.json"))
        let surface = ParamSurface(directory: facet, registry: registry, store: store)
        surface.start(after: store.restore())
        return (surface, store)
    }

    @Test("権利を持たない実行は、起動しても・値が変わっても・要求が来ても目録を書かない")
    func aRunWithoutTheClaimNeverWritesTheCatalogue() throws {
        let facet = try makeFacet()
        let holder = try OtherGenerationFixture(holding: facet)
        defer { holder.leave() }
        let sketch = Knobbed()
        let run = launch(sketch, in: facet)

        #expect(try reportText(facet) == Self.sentinel, "起動で目録を書いた")
        sketch.radius = 10
        run.surface.drain()
        run.surface.flushIfChanged()
        #expect(try reportText(facet) == Self.sentinel, "値が変わって目録を書いた")

        try Data(#"{"id":"r1","values":[{"name":"radius","type":"float","value":150}]}"#.utf8)
            .write(to: WorkDirectory.requestURL(under: facet))
        #expect(run.surface.drain() == nil, "権利が無いのに要求に応えた")
        #expect(sketch.radius == 10, "権利が無いのに書き込みが当たった")
        #expect(try reportText(facet) == Self.sentinel)
    }

    @Test("権利を取った後は、最初の機会に自分の宣言を書き、番号が進む")
    func afterTakingTheClaimTheCatalogueIsWrittenAtTheFirstChance() throws {
        let facet = try makeFacet()
        let holder = try OtherGenerationFixture(holding: facet)
        let sketch = Knobbed()
        let run = launch(sketch, in: facet)
        #expect(try reportText(facet) == Self.sentinel)

        holder.leave()
        #expect(run.surface.drain() != nil, "権利を取ったのに書かなかった")
        let object = try reportObject(facet)
        #expect(object["revision"] as? Int == 1)
        let names = (object["params"] as? [[String: Any]])?.compactMap { $0["name"] as? String }
        #expect(names == ["radius"], "\(String(describing: names))")
    }

    /// 起動で書けなかった最初の応答は、保存から戻せなかったものも載せて、後で書く
    /// (ADR-0030 決定 6: 診断は端末にしか出ないので、外から読む側にも見える)。
    @Test("書けなかった最初の応答は、戻せなかった保存の値を載せて後で書く")
    func theFirstReplyKeepsWhatCouldNotBeRestored() throws {
        let facet = try makeFacet()
        let saved = facet.deletingLastPathComponent().appendingPathComponent("saved.json")
        try Data(
            #"{"values":[{"name":"gone","type":"float","value":1}]}"#.utf8).write(to: saved)
        let holder = try OtherGenerationFixture(holding: facet)
        let run = launch(Knobbed(), in: facet, saved: saved)
        holder.leave()
        run.surface.flushIfChanged()

        let discarded = try #require(try reportObject(facet)["discarded"] as? [[String: Any]])
        #expect(discarded.contains { $0["name"] as? String == "gone" }, "\(discarded)")
    }

    @Test("権利を持つ実行は、これまでどおり起動で目録を書き、番号が進む")
    func theHolderStillWritesAtLaunch() throws {
        let facet = try makeFacet()
        let sketch = Knobbed()
        let run = launch(sketch, in: facet)
        #expect(try reportObject(facet)["revision"] as? Int == 1)
        sketch.radius = 20
        run.surface.drain()
        #expect(try reportObject(facet)["revision"] as? Int == 2)
    }

    /// 見張りの世代交代: 重なっている間、次の世代は前の世代が去るまで目録を書かず、プレビューのつまみは
    /// 前の世代の宣言のまま (書き込みが効く先と一致する)。
    @Test("重なっている間、次の世代は目録を書かず、前の世代が去った後に書く")
    func theIncomingGenerationWaitsForTheOutgoing() throws {
        let facet = try makeFacet()
        let outgoing = try OtherGenerationFixture(holding: facet)
        try Data(#"{"id":"gen1"}"#.utf8).write(to: WorkDirectory.reportURL(under: facet))
        let run = launch(Knobbed(), in: facet)

        run.surface.drain()
        #expect(try reportText(facet) == #"{"id":"gen1"}"#, "前の世代の目録を書き換えた")

        outgoing.leave()
        run.surface.drain()
        #expect(try reportObject(facet)["revision"] != nil, "前の世代が去っても書かない")
    }
}
