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
            BuildReport.launched(
                output: "出力", stamp: "abc123", configuration: "debug",
                timings: BuildReport.Timings(detectMs: 12, buildMs: 34, relaunchMs: 56)))
        let top = text.split(separator: "\n").compactMap { line -> String? in
            // 入れ子 (timings の中) は字下げが深いので、上の階だけを見る
            guard line.hasPrefix("  \""), let end = line.dropFirst(3).firstIndex(of: "\"")
            else { return nil }
            return String(line.dropFirst(3)[..<end])
        }
        #expect(
            top == ["configuration", "launched", "ok", "output", "schemaVersion", "stamp", "status", "timings"])
    }

    /// 手書きの `CodingKeys` が並べていた 7 つと、`Timings` の 3 つ。
    @Test("載る鍵が、手書きの encode と同じ")
    func theKeysAreUnchanged() throws {
        let text = try encoded(
            BuildReport.launched(
                output: "出力", stamp: "abc123", configuration: "debug",
                timings: BuildReport.Timings(detectMs: 12, buildMs: 34, relaunchMs: 56, firstFrameMs: 78)))
        let object = try #require(
            try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
        #expect(
            Set(object.keys)
                == ["schemaVersion", "ok", "status", "output", "stamp", "configuration", "launched", "timings"])
        let timings = try #require(object["timings"] as? [String: Any])
        #expect(Set(timings.keys) == ["detectMs", "buildMs", "relaunchMs", "firstFrameMs"])

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
            BuildReport.launched(
                output: "", stamp: nil, configuration: "debug",
                timings: BuildReport.Timings(detectMs: nil, buildMs: 1, relaunchMs: nil)))
        #expect(text.contains("\"schemaVersion\" : 1"))
    }

    /// **省ける欄は省いたまま。** `encodeIfPresent` を手で書いていたのを合成に任せたので、
    /// `null` が現れると読み手の側の分岐が変わる。
    @Test("省いた欄は、null ではなく現れない")
    func absentFieldsStayAbsent() throws {
        let text = try encoded(
            BuildReport.failed(
                status: 1, output: "だめ", stamp: nil, configuration: "release",
                timings: BuildReport.Timings(detectMs: nil, buildMs: 2, relaunchMs: nil)))
        #expect(!text.contains("stamp"))
        #expect(!text.contains("detectMs"))
        #expect(!text.contains("relaunchMs"))
        #expect(!text.contains("firstFrameMs"))
        #expect(!text.contains("null"))
        #expect(text.contains("\"buildMs\" : 2"))
    }

    /// 道の区切りが `\/` に化けない (窓口も切り分けの口も、この文字列を人へ見せる)。
    @Test("出力の中の道は、そのままの形で載る")
    func pathsAreNotEscaped() throws {
        let text = try encoded(
            BuildReport.failed(
                status: 1, output: "/tmp/sketch/Sources/main.swift:3: error",
                stamp: nil, configuration: "debug",
                timings: BuildReport.Timings(detectMs: nil, buildMs: 1, relaunchMs: nil)))
        #expect(text.contains("/tmp/sketch/Sources/main.swift:3: error"))
    }

    // MARK: - 起こせなかった回は理由を持つ (#2574)

    private let timings = BuildReport.Timings(detectMs: nil, buildMs: 1, relaunchMs: nil)

    /// **理由の無い `ok: true, launched: false` は作れない。** 約束を型が守らせなければ、読み手が
    /// 理由の無い記録に出会う形が残る。空・空白だけ・空行だけの理由は、理由が無いと名乗る文に倒す。
    @Test("理由を渡さない起こせなかった回は、理由が無いと名乗る文を持つ")
    func aReportThatWasNotStartedAlwaysHasAReason() {
        for empty in ["", "   ", "\n\n", " \n \n"] {
            let report = BuildReport.notStarted(
                reason: empty, buildOutput: "Build complete!", stamp: nil,
                configuration: "debug", timings: timings)
            #expect(report.ok)
            #expect(!report.launched)
            #expect(report.notStartedReason == BuildReport.unknownReason)
            #expect(report.output.hasPrefix(BuildReport.unknownReason + "\n\n"))
        }
    }

    /// 理由は空行を含められない (最初の空行までが理由と読まれる)。行を詰め、頭は空でない。
    @Test("複数行の理由は空行を詰めて持ち、本文の頭と欄が同じになる")
    func aMultiLineReasonKeepsNoBlankLine() throws {
        let report = BuildReport.notStarted(
            reason: "\nfirst\n\n  second  \n", buildOutput: "out", stamp: nil,
            configuration: "debug", timings: timings)
        let reason = try #require(report.notStartedReason)
        #expect(reason == "first\nsecond")
        #expect(report.output == reason + "\n\nout")
        #expect(report.notStartedHead == "first")
    }

    /// 起こせた回・通らなかった回は理由を持たない (欄が載らない)。
    @Test("起こせた回と通らなかった回は、理由を持たない")
    func otherReportsCarryNoReason() throws {
        let launched = BuildReport.launched(
            output: "", stamp: nil, configuration: "debug", timings: timings)
        let failed = BuildReport.failed(
            status: 1, output: "x", stamp: nil, configuration: "debug", timings: timings)
        #expect(launched.notStartedReason == nil && launched.notStartedHead == nil)
        #expect(failed.notStartedReason == nil && failed.notStartedHead == nil)
        #expect(!(try encoded(launched)).contains("notStartedReason"))
        #expect(!(try encoded(failed)).contains("notStartedReason"))
    }

    @Test("起こせなかった回の記録は、理由の欄を持って書かれる")
    func theReasonIsWrittenToTheRecord() throws {
        let report = BuildReport.notStarted(
            reason: "Could not start hello", buildOutput: "out", stamp: nil,
            configuration: "debug", timings: timings)
        let object = try #require(
            try JSONSerialization.jsonObject(with: Data(try encoded(report).utf8)) as? [String: Any])
        #expect(object["notStartedReason"] as? String == "Could not start hello")
        #expect(object["launched"] as? Bool == false)
        #expect(object["ok"] as? Bool == true)
    }
}
