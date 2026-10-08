// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import mokume

/// 外のプロセスから送った文字列で円を動かし、クリックで送り返す。
///
/// **見どころは、`nc` から送った文字列がそのまま円の大きさになること。** 円は UDP (6000) で
/// 受けた数 (0〜1) を、高さに対する直径の割合にする。円をクリックすると `hit` を送り返し、
/// 届いた `hit` のたびに色が入れ替わる。`draw()` はマウスの値を直には使わず、届いた文字列
/// だけを読む。円の下の点は受け口の様子で、受けていれば緑、受けていなければ灰色。
///
/// 外から動かす:
///
/// - UDP: `nc -u 127.0.0.1 6000` で `0.3` と打つ。クリックの `hit` は `nc -u -l 6001` に出る
///
/// **書き出しと台帳では回さない** (カタログの `reachesOutside`)。実物のポートを開くので、
/// 外から届いた値が絵に入りうる ([ADR-0028] 決定 7)。文字列で動く絵を書き出すなら、
/// `createUDP(messages:)` で記録した列を流す。
///
/// [ADR-0028]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0028-external-inputs.md
final class NetAndReply: Sketch {
    var settings = SketchSettings(width: 960, height: 540, title: "net and reply")

    private var udp: UDPPort?
    /// 届いた数 (0〜1)。円の直径は、高さに対するこの割合。
    private var size: Float = 0.5
    /// 届いた `hit` の数。
    private var hits = 0

    func setup() {
        // 受けるのは 6000、送り返すのは 6001 (同じ機械の `nc -u -l 6001` で見える)
        udp = try? createUDP(listen: 6000, send: ("127.0.0.1", 6001))
    }

    func draw() {
        for text in udp?.messages ?? [] {
            read(text)
        }

        background(18, 18, 24)
        noStroke()
        if hits % 2 == 0 {
            fill(232, 170, 92)
        } else {
            fill(120, 160, 220)
        }
        circle(width / 2, height / 2, size * height)

        // 受け口の様子
        if udp?.state == .running {
            fill(96, 200, 120)
        } else {
            fill(90, 90, 100)
        }
        circle(width / 2, height - 40, 16)
    }

    func mousePressed() {
        let dx = mouseX - width / 2
        let dy = mouseY - height / 2
        let radius = size * height / 2
        if dx * dx + dy * dy <= radius * radius {
            udp?.send("hit")
        }
    }

    /// 数なら大きさに、`hit` なら当たりに数える。それ以外は読まない。
    private func read(_ text: String) {
        if let value = Float(text) {
            size = constrain(value, 0.05, 1)
        } else if text == "hit" {
            hits += 1
        }
    }
}
