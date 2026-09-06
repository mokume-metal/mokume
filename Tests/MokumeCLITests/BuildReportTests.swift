// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation
import Testing
import mokume

@testable import MokumeCLI

/// 作り直しの記録が書き出す JSON。
///
/// `schemaVersion` を注入するためだけの手書き `encode(to:)` を畳み、格納プロパティ +
/// 合成 `Codable` へ寄せた ([#854]・親は [#814])。**畳んだ結果として出力が変わったら
/// 畳み方が間違い**なので、載る鍵と値をここで留める。
///
/// **並びは辞書順で決まる ([#989] で留めた)。** かつては `.sortedKeys` を付けていなかった
/// ので `JSONEncoder` が辞書の走査順で書き出し、**プロセスごとに変わっていた** — 手書きの
/// `encode(to:)` が `CodingKeys` の順に書いていても、届く並びはその順ではなかった。だから
/// 当時は「並びを留める検査を書くと、畳んだこととは関係なく落ちる」と書いてある。
/// いまは組むところが 1 つ (``AtomicFile/writeJSON(_:to:)``) なので、下の検査が留められる。
///
/// [#989]: https://github.com/mokume-metal/mokume/issues/989
///
/// [#854]: https://github.com/mokume-metal/mokume/issues/854
/// [#814]: https://github.com/mokume-metal/mokume/issues/814
@Suite("作り直しの記録の形")
struct BuildReportTests {
    /// 見張りが書くときと**同じ口を通す**。かつてはここで `JSONEncoder` を組み直して
    /// いたが、それは `WatchSession` の設定の写しで、割れても誰も気付かなかった (#989)。
    private func encoded(_ report: BuildReport) throws -> String {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("mokume-build-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("status.json")
        try AtomicFile.writeJSON(report, to: url)
        return try String(contentsOf: url, encoding: .utf8)
    }

    /// **並びが決まっている。** 面ごとに `.sortedKeys` の有無が割れていた頃は、同じ型を
    /// 書いても走査順で並びが変わった (#989 が畳んだ)。差分を取る読み手に効く。
    @Test("鍵の並びが、辞書順で決まる")
    func theKeyOrderIsDecided() throws {
        let text = try encoded(
            BuildReport(
                ok: true, status: 0, output: "出力", stamp: "abc123", configuration: "debug",
                timings: BuildReport.Timings(detectMs: 12, buildMs: 34, relaunchMs: 56)))
        let top = text.split(separator: "\n").compactMap { line -> String? in
            // 入れ子 (timings の中) は字下げが深いので、上の階だけを見る
            guard line.hasPrefix("  \""), let end = line.dropFirst(3).firstIndex(of: "\"")
            else { return nil }
            return String(line.dropFirst(3)[..<end])
        }
        #expect(
            top == ["configuration", "ok", "output", "schemaVersion", "stamp", "status", "timings"])
    }

    /// 手書きの `CodingKeys` が並べていた 7 つと、`Timings` の 3 つ。
    @Test("載る鍵が、手書きの encode と同じ")
    func theKeysAreUnchanged() throws {
        let text = try encoded(
            BuildReport(
                ok: true, status: 0, output: "出力", stamp: "abc123", configuration: "debug",
                timings: BuildReport.Timings(detectMs: 12, buildMs: 34, relaunchMs: 56)))
        let object = try #require(
            try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
        #expect(
            Set(object.keys)
                == ["schemaVersion", "ok", "status", "output", "stamp", "configuration", "timings"])
        let timings = try #require(object["timings"] as? [String: Any])
        #expect(Set(timings.keys) == ["detectMs", "buildMs", "relaunchMs"])

        #expect(object["schemaVersion"] as? Int == 1)
        #expect(object["ok"] as? Bool == true)
        #expect(object["status"] as? Int == 0)
        #expect(object["output"] as? String == "出力")
        #expect(object["stamp"] as? String == "abc123")
        #expect(object["configuration"] as? String == "debug")
        #expect(timings["buildMs"] as? Double == 34)
    }

    /// **面の版は書き出される。** 格納プロパティへ移したので、既定値のまま書かれること
    /// (メンバーワイズの初期化子に現れないこと) を見る。
    @Test("面の版が、組む側の手を借りずに載る")
    func theSchemaVersionRidesAlong() throws {
        let text = try encoded(
            BuildReport(
                ok: true, status: 0, output: "", stamp: nil, configuration: "debug",
                timings: BuildReport.Timings(detectMs: nil, buildMs: 1, relaunchMs: nil)))
        #expect(text.contains("\"schemaVersion\" : 1"))
    }

    /// **省ける欄は省いたまま。** `encodeIfPresent` を手で書いていたのを合成に任せたので、
    /// `null` が現れると読み手の側の分岐が変わる。
    @Test("省いた欄は、null ではなく現れない")
    func absentFieldsStayAbsent() throws {
        let text = try encoded(
            BuildReport(
                ok: false, status: 1, output: "だめ", stamp: nil, configuration: "release",
                timings: BuildReport.Timings(detectMs: nil, buildMs: 2, relaunchMs: nil)))
        #expect(!text.contains("stamp"))
        #expect(!text.contains("detectMs"))
        #expect(!text.contains("relaunchMs"))
        #expect(!text.contains("null"))
        #expect(text.contains("\"buildMs\" : 2"))
    }

    /// 道の区切りが `\/` に化けない (窓口も切り分けの口も、この文字列を人へ見せる)。
    @Test("出力の中の道は、そのままの形で載る")
    func pathsAreNotEscaped() throws {
        let text = try encoded(
            BuildReport(
                ok: false, status: 1, output: "/tmp/sketch/Sources/main.swift:3: error",
                stamp: nil, configuration: "debug",
                timings: BuildReport.Timings(detectMs: nil, buildMs: 1, relaunchMs: nil)))
        #expect(text.contains("/tmp/sketch/Sources/main.swift:3: error"))
    }
}
