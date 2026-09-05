// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation
import Testing

@testable import MokumeCLI

/// 作り直しの記録が書き出す JSON。
///
/// `schemaVersion` を注入するためだけの手書き `encode(to:)` を畳み、格納プロパティ +
/// 合成 `Codable` へ寄せた ([#854]・親は [#814])。**畳んだ結果として出力が変わったら
/// 畳み方が間違い**なので、載る鍵と値をここで留める。
///
/// **並びは留めない — 畳む前から決定的ではない。** 見張りは
/// `[.prettyPrinted, .withoutEscapingSlashes]` で書き、`.sortedKeys` を付けていないので、
/// `JSONEncoder` は辞書の走査順で書き出す (プロセスごとに変わる)。手書きの `encode(to:)`
/// が `CodingKeys` の順に書いていても、届く並びはその順ではなかった。**並びを留める
/// 検査を書くと、畳んだこととは関係なく落ちる。** 並びを揃えること自体は読み手に効く話
/// だが、それは振る舞いを変えるので #814 に残る (節 3 — 面ごとに `.sortedKeys` の有無が
/// 割れている)。
///
/// [#854]: https://github.com/mokume-metal/mokume/issues/854
/// [#814]: https://github.com/mokume-metal/mokume/issues/814
@Suite("作り直しの記録の形")
struct BuildReportTests {
    /// 見張りが書くときと同じ組み方 (`WatchSession` と揃える)。
    private func encoded(_ report: BuildReport) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes]
        return String(decoding: try encoder.encode(report), as: UTF8.self)
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
