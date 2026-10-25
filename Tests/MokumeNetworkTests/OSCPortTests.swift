// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Darwin
import Foundation
import Synchronization
import Testing

@testable import MokumeCore
@testable import MokumeNetwork

/// 127.0.0.1 のポートを握る。他のアプリがそのポートを使っている状態を作る。
///
/// 既定は UDP のソケット。`stream` なら TCP のソケットで握り、待ち受けまで始める
/// (TCP・WebSocket の受け口が使用中を見分けるのは、相手が待ち受けているときである)。
nonisolated final class PortHolder: Sendable {
    let port: Int
    private let descriptor: Int32

    struct Failure: Error {
        let call: String
        let code: Int32
    }

    /// 誰も受けない 127.0.0.1 の UDP の口を、**番号を手放さずに**作る (#2542)。
    ///
    /// 番号 0 で握った UDP の socket を、送り手ではない相手 (127.0.0.1:1) へ繋いでおく。繋いだ UDP の
    /// socket は繋いだ相手以外からの datagram を受けないので、届いた datagram はどの socket にも
    /// 当たらず、拒否 (ICMP の port unreachable) が送り手の次の送信の失敗として返る。**握っている間は、
    /// 他のプロセスが同じ番号を bind できない** (`EADDRINUSE`)。番号を選んで手放してから狙う形は、
    /// 手放してから狙うまでの間に他が番号を取りうる (#2359 と同じ隙間)。検査の終わりに ``release()``
    /// で手放す。
    static func unanswered() throws -> PortHolder {
        try PortHolder(port: 0, stream: false, connectingAway: true)
    }

    convenience init(port: Int, stream: Bool = false) throws {
        try self.init(port: port, stream: stream, connectingAway: false)
    }

    private init(port: Int, stream: Bool, connectingAway: Bool) throws {
        let descriptor = socket(AF_INET, stream ? SOCK_STREAM : SOCK_DGRAM, 0)
        guard descriptor >= 0 else { throw Failure(call: "socket", code: errno) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(UInt16(port).bigEndian)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0 else {
            let code = errno
            close(descriptor)
            throw Failure(call: "bind", code: code)
        }
        if stream, Darwin.listen(descriptor, 4) != 0 {
            let code = errno
            close(descriptor)
            throw Failure(call: "listen", code: code)
        }
        if connectingAway {
            var away = sockaddr_in()
            away.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            away.sin_family = sa_family_t(AF_INET)
            away.sin_port = in_port_t(UInt16(1).bigEndian)
            away.sin_addr.s_addr = inet_addr("127.0.0.1")
            let connected = withUnsafePointer(to: &away) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
            guard connected == 0 else {
                let code = errno
                close(descriptor)
                throw Failure(call: "connect", code: code)
            }
        }
        var actual = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &actual) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(descriptor, $0, &length)
            }
        }
        self.descriptor = descriptor
        self.port = Int(UInt16(bigEndian: actual.sin_port))
    }

    /// 握っていた番号を手放す。
    ///
    /// **手放してから受け口が同じ番号を開き直すまでの間に、他のプロセスが番号を取りうる** (#2542)。
    /// 「他が握っていれば unavailable、空けば受け始める」を確かめる検査は、この隙間そのものが目的
    /// (空いたら受け始める) なので閉じる手が無い (#2359 の決定で残している)。取られても受け口は
    /// unavailable のままで、検査は期限で赤くなるだけで、緑にはならない — 確かめることは変わらず、
    /// 変わるのは揺れの確率だけである。
    ///
    /// 2 度目からは何もしない。検査の途中で手放す口 (受け手を同じ番号で開く前など) も、終わりの
    /// `defer` で重ねて呼べる — 2 度閉じると、その間に同じ番号を振り直された別の descriptor を閉じうる。
    func release() {
        guard held.withLock({ held in defer { held = false }; return held }) else { return }
        close(descriptor)
    }

    private let held = Mutex(true)
}

/// 作り物の送り元 (#2910)。通信の揺れを入れずに、番号つきの送りの補助が名乗りをどう読むかを確かめる。
///
/// `raw` があればそれで受け口へ出し、無ければ何も出さない。`complaint` があれば、送るとき (と、
/// `complainsOnStop` なら閉じるとき) に送れないと名乗る。
nonisolated final class ScriptedSender: DatagramSending, SendTracing {
    private let raw: RawDatagramSocket?
    private let port: Int
    private let complaint: (@Sendable (String) -> Void)?
    private let complainsOnStop: Bool
    private let traced: Mutex<SendTrace>

    /// - Parameter trace: 名乗りに載る送り手の跡 (``SendTrace``)。送るたびに `issued` が増える。
    init(
        raw: RawDatagramSocket?, port: Int, complaint: (@Sendable (String) -> Void)?,
        complainsOnStop: Bool = false, trace: SendTrace = SendTrace()
    ) {
        self.raw = raw
        self.port = port
        self.complaint = complaint
        self.complainsOnStop = complainsOnStop
        traced = Mutex(trace)
    }

    var sendTrace: SendTrace { traced.withLock { $0 } }

    func send(_ bytes: [UInt8]) {
        traced.withLock { $0.issued += 1 }
        complaint?("Could not send to 127.0.0.1:\(port) (Address already in use)")
        _ = raw?.send(bytes, to: port)
    }

    func stop() {
        if complainsOnStop {
            complaint?("Could not send to 127.0.0.1:\(port) (Address already in use)")
        }
    }
}

/// 知らせの行き先。どのスレッドから書かれてもよい。
nonisolated final class Told: Sendable {
    private let store = Mutex<[String]>([])
    func append(_ line: String) { store.withLock { $0.append(line) } }
    var lines: [String] { store.withLock { $0 } }
    func count(containing text: String) -> Int { lines.filter { $0.contains(text) }.count }
}

/// 受けるポートを OS が選ぶ入り口 (番号 0) の送り先。受け始めて番号が分かってから、そこへ向ける。
///
/// **空きポートの番号を先に選んで手放し、あとから開く形にしない。** 手放してから開くまでの間に
/// 別のプロセス (並行する他のセッションの検査など) がその番号を取ると、使用中として断られて
/// 落ちる (#2359)。番号は 0 を頼んで、開いた後に読む。
nonisolated final class AimedSender: DatagramSending, SendTracing {
    private let target = Mutex<DatagramSender?>(nil)
    private let warn: @Sendable (String) -> Void

    init(warn: @escaping @Sendable (String) -> Void) { self.warn = warn }

    /// 127.0.0.1 の `port` へ向ける。
    func aim(at port: Int) {
        target.withLock { $0 = DatagramSender(host: "127.0.0.1", port: port, warn: warn) }
    }

    func send(_ bytes: [UInt8]) { target.withLock { $0?.send(bytes) } }
    func stop() { target.withLock { $0?.stop() } }

    /// 向けた先の送り手の跡。まだ向けていなければ空 (名乗りでは「出 0」)。
    var sendTrace: SendTrace { target.withLock { $0?.sendTrace ?? SendTrace() } }
}

