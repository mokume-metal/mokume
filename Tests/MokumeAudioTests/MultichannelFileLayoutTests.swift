// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import AVFAudio
import Foundation
import Testing

@testable import MokumeAudio

/// 3 チャンネル以上の音のファイルが、2 チャンネルの出力でどう鳴るか (#4069 の再現)。
///
/// 配置のタグを持たない WAV (録音機・DAW の書き出しの形) と、配置が左・右・中央の WAV を検査の中で書き、
/// `SoundFile` が使うのと同じ経路 (``AudioFile/load(_:path:)`` → ``FilePlayer`` → 機材に出さない流れの書き出し)
/// で鳴らして、元のチャンネルごとに、出力の左右の最大値を記録する。
///
/// **固定するのはファイルの事実だけ** (読んだチャンネル数・長さ・書き出しの形)。鳴り方 (無音になるか・どれだけ混ざるか)
/// は OS の返し方に依り、下限の macOS 26 の CI と手元で違いうるので、期待には固定せず `MULTICH` で始まる行に出す。
@Suite("多チャンネルのファイルの鳴り方 (記録)", .serialized)
struct MultichannelFileLayoutTests {
    /// WAV の配置の書き方。
    enum Layout: String, CaseIterable {
        /// 形式の種類 1 (PCM) のまま、配置を持たない。
        case plain
        /// 拡張形式で、チャンネルの割り当て (dwChannelMask) が 0。
        case extensibleNoMask
        /// 拡張形式で、先頭の 3 チャンネルが 左・右・中央 (割り当て 0x7)。
        case extensibleLRC
    }

    /// `channels` チャンネル・48 kHz・16 bit の WAV を `url` へ書く。`active` のチャンネルだけが定数 0.5 で、ほかは 0。
    private static func writeWAV(
        to url: URL, channels: Int, active: Int, layout: Layout, frames: Int = 4800
    ) throws {
        func le16(_ value: Int) -> [UInt8] { [UInt8(value & 0xFF), UInt8((value >> 8) & 0xFF)] }
        func le32(_ value: Int) -> [UInt8] { le16(value & 0xFFFF) + le16((value >> 16) & 0xFFFF) }
        let blockAlign = channels * 2
        let dataSize = frames * blockAlign
        var format: [UInt8]
        switch layout {
        case .plain:
            format = le16(1) + le16(channels) + le32(48_000) + le32(48_000 * blockAlign)
                + le16(blockAlign) + le16(16)
        case .extensibleNoMask, .extensibleLRC:
            let mask = layout == .extensibleLRC ? 0x7 : 0
            // KSDATAFORMAT_SUBTYPE_PCM: 00000001-0000-0010-8000-00AA00389B71
            let subtype: [UInt8] = [
                0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x10, 0x00, 0x80, 0x00, 0x00, 0xAA, 0x00, 0x38, 0x9B, 0x71,
            ]
            format = le16(0xFFFE) + le16(channels) + le32(48_000) + le32(48_000 * blockAlign)
                + le16(blockAlign) + le16(16) + le16(22) + le16(16) + le32(mask) + subtype
        }
        var data: [UInt8] = []
        data.reserveCapacity(dataSize)
        let loud = le16(16_384)
        let silent = le16(0)
        for _ in 0..<frames {
            for channel in 0..<channels { data += channel == active ? loud : silent }
        }
        var bytes: [UInt8] = Array("RIFF".utf8) + le32(4 + 8 + format.count + 8 + dataSize) + Array("WAVE".utf8)
        bytes += Array("fmt ".utf8) + le32(format.count) + format
        bytes += Array("data".utf8) + le32(dataSize) + data
        try Data(bytes).write(to: url)
    }

    /// 出力の左右の、絶対値の最大。
    private struct Heard {
        var left: Float
        var right: Float
    }

    private static func peak(_ samples: [Float]) -> Float { samples.map { abs($0) }.max() ?? 0 }

    /// `url` を、`SoundFile` と同じ経路で 2 チャンネルの出力へ鳴らして、聞こえた最大と、開いたファイルの配置のタグを返す。
    private static func play(_ url: URL, expecting channels: Int) throws -> (Heard, tag: String) {
        let buffer = try AudioFile.load(url, path: url.lastPathComponent)
        #expect(Int(buffer.format.channelCount) == channels)
        #expect(buffer.frameLength == 4800)
        let tag = buffer.format.channelLayout.map { String($0.layoutTag, radix: 16) } ?? "nil"
        let flow = try SoundFlow.offline(sampleRate: 48_000, channels: 2, maximumFrames: 4096)
        let player = try #require(FilePlayer(flow: flow, buffer: buffer))
        player.play(from: 0, looping: false)
        let heard = try renderChannels(flow, 4800)
        #expect(heard.count == 2)
        #expect(heard.allSatisfy { $0.count == 4800 })
        return (Heard(left: peak(heard[0]), right: peak(heard[1])), tag)
    }

    @Test("3・4・6 チャンネルと、配置が 左・右・中央 の対照を鳴らして、元のチャンネルごとの出力の左右の最大を記録する")
    func recordsHowEachSourceChannelIsHeard() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("mokume-multichannel-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let cases: [(layout: Layout, channels: Int)] = [
            (.plain, 3), (.plain, 4), (.plain, 6),
            (.extensibleNoMask, 3), (.extensibleNoMask, 4), (.extensibleNoMask, 6),
            (.extensibleLRC, 3),
        ]
        for (layout, channels) in cases {
            for active in 0..<channels {
                let url = directory.appendingPathComponent("\(layout.rawValue)-\(channels)-\(active).wav")
                try Self.writeWAV(to: url, channels: channels, active: active, layout: layout)
                let (heard, tag) = try Self.play(url, expecting: channels)
                print(
                    "MULTICH layout=\(layout.rawValue) channels=\(channels) source=\(active) "
                        + "tag=0x\(tag) left=\(heard.left) right=\(heard.right)")
            }
        }
    }
}
