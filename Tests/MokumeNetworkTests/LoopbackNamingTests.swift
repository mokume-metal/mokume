// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation
import Network
import Synchronization
import Testing

@testable import MokumeNetwork

/// 送り手の前提が満たされなかった回の名乗り (#3001) の道具の検査。
///
/// 本物の繋ぎで揺れる赤そのものは手元で再現しない (CI で 3 回)。名乗りが読み分けの材料を
/// 揃えていることを、作り物の送り元と作り物の読み口で確かめる。**名乗りの各部を外すと、ここのどれかが赤になる。**
@Suite("送り手の前提の名乗り")
struct LoopbackNamingTests {
    @Test("rangesText は連なりを畳み、昇順で重ならずに書く")
    func rangesTextFoldsRuns() {
        #expect(rangesText([]) == "[]")
        #expect(rangesText([7, 0, 1, 2, 5, 8, 7]) == "[0…2, 5, 7…8]")
        #expect(rangesText([3]) == "[3]")
    }

    @Test("繋げなかった素の相手は、connect の errno と局所のポートと受け口のポートを名乗り、PeerGroup の名乗りにも載る (#3537)")
    func rawPeersNameAFailedConnect() async throws {
        let refuse: RawStream.Connector = { _, _ in EADDRINUSE }
        let streams = PeerGroup { StreamClient(port: 58147, connector: refuse) }
        defer { streams.closeAll() }
        let browsers = PeerGroup { BrowserSocket(port: 58147, connector: refuse) }
        defer { browsers.closeAll() }
        try await requireWait("素の相手が繋げなかったと名乗らなかった") {
            streams[0].state != .connecting && browsers[0].state != .connecting
        }
        for text in [streams.statesText, browsers.statesText] {
            #expect(text.contains("connect failed"), "\(text)")
            #expect(text.contains("errno \(EADDRINUSE) Address already in use"), "\(text)")
            #expect(text.contains("局所のポート"), "\(text)")
            #expect(text.contains("受け口のポート 58147"), "\(text)")
        }
        #expect(!streams[0].isReady && !browsers[0].isReady)
    }

    /// 閉じたポートへ繋ぎに行く相手の、名乗りの文面。**手放した番号を他が取って繋がってしまった回は、別の番号で
    /// 1 回だけやり直す** (並走する suite の `bind(0)` や ephemeral が同じ番号を取りうる)。それでも繋がれば止まる。
    private func refusedConnect(_ make: (Int) -> RawStream) async throws -> (port: Int, text: String) {
        var lastPort = 0
        for _ in 0..<2 {
            // 待ち受けて番号を知り、手放して閉じたポートにする
            let holder = try PortHolder(port: 0, stream: true)
            let port = holder.port
            lastPort = port
            holder.release()
            let peer = make(port)
            defer { peer.close() }
            let deadline = Date().addingTimeInterval(2)
            while Date() < deadline {
                if case .trouble = peer.state { return (port, peer.state.text) }
                if peer.state == .ready { break }
                try await Task.sleep(for: .milliseconds(10))
            }
        }
        try #require(Bool(false), "閉じたはずの番号 \(lastPort) へ 2 回とも繋がった (他が同じ番号を取った)")
        return (lastPort, "")
    }

    @Test("閉じたポートへ繋ぎに行く素の相手は、実経路 (EINPROGRESS → poll → SO_ERROR) で ECONNREFUSED を受け口のポートつきで名乗る (#3537)")
    func rawPeersNameARefusedConnectOnTheRealPath() async throws {
        let stream = try await refusedConnect { StreamClient(port: $0) }
        let browser = try await refusedConnect { BrowserSocket(port: $0) }
        for (port, text) in [stream, browser] {
            #expect(text.contains("connect failed"), "\(text)")
            #expect(text.contains("errno \(ECONNREFUSED) \(String(cString: strerror(ECONNREFUSED)))"), "\(text)")
            #expect(text.contains("受け口のポート \(port)"), "\(text)")
            #expect(text.contains("局所のポート"), "\(text)")
        }
        // 局所のポートが割り当てられなかった socket は、0 でなく「未割り当て」と名乗る
        let unassigned = StreamClient(port: 58147, connector: { _, _ in EADDRINUSE })
        defer { unassigned.close() }
        try await requireWait("名乗られなかった") { unassigned.state != .connecting }
        #expect(unassigned.state.text.contains("局所のポート 未割り当て"), "\(unassigned.state.text)")
        #expect(!unassigned.state.text.contains("局所のポート 0"), "\(unassigned.state.text)")
    }

