// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation
import Testing

@testable import MokumeNetwork

/// 送れないことの名乗りを、本物の繋ぎ (127.0.0.1) で送り続けて確かめる (#2326)。
///
/// ``DatagramSenderTests`` は繋ぎの読み替えを直に呼ぶだけで、**本物の送信を続けたときを見ていない**。
/// UDP の送信の完了は「手元のソケットから出た」ことしか言わず、宛先で誰も受けていない拒否 (ICMP) は
/// **次の送信**の失敗として返る。完了が誤り無しで返ったことを「送れた」と読むと、誰にも届いていない
/// のに送るたびに戻って、診断が 2 回に 1 回出直す。
///
/// 待ちは待つ側が期限を持つ。「それ以上増えない」を見るところだけは、増えうる時間を置いてから数える。
@Suite("本物の繋ぎで送り続ける", .serialized)
struct DatagramSenderLoopbackTests {
    /// 誰も受けていない 127.0.0.1 のポートの番号。
    private func unlistenedPort() throws -> Int {
        let holder = try PortHolder(port: 0)
        defer { holder.release() }
        return holder.port
    }

    /// 送れないことの診断の数。
    private func refusals(_ told: Told) -> Int { told.count(containing: "Could not send") }

    @Test("誰も受けていない宛先へ、フレームを挟んで 10 回送っても、診断は 1 行")
    func spacedSendsToNobodyAreToldOnce() async throws {
        let told = Told()
        let sender = DatagramSender(host: "127.0.0.1", port: try unlistenedPort(), warn: told.append)
        defer { sender.stop() }

        for index in 0..<10 {
            sender.send([UInt8(index)])
            try await Task.sleep(for: .milliseconds(60))
        }
        #expect(await until { refusals(told) >= 1 })
        try await Task.sleep(for: .milliseconds(300))
        #expect(refusals(told) == 1, "診断: \(told.lines)")
    }

    @Test("1 フレームの中で 10 回まとめて送っても、診断は 1 行で、自分で取り消した繋ぎの名乗りは混ざらない")
    func burstToNobodyIsToldOnceWithoutOwnCancellation() async throws {
        let told = Told()
        let sender = DatagramSender(host: "127.0.0.1", port: try unlistenedPort(), warn: told.append)
        defer { sender.stop() }

        // 拒否は最初の送信の後で届き、**次の送信**の失敗として返る。まとめて送ると、後ろの送信は
        // 同じ繋ぎに積まれていて、繋ぎを捨てるときに取り消される。1 度目の束では拒否がどの送信にも
        // 返らないことがあるので、ここでは増えていないことだけを見る
        for index in 0..<10 {
            sender.send([UInt8(index)])
        }
        try await Task.sleep(for: .milliseconds(300))
        #expect(refusals(told) <= 1, "診断: \(told.lines)")

        // 間を置いてまとめ直す。拒否が届いた後なので、束の最初の送信が失敗して名乗る。名乗りは
        // 通しで 1 行のままである
        for _ in 0..<2 {
            for index in 0..<10 {
                sender.send([UInt8(index)])
            }
            try await Task.sleep(for: .milliseconds(300))
        }
        #expect(await until { refusals(told) >= 1 })
        #expect(refusals(told) == 1, "診断: \(told.lines)")
        #expect(told.count(containing: "Operation canceled") == 0, "診断: \(told.lines)")
    }

    @Test("OSCPort.send と UDPPort.send も、誰も受けていない宛先へ送り続けて、それぞれ 1 行")
    func portsToNobodyTellOnce() async throws {
        let told = Told()
        let port = try unlistenedPort()
        let osc = OSCPort(
            port: nil, name: "osc (send only)", source: RecordedSource<OSCMessage>(batches: []),
            outbound: DatagramSender(host: "127.0.0.1", port: port, warn: told.append), owner: nil,
            warn: told.append)
        defer { osc.close() }
        let udp = UDPPort(
            port: nil, name: "udp (send only)", source: RecordedSource<String>(batches: []),
            outbound: DatagramSender(host: "127.0.0.1", port: port, warn: told.append), owner: nil,
            warn: told.append)
        defer { udp.close() }

        for index in 0..<10 {
            osc.send("/hit", index)
            try await Task.sleep(for: .milliseconds(60))
        }
        #expect(await until { refusals(told) >= 1 })
        try await Task.sleep(for: .milliseconds(300))
        #expect(refusals(told) == 1, "OSC の診断: \(told.lines)")

        // 同じ宛先を、別の入り口 (別の送り手) から。こちらも 1 行
        for index in 0..<10 {
            udp.send("hit \(index)")
            try await Task.sleep(for: .milliseconds(60))
        }
        #expect(await until { refusals(told) >= 2 })
        try await Task.sleep(for: .milliseconds(300))
        #expect(refusals(told) == 2, "UDP の診断: \(told.lines)")
    }

    @Test("受け手が開けば届き、届いた後で受け手が閉じれば、また 1 行だけ名乗る")
    func receiverComingAndGoing() async throws {
        let told = Told()
        let port = try unlistenedPort()
        // 戻すまでの間は短くして、検査が待つ時間を詰める (本番の既定は 0.5 秒)
        let sender = DatagramSender(
            host: "127.0.0.1", port: port, confirmAfter: 0.1, warn: told.append)
        defer { sender.stop() }

        // 受け手が居ない間は 1 行
        for index in 0..<6 {
            sender.send(Array("miss \(index)".utf8))
            try await Task.sleep(for: .milliseconds(60))
        }
        #expect(refusals(told) == 1, "診断: \(told.lines)")

        // 受け手が開く
        let heard = Told()
        let source = DatagramSource<String>.text(
            port: port, host: "127.0.0.1", retryAfter: 0.05, warn: heard.append)
        let receiver = UDPPort(
            port: port, name: "udp :\(port)", source: source, outbound: nil, owner: nil,
            warn: heard.append)
        try receiver.open()
        defer { receiver.close() }
        #expect(await until { receiver.state == .running })

        // 開いた直後に、拒否の残りが 1 つだけ送信の失敗として返ることはある。続けて送れば届き、
        // 届き始めたら取りこぼさない
        var received: [String] = []
        let deadline = Date().addingTimeInterval(10)
        var attempt = 0
        while received.isEmpty && Date() < deadline {
            sender.send(Array("first \(attempt)".utf8))
            attempt += 1
            try await Task.sleep(for: .milliseconds(60))
            receiver.supply()
            received += receiver.messages
        }
        #expect(!received.isEmpty, "届かなかった: \(told.lines)")
        for index in 0..<3 {
            sender.send(Array("after \(index)".utf8))
            try await Task.sleep(for: .milliseconds(60))
        }
        received += await collect(receiver, count: 3)
        #expect(received.suffix(3) == ["after 0", "after 1", "after 2"], "届いた: \(received)")
        #expect(refusals(told) == 1, "診断: \(told.lines)")

        // 間を空けて送れ続けたので、送れたと読んで戻っている。受け手が閉じたら、また 1 行
        try await Task.sleep(for: .milliseconds(300))
        sender.send(Array("settled".utf8))
        try await Task.sleep(for: .milliseconds(100))
        receiver.close()
        #expect(await until { receiver.state == .stopped })
        for index in 0..<10 {
            sender.send(Array("gone \(index)".utf8))
            try await Task.sleep(for: .milliseconds(60))
        }
        #expect(await until { refusals(told) >= 2 })
        try await Task.sleep(for: .milliseconds(300))
        #expect(refusals(told) == 2, "診断: \(told.lines)")
    }
}
