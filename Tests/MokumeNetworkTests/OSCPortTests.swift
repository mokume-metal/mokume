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
        let running = await until { osc.state == .running }
        guard running else {
            osc.close()
            throw ListeningFailure(state: osc.state)
        }
        guard let port = (osc.source as? NetworkOSCSource)?.boundPort else {
            osc.close()
            throw ListeningFailure(state: osc.state)
        }
        aimed.aim(at: port)
        return (osc, port)
    }

    /// 受け始められなかった。`state` はそのときの状態。
    private struct ListeningFailure: Error {
        let state: SourceState
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

    @Test("多くの送り元から一度に届いても 1 つも落とさず、黙った送り元は次の受け入れで閉じる")
    func manySendersAreAllHeardThenSwept() async throws {
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
        let count = DatagramListener.connectionLimit + 6
        let burst = (0..<count).map { _ in
            DatagramSender(host: "127.0.0.1", port: port, warn: told.append)
        }
        defer { for sender in burst { sender.stop() } }
        for (index, sender) in burst.enumerated() {
            sender.send(try Wire.encoded(OSCMessage("/from", index)))
        }
        let received = await collect(osc, count: count)
        #expect(Set(received.compactMap { $0.int(0) }) == Set(0..<count))
        // 受け入れた送り元を 1 本も外していない — 黙りでも (時計が止まっていて誰も黙っていない)、
        // 失敗でも。受け入れた数と持っている数が等しいことで、数え方の外で閉じる経路も捕まえる。
        // 受け入れた数が送り元の数 (70) に届くことは求めない: 負荷の下では Network.framework の
        // 受け口が、ある送り元の datagram を別の送り元の繋ぎで渡し、その送り元の繋ぎを作らない
        // ことがある (#2225 で実測。datagram は落ちない)。閉じたのではないので、ここでは数えない
        let tally = source.tally
        #expect(tally.closedIdle == 0)
        #expect(tally.ended == 0)
        #expect(source.connectionCount == tally.accepted)

        // ちょうど `idleAfter` 秒黙った後に新しい送り元が来たら、黙っていた送り元を閉じてから
        // 受ける (閉じるのは `idleAfter` 秒「以上」黙った送り元)
        clock.advance(by: idleAfter)
        let late = DatagramSender(host: "127.0.0.1", port: port, warn: told.append)
        defer { late.stop() }
        late.send(try Wire.encoded(OSCMessage("/late", 1)))
        #expect(await collect(osc, count: 1) == [OSCMessage("/late", 1)])
        #expect(source.connectionCount == 1)

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

        // 目安の数だけの送り元から送り、全部を読ませる
        let burst = (0..<DatagramListener.connectionLimit).map { _ in
            DatagramSender(host: "127.0.0.1", port: port, warn: told.append)
        }
        defer { for sender in burst { sender.stop() } }
        for (index, sender) in burst.enumerated() {
            sender.send(try Wire.encoded(OSCMessage("/from", index)))
        }
        #expect(await collect(osc, count: burst.count).count == burst.count)

        // `idleAfter` より長く黙ってから、新しい送り元を 1 本ずつ足す。待つほど黙りは長くなる
        // だけなので、遅い機械でも閉じる側へしか進まない。送り元の取り違えで数が目安に
        // 届いていなければ、足すうちに届く
        var late: [DatagramSender] = []
        defer { for sender in late { sender.stop() } }
        for index in 0..<20 where source.tally.closedIdle == 0 {
            try await Task.sleep(for: .milliseconds(100))
            let sender = DatagramSender(host: "127.0.0.1", port: port, warn: told.append)
            late.append(sender)
            sender.send(try Wire.encoded(OSCMessage("/late", index)))
        }
        #expect(await until { source.tally.closedIdle > 0 })
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

        #expect(await until { told.count(containing: "another app is using it") == 1 })
        #expect(osc.state == .unavailable)
        // 開き直しを何度か重ねても、知らせは増えない
        try await Task.sleep(for: .milliseconds(300))
        #expect(told.count(containing: "another app is using it") == 1)
        #expect(osc.state == .unavailable)

        holder.release()
        #expect(await until { osc.state == .running })
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
        // 両端は通る (走っていないスケッチなので、ポートは開かない)
        let edge = try sketch.createOSC(listen: 65535, send: ("127.0.0.1", 1))
        #expect(edge.port == 65535)
        #expect(edge.state == .unavailable)
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
