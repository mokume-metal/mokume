// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation
import Testing

@testable import MokumeCore

/// 外とやりとりするファイルの規約 (ADR-0018)。GPU は要らない。
@Suite("観測のファイルの往復")
struct ObservationProtocolTests {
    /// 使い捨ての区画を作る。
    private func makeFacet() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("mokume-observe-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func write(request: String, to facet: URL) throws {
        try AtomicFile.write(Data(request.utf8), to: facet.appendingPathComponent("request.json"))
    }

    private func report(id: String, image: String?, warnings: [String] = []) -> ObservationReport {
        ObservationReport(
            id: id,
            image: image,
            frame: 1,
            time: 0,
            size: .init(width: 4, height: 4),
            warnings: warnings)
    }

    @Test("区画が無ければ観測は働かない")
    func staysOffWithoutTheFacet() throws {
        let absent = FileManager.default.temporaryDirectory
            .appendingPathComponent("mokume-absent-\(UUID().uuidString)", isDirectory: true)
        #expect(FrameObserver.makeIfEnabled(at: absent) == nil)
    }

    @Test("区画があれば観測が働く")
    func turnsOnWithTheFacet() throws {
        let facet = try makeFacet()
        #expect(FrameObserver.makeIfEnabled(at: facet) != nil)
    }

