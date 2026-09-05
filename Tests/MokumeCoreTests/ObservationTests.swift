// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation
import Testing

@testable import MokumeCore

/// スケッチと繋いだ観測。GPU を要する。
@Suite(
    "スケッチを外から観測する",
    .enabled(
        if: RenderDevice.isAvailable,
        "この世代のコマンド構造に対応した GPU が無い実行環境ではスキップする")
)
struct ObservationTests {
    /// 左上に白い四角を置く。地は黒。
    final class Corner: Sketch {
        init() {}
        var settings: SketchSettings { SketchSettings(width: 32, height: 24) }
        func draw() {
            background(.display(red: 0, green: 0, blue: 0))
            fill(.display(red: 1, green: 1, blue: 1))
            rect(0, 0, 8, 6)
            expose("frame", frameCount)
            expose("label", "corner")
        }
    }

    /// フレームごとに四角が右へ動く。**動きを観測できているか**を見るため。
    final class Drifting: Sketch {
        init() {}
        /// `draw()` が呼ばれた回数。撮っているあいだもフレームループが進んでいることを
        /// 数えるために持つ。
        private(set) var draws = 0
        var settings: SketchSettings { SketchSettings(width: 32, height: 24) }
        func draw() {
            draws += 1
            background(.display(red: 0, green: 0, blue: 0))
            fill(.display(red: 1, green: 1, blue: 1))
            rect(Float(frameCount % 20), 8, 8, 8)
            expose("frame", frameCount)
        }
    }

    /// 一様に塗るだけ。
    final class Flat: Sketch {
        init() {}
        var settings: SketchSettings { SketchSettings(width: 16, height: 16) }
        func draw() { background(.display(red: 0.2, green: 0.2, blue: 0.2)) }
    }

    private func makeFacet() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("mokume-observe-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func request(
        id: String, scale: Double? = nil, count: Int? = nil, every: Int? = nil, in facet: URL
    ) throws {
        var body = #"{"id":"\#(id)""#
        if let scale { body += ",\"scale\":\(scale)" }
        if let count { body += ",\"count\":\(count)" }
        if let every { body += ",\"every\":\(every)" }
        body += "}"
        try AtomicFile.write(Data(body.utf8), to: facet.appendingPathComponent("request.json"))
    }

    private func frames(in facet: URL) throws -> [[String: Any]] {
        try readReport(in: facet)["frames"] as? [[String: Any]] ?? []
    }

    private func readReport(in facet: URL) throws -> [String: Any] {
        let data = try Data(contentsOf: facet.appendingPathComponent("report.json"))
        return try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
    }

    private func makeRuntime(_ sketch: any Sketch, facet: URL, now: @escaping () -> Double = { 0 })
        throws -> SketchRuntime
    {
        try SketchRuntime(
            sketch: sketch, gpu: try RenderDevice(), clock: nil, now: now,
            observer: FrameObserver(directory: facet))
    }

