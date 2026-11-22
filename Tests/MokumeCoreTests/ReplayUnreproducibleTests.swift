// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import CoreGraphics
import Foundation
import ImageIO
import MokumeTestSupport
import Testing
import UniformTypeIdentifiers
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
        // 並んで走る検査の見張りの印をこの面の頭が取っても、名乗りはその断片を読み込んだ実行へ行く。だから一致で見る
        #expect(recorded.unreproducible == [Reason.fragmentSwapped("paint.metal")], "\(recorded.unreproducible)")

        try write(0.2)
        let found = try await replay(Painted(fragment.path), try stripped(url), between: swap)
        #expect(found.unreproducible == [Reason.fragmentSwapped("paint.metal")], "\(found.unreproducible)")
    }

    /// 受け手を継がない所 (`Task.detached` に当たる) で断片を読み込み、`draw()` で使うスケッチ。
    final class PaintedAway: Sketch {
        var path = ""
        var paint: Shader?
        var settings: SketchSettings { SketchSettings(width: 16, height: 16, frameRate: 60) }
        init() {}
        convenience init(_ path: String) {
            self.init()
            self.path = path
        }
        func setup() throws {
            paint = try LaunchingSketch.$replay.withValue(nil) { try loadShader(path) }
        }
        func draw() {
            background(0.1)
            if let paint { shader(paint) }
            rect(0, 0, 8, 8)
        }
    }

    @Test("受け手の無い所で読み込んだ断片も、記録している実行の draw() で使えば、差し替えをその実行が名乗る")
    func aFragmentLoadedWithoutASinkIsNamedByTheRunThatUsesIt() async throws {
        let directory = try scratch()
        let fragment = directory.appendingPathComponent("paint.metal")
        func write(_ green: Float) throws {
            try """
                float4 paint(Fragment in, Values values) {
                    return float4(0.0, \(green), 0.0, 1.0);
                }
                """.write(to: fragment, atomically: true, encoding: .utf8)
        }
        let swap: (Int, SketchRuntime) async throws -> Void = { frame, runtime in
            guard frame == 2 else { return }
            try write(0.8)
            (runtime.sketch as? PaintedAway)?.paint?.watcher?.keepPending()
        }
        try write(0.2)
        let url = directory.appendingPathComponent("take.json")
        let recorded = try await record(PaintedAway(fragment.path), frames: 4, to: url, between: swap)
        #expect(recorded.unreproducible == [Reason.fragmentSwapped("paint.metal")], "\(recorded.unreproducible)")
    }

    @Test("断片の差し替えを別の実行のフレームの頭が扱っても、名乗りは断片を読み込んだ実行の記録に載り、扱った側には載らない")
    func aSwapTakenByAnotherRunIsNamedByItsOwner() throws {
        let directory = try scratch()
        let fragment = directory.appendingPathComponent("paint.metal")
        func write(_ green: Float) throws {
            try """
                float4 paint(Fragment in, Values values) {
                    return float4(0.0, \(green), 0.0, 1.0);
                }
                """.write(to: fragment, atomically: true, encoding: .utf8)
        }
        try write(0.2)
        func recording(_ sketch: any Sketch, to url: URL) throws -> SketchRuntime {
            let runtime = try SketchRuntime(
                sketch: sketch, gpu: RenderDevice(), clock: .frameIndex(frameRate: 60), persistsParams: false)
            try #require(runtime.startRecording(try #require(ReplayRequest(destination: url.path))))
            return runtime
        }
        let ownerURL = directory.appendingPathComponent("owner.json")
        let otherURL = directory.appendingPathComponent("other.json")
        let painted = Painted(fragment.path)
        let owner = try recording(painted, to: ownerURL)
        let other = try recording(Loader(nil), to: otherURL)
        try owner.advance()
        try other.advance()
        let paint = try #require(painted.paint)

        // 書き換えて印を立て、**持ち主より先に、別の実行のフレームを回す**。この間は main actor を譲らないので、
        // 見張りの `Task` は走らず、印を取るのは別の実行の面の頭である
        try write(0.8)
        paint.watcher?.keepPending()
        try other.advance()
        #expect(paint.generation == 1, "別の実行のフレームの頭が差し替えを扱った")
        try owner.advance()
        owner.closePlugins()
        other.closePlugins()

        let owned = try ReplayRecord.read(from: ownerURL)
        #expect(owned.unreproducible == [Reason.fragmentSwapped("paint.metal")], "\(owned.unreproducible)")
        let taken = try ReplayRecord.read(from: otherURL)
        #expect(taken.unreproducible.isEmpty, "扱った側の記録に載せない: \(taken.unreproducible)")
    }
}

// MARK: - 資源のハッシュ (#4092)

extension ReplayUnreproducibleTests {
    /// 資源の読み手。1 つずつ確かめる (音は `MokumeAudioTests` の `ReplayResourceSoundTests`)。
    enum ResourceKind: String, CaseIterable, Sendable {
        case image, requestImage, strings, shape, model, font, shader

