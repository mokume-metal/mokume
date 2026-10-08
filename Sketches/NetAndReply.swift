// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import mokume

/// 外のプロセスから送った文字列で円を動かし、クリックで送り返す。
///
/// **見どころは、`nc` やブラウザから送った文字列がそのまま円の大きさになること。** 円は左から
/// TCP (5204)・UDP (6000)・WebSocket (8025) で、それぞれ受けた数 (0〜1) を大きさにする。円を
/// クリックすると、その方式で `hit` を送り返す。届いた `hit` のたびに、その円の色が入れ替わる。
/// `draw()` はマウスの値を直には使わず、届いた文字列だけを読む。
///
/// 円の下の点は受け口の様子で、受けていて相手が居れば緑、受けているが相手が居なければ黄
/// (TCP と WebSocket。繋いでくる相手を数える)、受けていなければ灰色。
///
/// 外から動かす:
///
/// - TCP: `nc 127.0.0.1 5204` で繋いで `0.3` と打つ。クリックの `hit` は同じ端末に出る
/// - UDP: `nc -u 127.0.0.1 6000` で `0.3` と打つ。クリックの `hit` は `nc -u -l 6001` に出る
/// - WebSocket: ブラウザの console で
///   `ws = new WebSocket("ws://localhost:8025"); ws.onmessage = e => console.log(e.data); ws.onopen = () => ws.send("0.3")`。
///   続けて `ws.send("0.8")` で大きさが変わり、クリックの `hit` は console に出る
///
/// **書き出しと台帳では回さない** (カタログの `reachesOutside`)。実物のポートを開くので、
/// 外から届いた値が絵に入りうる ([ADR-0028] 決定 7)。文字列で動く絵を書き出すなら、
/// `createServer(messages:)`・`createUDP(messages:)` で記録した列を流す。
///
/// [ADR-0028]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0028-external-inputs.md
final class NetAndReply: Sketch {
    var settings = SketchSettings(width: 960, height: 540, title: "net and reply")

    /// 円の並び。左から TCP・UDP・WebSocket。
    private static let names = ["TCP 5204", "UDP 6000", "WebSocket 8025"]

    private var server: Server?
    private var udp: UDPPort?
    private var socket: Server?
    /// 円ごとに、届いた数 (0〜1)。直径は、円の枠に対するこの割合。
    private var sizes: [Float] = [0.5, 0.5, 0.5]
    /// 円ごとに、届いた `hit` の数。
    private var hits = [0, 0, 0]

    func setup() {
        server = try? createServer(5204)
        // 受けるのは 6000、送り返すのは 6001 (同じ機械の `nc -u -l 6001` で見える)
        udp = try? createUDP(listen: 6000, send: ("127.0.0.1", 6001))
        socket = try? createWebSocketServer(8025)
    }

    func draw() {
        for line in server?.messages ?? [] { read(line, into: 0) }
        for text in udp?.messages ?? [] { read(text, into: 1) }
        for text in socket?.messages ?? [] { read(text, into: 2) }

        background(18, 18, 24)
        noStroke()
        textAlign(.center)
        textSize(18)
        for lane in Self.names.indices {
            let x = center(of: lane)
            if hits[lane] % 2 == 0 {
                fill(232, 170, 92)
            } else {
                fill(120, 160, 220)
            }
            circle(x, height / 2, sizes[lane] * span)

            // 受け口の様子
            switch status(of: lane) {
            case .connected: fill(96, 200, 120)
            case .waiting: fill(220, 190, 80)
            case .closed: fill(90, 90, 100)
            }
            circle(x, height - 64, 14)
            fill(200, 200, 210)
            text(Self.names[lane], x, height - 28)
        }
    }

    func mousePressed() {
        for lane in Self.names.indices {
            let dx = mouseX - center(of: lane)
            let dy = mouseY - height / 2
            let radius = sizes[lane] * span / 2
            guard dx * dx + dy * dy <= radius * radius else { continue }
            switch lane {
            case 0: server?.write("hit\n")
            case 1: udp?.send("hit")
            default: socket?.write("hit")
            }
        }
    }

    // MARK: -

    private enum Status { case connected, waiting, closed }

    /// 円の枠 (直径の最大)。
    private var span: Float { min(height * 0.6, width / Float(Self.names.count) * 0.85) }

    private func center(of lane: Int) -> Float {
        width * (Float(lane) + 0.5) / Float(Self.names.count)
    }

    private func status(of lane: Int) -> Status {
        switch lane {
        case 1:
            return udp?.state == .running ? .connected : .closed
        default:
            let waiting = lane == 0 ? server : socket
            guard let waiting, waiting.state == .running else { return .closed }
            return waiting.clientCount > 0 ? .connected : .waiting
        }
    }

    /// 数なら大きさに、`hit` なら当たりに数える。それ以外は読まない。
    private func read(_ text: String, into lane: Int) {
        if let value = Float(text) {
            sizes[lane] = constrain(value, 0.05, 1)
        } else if text == "hit" {
            hits[lane] += 1
        }
    }
}
