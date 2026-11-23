// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import AVFAudio
import Foundation
import Testing

@testable import MokumeAudio
@testable import MokumeCore
import MokumeTestSupport

/// 3 チャンネル以上の音のファイルが、2 チャンネルの出力でどう鳴るか (#4069)。
///
/// 配置を名乗らない WAV (録音機・DAW の書き出しの形。`AVAudioFile` は番号だけの並び `DiscreteInOrder` として開く) は、
/// 1・2 チャンネル目が左右として鳴り、3 チャンネル目から先は鳴らない。配置が左・右・中央の WAV は、混ぜる節が中央を
/// 左右へ配るまま。WAV は検査の中でヘッダを手で組み、`SoundFile` が使うのと同じ経路 (``AudioFile/load(_:path:)`` →
/// ``FilePlayer`` → 機材に出さない流れの書き出し) で鳴らして、元のチャンネルごとに出力の左右の最大値を見る。
@Suite("多チャンネルのファイルの鳴り方", .serialized)
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
    static func writeWAV(
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

    /// 配置を名乗らない `channels` チャンネルのファイルで、元のチャンネル `active` だけを鳴らしたときに聞こえるはずの
    /// 左右の最大 (1 チャンネル目は左、2 チャンネル目は右、3 チャンネル目から先は無音)。
    static func expectedUnplaced(active: Int) -> (left: Float, right: Float) {
        switch active {
        case 0: (0.5, 0)
        case 1: (0, 0.5)
        default: (0, 0)
        }
    }

    /// 左右の最大が `expected` と、`tolerance` の内で同じか。
    static func matches(
        _ heard: (left: Float, right: Float), _ expected: (left: Float, right: Float), tolerance: Float = 1e-4
    ) -> Bool {
        abs(heard.left - expected.left) < tolerance && abs(heard.right - expected.right) < tolerance
    }

    private static func peak(_ samples: [Float]) -> Float { samples.map { abs($0) }.max() ?? 0 }

    /// `buffer` を、`SoundFile` と同じ経路で 2 チャンネルの出力へ鳴らして、聞こえた左右の最大を返す。
    static func heard(_ buffer: AVAudioPCMBuffer, pan: Float = 0) throws -> (left: Float, right: Float) {
        let flow = try SoundFlow.offline(sampleRate: 48_000, channels: 2, maximumFrames: 4096)
        let player = try #require(FilePlayer(flow: flow, buffer: buffer))
        player.pan = pan
        player.play(from: 0, looping: false)
        let heard = try renderChannels(flow, Int(buffer.frameLength))
        player.leave()
        #expect(heard.count == 2)
        return (peak(heard[0]), peak(heard[1]))
    }

    /// `url` を読んで鳴らす。読んだチャンネルの数と長さはファイルのまま (2 に減らさない)。
    private static func heard(_ url: URL, channels: Int, pan: Float = 0) throws -> (left: Float, right: Float) {
        let buffer = try AudioFile.load(url, path: url.lastPathComponent)
        #expect(Int(buffer.format.channelCount) == channels)
        #expect(buffer.frameLength == 4800)
        return try heard(buffer, pan: pan)
    }

    private static func withDirectory(_ body: (URL) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("mokume-multichannel-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try body(directory)
    }

    @Test(
        "配置を名乗らない 3・4・6 チャンネルの WAV は、1 チャンネル目が左・2 チャンネル目が右に同じ大きさで鳴り、3 チャンネル目から先は鳴らない",
        arguments: [Layout.plain, .extensibleNoMask], [3, 4, 6])
    func unplacedFilePlaysTheFirstTwoChannelsAsLeftAndRight(layout: Layout, channels: Int) throws {
        try Self.withDirectory { directory in
            for active in 0..<channels {
                let url = directory.appendingPathComponent("\(layout.rawValue)-\(channels)-\(active).wav")
                try Self.writeWAV(to: url, channels: channels, active: active, layout: layout)
                let heard = try Self.heard(url, channels: channels)
                let expected = Self.expectedUnplaced(active: active)
                #expect(
                    Self.matches(heard, expected),
                    "\(layout.rawValue) \(channels) ch の \(active + 1) チャンネル目: 左 \(heard.left) / 右 \(heard.right)")
            }
        }
    }

    @Test("配置が 左・右・中央 の 3 チャンネルの WAV は、中央が左右へ配られるまま鳴る")
    func placedFileKeepsItsLayout() throws {
        try Self.withDirectory { directory in
            let expected: [(left: Float, right: Float)] = [(0.5, 0), (0, 0.5), (0.3536, 0.3536)]
            for active in 0..<3 {
                let url = directory.appendingPathComponent("lrc-\(active).wav")
                try Self.writeWAV(to: url, channels: 3, active: active, layout: .extensibleLRC)
                let heard = try Self.heard(url, channels: 3)
                #expect(
                    Self.matches(heard, expected[active], tolerance: 1e-3),
                    "\(active + 1) チャンネル目: 左 \(heard.left) / 右 \(heard.right)")
            }
        }
    }

    @Test("1・2 チャンネルの WAV の鳴り方は変わらない", arguments: [Layout.plain, .extensibleNoMask])
    func monoAndStereoFilesAreUnchanged(layout: Layout) throws {
        try Self.withDirectory { directory in
            let mono = directory.appendingPathComponent("\(layout.rawValue)-1.wav")
            try Self.writeWAV(to: mono, channels: 1, active: 0, layout: layout)
            let heardMono = try Self.heard(mono, channels: 1)
            #expect(Self.matches(heardMono, (0.5, 0.5)), "1 ch: 左 \(heardMono.left) / 右 \(heardMono.right)")
            for active in 0..<2 {
                let url = directory.appendingPathComponent("\(layout.rawValue)-2-\(active).wav")
                try Self.writeWAV(to: url, channels: 2, active: active, layout: layout)
                let heard = try Self.heard(url, channels: 2)
                #expect(
                    Self.matches(heard, Self.expectedUnplaced(active: active)),
                    "2 ch の \(active + 1) チャンネル目: 左 \(heard.left) / 右 \(heard.right)")
            }
        }
    }

    @Test("配置を名乗らない 3 チャンネルの WAV の定位は、先頭の 2 チャンネルのバランスとして掛かる")
    func panBalancesTheFirstTwoChannelsOfAnUnplacedFile() throws {
        try Self.withDirectory { directory in
            // 左へ振ると右 (2 チャンネル目) が消え、右へ振ると左 (1 チャンネル目) が消える
            let cases: [(pan: Float, expected: [(left: Float, right: Float)])] = [
                (-1, [(0.5, 0), (0, 0), (0, 0)]),
                (1, [(0, 0), (0, 0.5), (0, 0)]),
            ]
            for (pan, expected) in cases {
                for active in 0..<3 {
                    let url = directory.appendingPathComponent("pan-\(pan)-\(active).wav")
                    try Self.writeWAV(to: url, channels: 3, active: active, layout: .plain)
                    let heard = try Self.heard(url, channels: 3, pan: pan)
                    #expect(
                        Self.matches(heard, expected[active]),
                        "pan \(pan) の \(active + 1) チャンネル目: 左 \(heard.left) / 右 \(heard.right)")
                }
            }
        }
    }

    /// チャンネルごとの説明 (`UseChannelDescriptions`) で `labels` を名乗る配置。
    static func describedLayout(_ labels: [AudioChannelLabel]) throws -> AVAudioChannelLayout {
        let offset = try #require(MemoryLayout<AudioChannelLayout>.offset(of: \.mChannelDescriptions))
        let size = offset + labels.count * MemoryLayout<AudioChannelDescription>.stride
        let raw = UnsafeMutableRawPointer.allocate(
            byteCount: max(size, MemoryLayout<AudioChannelLayout>.size), alignment: MemoryLayout<AudioChannelLayout>.alignment)
        defer { raw.deallocate() }
        raw.initializeMemory(as: UInt8.self, repeating: 0, count: max(size, MemoryLayout<AudioChannelLayout>.size))
        let layout = raw.assumingMemoryBound(to: AudioChannelLayout.self)
        layout.pointee.mChannelLayoutTag = kAudioChannelLayoutTag_UseChannelDescriptions
        layout.pointee.mNumberChannelDescriptions = UInt32(labels.count)
        let descriptions = (raw + offset).assumingMemoryBound(to: AudioChannelDescription.self)
        for (index, label) in labels.enumerated() { descriptions[index].mChannelLabel = label }
        return AVAudioChannelLayout(layout: layout)
    }

    /// `layout` の器で、元のチャンネル `active` だけを 0.5 にしたもの。
    static func buffer(_ layout: AVAudioChannelLayout, active: Int) throws -> AVAudioPCMBuffer {
        let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channelLayout: layout)
        let made = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 2000))
        made.frameLength = 2000
        let data = try #require(made.floatChannelData)
        for channel in 0..<Int(format.channelCount) {
            for index in 0..<2000 { data[channel][index] = channel == active ? 0.5 : 0 }
        }
        return made
    }

    @Test("番号だけを名乗る配置 (2 チャンネルの DiscreteInOrder・どれも Discrete の札の説明) も、先頭の 2 チャンネルが左右に鳴る")
    func everyDiscreteLayoutPlaysTheFirstTwoChannels() throws {
        let layouts: [(name: String, layout: AVAudioChannelLayout)] = [
            ("DiscreteInOrder 2", try #require(AVAudioChannelLayout(layoutTag: kAudioChannelLayoutTag_DiscreteInOrder | 2))),
            (
                "Discrete の札 3",
                try Self.describedLayout([kAudioChannelLabel_Discrete_0, kAudioChannelLabel_Discrete_1, kAudioChannelLabel_Discrete])
            ),
        ]
        for (name, layout) in layouts {
            for active in 0..<Int(layout.channelCount) {
                let heard = try Self.heard(try Self.buffer(layout, active: active))
                #expect(
                    Self.matches(heard, Self.expectedUnplaced(active: active)),
                    "\(name) の \(active + 1) チャンネル目: 左 \(heard.left) / 右 \(heard.right)")
            }
        }
    }

    @Test("位置を 1 つでも名乗る配置は、名乗らない配置と見なさない")
    func layoutsNamingAPositionAreNotUnplaced() throws {
        let lrc = try #require(AVAudioChannelLayout(layoutTag: kAudioChannelLayoutTag_MPEG_3_0_A))
        let mixed = try Self.describedLayout([
            kAudioChannelLabel_Discrete_0, kAudioChannelLabel_Right, kAudioChannelLabel_Discrete_2,
        ])
        let discrete = try #require(AVAudioChannelLayout(layoutTag: kAudioChannelLayoutTag_DiscreteInOrder | 3))
        #expect(!FilePlayer.isUnplaced(AVAudioFormat(standardFormatWithSampleRate: 48_000, channelLayout: lrc)))
        #expect(!FilePlayer.isUnplaced(AVAudioFormat(standardFormatWithSampleRate: 48_000, channelLayout: mixed)))
        #expect(FilePlayer.isUnplaced(AVAudioFormat(standardFormatWithSampleRate: 48_000, channelLayout: discrete)))
        // 1 チャンネルは配置に依らず左右へ配る (別の道)
        let mono = try #require(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1))
        #expect(!FilePlayer.isUnplaced(mono))
    }
}

