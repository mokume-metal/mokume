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
    /// `signal` を渡すと、`active` のチャンネルは定数の代わりにその標本列 (16 bit に丸める) になり、長さもその数になる。
    static func writeWAV(
        to url: URL, channels: Int, active: Int, layout: Layout, frames: Int = 4800, signal: [Float]? = nil
    ) throws {
        func le16(_ value: Int) -> [UInt8] { [UInt8(value & 0xFF), UInt8((value >> 8) & 0xFF)] }
        func le32(_ value: Int) -> [UInt8] { le16(value & 0xFFFF) + le16((value >> 16) & 0xFFFF) }
        let frames = signal?.count ?? frames
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
        for frame in 0..<frames {
            let sound = signal.map { le16(Int(($0[frame] * 32_767).rounded())) } ?? loud
            for channel in 0..<channels { data += channel == active ? sound : silent }
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
    ///
    /// - Parameter unplaced: 開いたファイルの処理の形式を、配置を名乗らない形 (``FilePlayer/isUnplaced(_:)``) と
    ///   見なすはずか。検査の前提 (手で組んだ WAV を `AVAudioFile` がどの配置で開くか) をここで断言する。
    private static func heard(
        _ url: URL, channels: Int, unplaced: Bool, pan: Float = 0
    ) throws -> (left: Float, right: Float) {
        let buffer = try AudioFile.load(url, path: url.lastPathComponent)
        #expect(Int(buffer.format.channelCount) == channels)
        #expect(buffer.frameLength == 4800)
        let tag = buffer.format.channelLayout.map { String($0.layoutTag, radix: 16) } ?? "nil"
        #expect(FilePlayer.isUnplaced(buffer.format) == unplaced, "\(url.lastPathComponent) の配置のタグ 0x\(tag)")
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
                let heard = try Self.heard(url, channels: channels, unplaced: true)
                let expected = Self.expectedUnplaced(active: active)
                #expect(
                    Self.matches(heard, expected),
                    "\(layout.rawValue) \(channels) ch の \(active + 1) チャンネル目: 左 \(heard.left) / 右 \(heard.right)")
            }
        }
    }

    /// 中央を左右へ配る倍率は OS のミキサーが決める (macOS 26・27 で約 0.7071) ので、決め打たない。
    @Test("配置が 左・右・中央 の 3 チャンネルの WAV は、左右がそのまま・中央が左右へ等しく配られるまま鳴る")
    func placedFileKeepsItsLayout() throws {
        try Self.withDirectory { directory in
            var heard: [(left: Float, right: Float)] = []
            for active in 0..<3 {
                let url = directory.appendingPathComponent("lrc-\(active).wav")
                try Self.writeWAV(to: url, channels: 3, active: active, layout: .extensibleLRC)
                heard.append(try Self.heard(url, channels: 3, unplaced: false))
            }
            #expect(Self.matches(heard[0], (0.5, 0)), "1 チャンネル目: 左 \(heard[0].left) / 右 \(heard[0].right)")
            #expect(Self.matches(heard[1], (0, 0.5)), "2 チャンネル目: 左 \(heard[1].left) / 右 \(heard[1].right)")
            let centre = heard[2]
            #expect(abs(centre.left - centre.right) < 1e-6, "中央は左右へ等しく: 左 \(centre.left) / 右 \(centre.right)")
            #expect(centre.left > 0.01 && centre.left < 0.5, "中央は鳴り、元の大きさより小さい: \(centre.left)")
        }
    }

    @Test("1・2 チャンネルの WAV の鳴り方は変わらない", arguments: [Layout.plain, .extensibleNoMask])
    func monoAndStereoFilesAreUnchanged(layout: Layout) throws {
        try Self.withDirectory { directory in
            let mono = directory.appendingPathComponent("\(layout.rawValue)-1.wav")
            try Self.writeWAV(to: mono, channels: 1, active: 0, layout: layout)
            let heardMono = try Self.heard(mono, channels: 1, unplaced: false)
            #expect(Self.matches(heardMono, (0.5, 0.5)), "1 ch: 左 \(heardMono.left) / 右 \(heardMono.right)")
            for active in 0..<2 {
                let url = directory.appendingPathComponent("\(layout.rawValue)-2-\(active).wav")
                try Self.writeWAV(to: url, channels: 2, active: active, layout: layout)
                // WAV の 2 チャンネルは配置を持たない形 (nil) で開く — 直しの前から左右に鳴る
                let heard = try Self.heard(url, channels: 2, unplaced: false)
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
                    let heard = try Self.heard(url, channels: 3, unplaced: true, pan: pan)
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

    /// 検査が組む配置の形。`tag` は組んだ `AVAudioChannelLayout` が持つはずのタグ (OS が別のタグへ直していないか)。
    struct Shape: CustomTestStringConvertible, Sendable {
        var name: String
        var tag: AudioChannelLayoutTag
        var labels: [AudioChannelLabel] = []
        var unplaced: Bool
        var testDescription: String { name }

        func layout() throws -> AVAudioChannelLayout {
            if tag == kAudioChannelLayoutTag_UseChannelDescriptions { return try describedLayout(labels) }
            return try #require(AVAudioChannelLayout(layoutTag: tag))
        }
    }

    nonisolated static let shapes: [Shape] = [
        // 位置を名乗らない形
        Shape(name: "DiscreteInOrder 3", tag: kAudioChannelLayoutTag_DiscreteInOrder | 3, unplaced: true),
        Shape(name: "DiscreteInOrder 2", tag: kAudioChannelLayoutTag_DiscreteInOrder | 2, unplaced: true),
        Shape(name: "Unknown 3", tag: kAudioChannelLayoutTag_Unknown | 3, unplaced: true),
        Shape(
            name: "札がどれも Discrete", tag: kAudioChannelLayoutTag_UseChannelDescriptions,
            labels: [kAudioChannelLabel_Discrete_0, kAudioChannelLabel_Discrete_1, kAudioChannelLabel_Discrete],
            unplaced: true),
        Shape(
            name: "札がどれも Unknown", tag: kAudioChannelLayoutTag_UseChannelDescriptions,
            labels: [kAudioChannelLabel_Unknown, kAudioChannelLabel_Unknown, kAudioChannelLabel_Unknown], unplaced: true),
        Shape(
            name: "札がどれも Unused", tag: kAudioChannelLayoutTag_UseChannelDescriptions,
            labels: [kAudioChannelLabel_Unused, kAudioChannelLabel_Unused, kAudioChannelLabel_Unused], unplaced: true),
        Shape(
            name: "札が Discrete・Unknown・Unused", tag: kAudioChannelLayoutTag_UseChannelDescriptions,
            labels: [kAudioChannelLabel_Discrete_0, kAudioChannelLabel_Unknown, kAudioChannelLabel_Unused],
            unplaced: true),
        // 位置を名乗る形
        Shape(name: "Stereo", tag: kAudioChannelLayoutTag_Stereo, unplaced: false),
        Shape(name: "MPEG 3.0 A (L R C)", tag: kAudioChannelLayoutTag_MPEG_3_0_A, unplaced: false),
        Shape(name: "MPEG 5.1 A", tag: kAudioChannelLayoutTag_MPEG_5_1_A, unplaced: false),
        Shape(
            name: "札が Discrete・Right・Discrete", tag: kAudioChannelLayoutTag_UseChannelDescriptions,
            labels: [kAudioChannelLabel_Discrete_0, kAudioChannelLabel_Right, kAudioChannelLabel_Discrete_2],
            unplaced: false),
        Shape(
            name: "札が Left・Right・Unknown", tag: kAudioChannelLayoutTag_UseChannelDescriptions,
            labels: [kAudioChannelLabel_Left, kAudioChannelLabel_Right, kAudioChannelLabel_Unknown], unplaced: false),
    ]

    @Test("配置の形ごとに、位置を名乗らない形かを見分ける (組んだ配置のタグが変わっていないことも見る)", arguments: shapes)
    func isUnplacedTellsEachShape(shape: Shape) throws {
        let layout = try shape.layout()
        #expect(layout.layoutTag == shape.tag, "組んだ配置のタグ 0x\(String(layout.layoutTag, radix: 16))")
        let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channelLayout: layout)
        #expect(format.channelCount >= 2)
        #expect(FilePlayer.isUnplaced(format) == shape.unplaced)
    }

    @Test("配置を持たない 1・2 チャンネルの形式は、名乗らない形と見なさない (1 チャンネルは別の道で左右へ配る)")
    func monoAndPlainStereoFormatsAreNotUnplaced() throws {
        let mono = try #require(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1))
        let stereo = try #require(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2))
        #expect(!FilePlayer.isUnplaced(mono))
        #expect(!FilePlayer.isUnplaced(stereo))
    }

    /// 直す前の版では、このどれも全チャンネルが無音だった (2 チャンネルの `DiscreteInOrder` も)。札がどれも `Unknown` の形
    /// とタグ `Unknown` は直す前から同じ鳴り方なので、直しを見分けない (``isUnplacedTellsEachShape(shape:)`` が見る)。
    @Test(
        "番号だけ・札が Unused だけの配置 (2 チャンネルの DiscreteInOrder を含む) も、先頭の 2 チャンネルが左右に鳴る",
        arguments: shapes.filter {
            $0.unplaced && ($0.tag & 0xFFFF_0000 == kAudioChannelLayoutTag_DiscreteInOrder || $0.labels.contains { $0 != kAudioChannelLabel_Unknown })
        })
    func unplacedLayoutsPlayTheFirstTwoChannels(shape: Shape) throws {
        let layout = try shape.layout()
        for active in 0..<Int(layout.channelCount) {
            let heard = try Self.heard(try Self.buffer(layout, active: active))
            #expect(
                Self.matches(heard, Self.expectedUnplaced(active: active)),
                "\(shape.name) の \(active + 1) チャンネル目: 左 \(heard.left) / 右 \(heard.right)")
        }
    }

    /// 2 チャンネルの節に描く道 (速さ ≠ 1 の読み直し・ループ・途中から・書き出しの音声トラック) でも、配置を持たない
    /// 4 チャンネルの 1 チャンネル目は左だけ・2 チャンネル目は右だけに出て、3・4 チャンネル目は出ない。
    @Test("配置を持たない 4 チャンネルを、速さを変えて・ループで・途中から・書き出しの流れで鳴らしても、先頭の 2 チャンネルだけが左右に出る")
    func unplacedFileKeepsItsChannelsOnEveryPath() throws {
        try Self.withDirectory { directory in
            for active in 0..<4 {
                let url = directory.appendingPathComponent("paths-\(active).wav")
                try Self.writeWAV(to: url, channels: 4, active: active, layout: .plain)
                let buffer = try AudioFile.load(url, path: url.lastPathComponent)
                #expect(FilePlayer.isUnplaced(buffer.format))
                let expected = Self.expectedUnplaced(active: active)
                // (名前, 速さ, 始まり, ループ)
                let paths: [(String, Double, Int, Bool)] = [
                    ("遅く", 0.5, 0, false), ("速く", 2, 0, true), ("ループ", 1, 0, true), ("途中から", 1, 3000, true),
                ]
                for (name, rate, start, looping) in paths {
                    let flow = try SoundFlow.offline(sampleRate: 48_000, channels: 2, maximumFrames: 4096)
                    let player = try #require(FilePlayer(flow: flow, buffer: buffer, rate: rate, kernel: nil))
                    player.play(from: start, looping: looping)
                    let heard = try renderBoth(flow, 9600)
                    player.leave()
                    let peaks = (left: Self.peak(heard.left), right: Self.peak(heard.right))
                    #expect(
                        Self.matches(peaks, expected, tolerance: 1e-3),
                        "\(name) の \(active + 1) チャンネル目: 左 \(peaks.left) / 右 \(peaks.right)")
                }
                // 書き出しの音声トラックを描く流れ
                let flow = try SoundFlow.offline(sampleRate: 48_000, channels: 2, maximumFrames: 4096)
                let player = try #require(FilePlayer(flow: flow, buffer: buffer))
                player.play(from: 0, looping: true)
                let track = TrackFlow(flow: flow, base: 0).advance(to: 9600, keeping: 9600)
                player.leave()
                #expect(track.complete)
                let peaks = (left: Self.peak(track.left), right: Self.peak(track.right))
                #expect(
                    Self.matches(peaks, expected),
                    "書き出しの流れの \(active + 1) チャンネル目: 左 \(peaks.left) / 右 \(peaks.right)")
            }
        }
    }

    // MARK: - 解析とエフェクトへ入る音 (#4167)

    /// `samples` がどれも `expected` と、`tolerance` の内で同じか。
    static func allNear(_ samples: [Float], _ expected: Float, tolerance: Float = 1e-6) -> Bool {
        !samples.isEmpty && samples.allSatisfy { abs($0 - expected) < tolerance }
    }

    /// 配置を名乗らない `channels` チャンネルの器で、元のチャンネル `active` だけを 0.5 にしたときに、解析と
    /// エフェクトへ入るはずの音 (直に鳴る先頭の 2 チャンネルの平均)。
    static func expectedUnplacedMono(active: Int) -> Float { active < 2 ? 0.25 : 0 }

    @Test(
        "配置を名乗らない 3・4・6 チャンネルの WAV の、解析とエフェクトへ入る音は先頭の 2 チャンネルの平均で、3 チャンネル目から先は入らない",
        arguments: [Layout.plain, .extensibleNoMask], [3, 4, 6])
    func unplacedFileAnalysesTheFirstTwoChannels(layout: Layout, channels: Int) throws {
        try Self.withDirectory { directory in
            for active in 0..<channels {
                let url = directory.appendingPathComponent("mono-\(layout.rawValue)-\(channels)-\(active).wav")
                try Self.writeWAV(to: url, channels: channels, active: active, layout: layout)
                let buffer = try AudioFile.load(url, path: url.lastPathComponent)
                #expect(FilePlayer.isUnplaced(buffer.format), "\(url.lastPathComponent) が配置を名乗らない形で開いていない")
                let expected = Self.expectedUnplacedMono(active: active)
                // `loadSound`・`requestSound` が作る解析の標本列
                let mono = AudioFile.mono(buffer)
                #expect(
                    Self.allNear(mono, expected),
                    "\(layout.rawValue) \(channels) ch の \(active + 1) チャンネル目: \(mono.first ?? .nan)")
                // `createAudioIn(file:)` が読む標本列
                let read = try AudioFile.read(url, path: url.lastPathComponent)
                #expect(read.samples == mono)
            }
        }
    }

    @Test("配置が 左・右・中央 の WAV と、1・2 チャンネルの WAV の、解析とエフェクトへ入る音は全チャンネルの平均のまま")
    func placedAndNarrowFilesAnalyseEveryChannel() throws {
        try Self.withDirectory { directory in
            // (書き方, チャンネル数, 鳴らす元のチャンネル, 期待する平均)
            var cases: [(Layout, Int, Int, Float)] = [(.plain, 1, 0, 0.5), (.extensibleNoMask, 1, 0, 0.5)]
            for layout in [Layout.plain, .extensibleNoMask] {
                cases += [(layout, 2, 0, 0.25), (layout, 2, 1, 0.25)]
            }
            cases += (0..<3).map { (.extensibleLRC, 3, $0, 0.5 / 3) }
            for (layout, channels, active, expected) in cases {
                let url = directory.appendingPathComponent("every-\(layout.rawValue)-\(channels)-\(active).wav")
                try Self.writeWAV(to: url, channels: channels, active: active, layout: layout)
                let buffer = try AudioFile.load(url, path: url.lastPathComponent)
                #expect(!FilePlayer.isUnplaced(buffer.format))
                let mono = AudioFile.mono(buffer)
                #expect(
                    Self.allNear(mono, expected),
                    "\(layout.rawValue) \(channels) ch の \(active + 1) チャンネル目: \(mono.first ?? .nan)")
                #expect(try AudioFile.read(url, path: url.lastPathComponent).samples == mono)
            }
        }
    }

    /// 2 チャンネルの名乗らない形 (`DiscreteInOrder 2`) は、先頭の 2 チャンネル = 全チャンネルなので、どちらの読み方でも同じ。
    @Test("配置の形ごとの器で、名乗らない 3 チャンネル以上だけが先頭の 2 チャンネルの平均、ほかは全チャンネルの平均になる", arguments: shapes)
    func monoFollowsTheLayout(shape: Shape) throws {
        let layout = try shape.layout()
        let channels = Int(layout.channelCount)
        for active in 0..<channels {
            let mono = AudioFile.mono(try Self.buffer(layout, active: active))
            let expected = shape.unplaced && channels > 2
                ? Self.expectedUnplacedMono(active: active) : 0.5 / Float(channels)
            #expect(
                Self.allNear(mono, expected),
                "\(shape.name) の \(active + 1) チャンネル目: \(mono.first ?? .nan) (期待 \(expected))")
        }
    }
}

