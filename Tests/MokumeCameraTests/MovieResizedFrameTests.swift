// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import AVFoundation
import CoreVideo
import Foundation
import Testing

@testable import MokumeCamera
@testable import MokumeCore

/// 途中でコマの大きさが変わる動画 (#3690)。GPU は要らない。動画は検査の中で作る。
///
/// 約束は「記録の大きさ (最初のコマの大きさ) と違うコマは、面の道へ乗せない」。面の道の絵は大きさの不一致を
/// 1 度だけ警告して捨てる (``Image/write(_:)-(PixelSurface)``) ので、乗せると絵は前のコマのまま止まる。
/// 変換器 (``FrameConverter``) は最初のコマの大きさへ縮めるので、そちらへ回せば頼んだ大きさの絵が届く。
/// 不透明なコマも透過を持つコマも、同じ結果になる。
@Suite(
    "途中で大きさが変わる動画",
    .enabled(if: TestMovie.canWrite, "この機械には H.264 の符号化器が無い")
)
struct MovieResizedFrameTests {
    /// 記録の大きさ (最初のコマ)。
    private static let recorded = (width: 128, height: 96)
    /// 途中から変わった後の大きさ。
    private static let later = (width: 192, height: 128)
    /// それぞれの枚数 (30 fps)。
    private static let count = 20

    /// 128×96 を 20 枚、続けて 192×128 を 20 枚。
    private func resizedMovie() async throws -> URL {
        let first = try await TestMovie.write(
            frames: Self.count, width: Self.recorded.width, height: Self.recorded.height, keyFrameInterval: 10,
            paint: TestMovie.stripe)
        let second = try await TestMovie.write(
            frames: Self.count, width: Self.later.width, height: Self.later.height, keyFrameInterval: 10,
            paint: TestMovie.stripe)
        defer {
            try? FileManager.default.removeItem(at: first)
            try? FileManager.default.removeItem(at: second)
        }
        return try await TestMovie.concatenated(first, second)
    }

    /// 大きさの変わらない 128×96 の 40 枚。
    private func steadyMovie() async throws -> URL {
        try await TestMovie.write(
            frames: Self.count * 2, width: Self.recorded.width, height: Self.recorded.height, keyFrameInterval: 10,
            paint: TestMovie.stripe)
    }

    private nonisolated static func halfClear(_ index: Int, _ x: Int, _ y: Int) -> TestMovie.Straight {
        x % 2 == 0 ? (240, 150, 70, 128) : (240, 150, 70, 255)
    }

    /// 乗算していない、不透明と半透明が混ざる透過の動画。128×96 を 4 枚、続けて 192×128 を 4 枚。
    private func resizedTransparentMovie() async throws -> URL {
        let first = try await TestMovie.writeTransparent(
            frames: 4, width: Self.recorded.width, height: Self.recorded.height, pixel: Self.halfClear)
        let second = try await TestMovie.writeTransparent(
            frames: 4, width: Self.later.width, height: Self.later.height, pixel: Self.halfClear)
        defer {
            try? FileManager.default.removeItem(at: first)
            try? FileManager.default.removeItem(at: second)
        }
        return try await TestMovie.concatenated(first, second)
    }

    private func size(of frame: VideoFrame) -> (width: Int, height: Int) {
        switch frame {
        case .converted(let picture): (picture.width, picture.height)
        case .surface(let surface): (surface.width, surface.height)
        }
    }

    private func isSurface(_ frame: VideoFrame) -> Bool {
        if case .surface = frame { true } else { false }
    }

    /// 係が列を埋め終えるまで待つ。期限 (60 秒) を越えたら落とす。
    private func settle(_ prefetcher: MoviePrefetcher) async throws {
        let deadline = ContinuousClock.now + .seconds(60)
        while !prefetcher.isSettled {
            try #require(ContinuousClock.now < deadline, "係が 60 秒で列を埋め終えない")
            try await Task.sleep(for: .milliseconds(1))
        }
    }

    /// 復号器が実際に届けるコマを、読み手を通さずに全部引く。**検査の前提を確かめる。**
    private func decodedBuffers(_ url: URL) throws -> [CVPixelBuffer] {
        let asset = AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        let (track, range, _, _) = try MovieReader.inspect(asset, path: url.path)
        let frames = try MovieFrames(
            asset: asset, track: track, start: range.start, duration: range.duration.seconds, keyFrames: nil)
        var buffers: [CVPixelBuffer] = []
        while let current = frames.current {
            buffers.append(current.buffer)
            let serial = current.serial
            try frames.step()
            if frames.current?.serial == serial { break }
        }
        return buffers
    }

