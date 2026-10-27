// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation
import MokumeDiagnostics
import MokumeTestSupport
import Testing

@testable import MokumeCore

/// 観測の撮影で、PNG の符号化とファイルの置き換えを、撮り終えた後もフレームの外で続ける形
/// ([#2381](https://github.com/mokume-metal/mokume/issues/2381))。
///
/// 目録は全枚の書き込みが決着した後に書く・書けなかった枚があれば `complete: false` と理由の警告で
/// 返し、目録はその枚の手前で終える・次の撮影は前の撮影の決着の後に始める (古い絵と新しい目録を組に
/// しない) — ADR-0018 決定 3 を、裏で走る形でも保つことを見る。GPU を要する。
@Suite(
    "観測の撮影の書き込みをフレームの外で続ける",
    .enabled(
        if: RenderDevice.isAvailable,
        "この世代のコマンド構造に対応した GPU が無い実行環境ではスキップする"),
    .ownWarningDigest
)
struct ObservationBackgroundWriteTests {
    /// フレームごとに四角が動く。撮った絵が枚ごとに違うので、順序の取り違えが見える。
    final class Drifting: Sketch {
        init() {}
        var settings: SketchSettings { SketchSettings(width: 32, height: 24) }
        func draw() {
            background(.display(red: 0, green: 0, blue: 0))
            fill(.display(red: 1, green: 1, blue: 1))
            rect(Float(frameCount % 20), 8, 8, 8)
            expose("frame", frameCount)
        }
    }

    private func makeFacet() throws -> URL {
        let directory = try TestScratch.directory("mokume-observe-bg")
        return directory
    }

    private func request(id: String, count: Int, in facet: URL) throws {
        try AtomicFile.write(
            Data(#"{"id":"\#(id)","count":\#(count)}"#.utf8),
            to: facet.appendingPathComponent("request.json"))
    }

    private func readReport(in facet: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: facet.appendingPathComponent("report.json")) else {
            return nil
        }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    /// 目録が出る (識別子が一致する) まで、フレームを進める。**期限つきで待つ** — 書き込みの決着は
    /// 機械の混み具合で決まるので、フレームの数では待たない。
    @discardableResult
    private func advance(
        _ runtime: SketchRuntime, untilReportOf id: String, in facet: URL, limit: Double = 20
    ) throws -> (report: [String: Any], frames: Int) {
        let deadline = Date().addingTimeInterval(limit)
        var frames = 0
        while Date() < deadline {
            try runtime.advance()
            frames += 1
            if let report = readReport(in: facet), report["id"] as? String == id {
                return (report, frames)
            }
        }
        Issue.record("目録 \(id) が \(limit) 秒たっても出ない")
        return ([:], frames)
    }

    private func makeRuntime(facet: URL, background: Bool) throws -> (SketchRuntime, FrameObserver) {
        let observer = FrameObserver(directory: facet, writesInBackground: background)
        let runtime = try SketchRuntime(
            sketch: Drifting(), gpu: try RenderDevice(), clock: nil, now: { 0 }, observer: observer)
        return (runtime, observer)
    }

    /// 目録の中身 (枚の名前・番号・時刻・統計・値) は、同期で書く形と同じ。
    private func essence(_ report: [String: Any]) -> [[String: Any]] {
        let frames = report["frames"] as? [[String: Any]] ?? []
        return frames.map { frame in
            var kept = frame
            kept["time"] = nil
            return kept
        }
    }

    @Test("目録の中身は、同期で書く形と同じ (枚・名前・番号・統計・値・順序)")
    func theCatalogueIsTheSameAsTheSynchronousOne() throws {
        var reports: [[String: Any]] = []
        for background in [false, true] {
            let facet = try makeFacet()
            let (runtime, _) = try makeRuntime(facet: facet, background: background)
            try runtime.advance()
            try request(id: "a1", count: 4, in: facet)
            reports.append(try advance(runtime, untilReportOf: "a1", in: facet).report)
        }
        let (sync, background) = (reports[0], reports[1])
        #expect(essence(sync).count == 4)
        // 撮ったフレームの番号は、決着を待つ間に進んだ分だけ後ろへずれうるので、名前・番号の並びと
        // 統計・値で見る (番号は撮った枚ごとに 1 ずつ進む)
        #expect(
            (background["frames"] as? [[String: Any]])?.compactMap { $0["image"] as? String }
                == (sync["frames"] as? [[String: Any]])?.compactMap { $0["image"] as? String })
        #expect(background["image"] as? String == "frame-003.png")
        #expect(background["warnings"] as? [String] == sync["warnings"] as? [String])
        #expect(background["size"] as? [String: Int] == sync["size"] as? [String: Int])
        let numbers = (background["frames"] as? [[String: Any]])?.compactMap { $0["frame"] as? Int } ?? []
        #expect(numbers == (numbers.first.map { first in (0..<4).map { first + $0 } } ?? []), "\(numbers)")
    }