/// ``MultichannelFileLayoutTests`` と同じ形の WAV を、3 つの口 (`loadSound`・`requestSound`・`createAudioIn(file:)`) で
/// 開いて、解析の値とエフェクトに通した出口を見る (#4167)。走っているスケッチの中で回すので GPU を要する。
///
/// 比べる相手は、同じ信号を 1 チャンネル目に持つ 2 チャンネルの WAV (全チャンネルの平均 = 先頭の 2 チャンネルの平均で、
/// 直しの前後で変わらない)。相手と同じ口・同じ回し方で開くので、OS のミキサーの係数や届くフレームを決め打たない。
@Suite(
    "多チャンネルのファイルの解析とエフェクト (3 つの口)",
    .serialized,
    .enabled(
        if: RenderDevice.isAvailable,
        "この世代のコマンド構造に対応した GPU が無い実行環境ではスキップする")
)
struct MultichannelAnalysisTests {
    enum Opener: String, CaseIterable, Sendable {
        case loadSound, requestSound, audioIn
    }

    /// 1 フレームで読んだ解析の値。
    struct Reading: Equatable {
        var level: Float
        var rms: Float
        var spectrum: [Float]
        var waveform: [Float]

        var isSilent: Bool {
            level == 0 && rms == 0 && spectrum.allSatisfy { $0 == 0 } && waveform.allSatisfy { $0 == 0 }
        }
    }

