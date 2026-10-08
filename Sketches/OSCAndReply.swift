// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import mokume

/// OSC を自分に送って、自分で受ける。
///
/// **見どころは、マウスで動かした値が 1 度ポートを出てから戻ってくること。** 横に引きずると
/// `/size` を 127.0.0.1:9000 へ送り、同じ 9000 で受けたメッセージだけが円の大きさを変える。
/// 円をクリックすると `/hit 1` を送り、受けるたびに円の色が入れ替わる。`draw()` はマウスの値を
/// 直には使わず、届いたメッセージだけを読む。左上の点は受け口の状態で、受けているあいだ緑になる
/// (ポートを他のアプリが使っていれば灰色のまま、空けば緑になる)。
///
/// TouchDesigner や TouchOSC と繋ぐなら、`send:` を相手の受けるアドレスに替える
/// (`("127.0.0.1", 7000)` など)。相手から `/size 0.0〜1.0` を 9000 へ送れば円の大きさが変わり、
/// クリックの `/hit 1` が相手に届く。
///
/// **書き出しと台帳では回さない** (カタログの `reachesOutside`)。実物のポートを開くので、
/// 外から届いた値が絵に入りうる ([ADR-0028] 決定 7)。メッセージで動く絵を書き出すなら、
/// `createOSC(messages:)` で記録した列を流す。
///
/// [ADR-0028]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0028-external-inputs.md
final class OSCAndReply: Sketch {
    var settings = SketchSettings(width: 960, height: 540, title: "osc and reply")

    /// 受けるポート。送り先も同じにして、自分で送って自分で受ける。
    private static let port = 9000

    private var osc: OSCPort?
    /// 届いた `/size` の値 (0〜1)。円の直径は、高さに対するこの割合。
    private var size: Float = 0.5
    /// 届いた `/hit` の数。
    private var hits = 0

    func setup() {
        osc = try? createOSC(listen: Self.port, send: ("127.0.0.1", Self.port))
    }

    func draw() {
        for message in osc?.messages ?? [] {
            switch message.address {
            case "/size": size = constrain(message.float(0) ?? size, 0.05, 1)
            case "/hit": hits += message.int(0) ?? 0
            default: break
            }
        }

        background(18, 18, 24)
        noStroke()
        if hits % 2 == 0 {
            fill(232, 170, 92)
        } else {
            fill(120, 160, 220)
        }
        circle(width / 2, height / 2, size * height)

        // 受け口の状態
        if osc?.state == .running {
            fill(96, 200, 120)
        } else {
            fill(90, 90, 100)
        }
        circle(28, 28, 16)
    }

    func mouseDragged(deltaX: Float, deltaY: Float) {
        osc?.send("/size", constrain(mouseX / width, 0, 1))
    }

    func mousePressed() {
        let dx = mouseX - width / 2
        let dy = mouseY - height / 2
        let radius = size * height / 2
        if dx * dx + dy * dy <= radius * radius {
            osc?.send("/hit", 1)
        }
    }
}