    /// 目録を読み手が見た時点で、並んだ絵は全部ファイルになっている。
    @Test("目録が出た時点で、並んだ絵は全部ファイルとして在る")
    func everyPictureExistsWhenTheCatalogueAppears() throws {
        let facet = try makeFacet()
        let (runtime, _) = try makeRuntime(facet: facet, background: true)
        try runtime.advance()
        try request(id: "a1", count: 6, in: facet)
        let report = try advance(runtime, untilReportOf: "a1", in: facet).report
        let frames = report["frames"] as? [[String: Any]] ?? []
        #expect(frames.count == 6)
        for frame in frames {
            let name = try #require(frame["image"] as? String)
            let size = (try? FileManager.default.attributesOfItem(
                atPath: facet.appendingPathComponent(name).path)[.size] as? Int) ?? 0
            #expect(size > 0, "\(name) が書けていない")
        }
        let names = try FileManager.default.contentsOfDirectory(atPath: facet.path)
        #expect(!names.contains { $0.hasSuffix(".tmp") }, "一時ファイルが残っている: \(names)")
    }

    /// 書き込みに失敗した枚があれば、今と同じく `complete: false` (`image` の鍵が無い) と理由の警告で返し、
    /// 目録はその枚の手前で終える。1 枚目 (frame-000) は置けて、2 枚目の行き先をディレクトリが塞ぐ。
    @Test("書けなかった枚があれば、その枚の手前で目録を終え、理由を警告で返す")
    func aFailedWriteEndsTheCatalogueBeforeThatFrame() throws {
        let facet = try makeFacet()
        // 行き先を塞ぐ。`clearProducts()` は、ディレクトリを消さずに残す
        try FileManager.default.createDirectory(
            at: facet.appendingPathComponent("frame-001.png"), withIntermediateDirectories: true)
        let (runtime, _) = try makeRuntime(facet: facet, background: true)
        try runtime.advance()
        try request(id: "a1", count: 3, in: facet)
        let report = try advance(runtime, untilReportOf: "a1", in: facet).report

        #expect((report["frames"] as? [[String: Any]])?.count == 1, "その枚の手前で終えていない")
        #expect(report["image"] == nil, "揃っていないのに image を名乗っている")
        let warnings = report["warnings"] as? [String] ?? []
        #expect(warnings.contains { $0.hasPrefix("Could not take the image:") }, "\(warnings)")
        #expect(
            FileManager.default.fileExists(atPath: facet.appendingPathComponent("frame-000.png").path))
    }

    /// 次の撮影の `clearProducts()` は、前の撮影の書き込みが決着してから行う。
    @Test("続けて 2 回撮ると、前の撮影の絵も目録も次の撮影に混ざらない")
    func twoCapturesInARowDoNotMix() throws {
        let facet = try makeFacet()
        let (runtime, _) = try makeRuntime(facet: facet, background: true)
        try runtime.advance()
        try request(id: "a1", count: 5, in: facet)
        // 1 回目の目録が出るのを待たずに、2 回目を頼む
        try runtime.advance()
        try request(id: "a2", count: 2, in: facet)
        let first = try advance(runtime, untilReportOf: "a1", in: facet)
        #expect((first.report["frames"] as? [[String: Any]])?.count == 5)
        let second = try advance(runtime, untilReportOf: "a2", in: facet)
        #expect((second.report["frames"] as? [[String: Any]])?.count == 2)

        // 2 回目が終わった後に、1 回目の絵 (3 枚目以降) が残っていない
        let names = try FileManager.default.contentsOfDirectory(atPath: facet.path)
            .filter { $0.hasPrefix("frame-") }.sorted()
        #expect(names == ["frame-000.png", "frame-001.png"], "\(names)")
    }

    /// 抱える枚数には上限があり、越えたら main が待つ。無制限に溜めない。
    @Test("抱える枚数は上限を越えない")
    func pendingWritesAreBounded() throws {
        let facet = try makeFacet()
        let (runtime, observer) = try makeRuntime(facet: facet, background: true)
        try runtime.advance()
        try request(id: "a1", count: 40, in: facet)
        let report = try advance(runtime, untilReportOf: "a1", in: facet).report
        #expect((report["frames"] as? [[String: Any]])?.count == 40)
        #expect(observer.peakPendingWrites <= Backpressure.defaultLimit, "\(observer.peakPendingWrites)")
    }

    /// 撮り終えてすぐに閉じても、目録を書いてから閉じる。
    @Test("撮り終えてすぐ閉じても、決着を待って目録を書く")
    func closingSettlesTheCatalogue() throws {
        let facet = try makeFacet()
        let (runtime, _) = try makeRuntime(facet: facet, background: true)
        try runtime.advance()
        try request(id: "a1", count: 1, in: facet)
        // 1 枚だけの列は 1 回の advance で撮り終える。書き込みの決着は待たずに閉じに行く
        try runtime.advance()
        runtime.closePlugins()
        let report = try #require(readReport(in: facet), "閉じた後に目録が無い")
        #expect(report["id"] as? String == "a1")
        #expect((report["frames"] as? [[String: Any]])?.count == 1)
    }

    /// 書き込みが置けなかったことを、決着として返す (裏で走る書き込みの失敗)。
    @Test("行き先を書けなければ、決着は『その枚が置けなかった』になる")
    func settleReportsAnAsynchronousFailure() throws {
        let facet = try makeFacet()
        let observer = FrameObserver(directory: facet, writesInBackground: true)
        let image = DisplayImage(width: 2, height: 2, bytes: [UInt8](repeating: 255, count: 16))
        _ = observer.enqueueFrame(image, at: 0)
        guard case .written? = observer.settleWrites(.block) else {
            Issue.record("書けるはずの 1 枚が書けていない")
            return
        }
        // 置き場を塞ぐ (読み取りだけ)。一時ファイルを作れず、裏の書き込みが転ぶ
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: facet.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: facet.path) }
        try #require(
            !FileManager.default.isWritableFile(atPath: facet.path), "置き場を塞げていない")
        _ = observer.enqueueFrame(image, at: 1)
        let settled = observer.settleWrites(.block)
        guard case .failed(let index, let reason)? = settled else {
            Issue.record("転んだことが決着に現れない: \(String(describing: settled))")
            return
        }
        #expect(index == 0)
        #expect(!reason.isEmpty)
    }
}