    @Test("繋がる前の送りの名乗りは、後で繋がっても消えない。繋がった後に書けなかった errno も名乗り、向こうが閉じた後の送りは名乗らない (#3537)")
    func rawPeersKeepWhatTheyNamedAboutWrites() async throws {
        let listener = try PortHolder(port: 0, stream: true)
        defer { listener.release() }
        // 繋ぎを遅らせて、繋がる前に送る
        let late = StreamClient(
            port: listener.port,
            connector: { descriptor, port in
                usleep(200_000)
                return RawStream.systemConnector(descriptor, port)
            })
        defer { late.close() }
        late.send("early")
        #expect(late.state.text.contains("send before connected"), "\(late.state.text)")
        try await Task.sleep(for: .milliseconds(700))
        #expect(late.state.text.contains("send before connected"), "繋がった後に名乗りが消えた: \(late.state.text)")

        // 繋がった後、書く向きを閉じてから送ると EPIPE。向こうは閉じていないので名乗る
        let open = StreamClient(port: listener.port)
        defer { open.close() }
        try await requireWait("繋がらなかった") { open.state == .ready }
        open.finish()
        open.send("after finish")
        #expect(open.state.text.contains("send failed (errno \(EPIPE) "), "\(open.state.text)")
        #expect(open.state.text.contains("受け口のポート \(listener.port)"), "\(open.state.text)")
        #expect(!open.closedByPeer)

        // 向こうが閉じた後の送りは、受け口の約束の話ではないので名乗らない
        let closing = try PortHolder(port: 0, stream: true)
        let ended = StreamClient(port: closing.port)
        defer { ended.close() }
        try await requireWait("繋がらなかった") { ended.state == .ready }
        closing.release()
        try await requireWait("向こうが閉じたと読まなかった") { ended.closedByPeer }
        ended.send("late")
        ended.finish()
        #expect(ended.state == .ready, "\(ended.state.text)")
    }

    @Test("壊れた frame は名乗って読みを止めるが、向こうが閉じた (closedByPeer) とは読まない")
    func brokenFrameIsNotAClose() async throws {
        let stalled: RawStream.Connector = { _, _ in EINPROGRESS }
        let browser = BrowserSocket(port: 58147, connector: stalled)
        defer { browser.close() }
        let response =
            "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n"
            + "Sec-WebSocket-Accept: \(WebSocketFrames.accept(for: browser.key))\r\n\r\n"
        browser.receive(Array(response.utf8))
        #expect(browser.state == .ready, "\(browser.state.text)")
        browser.receive([0x81, 127, 0x80, 0, 0, 0, 0, 0, 0, 0])
        #expect(browser.state.text.contains("invalid frame from the receiver"), "\(browser.state.text)")
        #expect(!browser.closedByPeer)
        // 名乗った後は読まない (後ろの frame で状態が替わらない)
        browser.receive(WebSocketFrames.encode(opcode: 0x1, payload: Array("x".utf8), mask: [0, 0, 0, 0]))
        #expect(browser.received.isEmpty)
    }

