// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation
import Testing
import mokume

@testable import MokumeCLI

/// 観測の応答から絵の名前を読むところ。
///
/// **書き手の版が読み手より古いことは避けられない。** 作品は再現のために mokume の版を
/// 固定してコミットし、道具は独立に新しくなる (#635)。だから目録 (#408) を書かない応答も
/// 読めなければならない。
@Suite("観測の応答の読み取り")
struct ObserveTests {
    /// 応答を先に置いた道具立てを組む。
    ///
    /// **要求を置く前から応答が在る形にする** — `exchange` は id の一致で完了を判定するので、
    /// 先に置いてあれば待たない。待ちを短くするのではなく、待ちを起こさない形にしてある。
    private func makeTools(report: [String: Any]) throws -> Tools {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("mokume-observe-\(UUID().uuidString)", isDirectory: true)
        let facets = Facets(directory: directory)
        try FileManager.default.createDirectory(
            at: facets.observeFacet, withIntermediateDirectories: true)
        var body = report
        body["id"] = "fixed"
        try JSONSerialization.data(withJSONObject: body)
            .write(to: facets.observeFacet.appendingPathComponent("report.json"))
        return Tools(facets: facets, makeID: { "fixed" })
    }

    /// どの応答にも要る土台。ここに `image` や `frames` を足して形を作る。
    private func base() -> [String: Any] {
        [
            "schemaVersion": 1,
            "frame": 42,
            "time": 0.7,
            "size": ["width": 1280, "height": 720],
            "warnings": [],
        ]
    }

    private func frame(_ name: String, _ number: Int) -> [String: Any] {
        ["image": name, "frame": number, "time": 0.7]
    }

    @Test("目録を持つ応答から絵の場所が返る")
    func readsTheManifest() throws {
        var report = base()
        report["image"] = "frame.png"
        report["frames"] = [frame("frame.png", 42)]
        let tools = try makeTools(report: report)

        let (text, isError) = tools.call("observe", arguments: [:])

        #expect(!isError)
        #expect(text.contains("絵: "))
        #expect(text.contains("frame.png"))
        // 目録が在るのだから、古い書き手の名乗りは付かない
        #expect(!text.contains("目録 (frames) を持ちません"))
    }

    @Test("目録が無くても、単数形の image から絵の場所が返る")
    func fallsBackToTheSingularName() throws {
        var report = base()
        report["image"] = "frame.png"  // 目録は書かれていない (#408 より前の書き手)
        let tools = try makeTools(report: report)

        let (text, isError) = tools.call("observe", arguments: [:])

        #expect(!isError)
        #expect(text.contains("絵: "))
        #expect(text.contains("frame.png"))
    }

    @Test("目録が無いまま読めたことは名乗る")
    func namesTheMissingManifest() throws {
        var report = base()
        report["image"] = "frame.png"
        let tools = try makeTools(report: report)

        let (text, _) = tools.call("observe", arguments: [:])

        #expect(text.contains("目録 (frames) を持ちません"))
    }

    @Test("目録も単数形も無ければ、採れなかったと答える")
    func reportsTheRealFailure() throws {
        var report = base()
        report["warnings"] = ["宣言した枚数が揃わなかった"]
        let tools = try makeTools(report: report)

        let (text, _) = tools.call("observe", arguments: [:])

        #expect(text.contains("絵は採れませんでした"))
        #expect(!text.contains("目録 (frames) を持ちません"))
    }

    @Test("目録が 2 枚以上なら、枚数と一覧を返す")
    func listsTheSequence() throws {
        var report = base()
        report["image"] = "frame-0002.png"
        report["frames"] = [frame("frame-0001.png", 42), frame("frame-0002.png", 43)]
        let tools = try makeTools(report: report)

        let (text, _) = tools.call("observe", arguments: [:])

        #expect(text.contains("絵 2 枚"))
        #expect(text.contains("frame-0001.png frame-0002.png"))
    }

    @Test("古い書き手に続けて撮るよう頼んだら、枚数が揃わないことを先に言う")
    func saysTheCountCannotBeMet() throws {
        var report = base()
        report["image"] = "frame.png"  // 目録が無いので 1 枚しか読めない
        let tools = try makeTools(report: report)

        let (text, _) = tools.call("observe", arguments: ["count": 8])

        #expect(text.contains("8 枚"))
        #expect(text.contains("1 枚しか"))
    }
}
