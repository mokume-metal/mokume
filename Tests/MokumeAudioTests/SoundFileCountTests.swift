// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import AVFAudio
import Foundation
import MokumeTestSupport
import Testing

@testable import MokumeAudio

/// `SoundFile.channels`・`frames` (#3705)。ファイルを `loadSound(_:)` と同じ読み方 (``AudioFile/load(_:path:)``) で
/// 読み、持ち主のいない `SoundFile` を作る。GPU も音の機材も要らない。
///
/// **数は定数を写さず、数字で書く** (#2285)。
///
/// 2^24 標本を超えるファイルの `frames` は、大きなファイルを 1 つだけ書くために ``AudioFileLoadTests`` の
/// `longFileIsReadToTheEnd` で確かめる (大きなファイルを書く検査を並列に走らせない)。
@Suite("音声ファイルのチャンネルと標本の数", .serialized)
struct SoundFileCountTests {
    /// `channels` チャンネル・`frames` 標本の、32 bit 浮動小数の WAV を書く。チャンネルごとに値を変える。
    private func writeWAV(channels: Int, frames: Int, sampleRate: Double = 48_000) throws -> URL {
        let url = TestScratch.path("mokume-count", pathExtension: "wav")
        let layout = try #require(
            AVAudioChannelLayout(
                layoutTag: kAudioChannelLayoutTag_DiscreteInOrder | AudioChannelLayoutTag(channels)))
        let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, interleaved: false,
            channelLayout: layout)
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        let buffer = try #require(
            AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)))
        buffer.frameLength = AVAudioFrameCount(frames)
        let data = try #require(buffer.floatChannelData)
        for channel in 0..<channels {
            data[channel].update(repeating: 0.1 * Float(channel + 1), count: frames)
        }
        try file.write(from: buffer)
        return url
    }

    /// `url` を読んで、持ち主のいない `SoundFile` にする。
    private func load(_ url: URL) throws -> SoundFile {
        let buffer = try AudioFile.load(url, path: url.lastPathComponent)
        return SoundFile(name: url.lastPathComponent, buffer: buffer, owner: nil, flow: nil, warn: { _ in })
    }

    @Test("48 kHz・10 秒のステレオは channels が 2・frames が 480000、モノラルは channels が 1")
    func stereoAndMono() throws {
        let stereoURL = try writeWAV(channels: 2, frames: 480_000)
        defer { try? FileManager.default.removeItem(at: stereoURL) }
        let stereo = try load(stereoURL)
        #expect(stereo.channels == 2)
        #expect(stereo.frames == 480_000)

        let monoURL = try writeWAV(channels: 1, frames: 1000)
        defer { try? FileManager.default.removeItem(at: monoURL) }
        let mono = try load(monoURL)
        #expect(mono.channels == 1)
        #expect(mono.frames == 1000)
    }

    @Test("3 チャンネル以上は 2 に畳まず、数をそのまま返す (4 チャンネルで 4)")
    func moreThanTwoChannelsAreNotFolded() throws {
        let url = try writeWAV(channels: 4, frames: 4800)
        defer { try? FileManager.default.removeItem(at: url) }
        let song = try load(url)
        #expect(song.channels == 4)
        #expect(song.frames == 4800)
    }

    @Test("外した (close) 後も、足し直した (open) 後も同じ値を返し、投げない")
    func valuesSurviveDetachAndReattach() throws {
        let url = try writeWAV(channels: 2, frames: 9600)
        defer { try? FileManager.default.removeItem(at: url) }
        let song = try load(url)
        song.close()
        #expect(song.channels == 2 && song.frames == 9600)
        try song.open()
        #expect(song.channels == 2 && song.frames == 9600)
    }
}
