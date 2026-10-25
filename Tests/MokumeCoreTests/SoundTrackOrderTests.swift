// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import AVFoundation
import Foundation
import Synchronization
import Testing

@testable import MokumeCore

/// 書き手が音の窓を絵に合わせて書く順と、書き損じの扱い (#3125)。符号化器も GPU も要らない — 書く先を差し替えて、
/// 書き手が渡した順を記録する。
@Suite("書き出しの音声トラック (書く順と書き損じ)")
struct SoundTrackOrderTests {
    /// 書き手が渡したものを記録する出口。`failingPictures`・`failingSounds` は、その番目 (0 始まり) の呼び出しで投げる。
    nonisolated final class Recording: MovieOutput, @unchecked Sendable {
        enum Event: Equatable {
            case picture(frame: Int)
            case sound(frame: Int)
        }

        private let lock = Mutex<[Event]>([])
        private let calls = Mutex<(pictures: Int, sounds: Int)>((0, 0))
        let failingPictures: Set<Int>
        let failingSounds: Set<Int>
        let frameRate: Int

        init(frameRate: Int = 60, failingPictures: Set<Int> = [], failingSounds: Set<Int> = []) {
            self.frameRate = frameRate
            self.failingPictures = failingPictures
            self.failingSounds = failingSounds
        }

        var events: [Event] { lock.withLock { $0 } }

        func append(_ image: DisplayImage, at time: Double) async throws(MovieWriteFailure) {
            let index = calls.withLock { state -> Int in
                defer { state.pictures += 1 }
                return state.pictures
            }
            if failingPictures.contains(index) {
                throw .writeFailed(path: "fake.mov", reason: "picture \(index) refused")
            }
            // 時刻は (フレーム - 1) / fps で渡されるので、フレームの番号へ戻す
            lock.withLock { $0.append(.picture(frame: Int((time * Double(frameRate)).rounded()) + 1)) }
        }

        func appendSound(_ window: SoundWindow) async throws(MovieWriteFailure) {
            let index = calls.withLock { state -> Int in
                defer { state.sounds += 1 }
                return state.sounds
            }
            if failingSounds.contains(index) {
                throw .writeFailed(path: "fake.mov", reason: "sound \(index) refused")
            }
            lock.withLock { $0.append(.sound(frame: window.frame)) }
        }

        func finish(lastFrameAt time: Double) async throws(MovieWriteFailure) {}
    }

    private func image() -> DisplayImage {
        DisplayImage(width: 4, height: 4, bytes: [UInt8](repeating: 0, count: 64))
    }

    private func window(_ frame: Int, frameRate: Int = 60) -> SoundWindow {
        SoundWindow(frame: frame, frameRate: frameRate)
    }

    /// `output` へ書く書き手。
    private func writer(_ output: Recording, frameRate: Int = 60) -> MovieWriter {
        MovieWriter(path: "fake.mov", frameRate: frameRate, open: { _, _ in output })
    }

    private func picture(_ writer: MovieWriter, frame: Int, frameRate: Int = 60) {
        writer.write(image(), frame: frame, time: Double(frame - 1) / Double(frameRate))
    }

    private func sounds(_ events: [Recording.Event]) -> [Int] {
        events.compactMap { if case .sound(let frame) = $0 { frame } else { nil } }
    }

    // MARK: - 先行を抑える

