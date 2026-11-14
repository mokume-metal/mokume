// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation
import MokumeTestSupport
import Testing
import mokume

@testable import MokumeCore

/// 記録できないものが使われたら、記録と再生の両方で理由つきで名乗る (#3575)。
///
/// 再生の側が自分で見つけることは、記録の `unreproducible` を消した写しを流して確かめる (記録の理由を読み上げるだけでは
/// 通らない)。記録も再生も同じプロセスで ``SketchRuntime`` を直に回す。GPU を要する。
@Suite(
    "記録できないものを、記録と再生の両方で名乗る",
    .serialized,
    .enabled(
        if: RenderDevice.isAvailable,
        "この世代のコマンド構造に対応した GPU が無い実行環境ではスキップする")
)
@MainActor
struct ReplayUnreproducibleTests {
    typealias Reason = ReplayRecorder.Reason

    private func scratch() throws -> URL { try TestScratch.directory("mokume-replay-unreproducible") }

    /// 記録する。`between` は `advance()` のたびに、その後で呼ぶ (待つ読み込みの `Task` を待つ・断片を書き換える)。
    private func record(
        _ sketch: any Sketch, frames: Int = 3, to url: URL,
        between: (Int, SketchRuntime) async throws -> Void = { _, _ in }
    ) async throws -> ReplayRecord {
        let runtime = try SketchRuntime(
            sketch: sketch, gpu: RenderDevice(), clock: .frameIndex(frameRate: 60), persistsParams: false)
        try #require(runtime.startRecording(try #require(ReplayRequest(destination: url.path))))
        for frame in 1...frames {
            try runtime.advance()
            try await between(frame, runtime)
        }
        runtime.closePlugins()
        return try ReplayRecord.read(from: url)
    }

    /// 流す。`SketchApplication` が流す子を組むのと同じ引数で組み、記録の終わりまで回す (期限は回数で持つ)。
    private func replay(
        _ sketch: any Sketch, _ url: URL,
        between: (Int, SketchRuntime) async throws -> Void = { _, _ in }
    ) async throws -> ReplayPlayer.Report {
        let record = try ReplayRecord.read(from: url)
        let player = ReplayPlayer(record: record, source: url.path, reportURL: nil)
        let runtime = try SketchRuntime(
            sketch: sketch, gpu: RenderDevice(), clock: .frameIndex(frameRate: record.frameRate), now: { 0 },
            onScreen: false, persistsParams: false, opensFacets: false, handover: player.clockStart)
        runtime.startReplaying(player)
        var advances = 0
        while !player.isFinished, advances < record.steps.count * 2 + 10 {
            player.beginAdvance(at: Double(advances))
            try runtime.advance()
            advances += 1
            try await between(advances, runtime)
        }
        try #require(player.isFinished, "記録の終わりまで流せなかった")
        let report = try #require(runtime.finishReplaying())
        runtime.closePlugins()
        return report
    }

    /// 記録の `unreproducible` を消した写し。**流す側が自分で見つけたものだけが、結果に載る。**
    private func stripped(_ url: URL) throws -> URL {
        var document = try #require(
            try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        document["unreproducible"] = nil
        let copy = url.deletingPathExtension().appendingPathExtension("stripped.json")
        try JSONSerialization.data(withJSONObject: document).write(to: copy)
        return copy
    }

    // MARK: - 待つ読み込み

    /// 待つ読み込みの口。14 本が通る 6 か所を 1 つずつ踏む (スケッチの `requestImage` と面の `requestImage` は同じ本体)。
    enum WaitingLoad: String, CaseIterable, Sendable {
        case strings, bytes, image, canvasImage, model, shape
    }

    final class Loader: Sketch {
        var kind: WaitingLoad?
        var loading: Task<Void, Never>?
        var settings: SketchSettings { SketchSettings(width: 16, height: 16, frameRate: 60) }
        init() {}
        convenience init(_ kind: WaitingLoad?) {
            self.init()
            self.kind = kind
        }
        func setup() {
            guard let kind else { return }
            let surface = canvas
            // 在らない名前でよい。名乗るのは、口を使ったことである
            loading = Task { [self] in
                switch kind {
                case .strings: _ = try? await requestStrings("missing.txt")
                case .bytes: _ = try? await requestBytes("missing.bin")
                case .image: _ = try? await requestImage("missing.png")
                case .canvasImage: _ = try? await surface.requestImage("missing.png")
                case .model: _ = try? await requestModel("missing.obj")
                case .shape: _ = try? await requestShape("missing.svg")
                }
            }
        }
        func draw() { background(0.1) }
    }

