// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import mokume

/// MIDI クロックの拍ごとに、背景の色が切り替わる (#1963 の作例 2)。
///
/// **見どころは、背景が切り替わる間隔が、クロックの間隔についてくること。** 開始の後、1 フレームに 1 クロックを
/// 24 フレーム続けると、24 フレーム目に拍が 0 から 1 になって暗い青から黄へ切り替わる。そこからは 1 フレームに
/// 2 クロックにしてあるので (DAW のテンポを 2 倍にしたのと同じ)、切り替わりは 12 フレームおきに速くなる。
/// 下の 4 つの四角は拍の数え (4 拍で 1 周) で、いまの拍が明るい。
///
/// 機材はここでは実機ではなく、`setup()` で作った記録した列を `createMIDI(messages:)` で流している。
/// **どのメッセージが入るかはフレームの数え方だけで決まる**ので、書き出すたびに同じ絵になる
/// ([ADR-0028] 決定 7)。実機で動かすなら、DAW の「MIDI クロックを送る」を入れて、`setup()` の 1 行を
/// 差し替えるだけでよい:
///
///     if let first = midiDevices().first { midi = createMIDI(first) }
///
/// [ADR-0028]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0028-external-inputs.md
/// 確認: `--render /tmp/mokume-frames --frames 72` で、`f.0023`(暗い青・拍 0)・`f.0024`(黄・拍 1)・
/// `f.0036`(暗い青・拍 2)・`f.0048`(黄・拍 3)・`f.0060`(暗い青・拍 4。四角は 1 つ目に戻る) を目安に、
/// 背景が切り替わることを確認。
final class MIDIAndBeat: Sketch {
    var settings: SketchSettings {
        SketchSettings(width: 960, height: 540, title: "midi and beat")
    }

    /// 記録した列の長さ (フレーム)。最後まで行けば最初に戻り、先頭の開始で拍が 0 に戻る。
    private static let length = 72

    private var midi: MIDIPort?

    func setup() {
        midi = createMIDI(messages: Self.recorded())
    }

    func draw() {
        // 受けたクロックから数えた拍 (24 クロックで 1 拍)。まだ何も届いていなければ 0
        let beat = midi?.beat ?? 0

        if beat % 2 == 0 {
            background(24, 28, 56)
        } else {
            background(244, 204, 84)
        }

        // 4 拍で 1 周する拍の数え。いまの拍の四角だけが明るい
        noStroke()
        for index in 0..<4 {
            if index == beat % 4 {
                fill(250, 250, 250)
            } else {
                fill(128, 128, 140)
            }
            rect(width / 2 + Float(index - 2) * 80 + 10, height / 2 - 30, 60, 60)
        }
    }

    /// 0 番目のフレームに開始、1〜24 番目は 1 フレームに 1 クロック (24 個目で拍 1)、25 番目からは 1 フレームに
    /// 2 クロック (DAW のテンポを 2 倍にした)。拍は 0 番目が 0、24 番目が 1、36 番目が 2、48 番目が 3、
    /// 60 番目が 4 になる。
    private static func recorded() -> [[MIDIMessage]?] {
        (0..<length).map { frame -> [MIDIMessage]? in
            if frame == 0 { return [.start] }
            return frame <= 24 ? [.clock] : [.clock, .clock]
        }
    }
}