    @Test("要求が無いフレームは、最終更新時刻を見るだけで返る")
    func costsOnlyOneLookWhenNothingIsRequested() throws {
        let observer = FrameObserver(directory: try makeFacet())
        for _ in 0..<10 { #expect(observer.pendingRequest() == nil) }
        #expect(observer.pollCount == 10)
        // 要求が無い間は 1 度も中身を開かない
        #expect(observer.readCount == 0)
    }

    @Test("置かれた要求を拾い、同じ識別子は二度処理しない")
    func readsARequestOnceAndOnlyOnce() throws {
        let facet = try makeFacet()
        let observer = FrameObserver(directory: facet)
        try write(request: #"{"id":"a1"}"#, to: facet)

        let first = observer.pendingRequest()
        #expect(first?.id == "a1")
        #expect(first?.scale == 1)

        try observer.respond(report(id: "a1", image: "frame.png"), image: nil)

        // **同じ内容を置き直しても** (最終更新時刻は変わる) 応えた識別子なら処理しない。
        // 置き直さずに確かめると、最終更新時刻の判定だけで nil になってしまい、
        // 識別子を見ていなくてもこの検査は通ってしまう
        try write(request: #"{"id":"a1"}"#, to: facet)
        #expect(observer.pendingRequest() == nil)

        // 内容が同じでも、識別子が変われば新しい要求になる
        try write(request: #"{"id":"a2","scale":0.5}"#, to: facet)
        let second = observer.pendingRequest()
        #expect(second?.id == "a2")
        #expect(second?.scale == 0.5)
    }

    @Test("知らない鍵は無視する")
    func ignoresUnknownKeys() throws {
        let facet = try makeFacet()
        let observer = FrameObserver(directory: facet)
        try write(request: #"{"id":"a1","somethingNew":42}"#, to: facet)
        #expect(observer.pendingRequest()?.id == "a1")
    }

    @Test("壊れた要求で走っているスケッチを止めない")
    func survivesAMalformedRequest() throws {
        let facet = try makeFacet()
        let observer = FrameObserver(directory: facet)
        try write(request: "{ this is not json", to: facet)
        #expect(observer.pendingRequest() == nil)
    }

    @Test("応答は原子的に置かれ、一時ファイルを残さない")
    func writesTheReportAtomically() throws {
        let facet = try makeFacet()
        let observer = FrameObserver(directory: facet)
        try observer.respond(report(id: "a1", image: nil), image: nil)

        let names = try FileManager.default.contentsOfDirectory(atPath: facet.path)
        #expect(names.contains("report.json"))
        #expect(!names.contains { $0.hasSuffix(".tmp") })

        let written = try Data(contentsOf: facet.appendingPathComponent("report.json"))
        let decoded = try JSONSerialization.jsonObject(with: written) as? [String: Any]
        #expect(decoded?["id"] as? String == "a1")
        #expect(decoded?["schemaVersion"] as? Int == 1)
    }

    @Test("採れなかったときは、前の絵を消してから応答する")
    func clearsTheStaleImageOnFailure() throws {
        let facet = try makeFacet()
        let observer = FrameObserver(directory: facet)
        let image = facet.appendingPathComponent("frame.png")
        try Data("古い絵".utf8).write(to: image)

        try observer.respond(
            report(id: "a2", image: nil, warnings: ["絵を採れませんでした"]), image: nil)

        // 新しい識別子の応答と古い絵を、読み手が組にできない状態にする
        #expect(!FileManager.default.fileExists(atPath: image.path))
        let written = try Data(contentsOf: facet.appendingPathComponent("report.json"))
        let decoded = try JSONSerialization.jsonObject(with: written) as? [String: Any]
        #expect(decoded?["image"] == nil)
        #expect((decoded?["warnings"] as? [String])?.isEmpty == false)
    }

    @Test("応答の鍵が、正典に置いた代表例と一致する")
    func staysInStepWithTheCanonicalExample() throws {
        // 実装 → 代表例 → スキーマの鎖のうち、ここは 1 本目を守る。実装に鍵を足して
        // 代表例を更新し忘れると落ちる (代表例とスキーマのずれは make ci-check が見る)
        let full = ObservationReport(
            id: "a1",
            image: "frame.png",
            frame: 1,
            time: 0.5,
            size: .init(width: 4, height: 4),
            warnings: [],
            stats: FrameStats.summarize(
                DisplayImage(width: 2, height: 2, bytes: [UInt8](repeating: 0, count: 16))),
            load: RuntimeLoad.sample(frameDurations: [0.016, 0.017]),
            values: ["angle": .float(1.0)],
            stamp: "b3f1a20c")
        let encoded = try JSONEncoder().encode(full)
        let produced = try JSONSerialization.jsonObject(with: encoded) as? [String: Any]

        let exampleURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // MokumeCoreTests
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // リポジトリ直下
            .appendingPathComponent("Schemas/examples/observe-report.json")
        let example =
            try JSONSerialization.jsonObject(with: Data(contentsOf: exampleURL)) as? [String: Any]

        #expect(Set(produced?.keys ?? [:].keys) == Set(example?.keys ?? [:].keys))
    }

    // MARK: - 要求を取りこぼさない (#221)

    @Test("置いている途中を掴んでも、要求は失われない")
    func keepsARequestThatCouldNotBeReadYet() throws {
        let facet = try makeFacet()
        let observer = FrameObserver(directory: facet)
        let requestURL = facet.appendingPathComponent("request.json")
        try write(request: #"{"id":"a1"}"#, to: facet)

        // 書き手が置き終える前の状態を作る (読めないだけで、中身は正しい)。
        // 最終更新時刻は変わらないので、読めるようになった後も同じ 1 件である
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: requestURL.path)
        #expect(observer.pendingRequest() == nil)

        try FileManager.default.setAttributes(
            [.posixPermissions: 0o644], ofItemAtPath: requestURL.path)
        #expect(observer.pendingRequest()?.id == "a1")
    }

    @Test("解けない要求は 1 度だけ読んで捨てる")
    func readsAnUndecodableRequestOnlyOnce() throws {
        let facet = try makeFacet()
        let observer = FrameObserver(directory: facet)
        try write(request: "{ これは JSON ではない", to: facet)

        #expect(observer.pendingRequest() == nil)
        #expect(observer.readCount == 1)

        // 再読しても直らないものを毎フレーム開き直さない
        #expect(observer.pendingRequest() == nil)
        #expect(observer.readCount == 1)
    }

    @Test("連続して置き換えられても、1 つも取りこぼさない")
    func losesNothingAcrossManyReplacements() throws {
        let facet = try makeFacet()
        let observer = FrameObserver(directory: facet)

        var answered: [String] = []
        for index in 1...100 {
            let id = "r\(index)"
            try write(request: #"{"id":"\#(id)"}"#, to: facet)
            guard let request = observer.pendingRequest() else { continue }
            try observer.respond(report(id: request.id, image: nil), image: nil)
            answered.append(request.id)
        }

        #expect(answered == (1...100).map { "r\($0)" })
    }

    @Test("応答を書けなくても、同じ要求を拾い直し続けない")
    func doesNotSpinOnARequestItCannotAnswer() throws {
        let facet = try makeFacet()
        let observer = FrameObserver(directory: facet)
        try write(request: #"{"id":"a1"}"#, to: facet)
        #expect(observer.pendingRequest()?.id == "a1")

        // 書き込み先を塞ぐ。応答は書けないが、応えようとしたことは残る
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: facet.path)
        #expect(throws: (any Error).self) {
            try observer.respond(report(id: "a1", image: nil), image: nil)
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: facet.path)

        #expect(observer.pendingRequest() == nil)
    }

    @Test("基準は作業ディレクトリで、環境から与えられれば上書きされる")
    func resolvesTheBaseDirectory() {
        let current = URL(
            fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
        #expect(WorkDirectory.resolve(environment: [:]) == current)
        #expect(WorkDirectory.resolve(environment: ["MOKUME_WORK_DIR": ""]) == current)
        #expect(
            WorkDirectory.resolve(environment: ["MOKUME_WORK_DIR": "/tmp/sketch"]).path
                == "/tmp/sketch")
        // 相対で与えられたら、読み取り側の作業ディレクトリを基準に絶対化する
        #expect(
            WorkDirectory.resolve(environment: ["MOKUME_WORK_DIR": "work"]).path
                == current.appendingPathComponent("work").standardizedFileURL.path)
    }

    @Test("刻印は渡されたときだけ載る")
    func carriesTheStampOnlyWhenGiven() {
        #expect(SourceStamp.resolve(environment: [:]) == nil)
        #expect(SourceStamp.resolve(environment: ["MOKUME_SOURCE_STAMP": ""]) == nil)
        #expect(SourceStamp.resolve(environment: ["MOKUME_SOURCE_STAMP": "b3f1"]) == "b3f1")
    }
}