/// `setup()` で検査が渡した手続きを走らせるだけのスケッチ (自分の静的な置き場を持ち、他の suite と共有しない)。
final class MultichannelSketch: Sketch {
    nonisolated(unsafe) static var onSetup: (MultichannelSketch) throws -> Void = { _ in }
    init() {}
    var settings: SketchSettings { SketchSettings(width: 8, height: 8) }
    func setup() throws { try Self.onSetup(self) }
    func draw() { background(0, 0, 0) }
}

/// ``MultichannelFileLayoutTests`` と同じ WAV を、`SoundFile` の `play()` を通して鳴らす。`pan(_:)` を通しても、
/// 配置を名乗らないファイルは先頭の 2 チャンネルが左右に鳴る。走っているスケッチの中で回すので GPU を要する。
@Suite(
    "多チャンネルのファイルの鳴り方 (SoundFile を通す)",
    .serialized,
    .enabled(
        if: RenderDevice.isAvailable,
        "この世代のコマンド構造に対応した GPU が無い実行環境ではスキップする")
)
struct MultichannelSoundFileTests {
    private static let perFrame = 800

    /// `url` を `SoundFile` にして、`pan` を渡して `play()` し、4 フレームぶん描かせて出力の左右の最大を返す。
    private func heard(_ url: URL, pan: Float?) throws -> (left: Float, right: Float) {
        let flow = try SoundFlow.offline(sampleRate: 48_000, channels: 2, maximumFrames: 4096)
        var sound: SoundFile?
        MultichannelSketch.onSetup = { sketch in
            let loaded = try AudioFile.load(url, path: url.lastPathComponent)
            let made = SoundFile(name: url.lastPathComponent, buffer: loaded, owner: sketch, flow: flow)
            sketch.attach(made)
            if let pan { made.pan(pan) }
            made.play()
            sound = made
        }
        let runtime = try SketchRuntime(sketch: MultichannelSketch(), gpu: try RenderDevice(), clock: nil)
        var left: [Float] = []
        var right: [Float] = []
        for _ in 0..<4 {
            try runtime.advance()
            let both = try renderBoth(flow, Self.perFrame)
            left += both.left
            right += both.right
        }
        runtime.closePlugins()
        // チャンネルの数はファイルのまま (2 に減らさない)
        #expect(sound?.channels == Int(try AudioFile.load(url, path: "").format.channelCount))
        func peak(_ samples: [Float]) -> Float { samples.map { abs($0) }.max() ?? 0 }
        return (peak(left), peak(right))
    }