        /// 書き出すファイルの名前。
        var fileName: String {
            switch self {
            case .image, .requestImage: "dot.png"
            case .strings: "words.txt"
            case .shape: "mark.svg"
            case .model: "pyramid.obj"
            case .font: "face.ttf"
            case .shader: "paint.metal"
            }
        }

        /// 版 `variant` (0 か 1) の中身を `url` に書く。0 と 1 は中身が違う。
        func write(_ variant: Int, to url: URL) throws {
            switch self {
            case .image, .requestImage:
                // 大きさも変える — 書き換えの前後で更新の印 (大きさ・時刻) が必ず変わる
                try writePNG(side: variant == 0 ? 1 : 2, gray: variant == 0 ? 0.2 : 0.8, to: url)
            case .strings:
                try (variant == 0 ? "alpha\nbeta\n" : "gamma\n").write(to: url, atomically: true, encoding: .utf8)
            case .shape:
                let side = variant == 0 ? 4 : 6
                try """
                    <svg xmlns="http://www.w3.org/2000/svg" width="8" height="8">\
                    <rect x="0" y="0" width="\(side)" height="\(side)"/></svg>
                    """.write(to: url, atomically: true, encoding: .utf8)
            case .model:
                let text = variant == 0 ? ModelFixture.pyramidText : ModelFixture.cubeText
                try text.write(to: url, atomically: true, encoding: .utf8)
            case .font:
                let source = variant == 0 ? "/System/Library/Fonts/Geneva.ttf" : "/System/Library/Fonts/Apple Braille.ttf"
                if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
                try FileManager.default.copyItem(atPath: source, toPath: url.path)
            case .shader:
                try """
                    float4 paint(Fragment in, Values values) {
                        return float4(0.0, \(variant == 0 ? "0.2" : "0.8"), 0.0, 1.0);
                    }
                    """.write(to: url, atomically: true, encoding: .utf8)
            }
        }

