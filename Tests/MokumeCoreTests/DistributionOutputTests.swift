// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import AVFoundation
import Foundation
import ImageIO
import MokumeTestSupport
import Testing
import UniformTypeIdentifiers

@testable import MokumeCore

/// 配る形 (GIF・MP4) の書き手 ([#2440](https://github.com/mokume-metal/mokume/issues/2440))。
///
/// **GPU を要さない** — 出口が受け取る絵と時刻を ``MovieWriter`` へ直接渡し、書き上がったファイルを
/// ImageIO と AVFoundation で読み戻して、枚数・遅延・寸法・繰り返し・色・透けを見る。
@Suite("配る形 (GIF・MP4) の書き手")
struct DistributionOutputTests {
    private func withDirectory(_ body: (URL) throws -> Void) throws {
        let directory = try TestScratch.directory("mokume-distribution")
        defer { try? FileManager.default.removeItem(at: directory) }
        try body(directory)
    }

    /// 枚ごとに違う絵 (四角が右へ動く)。大きさは `width` x `height`。
    private func picture(_ index: Int, width: Int = 48, height: Int = 32) -> DisplayImage {
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let offset = (y * width + x) * 4
                let inside = abs(x - (6 + index * 3)) < 5 && abs(y - height / 2) < 5
                bytes[offset] = inside ? 230 : UInt8(x * 255 / max(1, width - 1))
                bytes[offset + 1] = inside ? 60 : UInt8(y * 255 / max(1, height - 1))
                bytes[offset + 2] = 100
                bytes[offset + 3] = 255
            }
        }
        return DisplayImage(width: width, height: height, bytes: bytes)
    }

    private func write(
        _ format: MovieWriter.Format, to path: String, frames: Int, fps: Int,
        picture make: (Int) -> DisplayImage
    ) {
        let writer = MovieWriter(path: path, frameRate: fps, format: format)
        for index in 0..<frames {
            writer.write(make(index), frame: index + 1, time: Double(index) / Double(fps))
        }
        writer.finish()
        #expect(writer.takeFailure() == nil, "書き損じた")
    }

    private func gifSource(_ path: String) throws -> CGImageSource {
        try #require(CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil))
    }

    /// 読み戻した 1 枚の画素 (sRGB・乗算済みの文脈へ描いて読む)。
    private func pixel(_ source: CGImageSource, frame: Int, x: Int, y: Int) throws
        -> (r: UInt8, g: UInt8, b: UInt8, a: UInt8)
    {
        let image = try #require(CGImageSourceCreateImageAtIndex(source, frame, nil))
        let context = try #require(
            CGContext(
                data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
                bytesPerRow: image.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        let data = try #require(context.data).assumingMemoryBound(to: UInt8.self)
        // CGContext は左下原点ではなく、データの先頭が最上行
        let offset = (y * image.width + x) * 4
        return (data[offset], data[offset + 1], data[offset + 2], data[offset + 3])
    }

    // MARK: - GIF (完了条件 1・5)

    @Test("25 fps で 100 枚書くと、100 枚・各枚の遅延 4/100 秒・繰り返し無限の GIF になる")
    func aHundredFramesAtTwentyFiveFps() throws {
        try withDirectory { directory in
            let path = directory.appendingPathComponent("loop.gif").path
            write(.gif, to: path, frames: 100, fps: 25) { picture($0 % 12) }

            let source = try gifSource(path)
            #expect(CGImageSourceGetCount(source) == 100)
            let container = CGImageSourceCopyProperties(source, nil) as? [String: Any]
            let gif = container?[kCGImagePropertyGIFDictionary as String] as? [String: Any]
            #expect(gif?[kCGImagePropertyGIFLoopCount as String] as? Int == 0, "繰り返しが無限ではない: \(String(describing: gif))")
            #expect(gif?[kCGImagePropertyGIFCanvasPixelWidth as String] as? Int == 48)
            #expect(gif?[kCGImagePropertyGIFCanvasPixelHeight as String] as? Int == 32)
            for index in [0, 1, 50, 99] {
                let frame = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [String: Any]
                let frameGIF = frame?[kCGImagePropertyGIFDictionary as String] as? [String: Any]
                let delay = frameGIF?[kCGImagePropertyGIFUnclampedDelayTime as String] as? Double
                #expect(delay == 0.04, "\(index) 枚目の遅延が \(String(describing: delay))")
            }
            #expect(GIFFile.frameCount(atPath: path) == 100)
        }
    }

    @Test("遅延は 100 を fps で割った整数で、割り切れない fps は遅延を持たない")
    func delaysAreWholeHundredths() {
        #expect(GIFFile.delay(frameRate: 25) == 4)
        #expect(GIFFile.delay(frameRate: 50) == 2)
        #expect(GIFFile.delay(frameRate: 10) == 10)
        #expect(GIFFile.delay(frameRate: 100) == 1)
        for rate in [3, 24, 30, 60, 120, 99] { #expect(GIFFile.delay(frameRate: rate) == nil, "\(rate)") }
        let near = GIFFile.nearestFrameRates(to: 60)
        #expect(near.below == 50 && near.above == 100)
        let low = GIFFile.nearestFrameRates(to: 30)
        #expect(low.below == 25 && low.above == 50)
        #expect(GIFFile.nearestFrameRates(to: 200).above == nil)
    }

    /// 透け: アルファが 128 以上は不透明、未満は透明。半透明は書かない。透明にした画素の色は 0。
    @Test("透けた画素は、アルファ 128 以上が不透明・未満が透明で書かれる")
    func transparencyIsOneBit() throws {
        try withDirectory { directory in
            let path = directory.appendingPathComponent("alpha.gif").path
            let alphas: [UInt8] = [0, 1, 127, 128, 129, 255]
            let width = alphas.count
            var bytes = [UInt8](repeating: 0, count: width * 4)
            for (x, alpha) in alphas.enumerated() {
                bytes[x * 4] = 200
                bytes[x * 4 + 1] = 50
                bytes[x * 4 + 2] = 10
                bytes[x * 4 + 3] = alpha
            }
            let image = DisplayImage(width: width, height: 1, bytes: bytes)
            write(.gif, to: path, frames: 1, fps: 25) { _ in image }

            let source = try gifSource(path)
            let read = try (0..<width).map { try pixel(source, frame: 0, x: $0, y: 0).a }
            #expect(read == [0, 0, 0, 255, 255, 255], "\(read)")
        }
    }

    /// 色: Display P3 を sRGB へ写してから書く。無彩色は変わらず、彩度のある色は値が変わる。
    @Test("色は Display P3 から sRGB へ写してから書かれる")
    func colourIsConvertedToSRGB() {
        var bytes: [UInt8] = []
        bytes += [128, 128, 128, 255]  // 無彩色
        bytes += [200, 80, 60, 255]  // 彩度のある色
        let converted = DistributionColor.srgb(
            DisplayImage(width: 2, height: 1, bytes: bytes), alpha: .drop)
        #expect(Array(converted.bytes[0..<3]) == [128, 128, 128], "無彩色が変わった: \(converted.bytes)")
        #expect(
            Array(converted.bytes[4..<7]) != [200, 80, 60],
            "彩度のある色が P3 のまま書かれる: \(converted.bytes)")
        // Display P3 の赤みは sRGB で見ると、より赤く (R が増え G・B が減る) なる
        #expect(converted.bytes[4] > 200 && converted.bytes[5] < 80, "\(converted.bytes)")
        #expect(converted.bytes[3] == 255 && converted.bytes[7] == 255)
    }

    @Test("読む側が 1 枚も受け取らなければ、GIF を残さず書き損じにする")
    func noFramesLeavesNoFile() throws {
        try withDirectory { directory in
            let path = directory.appendingPathComponent("none.gif").path
            let writer = MovieWriter(path: path, frameRate: 25, format: .gif)
            writer.finish()
            #expect(!FileManager.default.fileExists(atPath: path))
        }
    }

    /// 枚数を先に渡さずに 1 枚ずつ書き足すので、途中で閉じても書けた枚数の有効な GIF になる。描き終えない回の
    /// 穴は、道具が書き出し先の枚数で断る (`RenderRequest.inspectOutput`)。
    @Test("途中で閉じても、書けた枚数の有効な GIF になる")
    func closingEarlyKeepsTheFramesWritten() throws {
        try withDirectory { directory in
            let path = directory.appendingPathComponent("short.gif").path
            write(.gif, to: path, frames: 4, fps: 25) { picture($0) }
            #expect(GIFFile.frameCount(atPath: path) == 4)
        }
    }

    /// 1 枚だけの GIF から、色表と圧縮列を取り出して組み直す (``GIFBlocks``)。透けのある枚は「描く前に前の絵を
    /// 消す」と宣言する — 宣言しないと、透けた所に前の枚が残る。透けた画素の無い枚には、透けの印を付けない。
    @Test("透けのある枚は消し方 2、無い枚は消し方 1 で書かれ、色表は枚ごとに持つ")
    func blocksDeclareHowTheFrameIsCleared() throws {
        func single(_ alphas: [UInt8]) throws -> GIFBlocks {
            var bytes = [UInt8](repeating: 0, count: alphas.count * 4)
            for (x, alpha) in alphas.enumerated() {
                bytes[x * 4] = UInt8(40 + x * 20); bytes[x * 4 + 1] = 90; bytes[x * 4 + 2] = 200; bytes[x * 4 + 3] = alpha
            }
            let converted = DistributionColor.srgb(
                DisplayImage(width: alphas.count, height: 1, bytes: bytes), alpha: .threshold)
            let hasTransparency = alphas.contains { $0 < DistributionColor.gifThreshold }
            let image = try #require(GIFFile.cgImage(of: converted, withAlpha: hasTransparency))
            let data = NSMutableData()
            let destination = try #require(
                CGImageDestinationCreateWithData(data, UTType.gif.identifier as CFString, 1, nil))
            CGImageDestinationAddImage(destination, image, nil)
            #expect(CGImageDestinationFinalize(destination))
            return try #require(GIFBlocks.parse(data as Data))
        }
        let opaque = try single([255, 255, 255, 255])
        let clear = try single([255, 0, 255, 255])
        #expect(opaque.transparentIndex == nil, "透けた画素の無い枚に透けの印が付いた")
        #expect(clear.transparentIndex != nil)
        #expect(!opaque.colorTable.isEmpty && opaque.colorTable.count % 3 == 0)

        // 制御ブロック: 21 F9 04 <packed> <遅延 2 バイト> <透けた番号> 00 の packed の bit 2-4 が消し方、bit 0 が透けの印
        let opaqueFrame = [UInt8](opaque.frame(delay: 4))
        let clearFrame = [UInt8](clear.frame(delay: 4))
        #expect(Array(opaqueFrame[0..<3]) == [0x21, 0xF9, 0x04])
        #expect((opaqueFrame[3] >> 2) & 0x07 == 1 && opaqueFrame[3] & 0x01 == 0)
        #expect((clearFrame[3] >> 2) & 0x07 == 2 && clearFrame[3] & 0x01 == 1)
        #expect(opaqueFrame[4] == 4 && opaqueFrame[5] == 0, "遅延 4/100 秒")
        // 頭は繰り返し無限の印を持つ
        let header = [UInt8](GIFBlocks.header(width: 4, height: 1))
        #expect(Array(header[0..<6]) == Array("GIF89a".utf8))
        #expect(String(decoding: header[16..<27], as: UTF8.self) == "NETSCAPE2.0")
        #expect(Array(header[27..<32]) == [0x03, 0x01, 0x00, 0x00, 0x00])
    }

    // MARK: - MP4 (完了条件 2)

    @Test("MP4 は H.264 で、枚数と刻みが --fps と --seconds のとおり")
    func anMP4IsH264WithTheRequestedFramesAndRate() async throws {
        try await withDirectoryAsync { directory in
            let path = directory.appendingPathComponent("loop.mp4").path
            write(.h264, to: path, frames: 30, fps: 30) { picture($0 % 12, width: 64, height: 48) }

            #expect(MovieFile.videoSampleCount(atPath: path) == 30)
            let asset = AVURLAsset(url: URL(fileURLWithPath: path))
            let track = try #require(try await asset.loadTracks(withMediaType: .video).first)
            let descriptions = try await track.load(.formatDescriptions)
            let codec = try #require(descriptions.first).mediaSubType
            #expect(codec == .h264, "H.264 ではない: \(codec)")
            let size = try await track.load(.naturalSize)
            #expect(Int(size.width) == 64 && Int(size.height) == 48)
            let duration = try await asset.load(.duration).seconds
            #expect(abs(duration - 1.0) < 0.01, "長さが \(duration) 秒")
            let rate = try await track.load(.nominalFrameRate)
            #expect(abs(rate - 30) < 0.5, "刻みが \(rate) fps")
            // 容れ物は MP4 (ProRes の .mov ではない)
            let head = try Data(contentsOf: URL(fileURLWithPath: path)).prefix(12)
            #expect(String(decoding: head.dropFirst(4), as: UTF8.self).hasPrefix("ftyp"))
        }
    }

    /// H.264 は奇数の大きさを書けるかを測った結果で、書けない大きさは書き損じとして名乗る。
    @Test("奇数の大きさの MP4 を書く (書けなければ書き損じとして名乗る)")
    func anOddSizeIsWrittenOrNamed() async throws {
        try await withDirectoryAsync { directory in
            let path = directory.appendingPathComponent("odd.mp4").path
            let writer = MovieWriter(path: path, frameRate: 25, format: .h264)
            for index in 0..<5 {
                writer.write(
                    picture(index, width: 63, height: 47), frame: index + 1, time: Double(index) / 25)
            }
            writer.finish()
            let failure = writer.takeFailure()
            print("MEASURED odd-size (63x47) MP4: \(failure ?? "written")")
            if failure == nil {
                #expect(MovieFile.videoSampleCount(atPath: path) == 5)
            } else {
                #expect(!(failure ?? "").isEmpty)
            }
        }
    }

    /// 辺が 1 の絵を H.264 の書き手へ渡すと、OS の書き手は成功を返したまま 0 バイトを書く (#3223)。
    /// 書き損じとして、渡した大きさと下限を名乗り、0 バイトのファイルを残さない。
    @Test("辺が 1 の MP4 は、大きさと下限を名乗る書き損じになり、0 バイトのファイルを残さない。辺が 2 なら書ける")
    func aSideOfOnePixelIsNamedNotWrittenEmpty() async throws {
        try await withDirectoryAsync { directory in
            for (width, height) in [(64, 1), (1, 64), (1, 1), (2, 1)] {
                let path = directory.appendingPathComponent("thin-\(width)x\(height).mp4").path
                let writer = MovieWriter(path: path, frameRate: 25, format: .h264)
                for index in 0..<5 {
                    writer.write(
                        picture(index, width: width, height: height), frame: index + 1,
                        time: Double(index) / 25)
                }
                writer.finish()
                let failure = try #require(writer.takeFailure(), "\(width)x\(height): 書き損じを名乗っていない")
                #expect(failure.contains("Could not"), "\(width)x\(height): \(failure)")
                #expect(failure.contains("\(width)x\(height)"), "\(width)x\(height): 大きさを名乗っていない: \(failure)")
                #expect(!FileManager.default.fileExists(atPath: path), "\(width)x\(height): 行き先にファイルが残っている")
            }
            // 陰性対照: 辺が 2 なら、頼んだ枚数の MP4 が書ける
            for (width, height) in [(64, 2), (2, 2)] {
                let path = directory.appendingPathComponent("ok-\(width)x\(height).mp4").path
                write(.h264, to: path, frames: 5, fps: 25) { picture($0, width: width, height: height) }
                #expect(MovieFile.videoSampleCount(atPath: path) == 5, "\(width)x\(height)")
            }
        }
    }

    /// H.264 の `MovieFile` に 1 枚書いて閉じる。`closedEmpty` なら、書き手が「済んだ」と言った直後に行き先を
    /// 空のファイルに差し替える。閉じるのが断られたらその失敗を返す。
    private nonisolated static func closeOneFrame(
        path: String, image: DisplayImage, closedEmpty: Bool
    ) async -> MovieWriteFailure? {
        do {
            let file = try MovieFile(path: path, width: 64, height: 48, frameRate: 25, format: .h264)
            if closedEmpty {
                file.readsForTesting.closed = { FileManager.default.createFile(atPath: $0, contents: Data()) }
            }
            try await file.append(image, at: 0)
            try await file.finish(lastFrameAt: 0)
            return nil
        } catch {
            return error
        }
    }

    /// 閉じた後の確かめが `finish` を通って働く (#3223)。本物の書き手では 0 バイトを作れない (辺の下限が先に
    /// 断る) ので、書き手が「済んだ」と言った直後に行き先を 0 バイトへ切り詰めて、「済んだと言ったのに空」を
    /// 差し込む (``MovieFile/ReadsForTesting/closed``)。`finish` の確かめの呼びを外すと、この検査が赤くなる。
    @Test("閉じた後に空だったファイルは、finish が書き損じとして名乗り、行き先に残さない。空でなければ通す")
    func finishNamesAFileThatClosedEmpty() async throws {
        try await withDirectoryAsync { directory in
            // 陰性対照: 差し込まなければ、同じ手順で閉じられる
            let good = directory.appendingPathComponent("good.mp4").path
            let image = picture(0, width: 64, height: 48)
            #expect(await Self.closeOneFrame(path: good, image: image, closedEmpty: false) == nil)
            #expect(MovieFile.videoSampleCount(atPath: good) == 1)

            let path = directory.appendingPathComponent("hollow.mp4").path
            let failure = await Self.closeOneFrame(path: path, image: image, closedEmpty: true)
            guard case .writeFailed(let failedPath, let reason)? = failure else {
                Issue.record("空のファイルを成功として閉じた (または書き損じ以外で断った): \(String(describing: failure))")
                return
            }
            #expect(failedPath == path)
            #expect(reason.contains("64x48"), "\(reason)")
            #expect(reason.contains("without writing anything"), "\(reason)")
            #expect(!FileManager.default.fileExists(atPath: path), "空のファイルが行き先に残っている")
        }
    }

    /// 閉じた後の確かめの判断 (``MovieFile/hollowReason(atPath:width:height:limitSeconds:read:)``)。
    @Test("閉じた後の確かめは、0 バイト・映像のトラックが無いもの・標本が無いものを中身が無いとし、書けた動画は通す")
    func aHollowFileIsNamedAfterClosing() async throws {
        try await withDirectoryAsync { directory in
            let empty = directory.appendingPathComponent("empty.mp4").path
            FileManager.default.createFile(atPath: empty, contents: Data())
            let reason = try #require(await MovieFile.hollowReason(atPath: empty, width: 64, height: 1))
            #expect(reason.contains("64x1"), "\(reason)")

            // 本物の書けた動画は、1 枚でも複数枚でも通す (トラックの長さと標本の大きさを安く読むだけ)
            for frames in [1, 5] {
                let good = directory.appendingPathComponent("good-\(frames).mp4").path
                write(.h264, to: good, frames: frames, fps: 25) { picture($0, width: 64, height: 48) }
                #expect(await MovieFile.readClosedFile(atPath: good) == .hasSamples, "\(frames) 枚")
                #expect(await MovieFile.hollowReason(atPath: good, width: 64, height: 48) == nil, "\(frames) 枚")
            }
            if MovieFile.isAvailable {
                let mov = directory.appendingPathComponent("good.mov").path
                write(.proRes4444, to: mov, frames: 1, fps: 25) { picture($0, width: 64, height: 48) }
                #expect(await MovieFile.hollowReason(atPath: mov, width: 64, height: 48) == nil)
            }

            // 読めないだけのファイルは断らない (書き手が済んだと言ったものを、読み込みの都合で書き損じにしない)
            let garbage = directory.appendingPathComponent("garbage.mp4").path
            FileManager.default.createFile(atPath: garbage, contents: Data("not a movie".utf8))
            #expect(await MovieFile.hollowReason(atPath: garbage, width: 64, height: 48) == nil)

            // トラックの無いもの・トラックはあっても標本の無いものは断る。本物の書き手では作れない
            // (標本の無いトラックは「読めない」になる) ので、読む手を差し替える
            let filled = directory.appendingPathComponent("filled.mp4").path
            FileManager.default.createFile(atPath: filled, contents: Data("x".utf8))
            let noTrack = await MovieFile.hollowReason(
                atPath: filled, width: 64, height: 48, read: { _ in .noVideoTrack })
            #expect(try #require(noTrack).contains("without a video track"))
            let noSamples = await MovieFile.hollowReason(
                atPath: filled, width: 64, height: 48, read: { _ in .noSamples })
            #expect(try #require(noSamples).contains("no frames"))
            #expect(await MovieFile.hollowReason(atPath: filled, width: 64, height: 48, read: { _ in .hasSamples }) == nil)
        }
    }

    /// 終わらない読みを差し込んだ確かめの結果と、**確かめの中で**測った経過時間。測るのを隔離の外 (この関数) で
    /// 済ませるのは、main actor 上の検査が他の検査に塞がれた待ちを、期限の遅れと取り違えないため。
    private nonisolated static func hollowReasonOfAReadThatNeverEnds(
        path: String, limitSeconds: Double
    ) async -> (reason: String?, elapsed: Duration) {
        let clock = ContinuousClock()
        let started = clock.now
        // 期限を越えたものは、標本が無いと答えるものでも断らない (答えは捨てられる)
        let reason = await MovieFile.hollowReason(
            atPath: path, width: 64, height: 48, limitSeconds: limitSeconds,
            read: { _ in
                try? await Task.sleep(for: .seconds(60))
                return .noSamples
            })
        return (reason, clock.now - started)
    }

    /// 読みが期限を越えたら、確かめられなかったとして断らずに通す (#3223)。遅いボリュームで詰まっても、書き手の
    /// 閉じる期限に当たらない。読みは終わらないものを差し込み、期限の外で待たないことを経過時間で見る。
    @Test("閉じた後の確かめは、読みが期限を越えたら断らずに通し、読みの終わりを待たない")
    func aSlowReadIsNotWaitedForNorBlamed() async throws {
        try await withDirectoryAsync { directory in
            let path = directory.appendingPathComponent("slow.mp4").path
            FileManager.default.createFile(atPath: path, contents: Data("x".utf8))
            let outcome = await Self.hollowReasonOfAReadThatNeverEnds(path: path, limitSeconds: 0.2)
            #expect(outcome.reason == nil, "期限を越えた読みで断った: \(outcome.reason ?? "")")
            #expect(outcome.elapsed < .seconds(10), "読みの終わりを待った: \(outcome.elapsed)")
        }
    }

    // MARK: - 綴り・fps の規則 (完了条件 1〜4)

    @Test("配る形の綴りと、番号の場所を持つ連番との分かれ目")
    func destinationRules() {
        #expect(FrameRecorder.distribution(of: "loop.gif") == .gif)
        #expect(FrameRecorder.distribution(of: "out/Loop.MP4") == .mp4)
        // 番号の場所を持つ綴りは、今までどおり連番
        #expect(FrameRecorder.distribution(of: "out/frame-####.gif") == nil)
        #expect(FrameRecorder.distribution(of: "motion.mov") == nil)
        #expect(FrameRecorder.distribution(of: "photo.png") == nil)
        // `beginRecord` は配る形を受けない (枚数を知る `mokume render` だけが頼む)
        #expect(!FrameRecorder.accepts("loop.gif"))
        #expect(FrameRecorder.acceptsForRender("loop.gif") && FrameRecorder.acceptsForRender("loop.mp4"))
        #expect(FrameRecorder.acceptsForRender("motion.mov"))
        #expect(!FrameRecorder.acceptsForRender("loop.webm"))
    }

    @Test("GIF は 100 を割り切る fps だけ、MP4 は .mov と同じ刻みの上限まで")
    func rateRules() {
        for rate in [1, 2, 4, 5, 10, 20, 25, 50, 100] {
            #expect(FrameRecorder.acceptsForRender("loop.gif", frameRate: rate), "\(rate)")
        }
        for rate in [3, 24, 30, 60, 120] {
            #expect(!FrameRecorder.acceptsForRender("loop.gif", frameRate: rate), "\(rate)")
        }
        #expect(FrameRecorder.acceptsForRender("loop.mp4", frameRate: 60))
        #expect(FrameRecorder.acceptsForRender("loop.mp4", frameRate: FrameRecorder.movieFrameRateLimit))
        #expect(!FrameRecorder.acceptsForRender("loop.mp4", frameRate: FrameRecorder.movieFrameRateLimit + 1))
        #expect(RenderRequest(frameRate: 25, frameCount: 100, destination: "/tmp/loop.gif") != nil)
        #expect(RenderRequest(frameRate: 60, frameCount: 240, destination: "/tmp/loop.gif") == nil)
        #expect(RenderRequest(frameRate: 60, frameCount: 240, destination: "/tmp/loop.mp4") != nil)
    }

    // MARK: - 書き出し先の確かめ

    @Test("GIF・MP4 の書き出し先は、枚数まで確かめる")
    func outputCheckCountsGIFAndMP4() throws {
        try withDirectory { directory in
            let start = Date().addingTimeInterval(-5)
            let gif = directory.appendingPathComponent("a.gif").path
            write(.gif, to: gif, frames: 6, fps: 25) { picture($0) }
            let mp4 = directory.appendingPathComponent("a.mp4").path
            write(.h264, to: mp4, frames: 6, fps: 25) { picture($0, width: 64, height: 48) }

            let okGIF = try #require(RenderRequest(frameRate: 25, frameCount: 6, destination: gif))
            let okMP4 = try #require(RenderRequest(frameRate: 25, frameCount: 6, destination: mp4))
            #expect(okGIF.inspectOutput(since: start) == nil)
            #expect(okMP4.inspectOutput(since: start) == nil)
            let moreGIF = try #require(RenderRequest(frameRate: 25, frameCount: 7, destination: gif))
            let moreMP4 = try #require(RenderRequest(frameRate: 25, frameCount: 7, destination: mp4))
            #expect(moreGIF.inspectOutput(since: start) == .frames(found: 6))
            #expect(moreMP4.inspectOutput(since: start) == .frames(found: 6))
            let none = try #require(
                RenderRequest(
                    frameRate: 25, frameCount: 2,
                    destination: directory.appendingPathComponent("none.gif").path))
            #expect(none.inspectOutput(since: start) == .notWritten)
        }
    }

    /// 非同期の検査から使う一時ディレクトリ。
    private func withDirectoryAsync(_ body: (URL) async throws -> Void) async throws {
        let directory = try TestScratch.directory("mokume-distribution")
        defer { try? FileManager.default.removeItem(at: directory) }
        try await body(directory)
    }
}
