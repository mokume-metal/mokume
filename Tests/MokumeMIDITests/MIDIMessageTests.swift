// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation
import Testing

@testable import MokumeMIDI

/// メッセージの型と、UMP の語からの読み。CoreMIDI にも機材にも触れない。
nonisolated struct MIDIMessageTests {
    @Test("3 種のメッセージは JSON へ書いて読み戻すと等しい (#2603 の記録に載せる)")
    func codableRoundTrip() throws {
        let messages: [MIDIMessage] = [
            .noteOn(channel: 1, note: 60, velocity: 100),
            .noteOff(channel: 16, note: 127, velocity: 0),
            .controlChange(channel: 10, controller: 1, value: 64),
        ]
        let data = try JSONEncoder().encode(messages)
        #expect(try JSONDecoder().decode([MIDIMessage].self, from: data) == messages)
    }

    @Test("範囲の端: チャンネルは 1〜16、データは 0〜127 だけが有効")
    func validity() {
        #expect(MIDIMessage.noteOn(channel: 1, note: 0, velocity: 0).isValid)
        #expect(MIDIMessage.noteOn(channel: 16, note: 127, velocity: 127).isValid)
        #expect(!MIDIMessage.noteOn(channel: 0, note: 60, velocity: 100).isValid)
        #expect(!MIDIMessage.noteOn(channel: 17, note: 60, velocity: 100).isValid)
        #expect(!MIDIMessage.noteOff(channel: 1, note: 128, velocity: 0).isValid)
        #expect(!MIDIMessage.controlChange(channel: 1, controller: 1, value: -1).isValid)
        #expect(!MIDIMessage.controlChange(channel: 1, controller: 128, value: 0).isValid)
    }

    // UMP の MIDI 1.0 チャンネルボイス: 0x2 | グループ | 状態 | チャンネル | データ 1 | データ 2

    @Test("ノートオン・ノートオフ・CC を読み、チャンネルは 1 から数える")
    func decodesChannelVoice() {
        let decoded = MIDIUMP.decode([
            0x2092_3C64,  // ch 3 ノートオン 60 速度 100
            0x2082_3C10,  // ch 3 ノートオフ 60 速度 16
            0x20BF_0140,  // ch 16 CC 1 = 64
        ])
        #expect(
            decoded.messages == [
                .noteOn(channel: 3, note: 60, velocity: 100),
                .noteOff(channel: 3, note: 60, velocity: 16),
                .controlChange(channel: 16, controller: 1, value: 64),
            ])
        #expect(decoded.unreadable == 0)
    }

    @Test("速度 0 のノートオンは、ノートオフとして届く")
    func noteOnWithZeroVelocityIsNoteOff() {
        #expect(MIDIUMP.decode([0x2090_3C00]).messages == [.noteOff(channel: 1, note: 60, velocity: 0)])
    }

    @Test("クロック・開始・ユーティリティは数えずに読み飛ばす。ピッチベンド・SysEx は読めないと数える")
    func skipsAndCounts() {
        let decoded = MIDIUMP.decode([
            0x10F8_0000,  // クロック (システムリアルタイム)
            0x0000_0000,  // NOOP
            0x20E0_0040,  // ピッチベンド
            0x20C0_0500,  // プログラムチェンジ
            0x3016_0102, 0x0304_0506,  // SysEx7 (2 語)
            0x20B0_0701,  // CC 7 = 1 (続けて読める)
        ])
        #expect(decoded.messages == [.controlChange(channel: 1, controller: 7, value: 1)])
        #expect(decoded.unreadable == 3)
    }

    @Test("途中で切れた末尾は、読めないと 1 件数えて止まる")
    func truncatedTail() {
        let decoded = MIDIUMP.decode([0x20B0_0101, 0x3016_0102])
        #expect(decoded.messages == [.controlChange(channel: 1, controller: 1, value: 1)])
        #expect(decoded.unreadable == 1)
    }

    @Test("上位のビットは落とす: データは 7 ビット")
    func dataIsSevenBits() {
        // データ 2 の最上位ビットが立っていても 7 ビットだけを読む
        #expect(
            MIDIUMP.decode([0x20B0_01C0]).messages == [.controlChange(channel: 1, controller: 1, value: 64)])
    }
}
