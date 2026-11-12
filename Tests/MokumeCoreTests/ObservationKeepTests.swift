// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation
import MokumeTestSupport
import Testing

@testable import MokumeCore

/// 観測の要求の `keep` を読む層 ([#2618](https://github.com/mokume-metal/mokume/issues/2618))。GPU を要しない。
@Suite("観測の持ち出しの指定を読む")
struct ObservationKeepRequestTests {
    private func decode(_ body: String) throws -> ObservationRequest {
        try JSONDecoder().decode(ObservationRequest.self, from: Data(body.utf8))
    }

    @Test("keep は省略・null で false、true で true。この版が読む鍵に入る")
    func readsKeep() throws {
        #expect(try decode(#"{"id":"a"}"#).keep == false)
        #expect(try decode(#"{"id":"a","keep":null}"#).keep == false)
        #expect(try decode(#"{"id":"a","keep":false}"#).keep == false)
        #expect(try decode(#"{"id":"a","keep":true}"#).keep == true)
        #expect(try decode(#"{"id":"a","keep":true}"#).unknownKeys.isEmpty)
        #expect(ObservationRequest.readKeys.contains("keep"))
    }

    @Test("真偽の値でない keep は、省略として通さず読めない要求にする", arguments: [#""yes""#, "1", "0", "[true]"])
    func refusesKeepOfTheWrongType(_ value: String) {
        #expect(throws: DecodingError.self) { try decode(#"{"id":"a","keep":\#(value)}"#) }
    }

    @Test(
        "置き場の名前に使えない識別子は断る",
        arguments: ["", ".", "..", "../x", "a/b", ".hidden", "a.partial", String(repeating: "x", count: 250), "a\u{0}b"])
    func refusesUnsafeIdentifiers(_ id: String) {
        #expect(KeptFrame.refusal(forDirectoryNamed: id) != nil, "\(id.debugDescription)")
    }

    @Test("ふつうの識別子は置き場の名前に使う", arguments: ["a1", "8f2b1c", "take 3", "観測-1", "a.b"])
    func acceptsOrdinaryIdentifiers(_ id: String) {
        #expect(KeptFrame.refusal(forDirectoryNamed: id) == nil)
    }
}

/// 観測 1 枚と、そのフレームについて分かる条件を組で持ち出す ([#2618](https://github.com/mokume-metal/mokume/issues/2618))。
/// GPU を要する。
@Suite(
    "観測の 1 枚を条件と組で持ち出す",
    .serialized,
    .enabled(
        if: RenderDevice.isAvailable,
        "この世代のコマンド構造に対応した GPU が無い実行環境ではスキップする"),
    .ownWarningDigest
)
@MainActor
struct ObservationKeepTests {
    /// 半径で円を描き、**描いた後に** 半径を 1 足す。描いた入力と `draw()` の終わりの値が違う。
    final class Growing: Sketch {
        @Param(0...1000) var radius: Double = 120
        var settings: SketchSettings { SketchSettings(width: 32, height: 24, frameRate: 60) }
        func draw() {
            background(0)
            fill(255)
            circle(16, 12, Float(radius) / 20)
            expose("drawnRadius", radius)
            radius += 1
        }
    }

    private struct Place {
        let facet: URL
        let kept: URL
    }

    private func place() throws -> Place {
        let root = try TestScratch.directory("mokume-observe-keep")
        let facet = root.appendingPathComponent("observe", isDirectory: true)
        try FileManager.default.createDirectory(at: facet, withIntermediateDirectories: true)
        return Place(facet: facet, kept: root.appendingPathComponent("kept", isDirectory: true))
    }

    private func makeRuntime(
        _ place: Place, sketch: any Sketch = Growing(), background: Bool = false
    ) throws -> (SketchRuntime, FrameObserver) {
        let observer = FrameObserver(
            directory: place.facet, writesInBackground: background, keptDirectory: place.kept)
        let runtime = try SketchRuntime(
            sketch: sketch, gpu: RenderDevice(), clock: .frameIndex(frameRate: 60), now: { 0 },
            observer: observer)
        return (runtime, observer)
    }

    private func request(_ body: String, in place: Place) throws {
        try AtomicFile.write(Data(body.utf8), to: place.facet.appendingPathComponent("request.json"))
    }

    private func json(_ url: URL) throws -> [String: Any] {
        try #require(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
    }

    /// 目録が出る (識別子が一致する) まで進める。**期限つきで待つ** — 裏で書く形では、決着は機械の混み具合で決まる。
    @discardableResult
    private func advance(
        _ runtime: SketchRuntime, untilReportOf id: String, in place: Place, limit: Double = 20
    ) throws -> [String: Any] {
        let deadline = Date().addingTimeInterval(limit)
        let url = place.facet.appendingPathComponent("report.json")
        while Date() < deadline {
            try runtime.advance()
            if let report = try? json(url), report["id"] as? String == id { return report }
        }
        Issue.record("目録 \(id) が \(limit) 秒たっても出ない")
        return [:]
    }

    private func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }

    private func paramValue(_ manifest: [String: Any], _ name: String) -> Double? {
        let params = manifest["params"] as? [String: Any]
        let values = params?["values"] as? [[String: Any]] ?? []
        return values.first { $0["name"] as? String == name }?["value"] as? Double
    }

    @Test(
        "keep の観測は、区画の外に絵と目録の組を残し、目録は draw() の終わりの値と名乗る。次の要求で消えない",
        arguments: [false, true])
    func keepsThePictureWithItsConditions(background: Bool) throws {
        let place = try place()
        let (runtime, _) = try makeRuntime(place, background: background)
        for _ in 0..<5 { try runtime.advance() }
        try request(#"{"id":"a1","keep":true}"#, in: place)
        let report = try advance(runtime, untilReportOf: "a1", in: place)

        #expect(report["kept"] as? String == "../kept/a1")
        #expect((report["warnings"] as? [String])?.contains { $0.contains("kept") } != true, "\(report)")
        let folder = place.kept.appendingPathComponent("a1", isDirectory: true)
        #expect(!exists(place.kept.appendingPathComponent("a1.partial")), "書き途中が残っている")
        // 応答からの相対で辿れる
        #expect(
            exists(place.facet.appendingPathComponent("../kept/a1/kept.json").standardizedFileURL))

        // 持ち出した絵は、区画の絵とバイト列ごと同じ (符号化し直さない・完了条件 6)
        let keptImage = try Data(contentsOf: folder.appendingPathComponent("frame.png"))
        let facetImage = try Data(contentsOf: place.facet.appendingPathComponent("frame-000.png"))
        #expect(keptImage == facetImage)

        let manifest = try json(folder.appendingPathComponent("kept.json"))
        let shot = try #require((report["frames"] as? [[String: Any]])?.first)
        #expect(manifest["schemaVersion"] as? Int == 1)
        #expect(manifest["complete"] as? Bool == true)
        #expect(manifest["id"] as? String == "a1")
        #expect(manifest["image"] as? String == "frame.png")
        #expect(manifest["frame"] as? Int == shot["frame"] as? Int)
        #expect(manifest["time"] as? Double == shot["time"] as? Double)
        #expect(manifest["clock"] as? [String: AnyHashable] == ["kind": "frames", "frameRate": 60])
        #expect(manifest["size"] as? [String: Int] == ["width": 32, "height": 24])
        #expect(manifest.keys.contains("stamp"))
        #expect(manifest["record"] is NSNull, "記録していない実行では、記録を指さない (種・版は不明)")
        #expect(manifest["paramsUnknownReason"] == nil)

        // 描いた半径は expose の値、目録の @Param は draw() の終わりの値 (描いた値 + 1)
        let values = try #require(manifest["values"] as? [String: [String: Any]])
        let drawn = try #require(values["drawnRadius"]?["value"] as? Double)
        #expect((manifest["params"] as? [String: Any])?["read"] as? String == "endOfDraw")
        #expect(paramValue(manifest, "radius") == drawn + 1, "\(manifest)")

        // 次の要求 (持ち出さない) は区画を書き直すが、持ち出した組には触れない
        let before = try Data(contentsOf: folder.appendingPathComponent("kept.json"))
        try request(#"{"id":"a2"}"#, in: place)
        let next = try advance(runtime, untilReportOf: "a2", in: place)
        #expect(next["kept"] == nil)
        #expect(try Data(contentsOf: folder.appendingPathComponent("kept.json")) == before)
        #expect(try Data(contentsOf: folder.appendingPathComponent("frame.png")) == keptImage)
    }

    /// 完了条件 1・6: `keep` を書かない観測は今と同じ。
    @Test("keep を書かない・false・null の観測は、応答も絵も同じで、持ち出しの置き場を作らない")
    func anObservationWithoutKeepIsUnchanged() throws {
        var answers: [(report: Data, image: Data)] = []
        for body in [#"{"id":"a1"}"#, #"{"id":"a1","keep":false}"#, #"{"id":"a1","keep":null}"#] {
            let place = try place()
            let (runtime, _) = try makeRuntime(place)
            for _ in 0..<3 { try runtime.advance() }
            try request(body, in: place)
            var report = try advance(runtime, untilReportOf: "a1", in: place)
            #expect(report["kept"] == nil, "\(body)")
            #expect(!exists(place.kept), "\(body) で持ち出しの置き場を作った")
            // 負荷 (メモリ・測った時間) は走らせるたびに違うので外して比べる
            report["load"] = nil
            answers.append(
                (
                    try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys]),
                    try Data(contentsOf: place.facet.appendingPathComponent("frame-000.png"))
                ))
        }
        #expect(answers[1].report == answers[0].report)
        #expect(answers[2].report == answers[0].report)
        #expect(answers[1].image == answers[0].image)
        #expect(answers[2].image == answers[0].image)
    }

