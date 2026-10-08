// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Network
import Testing

@testable import MokumeNetwork

/// 送れないことの名乗り (#1962)。本物の繋ぎは作らず、繋ぎの状態を読み替える手続きを直に呼ぶ。
///
/// **送れないときに黙らないことが約束である。** 束ねた `.app` にローカルネットワークの許可が
/// 無いと、繋ぎは `waiting (Network is down)` のまま動かず、送ったものの完了も返らない。
/// 読み替えが `waiting` を見落とすと、メッセージは黙って消える (実測)。
@Suite("送れないことの名乗り")
struct DatagramSenderTests {
    private func sender(_ told: Told) -> DatagramSender {
        DatagramSender(host: "192.168.1.20", port: 7000, warn: told.append)
    }

    @Test("待っている繋ぎは 1 度だけ名乗り、宛先とエラーと許可の見当を添える")
    func waitingIsToldOnce() {
        let told = Told()
        let sender = sender(told)
        sender.onQueue { sender.changed(to: .waiting(.posix(.ENETDOWN)), on: nil) }
        #expect(told.lines.count == 1)
        let line = told.lines.first ?? ""
        #expect(line.contains("192.168.1.20:7000"))
        #expect(line.contains("Network is down"))
        #expect(line.contains("System Settings > Privacy & Security > Local Network"))
        #expect(line.contains("may not be allowed"))  // 断定しない

        // 待ち続けても重ねて言わない
        sender.onQueue { sender.changed(to: .waiting(.posix(.ENETDOWN)), on: nil) }
        #expect(told.lines.count == 1)
    }

    @Test("繋がる途中と繋がったときは名乗らない")
    func readyIsSilent() {
        let told = Told()
        let sender = sender(told)
        let states: [NWConnection.State] = [.setup, .preparing, .ready, .cancelled]
        for state in states {
            sender.onQueue { sender.changed(to: state, on: nil) }
        }
        #expect(told.lines.isEmpty)
    }

    @Test("送れた後にまた待てば、もう 1 度名乗る。繋がっただけでは戻さない")
    func toldAgainAfterASuccessfulSend() {
        let told = Told()
        let sender = sender(told)
        sender.onQueue { sender.changed(to: .waiting(.posix(.ENETDOWN)), on: nil) }
        sender.onQueue { sender.changed(to: .ready, on: nil) }
        sender.onQueue { sender.changed(to: .waiting(.posix(.ENETDOWN)), on: nil) }
        #expect(told.lines.count == 1)

        sender.onQueue { sender.finished(sending: nil, on: nil) }
        sender.onQueue { sender.changed(to: .waiting(.posix(.ENETDOWN)), on: nil) }
        #expect(told.lines.count == 2)
    }

    @Test("失敗した繋ぎは、宛先で誰も受けていない見当を名乗る (許可には触れない)")
    func failedPointsAtTheListener() {
        let told = Told()
        let sender = sender(told)
        sender.onQueue { sender.changed(to: .failed(.posix(.ECONNREFUSED)), on: nil) }
        #expect(told.lines.count == 1)
        let line = told.lines.first ?? ""
        #expect(line.contains("192.168.1.20:7000"))
        #expect(line.contains("Connection refused"))
        #expect(line.contains("listening"))
        #expect(!line.contains("Local Network"))
    }
}