    @Test("要求を置くと、絵と内訳が出てくる")
    func respondsWithAnImageAndItsAccount() throws {
        let facet = try makeFacet()
        let runtime = try makeRuntime(Corner(), facet: facet)
        try runtime.advance()
        try runtime.advance()

        try request(id: "a1", in: facet)
        try runtime.advance()

        let report = try readReport(in: facet)
        #expect(report["id"] as? String == "a1")
        #expect(report["frame"] as? Int == 3)
        #expect((report["size"] as? [String: Any])?["width"] as? Int == 32)
        #expect(report["image"] as? String == "frame-000.png")
        #expect(
            FileManager.default.fileExists(
                atPath: facet.appendingPathComponent("frame-000.png").path))
    }

    @Test("差し出した値が、その絵と同じ応答に載る")
    func carriesTheValuesTheSketchExposed() throws {
        let facet = try makeFacet()
        let runtime = try makeRuntime(Corner(), facet: facet)
        try runtime.advance()

        try request(id: "a1", in: facet)
        try runtime.advance()

        let values = try readReport(in: facet)["values"] as? [String: Any]
        let frame = values?["frame"] as? [String: Any]
        #expect(frame?["type"] as? String == "int")
        #expect(frame?["value"] as? Int == 2)
        let label = values?["label"] as? [String: Any]
        #expect(label?["type"] as? String == "string")
        #expect(label?["value"] as? String == "corner")
    }

    @Test("止めていても応答が返り、そのときフレームは進まない")
    func answersWhilePausedWithoutAdvancing() throws {
        let facet = try makeFacet()
        let runtime = try makeRuntime(Corner(), facet: facet)
        try runtime.advance()
        try runtime.advance()
        runtime.pause()

        try request(id: "a1", in: facet)
        try runtime.advance()

        let report = try readReport(in: facet)
        #expect(report["id"] as? String == "a1")
        // 止めた時点の絵をそのまま返す。観測がフレーム番号を動かさない
        #expect(report["frame"] as? Int == 2)
        #expect(runtime.frameCount == 2)
        #expect(report["image"] as? String == "frame-000.png")
    }

    @Test("まだ 1 枚も描いていなければ、1 枚描いてから応える")
    func drawsTheFirstFrameForTheFirstRequest() throws {
        let facet = try makeFacet()
        let runtime = try makeRuntime(Corner(), facet: facet)
        runtime.pause()

        try request(id: "a1", in: facet)
        try runtime.advance()

        let report = try readReport(in: facet)
        #expect(report["id"] as? String == "a1")
        #expect(report["frame"] as? Int == 1)
        #expect(
            FileManager.default.fileExists(
                atPath: facet.appendingPathComponent("frame-000.png").path))
    }

    @Test("絵の要約が、実際に描かれたものを映す")
    func summarizesWhatWasActuallyDrawn() throws {
        let facet = try makeFacet()
        let runtime = try makeRuntime(Corner(), facet: facet)
        try runtime.advance()
        try request(id: "a1", in: facet)
        try runtime.advance()

        let stats = try #require(try readReport(in: facet)["stats"] as? [String: Any])
        let fraction = try #require(stats["contentFraction"] as? Double)
        // 左上の 8x6 が白。面は 32x24 なので、地と違う点は全体の 1 割弱
        #expect(fraction > 0)
        #expect(fraction < 0.2)

        let bounds = try #require(stats["contentBounds"] as? [String: Any])
        #expect((bounds["x"] as? Double) == 0)
        #expect((bounds["y"] as? Double) == 0)
        #expect((bounds["width"] as? Double ?? 1) < 0.4)
    }

    @Test("一様な絵では、内容のある点が 0 になる")
    func reportsNoContentForAFlatImage() throws {
        let facet = try makeFacet()
        let runtime = try makeRuntime(Flat(), facet: facet)
        try runtime.advance()
        try request(id: "a1", in: facet)
        try runtime.advance()

        let stats = try #require(try readReport(in: facet)["stats"] as? [String: Any])
        #expect(stats["contentFraction"] as? Double == 0)
        #expect(stats["contentBounds"] == nil)
    }

    @Test("縮めて撮ると、小さい絵が出てくる")
    func honorsTheRequestedScale() throws {
        let facet = try makeFacet()
        let runtime = try makeRuntime(Corner(), facet: facet)
        try runtime.advance()
        try request(id: "a1", scale: 0.5, in: facet)
        try runtime.advance()

        let grid = try #require(try readReport(in: facet)["stats"] as? [String: Any])
        let sampleGrid = try #require(grid["sampleGrid"] as? [String: Any])
        // 32x24 を半分にした 16x12 を、64 点の格子で数えようとすると絵の大きさで頭打ちになる
        #expect(sampleGrid["width"] as? Int == 16)
        #expect(sampleGrid["height"] as? Int == 12)
        // 面の大きさは縮めない — 何を描いた面かは変わらないため
        #expect((try readReport(in: facet)["size"] as? [String: Any])?["width"] as? Int == 32)
    }

    @Test("走らせている重さが載る")
    func carriesTheRuntimeLoad() throws {
        let facet = try makeFacet()
        var clock = 0.0
        let runtime = try makeRuntime(Corner(), facet: facet, now: { clock })
        for _ in 0..<4 {
            clock += 0.016
            try runtime.advance()
        }
        try request(id: "a1", in: facet)
        clock += 0.016
        try runtime.advance()

        let load = try #require(try readReport(in: facet)["load"] as? [String: Any])
        let rate = try #require(load["frameRate"] as? Double)
        #expect(abs(rate - 62.5) < 0.5)
        #expect(load["thermalState"] as? String != nil)
        #expect((load["memoryMB"] as? Double ?? 0) > 0)
    }

    // MARK: - 描画が失敗しても観測は応える (#221)

    @Test("描けなかったフレームでも、理由を載せた応答が返る")
    func answersEvenWhenTheFrameCouldNotBeDrawn() throws {
        let facet = try makeFacet()
        let runtime = try makeRuntime(Corner(), facet: facet)
        let image = facet.appendingPathComponent("frame-000.png")

        // 先に 1 枚撮っておく。前回の絵が残っている状態から失敗させる
        try runtime.advance()
        try request(id: "ok", in: facet)
        try runtime.advance()
        #expect(FileManager.default.fileExists(atPath: image.path))

        runtime.canvas.failureForTesting = .timedOut(seconds: 5)
        try request(id: "a1", in: facet)
        #expect(throws: RenderFailure.self) { try runtime.advance() }

        let report = try readReport(in: facet)
        #expect(report["id"] as? String == "a1")
        // 描画先の中身が信用できないので絵は採らない。理由は必ず載る (ADR-0018 決定 3)
        #expect(report["image"] as? String == nil)
        #expect((report["warnings"] as? [String])?.isEmpty == false)
        // 新しい識別子の応答と古い絵を組にしない
        #expect(!FileManager.default.fileExists(atPath: image.path))
    }

    @Test("描画が失敗し続けても、置いた要求すべてに応答が返る")
    func keepsAnsweringWhileTheFrameKeepsFailing() throws {
        let facet = try makeFacet()
        let runtime = try makeRuntime(Corner(), facet: facet)
        try runtime.advance()
        runtime.canvas.failureForTesting = .encoderUnavailable

        var answered = 0
        for index in 1...100 {
            let id = "r\(index)"
            try request(id: id, in: facet)
            try? runtime.advance()
            if try readReport(in: facet)["id"] as? String == id { answered += 1 }
        }
        #expect(answered == 100)
    }

    @Test("入力が生きているのに観測だけが黙る、という形にならない")
    func neverGoesSilentWhileInputKeepsAnswering() throws {
        let observeFacet = try makeFacet()
        let inputFacet = try makeFacet()
        let runtime = try SketchRuntime(
            sketch: Corner(), gpu: try RenderDevice(), clock: nil, now: { 0 },
            observer: FrameObserver(directory: observeFacet),
            inbox: InputInbox(directory: inputFacet))
        try runtime.advance()
        runtime.canvas.failureForTesting = .timedOut(seconds: 5)

        try AtomicFile.write(
            Data(#"{"id":"i1","events":[{"type":"mouseMoved","x":1,"y":2}]}"#.utf8),
            to: inputFacet.appendingPathComponent("request.json"))
        try request(id: "o1", in: observeFacet)
        try? runtime.advance()

        // 入力が応えているなら、観測も応えていなければならない
        let inputReport = try JSONSerialization.jsonObject(
            with: Data(contentsOf: inputFacet.appendingPathComponent("report.json")))
            as? [String: Any]
        #expect(inputReport?["id"] as? String == "i1")
        #expect(try readReport(in: observeFacet)["id"] as? String == "o1")
    }

    // MARK: - 動きを続けて観測する (#387)

    @Test("1 枚だけ頼んでも、目録は 1 要素の並びとして在る")
    func alwaysCarriesAnIndexEvenForASingleFrame() throws {
        // 枚数で応答の形が変わると、読み手はまず形を見分けるところから始めることになる
        let facet = try makeFacet()
        let runtime = try makeRuntime(Corner(), facet: facet)
        try request(id: "a1", in: facet)
        try runtime.advance()

        let listed = try frames(in: facet)
        #expect(listed.count == 1)
        #expect(listed.first?["image"] as? String == "frame-000.png")
        let top = try readReport(in: facet)["frame"] as? Int
        #expect(listed.first?["frame"] as? Int == top)
    }

    @Test("続けて撮ると、宣言した枚数の絵と目録が返る")
    func capturesTheDeclaredNumberOfFrames() throws {
        let facet = try makeFacet()
        let runtime = try makeRuntime(Drifting(), facet: facet)
        try runtime.advance()

        try request(id: "a1", count: 4, every: 2, in: facet)
        // 頼んだ列が返るまで進める。届いた時点で止める
        for _ in 0..<16 where (try? readReport(in: facet)["id"] as? String) != "a1" {
            try runtime.advance()
        }

        let report = try readReport(in: facet)
        #expect(report["id"] as? String == "a1")
        let listed = try frames(in: facet)
        #expect(listed.count == 4)

        // 名前は撮った順、絵は全部そこに在る
        #expect(
            listed.compactMap { $0["image"] as? String }
                == ["frame-000.png", "frame-001.png", "frame-002.png", "frame-003.png"])
        for name in listed.compactMap({ $0["image"] as? String }) {
            #expect(
                FileManager.default.fileExists(
                    atPath: facet.appendingPathComponent(name).path))
        }

        // フレーム番号が間隔どおりに並ぶ
        let numbers = listed.compactMap { $0["frame"] as? Int }
        #expect(numbers.count == 4)
        #expect(zip(numbers, numbers.dropFirst()).allSatisfy { $1 - $0 == 2 })

        // 上の階は最後の 1 枚を指す
        #expect(report["image"] as? String == "frame-003.png")
        #expect(report["frame"] as? Int == numbers.last)
    }

    @Test("撮っているあいだも、フレームは進み続ける")
    func keepsTheFrameLoopRunningWhileCapturing() throws {
        // 止めてから撮ると、測っている対象そのものが変わる
        let sketch = Drifting()
        let facet = try makeFacet()
        let runtime = try makeRuntime(sketch, facet: facet)
        try runtime.advance()
        let before = sketch.draws

        try request(id: "a1", count: 5, every: 3, in: facet)
        var advances = 0
        while (try? readReport(in: facet)["id"] as? String) != "a1", advances < 40 {
            try runtime.advance()
            advances += 1
        }

        #expect(try readReport(in: facet)["id"] as? String == "a1")
        // 進めた回数ぶん、ちょうど描かれている — 1 回でも間引かれていたら合わない
        #expect(sketch.draws - before == advances)

        // 絵の中身も動いている。数字だけで判定できることが目録の値打ち
        let bounds = try frames(in: facet).compactMap {
            ($0["stats"] as? [String: Any])?["contentBounds"] as? [String: Any]
        }
        #expect(bounds.count == 5)
        #expect(Set(bounds.compactMap { $0["x"] as? Double }).count > 1)
    }

    @Test("フレームごとの値が、その絵と同じ行に載る")
    func carriesPerFrameValuesInTheIndex() throws {
        let facet = try makeFacet()
        let runtime = try makeRuntime(Drifting(), facet: facet)
        try request(id: "a1", count: 3, in: facet)
        for _ in 0..<8 where (try? readReport(in: facet)["id"] as? String) != "a1" {
            try runtime.advance()
        }

        let exposed = try frames(in: facet).compactMap {
            (($0["values"] as? [String: Any])?["frame"] as? [String: Any])?["value"] as? Int
        }
        #expect(exposed.count == 3)
        // 差し出した値も動いている。絵を開かずに「進んだ」と言える
        #expect(exposed == exposed.sorted())
        #expect(Set(exposed).count == 3)
        // その行の絵を描いたフレームと同じ番号になっている
        let captured = try frames(in: facet).compactMap { $0["frame"] as? Int }
        #expect(exposed == captured)
    }

    @Test("上限を超えて頼むと、切り詰めたことが応答に出る")
    func saysSoWhenItTrimsAnOversizedRequest() throws {
        // **黙って切らない。** 切ったことが応答から読めないと、読み手は「動きが途中で
        // 止まった」と「上限で切られた」を区別できない (切る規則そのものは
        // ObservationProtocolTests の純粋な検査が見る)
        let facet = try makeFacet()
        let runtime = try makeRuntime(Flat(), facet: facet)
        try request(id: "a1", count: 1, every: 1_000, in: facet)
        try runtime.advance()

        #expect(try readReport(in: facet)["id"] as? String == "a1")
        let warnings = try readReport(in: facet)["warnings"] as? [String] ?? []
        #expect(warnings.contains { $0.contains("1000") && $0.contains("60") })
    }

    @Test("撮っている途中で描けなくなったら、そこまでを残して打ち切る")
    func stopsTheCaptureWhenTheFrameFails() throws {
        let facet = try makeFacet()
        let runtime = try makeRuntime(Drifting(), facet: facet)
        try runtime.advance()

        try request(id: "a1", count: 6, every: 1, in: facet)
        try runtime.advance()
        try runtime.advance()
        runtime.canvas.failureForTesting = .timedOut(seconds: 5)
        #expect(throws: RenderFailure.self) { try runtime.advance() }

        let report = try readReport(in: facet)
        #expect(report["id"] as? String == "a1")
        // 揃わなかったので image は落とす — 読み手はこの鍵の有無だけで成否を言える
        #expect(report["image"] as? String == nil)
        #expect((report["warnings"] as? [String])?.isEmpty == false)
        // そこまでに撮れた絵は目録に残る。数が宣言と合わないことで途中だと分かる
        let listed = try frames(in: facet)
        #expect(!listed.isEmpty)
        #expect(listed.count < 6)
    }

    @Test("進んでいないあいだに撮ると、そのことわりが出る")
    func warnsWhenTheSameFrameRepeats() throws {
        let facet = try makeFacet()
        let runtime = try makeRuntime(Drifting(), facet: facet)
        try runtime.advance()
        runtime.pause()

        try request(id: "a1", count: 3, in: facet)
        for _ in 0..<8 where (try? readReport(in: facet)["id"] as? String) != "a1" {
            try runtime.advance()
        }

        let numbers = try frames(in: facet).compactMap { $0["frame"] as? Int }
        #expect(numbers.count == 3)
        #expect(Set(numbers).count == 1)
        let warnings = try readReport(in: facet)["warnings"] as? [String] ?? []
        #expect(warnings.contains { $0.contains("同じフレーム") })
    }

    @Test("撮っているあいだは、次の要求を拾わない")
    func ignoresANewRequestUntilTheCaptureEnds() throws {
        // 拾うと 2 つの列が同じ区画へ混ざり、どちらの目録も数が合わなくなる
        let facet = try makeFacet()
        let runtime = try makeRuntime(Drifting(), facet: facet)
        try runtime.advance()

        try request(id: "a1", count: 4, every: 2, in: facet)
        try runtime.advance()
        try request(id: "a2", count: 2, in: facet)

        var advances = 0
        while (try? readReport(in: facet)["id"] as? String) != "a1", advances < 20 {
            try runtime.advance()
            advances += 1
        }
        #expect(try frames(in: facet).count == 4)
        // 割り込んだ要求は捨てられず、列が終わってから応えられる
        advances = 0
        while (try? readReport(in: facet)["id"] as? String) != "a2", advances < 20 {
            try runtime.advance()
            advances += 1
        }
        #expect(try readReport(in: facet)["id"] as? String == "a2")
        #expect(try frames(in: facet).count == 2)
    }

    @Test("新しい列を撮り始めると、前の列の絵が残らない")
    func leavesNoImagesFromThePreviousCapture() throws {
        let facet = try makeFacet()
        let runtime = try makeRuntime(Drifting(), facet: facet)
        try request(id: "a1", count: 5, in: facet)
        for _ in 0..<12 where (try? readReport(in: facet)["id"] as? String) != "a1" {
            try runtime.advance()
        }
        #expect(try frames(in: facet).count == 5)

        try request(id: "a2", count: 2, in: facet)
        for _ in 0..<8 where (try? readReport(in: facet)["id"] as? String) != "a2" {
            try runtime.advance()
        }

        // 目録は 2 枚。区画に残っている絵も 2 枚 — 3 枚目以降が残っていると、
        // 目録を読まずに覗いた人が前の列と取り違える
        #expect(try frames(in: facet).count == 2)
        let left = try FileManager.default.contentsOfDirectory(atPath: facet.path)
            .filter { $0.hasPrefix("frame-") }
        #expect(left.sorted() == ["frame-000.png", "frame-001.png"])
    }
}