    @Test("待つ読み込みを使うと、記録と再生の両方が「待つ読み込み」を名乗る", arguments: WaitingLoad.allCases)
    func waitingLoadsAreNamed(kind: WaitingLoad) async throws {
        let url = try scratch().appendingPathComponent("take.json")
        // 最初の枚の後に、`setup()` で起こした読み込みを待ち終える
        let wait: (Int, SketchRuntime) async throws -> Void = { frame, runtime in
            if frame == 1 { await (runtime.sketch as? Loader)?.loading?.value }
        }
        let recorded = try await record(Loader(kind), to: url, between: wait)
        #expect(recorded.unreproducible == [Reason.waitingLoad], "\(recorded.unreproducible)")

        let replayed = try await replay(Loader(kind), url, between: wait)
        #expect(replayed.unreproducible == [Reason.waitingLoad], "記録の理由と流して見つけた理由を重ねない")
        #expect(ReplayPlayer.summary(of: replayed).contains(Reason.waitingLoad), "端末の 1 行にも載る")

        let found = try await replay(Loader(kind), try stripped(url), between: wait)
        #expect(found.unreproducible == [Reason.waitingLoad], "流す側が自分で見つける: \(found.unreproducible)")
    }

    @Test("待つ読み込みを使わない作品は、記録も再生も何も名乗らない")
    func noWaitingLoadNamesNothing() async throws {
        let url = try scratch().appendingPathComponent("take.json")
        let recorded = try await record(Loader(nil), to: url)
        #expect(recorded.unreproducible.isEmpty)
        let replayed = try await replay(Loader(nil), url)
        #expect(replayed.unreproducible.isEmpty && replayed.matched)
        #expect(ReplayPlayer.summary(of: replayed).hasSuffix("every check matched the record"))
    }

    // MARK: - カメラ (完了条件 1・案 A)

    /// 記録した列をカメラの代わりに流す。`url` があれば、列の 1 枚を URL から受け取った本文で作る。
    final class Rehearsal: Sketch {
        var url: String?
        var camera: Capture?
        var settings: SketchSettings { SketchSettings(width: 16, height: 16, frameRate: 60) }
        init() {}
        convenience init(url: String?) {
            self.init()
            self.url = url
        }
        func setup() throws {
            let frames: [DisplayImage]
            if let url {
                frames = [DisplayImage(width: 2, height: 2, bytes: try loadBytes(url))]
            } else {
                let red = DisplayImage(width: 2, height: 2, bytes: Array([[UInt8]](repeating: [255, 0, 0, 255], count: 4).joined()))
                let blue = DisplayImage(width: 2, height: 2, bytes: Array([[UInt8]](repeating: [0, 0, 255, 255], count: 4).joined()))
                frames = [red, blue]
            }
            camera = try createCapture(frames: frames)
        }
        func draw() {
            background(0.1)
            if let camera { image(camera.image, 0, 0, width, height) }
        }
    }

    @Test("スケッチの中で作った赤・青の列を createCapture(frames:) に渡しただけなら、記録も再生もカメラを名乗らず一致する")
    func fixedFramesAreNotACamera() async throws {
        let url = try scratch().appendingPathComponent("take.json")
        let recorded = try await record(Rehearsal(url: nil), frames: 4, to: url)
        #expect(recorded.unreproducible.isEmpty, "\(recorded.unreproducible)")
        let replayed = try await replay(Rehearsal(url: nil), url)
        #expect(replayed.unreproducible.isEmpty, "\(replayed.unreproducible)")
        #expect(replayed.matched, "列は同じフレームに同じ絵を出す: \(String(describing: replayed.firstMismatch))")
    }

