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
        arguments: [
            "", ".", "..", "../x", "a/b", ".hidden", "a.partial", "a.PARTIAL", "a.Partial", "x.12.partial",
            "x.12.PARTIAL", String(repeating: "x", count: 237), "a\u{0}b",
        ])
    func refusesUnsafeIdentifiers(_ id: String) {
        #expect(KeptFrame.refusal(forDirectoryNamed: id) != nil, "\(id.debugDescription)")
    }

    @Test(
        "ふつうの識別子は置き場の名前に使う",
        arguments: ["a1", "8f2b1c", "take 3", "観測-1", "a.b", "partial", "a.partial.b", String(repeating: "x", count: 236)])
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
        _ place: Place, sketch: any Sketch = Growing(), background: Bool = false, inbox: URL? = nil
    ) throws -> (SketchRuntime, FrameObserver) {
        let observer = FrameObserver(
            directory: place.facet, writesInBackground: background, keptDirectory: place.kept)
        let runtime = try SketchRuntime(
            sketch: sketch, gpu: RenderDevice(), clock: .frameIndex(frameRate: 60), now: { 0 },
            observer: observer, inbox: inbox.map { InputInbox(directory: $0) })
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

    /// その名前に何か在るか (リンクはたどらない)。
    private func lexists(_ url: URL) -> Bool {
        var status = stat()
        return lstat(url.path, &status) == 0
    }

    /// 置き場に残った書き途中の名前。
    private func partials(in place: Place) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: place.kept.path)) ?? [])
            .filter { $0.hasSuffix(".partial") }.sorted()
    }

    /// 走っていないプロセスの番号 (書き途中を残して死んだ回の代わり)。
    private func deadProcess() throws -> pid_t {
        for candidate in stride(from: pid_t(99_998), to: 1_000, by: -1)
        where kill(candidate, 0) != 0 && errno == ESRCH {
            return candidate
        }
        throw CocoaError(.fileNoSuchFile)
    }

    /// 書き途中の置き場を、この手が置く形 (絵だけ) で作る。
    @discardableResult
    private func leavePartial(_ name: String, in place: Place, contents: [String] = ["frame.png"]) throws -> URL {
        let partial = place.kept.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: partial, withIntermediateDirectories: true)
        for entry in contents { try Data("stale".utf8).write(to: partial.appendingPathComponent(entry)) }
        return partial
    }

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
        #expect(partials(in: place).isEmpty, "書き途中が残っている")
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

    /// `setup()` で止め、押されたら決めたことをする。止めている間のコールバックが絵か値を変える形を作る。
    final class Pressed: Sketch {
        enum Action: Sendable, CustomStringConvertible {
            /// 何も描かず、値も変えない (数えるだけ)。
            case nothing
            /// 画素を 1 つ書く (`set()`)。
            case pixel
            /// 描いて、読み出しのために描き切らせる (`loadPixels()`)。
            case drawing
            /// `@Param` を書き換える。
            case knob

            var description: String {
                switch self {
                case .nothing: "nothing"
                case .pixel: "pixel"
                case .drawing: "drawing"
                case .knob: "knob"
                }
            }
        }

        @Param(0...1000) var radius: Double = 120
        var action: Action = .nothing
        var presses = 0
        init() {}
        var settings: SketchSettings { SketchSettings(width: 32, height: 24, frameRate: 60) }
        func setup() { noLoop() }
        func draw() {
            background(0)
            circle(16, 12, Float(radius) / 20)
        }
        func mousePressed() {
            presses += 1
            switch action {
            case .nothing: break
            case .pixel: set(1, 1, .linear(red: 1, green: 1, blue: 1))
            case .drawing:
                fill(255)
                rect(0, 0, 8, 8)
                loadPixels()
            case .knob: radius = 999
            }
        }
    }

    /// 反証 5: 止めている間に配った入力のコールバックが絵を書き換えたら、その絵は描いたフレームの絵ではない。
    /// 値だけを変えたなら絵は同じで、値が分からないと名乗る。何もしなければ値まで載る。
    @Test(
        "止めている間のコールバックが絵を書き換えたら持ち出さず、値だけなら値を不明と名乗る",
        arguments: [Pressed.Action.nothing, .pixel, .drawing, .knob])
    func aCallbackWhileStoppedIsSeen(_ action: Pressed.Action) throws {
        let place = try place()
        let inbox = try TestScratch.directory("mokume-observe-keep-input")
        let sketch = Pressed()
        sketch.action = action
        let (runtime, _) = try makeRuntime(place, sketch: sketch, inbox: inbox)
        try runtime.advance()
        try runtime.advance()
        try AtomicFile.write(
            Data(#"{"id":"i1","events":[{"type":"mouseDown","x":4,"y":4,"button":0}]}"#.utf8),
            to: inbox.appendingPathComponent("request.json"))
        try runtime.advance()
        #expect(sketch.presses == 1, "止めている間にコールバックが配られていない")

        try request(#"{"id":"c1","keep":true}"#, in: place)
        let report = try advance(runtime, untilReportOf: "c1", in: place)
        let warnings = report["warnings"] as? [String] ?? []
        switch action {
        case .nothing, .knob:
            #expect(report["kept"] as? String == "../kept/c1", "\(report)")
            let manifest = try json(place.kept.appendingPathComponent("c1/kept.json"))
            if action == .nothing {
                #expect(paramValue(manifest, "radius") == 120, "\(manifest)")
            } else {
                #expect(manifest["params"] is NSNull, "\(manifest)")
                #expect((manifest["paramsUnknownReason"] as? String)?.contains("changed after frame") == true)
            }
        case .pixel, .drawing:
            #expect(report["kept"] == nil, "\(report)")
            #expect(warnings.contains { $0.contains("not kept") && $0.contains("picture was changed") }, "\(warnings)")
            #expect(!lexists(place.kept.appendingPathComponent("c1")))
        }
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

    /// 反証 3: 既に在る `<id>` は、中身の在るフォルダでも空のフォルダでも上書きしない。
    @Test("同じ名前の持ち出しが既に在れば、上書きも削除もせず、持ち出さずに名乗る", arguments: [false, true])
    func anExistingFolderIsNeverOverwritten(empty: Bool) throws {
        let place = try place()
        let folder = place.kept.appendingPathComponent("a1", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let sentinel = folder.appendingPathComponent("kept.json")
        if !empty { try Data("earlier".utf8).write(to: sentinel) }
        let (runtime, _) = try makeRuntime(place)
        try runtime.advance()
        try request(#"{"id":"a1","keep":true}"#, in: place)
        let report = try advance(runtime, untilReportOf: "a1", in: place)
        #expect(report["kept"] == nil)
        #expect(report["image"] as? String == "frame-000.png", "観測そのものは撮れている")
        #expect(
            (report["warnings"] as? [String])?.contains { $0.contains("already exists") } == true, "\(report)")
        let left = try FileManager.default.contentsOfDirectory(atPath: folder.path)
        #expect(left == (empty ? [] : ["kept.json"]), "既に在ったフォルダの中身が変わった")
        if !empty { #expect(try Data(contentsOf: sentinel) == Data("earlier".utf8)) }
        #expect(partials(in: place).isEmpty)
    }

    /// 反証 3: 在るかを確かめてから移すまでの間に `<id>` を置かれても、置かれたものを置き換えない (`RENAME_EXCL`)。
    @Test("確かめた後に同じ名前の空のフォルダを置かれても、置き換えずに書き途中のまま残す")
    func aFolderPlacedJustBeforeTheMoveIsNotReplaced() throws {
        let place = try place()
        let (runtime, observer) = try makeRuntime(place)
        let folder = place.kept.appendingPathComponent("a1", isDirectory: true)
        observer.keepWillPlace = {
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        }
        try runtime.advance()
        try request(#"{"id":"a1","keep":true}"#, in: place)
        let report = try advance(runtime, untilReportOf: "a1", in: place)
        #expect(report["kept"] == nil)
        #expect(
            (report["warnings"] as? [String])?.contains { $0.contains("left unfinished") } == true, "\(report)")
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path).isEmpty, "置かれたフォルダを置き換えた")
        #expect(partials(in: place) == ["a1.\(getpid()).partial"])
    }

    /// 反証 1: 大文字小文字だけが違う名前は、大文字小文字を区別しないボリューム (macOS の既定) では同じ名前になる。
    /// 区別するボリュームでも成り立つ形で見る — **既に在る別の名前の置き場は、どちらでも残る**。
    @Test("大文字小文字だけが違う名前の持ち出しが既に在っても、それを消さず書き換えない")
    func aFolderDifferingOnlyInCaseIsKept() throws {
        let place = try place()
        let other = place.kept.appendingPathComponent("A1", isDirectory: true)
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        try Data("earlier".utf8).write(to: other.appendingPathComponent("kept.json"))
        let (runtime, _) = try makeRuntime(place)
        try runtime.advance()
        try request(#"{"id":"a1","keep":true}"#, in: place)
        let report = try advance(runtime, untilReportOf: "a1", in: place)
        let listing = try FileManager.default.contentsOfDirectory(atPath: place.kept.path)
        #expect(listing.contains("A1"), "\(listing)")
        #expect(try Data(contentsOf: other.appendingPathComponent("kept.json")) == Data("earlier".utf8))
        #expect(partials(in: place).isEmpty)
        // 区別しないボリュームでは同じ名前なので断る。区別するボリュームでは別の名前として置く
        let caseFolds = !listing.contains("a1")
        #expect((report["kept"] == nil) == caseFolds, "\(report)")
    }

    /// 反証 2: 片付けてよいのは、名前の形が合い、持ち主がもう居ない、中身もこの手が置く形の書き途中だけ。
    @Test("死んだ回が残した書き途中だけを片付け、生きている回・形の違うものには触れずに完成させる")
    func onlyAbandonedPartialsAreCleared() throws {
        let place = try place()
        let dead = try deadProcess()
        let abandoned = try leavePartial("a1.\(dead).partial", in: place, contents: ["frame.png", "kept.json"])
        // 生きているプロセス (launchd) の書き途中・中身の形が違う書き途中・名前の形が違うもの (pid の無い名前・
        // 大文字の尾) は残す
        let living = try leavePartial("a1.1.partial", in: place)
        let foreign = try leavePartial("a1.\(dead - 1).partial", in: place, contents: ["frame.png", "notes.txt"])
        let unnumbered = try leavePartial("a1.partial", in: place)
        let shouting = try leavePartial("a1.\(dead - 2).PARTIAL", in: place)
        let (runtime, _) = try makeRuntime(place)
        try runtime.advance()
        try request(#"{"id":"a1","keep":true}"#, in: place)
        let report = try advance(runtime, untilReportOf: "a1", in: place)
        #expect(report["kept"] as? String == "../kept/a1", "\(report)")
        #expect(!lexists(abandoned), "死んだ回の書き途中が残っている")
        for left in [living, foreign, unnumbered, shouting] {
            #expect(exists(left.appendingPathComponent("frame.png")), "\(left.lastPathComponent) を片付けた")
        }
        #expect(exists(foreign.appendingPathComponent("notes.txt")))
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
        let partial = place.kept.appendingPathComponent("f1.\(getpid()).partial", isDirectory: true)
        #expect(exists(partial), "書き途中が残っていない")
        #expect(!lexists(place.kept.appendingPathComponent("f1")), "完成の名前が在る")
        #expect(exists(partial.appendingPathComponent("frame.png")) == (step != .image))
        // 反証 4: 改名で転んだ書き途中の中にも `complete: true` の目録が残る。完成の印は名前 (`f1`) で、目録の
        // `complete` ではない — 書き途中の中の目録は、完成の置き場の名前の下には無い
        let manifest = partial.appendingPathComponent("kept.json")
        #expect(exists(manifest) == (step == .rename))
        if step == .rename { #expect(try json(manifest)["complete"] as? Bool == true) }

        // 次の持ち出しは、別の識別子なら書き途中に触れずに完成する
        observer.keepFault = nil
        try request(#"{"id":"f2","keep":true}"#, in: place)
        let next = try advance(runtime, untilReportOf: "f2", in: place)
        #expect(next["kept"] as? String == "../kept/f2")
        #expect(exists(partial))
    }

    @Test("置き場の名前にファイルが在るときは、消さず、持ち出さずに名乗る")
    func anUnwritablePlaceIsNamed() throws {
        let place = try place()
        // 置き場の名前にファイルを置いて、ディレクトリを作れなくする
        try Data("mine".utf8).write(to: place.kept)
        let (runtime, _) = try makeRuntime(place)
        try runtime.advance()
        try request(#"{"id":"u1","keep":true}"#, in: place)
        let report = try advance(runtime, untilReportOf: "u1", in: place)
        #expect(report["kept"] == nil)
        #expect(
            (report["warnings"] as? [String])?.contains { $0.contains("is not a folder") } == true, "\(report)")
        #expect(try Data(contentsOf: place.kept) == Data("mine".utf8))
    }

    /// 反証 7: 置き場 (`.mokume/kept`) 自体がシンボリックリンクなら、たどって外へ書かない・外のものを消さない。
    @Test("置き場がシンボリックリンクなら、たどらず、外へ 1 バイトも書かず、外のものを消さない")
    func aLinkedPlaceIsNotFollowed() throws {
        let place = try place()
        let outside = try TestScratch.directory("mokume-observe-keep-outside")
        let dead = try deadProcess()
        // 外に、片付けの対象と同じ形の書き途中を置く (たどれば消える)
        let stale = outside.appendingPathComponent("l1.\(dead).partial", isDirectory: true)
        try FileManager.default.createDirectory(at: stale, withIntermediateDirectories: true)
        try Data("stale".utf8).write(to: stale.appendingPathComponent("frame.png"))
        let before = try FileManager.default.subpathsOfDirectory(atPath: outside.path).sorted()
        try FileManager.default.createSymbolicLink(at: place.kept, withDestinationURL: outside)
        let (runtime, _) = try makeRuntime(place)
        try runtime.advance()
        try request(#"{"id":"l1","keep":true}"#, in: place)
        let report = try advance(runtime, untilReportOf: "l1", in: place)
        #expect(report["kept"] == nil)
        #expect(
            (report["warnings"] as? [String])?.contains { $0.contains("is not a folder") } == true, "\(report)")
        #expect(try FileManager.default.subpathsOfDirectory(atPath: outside.path).sorted() == before)
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: place.kept.path) == outside.path)
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
