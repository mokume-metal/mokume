// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import mokume

/// MIDI コントローラの 1 番のつまみ (CC 1) を回すと、円の色相が回る (#1963 の作例 1)。
///
/// **見どころは、つまみを 0 から 127 まで回す間に円の色が 1 周すること。** 赤から始まり、15 フレーム目あたりで
/// 青緑になり、30 フレーム目に赤へ戻る。下の小さな四角は押されている鍵 (ノート) で、C (60) と E (64) が
/// 重なって押され、離される。
///
/// 機材はここでは実機ではなく、`setup()` で作った記録した列を `createMIDI(messages:)` で流している。
/// **どのメッセージが入るかはフレームの数え方だけで決まる**ので、書き出すたびに同じ絵になる
/// ([ADR-0028] 決定 7)。実機で動かすなら、`setup()` の 1 行を差し替えるだけでよい:
///
///     if let first = midiDevices().first { midi = createMIDI(first) }
///
/// [ADR-0028]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0028-external-inputs.md
/// 確認: `--render /tmp/mokume-frames --frames 60` で、`f.0000`・`f.0015`・`f.0030` を目安に、円が
/// 赤・青緑・赤になることを確認。鍵の四角は 5〜24 フレーム目に C、15〜44 フレーム目に E が出る。
final class MIDIAndHue: Sketch {
    var settings: SketchSettings {
        SketchSettings(width: 960, height: 540, title: "midi and hue")
    }

    /// 記録した列の長さ (フレーム)。最後まで行けば最初に戻る。
    private static let length = 60

    private var midi: MIDIPort?
    /// いま押されているノート。
    private var held: Set<Int> = []

    func setup() {
        midi = createMIDI(messages: Self.recorded())
    }

    func draw() {
        for message in midi?.messages ?? [] {
            switch message {
            case .noteOn(_, let note, _): held.insert(note)
            case .noteOff(_, let note, _): held.remove(note)
            default: break
            }
        }
        // つまみの現在値 (0〜1) を色相の 1 周 (0〜360 度) に写す。まだ届いていなければ 0 (赤)
        let hue = (midi?.controlChange(1) ?? 0) * 360

        background(18, 18, 24)
        noStroke()
        fill(color(hue: hue, saturation: 90, brightness: 100))
        circle(width / 2, height / 2 - 20, 200)

        // 押されている鍵。ノートの番号を、左から右へ並べる
        fill(232, 232, 240)
        for note in held.sorted() {
            rect(width / 2 + Float(note - 62) * 24 - 10, height - 80, 20, 20)
        }
    }

    /// つまみ 1 番を 0〜29 フレームで 0 から 127 まで回し (それ以降は触らない)、C を 5〜24 フレーム目、
    /// E を 15〜44 フレーム目に押す。
    private static func recorded() -> [[MIDIMessage]?] {
        (0..<length).map { frame -> [MIDIMessage]? in
            var messages: [MIDIMessage] = []
            if frame < 30 {
                messages.append(.controlChange(channel: 1, controller: 1, value: frame * 127 / 29))
            }
            if frame == 5 { messages.append(.noteOn(channel: 1, note: 60, velocity: 100)) }
            if frame == 15 { messages.append(.noteOn(channel: 1, note: 64, velocity: 90)) }
            if frame == 25 { messages.append(.noteOff(channel: 1, note: 60, velocity: 0)) }
            if frame == 45 { messages.append(.noteOff(channel: 1, note: 64, velocity: 0)) }
            return messages
        }
    }
}