    /// 開いて、鳴らし始めてからのフレームごとの解析の値と、エフェクトの出口 (左右を続けた列)。
    struct Observed {
        var readings: [Reading] = []
        var effect: [Float] = []
    }

    /// 口 `opener` で `path` を開くスケッチ。`SoundFile` は届いた後の最初の `draw()` で `LowPass` に通して
    /// ループさせる (届くフレームが口で違っても、鳴らし始めからの値が揃う)。
    final class Opening: Sketch {
        var settings: SketchSettings { SketchSettings(width: 8, height: 8) }
        var opener = Opener.loadSound
        var path = ""
        var flow: SoundFlow?
        var song: SoundFile?
        var input: AudioIn?
        var filter: LowPass?
        var loading: Task<Void, Never>?
        var arrived = false
        var failure: AudioFailure?
        var readings: [Reading] = []

        init() {}

        func setup() throws {
            switch opener {
            case .loadSound:
                song = try loadSound(path, flow: flow)
                arrived = true
            case .requestSound:
                loading = Task {
                    defer { arrived = true }
                    do { song = try await requestSound(path, flow: flow) } catch { failure = error as? AudioFailure }
                }
            case .audioIn:
                input = try createAudioIn(file: path)
                arrived = true
            }
        }

        func draw() {
            background(0)
            if let song {
                if filter != nil {
                    readings.append(
                        Reading(level: song.level, rms: song.rms, spectrum: song.spectrum, waveform: song.waveform))
                } else {
                    let low = LowPass(stage: SynthStage.stage(for: self, flow: flow))
                    low.process(song)
                    song.loop()
                    filter = low
                }
            } else if let input {
                readings.append(
                    Reading(level: input.level, rms: input.rms, spectrum: input.spectrum, waveform: input.waveform))
            }
        }
    }

