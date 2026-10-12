// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

// 性能レビュー (親 #1744) 群 G4Media の計測の下書き。**コンパイルされない置き場にある。**
//
// 置き場の想定: Tests/MokumeCoreTests/PerfReviewG4Media.swift
// 末尾の「動画・カメラ」の節 (ADR-0042 決定 5・#1960) と、それを使う 2 つの @Test は
// `@testable import MokumeCamera` を要る。MokumeCoreTests は `mokume` 経由で MokumeCamera に
// 届くので import できる見込みだが、通らなければ G4Video と externalPixels / movieReaderStalls
// だけを Tests/MokumeCameraTests/PerfReviewG4Camera.swift へ切り出す (CanvasFixture は写す)。
//
// 出力は 1 行 1 値: PERF<TAB>Issue<TAB>場面<TAB>指標<TAB>値<TAB>単位 (grep '^PERF' で集める)。
// 数字は release で採る (`make test-release`)。debug の数字を根拠にしない。

import AVFoundation
import CoreVideo
import Foundation
import Metal
import Synchronization
import Testing
import VideoToolbox

@testable import MokumeCamera
@testable import MokumeCore

// MARK: - 共通の道具

/// 時間を測って 1 行ずつ出す。名前を他の検査と取り合わないよう、この群の中に閉じる。
nonisolated private enum G4 {
    /// 測る大きさ。1080p と 4K。
    static let sizes: [(width: Int, height: Int)] = [(1920, 1080), (3840, 2160)]

    static func ms(_ duration: Duration) -> Double {
        let parts = duration.components
        return Double(parts.seconds) * 1e3 + Double(parts.attoseconds) / 1e15
    }

    /// 暖機 `warmup` 回の後に `runs` 回測り、ミリ秒で返す。
    static func sample(
        warmup: Int = 3, runs: Int = 20, _ body: () throws -> Void
    ) rethrows -> [Double] {
        let clock = ContinuousClock()
        for _ in 0..<warmup { try body() }
        var values: [Double] = []
        values.reserveCapacity(runs)
        for _ in 0..<runs { values.append(ms(try clock.measure { try body() })) }
        return values
    }

    /// 中央値・p90・最小・最大・回数を出す。
    static func report(_ id: String, _ scene: String, _ metric: String, _ values: [Double], unit: String = "ms") {
        let sorted = values.sorted()
        guard !sorted.isEmpty else { return }
        let p90Index = min(sorted.count - 1, Int((Double(sorted.count) * 0.9).rounded(.up)) - 1)
        line(id, scene, "\(metric).median", sorted[sorted.count / 2], unit)
        line(id, scene, "\(metric).p90", sorted[max(0, p90Index)], unit)
        line(id, scene, "\(metric).min", sorted[0], unit)
        line(id, scene, "\(metric).max", sorted[sorted.count - 1], unit)
        line(id, scene, "\(metric).n", Double(sorted.count), "count")
    }

    static func line(_ id: String, _ scene: String, _ metric: String, _ value: Double, _ unit: String) {
        print("PERF\t\(id)\t\(scene)\t\(metric)\t\(String(format: "%.4f", value))\t\(unit)")
    }

    /// 符号化に手応えのある絵 (行と列と擬似乱数が混ざる)。同じ `seed` からはいつも同じ絵。
    static func picture(width: Int, height: Int, seed: UInt32 = 1) -> DisplayImage {
        let count = width * height * 4
        let bytes = [UInt8](unsafeUninitializedCapacity: count) { buffer, initialized in
            var state = seed &* 747_796_405 &+ 2_891_336_453
            for y in 0..<height {
                for x in 0..<width {
                    state = state &* 1_664_525 &+ 1_013_904_223
                    let index = (y * width + x) * 4
                    buffer[index] = UInt8(truncatingIfNeeded: x &+ Int(state >> 28))
                    buffer[index + 1] = UInt8(truncatingIfNeeded: y &+ Int(state >> 29))
                    buffer[index + 2] = UInt8(truncatingIfNeeded: x ^ y ^ Int(seed))
                    buffer[index + 3] = 255
                }
            }
            initialized = count
        }
        return DisplayImage(width: width, height: height, bytes: bytes)
    }

    static func temporaryDirectory(_ name: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("mokume-perf-g4-\(name)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}

/// 消されないように結果を受ける先。
nonisolated(unsafe) private var g4Sink = 0

/// 全コアを回す負荷。**期限で必ず止まる** (止め忘れても `limit` 秒で抜ける)。
nonisolated private final class G4Spinners: Sendable {
    private let stop = Mutex(false)

    func start(count: Int, qos: QualityOfService, limit: Double) {
        for _ in 0..<count {
            let thread = Thread { [self] in
                let end = Date().addingTimeInterval(limit)
                var spin: UInt64 = 0
                while !stop.withLock({ $0 }), Date() < end {
                    for _ in 0..<20_000 { spin = spin &* 6_364_136_223_846_793_005 &+ 1 }
                }
                if spin == 42 { print("") }
            }
            thread.qualityOfService = qos
            thread.start()
        }
    }

    func finish() { stop.withLock { $0 = true } }
}

// MARK: - CPU だけの計測 (GPU を要さない)

@Suite("PerfReview G4Media CPU", .serialized)
struct PerfReviewG4MediaCPU {

    // MARK: #2372 読み戻しの確保の形

    /// `EncodedImage.read()` と同じ形 (0 埋めの確保 + 行ごとの写し) と、0 埋めをしない 1 回の写しを
    /// 同じ大きさで並べる。**直した後の費用ではなく、いまの形の内訳を見るため**の参照である。
    /// 元は幅ちょうどの行 (実物の行の間隔は GPU の節の `bytesPerRow` で確かめる)。
    @Test("2372 読み戻しの内訳: 0 埋めの確保・行ごとの写し・1 回の写し")
    func readbackShapes() {
        for (width, height) in G4.sizes {
            let scene = "\(width)x\(height)"
            let length = width * height * 4
            let rowBytes = width * 4
            let source = UnsafeMutableRawPointer.allocate(byteCount: length, alignment: 256)
            defer { source.deallocate() }
            memset(source, 0x5a, length)

            G4.report("2372", scene, "zeroFilledAllocationOnly", G4.sample {
                let bytes = [UInt8](repeating: 0, count: length)
                g4Sink &+= Int(bytes[length / 2])
            })
            // いまの read() と同じ: 0 埋めしてから行ごとに写す
            G4.report("2372", scene, "zeroFillThenRowCopy", G4.sample {
                var bytes = [UInt8](repeating: 0, count: length)
                bytes.withUnsafeMutableBytes { destination in
                    for row in 0..<height {
                        destination.baseAddress!.advanced(by: row * rowBytes)
                            .copyMemory(from: source.advanced(by: row * rowBytes), byteCount: rowBytes)
                    }
                }
                g4Sink &+= Int(bytes[length / 2])
            })
            // 0 埋めせずに 1 回で写す (完了条件 2 の形の目安)
            G4.report("2372", scene, "uninitializedSingleCopy", G4.sample {
                let bytes = [UInt8](unsafeUninitializedCapacity: length) { buffer, initialized in
                    buffer.baseAddress!.update(from: source.assumingMemoryBound(to: UInt8.self), count: length)
                    initialized = length
                }
                g4Sink &+= Int(bytes[length / 2])
            })
        }
    }

    // MARK: #2372 / #2381 PNG の書き出しの内訳 (連番・save()・観測が共有する)

    @Test("2372/2381 PNG の内訳: Data へのもう 1 回の写しと、PNGFile.write の全体")
    func pngShapes() throws {
        let directory = try G4.temporaryDirectory("png")
        defer { try? FileManager.default.removeItem(at: directory) }
        for (width, height) in G4.sizes {
            let scene = "\(width)x\(height)"
            let image = G4.picture(width: width, height: height)
            G4.report("2372", scene, "Data(image.bytes)", G4.sample { g4Sink &+= Data(image.bytes).count })
            let url = directory.appendingPathComponent("g4-\(width).png")
            G4.report("2372", scene, "PNGFile.write", try G4.sample(warmup: 1, runs: 6) {
                try PNGFile.write(image, to: url)
            })
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            G4.line("2372", scene, "pngBytes", Double((attributes[.size] as? Int) ?? 0), "bytes")
        }
    }

    // MARK: #2372 動画の背圧で main が待つ長さ

    /// `MovieWriter.write` を main から続けて呼び、**1 回の呼び出しで main が返らなかった時間**を数える。
    /// 書く側が追いつかなければ `take()` の semaphore で待つので、ここが「main が utility の仕事を
    /// 待つ」の実物である。
    @Test(
        "2372 動画の書き出し: write() 1 回あたりに main が塞がる時間と、待った回数",
        .enabled(if: MovieFile.isAvailable, "ProRes 4444 の符号化器が無い"))
    func movieWriterBlocksMain() throws {
        let directory = try G4.temporaryDirectory("movie")
        defer { try? FileManager.default.removeItem(at: directory) }
        let clock = ContinuousClock()
        for (width, height) in G4.sizes {
            let scene = "\(width)x\(height)"
            let frames = width > 2000 ? 24 : 48
            // 2 枚を交互に渡す (同じ絵の続きで符号化器が手を抜けないように)
            let pictures = [G4.picture(width: width, height: height, seed: 1),
                            G4.picture(width: width, height: height, seed: 2)]
            let writer = MovieWriter(
                path: directory.appendingPathComponent("g4-\(width).mov").path, frameRate: 60)
            var perWrite: [Double] = []
            var blocked = 0
            let began = clock.now
            for index in 0..<frames {
                let spent = G4.ms(clock.measure {
                    writer.write(pictures[index % 2], frame: index + 1, time: Double(index) / 60)
                })
                perWrite.append(spent)
                if spent > 0.5 { blocked += 1 }
            }
            let writing = G4.ms(clock.now - began)
            let finishing = G4.ms(clock.measure { writer.finish() })
            #expect(writer.takeFailure() == nil)
            G4.report("2372", scene, "MovieWriter.write.mainBlocked", perWrite)
            G4.line("2372", scene, "MovieWriter.write.blockedOver0.5ms", Double(blocked), "count")
            G4.line("2372", scene, "MovieWriter.peakOutstanding", Double(writer.peakOutstanding), "frames")
            G4.line("2372", scene, "MovieWriter.finish", finishing, "ms")
            G4.line("2372", scene, "MovieWriter.throughput", Double(frames) / ((writing + finishing) / 1000), "fps")
        }
    }

    /// 同じ形を FrameWriter (PNG の連番) で。行き先が枚ごとに違うので、PNG は上限 (4) まで並んで走る。
    @Test("2372 連番 (PNG) の書き出し: write() 1 回あたりに main が塞がる時間")
    func frameWriterBlocksMain() throws {
        let directory = try G4.temporaryDirectory("sequence")
        defer { try? FileManager.default.removeItem(at: directory) }
        let clock = ContinuousClock()
        for (width, height) in G4.sizes {
            let scene = "\(width)x\(height)"
            let frames = width > 2000 ? 16 : 32
            let pictures = [G4.picture(width: width, height: height, seed: 1),
                            G4.picture(width: width, height: height, seed: 2)]
            let writer = FrameWriter()
            var perWrite: [Double] = []
            let began = clock.now
            for index in 0..<frames {
                let path = directory.appendingPathComponent(String(format: "w\(width)-%04d.png", index)).path
                perWrite.append(G4.ms(clock.measure { writer.write(pictures[index % 2], to: path) }))
            }
            let drained = G4.ms(clock.measure { writer.drain() })
            let total = G4.ms(clock.now - began)
            G4.report("2372", scene, "FrameWriter.write.mainBlocked", perWrite)
            G4.line("2372", scene, "FrameWriter.drain", drained, "ms")
            G4.line("2372", scene, "FrameWriter.peakOutstanding", Double(writer.peakOutstanding), "frames")
            G4.line("2372", scene, "FrameWriter.throughput", Double(frames) / (total / 1000), "fps")
        }
    }

    /// **優先度で符号化の速さが変わるか**を直接見る。`MovieFile` を `.utility` と `.userInitiated` の
    /// 仕事から叩き、全コアを userInitiated で回す負荷の有無で並べる。変わらなければ、#2372 の
    /// 1 つ目 (優先度の逆転) は実害として示せない。
    @Test(
        "2372 優先度と符号化の速さ: utility / userInitiated × 負荷なし / 全コア負荷",
        .enabled(if: MovieFile.isAvailable, "ProRes 4444 の符号化器が無い"))
    func encodePriority() async throws {
        let directory = try G4.temporaryDirectory("priority")
        defer { try? FileManager.default.removeItem(at: directory) }
        let width = 1920, height = 1080, frames = 30
        let pictures = [G4.picture(width: width, height: height, seed: 1),
                        G4.picture(width: width, height: height, seed: 2)]
        let cores = ProcessInfo.processInfo.activeProcessorCount
        for loaded in [false, true] {
            for (name, priority) in [("utility", TaskPriority.utility), ("userInitiated", TaskPriority.userInitiated)] {
                let spinners = G4Spinners()
                if loaded { spinners.start(count: cores, qos: .userInitiated, limit: 20) }
                let path = directory.appendingPathComponent("p-\(name)-\(loaded).mov").path
                let elapsed = try await Task.detached(priority: priority) { () async throws -> Double in
                    let file = try MovieFile(path: path, width: width, height: height, frameRate: 60)
                    let clock = ContinuousClock()
                    let start = clock.now
                    for index in 0..<frames {
                        try await file.append(pictures[index % 2], at: Double(index) / 60)
                    }
                    try await file.finish(lastFrameAt: Double(frames - 1) / 60)
                    return G4.ms(clock.now - start)
                }.value
                spinners.finish()
                let scene = "1920x1080.\(name).\(loaded ? "allCoresBusy" : "idle")"
                G4.line("2372", scene, "MovieFile.throughput", Double(frames) / (elapsed / 1000), "fps")
                G4.line("2372", scene, "MovieFile.total", elapsed, "ms")
            }
        }
    }
}

// MARK: - GPU を使う計測

@Suite("PerfReview G4Media", .serialized, .enabled(if: RenderDevice.isAvailable, "GPU が無い"))
struct PerfReviewG4Media {

    // MARK: #2372 実物の読み戻し

    /// GPU の決着を済ませてから `read()` だけを測る。**CPU の確保と写しだけ**の値になる。
    @Test("2372 EncodedImage.read() の 1 回 (GPU の決着後)")
    func encodedImageRead() throws {
        let gpu = try RenderDevice()
        for (width, height) in G4.sizes {
            let scene = "\(width)x\(height)"
            let canvas = try CanvasFixture.make(gpu: gpu, width: width, height: height)
            try canvas.draw { canvas.background(64) }
            let encoded = try canvas.output.encodeToImage()
            try gpu.waitForSubmission(encoded.pendingSubmission)
            G4.line("2372", scene, "bytesPerRow", Double(encoded.bytesPerRow), "bytes")
            G4.line("2372", scene, "widthInBytes", Double(width * 4), "bytes")
            G4.report("2372", scene, "EncodedImage.read", G4.sample { g4Sink &+= encoded.read().bytes.count })
        }
    }

    // MARK: #2372 走っているスケッチで録る (完了条件 4 の「前」)

    /// 作品を録りながら回す。`advance()` 1 回の壁時計を、録らないときと並べる。
    @Test(
        "2372 走りの中の録画: advance() あたりの main の時間 (録らない / .mov / 連番 PNG)",
        .enabled(if: MovieFile.isAvailable, "ProRes 4444 の符号化器が無い"))
    func recordingInTheLoop() throws {
        let directory = try G4.temporaryDirectory("record")
        defer { try? FileManager.default.removeItem(at: directory) }
        for (width, height) in G4.sizes {
            G4BusySketch.size = (width, height)
            for target in ["none", "movie", "sequence"] {
                let scene = "\(width)x\(height).\(target)"
                let runtime = try SketchRuntime(sketch: G4BusySketch(), gpu: try RenderDevice())
                for _ in 0..<3 { try runtime.advance() }
                switch target {
                case "movie": runtime.beginRecord(directory.appendingPathComponent("r-\(width).mov").path)
                case "sequence": runtime.beginRecord(directory.appendingPathComponent("s-\(width)-####.png").path)
                default: break
                }
                let frames = width > 2000 ? 20 : 30
                let perFrame = try G4.sample(warmup: 0, runs: frames) { try runtime.advance() }
                G4.report("2372", scene, "advance", perFrame)
                if target != "none" {
                    G4.line("2372", scene, "endRecord", G4.ms(ContinuousClock().measure { runtime.endRecord() }), "ms")
                }
                runtime.closePlugins()
            }
        }
    }

    // MARK: #2375 粒

    /// 粒を満たす。寿命は長く、大きさは小さく (塗りの費用を消す)。
    private func filled(_ canvas: Canvas, capacity: Int, alive: Bool) throws -> Particles {
        let dust = try canvas.makeParticles(count: capacity)
        guard alive else { return dust }
        var randomness = Randomness(seed: 2375)
        // 毎秒 容量×30 個 = 1 フレーム (既定の 1/60 秒) に容量の半分。2 フレームで満ちる
        for _ in 0..<2 {
            try canvas.draw {
                canvas.background(0)
                canvas.emit(
                    dust, from: .point(320, 180), toward: .plane(0...(2 * Float.pi)),
                    rate: Float(capacity) * 30, speed: 1...5, life: 1000...1000, size: 0.05...0.05,
                    color: .linear(red: 1, green: 0.6, blue: 0.2), using: &randomness)
                canvas.particles(dust)
            }
        }
        try canvas.gpu.settle()
        return dust
    }

    /// 粒の段を、1 フレームの中で他と混ぜずに測る。
    ///
    /// - 全体: `particles()` を呼ぶフレームと呼ばないフレームの差 (draw → settle の壁時計)
    /// - 段ごと: 旗・scan の全段・scan の初段・update を、それぞれ単独の描き切りに載せて測る
    /// - 投入の下限: scan の最上段 (1 スレッド) だけを載せた描き切り
    ///
    /// GPU の時間の口が無いので、すべて「投入して決着するまで」の壁時計である。
    @Test("2375 粒の段の費用: 10 万 / 100 万粒、全部生きている / 全部死んでいる", arguments: [100_000, 1_000_000])
    func particleStages(capacity: Int) throws {
        let gpu = try RenderDevice()
        for alive in [true, false] {
            let scene = "\(capacity).\(alive ? "alive" : "dead")"
            let canvas = try CanvasFixture.make(gpu: gpu, width: 640, height: 360)
            let dust = try filled(canvas, capacity: capacity, alive: alive)
            G4.line("2375", scene, "scanLevels", Double(dust.scanCount), "count")
            G4.line("2375", scene, "dispatchesPerCall", Double(dust.dispatchCount), "count")
            G4.line("2375", scene, "stateBytes", Double(dust.state.count * 4), "bytes")
            G4.line("2375", scene, "instanceBytes", Double(dust.instances.count * 4), "bytes")

            let withParticles = try G4.sample(runs: 15) {
                try canvas.draw { canvas.background(0); canvas.particles(dust) }
                try gpu.settle()
            }
            G4.line("2375", scene, "drawCallsInLastFrame", Double(canvas.drawCallsInLastFrame), "count")
            let withoutParticles = try G4.sample(runs: 15) {
                try canvas.draw { canvas.background(0) }
                try gpu.settle()
            }
            G4.report("2375", scene, "frameWithParticles", withParticles)
            G4.report("2375", scene, "frameWithoutParticles", withoutParticles)

            // 段ごと。指定 (parameters) は上の本物のフレームが書いたものが残っている
            func stage(_ body: @escaping () -> Void) throws -> [Double] {
                try G4.sample(runs: 15) {
                    try canvas.draw(body)
                    try gpu.settle()
                }
            }
            let top = dust.scanCount - 1
            G4.report("2375", scene, "submitFloor(scanTopLevel)", try stage {
                guard top >= 0 else { return }
                canvas.compute(
                    dust.scan, over: dust.levelLengths[top + 1], reads: [dust.levelHeaders[top]],
                    writes: [dust.levels])
            })
            G4.report("2375", scene, "stageFlag", try stage {
                canvas.compute(
                    dust.flag, over: dust.capacity, reads: [dust.parameters, dust.state],
                    writes: [dust.levels])
            })
            G4.report("2375", scene, "stageScanAllLevels", try stage {
                for level in 0..<dust.scanCount {
                    canvas.compute(
                        dust.scan, over: dust.levelLengths[level + 1], reads: [dust.levelHeaders[level]],
                        writes: [dust.levels])
                }
            })
            G4.report("2375", scene, "stageScanLevel0", try stage {
                canvas.compute(
                    dust.scan, over: dust.levelLengths[1], reads: [dust.levelHeaders[0]],
                    writes: [dust.levels])
            })
            G4.report("2375", scene, "stageUpdate", try stage {
                canvas.compute(
                    dust.update, over: dust.capacity, reads: [dust.parameters, dust.levels],
                    writes: [dust.state, dust.instances, dust.arguments])
            })
        }
    }

    // MARK: #2381 観測の撮影

    /// 作品を回しながら観測で 10 枚を毎フレーム撮り、撮る間の `advance()` を撮らないフレームと
    /// 並べる。撮った枚の内訳 (GPU を待って読む・PNG・統計・AtomicFile) も別に測る。
    @Test("2381 観測の撮影: 撮る枚の advance() と、その内訳", arguments: [1.0, 0.5])
    func observationCapture(scale: Double) throws {
        for (width, height) in G4.sizes {
            let scene = "\(width)x\(height).scale\(scale)"
            G4BusySketch.size = (width, height)
            let facet = try G4.temporaryDirectory("observe")
            defer { try? FileManager.default.removeItem(at: facet) }
            let observer = FrameObserver(directory: facet)
            let runtime = try SketchRuntime(
                sketch: G4BusySketch(), gpu: try RenderDevice(), clock: nil,
                now: { ProcessInfo.processInfo.systemUptime }, observer: observer)
            for _ in 0..<3 { try runtime.advance() }
            let plain = try G4.sample(warmup: 0, runs: 20) { try runtime.advance() }
            G4.report("2381", scene, "advance.notCapturing", plain)

            // 10 枚を毎フレーム撮る要求。撮り始めは要求を拾ったフレーム、最後の枚で報告を書く
            let body = #"{"id":"g4","scale":\#(scale),"count":10,"every":1}"#
            try AtomicFile.write(Data(body.utf8), to: facet.appendingPathComponent("request.json"))
            let capturing = try G4.sample(warmup: 0, runs: 12) { try runtime.advance() }
            G4.report("2381", scene, "advance.capturing(12 frames incl. 10 shots)", capturing)

            // 報告の frameTimeMs に撮影が混ざったか (直前 60 区間の窓)
            let report = try JSONSerialization.jsonObject(
                with: Data(contentsOf: facet.appendingPathComponent("report.json"))) as? [String: Any]
            let load = report?["load"] as? [String: Any]
            let frameTime = load?["frameTimeMs"] as? [String: Any]
            G4.line("2381", scene, "report.frameTimeMs.mean", (frameTime?["mean"] as? Double) ?? -1, "ms")
            G4.line("2381", scene, "report.frameTimeMs.max", (frameTime?["max"] as? Double) ?? -1, "ms")
            G4.line("2381", scene, "report.frameRate", (load?["frameRate"] as? Double) ?? -1, "fps")

            // 内訳。絵は撮ったものと同じ道で読む
            G4.report("2381", scene, "encodeToImageAndRead", try G4.sample(runs: 10) {
                _ = try runtime.target.encodeToImageAndRead(scaledBy: scale)
            })
            let image = try runtime.target.encodeToImageAndRead(scaledBy: scale)
            G4.report("2381", scene, "FrameStats.summarize", G4.sample(runs: 20) {
                g4Sink &+= FrameStats.summarize(image).sampleGrid.width
            })
            G4.report("2381", scene, "observer.writeFrame(PNG+AtomicFile)", try G4.sample(warmup: 1, runs: 6) {
                _ = try observer.writeFrame(image, at: 99)
            })
            runtime.closePlugins()
        }
    }

    // MARK: #1792 字形を焼くたびの全完了待ち・焼き場の形式・鍵の大きさ

    /// GPU に仕事のある作品で、`textSize` を毎フレーム変える / 変えないを、**決着を待たずに続けて
    /// 回した**ときの 1 フレームあたりで並べる (焼くフレームだけ CPU と GPU の重なりが切れる)。
    @Test("1792 textSize を毎フレーム変える文字: 続けて回した 1 フレームあたりと、待ちの回数")
    func glyphBakeStalls() throws {
        let gpu = try RenderDevice()
        let lines = ["The quick brown fox jumps over 0123456789", "あいうえお かきくけこ 字形 焼き込み"]
        for animated in [false, true] {
            let scene = animated ? "animatedSize" : "fixedSize"
            let canvas = try CanvasFixture.make(gpu: gpu, width: 1920, height: 1080)
            var frame = 0
            func drawFrame() throws {
                frame += 1
                try canvas.draw {
                    canvas.background(0)
                    canvas.noStroke()
                    // GPU に数 ms の塗りを与える (半透明の全面を重ねる)
                    for index in 0..<48 {
                        canvas.fill(255, Float(index * 5 % 255), 64, 8)
                        canvas.rect(0, 0, 1920, 1080)
                    }
                    canvas.fill(255)
                    canvas.textSize(animated ? 24 + Float(frame % 97) * 0.173 : 32)
                    for (row, line) in lines.enumerated() { canvas.text(line, 40, 120 + Float(row) * 80) }
                }
            }
            for _ in 0..<3 { try drawFrame() }
            try gpu.settle()
            let settlesBefore = gpu.settleCalls
            let blockingBefore = gpu.blockingWaits
            let bakedBefore = canvas.atlas.bakedCount
            let serialBefore = canvas.atlas.pageSerial
            let frames = 30
            let total = try ContinuousClock().measure {
                for _ in 0..<frames { try drawFrame() }
                try gpu.settle()
            }
            let perFrame = Double(frames)
            G4.line("1792", scene, "pipelinedFrame", G4.ms(total) / perFrame, "ms")
            G4.line("1792", scene, "settleCallsPerFrame", Double(gpu.settleCalls - settlesBefore) / perFrame, "count")
            G4.line("1792", scene, "blockingWaitsPerFrame", Double(gpu.blockingWaits - blockingBefore) / perFrame, "count")
            G4.line("1792", scene, "glyphsBakedPerFrame", Double(canvas.atlas.bakedCount - bakedBefore) / perFrame, "count")
            G4.line("1792", scene, "pageChanges", Double(canvas.atlas.pageSerial - serialBefore), "count")
            G4.line("1792", scene, "atlasSide", Double(canvas.atlas.size), "px")
            G4.line(
                "1792", scene, "atlasPageBytes",
                Double(canvas.atlas.size * canvas.atlas.size * GlyphAtlas.bytesPerPixel), "bytes")
        }
    }

    // MARK: ADR-0042 決定 5 外の画素の道 (変換 → Image.write → 送る)

    /// 合成した CVPixelBuffer (32BGRA・IOSurface 付き) を `FrameConverter` に通し、`Image.write` して
    /// 貼るまでを段ごとに測る。#487 / PR #604 の当時の値 (1080p: write 1.74 ms・送るまで 2.20 ms、
    /// 20 回の最速値) と並べるため、最小値も出す。**当時は FrameConverter (色空間の変換) が無く、
    /// write は CPU で Float16 へ変換していた** (いまは 1M 画素以上で GPU の復号へ回る・#1771)。
    @Test("ADR-0042 決定 5 外の画素: FrameConverter と Image.write → 貼る (1080p / 4K)")
    func externalPixels() throws {
        let gpu = try RenderDevice()
        for (width, height) in G4.sizes {
            for tagged in [false, true] {
                let scene = "\(width)x\(height).\(tagged ? "rec709" : "untagged")"
                let buffer = try #require(G4Video.pixelBuffer(width: width, height: height, rec709: tagged))
                let converter = FrameConverter(width: width, height: height)
                G4.report("ADR0042-5", scene, "FrameConverter.convert", try G4.sample {
                    g4Sink &+= try converter.convert(buffer).bytes.count
                })
                // 頼んだ大きさと違って届いた (縮める道)。カメラが別の大きさを返したとき
                let smaller = FrameConverter(width: width / 2, height: height / 2)
                G4.report("ADR0042-5", scene, "FrameConverter.convert(toHalf)", try G4.sample {
                    g4Sink &+= try smaller.convert(buffer).bytes.count
                })

                guard !tagged else { continue }
                let picture = try converter.convert(buffer)
                let canvas = try CanvasFixture.make(gpu: gpu, width: width, height: height)
                let image = try canvas.createImage(width, height)
                G4.report("ADR0042-5", scene, "Image.write", G4.sample { image.write(picture) })
                let clock = ContinuousClock()
                var drawCPU: [Double] = []
                var settleWall: [Double] = []
                for run in 0..<23 {
                    image.write(picture)
                    let drew = try clock.measure { try canvas.draw { canvas.image(image, 0, 0) } }
                    let settled = try clock.measure { try gpu.settle() }
                    if run >= 3 { drawCPU.append(G4.ms(drew)); settleWall.append(G4.ms(settled)) }
                }
                G4.report("ADR0042-5", scene, "drawWithWrittenImage.cpu", drawCPU)
                G4.report("ADR0042-5", scene, "drawWithWrittenImage.settle", settleWall)
                G4.report("ADR0042-5", scene, "drawWithUnchangedImage.total", try G4.sample {
                    try canvas.draw { canvas.image(image, 0, 0) }
                    try gpu.settle()
                })
            }
        }
    }

    // MARK: #1960 動画を main で読む: ループの継ぎ目・jump() で読み手を作り直す止まり

    /// H.264 の 3 秒 (30 fps × 90 枚) の動画を作り、`MovieReader.picture(at:)` を main から呼ぶ。
    ///
    /// - steady: 1/30 秒ずつ進める (1 回の呼び出しが返らない長さ。最大がデコードの止まり)
    /// - loopSeam: 2.95 秒から 0 秒へ (読み手を作り直す)
    /// - jumpBack: 2.9 秒から 2.5 秒へ (2.5 秒の手前のキーフレームから復号し直す)
    /// - jumpAhead: 0 秒から 2.5 秒へ (`seekAhead` の 1 秒を越える)
    /// キーフレームの間隔は 1 秒 (30) と 3 秒 (90 = 先頭の 1 つだけ) で振る。HEVC も 1 本 (#2202 が
    /// 「4K の HEVC で予算に収まるかは測っていない」と書いている)。
    @Test(
        "1960 動画の読み: 通常の 1 コマ・ループの継ぎ目・jump() の止まり",
        .enabled(if: G4Video.canWriteH264, "H.264 の符号化器が無い"),
        arguments: ["h264.gop30", "h264.gop90", "hevc.gop30"])
    func movieReaderStalls(variant: String) async throws {
        let codec: AVVideoCodecType = variant.hasPrefix("hevc") ? .hevc : .h264
        let keyFrameInterval = variant.hasSuffix("gop90") ? 90 : 30
        for (width, height) in G4.sizes {
            let scene = "\(width)x\(height).\(variant)"
            let url = try await G4Video.writeMovie(
                codec: codec, width: width, height: height, frames: 90, fps: 30,
                keyFrameInterval: keyFrameInterval)
            defer { try? FileManager.default.removeItem(at: url) }
            let clock = ContinuousClock()
            let reader = try MovieReader(url: url, path: url.path)

            var steady: [Double] = []
            for frame in 0..<89 {
                let position = Double(frame) / 30
                steady.append(G4.ms(try clock.measure { _ = try reader.picture(at: position) }))
            }
            G4.report("1960", scene, "steady.picture(at:)", steady)

            func stall(from: Double, to: Double, runs: Int = 8) throws -> [Double] {
                var values: [Double] = []
                for _ in 0..<runs {
                    _ = try reader.picture(at: from)
                    values.append(G4.ms(try clock.measure { _ = try reader.picture(at: to) }))
                }
                return values
            }
            G4.report("1960", scene, "loopSeam(2.95->0)", try stall(from: 2.95, to: 0))
            G4.report("1960", scene, "jumpBack(2.9->2.5)", try stall(from: 2.9, to: 2.5))
            G4.report("1960", scene, "jumpAhead(0->2.5)", try stall(from: 0, to: 2.5))
            // seekAhead (1 秒) の内側へ飛ぶと、読み直さずに間のコマを全部 main で復号して進む
            G4.report("1960", scene, "jumpAheadWithin1s(0->0.9)", try stall(from: 0, to: 0.9))
            reader.close()

            // 作り直しの内訳: 開いて読み始める / 2.5 秒の最初の 1 コマが出る
            let (opening, firstSample) = try await G4Video.restartCosts(url: url, at: 2.5, runs: 8)
            G4.report("1960", scene, "restart.openAndStart", opening)
            G4.report("1960", scene, "restart.firstSampleAt2.5", firstSample)
        }
    }
}

/// 録画・観測で回す作品。地に半透明の矩形を重ね、PNG と ProRes に手応えを与える。
final class G4BusySketch: Sketch {
    nonisolated(unsafe) static var size = (1920, 1080)
    init() {}
    var settings: SketchSettings { SketchSettings(width: Self.size.0, height: Self.size.1) }
    func draw() {
        background(.display(red: 0.05, green: 0.05, blue: 0.08))
        noStroke()
        let (width, height) = (Float(Self.size.0), Float(Self.size.1))
        for index in 0..<300 {
            let t = Float(index) * 0.618 + Float(frameCount) * 0.01
            fill(.display(
                red: 0.5 + 0.5 * sin(t), green: 0.5 + 0.5 * sin(t * 1.3), blue: 0.5 + 0.5 * sin(t * 1.7),
                alpha: 0.6))
            rect(
                (t * 97).truncatingRemainder(dividingBy: width), (t * 61).truncatingRemainder(dividingBy: height),
                width / 12, height / 12)
        }
    }
}

// MARK: - 動画・カメラの道具 (ADR-0042 決定 5・#1960)

nonisolated enum G4Video {
    static let canWriteH264: Bool = {
        var encoder: CFString?
        var properties: CFDictionary?
        return VTCopySupportedPropertyDictionaryForEncoder(
            width: 1920, height: 1080, codecType: kCMVideoCodecType_H264, encoderSpecification: nil,
            encoderIDOut: &encoder, supportedPropertiesOut: &properties) == noErr
    }()

    /// 32BGRA・IOSurface 付きの 1 枚。`rec709` なら色を名乗らせる (動画の読み手が渡すものに近い)。
    static func pixelBuffer(width: Int, height: Int, rec709: Bool) -> CVPixelBuffer? {
        var made: CVPixelBuffer?
        let attributes = [kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any]()] as CFDictionary
        guard CVPixelBufferCreate(
            kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA, attributes, &made) == kCVReturnSuccess,
            let buffer = made
        else { return nil }
        fill(buffer, index: 0)
        if rec709 {
            CVBufferSetAttachment(
                buffer, kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_709_2, .shouldPropagate)
            CVBufferSetAttachment(
                buffer, kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_ITU_R_709_2, .shouldPropagate)
            CVBufferSetAttachment(
                buffer, kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_709_2, .shouldPropagate)
        }
        return buffer
    }

    /// 行ごとに一色で塗り、動く白い帯を置く (速く塗れて、コマごとに違う)。
    static func fill(_ buffer: CVPixelBuffer, index: Int) {
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return }
        let width = CVPixelBufferGetWidth(buffer)
        let height = CVPixelBufferGetHeight(buffer)
        let rowBytes = CVPixelBufferGetBytesPerRow(buffer)
        let bar = min(64, width)
        let barX = (index * 37) % max(1, width - bar)
        for y in 0..<height {
            let row = base.advanced(by: y * rowBytes).assumingMemoryBound(to: UInt32.self)
            let level = UInt32(truncatingIfNeeded: (y + index * 3) & 0xff)
            row.update(
                repeating: 0xff00_0000 | level << 16 | UInt32((y >> 2) & 0xff) << 8 | UInt32((index * 5) & 0xff),
                count: width)
            (row + barX).update(repeating: 0xffff_ffff, count: bar)
        }
    }

    /// H.264 / HEVC の動画を一時ディレクトリへ書く。キーフレームの間隔を指定できる。
    static func writeMovie(
        codec: AVVideoCodecType, width: Int, height: Int, frames: Int, fps: Int32, keyFrameInterval: Int
    ) async throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("mokume-perf-g4-\(UUID().uuidString).mov")
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(
            mediaType: .video,
            outputSettings: [
                AVVideoCodecKey: codec,
                AVVideoWidthKey: width,
                AVVideoHeightKey: height,
                AVVideoCompressionPropertiesKey: [
                    AVVideoMaxKeyFrameIntervalKey: keyFrameInterval,
                    AVVideoAverageBitRateKey: width * height * 4,
                ],
                AVVideoColorPropertiesKey: [
                    AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                    AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                    AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2,
                ],
            ])
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: width,
                kCVPixelBufferHeightKey as String: height,
            ])
        writer.add(input)
        try #require(writer.startWriting(), "\(String(describing: writer.error))")
        writer.startSession(atSourceTime: .zero)
        for index in 0..<frames {
            while !input.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(1)) }
            let pool = try #require(adaptor.pixelBufferPool)
            var made: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, pool, &made)
            let buffer = try #require(made)
            fill(buffer, index: index)
            #expect(adaptor.append(buffer, withPresentationTime: CMTime(value: CMTimeValue(index), timescale: fps)))
        }
        input.markAsFinished()
        writer.endSession(atSourceTime: CMTime(value: CMTimeValue(frames), timescale: fps))
        await writer.finishWriting()
        try #require(writer.status == .completed, "\(String(describing: writer.error))")
        return url
    }

    /// `MovieReader` が作り直すときと同じ形で読み手を開き、(開いて読み始めるまで, 最初の 1 コマまで) を
    /// `runs` 回測る。
    static func restartCosts(url: URL, at seconds: Double, runs: Int) async throws -> ([Double], [Double]) {
        let asset = AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        let track = try #require(try await asset.loadTracks(withMediaType: .video).first)
        let clock = ContinuousClock()
        var opening: [Double] = []
        var firstSample: [Double] = []
        for _ in 0..<runs {
            var made: (reader: AVAssetReader, output: AVAssetReaderTrackOutput)?
            opening.append(G4.ms(try clock.measure {
                let reader = try AVAssetReader(asset: asset)
                let output = AVAssetReaderTrackOutput(
                    track: track,
                    outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
                output.alwaysCopiesSampleData = false
                reader.timeRange = CMTimeRange(
                    start: CMTime(seconds: seconds, preferredTimescale: 1_000_000), duration: .positiveInfinity)
                reader.add(output)
                _ = reader.startReading()
                made = (reader, output)
            }))
            firstSample.append(G4.ms(clock.measure { _ = made?.output.copyNextSampleBuffer() }))
            made?.reader.cancelReading()
        }
        return (opening, firstSample)
    }
}
