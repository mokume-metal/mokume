// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation
import MokumeTestSupport
import Testing

@testable import MokumeCore

/// 走らせている側が、`id` は読めるが解けない観測の要求に応えること (#2550)。GPU を要する
/// (``SketchRuntime`` を回す)。
///
/// 区画の層 (`FrameObserver.refuse`) は `ObservationProtocolTests` が GPU なしで見る。ここが見るのは
/// **つなぎ** — 走らせている側が `.unreadable` を拾って応えること。つなぎで落とすと、応答が書かれない
/// だけでなく、要求を応えた記録にしないので毎フレーム読み直したまま空回りする。
@Suite(
    "走らせている側が、読めない観測の要求に応える",
    .enabled(if: RenderDevice.isAvailable, "対応する GPU が必要"), .ownWarningDigest)
struct ObservationUnreadableRequestTests {
    final class Scene: Sketch {
        init() {}
        let settings = SketchSettings(width: 32, height: 24)
        var draws = 0
        func draw() {
            draws += 1
            background(0)
            fill(250, 80, 30)
            circle(16, 12, 8)
        }
    }

    private func facet() throws -> URL {
        let path = TestScratch.path("mokume-unreadable")
        try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
        return path
    }

    private func request(_ body: String, to path: URL) throws {
        try AtomicFile.write(Data(body.utf8), to: path.appendingPathComponent("request.json"))
    }

    private func report(_ path: URL) throws -> [String: Any] {
        try #require(
            JSONSerialization.jsonObject(with: Data(contentsOf: path.appendingPathComponent("report.json")))
                as? [String: Any])
    }

    @Test(
        "型の違う値の観測の要求は、撮らずに理由を載せて 1 度だけ応え、前回の絵を消す",
        arguments: [#"{"id":"x1","scale":"0.5"}"#, #"{"id":"x1","scale":true}"#])
    func answersAnUndecodableRequestOnce(_ body: String) throws {
        let path = try facet(), scene = Scene()
        let observer = FrameObserver(directory: path)
        let runtime = try SketchRuntime(
            sketch: scene, gpu: RenderDevice(), clock: nil, now: { 0 }, observer: observer)
        let frame = path.appendingPathComponent("frame-000.png")

        // 前回の成果物: 正しい要求で 1 枚撮っておく
        try request(#"{"id":"old"}"#, to: path)
        try runtime.advance()
        try #require(try report(path)["id"] as? String == "old", "前提: 正しい要求には撮って応える")
        try #require(FileManager.default.fileExists(atPath: frame.path), "前提: 前回の絵がある")

        try request(body, to: path)
        try runtime.advance()

        // (a) 目録が理由つきで書かれる
        let response = try report(path)
        #expect(response["id"] as? String == "x1")
        #expect(response["image"] == nil)
        #expect((response["frames"] as? [Any])?.isEmpty == true)
        let warnings = response["warnings"] as? [String] ?? []
        #expect(warnings.contains { $0.contains("could not be read") && $0.contains("scale") }, "\(warnings)")
        // (b) 前回の絵は消してある。新しい id の目録と古い絵が組にならない
        #expect(!FileManager.default.fileExists(atPath: frame.path))

        // (c) 次のフレームからは読み直さず、応答も増えない
        let reads = observer.readCount
        let written = try Data(contentsOf: path.appendingPathComponent("report.json"))
        try runtime.advance()
        try runtime.advance()
        #expect(observer.readCount == reads, "応えた要求を読み直している")
        #expect(try Data(contentsOf: path.appendingPathComponent("report.json")) == written)
        #expect(!FileManager.default.fileExists(atPath: frame.path))
        // 読めない要求でフレームを落とさない (4 フレームとも描いている)
        #expect(scene.draws == 4)
    }
}