    private static let perFrame = 800
    private static let frames = 8
    /// 1 チャンネル目に置く信号 (拍で揺れる和音)。
    private static let signal = Array(chord.prefix(9600))

    /// 開くのを待ってから `frames` フレーム回す。**待つ側が期限を持つ** — 30 秒たっても届かなければ失敗にする。
    private func observe(_ url: URL, _ opener: Opener) async throws -> Observed {
        let flow = opener == .audioIn ? nil : try SoundFlow.offline(sampleRate: 48_000, channels: 2, maximumFrames: 4096)
        let sketch = Opening()
        sketch.opener = opener
        sketch.path = url.path
        sketch.flow = flow
        let runtime = try SketchRuntime(
            sketch: sketch, gpu: try RenderDevice(), clock: nil,
            now: { ProcessInfo.processInfo.systemUptime }, presenceClock: { 0 })
        defer { runtime.closePlugins() }
        let deadline = ContinuousClock.now + .seconds(30)
        var observed = Observed()
        while !sketch.arrived || (opener != .audioIn && sketch.filter == nil) {
            guard ContinuousClock.now < deadline else {
                Issue.record("30 秒たっても \(opener.rawValue) の音が届かない")
                return observed
            }
            // 流れは、届いた音を鳴らし始めるまで描かせない (足されるまで流れは動いていない)
            try runtime.advance()
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(sketch.failure == nil, "失敗: \(String(describing: sketch.failure))")
        // 鳴らし始めた (`createAudioIn(file:)` は開いた) フレームまでの値は見ない
        sketch.readings = []
        for _ in 0..<Self.frames {
            try runtime.advance()
            if let flow {
                let heard = try renderBoth(flow, Self.perFrame)
                observed.effect += heard.left + heard.right
            }
        }
        observed.readings = sketch.readings
        return observed
    }

    @Test(
        "配置を名乗らない 3・6 チャンネルの WAV を 3 つの口で開くと、3 チャンネル目から先だけの音には解析もエフェクトも反応せず、1 チャンネル目だけの音は先頭の 2 チャンネルの平均として届く",
        arguments: Opener.allCases, [3, 6])
    func unplacedFileAnalysesWhatIsHeard(opener: Opener, channels: Int) async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("mokume-multichannel-analysis-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        func write(_ name: String, channels: Int, active: Int) throws -> URL {
            let url = directory.appendingPathComponent("\(name).wav")
            try MultichannelFileLayoutTests.writeWAV(
                to: url, channels: channels, active: active, layout: .plain, signal: Self.signal)
            return url
        }
        let hidden = try write("hidden", channels: channels, active: channels - 1)
        let first = try write("first", channels: channels, active: 0)
        let reference = try write("reference", channels: 2, active: 0)
        #expect(FilePlayer.isUnplaced(try AudioFile.load(hidden, path: "hidden.wav").format))

        // 3 チャンネル目から先だけの音: 解析の値はどれも 0、エフェクトの出口も無音
        let silent = try await observe(hidden, opener)
        #expect(silent.readings.count == Self.frames)
        for (index, reading) in silent.readings.enumerated() {
            #expect(reading.isSilent, "\(opener.rawValue) \(channels) ch の枚 \(index): level \(reading.level) / rms \(reading.rms)")
        }
        if opener != .audioIn {
            #expect(silent.effect.count == 2 * Self.frames * Self.perFrame)
            #expect(silent.effect.allSatisfy { $0 == 0 }, "エフェクトの出口の最大 \(silent.effect.map { abs($0) }.max() ?? 0)")
        }

        // 1 チャンネル目だけの音: 相手 (2 チャンネルの全チャンネルの平均) と同じ値・同じ出口
        let heard = try await observe(first, opener)
        let expected = try await observe(reference, opener)
        #expect(expected.readings.count == Self.frames)
        #expect(expected.readings.contains { !$0.isSilent }, "相手が鳴っていない")
        #expect(heard.readings == expected.readings, "\(opener.rawValue) \(channels) ch の解析の値が相手と違う")
        if opener != .audioIn {
            #expect(expected.effect.contains { $0 != 0 }, "相手のエフェクトの出口が無音")
            #expect(heard.effect.count == expected.effect.count)
            let worst = zip(heard.effect, expected.effect).map { abs($0 - $1) }.max() ?? 1
            #expect(worst < 1e-6, "\(opener.rawValue) \(channels) ch のエフェクトの出口が相手と最大 \(worst) 違う")
        }
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
        ]
        // 対照: 左・右・中央の中央は、SoundFile を通しても、節へ直に鳴らした値 (倍率は OS のミキサーが決める) と同じ
        let centre = directory.appendingPathComponent("lrc-centre.wav")
        try MultichannelFileLayoutTests.writeWAV(to: centre, channels: 3, active: 2, layout: .extensibleLRC)
        let direct = try MultichannelFileLayoutTests.heard(try AudioFile.load(centre, path: "lrc-centre.wav"))
        let throughSoundFile = try heard(centre, pan: nil)
        #expect(direct.left > 0.01 && abs(direct.left - direct.right) < 1e-6)
        #expect(
            MultichannelFileLayoutTests.matches(throughSoundFile, direct, tolerance: 1e-6),
            "中央: SoundFile 左 \(throughSoundFile.left) / 右 \(throughSoundFile.right)、直 \(direct.left) / \(direct.right)")
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