    @Test("繋がる前の送りと finish は黙って捨てず、捨てたと名乗る。検査が閉じた後の送りは黙る (#3537)")
    func rawPeersNameASendBeforeConnected() async throws {
        // 繋ぎが済まないまま (EINPROGRESS のまま) の相手
        let stalled: RawStream.Connector = { _, _ in EINPROGRESS }
        let stream = StreamClient(port: 58147, connector: stalled)
        stream.send("hit\n")
        #expect(stream.state.text.contains("send before connected (4 バイトを捨てた"), "\(stream.state.text)")
        let browser = BrowserSocket(port: 58147, connector: stalled)
        browser.send("hit")
        #expect(browser.state.text.contains("send before connected"), "\(browser.state.text)")
        let finishing = StreamClient(port: 58147, connector: stalled)
        finishing.finish()
        #expect(finishing.state.text.contains("finish before connected"), "\(finishing.state.text)")

        // 閉じた後の送りは、検査が閉じたのだから名乗らない
        let closed = StreamClient(port: 58147, connector: stalled)
        closed.close()
        closed.send("late")
        #expect(closed.state == .connecting, "\(closed.state.text)")
        for peer in [stream, finishing, closed] { peer.close() }
        browser.close()
    }

    @Test("WebSocket の frame の長さは 125 / 126 / 65536 バイトで符号化の形が替わり、符号化した frame は読み戻せる (マスクされる)")
    func webSocketFrameLengthsRoundTrip() {
        let mask: [UInt8] = [0x11, 0x22, 0x33, 0x44]
        // (中身の大きさ, 長さの欄の大きさ): 125 は 7 ビット、126〜65535 は 16 ビット、65536 から 64 ビット
        for (size, lengthField) in [(0, 0), (125, 0), (126, 2), (65535, 2), (65536, 8)] {
            let payload = (0..<size).map { UInt8($0 % 251) }
            let frame = WebSocketFrames.encode(opcode: 0x2, payload: payload, mask: mask)
            #expect(frame.count == 2 + lengthField + 4 + size, "size \(size)")
            #expect(frame[1] & 0x80 != 0, "client の frame はマスクする (size \(size))")
            #expect(frame[1] & 0x7F == (size < 126 ? UInt8(size) : (size <= 0xFFFF ? 126 : 127)), "size \(size)")
            #expect(
                WebSocketFrames.decode(frame)
                    == .frame(.init(fin: true, opcode: 0x2, payload: payload), consumed: frame.count),
                "size \(size)")
            // 途中までは揃っていない
            #expect(WebSocketFrames.decode(Array(frame.dropLast())) == .incomplete, "size \(size)")
        }
        // server の frame (マスクなし) の 126 / 127 の長さの欄を読む
        let medium = [UInt8](repeating: 7, count: 300)
        let sixteen = [UInt8(0x81), 126, UInt8(300 >> 8), UInt8(300 & 0xFF)] + medium
        #expect(
            WebSocketFrames.decode(sixteen)
                == .frame(.init(fin: true, opcode: 0x1, payload: medium), consumed: sixteen.count))
        let sixtyFour = [UInt8(0x81), 127, 0, 0, 0, 0, 0, 0, UInt8(300 >> 8), UInt8(300 & 0xFF)] + medium
        #expect(
            WebSocketFrames.decode(sixtyFour)
                == .frame(.init(fin: true, opcode: 0x1, payload: medium), consumed: sixtyFour.count))
    }

    @Test("WebSocket の frame の長さの上限ちょうどは揃うのを待ち、上限 + 1 は範囲外と読む")
    func webSocketFrameLengthLimitIsExact() {
        func header(_ length: Int) -> [UInt8] {
            [0x81, 127] + (0..<8).map { UInt8((length >> (8 * (7 - $0))) & 0xFF) }
        }
        #expect(WebSocketFrames.decode(header(WebSocketFrames.payloadLimit)) == .incomplete)
        guard case .invalid = WebSocketFrames.decode(header(WebSocketFrames.payloadLimit + 1)) else {
            Issue.record("上限 + 1 を範囲外と読まなかった")
            return
        }
    }

    @Test("WebSocket の壊れた frame (長さの上位ビット・大きすぎる長さ) は、落ちずに範囲外と読む")
    func webSocketFrameLengthOutOfRange() {
        let highBit: [UInt8] = [0x81, 127, 0x80, 0, 0, 0, 0, 0, 0, 0]
        let all: [UInt8] = [0x81, 127, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF]
        let big: [UInt8] = [0x81, 127, 0, 0, 0, 0, 0x10, 0, 0, 0]
        for bytes in [highBit, all, big] {
            guard case .invalid(let reason) = WebSocketFrames.decode(bytes) else {
                Issue.record("範囲外と読まなかった: \(bytes)")
                continue
            }
            #expect(reason.contains("out of range"), "\(reason)")
        }
    }

    @Test("期限つきの読みは、答えない読みを期限で諦めて nil を返し、答える読みはその値を返す")
    func readWithinGivesUpOnABlockedRead() async {
        let gate = DispatchSemaphore(value: 0)
        let started = Date()
        let blocked: Int? = await readWithin(0.2) {
            gate.wait()
            return 1
        }
        #expect(blocked == nil)
        #expect(Date().timeIntervalSince(started) < 3, "期限を越えて待った")
        gate.signal()
        #expect(await readWithin(1) { 7 } == 7)
    }

    @Test("受け口の待ち行列が答えなければ、答えなかったと名乗り、受け入れ・持つ数は読めたふりをしない。送り手の名乗りは受け口の知らせに入れない")
    func receiverViewNamesAQueueThatDidNotAnswer() async {
        let told = Told()
        told.append("Could not send to 127.0.0.1:1 (Address already in use)")
        told.append("udp :1 is in use")
        let gate = DispatchSemaphore(value: 0)
        let view = await receiverView(.running, tracing: nil, told: told, within: 0.2) {
            gate.wait()
            return (SenderTally(), 0)
        }
        gate.signal()
        #expect(view.tally == nil && view.connections == nil)
        #expect(view.accepted == nil)
        #expect(view.text.contains("受け口の待ち行列が 0.2 秒答えなかった"), "\(view.text)")
        #expect(!view.text.contains("受け入れ 0"), "\(view.text)")
        // 受け口の知らせは残し、送り手の行は除く (送り手の行は送り手の側で数える)
        #expect(view.told == ["udp :1 is in use"])
        #expect(view.text.contains("受け口の知らせ 1 行"), "\(view.text)")

        let answered = await receiverView(.running, tracing: nil, told: told, within: 1) {
            (SenderTally(accepted: 3, closedIdle: 2, ended: 1), 4)
        }
        #expect(answered.text.contains("受け入れ 3・黙りで閉じた 2・終わって外れた 1・持つ数 4"), "\(answered.text)")
    }

    /// 呼ばれた順を記録する作り物の読み口。
    private final class Calls: Sendable {
        let order = Mutex<[String]>([])
        func add(_ name: String) { order.withLock { $0.append(name) } }
    }

    private func scripted(
        _ calls: Calls = Calls(), before: Int?, after: Int?, probe: Bool
    ) -> Landing {
        let views = Mutex([before, after])
        return Landing(
            receiver: {
                calls.add("受け口")
                let accepted = views.withLock { $0.isEmpty ? nil : $0.removeFirst() } ?? nil
                return ReceiverView(
                    state: .running, trace: nil,
                    tally: accepted.map { SenderTally(accepted: $0) }, connections: accepted,
                    told: [], patience: 3)
            },
            probe: {
                calls.add("1 通")
                return probe
            })
    }

    @Test("1 通が読まれても、受け入れの数が増えなければ別の繋ぎで渡されたと名乗り、増えれば新しい送り元を受けられたと名乗る")
    func requireSentNamesTheAcceptedDifference() async throws {
        let log = SendLog()
        let unchanged = try await said {
            try await requireSent(
                false, "読めなかった", log: log, landing: scripted(before: 5, after: 5, probe: true))
        }
        #expect(unchanged.contains("読めたが受け入れは増えていない (差 0。別の繋ぎで渡された)"), "\(unchanged)")

        let grown = try await said {
            try await requireSent(
                false, "読めなかった", log: log, landing: scripted(before: 5, after: 6, probe: true))
        }
        #expect(grown.contains("読めた・受け入れ +1 (新しい送り元を受けられた)"), "\(grown)")

        let notRead = try await said {
            try await requireSent(
                false, "読めなかった", log: log, landing: scripted(before: 5, after: 5, probe: false))
        }
        #expect(notRead.contains("読めなかった (受け口が 3 秒のうちに新しい送り元の datagram を渡さなかった)"), "\(notRead)")

        // 受け口の待ち行列が答えなければ、受け入れの数の差は言えない
        let unanswered = try await said {
            try await requireSent(
                false, "読めなかった", log: log, landing: scripted(before: nil, after: nil, probe: true))
        }
        #expect(unanswered.contains("読めた (受け入れの数は読めない)"), "\(unanswered)")
        #expect(unanswered.contains("受け口の待ち行列が 3.0 秒答えなかった"), "\(unanswered)")

        // 1 通で分からないことを、どの名乗りにも正直に書く
        for text in [unchanged, grown, notRead, unanswered] {
            #expect(text.contains("一度に来たときだけ受け口で落ちる形は、この 1 通では分からない"), "\(text)")
        }
    }

    @Test("素の socket から送る記録は、名乗りの 0 行を黙っていると読ませず、替えた回数を言わず、様子を読めない送り元と名乗り、待っただけの段も秒数を名乗る")
    func requireSentNamesARawSocketSender() async throws {
        let log = SendLog(rawSocket: true)
        log.watch("素の socket") { nil }
        log.record(
            label: "素の socket", expected: 3, heard: 1, missing: nil, replacements: 0,
            heardAfterReplacement: 0, waited: 1, limit: 5)
        let text = try await said {
            try await requireSent(
                false, "読めなかった", log: log, landing: scripted(before: 5, after: 6, probe: true))
        }
        #expect(text.contains("素の socket: 読めたのは 1/3・読めなかった 2 通 (どの通かは分からない)"), "\(text)")
        #expect(text.contains("送り元の様子 {様子を読めない送り元}×1"), "\(text)")
        #expect(text.contains("素の socket から直に送った"), "\(text)")
        #expect(!text.contains("黙っている") && !text.contains("替えた"), "\(text)")
        #expect(text.contains("待った 1.0 秒/期限 5.0 秒"), "\(text)")

        // 通の数を数えない待ちは、待った秒数と期限だけを足す (数え方の欄は出ない)
        let waiting = SendLog(rawSocket: true)
        waiting.recordWait(waited: 0.5, limit: 2)
        waiting.recordWait(waited: 0.3, limit: 3)
        #expect(waiting.waitText == "待った 0.8 秒/期限 5.0 秒", "\(waiting.waitText)")
        #expect(!waiting.senderText.contains("読めたのは"), "\(waiting.senderText)")

        // 素の socket でない記録は、従来どおり黙っていると名乗る
        let silent = try await said {
            try await requireSent(
                false, "読めなかった", log: SendLog(), landing: scripted(before: 5, after: 6, probe: true))
        }
        #expect(silent.contains("名乗りは 0 行 (黙っている)"), "\(silent)")
    }

    @Test("素の socket の sendto が失敗していたら、送り手で出なかったと名乗って受け口のせいと読ませず、成功していればそう言い、戻りを記録していなければそう言う")
    func requireSentNamesTheRawSendResult() async throws {
        let peer = try RawDatagramSocket()
        defer { peer.release() }
        // ポート 0 へは送れない (送り手で出ない形)
        #expect(peer.send([1, 2, 3], to: 0) == -1)
        #expect(peer.sendRecord.attempts == 1 && peer.sendRecord.failures == 1)
        #expect(peer.sendRecord.firstFailure?.requested == 3)

        let log = SendLog(rawSocket: true)
        log.watch(raw: peer)
        let failed = try await said {
            try await requireSent(
                false, "読めなかった", log: log, landing: scripted(before: 5, after: 5, probe: true))
        }
        #expect(failed.contains("素の socket の sendto が失敗した: 1 回のうち 1 回・最初の失敗は errno "), "\(failed)")
        #expect(failed.contains("3 バイトを送ろうとした"), "\(failed)")
        #expect(failed.contains("送り手で出なかった回があり、読めなかった理由は受け口ではなく送り手側の見込み"), "\(failed)")
        #expect(!failed.contains("とも成功"), "\(failed)")

        // 送れていれば、そう言う (誰も待っていないポートへも、sendto 自体は成功する)
        let sender = try RawDatagramSocket()
        defer { sender.release() }
        #expect(sender.send(Array("hello".utf8), to: 9) == 5)
        #expect(sender.send(Array("x".utf8), to: 9) == 1)
        let sentLog = SendLog(rawSocket: true)
        sentLog.watch(raw: sender)
        let sent = try await said {
            try await requireSent(
                false, "読めなかった", log: sentLog, landing: scripted(before: 5, after: 5, probe: true))
        }
        #expect(sent.contains("sendto は 2 回とも成功 (計 6 バイト)"), "\(sent)")
        #expect(!sent.contains("送り手で出なかった"), "\(sent)")

        // 戻りを記録していない記録 (送った socket を渡さなかった) は、そう言う
        let unwatched = try await said {
            try await requireSent(
                false, "読めなかった", log: SendLog(rawSocket: true),
                landing: scripted(before: 5, after: 5, probe: true))
        }
        #expect(unwatched.contains("sendto の戻りは記録していない"), "\(unwatched)")
    }

    @Test("名乗りは、送り手の様子と受け口の様子を同じ時点で撮ってから 1 通を送り、その後にもう 1 度受け口を撮る。満たされたときは何もしない")
    func requireSentTakesSnapshotsAroundTheProbe() async throws {
        let calls = Calls()
        let log = SendLog()
        log.watch {
            calls.add("送り手")
            return nil
        }
        _ = try await said {
            try await requireSent(
                false, "読めなかった", log: log, landing: scripted(calls, before: 1, after: 2, probe: true))
        }
        #expect(calls.order.withLock { $0 } == ["送り手", "受け口", "1 通", "受け口"])

        let satisfied = Calls()
        try await requireSent(
            true, "名乗らない", log: log, landing: scripted(satisfied, before: 1, after: 2, probe: true))
        #expect(satisfied.order.withLock { $0 }.isEmpty)
    }

    @Test("読めなかった番号と、そのうち名乗った送り元・黙っている送り元を、名乗りが届いた順に依らず同じ文で名乗る")
    func senderTextNamesMissingNumbersInAStableOrder() {
        func log(arrival: [Int]) -> SendLog {
            let log = SendLog()
            for index in 0..<6 {
                let trace = SendTrace(
                    issued: 1, completed: index == 4 ? 1 : 0, failed: 0,
                    state: index == 4 ? "ready" : "preparing")
                log.watch("/from", index: index) { trace }
            }
            for index in arrival {
                log.complain("Could not send to 127.0.0.1:9 (Address already in use)", label: "/from", index: index)
            }
            // 0 と 3 は読めた。1・2・4・5 は読めなかった (1 と 5 が名乗った)
            log.record(
                label: "/from", expected: 6, heard: 2, missing: [1, 2, 4, 5], replacements: 2,
                heardAfterReplacement: 1, waited: 1.5, limit: 2)
            return log
        }
        let first = log(arrival: [5, 1, 3]).senderText
        let second = log(arrival: [3, 1, 5]).senderText
        #expect(first == second, "名乗りの届いた順で文が揺れた")
        #expect(
            first.contains("/from: 読めたのは 2/6・読めなかった 4 本 [1…2, 4…5]・うち名乗った [1, 5]・名乗らずに黙っている [2, 4]"),
            "\(first)")
        // 読めなかった側と読めた側で、送り元の様子を分けて数える。名乗った 3 は読めた側
        #expect(
            first.contains("読めなかった側の送り元の様子 {出 1・誤り無し 0・誤り 0・最後 preparing}×3 {出 1・誤り無し 1・誤り 0・最後 ready}×1"),
            "\(first)")
        #expect(first.contains("読めた側の送り元の様子 {出 1・誤り無し 0・誤り 0・最後 preparing}×2"), "\(first)")
        #expect(first.contains("名乗った送り元 /from[1, 3, 5]・名乗り 3 行"), "\(first)")
        #expect(log(arrival: []).senderText.contains("名乗りは 0 行 (黙っている)"))
    }

    // MARK: - 待ちの道具 (#3124)

    @Test("前提を待つ道具は、満たされなければ何が・どれだけ待って満たされなかったかを名乗って止まり、満たされれば何も言わない")
    func requireWaitNamesWhatDidNotHappen() async throws {
        let bare = try await said {
            try await requireWait("相手が閉じなかった", within: 0.1) { false }
        }
        #expect(bare.contains("相手が閉じなかった"), "\(bare)")
        #expect(bare.contains("期限 0.1 秒"), "\(bare)")

        let detailed = try await said {
            try await requireWait("数が揃わなかった", within: 0.1, detail: { "数えたのは 2" }) { false }
        }
        #expect(detailed.contains("数が揃わなかった") && detailed.contains("数えたのは 2"), "\(detailed)")

        // 満たされれば、止まらずに返る (止まれば検査が赤になる)
        try await requireWait("すぐ満ちる", within: 0.1) { true }
    }

    @Test("集める道具は、足りなければ個数と読めた数と手がかりを名乗って止まり、揃えば読めたものを返す")
    func requireCollectedNamesTheShortfall() async throws {
        var given = false
        let short = try await said {
            _ = try await requireCollected(
                count: 3, within: 0.1, what: "受け口が読めなかった", detail: { "状態: running" }
            ) {
                defer { given = true }
                return given ? [] : ["a"]
            }
        }
        #expect(short.contains("受け口が読めなかった"), "\(short)")
        #expect(short.contains("3 個のうち読めたのは"), "\(short)")
        #expect(short.contains("状態: running"), "\(short)")

        var round = 0
        let enough = try await requireCollected(count: 3, within: 1, what: "集める") {
            round += 1
            return round == 1 ? ["a", "b"] : ["c"]
        }
        #expect(enough == ["a", "b", "c"])
    }

    @Test("満たされなかったときの名乗りを呼ぶ側が行う待ちは、名乗る段を呼び、その段が投げなくても止まる")
    func requireArrivalCallsTheNamingStep() async throws {
        let called = Mutex(0)
        let thrown = try await said {
            try await requireArrival("着かなかった", within: 0.1, until: { false }) {
                called.withLock { $0 += 1 }
                try #require(Bool(false), "名乗る段の文")
            }
        }
        #expect(called.withLock { $0 } == 1)
        #expect(thrown.contains("名乗る段の文"), "\(thrown)")

        let silent = try await said {
            try await requireArrival("着かなかった", within: 0.1, until: { false }) {
                called.withLock { $0 += 1 }
            }
        }
        #expect(silent.contains("着かなかった"), "名乗る段が黙っても止まる: \(silent)")

        try await requireArrival("すぐ着く", within: 0.1, until: { true }) {
            called.withLock { $0 += 100 }
        }
        #expect(called.withLock { $0 } == 2, "満たされたら名乗る段は呼ばない")
    }

    @Test("起きないことの観測は、期限まで起きなければ真、起きれば偽")
    func doesNotHappenIsTrueOnlyWhenItNeverHappens() async {
        #expect(await doesNotHappen(within: 0.05) { false })
        #expect(await !doesNotHappen(within: 0.5) { true })
    }
}
