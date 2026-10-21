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

    /// 始めていない繋ぎを作る。通信はしない。
    private func unstartedConnection() -> NWConnection {
        NWConnection(host: "192.168.1.20", port: 7000, using: .udp)
    }

    /// 送信の完了を、`connection` に返ったものとして読ませる。`issued` は送信を出した時刻。
    private func complete(
        _ sender: DatagramSender, _ error: NWError?, on connection: NWConnection?,
        issuedAt issued: TimeInterval? = nil
    ) {
        sender.onQueue { sender.finished(sending: error, on: connection, issuedAt: issued) }
    }

    @Test("拒否で名乗った後は、完了が誤り無しで返っても戻らない。拒否は次の送信の失敗として返る")
    func aCleanCompletionDoesNotClearARefusal() {
        let told = Told()
        let clock = ManualClock(0)
        let sender = clocked(told, clock)
        let connection = unstartedConnection()
        sender.onQueue { sender.attach(connection) }
        complete(sender, refused, on: connection)
        #expect(told.lines.count == 1)

        // 送るたびに「誤り無し」と「拒否」が交互に返る。誤り無しの完了で戻すと、毎回言い直す。
        // 拒否が返るたびに繋ぎは捨てられるので、次は新しい繋ぎ
        for _ in 0..<6 {
            let next = unstartedConnection()
            sender.onQueue { sender.attach(next) }
            clock.advance(by: 0.1)
            complete(sender, nil, on: next, issuedAt: clock.provider())
            clock.advance(by: 0.1)
            complete(sender, refused, on: next)
        }
        #expect(told.lines.count == 1)
    }

    @Test("同じ繋ぎで、最初の完了から間を空けて出した 2 つ目も誤り無く終わったら戻り、次の拒否をまた名乗る")
    func aConfirmedSendClearsARefusal() {
        let told = Told()
        let clock = ManualClock(0)
        let sender = clocked(told, clock)
        let connection = unstartedConnection()
        sender.onQueue { sender.attach(connection) }
        complete(sender, refused, on: connection)

        // 新しい繋ぎで最初の完了 (0 秒)。0.4 秒後に出した送信は間が足りない
        let next = unstartedConnection()
        sender.onQueue { sender.attach(next) }
        complete(sender, nil, on: next, issuedAt: 0)
        clock.advance(by: 0.4)
        complete(sender, nil, on: next, issuedAt: 0.4)
        clock.advance(by: 0.1)
        complete(sender, refused, on: next)
        #expect(told.lines.count == 1)

        // 拒否が返ると繋ぎは捨てられ、数え直し。0.5 秒空けて出した送信が終わったら戻る
        let third = unstartedConnection()
        sender.onQueue { sender.attach(third) }
        complete(sender, nil, on: third, issuedAt: clock.provider())
        let first = clock.provider()
        clock.advance(by: 0.5)
        complete(sender, nil, on: third, issuedAt: first + 0.5)
        complete(sender, refused, on: third)
        #expect(told.lines.count == 2)
    }

    /// 受け手が居ない間の最後の送信が誤り無く終わり、受け手が開くまでが `confirmAfter` を超えると、
    /// 送れたと読んで戻る。そこへ拒否の残りが返ると 2 行目を名乗る (#3045)。**設計どおりの結果** —
    /// 時計を手で進めて、実時間の揺れ無しに固定する。本物の繋ぎで送り続ける検査
    /// (``DatagramSenderLoopbackTests``) は、開いた直後の増えを高々 1 行まで許す。
    @Test("居ない間の最後の送信が誤り無く終わり、開くまでが confirmAfter を超えると、残りの拒否で 2 行目を名乗る")
    func aLeftoverRefusalAfterTheReceiverOpensIsToldAgain() {
        let told = Told()
        let clock = ManualClock(0)
        let sender = clocked(told, clock, confirmAfter: 0.1)
        let connection = unstartedConnection()
        sender.onQueue { sender.attach(connection) }
        complete(sender, refused, on: connection)
        #expect(told.lines.count == 1)

        // 受け手が居ない間の最後の送信 (0 秒に誤り無く終わる)。そこから 0.3 秒後に受け手が開き、
        // 次の送信は誤り無く終わる (間が confirmAfter 以上なので、戻る)
        let next = unstartedConnection()
        sender.onQueue { sender.attach(next) }
        complete(sender, nil, on: next, issuedAt: 0)
        clock.advance(by: 0.3)
        complete(sender, nil, on: next, issuedAt: clock.provider())
        #expect(told.lines.count == 1)

        // 拒否の残りが返る
        complete(sender, refused, on: next)
        #expect(told.lines.count == 2)
    }

    @Test("間は送信を出した時刻で測る。完了が遅れて返っただけでは満たさない")
    func theGapIsMeasuredFromWhenTheSendWasIssued() {
        let told = Told()
        let clock = ManualClock(0)
        let sender = clocked(told, clock)
        let connection = unstartedConnection()
        sender.onQueue { sender.attach(connection) }
        complete(sender, refused, on: connection)
        let next = unstartedConnection()
        sender.onQueue { sender.attach(next) }

        // 1 つ目 (0 秒に完了)。2 つ目は 0.1 秒に出したのに、待ち行列が遅れて完了が 0.6 秒に返る
        complete(sender, nil, on: next, issuedAt: 0)
        clock.advance(by: 0.6)
        complete(sender, nil, on: next, issuedAt: 0.1)
        complete(sender, refused, on: next)
        #expect(told.lines.count == 1)  // 戻っていれば、この拒否を名乗り直して 2 になる
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

    @Test("待っていると名乗った後に拒否が返れば、以後は拒否として戻す (1 度の成功で言い直さない)")
    func aRefusalAfterWaitingIsStillARefusal() {
        let told = Told()
        let clock = ManualClock(0)
        let sender = clocked(told, clock)
        let connection = unstartedConnection()
        sender.onQueue { sender.attach(connection) }
        sender.onQueue { sender.changed(to: .waiting(.posix(.ENETDOWN)), on: nil) }
        #expect(told.lines.count == 1)

        complete(sender, refused, on: connection)  // 名乗り済みなので増えない。ここで拒否になる
        let next = unstartedConnection()
        sender.onQueue { sender.attach(next) }
        complete(sender, nil, on: next, issuedAt: clock.provider())  // 誤り無しの 1 度では戻らない
        complete(sender, refused, on: next)
        #expect(told.lines.count == 1)
    }

    @Test("捨てた繋ぎに返った完了は、どんな誤りでも名乗らず、いまの繋ぎの数え方を崩さない")
    func completionsOfADroppedConnectionAreIgnored() {
        let told = Told()
        let clock = ManualClock(0)
        let sender = clocked(told, clock)
        let dropped = unstartedConnection()
        let current = unstartedConnection()
        sender.onQueue { sender.attach(current) }

        // 弱参照が消えた (nil) 完了も、いまの繋ぎではない
        for error in [NWError.posix(.ECANCELED), refused, .posix(.EMSGSIZE)] {
            complete(sender, error, on: dropped)
            complete(sender, error, on: nil)
        }
        #expect(told.lines.isEmpty)

        // いまの繋ぎの数え方を、捨てた繋ぎの誤りで消さない: 拒否の名乗り後、いまの繋ぎで最初の
        // 完了 (0 秒) の後に捨てた繋ぎの拒否が返っても、0.5 秒空けた送信で戻れる
        complete(sender, refused, on: current)
        let fresh = unstartedConnection()
        sender.onQueue { sender.attach(fresh) }
        complete(sender, nil, on: fresh, issuedAt: 0)
        complete(sender, refused, on: dropped)
        complete(sender, nil, on: dropped, issuedAt: 5)  // 捨てた繋ぎの成功は数えない
        clock.advance(by: 0.5)
        complete(sender, nil, on: fresh, issuedAt: 0.5)
        complete(sender, refused, on: fresh)
        #expect(told.lines.count == 2)
    }

    @Test("いまの繋ぎに返った取り消しは、送れない理由として名乗る")
    func cancellationOfTheCurrentConnectionIsNamed() {
        let told = Told()
        let sender = clocked(told, ManualClock(0))
        let connection = unstartedConnection()
        sender.onQueue { sender.attach(connection) }
        complete(sender, .posix(.ECANCELED), on: connection)
        #expect(told.lines.count == 1)
        #expect(told.lines.first?.contains("Operation canceled") == true)
    }
}
