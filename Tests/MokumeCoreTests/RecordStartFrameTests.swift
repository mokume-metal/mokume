// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import AVFoundation
import Foundation
import ImageIO
import Testing

@testable import MokumeCore

/// 録りの 1 枚目が、**`beginRecord()` を呼んだフレームの絵**であること。GPU を要する。
///
/// 絵は 1 枚遅れて出口へ届く ([#927])。撮る係がその前のフレームから差込口の並びに居ると、
/// 撮り始めたフレームで**前のフレームの絵**が届く — 直前のフレームで `save()` を頼んでいた
/// ときと、外から足した出口が付いているときである。それを録りに入れると 1 枚多くなり、
/// 全体が 1 フレーム前へずれる ([#1456])。
///
/// ずれは絵を見ても分からない (動きが 1 コマ早く始まるだけ) ので、フレームごとに明るさを
/// 変えて、撮れた各枚がどのフレームの絵かを画素で読む。
///
/// [#927]: https://github.com/mokume-metal/mokume/issues/927
/// [#1456]: https://github.com/mokume-metal/mokume/issues/1456
@Suite(
    "録りの 1 枚目",
    .enabled(
        if: RenderDevice.isAvailable,
        "この世代のコマンド構造に対応した GPU が無い実行環境ではスキップする")
)
struct RecordStartFrameTests {

    /// 撮り始めるフレーム。
    static let startsAt = 2
    /// 止めるフレーム。**このフレームの絵は入らない** — 止める時点ではまだ描き終えていない。
    static let endsAt = 12
    /// 撮れるはずのフレーム。読んだ明るさ (``frame(showing:)``) と比べるので、欠けうる形で持つ。
    static let recorded: [Int?] = Array(startsAt..<endsAt)

    /// フレームごとに明るさを変え、決めたフレームの間だけ撮る。
    final class Recording: Sketch {
        var pattern = ""
        /// 空でなければ、1 フレーム目にここへ `save()` する。
        var stillPath = ""
        var declared: [any Plugin] = []
        init() {}
        var settings: SketchSettings { SketchSettings(width: 64, height: 48, frameRate: 60) }
        var plugins: [any Plugin] { declared }
        func draw() {
            // 灰色は書いた数と書き出したバイトが一致する (``LinearRGBA/display(red:green:blue:alpha:)``)
            let level = Float(frameCount * RecordStartFrameTests.step) / 255
            background(.display(red: level, green: level, blue: level))
            if frameCount == 1, !stillPath.isEmpty { save(stillPath) }
            if frameCount == RecordStartFrameTests.startsAt { beginRecord(pattern) }
            if frameCount == RecordStartFrameTests.endsAt { endRecord() }
        }
    }

    /// 何も受け取らない出口。**付いている間は毎フレーム絵が組まれる**ので、撮る係が並びへ
    /// 入ったフレームで、前のフレームの絵が配られる。
    final class Idle: Outlet {
        func receive(_ frame: OutputFrame) {}
    }

    struct IdlePlugin: Plugin {
        let outlet: Idle
        func register(into registry: PluginRegistry) { registry.add(outlet: outlet) }
    }

    /// 撮り始めるフレームまでに撮る係を並びへ入れるもの。
    enum Before: String, CaseIterable, CustomTestStringConvertible {
        /// 何も頼まない。**直す前から正しかった形**で、比べる相手になる
        case nothing
        /// 1 フレーム目に `save()` する
        case save
        /// 外から足した出口が付いている
        case outlet

        var testDescription: String { rawValue }
    }

    /// 連番を撮る。**直前に何をしていても、1 枚目は撮り始めたフレームの絵である。**
    @Test("連番の 1 枚目は、beginRecord() を呼んだフレームの絵", arguments: Before.allCases)
    func theSequenceStartsAtItsOwnFrame(_ before: Before) async throws {
        try await withTemporaryDirectory("mokume-record-start-sequence") { directory in
            let frames = directory.appendingPathComponent("frames", isDirectory: true)
            let still = directory.appendingPathComponent("still.png")
            try run(
                pattern: frames.appendingPathComponent("f-###.png").path, before: before,
                still: still)

            let names = try FileManager.default.contentsOfDirectory(atPath: frames.path).sorted()
            let shown = try names.map { try firstByte(of: frames.appendingPathComponent($0)) }
            #expect(shown.map(Self.frame(showing:)) == Self.recorded, "各枚の明るさ: \(shown)")
            try expectStillIsFrameOne(still, before)
        }
    }