    @Test("SoundFile の play() を通しても、配置を名乗らない 3・6 チャンネルは先頭の 2 チャンネルが左右に鳴り、左右中央の対照は変わらない")
    func soundFilePlaysTheFirstTwoChannelsOfAnUnplacedFile() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("mokume-multichannel-sf-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        // (書き方, チャンネル数, 鳴らす元のチャンネル, 定位, 期待する左右の最大)
        let cases: [(MultichannelFileLayoutTests.Layout, Int, Int, Float?, (left: Float, right: Float))] = [
            (.plain, 3, 0, nil, (0.5, 0)), (.plain, 3, 1, nil, (0, 0.5)), (.plain, 3, 2, nil, (0, 0)),
            (.plain, 3, 0, -1, (0.5, 0)), (.plain, 3, 1, -1, (0, 0)),
            (.plain, 6, 0, nil, (0.5, 0)), (.plain, 6, 1, nil, (0, 0.5)), (.plain, 6, 5, nil, (0, 0)),
            (.extensibleLRC, 3, 2, nil, (0.3536, 0.3536)),
        ]
        for (layout, channels, active, pan, expected) in cases {
            let url = directory.appendingPathComponent("\(layout.rawValue)-\(channels)-\(active).wav")
            try MultichannelFileLayoutTests.writeWAV(to: url, channels: channels, active: active, layout: layout)
            let result = try heard(url, pan: pan)
            let panName = pan.map { String($0) } ?? "既定"
            #expect(
                MultichannelFileLayoutTests.matches(result, expected, tolerance: 1e-3),
                "\(layout.rawValue) \(channels) ch の \(active + 1) チャンネル目 (pan \(panName)): 左 \(result.left) / 右 \(result.right)")
        }
    }
}
