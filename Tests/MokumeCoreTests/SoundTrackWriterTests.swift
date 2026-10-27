// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import AVFoundation
import Foundation
import MokumeTestSupport
import Testing

@testable import MokumeCore

/// 書き出しの音声トラックの、書き手と撮る係の側 (#3125)。GPU を要さない。スケッチを走らせずに、窓と絵を直に渡す。
@Suite(
    "書き出しの音声トラック (書き手と撮る係)",
    .enabled(if: MovieFile.isAvailable, "この機械には ProRes 4444 の符号化器が無い"))
struct SoundTrackWriterTests {
    private func image(_ level: UInt8) -> DisplayImage {
        DisplayImage(width: 64, height: 48, bytes: [UInt8](repeating: level, count: 64 * 48 * 4))
    }

    /// 全部が `value` の窓。
    private func window(frame: Int, frameRate: Int = 60, value: Float = 0.25) -> SoundWindow {
        var window = SoundWindow(frame: frame, frameRate: frameRate)
        for index in 0..<window.count {
            window.left[index] = value
            window.right[index] = -value
        }
        return window
    }

    private func withDirectory(_ body: (URL) async throws -> Void) async throws {
        let directory = try TestScratch.directory("mokume-sound-writer")
        defer { try? FileManager.default.removeItem(at: directory) }
        try await body(directory)
    }

    // MARK: - 窓の式

