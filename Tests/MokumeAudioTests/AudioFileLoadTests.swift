// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import AVFAudio
import Foundation
import MokumeTestSupport
import Testing

@testable import MokumeAudio

/// 音声ファイルを終わりまで読むこと (#3969)。`AVAudioFile.read(into:)` は 1 回に 2^24 標本までしか読まないので、
/// それより長いファイルの終わりが黙って切れていた。GPU も音の機材も要らない。
///
/// **数は定数を写さず、数字で書く** (#2285)。2^24 = 16,777,216。
@Suite("音声ファイルの読み込み: 長さ", .serialized)
struct AudioFileLoadTests {
    /// 終わりの標本の値。ほかの標本 (0.25) と見分ける。
    private static let last: Float = 0.75

    /// `frames` 標本のモノラルの 32 bit 浮動小数の WAV を書く。終わりの標本だけ ``last``。
    ///
    /// **32 bit 浮動小数で書く** — 16 bit の整数で書いたファイルは、変換の経路を通るので 1 回の `read` で 2^24 を
    /// 超えて読めてしまい、切れる不具合を再現しない (処理の形式のままのファイルだけが切れる)。
    private func writeWAV(frames: Int) throws -> URL {
        let url = TestScratch.path("mokume-long", pathExtension: "wav")
        let format = try #require(
            AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 1, interleaved: false))
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        let piece = 1 << 20
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(piece)))
        var written = 0
        while written < frames {
            let count = min(piece, frames - written)
            buffer.frameLength = AVAudioFrameCount(count)
            let data = try #require(buffer.floatChannelData)[0]
            data.update(repeating: 0.25, count: count)
            if written + count == frames { data[count - 1] = Self.last }
            try file.write(from: buffer)
            written += count
        }
        return url
    }

    @Test(
        "2^24 を超えるファイルも、標本の数が長さと一致し、終わりの標本まで読める",
        arguments: [16_777_217, 16_777_218, 33_554_435])
    func longFilesAreReadToTheEnd(_ frames: Int) throws {
        let url = try writeWAV(frames: frames)
        defer { try? FileManager.default.removeItem(at: url) }
        let buffer = try AudioFile.load(url, path: "long.wav")
        #expect(Int(buffer.frameLength) == frames)
        let data = try #require(buffer.floatChannelData)[0]
        #expect(data[frames - 1] == Self.last, "終わりの標本: \(data[frames - 1])")
        #expect(data[frames - 2] == 0.25)
        #expect(AudioFile.mono(buffer).count == frames)
    }

    @Test("2^24 ちょうどと、それより短いファイルは、1 回で読んだときと 1 標本も変わらない", arguments: [16_777_216, 1000])
    func shortFilesAreUnchanged(_ frames: Int) throws {
        let url = try writeWAV(frames: frames)
        defer { try? FileManager.default.removeItem(at: url) }
        let loaded = try AudioFile.load(url, path: "short.wav")
        // 直す前の読み方 (1 回の read) で読んだもの
        let file = try AVAudioFile(forReading: url)
        let once = try #require(
            AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)))
        try file.read(into: once)
        #expect(loaded.frameLength == once.frameLength)
        #expect(Int(loaded.frameLength) == frames)
        let a = UnsafeBufferPointer(start: try #require(loaded.floatChannelData)[0], count: frames)
        let b = UnsafeBufferPointer(start: try #require(once.floatChannelData)[0], count: frames)
        #expect(a.elementsEqual(b))
    }

    @Test("見出しの長さまで読めない (途中で切れた) ファイルは、読めた分を返さず unreadable を投げる")
    func truncatedFileIsUnreadable() throws {
        // CAF は見出しに長さを持つ。終わりを削ると、見出しの長さに標本が届かない
        let url = TestScratch.path("mokume-cut", pathExtension: "caf")
        defer { try? FileManager.default.removeItem(at: url) }
        let format = try #require(
            AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 1, interleaved: false))
        do {
            let file = try AVAudioFile(forWriting: url, settings: format.settings)
            let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 100_000))
            buffer.frameLength = 100_000
            try #require(buffer.floatChannelData)[0].update(repeating: 0.25, count: 100_000)
            try file.write(from: buffer)
        }
        let handle = try FileHandle(forUpdating: url)
        let size = try handle.seekToEnd()
        try handle.truncate(atOffset: size - 200_000)
        try handle.close()
        #expect(try AVAudioFile(forReading: url).length == 100_000, "見出しの長さが残っていない")
        #expect(throws: AudioFailure.unreadable(path: "cut.caf")) {
            try AudioFile.load(url, path: "cut.caf")
        }
    }
}
