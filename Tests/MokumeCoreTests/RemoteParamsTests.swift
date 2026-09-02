// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation
import Testing

@testable import MokumeCore

/// 面越しのつまみ。
///
/// 見張りが出すプレビューはスケッチを持たないので、宣言も値も `.mokume/params` の応答から
/// 引く ([ADR-0032](https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0032-window-ownership.md) 決定 5)。
@Suite("面越しのつまみ")
@MainActor
struct RemoteParamsTests {
    /// 区画を 1 つ作って渡す。
    private func withFacet<T>(_ body: (URL) throws -> T) rethrows -> T {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("mokume-params-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        return try body(directory)
    }

    /// 走っている側が書く応答を、そのまま置く。
    private func publish(
        _ declarations: [ParamDeclaration], revision: Int = 1, id: String? = nil, at facet: URL
    ) throws {
        let report = ParamReport(
            revision: revision, id: id, params: declarations, rejected: [], clamped: [],
            discarded: [])
        try AtomicFile.write(
            try JSONEncoder().encode(report),
            to: facet.appendingPathComponent(ParamSurface.reportFileName))
    }

    private func request(at facet: URL) throws -> [String: Any]? {
        let url = facet.appendingPathComponent(ParamSurface.requestFileName)
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    /// 応答には名前・型・値・幅・候補が**まとめて**載っているので、読み手はこれだけで
    /// つまみを組める (ADR-0030 決定 2)。
    @Test("応答を読むと、宣言のとおりの箱が並ぶ")
    func buildsBoxesFromTheReport() throws {
        try withFacet { facet in
            try publish(
                [
                    ParamDeclaration(name: "size", value: .float(12), range: ParamRange(0...100)),
                    ParamDeclaration(
                        name: "mode", value: .string("a"), choices: ["a", "b"]),
                ], at: facet)
            let params = RemoteParams(directory: facet)
            #expect(params.refresh())
            #expect(params.boxes.map(\.name) == ["size", "mode"])
            #expect(params.boxes[0].range?.upperBound == 100)
            #expect(params.boxes[1].choices == ["a", "b"])
        }
    }

    /// **区画の書き方は外から書くときと同じ** (ADR-0030 決定 2)。道具だからといって
    /// 近道を作ると、面から書いたときにだけ起きる不具合が生まれる。
    @Test("動かすと、外から書くのと同じ形の要求が置かれる")
    func writesTheSameRequestShape() throws {
        try withFacet { facet in
            try publish([ParamDeclaration(name: "size", value: .float(12))], at: facet)
            let params = RemoteParams(directory: facet)
            #expect(params.refresh())
            _ = params.boxes[0].write(.float(40))

            let placed = try #require(try request(at: facet))
            #expect(placed["id"] is String)
            let values = try #require(placed["values"] as? [[String: Any]])
            #expect(values.count == 1)
            #expect(values[0]["name"] as? String == "size")
            #expect(values[0]["type"] as? String == "float")
            #expect(values[0]["value"] as? Double == 40)
        }
    }

    /// **動かした直後は、まだ動かす前の応答しか無い。** そのまま採るとつまみが戻る。
    @Test("自分の要求が届く前の応答では、つまみが戻らない")
    func doesNotSnapBackBeforeTheChildAnswers() throws {
        try withFacet { facet in
            try publish([ParamDeclaration(name: "size", value: .float(12))], at: facet)
            let params = RemoteParams(directory: facet)
            #expect(params.refresh())
            _ = params.boxes[0].write(.float(40))

            // 動かす前の値を運ぶ応答 (まだこちらの要求に応えていない)
            try publish(
                [ParamDeclaration(name: "size", value: .float(12))], revision: 2, at: facet)
            params.refresh()
            #expect(params.boxes[0].value == .float(40))
        }
    }

    /// 子が応えたら、**子の言うほうへ合わせる** — 収めるのも弾くのも子の仕事なので、
    /// 端で収められた値はここで見えるようになる。
    @Test("要求に応えた応答が来たら、子の値へ合わせる")
    func adoptsTheChildsValue() throws {
        try withFacet { facet in
            try publish([ParamDeclaration(name: "size", value: .float(12))], at: facet)
            let params = RemoteParams(directory: facet)
            #expect(params.refresh())
            _ = params.boxes[0].write(.float(400))
            let id = try #require(try request(at: facet)?["id"] as? String)

            // 子は範囲へ収めて応えた
            try publish(
                [ParamDeclaration(name: "size", value: .float(100), range: ParamRange(0...100))],
                revision: 2, id: id, at: facet)
            params.refresh()
            #expect(params.boxes[0].value == .float(100))
        }
    }

    /// 見張りは作り直しのたびに別のスケッチを起こしうる。宣言を足した・消した・名前を
    /// 変えたときに、面が古いままにならないようにする。
    @Test("宣言の顔ぶれが変われば、箱も入れ替わる")
    func rebuildsWhenDeclarationsChange() throws {
        try withFacet { facet in
            try publish([ParamDeclaration(name: "size", value: .float(12))], at: facet)
            let params = RemoteParams(directory: facet)
            #expect(params.refresh())

            try publish(
                [
                    ParamDeclaration(name: "size", value: .float(12)),
                    ParamDeclaration(name: "speed", value: .float(1)),
                ], revision: 2, at: facet)
            #expect(params.refresh())
            #expect(params.boxes.map(\.name) == ["size", "speed"])
        }
    }

    /// **値が変わっただけでは組み直さない。** 組み直すと、触っている手からつまみが消える。
    @Test("値だけが変わったときは、箱を組み直さない")
    func keepsBoxesWhenOnlyValuesChange() throws {
        try withFacet { facet in
            try publish([ParamDeclaration(name: "size", value: .float(12))], at: facet)
            let params = RemoteParams(directory: facet)
            #expect(params.refresh())
            let first = params.boxes[0]

            try publish(
                [ParamDeclaration(name: "size", value: .float(30))], revision: 2, at: facet)
            #expect(!params.refresh())
            #expect(params.boxes[0] === first)
            #expect(params.boxes[0].value == .float(30))
        }
    }

    @Test("宣言が 1 つも無ければ、箱も無い")
    func staysEmptyWithoutDeclarations() throws {
        try withFacet { facet in
            try publish([], at: facet)
            let params = RemoteParams(directory: facet)
            params.refresh()
            #expect(params.boxes.isEmpty)
        }
    }
}
