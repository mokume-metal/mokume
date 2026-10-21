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
nonisolated final class ScriptedSender: DatagramSending {
    private let raw: RawDatagramSocket?
    private let port: Int
    private let complaint: (@Sendable (String) -> Void)?
    private let complainsOnStop: Bool

    init(
        raw: RawDatagramSocket?, port: Int, complaint: (@Sendable (String) -> Void)?,
        complainsOnStop: Bool = false
    ) {
        self.raw = raw
        self.port = port
        self.complaint = complaint
        self.complainsOnStop = complainsOnStop
    }

    func send(_ bytes: [UInt8]) {
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
nonisolated final class AimedSender: DatagramSending {
    private let target = Mutex<DatagramSender?>(nil)
    private let warn: @Sendable (String) -> Void

    init(warn: @escaping @Sendable (String) -> Void) { self.warn = warn }

    /// 127.0.0.1 の `port` へ向ける。
    func aim(at port: Int) {
        target.withLock { $0 = DatagramSender(host: "127.0.0.1", port: port, warn: warn) }
    }

    func send(_ bytes: [UInt8]) { target.withLock { $0?.send(bytes) } }
    func stop() { target.withLock { $0?.stop() } }
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
    private func collect(_ osc: OSCPort, count: Int) async -> [OSCMessage] {
        var received: [OSCMessage] = []
        _ = await until {
            osc.supply()
            received += osc.messages
            return received.count >= count
        }
        return received
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
    /// - Parameter makeSender: 番号と、何度目の送り元か (1 から) と、送れないときの知らせの行き先を受けて、
    ///   送り元を作る。知らせは `told` にも流す。
    private func sendNumberedBurst(
        count: Int, address: String = "/from", through osc: OSCPort,
        senders: inout [any DatagramSending], told: Told,
        replacements: Int = 3, within seconds: TimeInterval = 10,
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
            return makeSender(index, attempt) { line in
                told.append(line)
                guard current.withLock({ $0[index] }) == attempt else { return }
                stuck.withLock { _ = $0.insert(index) }
            }
        }
        for index in 0..<count {
            let opened = sender(index)
            senders.append(opened)
            opened.send(try Wire.encoded(OSCMessage(address, index)))
        }
        var heard = Set<Int>()
        let deadline = Date().addingTimeInterval(seconds)
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
        return heard
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
        let osc = try await listening(told: told).osc
        defer { osc.close() }

        osc.send("/size", Float(0.25))
        osc.send("/hit", 1)
        let received = await collect(osc, count: 2)
        #expect(received == [OSCMessage("/size", Float(0.25)), OSCMessage("/hit", 1)])
        #expect(osc.lastArrival != nil)
        #expect(osc.report == SourceReport(name: "osc :0", state: .running, lastArrival: osc.lastArrival))
        #expect(told.lines.isEmpty)

        osc.close()
        #expect(osc.state == .stopped)
        #expect(osc.messages.isEmpty)
    }

    @Test("同じメッセージの列は、ポートで受けても注入しても同じ結果になる")
    func injectedMessagesGiveTheSameOutcome() async throws {
        let told = Told()
        let live = try await listening(told: told).osc
        defer { live.close() }
        for message in Self.script {
            live.send(message)
        }
        let received = await collect(live, count: Self.script.count)

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

    @Test("読めない部分を含むパケットは、そこから後ろを捨てて数える。前と次のパケットは届く")
    func unreadablePacketIsCutOffAndCounted() async throws {
        let told = Told()
        let (osc, port) = try await listening(told: told)
        defer { osc.close() }

        let before = OSCMessage("/before", 1)
        let after = OSCMessage("/after", 2)
        let next = OSCMessage("/next", 3)
        let broken = Wire.bundle([
            try Wire.encoded(before), Wire.string("/bad") + Wire.string(",q"), try Wire.encoded(after),
        ])
        let raw = DatagramSender(host: "127.0.0.1", port: port, warn: told.append)
        defer { raw.stop() }
        raw.send(broken)
        raw.send(try Wire.encoded(next))

        let received = await collect(osc, count: 2)
        #expect(received == [before, next])
        #expect(osc.input.unreadable == 1)
    }

    @Test("9216 バイト以上のパケットは丸ごと捨てて数え、束の頭のメッセージだけを渡すことはしない")
    func oversizedPacketIsDiscardedWhole() async throws {
        let told = Told()
        let (osc, port) = try await listening(told: told)
        defer { osc.close() }
        let peer = try RawDatagramSocket()
        defer { peer.release() }

        // 12000 バイトの blob を 1 つ持つメッセージ (datagram は 12012 バイト)
        let blob = try Wire.encoded(OSCMessage("/b", arguments: [.blob([UInt8](repeating: 7, count: 12000))]))
        #expect(blob.count == 12012)
        // 頭に小さなメッセージを置いた束。先頭 9216 バイトに切れたものを読むと、頭だけが読める
        let bundle = Wire.bundle([try Wire.encoded(OSCMessage("/head", 1)), blob])
        let next = OSCMessage("/next", 3)
        for packet in [blob, bundle, try Wire.encoded(next)] {
            #expect(peer.send(packet, to: port) == packet.count)
        }
        let received = await collect(osc, count: 1)
        #expect(received == [next])
        #expect(osc.input.unreadable == 2)
        #expect(told.lines.isEmpty)
    }

    @Test("空の datagram は、Network.framework が送り元の流れの終わりと名乗っても読めないものとして数え、後から届いたメッセージも受ける")
    func emptyDatagramIsCountedAndLaterMessagesArrive() async throws {
        let told = Told()
        let (osc, port) = try await listening(told: told)
        defer { osc.close() }
        let source = try #require(osc.source as? NetworkOSCSource)
        let peer = try RawDatagramSocket()
        defer { peer.release() }

        // 送り元の流れができて受けを待っているところへ空を送る。この形の空の datagram を、
        // Network.framework は毎回、流れの終わり (`isFinal`) と名乗って渡す (macOS 27.0.1 で実測)
        let message = OSCMessage("/m", arguments: [])
        let packet = try Wire.encoded(message)
        #expect(peer.send(packet, to: port) == packet.count)
        var received = await collect(osc, count: 1)
        #expect(peer.send([], to: port) == 0)
        #expect(await until { osc.input.unreadable == 1 })

        // 終わりを名乗った空を数えたら、その流れを閉じる。閉じた後に届いたものは、新しい流れで受ける
        #expect(await until { source.tally.ended >= 1 })
        for _ in 0..<5 {
            #expect(peer.send(packet, to: port) == packet.count)
        }
        received += await collect(osc, count: 5)
        #expect(received == Array(repeating: message, count: 6))
        #expect(osc.input.unreadable == 1)
    }

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
        let heard = try await sendNumberedBurst(
            count: count, through: osc, senders: &senders, told: told
        ) { index, attempt, warn in
            attempts[index] = attempt
            // 奇数の番号の最初の送り元は、送れないと名乗って何も出さない。作り物の送り元だけで確かめる
            // (本物の送り元は負荷で名乗ることがあり、数が揺れる)
            let cannot = index % 2 == 1 && attempt == 1
            return ScriptedSender(raw: cannot ? nil : raw, port: port, complaint: cannot ? warn : nil)
        }
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

    /// 黙りの検査の場面。送る送り元の数と、最初の `/late` が既存の繋ぎで渡される形にするか。
    struct SweepScenario: CustomTestStringConvertible, Sendable {
        /// 最初に送る送り元の数。目安 (64) を超えるか、受け入れが目安に届かない数。
        var sending: Int
        /// 最初の `/late` を、最初の送り元と同じ source のソケットから出す。受け口はその datagram を
        /// 既存の繋ぎで渡し、受け入れは起きない (#2225 の揺れを決定的に作る)。
        var reusesASource = false

        var testDescription: String {
            "送り元 \(sending) 本" + (reusesASource ? "・最初の /late は既存の繋ぎで渡される" : "")
        }
    }

    @Test(
        "多くの送り元から一度に届いても 1 つも落とさず、黙った送り元は次の受け入れで閉じる",
        arguments: [
            SweepScenario(sending: DatagramListener.connectionLimit + 6),
            SweepScenario(sending: DatagramListener.connectionLimit - 10),
            SweepScenario(sending: DatagramListener.connectionLimit + 6, reusesASource: true),
        ]
    )
    func manySendersAreAllHeardThenSwept(_ scenario: SweepScenario) async throws {
        let count = scenario.sending
        let told = Told()
        // 黙りは手で進める時計で測る。本物の時計だと、受け入れが遅い機械 (負荷のある CI) では
        // 70 本を受け入れる途中で最初の送り元が `idleAfter` 秒黙ったことになって閉じられ、
        // 数が受け入れの速さで揺れる (#2225)
        let clock = ManualClock(0)
        let idleAfter: TimeInterval = 1
        let (osc, port) = try await listening(told: told, idleAfter: idleAfter, now: clock.provider)
        defer { osc.close() }
        let source = try #require(osc.source as? NetworkOSCSource)

        // 送り手ごとに別のポートから送る (使い捨てのソケットで送るスクリプトと同じ形)。
        // 目安の数を超えても、黙っていない送り元は閉じない — 閉じると読む前の datagram を捨てる。
        // 時計は止めたままなので、受け入れにどれだけ掛かっても黙った送り元は居ない
        var burst: [any DatagramSending] = []
        defer { for sender in burst { sender.stop() } }
        // 既存の繋ぎで渡される形では、0 番の送り元だけ source が固定のソケットで送る
        let reused = try RawDatagramSocket()
        defer { reused.release() }
        let heard = try await sendNumberedBurst(
            count: count, through: osc, senders: &burst, told: told
        ) { index, _, warn in
            if scenario.reusesASource, index == 0 {
                return ScriptedSender(raw: reused, port: port, complaint: nil)
            }
            return DatagramSender(host: "127.0.0.1", port: port, warn: warn)
        }
        #expect(heard == Set(0..<count))
        // 受け入れた送り元を 1 本も外していない — 黙りでも (時計が止まっていて誰も黙っていない)、
        // 失敗でも。受け入れた数と持っている数が等しいことで、数え方の外で閉じる経路も捕まえる。
        // 受け入れた数が送り元の数 (70) に届くことは求めない: 負荷の下では Network.framework の
        // 受け口が、ある送り元の datagram を別の送り元の繋ぎで渡し、その送り元の繋ぎを作らない
        // ことがある (#2225 で実測。受け口では datagram は落ちない)。閉じたのではないので、ここでは
        // 数えない。datagram が読まれないのは送り手側で出なかったときで、番号を送り直して補う (#2910)
        let tally = source.tally
        #expect(tally.closedIdle == 0)
        #expect(tally.ended == 0)
        #expect(source.connectionCount == tally.accepted)

        // **黙った送り元を閉じるのは、台帳の数が目安 (64) に届いているときの、次の受け入れだけ**
        // (`SenderLedger.admit`)。受け入れた数が目安に届かなかった回 (上の注の揺れ) では、次の受け入れが
        // 起きても何も閉じない。主題を見る前に、その前提を 2 つ満たす。
        //
        // 1 つ目: 台帳が目安に届くまで足す。時計は止めたままなので、足す間は何も閉じない。
        // 足す送り元も**全部読まれる**ことを前提にする: 読まれていない繋ぎは `admit` が閉じないので、
        // 台帳の数が主題の数え方とずれる。回ごとに宛名を変え、期限切れの後に遅れて届いた datagram が
        // 次の回の番号に数えられないようにする
        var fillers: [any DatagramSending] = []
        defer { for sender in fillers { sender.stop() } }
        let fillDeadline = Date().addingTimeInterval(15)
        var fillRounds = 0
        var unheardFillers = 0
        while source.connectionCount < DatagramListener.connectionLimit, Date() < fillDeadline {
            fillRounds += 1
            let need = DatagramListener.connectionLimit - source.connectionCount
            let filled = try await sendNumberedBurst(
                count: need, address: "/fill\(fillRounds)", through: osc, senders: &fillers,
                told: told, within: 5
            ) { _, _, warn in
                DatagramSender(host: "127.0.0.1", port: port, warn: warn)
            }
            unheardFillers += need - filled.count
        }
        let full = source.connectionCount
        try #require(
            full >= DatagramListener.connectionLimit,
            "台帳が目安 (\(DatagramListener.connectionLimit)) に届かない (\(full)) — 黙った送り元を閉じる前提が無い")
        try #require(
            unheardFillers == 0,
            "足した送り元のうち \(unheardFillers) 本が読まれていない — 読む前の繋ぎは閉じないので、閉じる数を数えられない")
        let closedBefore = source.tally.closedIdle
        #expect(closedBefore == 0)

        // 2 つ目: `/late` が**新しい受け入れを起こす**。この送り元も出ないことがあり、出ても受け口が
        // 既存の繋ぎで渡して繋ぎを作らないことがある (#2225)。受け入れが起きなかった回は何も閉じて
        // いないので、替えた送り元でやり直せる (回数と期限を持つ)。
        //
        // **やり直す前に、時計をもう `idleAfter` 秒進める。** 既存の繋ぎで渡された datagram は、その
        // 繋ぎを「いま読んだ」ことにする (`receive` が時計で印を付ける) ので、その繋ぎは黙っていない。
        // 進め直せば、またちょうど `idleAfter` 秒黙った繋ぎになり、閉じる数を台帳の数で数えられる。
        // 回ごとに宛名を変え、前の回の遅れて届いた datagram を数えない
        var lateSenders: [any DatagramSending] = []
        defer { for sender in lateSenders { sender.stop() } }
        let lateDeadline = Date().addingTimeInterval(15)
        var acceptedBefore = source.tally.accepted
        var lateHeard: Set<Int> = []
        var attempts = 0
        while attempts < 5, Date() < lateDeadline {
            attempts += 1
            // ちょうど `idleAfter` 秒黙った後に新しい送り元が来たら、黙っていた送り元を閉じてから
            // 受ける (閉じるのは `idleAfter` 秒「以上」黙った送り元)
            clock.advance(by: idleAfter)
            acceptedBefore = source.tally.accepted
            let attempt = attempts
            // この送り元も出ないことがある。同じ補助で、送れないと名乗ったら替えて待つ
            lateHeard = try await sendNumberedBurst(
                count: 1, address: "/late\(attempt)", through: osc, senders: &lateSenders,
                told: told, within: 5
            ) { _, _, warn in
                if scenario.reusesASource, attempt == 1 {
                    return ScriptedSender(raw: reused, port: port, complaint: nil)
                }
                return DatagramSender(host: "127.0.0.1", port: port, warn: warn)
            }
            if source.tally.accepted > acceptedBefore { break }
            #expect(source.connectionCount == full, "受け入れが起きていないのに台帳が動いた")
        }
        let acceptedByLate = source.tally.accepted - acceptedBefore
        try #require(
            acceptedByLate > 0,
            "/late が新しい受け入れを起こさなかった (\(attempts) 回) — 既存の繋ぎで渡された。黙った送り元を閉じる契機が来ない")
        if scenario.reusesASource {
            #expect(attempts >= 2, "前提: 最初の /late は既存の繋ぎで渡され、受け入れを起こさない")
        }
        #expect(lateHeard == [0])
        // 主題: 黙っていた送り元は全部閉じ、受け入れた新しい送り元だけが残る
        #expect(source.tally.closedIdle == closedBefore + full)
        #expect(source.connectionCount == acceptedByLate)

        // 黙りで閉じた送り元の待っていた受けは、空の datagram と同じ形 (content も error も nil) で
        // 返る。届いていない空を読めない数に足さない (#2324 の直しの反対側。実測で 70 個湧いた)
        let phantom = await until(1) { osc.input.unreadable > 0 }
        #expect(!phantom)
    }

    @Test("本番の時計のままでも、読んだ後に黙った送り元は次の受け入れで閉じる")
    func idleSendersAreSweptOnTheDefaultClock() async throws {
        let told = Told()
        // 時計は差し替えない (本番と同じ既定の時計)。前の検査は手で進める時計で回すので、既定の
        // 時計が黙りを測れなくなる退行 (止まった時計への差し替えなど) はここでしか捕まらない
        let (osc, port) = try await listening(told: told, idleAfter: 0.05)
        defer { osc.close() }
        let source = try #require(osc.source as? NetworkOSCSource)

        // 目安の数だけの送り元から送る。出なかった datagram は、送れないと名乗った分を送り直す (#2910)。
        // **全部が読まれることは求めない**: 名乗らずに読まれない送り元があっても、読めた分から
        // 黙りを測る (読んだ送り元が 1 つ以上あれば、黙りで閉じる相手がいる)
        var burst: [any DatagramSending] = []
        defer { for sender in burst { sender.stop() } }
        let heard = try await sendNumberedBurst(
            count: DatagramListener.connectionLimit, through: osc, senders: &burst, told: told,
            within: 5
        ) { _, _, warn in
            DatagramSender(host: "127.0.0.1", port: port, warn: warn)
        }
        try #require(!heard.isEmpty, "1 通も読めていない — 黙りを測る相手がいない")

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
        var late: [DatagramSender] = []
        defer { for sender in late { sender.stop() } }
        var acceptedWhenFull: Int?
        for index in 0..<DatagramListener.connectionLimit
        where source.tally.closedIdle == closedWhileCollecting {
            try await Task.sleep(for: .milliseconds(index == 0 ? 100 : 10))
            if acceptedWhenFull == nil, source.connectionCount >= DatagramListener.connectionLimit {
                acceptedWhenFull = source.tally.accepted
            }
            let sender = DatagramSender(host: "127.0.0.1", port: port, warn: told.append)
            late.append(sender)
            sender.send(try Wire.encoded(OSCMessage("/late", index)))
        }
        let swept = await until { source.tally.closedIdle > closedWhileCollecting }
        if !swept {
            let atLimit = try #require(
                acceptedWhenFull,
                "台帳が目安 (\(DatagramListener.connectionLimit)) に届かなかった (\(source.connectionCount)) — 黙った送り元を閉じる前提が無い")
            try #require(
                source.tally.accepted > atLimit,
                "台帳が目安に届いた後、新しい受け入れが起きなかった — 閉じる契機が来ていない")
        }
        #expect(swept)
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
        osc.send("/back", 1)
        #expect(await collect(osc, count: 1) == [OSCMessage("/back", 1)])
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

        sender.send("/size", Float(0.25))
        sender.send("/hit", 1)
        let received = await collect(receiver.osc, count: 2)
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
        let osc = try await listening(told: told).osc
        defer { osc.close() }

        osc.send(OSCMessage("/big", arguments: [.blob([UInt8](repeating: 7, count: 12000))]))
        osc.send("/after", 1)
        let received = await collect(osc, count: 1)
        #expect(received == [OSCMessage("/after", 1)])
        #expect(osc.input.unreadable == 0)
        #expect(told.lines.count == 1)
        #expect(told.count(containing: "9212 bytes at most") == 1)
        #expect(told.count(containing: "listening") == 0)
    }
}
