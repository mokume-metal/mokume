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
    /// 誰も受けていない 127.0.0.1 の UDP の口。**検査が手放すまで番号を握る** (``PortHolder/unanswered()``)。
    ///
    /// かつては番号 0 で握ってすぐ手放し、その番号を狙っていた。手放してから狙うまでの間に他の
    /// プロセスがその番号を取ると、拒否が返らずに `refusals >= 1` が期限で落ちる (#2542・#2359 と
    /// 同じ隙間)。握ったままなら、他は同じ番号を bind できない。
    private func unanswered() throws -> PortHolder { try PortHolder.unanswered() }

    /// 送れないことの診断の数。
    private func refusals(_ told: Told) -> Int { told.count(containing: "Could not send") }

    /// 診断の行の読み分け。`refusals` は "Could not send" で数えて、宛先の失敗 (拒否・`Check that something
    /// is listening`) と待ち (`keeps waiting`) を区別しない。**赤のとき、どちらの文が増えたかを失敗の文面に
    /// 載せる** (次に赤が出たら切り分けられるように — #3045)。
    private func diagnosis(_ told: Told) -> String {
        let toward = told.count(containing: "Check that something is listening")
        let waiting = told.count(containing: "keeps waiting")
        return "宛先の失敗 \(toward) 行・待ち \(waiting) 行・全行: \(told.lines)"
    }

    /// **握っている間は、他が同じ番号を取れない** (#2542)。隙間はめったに開かないので、握らない形へ
    /// 戻しても下の検査は赤くならない — その代わりに、隙間が無いことをここで直に見る。
    @Test("誰も受けない口は、握っている間、同じ番号を bind できない")
    func theUnansweredPortCannotBeTakenWhileHeld() throws {
        let nobody = try unanswered()
        defer { nobody.release() }
        do {
            let other = try PortHolder(port: nobody.port)
            other.release()
            Issue.record("握っている番号 \(nobody.port) を、別の socket が bind できた")
        } catch let failure as PortHolder.Failure {
            #expect(failure.call == "bind")
            #expect(failure.code == EADDRINUSE, "errno \(failure.code)")
        }
    }

    @Test("誰も受けていない宛先へ、フレームを挟んで 10 回送っても、診断は 1 行")
    func spacedSendsToNobodyAreToldOnce() async throws {
        let told = Told()
        let nobody = try unanswered()
        defer { nobody.release() }
        let sender = DatagramSender(host: "127.0.0.1", port: nobody.port, warn: told.append)
        defer { sender.stop() }

        for index in 0..<10 {
            sender.send([UInt8(index)])
            try await Task.sleep(for: .milliseconds(60))
        }
        try await requireWait(
            "宛先の拒否が 1 行に届かなかった", detail: { diagnosis(told) }
        ) {
            refusals(told) >= 1
        }
        try await Task.sleep(for: .milliseconds(300))
        #expect(refusals(told) == 1, "診断: \(diagnosis(told))")
    }

    @Test("1 フレームの中で 10 回まとめて送っても、診断は 1 行で、自分で取り消した繋ぎの名乗りは混ざらない")
    func burstToNobodyIsToldOnceWithoutOwnCancellation() async throws {
        let told = Told()
        let nobody = try unanswered()
        defer { nobody.release() }
        let sender = DatagramSender(host: "127.0.0.1", port: nobody.port, warn: told.append)
        defer { sender.stop() }

        // 拒否は最初の送信の後で届き、**次の送信**の失敗として返る。まとめて送ると、後ろの送信は
        // 同じ繋ぎに積まれていて、繋ぎを捨てるときに取り消される。1 度目の束では拒否がどの送信にも
        // 返らないことがあるので、ここでは増えていないことだけを見る
        for index in 0..<10 {
            sender.send([UInt8(index)])
        }
        try await Task.sleep(for: .milliseconds(300))
        #expect(refusals(told) <= 1, "診断: \(diagnosis(told))")

        // 間を置いてまとめ直す。拒否が届いた後なので、束の最初の送信が失敗して名乗る。名乗りは
        // 通しで 1 行のままである
        for _ in 0..<2 {
            for index in 0..<10 {
                sender.send([UInt8(index)])
            }
            try await Task.sleep(for: .milliseconds(300))
        }
        try await requireWait(
            "宛先の拒否が 1 行に届かなかった", detail: { diagnosis(told) }
        ) {
            refusals(told) >= 1
        }
        #expect(refusals(told) == 1, "診断: \(diagnosis(told))")
        #expect(told.count(containing: "Operation canceled") == 0, "診断: \(diagnosis(told))")
    }

    @Test("OSCPort.send と UDPPort.send も、誰も受けていない宛先へ送り続けて、それぞれ 1 行")
    func portsToNobodyTellOnce() async throws {
        let told = Told()
        let nobody = try unanswered()
        defer { nobody.release() }
        let port = nobody.port
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
        try await requireWait(
            "宛先の拒否が 1 行に届かなかった", detail: { diagnosis(told) }
        ) {
            refusals(told) >= 1
        }
        try await Task.sleep(for: .milliseconds(300))
        #expect(refusals(told) == 1, "OSC の診断: \(diagnosis(told))")

        // 同じ宛先を、別の入り口 (別の送り手) から。こちらも 1 行
        for index in 0..<10 {
            udp.send("hit \(index)")
            try await Task.sleep(for: .milliseconds(60))
        }
        try await requireWait(
            "宛先の拒否が 2 行に届かなかった", detail: { diagnosis(told) }
        ) {
            refusals(told) >= 2
        }
        try await Task.sleep(for: .milliseconds(300))
        #expect(refusals(told) == 2, "UDP の診断: \(diagnosis(told))")
    }
}