/// 検査から動かせる時計 (秒)。受け口が送り元の黙りを測る時計の代わりに渡す。
/// どのスレッドから読まれてもよい (受け口は自分の待ち行列の上で読む)。
nonisolated final class ManualClock: Sendable {
    private let seconds: Mutex<TimeInterval>
    init(_ start: TimeInterval) { seconds = Mutex(start) }
    var provider: @Sendable () -> TimeInterval { { [self] in seconds.withLock { $0 } } }
    func advance(by interval: TimeInterval) { seconds.withLock { $0 += interval } }
}

/// 送ったバイト列を溜める送り手。通信はしない。
nonisolated final class RecordingSender: DatagramSending {
    private let store = Mutex<[[UInt8]]>([])
    var sent: [[UInt8]] { store.withLock { $0 } }
    func send(_ bytes: [UInt8]) { store.withLock { $0.append(bytes) } }
    func stop() {}
}

/// 作る口が値を検めるためだけのスケッチ。走らせない。
final class IdleSketch: Sketch {
    init() {}
    func draw() {}
}

/// OSC の入り口 (#1962)。GPU は要らない。通信は 127.0.0.1 だけで行う (別の機械には届かない)。
///
/// 入り口を走っているスケッチに足さず、フレームの代わりに ``OSCPort/supply()`` を自分で呼ぶ。
/// **待つ側が期限を持つ** — 届くのを待つ検査は、期限を越えたら満たされなかったとして落ちる。
@Suite("OSC の入り口", .serialized)
struct OSCPortTests {
    /// フレームを回すように取り出しを続け、`count` 個届くまで (か期限まで) 集める。
    ///
    /// 読めた数と待った秒数を `log` に数える (読まれなかった回の名乗りの材料 — #3001)。足りなくても名乗らずに
    /// 短い列を返すので、`log` は必須で、呼ぶ側が ``requireSent(_:_:log:landing:)`` で名乗る (#3124)。
    private func collect(
        _ osc: OSCPort, count: Int, within seconds: TimeInterval = 5, label: String = "送り",
        log: SendLog
    ) async -> [OSCMessage] {
        await collectCounting(count: count, within: seconds, label: label, log: log) {
            osc.supply()
            return osc.messages
        }
    }