    @Test("窓の先頭は、フレームの番号から直に求める。144 fps・48000 Hz の 144 フレームで 48000 標本ちょうど")
    func windowStartsComeFromTheFrameNumber() {
        // 丸めて足すと 47952 になる
        #expect(144 * (48_000 / 144) == 47_952)
        let total = (0..<144).reduce(0) { $0 + SoundWindow.count(ofFrame: $1, frameRate: 144) }
        #expect(total == 48_000)
        // 窓は継ぎ目なく並ぶ (前の窓の先頭 + 長さ = 次の窓の先頭)
        for frame in 0..<400 {
            #expect(
                SoundWindow.start(ofFrame: frame, frameRate: 144)
                    + SoundWindow.count(ofFrame: frame, frameRate: 144)
                    == SoundWindow.start(ofFrame: frame + 1, frameRate: 144))
        }
        #expect(SoundWindow.start(ofFrame: 30, frameRate: 60) == 24_000)
        #expect(SoundWindow.start(ofFrame: 90, frameRate: 60) == 72_000)
        // 整数で数えた ⌊N·48000/fps⌋ とも一致する (浮動小数の秒を通さない)
        for frame in 0..<400 {
            #expect(SoundWindow.start(ofFrame: frame, frameRate: 144) == Int(Double(frame) * 48_000 / 144))
        }
    }

    // MARK: - 書き手

    @Test("窓を窓ごとに渡しても、音声トラックの標本は窓の継ぎ目で欠けも重なりも無い")
    func windowsAreWrittenSeamlessly() async throws {
        try await withDirectory { directory in
            let path = directory.appendingPathComponent("sound.mov").path
            let writer = MovieWriter(path: path, frameRate: 144)
            for frame in 0..<144 {
                // 音は先に積む (絵より 1 フレーム先)
                writer.writeSound(window(frame: frame, frameRate: 144, value: 0.25))
                if frame > 0 { writer.write(image(40), frame: frame, time: Double(frame - 1) / 144) }
            }
            writer.write(image(40), frame: 144, time: 143.0 / 144)
            writer.finish()
            #expect(writer.takeFailure() == nil)

            let asset = AVURLAsset(url: URL(fileURLWithPath: path))
            let tracks = try await asset.loadTracks(withMediaType: .audio)
            #expect(tracks.count == 1)
            let reader = try AVAssetReader(asset: asset)
            let output = AVAssetReaderTrackOutput(
                track: try #require(tracks.first),
                outputSettings: [
                    AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMBitDepthKey: 32,
                    AVLinearPCMIsFloatKey: true, AVLinearPCMIsBigEndianKey: false,
                    AVLinearPCMIsNonInterleaved: false,
                ])
            reader.add(output)
            try #require(reader.startReading())
            var frames = 0
            var wrong = 0
            while let buffer = output.copyNextSampleBuffer() {
                let count = CMSampleBufferGetNumSamples(buffer)
                frames += count
                guard let block = CMSampleBufferGetDataBuffer(buffer) else { continue }
                var length = 0
                var pointer: UnsafeMutablePointer<Int8>?
                CMBlockBufferGetDataPointer(
                    block, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &length,
                    dataPointerOut: &pointer)
                guard let pointer else { continue }
                let floats = UnsafeBufferPointer(
                    start: UnsafeRawPointer(pointer).assumingMemoryBound(to: Float.self), count: length / 4)
                for index in stride(from: 0, to: floats.count, by: 2)
                where floats[index] != 0.25 || floats[index + 1] != -0.25 { wrong += 1 }
            }
            #expect(frames == 48_000, "\(frames) 標本")
            #expect(wrong == 0)
        }
    }

    @Test("音声の書き損じ (標本の束を作れない窓) は、映像と同じ道で名乗られ、撮る係の「書き出しに穴がある」に立つ")
    func aFailedSoundWindowIsReportedLikeAFailedPicture() async throws {
        try await withDirectory { directory in
            let recorder = FrameRecorder(frameRate: 60)
            recorder.beginRecord(directory.appendingPathComponent("broken.mov").path, at: 1)
            recorder.decideSound(hasSources: true, fixedClock: true)
            #expect(recorder.soundTrack == .carrying(frameRate: 60))
            let movie = try #require(recorder.recordingMovie)

            recorder.writeSound(window(frame: 0))
            movie.write(image(40), frame: 1, time: 0)
            // 左右の長さが違う窓は、標本の束を作れない
            var broken = window(frame: 1)
            broken.right.removeLast()
            recorder.writeSound(broken)
            movie.write(image(60), frame: 2, time: 1.0 / 60)
            try #require(
                pollUntilSettled(within: 10) {
                    recorder.absorbOutcomes()
                    return recorder.failure != nil
                },
                "音声の書き損じが 10 秒待っても決着しない")
            #expect(recorder.failure?.contains("Could not write") == true)
            #expect(recorder.failure?.contains("sample buffer") == true, "\(recorder.failure ?? "")")
            #expect(recorder.hasFailedToWrite, "書き出しの穴が立たない — mokume render の終了コードに現れない")
            recorder.close()
        }
    }

    // MARK: - 載せるかの決まり

    @Test("固定の時計の .mov は、音源が居れば載せ、居なければ載せない。音源が居ても決めた後は変わらない")
    func theDecisionIsMadeOnce() async throws {
        try await withDirectory { directory in
            let carrying = FrameRecorder(frameRate: 60)
            carrying.beginRecord(directory.appendingPathComponent("a.mov").path, at: 1)
            #expect(carrying.soundTrack == .undecided)
            #expect(carrying.decideSound(hasSources: true, fixedClock: true))
            // 決めた後は聞き直さない
            #expect(!carrying.decideSound(hasSources: false, fixedClock: true))
            #expect(carrying.soundTrack == .carrying(frameRate: 60))
            carrying.close()

            let bare = FrameRecorder(frameRate: 60)
            bare.beginRecord(directory.appendingPathComponent("b.mov").path, at: 1)
            #expect(!bare.decideSound(hasSources: false, fixedClock: true))
            #expect(bare.soundTrack == .declined)
            #expect(bare.warnings.message(for: .soundNotCarried) == nil, "音源が居なければ名乗らない")
            // 録りの途中で足された音源は、トラックが無いので載せず、1 度だけ名乗る
            bare.noteLateSound()
            bare.noteLateSound()
            #expect(bare.warnings.count { if case .soundAddedLate = $0 { true } else { false } } == 1)
            bare.close()
        }
    }

    @Test("載せない録り (実時間の時計の .mov・MP4・GIF・連番) に音源が居れば、載せないことを 1 度だけ名乗る")
    func recordingsThatCarryNoSoundSayWhy() async throws {
        try await withDirectory { directory in
            @MainActor func carries(_ pattern: String, fixedClock: Bool = true) -> FrameRecorder {
                // GIF は 1 枚の遅延が 1/100 秒の整数倍になる fps (50) だけ受ける
                let recorder = FrameRecorder(frameRate: 50)
                recorder.beginRecord(
                    directory.appendingPathComponent(pattern).path, at: 1,
                    rendering: pattern.hasSuffix(".mp4") || pattern.hasSuffix(".gif") ? 50 : nil)
                recorder.decideSound(hasSources: true, fixedClock: fixedClock)
                return recorder
            }
            for (pattern, fixedClock) in [("w.mov", false), ("v.mp4", true), ("g.gif", true), ("f-###.png", true)] {
                let recorder = carries(pattern, fixedClock: fixedClock)
                #expect(recorder.soundTrack == .declined, "\(pattern)")
                #expect(recorder.warnings.message(for: .soundNotCarried)?.contains("does not carry sound") == true, "\(pattern)")
                #expect(
                    recorder.warnings.count { if case .soundNotCarried = $0 { true } else { false } } == 1)
                // 載せないので、窓を渡しても何も書かれない
                recorder.writeSound(window(frame: 0))
                recorder.close()
            }
        }
    }
}