/// 観測の絵を置けなかった事情は、OS の文面で名乗る (#3211・#2839)。`"\(error)"` は `POSIXError` や
/// `NSError` の中身をそのまま並べ、言語の設定に左右されうる説明も混ざる。GPU は要らない。
@Suite("観測の絵を置けなかった事情の文")
struct ObservationPlacementWordingTests {
    private func makeFacet() throws -> URL {
        let directory = try TestScratch.directory("mokume-observe-wording")
        return directory
    }

    private let image = DisplayImage(width: 2, height: 2, bytes: [UInt8](repeating: 255, count: 16))

    @Test("置く準備で断った理由 (書く先がディレクトリ) は、Is a directory と名乗る")
    func aDestinationThatIsADirectoryIsNamedInCWords() throws {
        let facet = try makeFacet()
        defer { try? FileManager.default.removeItem(at: facet) }
        try FileManager.default.createDirectory(
            at: facet.appendingPathComponent("frame-000.png"), withIntermediateDirectories: true)
        let observer = FrameObserver(directory: facet, writesInBackground: true)
        _ = observer.enqueueFrame(image, at: 0)
        guard case .failed(_, let reason)? = observer.settleWrites(.block) else {
            Issue.record("置けなかったことが決着に現れない")
            return
        }
        #expect(reason == "Is a directory", Comment(rawValue: reason))
    }

    /// 一時ファイルは書けて、置き換えだけが転ぶ形: 行き先のファイルを変更不可 (`UF_IMMUTABLE`) にする。
    /// 置き換えの失敗は Cocoa の失敗で、下に `EACCES` (13) を持つ。
    @Test("置く段で転んだ理由 (置き換えの失敗) も、Foundation の説明ではなく OS の文面で名乗る")
    func aFailureWhilePlacingIsNamedInCWords() throws {
        let facet = try makeFacet()
        let destination = facet.appendingPathComponent("frame-000.png")
        try Data("old".utf8).write(to: destination)
        try #require(chflags(destination.path, UInt32(UF_IMMUTABLE)) == 0, "行き先を変更不可にできない")
        defer {
            chflags(destination.path, 0)
            try? FileManager.default.removeItem(at: facet)
        }
        let observer = FrameObserver(directory: facet, writesInBackground: true)
        _ = observer.enqueueFrame(image, at: 0)
        guard case .failed(_, let reason)? = observer.settleWrites(.block) else {
            Issue.record("置けなかったことが決着に現れない")
            return
        }
        #expect(reason == "Permission denied", Comment(rawValue: reason))
    }
}
