// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import mokume

/// Arduino のつまみ (可変抵抗) で円を動かす (#1961 の作例)。
///
/// **見どころは、つまみを回すと円が左右に動き、USB を抜くと円が止まって「切断」と出ること。**
/// 挿し直せば、また動く。Arduino には次を書き込んでおく (A0 に可変抵抗を繋ぐ):
///
///     void setup() { Serial.begin(9600); }
///     void loop() { Serial.println(analogRead(A0)); delay(10); }
///
/// `draw()` は届いた行 (0〜1023) だけを読む。左上の点は受け口の状態で、受けているあいだ緑、
/// 繋がっていない・他のアプリが使っているあいだ灰色、抜かれたら赤になる。点の横は開いた
/// ポートの識別子で、USB の機材が無いときは Mac 自身のポート (`/dev/cu.debug-console` など) を
/// 開くので、何も届かない。
///
/// **書き出しと台帳では回さない** (カタログの `reachesOutside`)。実物のポートを開くので、外から
/// 届いた値が絵に入りうる ([ADR-0028] 決定 7)。機材なしで同じ動きを出すなら、
/// `createSerial(lines:)` で記録した行を流す。
///
/// [ADR-0028]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0028-external-inputs.md
final class SerialAndKnob: Sketch {
    var settings = SketchSettings(width: 960, height: 540, title: "serial and knob")

    private var port: Serial?
    /// 開いたポートの識別子。開いていなければ空。
    private var opened = ""
    /// 円の中心の横の位置。届いた値 (0〜1023) を幅に写したもの。
    private var x: Float = 0

    func setup() {
        if let first = serialPorts().first {
            port = try? createSerial(first, baudRate: 9600)
            opened = first.id
        }
    }

    func draw() {
        for line in port?.lines ?? [] {
            if let value = Float(line) { x = constrain(value / 1023, 0, 1) * width }
        }

        background(18, 18, 24)
        noStroke()
        fill(232, 170, 92)
        circle(x, height / 2, 60)

        // 受け口の状態
        switch port?.state {
        case .running: fill(96, 200, 120)
        case .disconnected: fill(220, 90, 80)
        default: fill(90, 90, 100)
        }
        circle(28, 28, 16)
        fill(200)
        text(opened.isEmpty ? "no serial port" : opened, 48, 34)
        if port?.state == .disconnected { text("切断", 48, 64) }
    }
}
