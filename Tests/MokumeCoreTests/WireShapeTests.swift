// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation
import Testing

@testable import MokumeCore

/// 区画へ置く応答の**鍵**。
///
/// ## なぜ留めるのか
///
/// `schemaVersion` を注入するためだけの手書き `encode(to:)` を落として合成に戻した
/// ([#992](https://github.com/mokume-metal/mokume/issues/992))。畳んだ代わりに危うさが
/// 1 つ増える — **合成の `encode` は、後から足したプロパティを黙って面へ出す。** 手書き
/// だったころは書き足さなければ出なかったので、面が広がるのは意図した操作だった。
///
/// 面が黙って広がると、[ADR-0018] 決定 5 の版の上げ方 (鍵を足したら版を上げる) を
/// 通らないまま、同じ版を名乗る違う形の応答が出る。ここが鍵を留めるので、増えたら赤くなる。
///
/// **並びは留めない。** 並びを決めているのは符号化器であって型ではない — `.sortedKeys`
/// を付けない経路の並びは辞書の走査順で、畳む前から決まっていなかった。
///
/// [ADR-0018]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0018-observation-and-control-surface.md
@Suite("応答に出る鍵")
struct WireShapeTests {
    private func keys(_ value: some Encodable) throws -> Set<String> {
        let data = try JSONEncoder().encode(value)
        let object = try #require(
            try JSONSerialization.jsonObject(with: data) as? [String: Any])
        return Set(object.keys)
    }

    @Test("入力の応答")
    func inputReport() throws {
        #expect(
            try keys(InputReport(id: "r", accepted: 1, ignored: 0, dropped: 0))
                == ["schemaVersion", "id", "accepted", "ignored", "dropped"])
    }

    @Test("つまみの応答。**まだ 1 つも応えていなければ id を出さない**")
    func paramReport() throws {
        let base: Set<String> = [
            "schemaVersion", "revision", "params", "rejected", "clamped", "discarded",
        ]
        let quiet = ParamReport(
            revision: 1, id: nil, params: [], rejected: [], clamped: [], discarded: [])
        #expect(try keys(quiet) == base)

        let answered = ParamReport(
            revision: 2, id: "q", params: [], rejected: [], clamped: [], discarded: [])
        #expect(try keys(answered) == base.union(["id"]))
    }

    @Test("差し出す面の目録")
    func manifest() throws {
        #expect(
            try keys(SharedFrameSurface.Manifest(ids: [1], width: 16, height: 9))
                == ["schemaVersion", "ids", "width", "height"])
    }

    @Test("撮った 1 枚。**測れていないものは出さない**")
    func capturedFrame() throws {
        let bare = ObservationReport.CapturedFrame(
            image: "f.png", frame: 1, time: 0, stats: nil, values: nil)
        #expect(try keys(bare) == ["image", "frame", "time"])

        let full = ObservationReport.CapturedFrame(
            image: "f.png", frame: 1, time: 0, stats: nil, values: ["n": .int(1)])
        #expect(try keys(full) == ["image", "frame", "time", "values"])
    }

    @Test("観測の応答。**撮れなかったものは鍵ごと出さない**")
    func observationReport() throws {
        // 鍵の有無だけで成否を言える (ADR-0018 決定 3) ので、nil は省略される
        let failed = ObservationReport(
            id: "o", image: nil, frame: 1, time: 0, size: .init(width: 16, height: 9))
        #expect(
            try keys(failed)
                == ["schemaVersion", "id", "frame", "time", "size", "warnings", "frames"])

        let captured = ObservationReport(
            id: "o", image: "last.png", frame: 1, time: 0, size: .init(width: 16, height: 9),
            warnings: [], stats: nil, load: nil, values: ["n": .int(1)], stamp: "s",
            frames: [])
        #expect(
            try keys(captured) == [
                "schemaVersion", "id", "image", "frame", "time", "size", "warnings", "values",
                "stamp", "frames",
            ])
    }
}
