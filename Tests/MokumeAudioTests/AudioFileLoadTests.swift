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
/// **数は定数を写さず、数字で書く** (#2285)。2^24 = 16,777,216、塊 (``AudioFile/readChunk``) は 2^20 = 1,048,576。
///
/// **大きなファイル (2^24 標本前後・約 67 MB) は、この Suite の中で 1 つずつ書く** (直列)。2^24 を越えるファイルは
/// 直しを外すと赤になる検査に要る 1 つ (2^24 + 1 標本) だけで、`SoundFile.frames` (#3705) の検査もそれを使う。
/// 塊の境目は、塊を 2 つまたぐ小さなファイルで見る。
@Suite("音声ファイルの読み込み: 長さ", .serialized)
struct AudioFileLoadTests {
    /// `channels` チャンネル・`frames` 標本の 32 bit 浮動小数のファイルを書く。標本の値は `value(channel, frame)`。
    ///
    /// **32 bit 浮動小数で書く** — 16 bit の整数で書いたファイルは、変換の経路を通るので 1 回の `read` で 2^24 を
    /// 超えて読めてしまい、切れる不具合を再現しない (処理の形式のままのファイルだけが切れる)。
    private func write(
        channels: Int, frames: Int, pathExtension: String = "wav", value: (Int, Int) -> Float
    ) throws -> URL {
        let url = TestScratch.path("mokume-long", pathExtension: pathExtension)
        let layout = try #require(
            AVAudioChannelLayout(
                layoutTag: kAudioChannelLayoutTag_DiscreteInOrder | AudioChannelLayoutTag(channels)))
        let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: 48_000, interleaved: false, channelLayout: layout)
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        let piece = 1 << 20
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(piece)))
        let data = try #require(buffer.floatChannelData)
        var written = 0
        while written < frames {
            let count = min(piece, frames - written)
            buffer.frameLength = AVAudioFrameCount(count)
            for channel in 0..<channels {
                for frame in 0..<count { data[channel][frame] = value(channel, written + frame) }
            }
            try file.write(from: buffer)
            written += count
        }
        return url
    }

    /// 終わりの標本だけ 0.75、ほかは 0.25 のモノラル。
    private func writeMono(frames: Int) throws -> URL {
        try write(channels: 1, frames: frames) { _, frame in frame == frames - 1 ? 0.75 : 0.25 }
    }

    @Test("2^24 を超えるファイルも、標本の数が長さと一致し、終わりの標本まで読める。SoundFile.frames も同じ数")
    func longFileIsReadToTheEnd() throws {
        let frames = 16_777_217
        let url = try writeMono(frames: frames)
        defer { try? FileManager.default.removeItem(at: url) }
        let buffer = try AudioFile.load(url, path: "long.wav")
        #expect(Int(buffer.frameLength) == 16_777_217)
        let data = try #require(buffer.floatChannelData)[0]
        #expect(data[frames - 1] == 0.75, "終わりの標本: \(data[frames - 1])")
        #expect(data[frames - 2] == 0.25)

        // #3705: frames は読み込んだ標本の数そのもので、duration × sampleRate の丸めに引きずられない
        let song = SoundFile(name: "long.wav", buffer: buffer, owner: nil, flow: nil, warn: { _ in })
        #expect(song.frames == 16_777_217)
        let approximate = song.duration * song.sampleRate
        #expect(Int(approximate) != 16_777_217, "掛け直しでも合うなら、この長さは検査にならない: \(approximate)")
    }

    @Test("2^24 ちょうどと、それより短いファイルは、1 回で読んだときと 1 標本も変わらない", arguments: [16_777_216, 1000])
    func shortFilesAreUnchanged(_ frames: Int) throws {
        let url = try writeMono(frames: frames)
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

    @Test(
        "塊を 2 つまたぐ 2 ch・4 ch のファイルも、チャンネルごとの値が先頭・塊の境目の前後・終わりで書いたとおり",
        arguments: [2, 4])
    func multichannelAcrossChunks(_ channels: Int) throws {
        // 2^20 + 51,424 標本。塊 (2^20) を 1 つ読み切り、2 つ目の塊が途中で終わる
        let frames = 1_100_000
        // チャンネルと標本の番号から決まる値。2^24 未満の整数なので単精度で正確に表せる
        let value: (Int, Int) -> Float = { channel, frame in Float(channel * 2_000_000 + frame) }
        let url = try write(channels: channels, frames: frames, value: value)
        defer { try? FileManager.default.removeItem(at: url) }
        let buffer = try AudioFile.load(url, path: "multi.wav")
        #expect(Int(buffer.frameLength) == 1_100_000)
        #expect(Int(buffer.format.channelCount) == channels)
        let data = try #require(buffer.floatChannelData)
        for channel in 0..<channels {
            for frame in [0, 1_048_575, 1_048_576, 1_099_999] {
                #expect(
                    data[channel][frame] == value(channel, frame),
                    "チャンネル \(channel) の標本 \(frame): \(data[channel][frame])")
            }
        }
    }

    @Test(
        "見出しの長さより実際が短い (終わりを削った) ファイルは、投げずに読めた所までを返す",
        arguments: ["wav", "caf"])
    func truncatedFileReturnsWhatWasRead(_ pathExtension: String) throws {
        let url = try write(channels: 1, frames: 100_000, pathExtension: pathExtension) { _, frame in Float(frame) }
        defer { try? FileManager.default.removeItem(at: url) }
        // 終わりの 200,000 バイト (50,000 標本) を削る。CAF は見出しに長さ 100,000 を残したままで、残りより多く
        // 求めた read の返し方が OS で違う: macOS 27 では求めた数より少ない 50,000 標本を返し、次の read が終わりの
        // 誤りを投げる。macOS 26 では標本を返さずにいきなり誤りを投げる (CI で unreadable になった。手元の OS では
        // 再現しないので、その返し方は下の `truncatedReaders` で差し替えた読み手を使って確かめる)。WAV は長さを残りから
        // 50,000 と数え直すが、1 回目の read は 49,152 標本しか返さず (macOS 27)、続きは次の read で届く
        let handle = try FileHandle(forUpdating: url)
        let size = try handle.seekToEnd()
        try handle.truncate(atOffset: size - 200_000)
        try handle.close()
        if pathExtension == "caf" {
            #expect(try AVAudioFile(forReading: url).length == 100_000, "見出しの長さが残っていない")
        }
        let buffer = try AudioFile.load(url, path: "cut.\(pathExtension)")
        #expect(buffer.frameLength == 50_000)
        let data = UnsafeBufferPointer(start: try #require(buffer.floatChannelData)[0], count: 50_000)
        #expect(data.elementsEqual((0..<50_000).map(Float.init)))

        // 直す前の読み方 (1 回の read) で読めていた標本は、すべて同じ値で読める。macOS 26 の CAF は 1 回の read が
        // 誤りを投げる (直す前も unreadable だった) ので、読めていた標本は 0 で、比べるものが無い
        let file = try AVAudioFile(forReading: url)
        let once = try #require(
            AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)))
        let before: Int
        do {
            try file.read(into: once)
            before = Int(once.frameLength)
        } catch {
            before = 0
        }
        #expect(before <= 50_000, "1 回の read で読めた数: \(before)")
        let onceData = UnsafeBufferPointer(start: try #require(once.floatChannelData)[0], count: before)
        #expect(onceData.elementsEqual(data.prefix(before)))
    }

    /// `read` の返し方を差し替えた読み手。見出しの長さは 100,000 で、実際にあるのは `actual` 標本。標本の値は番号。
    /// 誤りを投げた後は位置をでたらめ (実際の終わり) に動かすので、読み直す側が位置を戻さないと値がずれる。
    final class FakeReader {
        enum Style: Sendable {
            /// macOS 26: 残りより多く求めると、標本を返さずに終わりの誤りを投げる
            case throwsWhenAskedPastEnd
            /// macOS 27: 残りより多く求めると読めた分を返し、残りが 0 のときだけ終わりの誤りを投げる
            case returnsShortThenThrows
            /// いつも終わりの誤りを投げる
            case alwaysThrows
            /// `actual` の所から先は、終わり以外の誤りを投げる (途中で壊れたファイル)
            case brokenAfterActual
        }

        let style: Style
        let actual: Int
        var position = 0
        var reads = 0

        init(_ style: Style, actual: Int) {
            self.style = style
            self.actual = actual
        }

        static let endOfFile = NSError(domain: NSOSStatusErrorDomain, code: Int(kAudioFileEndOfFileError))
        static let broken = NSError(domain: NSOSStatusErrorDomain, code: Int(kAudioFileInvalidFileError))

        func seek(_ to: AVAudioFramePosition) { position = Int(to) }

        func read(into piece: AVAudioPCMBuffer, count: AVAudioFrameCount) throws {
            reads += 1
            let remaining = actual - position
            let wanted = Int(count)
            let failure: NSError? =
                switch style {
                case .throwsWhenAskedPastEnd: wanted > remaining ? Self.endOfFile : nil
                case .returnsShortThenThrows: remaining <= 0 ? Self.endOfFile : nil
                case .alwaysThrows: Self.endOfFile
                case .brokenAfterActual: wanted > remaining ? Self.broken : nil
                }
            if let failure {
                piece.frameLength = 0
                position = actual
                throw failure
            }
            let given = min(wanted, remaining)
            let data = piece.floatChannelData![0]
            for frame in 0..<given { data[frame] = Float(position + frame) }
            piece.frameLength = AVAudioFrameCount(given)
            position += given
        }
    }

    private func readWith(_ reader: FakeReader) throws -> (ok: Bool, buffer: AVAudioPCMBuffer) {
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 100_000))
        let ok = AudioFile.readAll(
            length: 100_000, into: buffer, seek: reader.seek, read: { try reader.read(into: $0, count: $1) })
        return (ok, buffer)
    }

    @Test(
        "見出しより短いファイルは、read が終わりの手前をどう返しても (OS ごとの返し方)、読めた所までを書いた値で返す",
        arguments: [FakeReader.Style.throwsWhenAskedPastEnd, .returnsShortThenThrows], [50_000, 1, 99_999])
    func truncatedReaders(_ style: FakeReader.Style, _ actual: Int) throws {
        let reader = FakeReader(style, actual: actual)
        let (ok, buffer) = try readWith(reader)
        #expect(ok)
        #expect(Int(buffer.frameLength) == actual)
        let data = UnsafeBufferPointer(start: try #require(buffer.floatChannelData)[0], count: Int(buffer.frameLength))
        #expect(data.elementsEqual((0..<actual).map(Float.init)))
        // 半分ずつ詰めるので、read の回数は長さの桁 (2 を底に) の数倍に収まる
        #expect(reader.reads < 80, "read の回数: \(reader.reads)")
    }

    @Test("1 標本も読めずに終わりの誤りを投げ続ける読み手は、読めない (unreadable)")
    func alwaysThrowingReaderIsUnreadable() throws {
        let (ok, _) = try readWith(FakeReader(.alwaysThrows, actual: 50_000))
        #expect(!ok)
    }

    @Test("途中から終わり以外の誤りを投げる読み手は、1 標本ずつにしても読めなければ、読めた所があっても unreadable")
    func brokenReaderIsUnreadable() throws {
        let (ok, _) = try readWith(FakeReader(.brokenAfterActual, actual: 50_000))
        #expect(!ok)
    }

    @Test("器の容量は UInt32 に収まる長さだけ。2^32 標本以上は落ちずに nil (読み込みは unreadable)")
    func capacityRejectsLengthsBeyondUInt32() {
        #expect(AudioFile.capacity(forLength: 1) == 1)
        #expect(AudioFile.capacity(forLength: 4_294_967_295) == 4_294_967_295)
        #expect(AudioFile.capacity(forLength: 4_294_967_296) == nil)
        #expect(AudioFile.capacity(forLength: 8_589_934_593) == nil)
    }
}