    /// 動画を撮る。連番と同じ受け取り方を通るので、同じずれ方をする。
    @Test(
        "動画の 1 枚目は、beginRecord() を呼んだフレームの絵",
        .enabled(if: MovieFile.isAvailable, "この機械には ProRes 4444 の符号化器が無い"),
        arguments: Before.allCases)
    func theMovieStartsAtItsOwnFrame(_ before: Before) async throws {
        try await withTemporaryDirectory("mokume-record-start-movie") { directory in
            let path = directory.appendingPathComponent("motion.mov").path
            let still = directory.appendingPathComponent("still.png")
            try run(pattern: path, before: before, still: still)

            let shown = try await firstBytes(ofMovieAt: path)
            #expect(shown.map(Self.frame(showing:)) == Self.recorded, "各枚の明るさ: \(shown)")
            try expectStillIsFrameOne(still, before)
        }
    }

    // MARK: - 道具

    /// フレームごとの明るさの刻み (0…255)。
    static let step = 20

    /// 読んだ明るさが、どのフレームの絵か。
    ///
    /// **近いフレームが無ければ `nil`。** 別の絵を最寄りのフレームへ丸めて通さない。
    /// 許す幅は刻みの半分より十分狭く取る (動画は符号化を通るので、書いた数とちょうどには
    /// 一致しない)。
    static func frame(showing byte: UInt8) -> Int? {
        let nearest = Int((Double(byte) / Double(step)).rounded())
        return abs(Int(byte) - nearest * step) <= 4 ? nearest : nil
    }

    /// 決めたフレームの間だけ撮るスケッチを、止めるフレームまで回して閉じる。
    private func run(pattern: String, before: Before, still: URL) throws {
        let sketch = Recording()
        sketch.pattern = pattern
        if before == .save { sketch.stillPath = still.path }
        if before == .outlet { sketch.declared = [IdlePlugin(outlet: Idle())] }
        let runtime = try SketchRuntime(sketch: sketch, gpu: try RenderDevice())
        for _ in 0..<Self.endsAt { try runtime.advance() }
        runtime.closePlugins()
    }

    /// `save()` が書くのは**それを呼んだフレームの絵**のまま ([#927])。撮り始める前の絵を
    /// 録りから外すときに、同じ 1 枚を受け取る予約まで巻き込んでいないこと。
    ///
    /// [#927]: https://github.com/mokume-metal/mokume/issues/927
    private func expectStillIsFrameOne(_ still: URL, _ before: Before) throws {
        guard before == .save else { return }
        let shown = try firstByte(of: still)
        #expect(Self.frame(showing: shown) == 1, "save() の明るさ: \(shown)")
    }

    /// 書いた PNG の左上の画素の、最初のバイト (赤)。
    private func firstByte(of url: URL) throws -> UInt8 {
        let source = try #require(CGImageSourceCreateWithURL(url as CFURL, nil))
        let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        let data = try #require(image.dataProvider?.data as Data?)
        return try #require(data.first)
    }

    /// 書き出した動画の各枚の、左上の画素の赤。**符号化を通った実物を読む** — 渡した絵ではなく。
    private func firstBytes(ofMovieAt path: String) async throws -> [UInt8] {
        let asset = AVURLAsset(url: URL(fileURLWithPath: path))
        let track = try #require(try await asset.loadTracks(withMediaType: .video).first)
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(
            track: track,
            outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        reader.add(output)
        try #require(reader.startReading(), "動画を読み始められない: \(String(describing: reader.error))")

        var reds: [UInt8] = []
        while let sample = output.copyNextSampleBuffer() {
            guard let buffer = CMSampleBufferGetImageBuffer(sample) else { continue }
            CVPixelBufferLockBaseAddress(buffer, .readOnly)
            defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
            let base = try #require(CVPixelBufferGetBaseAddress(buffer))
            // 並びは BGRA なので、赤は 3 つ目
            reds.append(base.assumingMemoryBound(to: UInt8.self)[2])
        }
        return reds
    }
}

/// 検査のあいだだけ使う一時ディレクトリ。
private func withTemporaryDirectory(
    _ name: String, _ body: (URL) async throws -> Void
) async throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("\(name)-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    try await body(directory)
}