        private func writePNG(side: Int, gray: Double, to url: URL) throws {
            let space = CGColorSpace(name: CGColorSpace.sRGB)!
            let context = try #require(
                CGContext(
                    data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.setFillColor(CGColor(colorSpace: space, components: [gray, gray, gray, 1])!)
            context.fill(CGRect(x: 0, y: 0, width: side, height: side))
            let made = try #require(context.makeImage())
            let destination = try #require(
                CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil))
            CGImageDestinationAddImage(destination, made, nil)
            #expect(CGImageDestinationFinalize(destination))
        }
    }

    /// 資源を 1 つ読むスケッチ。`setup()` で 1 度読み (待つ読み込みは `Task` で)、描くかは `draws` で決める。
    /// `everyFrame` なら `draw()` で毎フレーム読む (控えは更新の印が変わったときだけ読み直す)。
    final class ResourceReader: Sketch {
        var kind = ResourceKind.image
        var path = ""
        var draws = false
        var everyFrame = false
        var loading: Task<Void, Never>?
        var picture: Image?
        var settings: SketchSettings { SketchSettings(width: 16, height: 16, frameRate: 60) }
        init() {}
        convenience init(_ kind: ResourceKind, path: String, draws: Bool = false, everyFrame: Bool = false) {
            self.init()
            self.kind = kind
            self.path = path
            self.draws = draws
            self.everyFrame = everyFrame
        }
        func setup() throws {
            if everyFrame { return }
            switch kind {
            case .image: picture = try loadImage(path)
            case .requestImage: loading = Task { [self] in picture = try? await requestImage(path) }
            case .strings: _ = try loadStrings(path)
            case .shape: _ = try loadShape(path)
            case .model: _ = try loadModel(path)
            case .font: _ = try loadFont(path)
            case .shader: _ = try loadShader(path)
            }
        }
        func draw() {
            background(0.1)
            if everyFrame { picture = try? loadImage(path) }
            if draws, let picture { image(picture, 0, 0, width, height) }
        }
    }

    /// `setup()` で起こした待つ読み込みを、最初の枚の後に待ち終える。
    private var awaitLoading: (Int, SketchRuntime) async throws -> Void {
        { frame, runtime in
            if frame == 1 { await (runtime.sketch as? ResourceReader)?.loading?.value }
        }
    }

    @Test(
        "記録の後に資源を書き換えて流すと、流す側が「資源のハッシュが違う」を名乗り、描かない資源なら matched は真のまま",
        arguments: ResourceKind.allCases)
    func aChangedResourceIsNamedWhenReplayed(kind: ResourceKind) async throws {
        let directory = try scratch()
        let file = directory.appendingPathComponent(kind.fileName)
        try kind.write(0, to: file)
        let url = directory.appendingPathComponent("take.json")
        let recorded = try await record(ResourceReader(kind, path: file.path), to: url, between: awaitLoading)
        let waiting = kind == .requestImage ? [Reason.waitingLoad] : []
        #expect(recorded.unreproducible == waiting, "\(kind): \(recorded.unreproducible)")
        #expect(recorded.resources.keys.sorted() == [file.path], "\(kind): \(recorded.resources)")

        // 対照: 書き換えなければ名乗らない
        let same = try await replay(ResourceReader(kind, path: file.path), url, between: awaitLoading)
        #expect(same.unreproducible == waiting && same.matched, "\(kind): \(same.unreproducible)")

        try kind.write(1, to: file)
        let differs = Reason.resourceDiffers(file.path)
        let changed = try await replay(ResourceReader(kind, path: file.path), url, between: awaitLoading)
        #expect(changed.unreproducible == waiting + [differs], "\(kind): \(changed.unreproducible)")
        #expect(ReplayPlayer.summary(of: changed).contains(differs), "端末の最後の 1 行にも載る")
        #expect(changed.matched, "資源の違いだけでは matched を偽にしない: \(String(describing: changed.firstMismatch))")
    }

    @Test("描いた画像を書き換えて流すと、資源のハッシュの違いを名乗り、matched は絵の照合で偽になる")
    func aChangedDrawnImageIsNamedAndThePictureDiffers() async throws {
        let directory = try scratch()
        let file = directory.appendingPathComponent("dot.png")
        try ResourceKind.image.write(0, to: file)
        let url = directory.appendingPathComponent("take.json")
        _ = try await record(ResourceReader(.image, path: file.path, draws: true), to: url)
        try ResourceKind.image.write(1, to: file)
        let changed = try await replay(ResourceReader(.image, path: file.path, draws: true), url)
        #expect(changed.unreproducible == [Reason.resourceDiffers(file.path)], "\(changed.unreproducible)")
        #expect(!changed.matched, "絵が違うので照合が食い違う")
    }

    @Test("記録の途中で同じ名前の画像の中身が変わると、記録が「資源が実行中に変わった」を名乗る")
    func aResourceChangedWhileRecordingIsNamed() async throws {
        let directory = try scratch()
        let file = directory.appendingPathComponent("dot.png")
        try ResourceKind.image.write(0, to: file)
        let url = directory.appendingPathComponent("take.json")
        let recorded = try await record(ResourceReader(.image, path: file.path, everyFrame: true), to: url) {
            frame, _ in
            if frame == 1 { try ResourceKind.image.write(1, to: file) }
        }
        #expect(recorded.unreproducible == [Reason.resourceChanged(file.path)], "\(recorded.unreproducible)")

        // 対照: 書き換えなければ、毎フレーム読んでも名乗らない
        try ResourceKind.image.write(0, to: file)
        let quiet = try await record(
            ResourceReader(.image, path: file.path, everyFrame: true),
            to: directory.appendingPathComponent("quiet.json"))
        #expect(quiet.unreproducible.isEmpty, "\(quiet.unreproducible)")
    }

    @Test("resources を持たない記録も読めて流せ、資源を書き換えていても名乗らない (欄を足す前の記録)")
    func aRecordWithoutResourcesStillReplays() async throws {
        let directory = try scratch()
        let file = directory.appendingPathComponent("words.txt")
        try ResourceKind.strings.write(0, to: file)
        let url = directory.appendingPathComponent("take.json")
        _ = try await record(ResourceReader(.strings, path: file.path), to: url)
        var document = try #require(
            try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        #expect(document["resources"] != nil)
        document["resources"] = nil
        let old = directory.appendingPathComponent("old.json")
        try JSONSerialization.data(withJSONObject: document).write(to: old)
        #expect(try ReplayRecord.read(from: old).resources.isEmpty)

        try ResourceKind.strings.write(1, to: file)
        let replayed = try await replay(ResourceReader(.strings, path: file.path), old)
        #expect(replayed.unreproducible.isEmpty && replayed.matched, "\(replayed.unreproducible)")
    }
}

/// 資源の中身の SHA-256 (``ResourceDigest``)。GPU も実行も要らない。
@Suite("資源の中身のハッシュ")
struct ResourceDigestTests {
    @Test("既知の値に一致し、塊を跨ぐ大きなファイルも中身全体のハッシュになる。読めないファイルは nil")
    func digestsWholeFiles() throws {
        #expect(
            ResourceDigest.sha256(of: Data("abc".utf8))
                == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        // 塊 (1 MiB) の 3 つ分と端数
        let data = Data((0..<((3 << 20) + 17)).map { UInt8(truncatingIfNeeded: $0 &* 31) })
        let url = TestScratch.path("mokume-resource-digest", pathExtension: "bin")
        try data.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(ResourceDigest.sha256(of: url) == ResourceDigest.sha256(of: data))
        let empty = TestScratch.path("mokume-resource-digest", pathExtension: "bin")
        try Data().write(to: empty)
        defer { try? FileManager.default.removeItem(at: empty) }
        #expect(ResourceDigest.sha256(of: empty) == ResourceDigest.sha256(of: Data()))
        #expect(ResourceDigest.sha256(of: url.appendingPathExtension("missing")) == nil)
    }
}