    @Test("持ち出しを頼まない目録は、kept の鍵を書かない (符号化の段)")
    func theReplyWithoutKeepHasNoKeptKey() throws {
        let report = ObservationReport(
            id: "a1", image: "frame-000.png", frame: 3, time: 0.05, size: .init(width: 4, height: 4))
        let text = String(decoding: try JSONEncoder().encode(report), as: UTF8.self)
        #expect(!text.contains("kept"), "\(text)")
        let kept = report.keeping(at: "../kept/a1", warning: nil)
        #expect(String(decoding: try JSONEncoder().encode(kept), as: UTF8.self).contains(#""kept":"..\/kept\/a1""#))
    }

    @Test("2 枚以上の列と keep を一緒に頼むと、撮るが持ち出さず、警告で名乗る")
    func aSeriesIsTakenButNotKept() throws {
        let place = try place()
        let (runtime, _) = try makeRuntime(place)
        try runtime.advance()
        try request(#"{"id":"s1","count":2,"keep":true}"#, in: place)
        let report = try advance(runtime, untilReportOf: "s1", in: place)
        #expect((report["frames"] as? [Any])?.count == 2)
        #expect(report["image"] as? String == "frame-001.png")
        #expect(report["kept"] == nil)
        #expect(
            (report["warnings"] as? [String])?.contains {
                $0.contains("not kept") && $0.contains("single shot")
            } == true, "\(report)")
        #expect(!exists(place.kept))
    }