    @Test("URL から受け取った画像を createCapture(frames:) に渡すと、記録も再生も URL だけを名乗り、カメラは加わらない")
    func framesFromAURLNameOnlyTheURL() async throws {
        let body = Data(Array([[UInt8]](repeating: [0, 255, 0, 255], count: 4).joined()))
        let web = CannedResponses.serve(.answer(status: 200, body: body))
        let url = try scratch().appendingPathComponent("take.json")
        let recorded = try await record(Rehearsal(url: web), to: url)
        #expect(recorded.unreproducible == [Reason.webFile], "\(recorded.unreproducible)")
        let replayed = try await replay(Rehearsal(url: web), url)
        #expect(replayed.unreproducible == [Reason.webFile], "\(replayed.unreproducible)")
        let found = try await replay(Rehearsal(url: web), try stripped(url))
        #expect(found.unreproducible == [Reason.webFile], "\(found.unreproducible)")
    }

    // MARK: - URL (面を直に呼ぶ)

    final class SurfaceFetcher: Sketch {
        var url = ""
        var settings: SketchSettings { SketchSettings(width: 16, height: 16, frameRate: 60) }
        init() {}
        convenience init(_ url: String) {
            self.init()
            self.url = url
        }
        func setup() { _ = try? canvas.loadImage(url) }
        func draw() { background(0.1) }
    }

    @Test("面の loadImage(_:) を直に呼んで URL から読んでも、記録と再生の両方が URL を名乗る")
    func aWebImageThroughTheSurfaceIsNamed() async throws {
        let web = CannedResponses.serve("not an image")
        let url = try scratch().appendingPathComponent("take.json")
        let recorded = try await record(SurfaceFetcher(web), to: url)
        #expect(recorded.unreproducible == [Reason.webFile], "\(recorded.unreproducible)")
        let found = try await replay(SurfaceFetcher(web), try stripped(url))
        #expect(found.unreproducible == [Reason.webFile], "\(found.unreproducible)")
    }

    // MARK: - パスだけのファイル

    @Test("ドロップしたファイルは、記録が名乗り、流す側も入力を当てるときに自分で名乗る")
    func aDroppedFileIsNamedWhenReplayed() async throws {
        let url = try scratch().appendingPathComponent("take.json")
        let recorded = try await record(Loader(nil), to: url) { frame, runtime in
            if frame == 1 { runtime.input.enqueue(.fileDropped(paths: ["/tmp/a.png"], x: 1, y: 1)) }
        }
        #expect(recorded.unreproducible == [Reason.fileByPath], "\(recorded.unreproducible)")
        let found = try await replay(Loader(nil), try stripped(url))
        #expect(found.unreproducible == [Reason.fileByPath], "\(found.unreproducible)")
    }

    // MARK: - .metal の断片の差し替え

    final class Painted: Sketch {
        var path = ""
        var paint: Shader?
        var settings: SketchSettings { SketchSettings(width: 16, height: 16, frameRate: 60) }
        init() {}
        convenience init(_ path: String) {
            self.init()
            self.path = path
        }
        func setup() throws { paint = try loadShader(path) }
        func draw() {
            background(0.1)
            if let paint { shader(paint) }
            rect(0, 0, 8, 8)
        }
    }

    @Test("走らせたまま .metal の断片が差し替わると、記録と再生の両方がその断片を名乗る")
    func aSwappedFragmentIsNamed() async throws {
        let directory = try scratch()
        let fragment = directory.appendingPathComponent("paint.metal")
        func write(_ green: Float) throws {
            try """
                float4 paint(Fragment in, Values values) {
                    return float4(0.0, \(green), 0.0, 1.0);
                }
                """.write(to: fragment, atomically: true, encoding: .utf8)
        }
        // 2 枚目の後に書き換え、**同じ流れのまま** 印を立てる。次の枚の面の頭 (`withActiveRuntime` の外) で差し替わる
        let swap: (Int, SketchRuntime) async throws -> Void = { frame, runtime in
            guard frame == 2 else { return }
            try write(0.8)
            (runtime.sketch as? Painted)?.paint?.watcher?.keepPending()
        }
        try write(0.2)
        let url = directory.appendingPathComponent("take.json")
        let recorded = try await record(Painted(fragment.path), frames: 4, to: url, between: swap)
        // 並んで走る検査の見張りの印も、この面の頭が取りうる (`FileWatcher.takeChanges()`)。だから含むかで見る
        #expect(recorded.unreproducible.contains(Reason.fragmentSwapped("paint.metal")), "\(recorded.unreproducible)")

        try write(0.2)
        let found = try await replay(Painted(fragment.path), try stripped(url), between: swap)
        #expect(found.unreproducible.contains(Reason.fragmentSwapped("paint.metal")), "\(found.unreproducible)")
    }
}