    /// この動画の色の意味の表を、共有の表に作り終えるまで待つ。**表が無い間は不透明なコマも変換器の道へ
    /// 回る** (main の読み手は表を作らない) ので、待たずに見ると、面の道に乗るはずのコマが乗らない理由が
    /// 「大きさ」ではなく「表がまだ無い」でも検査が緑になる (取りこぼし)。
    private func primeSurfaceTable(for url: URL) async throws {
        let buffer = try #require(try decodedBuffers(url).first)
        let deadline = ContinuousClock.now + .seconds(60)
        while true {
            switch SurfaceRoute.surface(for: buffer, alpha: .straight, reshaped: false, builds: true) {
            case .success: return
            case .failure(.tablePending): break
            case .failure(let refusal): Issue.record("表を作れない: \(refusal)"); return
            }
            try #require(ContinuousClock.now < deadline, "表が 60 秒で出来ない")
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    @Test("前提: 継いだ動画は、復号器が途中から大きさの違うコマを届け、そのコマは (大きさを問わなければ) 面の道に乗る")
    func premiseTheDecoderDeliversTheNewSize() async throws {
        let url = try await resizedMovie()
        defer { try? FileManager.default.removeItem(at: url) }
        try await primeSurfaceTable(for: url)
        let buffers = try decodedBuffers(url)
        let sizes = buffers.map { (width: CVPixelBufferGetWidth($0), height: CVPixelBufferGetHeight($0)) }
        #expect(sizes.count == Self.count * 2)
        #expect(sizes.prefix(Self.count).allSatisfy { $0 == Self.recorded }, "前半は記録の大きさ")
        #expect(sizes.suffix(Self.count).allSatisfy { $0 == Self.later }, "後半は大きさが変わる: \(sizes.suffix(Self.count))")
        // 大きさの判定が無ければ、後半のコマも面に乗る。ここが乗らないと、下の検査は理由の違う緑になる
        for (index, buffer) in buffers.enumerated() {
            let route = SurfaceRoute.surface(for: buffer, alpha: .straight, reshaped: false, builds: false)
            #expect((try? route.get()) != nil, "\(index) 枚目が面の道に乗らない: \(route)")
        }
    }

    @Test("読み手 (同期の道): 途中で大きさが変わった不透明なコマは、面に乗らず、記録の大きさの絵として届く")
    func readerShrinksResizedOpaqueFrames() async throws {
        let url = try await resizedMovie()
        defer { try? FileManager.default.removeItem(at: url) }
        try await primeSurfaceTable(for: url)
        let reader = try MovieReader(url: url, path: url.path)
        #expect(reader.width == Self.recorded.width && reader.height == Self.recorded.height)
        var delivered: [VideoFrame] = []
        for index in 0..<(Self.count * 2) {
            if let frame = try reader.frame(at: Double(index) / 30) { delivered.append(frame) }
        }
        #expect(delivered.count == Self.count * 2, "40 枚が全部届く (届いたのは \(delivered.count) 枚)")
        for (index, frame) in delivered.enumerated() {
            let got = size(of: frame)
            #expect(got == Self.recorded, "\(index) 枚目が \(got) で届いた (記録は \(Self.recorded))")
        }
        // 前半は記録の大きさなので面の道に乗る (表が出来ている前提の確認。乗らないと後半の検査が取りこぼす)
        #expect(delivered.prefix(Self.count).filter(isSurface).count >= Self.count - 2, "前半が面に乗らない")
        // 後半は、大きさの違う面ではなく、変換器が縮めた CPU の絵
        #expect(!delivered.suffix(Self.count).contains(where: isSurface), "大きさの違うコマが面の道に乗った")
    }

    @Test("先読みの係: 途中で大きさが変わった不透明なコマは、面に乗らず、記録の大きさの絵として列に入る")
    func prefetcherShrinksResizedOpaqueFrames() async throws {
        let url = try await resizedMovie()
        defer { try? FileManager.default.removeItem(at: url) }
        try await primeSurfaceTable(for: url)
        let prefetcher = MoviePrefetcher(
            source: MovieSource(
                url: url, path: url.lastPathComponent, indexesKeyFrames: true, width: Self.recorded.width,
                height: Self.recorded.height, orientation: .identity))
        defer { prefetcher.close() }
        _ = try prefetcher.picture(at: 0, generation: 0, lap: 0, looping: false)
        try await settle(prefetcher)
        var delivered: [VideoFrame] = []
        for index in 0..<(Self.count * 2) {
            if let frame = try prefetcher.picture(at: Double(index) / 30, generation: 0, lap: 0, looping: false) {
                delivered.append(frame)
            }
            try await settle(prefetcher)
        }
        // 後半のコマが届くこと (捨てられて前のコマのまま止まっていない)
        #expect(delivered.count >= Self.count + 1, "後半のコマが届かない (届いたのは \(delivered.count) 枚)")
        for (index, frame) in delivered.enumerated() {
            let got = size(of: frame)
            #expect(got == Self.recorded, "\(index) 枚目が \(got) で届いた (記録は \(Self.recorded))")
        }
        #expect(delivered.prefix(Self.count).filter(isSurface).count >= Self.count - 2, "前半が面に乗らない")
        #expect(!delivered.suffix(Self.count).contains(where: isSurface), "大きさの違うコマが面の道に乗った")
    }

    @Test("先読みの係: 大きさが変わった後へ飛んでも (作り直しても) 記録の大きさの絵が届く")
    func prefetcherShrinksResizedFramesAfterAJump() async throws {
        let url = try await resizedMovie()
        defer { try? FileManager.default.removeItem(at: url) }
        try await primeSurfaceTable(for: url)
        let prefetcher = MoviePrefetcher(
            source: MovieSource(
                url: url, path: url.lastPathComponent, indexesKeyFrames: true, width: Self.recorded.width,
                height: Self.recorded.height, orientation: .identity))
        defer { prefetcher.close() }
        _ = try prefetcher.picture(at: 1.0, generation: 1, lap: 0, looping: false)
        try await settle(prefetcher)
        let frame = try #require(try prefetcher.picture(at: 1.0, generation: 1, lap: 0, looping: false))
        #expect(size(of: frame) == Self.recorded)
        #expect(!isSurface(frame))
    }

    @Test("透過を持つコマも、途中で大きさが変われば、同じく記録の大きさの絵として届く (読み手・係)")
    func resizedTransparentFramesAreShrunkToo() async throws {
        try #require(TestMovie.canWriteTransparent, "ProRes 4444 の符号化器が無い")
        let url = try await resizedTransparentMovie()
        defer { try? FileManager.default.removeItem(at: url) }
        let reader = try MovieReader(url: url, path: url.path)
        var count = 0
        for index in 0..<8 {
            guard let frame = try reader.frame(at: Double(index) / 30) else { continue }
            count += 1
            #expect(size(of: frame) == Self.recorded, "読み手: \(index) 枚目")
            #expect(!isSurface(frame), "透過のコマは面に乗らない")
        }
        #expect(count == 8)
    }

    @Test("大きさが変わらない不透明な動画は、これまでどおり面の道に乗る (読み手・係)")
    func steadyMovieStaysOnTheSurfaceRoute() async throws {
        let url = try await steadyMovie()
        defer { try? FileManager.default.removeItem(at: url) }
        try await primeSurfaceTable(for: url)
        let prefetcher = MoviePrefetcher(
            source: MovieSource(
                url: url, path: url.lastPathComponent, indexesKeyFrames: true, width: Self.recorded.width,
                height: Self.recorded.height, orientation: .identity))
        defer { prefetcher.close() }
        _ = try prefetcher.picture(at: 0, generation: 0, lap: 0, looping: false)
        try await settle(prefetcher)
        var delivered: [VideoFrame] = []
        for index in 0..<(Self.count * 2) {
            if let frame = try prefetcher.picture(at: Double(index) / 30, generation: 0, lap: 0, looping: false) {
                delivered.append(frame)
            }
            try await settle(prefetcher)
        }
        #expect(delivered.count >= Self.count * 2 - 2)
        #expect(delivered.allSatisfy { size(of: $0) == Self.recorded })
        #expect(delivered.filter(isSurface).count >= delivered.count - 2, "係: 面に乗ったのは \(delivered.filter(isSurface).count) / \(delivered.count) 枚")

        let reader = try MovieReader(url: url, path: url.path)
        var surfaces = 0
        var frames = 0
        for index in 0..<(Self.count * 2) {
            guard let frame = try reader.frame(at: Double(index) / 30) else { continue }
            frames += 1
            if isSurface(frame) { surfaces += 1 }
            #expect(size(of: frame) == Self.recorded)
        }
        #expect(frames == Self.count * 2)
        #expect(surfaces >= frames - 2, "読み手: 面に乗ったのは \(surfaces) / \(frames) 枚")
    }
}