/// 観測が**まだ 1 枚も描いていない**スケッチを叩いたときの 1 枚。
///
/// 通常のフレームと同じ手順で描かれることを見る。かつてはここだけが別に書かれており、
/// 入り口の供給と面への時刻の受け渡しが落ちていた
/// ([#808](https://github.com/mokume-metal/mokume/issues/808))。**窓で走らせている限り
/// 再現しない**ので、外から観測する側でしか気付けない。
@Suite(
    "観測が最初に叩いた 1 枚",
    .enabled(
        if: RenderDevice.isAvailable,
        "この世代のコマンド構造に対応した GPU が無い実行環境ではスキップする")
)
struct FirstObservedFrameTests {
    /// 描いた瞬間の**面の**時刻を控える。
    ///
    /// `Sketch/time` ではなく面の側を見る — 落ちていたのは面への受け渡しで、
    /// `timing` はどちらの経路でも進んでいたためである。面の時刻は利用者の断片と
    /// 粒が読むので、ここが前の値のままだと動くものだけが止まる。
    final class SurfaceClock: Sketch {
        init() {}
        private(set) var times: [Float] = []
        private(set) var deltas: [Float] = []
        var settings: SketchSettings { SketchSettings(width: 16, height: 16) }
        func draw() {
            background(.display(red: 0, green: 0, blue: 0))
            times.append(canvas.time)
            deltas.append(canvas.deltaTime)
        }
    }