    @Test("外から止めている間に値だけ変えて撮ると、古い絵に新しい値を結び付けず、分からないと名乗る")
    func aKnobMovedWhilePausedIsNotTiedToTheOldPicture() throws {
        let place = try place()
        let sketch = Growing()
        let (runtime, _) = try makeRuntime(place, sketch: sketch)
        for _ in 0..<4 { try runtime.advance() }
        runtime.pause()
        try runtime.advance()

        // 止めたまま、値を変えずに撮る: 最後に描いたフレームの終わりの値が載る
        try request(#"{"id":"p1","keep":true}"#, in: place)
        try advance(runtime, untilReportOf: "p1", in: place)
        let still = try json(place.kept.appendingPathComponent("p1/kept.json"))
        #expect(paramValue(still, "radius") == sketch.radius, "\(still)")
        #expect(still["paramsUnknownReason"] == nil)

        // 止めたまま、つまみを動かしてから撮る: 絵は動いていないので、値は分からない
        #expect(runtime.paramRegistry.write(.float(500), to: "radius") != nil)
        try request(#"{"id":"p2","keep":true}"#, in: place)
        let report = try advance(runtime, untilReportOf: "p2", in: place)
        #expect(report["kept"] as? String == "../kept/p2")
        let moved = try json(place.kept.appendingPathComponent("p2/kept.json"))
        #expect(moved["params"] is NSNull, "\(moved)")
        #expect((moved["paramsUnknownReason"] as? String)?.contains("changed after frame") == true)
        #expect(moved["frame"] as? Int == still["frame"] as? Int, "止めている間は同じ絵")
    }

    @Test("記録中に撮った枚は、記録の識別子とフレーム番号を指す")
    func aShotWhileRecordingPointsAtTheRecord() throws {
        let place = try place()
        let (runtime, _) = try makeRuntime(place)
        let destination = place.facet.deletingLastPathComponent().appendingPathComponent("take.json")
        let replay = try #require(ReplayRequest(destination: destination.path))
        #expect(runtime.startRecording(replay))
        let recordID = try #require(runtime.recordingStatus?.id)
        for _ in 0..<3 { try runtime.advance() }
        try request(#"{"id":"r1","keep":true}"#, in: place)
        let report = try advance(runtime, untilReportOf: "r1", in: place)
        let manifest = try json(place.kept.appendingPathComponent("r1/kept.json"))
        let shot = try #require((report["frames"] as? [[String: Any]])?.first)
        #expect(manifest["record"] as? [String: AnyHashable] == ["id": recordID, "frame": shot["frame"] as? Int])
        runtime.closePlugins()
    }

    @Test("同じ名前の持ち出しが既に在れば、上書きも削除もせず、持ち出さずに名乗る")
    func anExistingFolderIsNeverOverwritten() throws {
        let place = try place()
        let folder = place.kept.appendingPathComponent("a1", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let sentinel = folder.appendingPathComponent("kept.json")
        try Data("earlier".utf8).write(to: sentinel)
        let (runtime, _) = try makeRuntime(place)
        try runtime.advance()
        try request(#"{"id":"a1","keep":true}"#, in: place)
        let report = try advance(runtime, untilReportOf: "a1", in: place)
        #expect(report["kept"] == nil)
        #expect(report["image"] as? String == "frame-000.png", "観測そのものは撮れている")
        #expect(
            (report["warnings"] as? [String])?.contains { $0.contains("already exists") } == true, "\(report)")
        #expect(try Data(contentsOf: sentinel) == Data("earlier".utf8))
        #expect(!exists(folder.appendingPathComponent("frame.png")))
        #expect(!exists(place.kept.appendingPathComponent("a1.partial")))
    }

    @Test("前の回が残した同じ名前の書き途中は、片付けてから書き直し、完成させる")
    func aLeftoverPartialIsReplaced() throws {
        let place = try place()
        let partial = place.kept.appendingPathComponent("a1.partial", isDirectory: true)
        try FileManager.default.createDirectory(at: partial, withIntermediateDirectories: true)
        try Data("stale".utf8).write(to: partial.appendingPathComponent("frame.png"))
        let (runtime, _) = try makeRuntime(place)
        try runtime.advance()
        try request(#"{"id":"a1","keep":true}"#, in: place)
        let report = try advance(runtime, untilReportOf: "a1", in: place)
        #expect(report["kept"] as? String == "../kept/a1")
        #expect(!exists(partial))
        let image = try Data(contentsOf: place.kept.appendingPathComponent("a1/frame.png"))
        #expect(image == (try Data(contentsOf: place.facet.appendingPathComponent("frame-000.png"))))
    }

    /// 完了条件 4: 書き込みが途中で転ぶと、完成の印 (改名と目録の `complete`) が無い形で残る。
    @Test(
        "持ち出しの書き込みが途中で転ぶと、書き途中のまま残り、完成として渡さない",
        arguments: [FrameObserver.KeepStep.image, .manifest, .rename])
    func aFailedKeepIsLeftUnfinished(_ step: FrameObserver.KeepStep) throws {
        let place = try place()
        let (runtime, observer) = try makeRuntime(place)
        observer.keepFault = step
        try runtime.advance()
        try request(#"{"id":"f1","keep":true}"#, in: place)
        let report = try advance(runtime, untilReportOf: "f1", in: place)
        #expect(report["kept"] == nil)
        #expect(report["image"] as? String == "frame-000.png", "観測そのものは撮れている")
        #expect(
            (report["warnings"] as? [String])?.contains { $0.contains("left unfinished") } == true, "\(report)")
        let partial = place.kept.appendingPathComponent("f1.partial", isDirectory: true)
        #expect(exists(partial), "書き途中が残っていない")
        #expect(!exists(place.kept.appendingPathComponent("f1")), "完成の名前が在る")
        #expect(exists(partial.appendingPathComponent("frame.png")) == (step != .image))
        #expect(exists(partial.appendingPathComponent("kept.json")) == (step == .rename))

        // 次の持ち出しは、別の識別子なら書き途中に触れずに完成する
        observer.keepFault = nil
        try request(#"{"id":"f2","keep":true}"#, in: place)
        let next = try advance(runtime, untilReportOf: "f2", in: place)
        #expect(next["kept"] as? String == "../kept/f2")
        #expect(exists(partial))
    }

    @Test("置き場を作れないときは、持ち出さずに名乗る")
    func anUnwritablePlaceIsNamed() throws {
        let place = try place()
        // 置き場の名前にファイルを置いて、ディレクトリを作れなくする
        try Data().write(to: place.kept)
        let (runtime, _) = try makeRuntime(place)
        try runtime.advance()
        try request(#"{"id":"u1","keep":true}"#, in: place)
        let report = try advance(runtime, untilReportOf: "u1", in: place)
        #expect(report["kept"] == nil)
        #expect(
            (report["warnings"] as? [String])?.contains { $0.contains("could not make") } == true, "\(report)")
    }

    @Test("置き場の名前に使えない識別子は、置き場の外へ書かずに断る")
    func anUnsafeIdentifierIsRefused() throws {
        let place = try place()
        let (runtime, _) = try makeRuntime(place)
        try runtime.advance()
        try request(#"{"id":"../escape","keep":true}"#, in: place)
        let report = try advance(runtime, untilReportOf: "../escape", in: place)
        #expect(report["kept"] == nil)
        #expect((report["warnings"] as? [String])?.contains { $0.contains("not kept") } == true)
        #expect(!exists(place.facet.deletingLastPathComponent().appendingPathComponent("escape")))
        #expect(!exists(place.kept))
    }
}