    /// 番号を載せた OSC (`address <番号>`) を `count` 個の送り元から 1 通ずつ送り、番号が全部読まれるまで
    /// (か期限まで) 集めて、読まれた番号を返す。
    ///
    /// **送った datagram が全部読まれる前提を置かない** (#2910)。全段が並走する負荷の下では、送り手の
    /// 繋ぎが作れず (`Address already in use` で `waiting` のまま) 出ない datagram があり、待っても
    /// 回復しない。受け口が落とすのではなく送る前の話だが、検査から見れば読まれない番号である。だから
    /// **送れないと名乗った送り元の番号が、まだ読まれていなければ、新しい送り元に替えて**送り直す
    /// (同じ送り元の繋ぎは待ったまま動かないことがある)。替えた古い送り元は閉じる。
    ///
    /// **替えた後の古い送り元の名乗りは数えない。** 閉じた後に遅れて返る `waiting` を、同じ番号の二度目の
    /// 名乗りとして替え直さない。
    ///
    /// **名乗らない送り元は替えない。** 出ていても、受け口の読みが遅れているだけのことがあり、新しい
    /// 送り元を足すと、読む前の繋ぎが台帳に残って (読む前の繋ぎは黙りで閉じない — ``SenderLedger``)
    /// 数が目安から下がらなくなる。名乗らずに読まれない番号は、期限 (`seconds`) まで待って、読まれた
    /// 分だけを返す。呼ぶ側は、返った番号が足りなくても先へ進めるようにする。替えるのは 1 つの番号に
    /// つき `replacements` 回まで。
    ///
    /// 送り元は番号の順に `senders` の末尾へ足す。呼ぶ側が検査の終わりに閉じる。
    ///
    /// 読まれなかった回の名乗り (#3001) のため、読まれなかった番号・替えた回数・替えた後に読まれた番号・
    /// 送り元ごとの名乗りの行と跡 (``SendTrace``) を、宛名 (`address`) の名で `log` に数える。呼ぶ側が
    /// ``requireSent(_:_:log:landing:)`` で名乗って止まる。**名乗らない送り元を替えず、期限を延ばさず、
    /// 救わない**のは、ここでも同じ。
    ///
    /// - Parameter makeSender: 番号と、何度目の送り元か (1 から) と、送れないときの知らせの行き先を受けて、
    ///   送り元を作る。知らせは `told` にも流す。
    private func sendNumberedBurst(
        count: Int, address: String = "/from", through osc: OSCPort,
        senders: inout [any DatagramSending], told: Told,
        replacements: Int = 3, within seconds: TimeInterval = 10, log: SendLog = SendLog(),
        makeSender:
            (_ index: Int, _ attempt: Int, _ warn: @escaping @Sendable (String) -> Void) ->
            any DatagramSending
    ) async throws -> Set<Int> {
        let first = senders.count
        let stuck = Mutex<Set<Int>>([])
        // 番号ごとの、いま生きている送り元が何度目か。古い送り元の名乗りを見分ける
        let current = Mutex([Int](repeating: 1, count: count))
        var attempts = [Int](repeating: 1, count: count)
        func sender(_ index: Int) -> any DatagramSending {
            let attempt = attempts[index]
            let opened = makeSender(index, attempt) { line in
                told.append(line)
                log.complain(line, label: address, index: index)
                guard current.withLock({ $0[index] }) == attempt else { return }
                stuck.withLock { _ = $0.insert(index) }
            }
            log.watch(address, index: index, sender: opened)
            return opened
        }
        for index in 0..<count {
            let opened = sender(index)
            senders.append(opened)
            opened.send(try Wire.encoded(OSCMessage(address, index)))
        }
        var heard = Set<Int>()
        let started = Date()
        let deadline = started.addingTimeInterval(seconds)
        while heard.count < count, Date() < deadline {
            osc.supply()
            heard.formUnion(osc.messages.filter { $0.address == address }.compactMap { $0.int(0) })
            let blocked = stuck.withLock { names in defer { names = [] }; return names }
            for index in blocked.sorted() where !heard.contains(index) && attempts[index] <= replacements {
                attempts[index] += 1
                current.withLock { $0[index] = attempts[index] }
                senders[first + index].stop()
                let opened = sender(index)
                senders[first + index] = opened
                opened.send(try Wire.encoded(OSCMessage(address, index)))
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        let missing = (0..<count).filter { !heard.contains($0) }
        log.record(
            label: address, expected: count, heard: count - missing.count, missing: missing,
            replacements: attempts.reduce(0) { $0 + $1 - 1 },
            heardAfterReplacement: (0..<count).filter { heard.contains($0) && attempts[$0] > 1 }.count,
            waited: Date().timeIntervalSince(started), limit: seconds)
        return heard
    }

    /// 送りの前提 (送った番号・通が読まれる) が満たされなかった回の名乗り (#3001)。受け口は `osc`、素の socket の
    /// 1 通は `port` へ送る。名乗りの中身と救わない理由は ``requireSent(_:_:log:landing:)``。
    private func requireHeard(
        _ ok: Bool, _ what: @autoclosure () -> String, log: SendLog, osc: OSCPort, port: Int, told: Told
    ) async throws {
        try await requireSent(
            ok, what(), log: log, landing: landing(of: osc, port: port, told: told))
    }

    /// 素の socket から送った通が `count` 通読まれるのを待つ。読まれなければ、受け口の様子と素の 1 通の前後の
    /// 受け入れの差を名乗って 1 つで止まる (#3105)。名乗りは ``requireSent(_:_:log:landing:)``・
    /// 素の socket の記録は ``collectOrName(_:count:within:landing:_:)`` と同じ。
    private func heard(
        _ osc: OSCPort, count: Int, within seconds: TimeInterval = 5, port: Int, told: Told,
        from peer: RawDatagramSocket, _ note: String = ""
    ) async throws -> [OSCMessage] {
        try await collectOrName(
            count: count, within: seconds, from: peer, landing: landing(of: osc, port: port, told: told), note
        ) { count, seconds, label, log in
            await collect(osc, count: count, within: seconds, label: label, log: log)
        }
    }

    /// 127.0.0.1 で、OS が選んだポート (0 を頼む) で受け、送り先も同じポートにした入り口。開いて、
    /// 受け始めてから、実際に開いたポートと一緒に返す。
    ///
    /// 空きポートを先に選んで手放すと、開くまでの間に別のプロセスに取られうる (#2359) ので、
    /// 受けるポートはここでしか決めない。
    private func listening(
        told: Told, idleAfter: TimeInterval = DatagramListener.defaultIdleAfter,
        now: (@Sendable () -> TimeInterval)? = nil
    ) async throws -> (osc: OSCPort, port: Int) {
        let aimed = AimedSender(warn: told.append)
        let osc = try loopback(
            port: 0, told: told, outbound: aimed, idleAfter: idleAfter, now: now)
        do {
            try await requireState(told: told, tracing: osc.source) { osc.state }
        } catch {
            osc.close()
            throw error
        }
        guard let port = (osc.source as? NetworkOSCSource)?.boundPort else {
            osc.close()
            throw MissingPort(state: osc.state, told: told.lines)
        }
        aimed.aim(at: port)
        return (osc, port)
    }

    /// `running` になったのに、開いたポートの番号を読めなかった。
    private struct MissingPort: Error {
        let state: SourceState
        let told: [String]
    }

    /// 127.0.0.1 の `port` で受け、送り先も同じポートにした入り口。開いて返す (受け始めるのは待たない)。
    ///
    /// 受けるポートの番号が要るなら ``listening(told:idleAfter:now:)`` を使う。
    /// こちらは番号を決めて渡す口で、他のアプリが握っているポートを名指しする検査だけが使う。
    private func loopback(
        port: Int, told: Told, outbound: (any DatagramSending)? = nil,
        idleAfter: TimeInterval = DatagramListener.defaultIdleAfter,
        now: (@Sendable () -> TimeInterval)? = nil
    ) throws -> OSCPort {
        // 時計を渡さなければ、本番 (`createOSC`) と同じく出どころの既定の時計で測る
        let source =
            if let now {
                NetworkOSCSource(
                    port: port, host: "127.0.0.1", retryAfter: 0.05, idleAfter: idleAfter, now: now,
                    warn: told.append)
            } else {
                NetworkOSCSource(
                    port: port, host: "127.0.0.1", retryAfter: 0.05, idleAfter: idleAfter,
                    warn: told.append)
            }
        let osc = OSCPort(
            port: port, name: "osc :\(port)",
            source: source,
            outbound: outbound ?? DatagramSender(host: "127.0.0.1", port: port, warn: told.append),
            owner: nil, warn: told.append)
        try osc.open()
        return osc
    }

    /// 送るメッセージの台本。大きさを動かし、当たりを数える。
    static let script: [OSCMessage] = [
        OSCMessage("/size", Float(0.25)),
        OSCMessage("/hit", 1),
        OSCMessage("/size", Float(0.75)),
        OSCMessage("/label", "fade"),
        OSCMessage("/hit", 1),
    ]

    /// 台本を読んだ結果。作例のスケッチがすることと同じ (大きさを置き換え、当たりを足す)。
    struct Outcome: Equatable {
        var size: Float = 0.5
        var hits = 0

        init(_ messages: [OSCMessage]) {
            for message in messages {
                switch message.address {
                case "/size": size = message.float(0) ?? size
                case "/hit": hits += message.int(0) ?? 0
                default: break
                }
            }
        }
    }

    // MARK: - 同じ機械の中で送って受ける

    @Test("自分で送ったメッセージを、自分のポートで受ける")
    func sendsToItselfAndReceives() async throws {
        let told = Told()
        let (osc, port) = try await listening(told: told)
        defer { osc.close() }
        let log = SendLog()
        log.watch { osc.sendTrace }

        osc.send("/size", Float(0.25))
        osc.send("/hit", 1)
        let received = await collect(osc, count: 2, log: log)
        try await requireHeard(
            received.count >= 2, "2 通のうち読めたのは \(received.count) 通", log: log, osc: osc, port: port,
            told: told)
        #expect(received == [OSCMessage("/size", Float(0.25)), OSCMessage("/hit", 1)])
        #expect(osc.lastArrival != nil)
        #expect(osc.report == SourceReport(name: "osc :0", state: .running, lastArrival: osc.lastArrival))
        #expect(told.lines.isEmpty)

        osc.close()
        #expect(osc.state == .stopped)
        #expect(osc.messages.isEmpty)
    }

    @Test("外して足し直した (close の後に open が来る) 入り口は、受け取りも送信も戻る。外し直せばまた 1 度だけ知らせて送らない (#3122)")
    func reopenedPortSendsAgain() throws {
        let told = Told()
        let recording = RecordingSender()
        let osc = OSCPort(
            port: 6000, name: "osc :6000",
            source: RecordedSource<OSCMessage>(batches: [[OSCMessage("/a", 1)]]),
            outbound: recording, owner: nil, warn: told.append)
        try osc.open()
        osc.send("/before", 1)
        osc.supply()
        #expect(osc.messages == [OSCMessage("/a", 1)])

        osc.close()
        #expect(osc.state == .stopped)
        osc.send("/while-closed", 1)
        osc.send("/while-closed", 2)
        #expect(recording.sent == [try OSCCodec.encode(OSCMessage("/before", 1))])
        #expect(told.count(containing: "is stopped") == 1)

        try osc.open()
        #expect(osc.state == .running)
        osc.send("/after", 2)
        osc.supply()
        #expect(osc.messages == [OSCMessage("/a", 1)])
        #expect(
            recording.sent == [
                try OSCCodec.encode(OSCMessage("/before", 1)), try OSCCodec.encode(OSCMessage("/after", 2)),
            ])
        #expect(told.count(containing: "is stopped") == 1, "足し直した後に送れたので、新しい知らせは出ない")

        // 外し直せば、また送らず、また 1 度だけ知らせる
        osc.close()
        osc.send("/again", 3)
        #expect(recording.sent.count == 2)
        #expect(told.count(containing: "is stopped") == 2)
    }

    @Test("外して足し直した入り口は、外す前に溜まっていたメッセージを出さず、足し直した後に届いたものだけを出す (#3122)")
    func reopenedPortDoesNotDeliverWhatWaitedBeforeClose() throws {
        let osc = OSCPort(
            port: 6000, name: "osc :6000", source: RecordedSource<OSCMessage>(batches: [[]]),
            outbound: nil, owner: nil)
        try osc.open()
        osc.input.send(OSCMessage("/stale", 1))
        osc.close()

        try osc.open()
        osc.supply()
        #expect(osc.messages.isEmpty, "外す前に溜まっていた分は、足し直した最初のフレームに出ない")
        #expect(osc.latest("/stale") == nil)

        osc.input.send(OSCMessage("/fresh", 2))
        osc.supply()
        #expect(osc.messages == [OSCMessage("/fresh", 2)])
    }

    @Test("実行に足されていない (外で呼んだ) stop() は何も止めず、利用者が止めた印も立てない。外して足し直せば戻る (#3122)")
    func stopWithoutARunDoesNotStick() throws {
        let told = Told()
        let recording = RecordingSender()
        let osc = OSCPort(
            port: 6000, name: "osc :6000",
            source: RecordedSource<OSCMessage>(batches: [[OSCMessage("/a", 1)]]),
            outbound: recording, owner: nil, warn: told.append)
        try osc.open()
        osc.stop()
        #expect(osc.state == .running, "外で呼んだ stop() は何も止めない")

        // 外して足し直せば戻る (印が立っていれば、ここで戻らない)
        osc.close()
        try osc.open()
        osc.supply()
        osc.send("/back", 1)
        #expect(osc.state == .running)
        #expect(osc.messages == [OSCMessage("/a", 1)])
        #expect(recording.sent == [try OSCCodec.encode(OSCMessage("/back", 1))])
    }

    @Test("同じメッセージの列は、ポートで受けても注入しても同じ結果になる")
    func injectedMessagesGiveTheSameOutcome() async throws {
        let told = Told()
        let (live, port) = try await listening(told: told)
        defer { live.close() }
        let log = SendLog()
        log.watch { live.sendTrace }
        for message in Self.script {
            live.send(message)
        }
        let received = await collect(live, count: Self.script.count, log: log)
        try await requireHeard(
            received.count >= Self.script.count, "\(Self.script.count) 通のうち読めたのは \(received.count) 通",
            log: log, osc: live, port: port, told: told)

        let injected = OSCPort(
            port: nil, name: "osc (recorded)",
            source: RecordedSource<OSCMessage>(batches: Self.script.map { [$0] }), outbound: nil, owner: nil)
        try injected.open()
        var replayed: [OSCMessage] = []
        for _ in Self.script {
            injected.supply()
            replayed += injected.messages
        }

        #expect(received == Self.script)
        #expect(replayed == Self.script)
        #expect(Outcome(received) == Outcome(replayed))
        #expect(Outcome(replayed) == Outcome(Self.script))
    }

    @Test("注入した列は、i 番目の取り出しで i 番目の束を渡し、終わりまで行けば始まりへ戻る")
    func injectedBatchesFollowTheFrames() throws {
        let first = OSCMessage("/a", 1)
        let second = OSCMessage("/b", 2)
        let osc = OSCPort(
            port: nil, name: "osc (recorded)",
            source: RecordedSource<OSCMessage>(batches: [[first, second], [], [second]]), outbound: nil,
            owner: nil)
        try osc.open()
        var frames: [[OSCMessage]] = []
        for _ in 0..<4 {
            osc.supply()
            frames.append(osc.messages)
        }
        #expect(frames == [[first, second], [], [second], [first, second]])
        #expect(osc.state == .running)
    }

    // MARK: - 最新の 1 つ (#2469)

    /// 注入した列を流す入り口。走っているスケッチへは足さず、`supply()` を自分で呼ぶ。
    private func replay(
        _ batches: [[OSCMessage]], told: Told = Told()
    ) throws -> OSCPort {
        let osc = OSCPort(
            port: nil, name: "osc (recorded)", source: RecordedSource<OSCMessage>(batches: batches),
            outbound: nil, owner: nil, warn: told.append)
        try osc.open()
        return osc
    }

    @Test("latest は、フレームの頭で宛名ごとの最後に届いた 1 つに更新され、何も届かないフレームは前のまま")
    func latestFollowsTheFramesAndKeepsTheLastValue() throws {
        let batches = [
            [OSCMessage("/1/fader1", Float(0.2)), OSCMessage("/1/fader1", Float(0.7))],
            [],
            [OSCMessage("/1/fader2", 1)],
        ]
        let osc = try replay(batches)
        #expect(osc.latest("/1/fader1") == nil, "取り出す前は何も無い")

        osc.supply()
        // 同じフレームで後に届いたもの。落とさない列は今までどおり両方を持つ
        #expect(osc.latest("/1/fader1")?.float(0) == 0.7)
        #expect(osc.latest("/1/fader2") == nil)
        #expect(osc.messages == batches[0])

        osc.supply()
        #expect(osc.latest("/1/fader1")?.float(0) == 0.7)
        #expect(osc.latest("/1/fader2") == nil)
        #expect(osc.messages.isEmpty)

        osc.supply()
        #expect(osc.latest("/1/fader1")?.float(0) == 0.7)
        #expect(osc.latest("/1/fader2")?.float(0) == 1)

        // 終わりまで行けば始まりへ戻り、新しい値が前の値を置き換える
        osc.supply()
        #expect(osc.latest("/1/fader1")?.float(0) == 0.7)
    }

    @Test("latest は宛名を文字どおりに引き、ワイルドカードも、前方一致も、一致しない宛名も nil")
    func latestDoesNotMatchWildcards() throws {
        let osc = try replay([[OSCMessage("/1/fader1", Float(0.5)), OSCMessage("/hit", 1)]])
        osc.supply()
        for address in ["/1/*", "/*", "/1/fader", "/1/fader1/", "/1/fader?", "/1/fader[1]", "", "/HIT"] {
            #expect(osc.latest(address) == nil, "\(address)")
        }
        #expect(osc.latest("/hit") == OSCMessage("/hit", 1))
    }

    @Test("同じ列からは、何度回しても同じフレームで同じ latest になる")
    func latestIsDeterministicForTheSameBatches() throws {
        let batches = [
            [OSCMessage("/a", Float(0.1))], [OSCMessage("/a", Float(0.9)), OSCMessage("/b", 2)], [],
        ]
        func run() throws -> [[String: Float?]] {
            let osc = try replay(batches)
            return (0..<5).map { _ in
                osc.supply()
                return ["/a": osc.latest("/a")?.float(0), "/b": osc.latest("/b")?.float(0)]
            }
        }
        let first = try run()
        #expect(first == (try run()))
        #expect(first[0]["/a"] == 0.1)
        #expect(first[1]["/a"] == 0.9)
    }

    @Test("stop() の後は latest も空になる")
    func latestIsEmptyAfterStop() throws {
        let osc = try replay([[OSCMessage("/a", 1)]])
        osc.supply()
        #expect(osc.latest("/a") != nil)
        osc.close()
        #expect(osc.latest("/a") == nil)
        osc.supply()
        #expect(osc.latest("/a") == nil)
    }

    @Test("覚える宛名は 4096 まで。超えた新しい宛名は覚えずに 1 度だけ知らせ、覚えた宛名は更新し、messages は落とさない")
    func latestRemembersAtMostTheAddressLimit() throws {
        let limit = OSCPort.latestAddressLimit
        let told = Told()
        let fill = (0..<limit).map { OSCMessage("/n/\($0)", $0) }
        let beyond = [OSCMessage("/extra/1", 1), OSCMessage("/extra/2", 2)]
        let update = [OSCMessage("/n/0", -1)]
        let osc = try replay([fill, beyond, update, beyond], told: told)
        osc.supply()
        #expect(osc.latest("/n/\(limit - 1)")?.int(0) == limit - 1)
        #expect(told.lines.isEmpty)

        osc.supply()
        #expect(osc.messages == beyond, "messages は落とさない")
        #expect(osc.latest("/extra/1") == nil)
        #expect(osc.latest("/extra/2") == nil)
        #expect(told.count(containing: "remembers the latest message of \(limit) addresses") == 1)
        #expect(told.lines.first?.contains("/extra/1") == true)

        osc.supply()
        #expect(osc.latest("/n/0")?.int(0) == -1, "覚えた宛名は上限に達しても更新する")
        osc.supply()
        #expect(told.lines.count == 1, "続けて届いても 2 度は言わない")
    }

    // MARK: - 読めないものは打ち切る

    @Test("番号つきの送りは、送れないと名乗った番号だけを新しい送り元に替えて全部を読む")
    func numberedBurstReplacesSendersThatCannotSend() async throws {
        let told = Told()
        let (osc, port) = try await listening(told: told)
        defer { osc.close() }
        let raw = try RawDatagramSocket()
        defer { raw.release() }

        let count = 10
        var attempts: [Int: Int] = [:]
        var senders: [any DatagramSending] = []
        defer { for sender in senders { sender.stop() } }
        let log = SendLog()
        let heard = try await sendNumberedBurst(
            count: count, through: osc, senders: &senders, told: told, log: log
        ) { index, attempt, warn in
            attempts[index] = attempt
            // 奇数の番号の最初の送り元は、送れないと名乗って何も出さない。作り物の送り元だけで確かめる
            // (本物の送り元は負荷で名乗ることがあり、数が揺れる)
            let cannot = index % 2 == 1 && attempt == 1
            return ScriptedSender(raw: cannot ? nil : raw, port: port, complaint: cannot ? warn : nil)
        }
        try await requireHeard(
            heard == Set(0..<count), "送り元 \(count) 本のうち読めたのは \(heard.count) 本", log: log,
            osc: osc, port: port, told: told)
        #expect(heard == Set(0..<count))
        // 替えたのは名乗った奇数の番号だけで、1 回で足りた
        #expect(attempts == Dictionary(uniqueKeysWithValues: (0..<count).map { ($0, $0 % 2 == 1 ? 2 : 1) }))
        #expect(senders.count == count)
        #expect(told.count(containing: "Address already in use") == count / 2)
    }

    @Test("番号つきの送りは、名乗らずに読まれない番号の送り元を替えず、期限で読まれた分を返す")
    func numberedBurstDoesNotReplaceSilentSenders() async throws {
        let told = Told()
        let (osc, port) = try await listening(told: told)
        defer { osc.close() }

        var senders: [any DatagramSending] = []
        defer { for sender in senders { sender.stop() } }
        var made = 0
        let heard = try await sendNumberedBurst(
            count: 3, through: osc, senders: &senders, told: told, within: 0.5
        ) { _, _, _ in
            made += 1
            return ScriptedSender(raw: nil, port: port, complaint: nil)
        }
        #expect(heard.isEmpty)
        #expect(made == 3)
    }

    @Test("番号つきの送りは、替えた後の古い送り元が遅れて名乗っても、同じ番号を替え直さない")
    func numberedBurstIgnoresAReplacedSendersLateComplaint() async throws {
        let told = Told()
        let (osc, port) = try await listening(told: told)
        defer { osc.close() }

        var attempts: [Int] = []
        var senders: [any DatagramSending] = []
        defer { for sender in senders { sender.stop() } }
        _ = try await sendNumberedBurst(
            count: 1, through: osc, senders: &senders, told: told, within: 0.3
        ) { _, attempt, warn in
            attempts.append(attempt)
            // 最初の送り元は、送れないと名乗り、閉じられたときにもう一度名乗る (閉じた後に遅れて返る
            // `waiting`)。替えた先は何も出さない。古い名乗りを数えると、もう一度替えて 3 回目になる
            return ScriptedSender(
                raw: nil, port: port, complaint: attempt == 1 ? warn : nil, complainsOnStop: true)
        }
        #expect(attempts == [1, 2])
    }

    @Test("番号つきの送りで読まれない番号があれば、読めなかった番号と名乗った送り元・送り元の様子・受け口の様子・素の socket の 1 通を名乗って 1 つで止まる")
    func requireHeardNamesBothSidesAndStops() async throws {
        let told = Told()
        let (osc, port) = try await listening(told: told)
        defer { osc.close() }
        let raw = try RawDatagramSocket()
        defer { raw.release() }

        // 0 番は読まれる。1 番は最初の送り元が名乗って出ず、替えた先で読まれる。2 番は名乗り続けて替える
        // 上限まで読まれない。3 番は名乗らずに出ない (替えない。繋ぎは `preparing` のまま)
        var senders: [any DatagramSending] = []
        defer { for sender in senders { sender.stop() } }
        let log = SendLog()
        let count = 4
        let heard = try await sendNumberedBurst(
            count: count, through: osc, senders: &senders, told: told, within: 1, log: log
        ) { index, attempt, warn in
            switch index {
            case 0: return ScriptedSender(raw: raw, port: port, complaint: nil)
            case 1: return ScriptedSender(raw: attempt == 1 ? nil : raw, port: port, complaint: attempt == 1 ? warn : nil)
            case 2: return ScriptedSender(raw: nil, port: port, complaint: warn)
            default:
                return ScriptedSender(raw: nil, port: port, complaint: nil, trace: SendTrace(state: "preparing"))
            }
        }
        #expect(heard == [0, 1])

        let text = try await said {
            try await requireHeard(
                heard == Set(0..<count), "送り元 \(count) 本のうち読めたのは \(heard.count) 本", log: log,
                osc: osc, port: port, told: told)
        }
        #expect(text.contains("送り元 4 本のうち読めたのは 2 本"), "名乗り: \(text)")
        #expect(text.contains("期限 1.0 秒"), "名乗り: \(text)")
        // 読めなかった番号と、そのうち名乗った送り元 (番号つき)
        #expect(
            text.contains("/from: 読めたのは 2/4・読めなかった 2 本 [2…3]・うち名乗った [2]・名乗らずに黙っている [3]"),
            "名乗り: \(text)")
        // 替えたのは 1 番が 1 回・2 番が 3 回 (上限)。替えた後に読まれたのは 1 番だけ
        #expect(text.contains("替えた 4 回・替えた後に読めた 1 本"), "名乗り: \(text)")
        #expect(text.contains("出どころは区別できない"), "名乗り: \(text)")
        // 送り元の様子は、読めなかった側と読めた側に分けて数える
        #expect(
            text.contains(
                "読めなかった側の送り元の様子 {出 1・誤り無し 0・誤り 0・最後 preparing}×1 {出 1・誤り無し 0・誤り 0・最後 知らせ無し}×1"),
            "名乗り: \(text)")
        #expect(text.contains("読めた側の送り元の様子 {出 1・誤り無し 0・誤り 0・最後 知らせ無し}×2"), "名乗り: \(text)")
        // 名乗りは 1 番が 1 行・2 番が 4 行。名乗った送り元は 1 番と 2 番
        #expect(text.contains("名乗った送り元 /from[1…2]・名乗り 5 行") && text.contains("Could not send to 127.0.0.1:\(port)"), "名乗り: \(text)")
        // 受け口の様子 (送り手の名乗りは受け口の知らせに数えない)
        #expect(text.contains("受け口 (1 通の前): running") && text.contains("移り変わり "), "名乗り: \(text)")
        #expect(text.contains("受け入れ 1・黙りで閉じた 0・終わって外れた 0・持つ数 1"), "名乗り: \(text)")
        #expect(text.contains("受け口の知らせは 0 行"), "名乗り: \(text)")
        #expect(text.contains("素の socket の 1 通: 読めた・受け入れ +1"), "名乗り: \(text)")
    }

    @Test("素の socket から送った通が読まれなければ、受け口の様子と素の 1 通の前後の受け入れの差を名乗り、送り手の欄は様子を読めない送り元と言って 1 つで止まる (#3105)")
    func rawSocketShortReadNamesTheReceiver() async throws {
        let told = Told()
        let (osc, port) = try await listening(told: told)
        defer { osc.close() }
        let peer = try RawDatagramSocket()
        defer { peer.release() }
        let packet = try Wire.encoded(OSCMessage("/m", arguments: []))

        // 1 通だけ送って 2 通を期待する (2 通目は来ない)
        #expect(peer.send(packet, to: port) == packet.count)
        let text = try await said {
            _ = try await heard(osc, count: 2, within: 0.5, port: port, told: told, from: peer, "(2 通目は送っていない)")
        }
        #expect(text.contains("素の socket から送った 2 通のうち読めたのは 1 通(2 通目は送っていない)"), "名乗り: \(text)")
        #expect(text.contains("期限 0.5 秒"), "名乗り: \(text)")
        #expect(text.contains("受け口 (1 通の前): running") && text.contains("受け入れ 1・黙りで閉じた 0・終わって外れた 0・持つ数 1"), "名乗り: \(text)")
        #expect(text.contains("素の socket の 1 通: 読めた・受け入れ +1 (新しい送り元を受けられた)"), "名乗り: \(text)")
        // 送り手の欄: 素の socket は名乗りも替えも持たない。黙っているとは言わない
        #expect(text.contains("送り元の様子 {様子を読めない送り元}×1"), "名乗り: \(text)")
        #expect(!text.contains("黙っている") && !text.contains("替えた"), "名乗り: \(text)")
        // 送った socket の sendto の戻り: 送れていたので、読めなかった理由は受け口側と読める
        #expect(text.contains("sendto は 1 回とも成功 (計 \(packet.count) バイト)"), "名乗り: \(text)")

        // 受け口が受けない形 (閉じた受け口) は、素の 1 通も読まれず、受け口側と読み分けられる
        osc.close()
        let closed = try await said {
            _ = try await heard(osc, count: 1, within: 0.3, port: port, told: told, from: peer)
        }
        #expect(closed.contains("受け口 (1 通の前): stopped"), "名乗り: \(closed)")
        #expect(closed.contains("素の socket の 1 通: 読めなかった"), "名乗り: \(closed)")
    }

    @Test("本番の時計のままでも、読んだ後に黙った送り元は次の受け入れで閉じる")
    func idleSendersAreSweptOnTheDefaultClock() async throws {
        let told = Told()
        // 時計は差し替えない (本番と同じ既定の時計)。黙りの約束は ``DatagramListenerFakeTests`` が
        // 手で進める時計で回すので、既定の時計が黙りを測れなくなる退行 (止まった時計への差し替えなど)
        // はここでしか捕まらない
        let (osc, port) = try await listening(told: told, idleAfter: 0.05)
        defer { osc.close() }
        let source = try #require(osc.source as? NetworkOSCSource)

        // 目安の数だけの送り元から送る。出なかった datagram は、送れないと名乗った分を送り直す (#2910)。
        // **全部が読まれることは求めない**: 名乗らずに読まれない送り元があっても、読めた分から
        // 黙りを測る (読んだ送り元が 1 つ以上あれば、黙りで閉じる相手がいる)
        var burst: [any DatagramSending] = []
        defer { for sender in burst { sender.stop() } }
        let burstLog = SendLog()
        let heard = try await sendNumberedBurst(
            count: DatagramListener.connectionLimit, through: osc, senders: &burst, told: told,
            within: 5, log: burstLog
        ) { _, _, warn in
            DatagramSender(host: "127.0.0.1", port: port, warn: warn)
        }
        try await requireHeard(
            !heard.isEmpty, "1 通も読めていない — 黙りを測る相手がいない", log: burstLog, osc: osc, port: port,
            told: told)

        // **集め終えた後の閉じを測る。** 本物の時計で `idleAfter` が 0.05 秒なので、集めている最中に
        // 受け入れが目安に達して閉じが起きうる。その分を数えないよう、ここの数を基準にする
        let closedWhileCollecting = source.tally.closedIdle

        // `idleAfter` より長く黙ってから、新しい送り元を 1 本ずつ足す。待つほど黙りは長くなる
        // だけなので、遅い機械でも閉じる側へしか進まない。読めなかった送り元や、別の送り元の繋ぎで
        // 渡された分で台帳が目安に届いていなくても、足すうちに届く
        //
        // **閉じなかった回が、主題の赤か前提の欠けかを見分ける。** 閉じるのは、台帳の数が目安に届いて
        // いるときの次の受け入れだけ (`SenderLedger.admit`)。届いた後に新しい受け入れが起きたのに
        // 閉じなければ主題の赤で、届かなかった・届いた後に受け入れが起きなかった回は前提の欠けである
        //
        // 足す送り元も本物の ``DatagramSender`` なので、出ない回がある。前提が欠けた回は、送り手の跡と受け口の
        // 様子を名乗って止まる (#3001)。名乗りの「読めた数」は、足し始めてからの受け入れの増えで数える
        // (足した 1 通ごとの読みは見ない)
        var late: [DatagramSender] = []
        defer { for sender in late { sender.stop() } }
        let lateLog = SendLog()
        let lateStarted = Date()
        let acceptedAtStart = source.tally.accepted
        var acceptedWhenFull: Int?
        for index in 0..<DatagramListener.connectionLimit
        where source.tally.closedIdle == closedWhileCollecting {
            try await Task.sleep(for: .milliseconds(index == 0 ? 100 : 10))
            if acceptedWhenFull == nil, source.connectionCount >= DatagramListener.connectionLimit {
                acceptedWhenFull = source.tally.accepted
            }
            let sender = DatagramSender(host: "127.0.0.1", port: port, warn: told.append)
            late.append(sender)
            lateLog.watch("/late", index: index, sender: sender)
            sender.send(try Wire.encoded(OSCMessage("/late", index)))
        }
        try await requireArrival(
            "黙った送り元が次の受け入れで閉じられなかった",
            until: { source.tally.closedIdle > closedWhileCollecting }
        ) {
            lateLog.record(
                label: "/late", expected: late.count,
                heard: min(source.tally.accepted - acceptedAtStart, late.count), missing: nil,
                replacements: 0, heardAfterReplacement: 0,
                waited: Date().timeIntervalSince(lateStarted), limit: 0)
            try await requireHeard(
                acceptedWhenFull != nil,
                "台帳が目安 (\(DatagramListener.connectionLimit)) に届かなかった (\(source.connectionCount)) — 黙った送り元を閉じる前提が無い",
                log: lateLog, osc: osc, port: port, told: told)
            let atLimit = try #require(acceptedWhenFull)
            try await requireHeard(
                source.tally.accepted > atLimit, "台帳が目安に届いた後、新しい受け入れが起きなかった — 閉じる契機が来ていない",
                log: lateLog, osc: osc, port: port, told: told)
        }
        #expect(source.connectionCount < DatagramListener.connectionLimit)
    }

    // MARK: - ポートが使えないとき

    @Test("ポートを他が握っていれば unavailable と 1 度だけ知らせ、空けば受け始める")
    func portInUseWaitsUntilFreed() async throws {
        let told = Told()
        let holder = try PortHolder(port: 0)
        let port = holder.port
        let osc = try loopback(port: port, told: told)
        defer { osc.close() }

        try await requireTold(containing: "another app is using it", told: told, tracing: osc.source) { osc.state }
        #expect(osc.state == .unavailable)
        // 開き直しを何度か重ねても、知らせは増えない
        try await Task.sleep(for: .milliseconds(300))
        #expect(told.count(containing: "another app is using it") == 1)
        #expect(osc.state == .unavailable)

        holder.release()
        try await requireState(told: told, tracing: osc.source) { osc.state }
        let log = SendLog()
        log.watch { osc.sendTrace }
        osc.send("/back", 1)
        let received = await collect(osc, count: 1, log: log)
        try await requireHeard(
            received.count >= 1, "1 通のうち読めたのは \(received.count) 通 (空いたポートで受け始めた後)", log: log,
            osc: osc, port: port, told: told)
        #expect(received == [OSCMessage("/back", 1)])
    }

    // MARK: - 作る口

    @Test("ポートの番号が 1〜65535 の外・送り先のホストが空なら、作るときに投げる")
    func creationRefusesUnusableValues() throws {
        let sketch = IdleSketch()
        #expect(throws: OSCFailure.invalidPort(0)) { try sketch.createOSC(listen: 0) }
        #expect(throws: OSCFailure.invalidPort(65536)) { try sketch.createOSC(listen: 65536) }
        #expect(throws: OSCFailure.invalidPort(0)) {
            try sketch.createOSC(listen: 9000, send: ("127.0.0.1", 0))
        }
        #expect(throws: OSCFailure.invalidHost(" ")) {
            try sketch.createOSC(listen: 9000, send: (" ", 7000))
        }
        // 両端は値の検めを通る。走っていないスケッチなので、その後ポートを開く前に断る (#2740)
        OutsideRun.$current.withValue(OutsideRun()) {
            #expect(throws: OSCFailure.notRunning(call: "createOSC(listen:send:)")) {
                try sketch.createOSC(listen: 65535, send: ("127.0.0.1", 1))
            }
            #expect(throws: OSCFailure.notRunning(call: "createOSC(listen:send:)")) {
                try sketch.createOSC(listen: 1, send: ("127.0.0.1", 65535))
            }
        }
    }

    @Test("createOSC(send:) は送り先の値を検め、走っていない所では呼んだ口の名前で notRunning を投げる (#2469)")
    func sendOnlyCreationRefusesUnusableValues() {
        let sketch = IdleSketch()
        #expect(throws: OSCFailure.invalidPort(0)) { try sketch.createOSC(send: ("127.0.0.1", 0)) }
        #expect(throws: OSCFailure.invalidPort(65536)) { try sketch.createOSC(send: ("127.0.0.1", 65536)) }
        #expect(throws: OSCFailure.invalidHost(" ")) { try sketch.createOSC(send: (" ", 7000)) }
        // 値の検めを通った後、ポートも開かずに断る。両端の 1 と 65535 は使える
        OutsideRun.$current.withValue(OutsideRun()) {
            #expect(throws: OSCFailure.notRunning(call: "createOSC(send:)")) {
                try sketch.createOSC(send: ("127.0.0.1", 65535))
            }
            #expect(throws: OSCFailure.notRunning(call: "createOSC(send:)")) {
                try sketch.createOSC(send: ("localhost", 1))
            }
        }
    }

    @Test("送るだけの入り口は、受けるポートを開かず、何も受けず、観測の inputs に行を出さず、送ったものは宛先で受けられる (#2469)")
    func sendOnlyPortSendsWithoutListening() async throws {
        let told = Told()
        let receiver = try await listening(told: told)
        defer { receiver.osc.close() }

        // `createOSC(send:)` が組むのと同じ部品 (何も受けない出どころ・共通の送り手)
        let sender = OSCPort(
            port: nil, name: "osc (send only)", source: SendOnlySource(),
            outbound: DatagramSender(host: "127.0.0.1", port: receiver.port, warn: told.append),
            owner: nil, warn: told.append)
        try sender.open()
        #expect(sender.port == nil)
        #expect(sender.state == .running)
        #expect(sender.report == nil, "受け口ではないので、inputs に載らない")

        let log = SendLog()
        log.watch { sender.sendTrace }
        sender.send("/size", Float(0.25))
        sender.send("/hit", 1)
        let received = await collect(receiver.osc, count: 2, log: log)
        try await requireHeard(
            received.count >= 2, "2 通のうち読めたのは \(received.count) 通 (送るだけの入り口から)", log: log,
            osc: receiver.osc, port: receiver.port, told: told)
        #expect(received == [OSCMessage("/size", Float(0.25)), OSCMessage("/hit", 1)])

        sender.supply()
        #expect(sender.messages.isEmpty)
        #expect(sender.latest("/size") == nil)
        #expect(sender.lastArrival == nil)
        #expect(told.lines.isEmpty)

        sender.close()
        #expect(sender.state == .stopped)
        sender.send("/late", 1)
        #expect(told.count(containing: "is stopped") == 1)
    }

    // MARK: - 送れないとき

    @Test("送れない理由は、理由ごとに 1 度だけ知らせて何も送らない")
    func unsendableIsToldOncePerReason() throws {
        let told = Told()
        let recording = RecordingSender()
        let osc = OSCPort(
            port: 9000, name: "osc :9000", source: RecordedSource<OSCMessage>(batches: []),
            outbound: recording, owner: nil, warn: told.append)
        osc.send("size", 1)
        osc.send("size", 2)
        #expect(recording.sent.isEmpty)
        #expect(told.lines.count == 1)
        #expect(told.lines.first?.contains("does not start with \"/\"") == true)

        osc.send("/ok", 1)
        #expect(recording.sent == [try Wire.encoded(OSCMessage("/ok", 1))])

        let nowhere = OSCPort(
            port: 9000, name: "osc :9000", source: RecordedSource<OSCMessage>(batches: []), outbound: nil,
            owner: nil, warn: told.append)
        nowhere.send("/a", 1)
        nowhere.send("/b", 1)
        #expect(told.count(containing: "has nowhere to send") == 1)

        let recorded = OSCPort(
            port: nil, name: "osc (recorded)", source: RecordedSource<OSCMessage>(batches: []),
            outbound: nil, owner: nil, warn: told.append)
        recorded.send("/a", 1)
        #expect(told.count(containing: "replays recorded messages") == 1)

        osc.close()
        osc.send("/late", 1)
        #expect(recording.sent.count == 1)
        #expect(told.count(containing: "is stopped") == 1)
    }

    @Test("符号化して 9216 バイト以上になるメッセージは送り手に渡さず、大きさと上限を 1 度だけ知らせる")
    func oversizedSendIsRefusedOnce() throws {
        let told = Told()
        // 送り手に渡らなければ、「受け手が居ない」見当で名乗る経路にも、繋ぎを捨てる経路にも入らない
        let recording = RecordingSender()
        let osc = OSCPort(
            port: 9000, name: "osc :9000", source: RecordedSource<OSCMessage>(batches: []),
            outbound: recording, owner: nil, warn: told.append)
        let large = OSCMessage("/big", arguments: [.blob([UInt8](repeating: 7, count: 12000))])
        osc.send(large)
        osc.send(large)
        #expect(recording.sent.map(\.count) == [])
        #expect(told.lines.count == 1)
        let line = told.lines.first ?? ""
        #expect(line.contains("/big"))
        #expect(line.contains("\(try Wire.encoded(large).count) bytes"))
        #expect(line.contains("9212 bytes at most"))
        #expect(!line.contains("listening"))

        // ちょうど 9216 バイトも送らず、OSC のパケットの最大 (4 バイトの倍数で 9212 バイト) は送る。
        // 宛名が違うので、9216 バイトの /b は改めて知らせる
        let header = try Wire.encoded(OSCMessage("/b", arguments: [.blob([])])).count
        osc.send(OSCMessage("/b", arguments: [.blob([UInt8](repeating: 7, count: 9216 - header))]))
        osc.send(OSCMessage("/b", arguments: [.blob([UInt8](repeating: 7, count: 9212 - header))]))
        #expect(recording.sent.map(\.count) == [9212])
        #expect(told.lines.count == 2)
        #expect(told.lines.last?.contains("/b was not sent because it is 9216 bytes") == true)
    }

    @Test("大きすぎる送りは宛名ごとに 1 度だけ知らせ、上限以内を送れたら、また知らせる")
    func oversizedSendIsToldPerAddressAndAgainAfterASuccessfulSend() throws {
        let told = Told()
        let recording = RecordingSender()
        let osc = OSCPort(
            port: 9000, name: "osc :9000", source: RecordedSource<OSCMessage>(batches: []),
            outbound: recording, owner: nil, warn: told.append)
        let blob = OSCValue.blob([UInt8](repeating: 7, count: 12000))
        osc.send(OSCMessage("/a", arguments: [blob]))
        osc.send(OSCMessage("/a", arguments: [blob]))
        #expect(told.count(containing: "9212 bytes at most") == 1)
        osc.send(OSCMessage("/b", arguments: [blob]))
        #expect(told.count(containing: "9212 bytes at most") == 2)
        #expect(told.count(containing: "/b was not sent") == 1)

        osc.send("/ok", 1)
        osc.send(OSCMessage("/a", arguments: [blob]))
        osc.send(OSCMessage("/a", arguments: [blob]))
        #expect(told.count(containing: "9212 bytes at most") == 3)
        #expect(told.count(containing: "/a was not sent") == 2)
        #expect(recording.sent.count == 1)
    }

    @Test("本物の宛先でも、上限に入らないメッセージは送らず、続けて送ったメッセージは届く")
    func oversizedSendLeavesTheDestinationReachable() async throws {
        let told = Told()
        let (osc, port) = try await listening(told: told)
        defer { osc.close() }
        let log = SendLog()
        log.watch { osc.sendTrace }

        osc.send(OSCMessage("/big", arguments: [.blob([UInt8](repeating: 7, count: 12000))]))
        osc.send("/after", 1)
        let received = await collect(osc, count: 1, log: log)
        try await requireHeard(
            received.count >= 1, "1 通のうち読めたのは \(received.count) 通 (上限に入らない 1 通の後に送った分)", log: log,
            osc: osc, port: port, told: told)
        #expect(received == [OSCMessage("/after", 1)])
        #expect(osc.input.unreadable == 0)
        #expect(told.lines.count == 1)
        #expect(told.count(containing: "9212 bytes at most") == 1)
        #expect(told.count(containing: "listening") == 0)
    }
}