    @Test("音の窓が絵より何フレームも先に届いても、書き手は絵が書けた分より 2 フレームまでしか先へ書かない。全部の窓が順に書かれる")
    func soundRunsAheadOfThePicturesByAtMostTheLead() {
        let output = Recording()
        let movie = writer(output)
        // 窓 0〜9 が先に積まれ、絵が遅れて 1〜10 と届く (先行 10 フレーム)
        for frame in 0..<10 { movie.writeSound(window(frame)) }
        for frame in 1...10 { picture(movie, frame: frame) }
        // 最後の絵より先の窓 (絵が落ちた末尾) は、閉じるときに書かれる
        for frame in 10..<13 { movie.writeSound(window(frame)) }
        movie.finish()
        #expect(movie.takeFailure() == nil)

        let events = output.events
        // 全部の窓が、番号の順に、1 つずつ書かれた
        #expect(sounds(events) == Array(0..<13), "\(sounds(events))")
        // 窓 w は、絵 w - 1 が書けた後に書かれる (窓 w - 1 が絵 w と同じ時刻なので、2 フレームぶんの先行)
        var picturesSoFar = 0
        for event in events {
            switch event {
            case .picture: picturesSoFar += 1
            case .sound(let frame) where frame < 10:
                #expect(
                    picturesSoFar >= frame - 1,  // 先行は 2 フレームまで
                    "窓 \(frame) が、絵が \(picturesSoFar) 枚しか書けていない時点で書かれた (先行が soundLead を越えた)")
            case .sound: break
            }
        }
        // 絵の窓が先に書かれず、絵と窓が交互に並ぶ (全部の窓が絵の前に書かれていない)
        #expect(events.first == .picture(frame: 1))
    }

    // MARK: - 最初の絵の書き損じ

    @Test("最初の絵が書けなかったら、音声トラックの書き込みを止める。窓は欠けも重なりもなく書かれず、後の絵は書かれる")
    func aFailedFirstPictureStopsTheSound() {
        let output = Recording(failingPictures: [0])
        let movie = writer(output)
        for frame in 0..<5 { movie.writeSound(window(frame)) }
        for frame in 1...6 { picture(movie, frame: frame) }
        movie.finish()

        let events = output.events
        #expect(sounds(events).isEmpty, "最初の絵が書けなかったのに、古い窓が後から書かれた: \(sounds(events))")
        #expect(events == (2...6).map { .picture(frame: $0) })
        // 書き損じは絵の側が名乗っている
        #expect(movie.takeFailure()?.contains("picture 0 refused") == true)
    }

    @Test("ファイルを開くのが最初の絵で断られても、同じに音声トラックを止める")
    func aFailedOpenStopsTheSound() {
        let calls = Mutex(0)
        let output = Recording()
        let movie = MovieWriter(
            path: "fake.mov", frameRate: 60,
            open: { _, _ in
                let call = calls.withLock { state -> Int in
                    defer { state += 1 }
                    return state
                }
                if call == 0 { throw MovieWriteFailure.destinationUnavailable(path: "fake.mov") }
                return output
            })
        for frame in 0..<5 { movie.writeSound(window(frame)) }
        for frame in 1...6 { picture(movie, frame: frame) }
        movie.finish()
        #expect(sounds(output.events).isEmpty)
        #expect(output.events == (2...6).map { .picture(frame: $0) })
        #expect(movie.takeFailure() != nil)
    }

    // MARK: - 窓の途中の書き損じ

    @Test("窓の書き込みが途中で断られたら、音声トラックを止める。同じ窓を二重に書かず、後の窓も書かない。書き損じは 1 度名乗る")
    func aFailedWindowStopsTheSoundWithoutRepeats() {
        // 窓の 3 番目の書き込みを断る
        let output = Recording(failingSounds: [2])
        let movie = writer(output)
        for frame in 0..<8 { movie.writeSound(window(frame)) }
        for frame in 1...9 { picture(movie, frame: frame) }
        movie.finish()

        let events = output.events
        #expect(sounds(events) == [0, 1], "断られた窓より後ろが書かれた、または窓が二重に書かれた: \(sounds(events))")
        // 映像は最後まで書かれる
        #expect(events.filter { if case .picture = $0 { true } else { false } }.count == 9)
        #expect(movie.takeFailure()?.contains("sound 2 refused") == true)
    }

    // MARK: - 0 標本の窓

    @Test("fps が標本化率を越えて窓が 0 標本になるフレームがあっても、書き損じにならず、継ぎ目が詰まって全標本が書かれる")
    func zeroSampleWindowsAreSkipped() async throws {
        guard MovieFile.isAvailable else { return }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("mokume-sound-zero-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("fast.mov").path

        let rate = 90_000
        let frames = 40
        // 90000 fps・48000 Hz: ⌊N·48000/90000⌋ は 1 フレームおきにしか進まない (0 標本の窓がある)
        let counts = (0..<frames).map { SoundWindow.count(ofFrame: $0, frameRate: rate) }
        try #require(counts.contains(0), "0 標本の窓が無い")
        let total = counts.reduce(0, +)
        let movie = MovieWriter(path: path, frameRate: rate)
        for frame in 0..<frames {
            var window = SoundWindow(frame: frame, frameRate: rate)
            for index in 0..<window.count {
                window.left[index] = 0.25
                window.right[index] = -0.25
            }
            movie.writeSound(window)
            movie.write(
                DisplayImage(width: 64, height: 48, bytes: [UInt8](repeating: 40, count: 64 * 48 * 4)),
                frame: frame + 1, time: Double(frame) / Double(rate))
        }
        movie.finish()
        #expect(movie.takeFailure() == nil, "0 標本の窓が書き損じになった")

        let asset = AVURLAsset(url: URL(fileURLWithPath: path))
        let track = try #require(try await asset.loadTracks(withMediaType: .audio).first)
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(
            track: track,
            outputSettings: [
                AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMBitDepthKey: 32,
                AVLinearPCMIsFloatKey: true, AVLinearPCMIsBigEndianKey: false,
                AVLinearPCMIsNonInterleaved: false,
            ])
        reader.add(output)
        try #require(reader.startReading())
        var read = 0
        while let buffer = output.copyNextSampleBuffer() { read += CMSampleBufferGetNumSamples(buffer) }
        #expect(read == total, "\(read) 標本 (期待 \(total))")
    }
}
