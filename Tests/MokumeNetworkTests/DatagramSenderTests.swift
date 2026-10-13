// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation
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

    // MARK: - UDP の送れた (#2326)

    private func clocked(_ told: Told, _ clock: ManualClock, confirmAfter: TimeInterval = 0.5)
        -> DatagramSender
    {
        DatagramSender(
            host: "192.168.1.20", port: 7000, confirmAfter: confirmAfter, now: clock.provider,
            warn: told.append)
    }

    private let refused = NWError.posix(.ECONNREFUSED)

    @Test("拒否で名乗った後は、完了が誤り無しで返っても戻らない。拒否は次の送信の失敗として返る")
    func aCleanCompletionDoesNotClearARefusal() {
        let told = Told()
        let clock = ManualClock(0)
        let sender = clocked(told, clock)
        sender.onQueue { sender.finished(sending: refused, on: nil) }
        #expect(told.lines.count == 1)

        // 送るたびに「誤り無し」と「拒否」が交互に返る。誤り無しの完了で戻すと、毎回言い直す
        for _ in 0..<6 {
            clock.advance(by: 0.1)
            sender.onQueue { sender.finished(sending: nil, on: nil) }
            clock.advance(by: 0.1)
            sender.onQueue { sender.finished(sending: refused, on: nil) }
        }
        #expect(told.lines.count == 1)
    }

    @Test("同じ繋ぎで間を空けた 2 つ目も誤り無く終わったら戻り、次の拒否をまた名乗る")
    func aConfirmedSendClearsARefusal() {
        let told = Told()
        let clock = ManualClock(0)
        let sender = clocked(told, clock)
        sender.onQueue { sender.finished(sending: refused, on: nil) }

        sender.onQueue { sender.finished(sending: nil, on: nil) }
        clock.advance(by: 0.4)  // まだ間が足りない
        sender.onQueue { sender.finished(sending: nil, on: nil) }
        sender.onQueue { sender.finished(sending: refused, on: nil) }
        #expect(told.lines.count == 1)

        // 拒否が返ると間の測り直し。足りたら戻る
        sender.onQueue { sender.finished(sending: nil, on: nil) }
        clock.advance(by: 0.5)
        sender.onQueue { sender.finished(sending: nil, on: nil) }
        sender.onQueue { sender.finished(sending: refused, on: nil) }
        #expect(told.lines.count == 2)
    }

    @Test("待っていた繋ぎは、拒否と違って、誤り無く終わった 1 度で戻す (間は要らない)")
    func waitingIsClearedByOneCleanCompletion() {
        let told = Told()
        let clock = ManualClock(0)
        let sender = clocked(told, clock)
        sender.onQueue { sender.changed(to: .waiting(.posix(.ENETDOWN)), on: nil) }
        sender.onQueue { sender.finished(sending: nil, on: nil) }
        sender.onQueue { sender.changed(to: .waiting(.posix(.ENETDOWN)), on: nil) }
        #expect(told.lines.count == 2)
    }

    @Test("自分で捨てた繋ぎの取り消しは、送れない理由として名乗らない。いまの繋ぎの取り消しは名乗る")
    func ownCancellationIsNotAReason() {
        let told = Told()
        let sender = clocked(told, ManualClock(0))
        // いまの繋ぎ (まだ 1 つも開いていない) ではない繋ぎで返った取り消し
        let dropped = NWConnection(host: "192.168.1.20", port: 7000, using: .udp)
        sender.onQueue { sender.finished(sending: .posix(.ECANCELED), on: dropped) }
        #expect(told.lines.isEmpty)

        sender.onQueue { sender.finished(sending: .posix(.ECANCELED), on: nil) }
        #expect(told.lines.count == 1)
        #expect(told.lines.first?.contains("Operation canceled") == true)
    }

    @Test("大きすぎる datagram は大きさを名乗り、宛先を疑わず、送れた 1 度で戻る")
    func tooLargeNamesTheSizeNotTheDestination() {
        let told = Told()
        let sender = clocked(told, ManualClock(0))
        sender.onQueue { sender.finished(sending: .posix(.EMSGSIZE), on: nil) }
        #expect(told.lines.count == 1)
        let line = told.lines.first ?? ""
        #expect(line.contains("Message too long"))
        #expect(line.contains("larger than one datagram"))
        #expect(!line.contains("listening"))
        #expect(!line.contains("Local Network"))

        // 続けて大きすぎても重ねて言わない。小さいものが送れたら戻る
        sender.onQueue { sender.finished(sending: .posix(.EMSGSIZE), on: nil) }
        #expect(told.lines.count == 1)
        sender.onQueue { sender.finished(sending: nil, on: nil) }
        sender.onQueue { sender.finished(sending: .posix(.EMSGSIZE), on: nil) }
        #expect(told.lines.count == 2)
    }
}