    /// 呼ばれた回数を数える入り口。
    final class CountingInlet: Inlet {
        private(set) var supplied = 0
        func supply() { supplied += 1 }
    }

    struct InletPlugin: Plugin {
        let inlet: any Inlet
        func register(into registry: PluginRegistry) { registry.add(inlet: inlet) }
    }

    /// 入り口を 1 本だけ持つスケッチ。`Sketch` は引数なしで作れる必要があるので、
    /// 走らせる前に差し込む。
    final class InletSketch: Sketch {
        nonisolated(unsafe) static var declared: [any Plugin] = []
        init() {}
        var settings: SketchSettings { SketchSettings(width: 16, height: 16) }
        var plugins: [any Plugin] { Self.declared }
        func draw() { background(.display(red: 0, green: 0, blue: 0)) }
    }

    private func makeFacet() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("mokume-first-frame-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func request(id: String, in facet: URL) throws {
        try AtomicFile.write(
            Data(#"{"id":"\#(id)"}"#.utf8), to: facet.appendingPathComponent("request.json"))
    }

    @Test("面の時刻が、そのフレームの値になっている")
    func handsTheSurfaceThisFramesClock() throws {
        let facet = try makeFacet()
        let sketch = SurfaceClock()
        // 実時間の時計を差し、進めた先を検査から決める。フレーム番号から導く時計だと
        // 最初の 1 枚がちょうど面の既定値と重なり、落ちていても気付けない
        nonisolated(unsafe) var clockReading = 0.0
        let runtime = try SketchRuntime(
            sketch: sketch, gpu: try RenderDevice(), clock: .wallClock, now: { clockReading },
            observer: FrameObserver(directory: facet))
        runtime.pause()

        clockReading = 2
        try request(id: "a1", in: facet)
        try runtime.advance()

        #expect(sketch.times == [2])
        #expect(sketch.deltas == [2])
    }

    @Test("入り口が、この 1 枚にも値を供給する")
    func suppliesFromInletsForThisFrameToo() throws {
        let facet = try makeFacet()
        let inlet = CountingInlet()
        InletSketch.declared = [InletPlugin(inlet: inlet)]
        defer { InletSketch.declared = [] }

        let runtime = try SketchRuntime(
            sketch: InletSketch(), gpu: try RenderDevice(), clock: nil, now: { 0 },
            observer: FrameObserver(directory: facet))
        runtime.pause()

        try request(id: "a1", in: facet)
        try runtime.advance()

        // 入り口は `draw()` の直前に供給する (ADR-0024 決定 6)。ここが 0 だと、
        // 最初の 1 枚だけ値の入っていない絵が返る
        #expect(inlet.supplied == 1)
    }
}
