// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import CryptoKit
import Darwin
import Foundation
import Synchronization

// 受け口 (TCP・WebSocket) の往復の検査で、受け口へ繋ぎに行く**検査の側の相手**。
//
// **Network.framework の繋ぎ (`NWConnection`) を使わず、素の BSD socket で繋ぐ** (#3537)。専用機の
// 往復の検査が、相手の繋ぎだけ `waiting(Address already in use)` のまま 10 秒抜けず、3〜6 回作り直しても
// 救われずに赤になった (#3160 の UDP の送り元と同じ形)。検査が見ているのは受け口の約束で、相手は
// `nc` やブラウザの代わりにすぎない。素の `connect` なら、失敗は errno と局所のポートで名乗れる。
// 製品のクライアントと受け口の相互運用は、`StreamClientTests` が見続ける。

/// 127.0.0.1 のポートへ、素の BSD socket で TCP を繋ぐ土台。繋ぐ・読むは専用の thread で走り、
/// 書く・閉じるは呼んだ thread で走る。
///
/// 繋げなかったら、その事情 (errno・局所のポート・受け口のポート) を ``PeerState/trouble(_:)`` に名乗り、
/// socket を閉じる。**作り直すのは ``PeerGroup`` の仕事** (替える回数と猶予はそちらのまま)。
/// 書けなかったとき (繋がる前・読む thread が終わった後・errno) も、黙って捨てずに同じ口で名乗る。
nonisolated class RawStream: @unchecked Sendable {
    /// 繋ぐ手続き。socket を非ブロックにして `connect` した戻りの errno (成功は 0・`EINPROGRESS` は
    /// 繋ぎの途中) を返す。検査が失敗を作るために差し替える。
    typealias Connector = @Sendable (_ descriptor: Int32, _ port: Int) -> Int32

    /// 繋げなかったと名乗るまでの猶予 (秒)。`connect` が戻らない (受け口の待ち行列が溢れて SYN が捨てられる) ときの上限。
    static let connectLimit: TimeInterval = 5

    let port: Int
    private let connector: Connector

    private struct Inner {
        var descriptor: Int32?
        var stopped = false
        var state = PeerState.connecting
        var ended = false
        /// TCP が繋がった (書いてよい)。
        var connected = false
        /// 送っている最中の数。読む thread は、これが 0 になってから descriptor を閉じる。
        var writers = 0
        /// 検査の側が見つけた事情 (書けなかった・壊れた frame)。**一度名乗ったら消さない。**
        var failure: String?
    }
    private let inner = Mutex(Inner())
    /// 送りの直列化 (複数の thread が同じ socket へ書いても、frame が混ざらない)。`inner` の錠は持たずに送る。
    private let sendLock = Mutex(())

    init(port: Int, connector: @escaping Connector = RawStream.systemConnector) {
        self.port = port
        self.connector = connector
    }

    /// 繋ぎ始める。**子の `init` の最後で呼ぶ** — 子の状態が揃う前に、読んだものの手続きが走らない。
    final func start() {
        let thread = Thread { [self] in run() }
        thread.name = "org.mokume.test.rawstream"
        thread.start()
    }

    // MARK: - 子が決める

    /// TCP が繋がった (読み始める前)。既定は繋がったと名乗る。WebSocket は握手を始めて、握手が済むまで名乗らない。
    func connected() { setState(.ready) }

    /// 届いたバイト列。読む thread で呼ばれる。
    func receive(_ chunk: [UInt8]) {}

    // MARK: - 子と検査が使う

    /// 繋ぎの状態 (``LoopbackPeer``)。
    final var state: PeerState {
        inner.withLock { inner in
            if let failure = inner.failure { return .trouble(failure) }
            return inner.state
        }
    }

    /// 向こうが閉じた (または読めなくなった)。
    final var closedByPeer: Bool { inner.withLock { $0.ended } }

    /// 繋ぎの状態を決める。**繋がった後の `trouble` は無視する** (切れた相手は、受け口の数が示す)。
    /// 書けなかった・壊れた frame のように、相手でなく検査の側が見つけた事情は ``fail(_:)`` で名乗る。
    final func setState(_ next: PeerState) {
        inner.withLock { inner in
            if case .trouble = next, inner.state == .ready { return }
            inner.state = next
        }
    }

    /// 事情を名乗る。**繋がった後でも、後の `setState(.ready)` (繋がった・握手が済んだ) でも消えない** —
    /// 黙って捨てると、後ろの期待が連鎖して外れる。最初に名乗った事情を残す (後からの二次的な失敗で上書きしない)。
    final func fail(_ reason: String) {
        inner.withLock { inner in
            if inner.failure == nil { inner.failure = reason }
        }
    }

    /// 向こうが閉じたと読む。
    final func markEnded() { inner.withLock { $0.ended = true } }

    /// 全部書く。検査が `close()` した後は何もしない。書けなければ偽で、事情を名乗る
    /// (繋がる前・読む thread が終わった後・errno)。**錠を持たずに送る** — 送りが待たされても、
    /// `state`・`close()`・読む thread は止まらない。
    @discardableResult
    final func write(_ bytes: [UInt8]) -> Bool {
        guard let descriptor = acquire("send", bytes.count) else { return false }
        defer { release() }
        return sendLock.withLock { _ in
            var offset = 0
            while offset < bytes.count {
                let written = bytes[offset...].withUnsafeBytes {
                    Darwin.send(descriptor, $0.baseAddress, $0.count, 0)
                }
                let code = errno
                if written < 0 {
                    if code == EINTR { continue }
                    // 検査が閉じた後と、向こうが閉じた後 (close の返事や pong が EPIPE になる) は名乗らない
                    if inner.withLock({ $0.stopped || $0.ended }) { return false }
                    fail(
                        "send failed (errno \(code) \(Self.describe(code))・\(bytes.count) バイト中 \(offset) 書けた・受け口のポート \(port))"
                    )
                    return false
                }
                offset += written
            }
            return true
        }
    }

    /// 書く向きを閉じる (書いたものの後に、終わりの印が届く)。読む向きは開いたまま。
    final func finishWriting() {
        guard let descriptor = acquire("finish", 0) else { return }
        defer { release() }
        sendLock.withLock { _ in
            if shutdown(descriptor, SHUT_WR) != 0 {
                let code = errno
                if inner.withLock({ $0.stopped || $0.ended }) { return }
                fail("finish failed (errno \(code) \(Self.describe(code))・受け口のポート \(port))")
            }
        }
    }

    /// 繋ぎを切る。読む thread も止まる。
    final func close() {
        inner.withLock { inner in
            inner.stopped = true
            if let descriptor = inner.descriptor { shutdown(descriptor, SHUT_RDWR) }
        }
    }

    /// 書く・閉じる前に descriptor を借りる。借りられなければ、事情を名乗って nil。
    /// `close()` の後は、検査が閉じたのだから黙って nil。
    private func acquire(_ what: String, _ size: Int) -> Int32? {
        let result = inner.withLock { inner -> (descriptor: Int32?, reason: String?) in
            if inner.stopped { return (nil, nil) }
            guard inner.connected else {
                return (nil, "\(what) before connected (\(size) バイトを捨てた・受け口のポート \(port))")
            }
            guard let descriptor = inner.descriptor else {
                // 向こうが閉じた後の送りは、受け口の約束の話ではない。名乗らない
                if inner.ended { return (nil, nil) }
                return (nil, "\(what) after the connection ended (\(size) バイトを捨てた・受け口のポート \(port))")
            }
            inner.writers += 1
            return (descriptor, nil)
        }
        if let reason = result.reason { fail(reason) }
        return result.descriptor
    }

    private func release() { inner.withLock { $0.writers -= 1 } }

    // MARK: - 読む thread

    private func run() {
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        let opened = errno
        guard descriptor >= 0 else {
            setState(.trouble("socket failed (errno \(opened) \(Self.describe(opened)))"))
            markEnded()
            return
        }
        defer {
            // 新しい送りを断ち、送っている最中のものを起こして、終わるのを待ってから閉じる
            inner.withLock { inner in
                inner.descriptor = nil
                shutdown(descriptor, SHUT_RDWR)
            }
            while inner.withLock({ $0.writers }) > 0 { usleep(1000) }
            Darwin.close(descriptor)
        }
        var on: Int32 = 1
        setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        var sendLimit = timeval(tv_sec: 5, tv_usec: 0)
        setsockopt(descriptor, SOL_SOCKET, SO_SNDTIMEO, &sendLimit, socklen_t(MemoryLayout<timeval>.size))
        var slice = timeval(tv_sec: 0, tv_usec: 50_000)
        setsockopt(descriptor, SOL_SOCKET, SO_RCVTIMEO, &slice, socklen_t(MemoryLayout<timeval>.size))
        let flags = fcntl(descriptor, F_GETFL)
        _ = fcntl(descriptor, F_SETFL, flags | O_NONBLOCK)
        let stopped = inner.withLock { inner -> Bool in
            inner.descriptor = descriptor
            return inner.stopped
        }
        if stopped { return }

        var code = connector(descriptor, port)
        if code == EINPROGRESS { code = awaitConnect(descriptor) }
        if inner.withLock({ $0.stopped }) { return }
        guard code == 0 else {
            let local = Self.localPort(of: descriptor)
            let localText = local == 0 ? "未割り当て" : String(local)
            setState(
                .trouble(
                    "connect failed (errno \(code) \(Self.describe(code))・局所のポート \(localText)・受け口のポート \(port))"
                ))
            markEnded()
            return
        }
        _ = fcntl(descriptor, F_SETFL, flags)
        inner.withLock { $0.connected = true }
        connected()

        var buffer = [UInt8](repeating: 0, count: 65536)
        while true {
            let count = buffer.withUnsafeMutableBytes { recv(descriptor, $0.baseAddress, $0.count, 0) }
            // errno は、錠を取るなど他の呼びが書き換える前に控える
            let code = errno
            if count > 0 {
                receive(Array(buffer[0..<count]))
                continue
            }
            if inner.withLock({ $0.stopped }) { return }
            if count < 0, code == EAGAIN || code == EWOULDBLOCK || code == EINTR { continue }
            markEnded()
            return
        }
    }

    /// 非ブロックの `connect` が済むのを待つ。戻りは errno (成功は 0)。上限か `close()` で諦める。
    private func awaitConnect(_ descriptor: Int32) -> Int32 {
        let deadline = Date().addingTimeInterval(Self.connectLimit)
        while Date() < deadline {
            if inner.withLock({ $0.stopped }) { return ECANCELED }
            var poller = pollfd(fd: descriptor, events: Int16(POLLOUT), revents: 0)
            let ready = poll(&poller, 1, 50)
            let code = errno
            if ready < 0 {
                if code == EINTR { continue }
                return code
            }
            if ready > 0 {
                var failure: Int32 = 0
                var length = socklen_t(MemoryLayout<Int32>.size)
                guard getsockopt(descriptor, SOL_SOCKET, SO_ERROR, &failure, &length) == 0 else {
                    return errno
                }
                return failure
            }
        }
        return ETIMEDOUT
    }

    // MARK: - 道具

    /// 既定の繋ぎ方: 127.0.0.1 のポートへ非ブロックで `connect` する。
    static let systemConnector: Connector = { descriptor, port in
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(UInt16(truncatingIfNeeded: port).bigEndian)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        return result == 0 ? 0 : errno
    }

    /// 自分側のポート。繋げなかった socket では 0 (未割り当て) のことがある。
    /// 宛先を知らずに局所のポートを選ばないよう、`connect` の前に `bind` はしない (衝突を増やしうる)。
    static func localPort(of descriptor: Int32) -> Int {
        var address = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(descriptor, $0, &length) }
        }
        return Int(UInt16(bigEndian: address.sin_port))
    }

    /// errno の C の文面 (言語の設定に左右されない)。
    static func describe(_ code: Int32) -> String { String(cString: strerror(code)) }
}

/// 127.0.0.1 のポートへ TCP で繋ぐ相手 (`nc` の代わり)。届いたバイト列を溜める。
nonisolated final class StreamClient: RawStream, LoopbackPeer, @unchecked Sendable {
    private let bytes = Mutex<[UInt8]>([])

    override init(port: Int, connector: @escaping Connector = RawStream.systemConnector) {
        super.init(port: port, connector: connector)
        start()
    }

    /// 届いたバイト列を文字列にしたもの。
    var received: String { String(decoding: bytes.withLock { $0 }, as: UTF8.self) }

    func send(_ text: String) { send(Array(text.utf8)) }

    func send(_ raw: [UInt8]) { write(raw) }

    /// 送る向きを閉じる (送ったものの後に、終わりの印が届く)。受ける向きは開いたまま。
    func finish() { finishWriting() }

    override func receive(_ chunk: [UInt8]) {
        bytes.withLock { $0 += chunk }
    }
}

/// 127.0.0.1 のポートへ WebSocket で繋ぐ相手 (ブラウザの代わり)。届いた text を 1 通ずつ溜める。
///
/// RFC 6455 の client の側を、検査に要る分だけ書く: 握手 (`Sec-WebSocket-Key`・返ってくる
/// `Sec-WebSocket-Accept` の照合)・text と binary の frame (**client の frame はマスクする**)・
/// 届いた text / continuation / ping (pong で答える) / close。
nonisolated final class BrowserSocket: RawStream, LoopbackPeer, @unchecked Sendable {
    private let path: String
    let key: String
    private let texts = Mutex<[String]>([])

    // 読む thread だけが触る
    private var pending: [UInt8] = []
    private var shook = false
    private var fragments: [UInt8] = []
    private var fragmentIsText = false
    private var broken = false

    init(port: Int, path: String = "/", connector: @escaping Connector = RawStream.systemConnector) {
        self.path = path
        key = Data((0..<16).map { _ in UInt8.random(in: 0...255) }).base64EncodedString()
        super.init(port: port, connector: connector)
        start()
    }

    /// 届いた text。届いた順。
    var received: [String] { texts.withLock { $0 } }

    /// 1 通の text として送る。
    func send(_ text: String) { sendFrame(opcode: 0x1, payload: Array(text.utf8)) }

    /// 1 通の binary として送る。
    func sendBinary(_ bytes: [UInt8]) { sendFrame(opcode: 0x2, payload: bytes) }

    // MARK: - 握手

    /// TCP が繋がったら握手を送る。握手が済むまで繋がったと名乗らない (`NWConnection` が `ready` を名乗る形と同じ)。
    override func connected() {
        let request =
            "GET \(path) HTTP/1.1\r\nHost: 127.0.0.1:\(port)\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n"
            + "Sec-WebSocket-Key: \(key)\r\nSec-WebSocket-Version: 13\r\n\r\n"
        write(Array(request.utf8))
    }

    override func receive(_ chunk: [UInt8]) {
        if broken { return }
        pending += chunk
        if !shook, !readHandshake() { return }
        readFrames()
    }

    /// 応答の頭を読む。まだ揃わなければ偽 (次の読みを待つ)。握手が成り立たなければ名乗って終える。
    private func readHandshake() -> Bool {
        let end = Array("\r\n\r\n".utf8)
        guard let range = Self.find(end, in: pending) else { return false }
        let head = String(decoding: pending[0..<range.lowerBound], as: UTF8.self)
        pending.removeSubrange(0..<range.upperBound)
        let lines = head.components(separatedBy: "\r\n")
        let status = lines.first ?? ""
        let accept = lines.dropFirst().compactMap { line -> String? in
            let parts = line.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            return parts.count == 2 && parts[0].lowercased() == "sec-websocket-accept" ? parts[1] : nil
        }.first
        guard status.contains(" 101"), accept == WebSocketFrames.accept(for: key) else {
            setState(.trouble("handshake refused (\(status)・accept \(accept ?? "なし"))"))
            markEnded()
            return false
        }
        shook = true
        setState(.ready)
        return true
    }

    // MARK: - frame

    private func readFrames() {
        while true {
            switch WebSocketFrames.decode(pending) {
            case .incomplete:
                return
            case .invalid(let reason):
                // 受け口の約束が破れた (壊れた frame)。落ちずに名乗って、以後読まない
                // 壊れた frame は「向こうが閉じた」ではない: 読みを止めるだけで closedByPeer は立てない
                fail("invalid frame from the receiver: \(reason)・受け口のポート \(port)")
                pending = []
                broken = true
                return
            case .frame(let frame, let consumed):
                pending.removeSubrange(0..<consumed)
                handle(frame)
            }
        }
    }

    private func handle(_ frame: WebSocketFrames.Frame) {
        switch frame.opcode {
        case 0x1, 0x2:
            fragmentIsText = frame.opcode == 0x1
            fragments = frame.payload
            if frame.fin { finishMessage() }
        case 0x0:
            fragments += frame.payload
            if frame.fin { finishMessage() }
        case 0x8:
            markEnded()
            sendFrame(opcode: 0x8, payload: Array(frame.payload.prefix(2)))
        case 0x9:
            sendFrame(opcode: 0xA, payload: frame.payload)
        default:
            break
        }
    }

    private func finishMessage() {
        // 空の 1 通は、空の文字列として積む。binary は積まない
        if fragmentIsText { texts.withLock { $0.append(String(decoding: fragments, as: UTF8.self)) } }
        fragments = []
    }

    /// client の frame を 1 つ送る。**client の frame は必ずマスクする** (RFC 6455 5.3)。
    /// 書けなければ ``RawStream/write(_:)`` が名乗る。
    private func sendFrame(opcode: UInt8, payload: [UInt8]) {
        write(WebSocketFrames.encode(opcode: opcode, payload: payload))
    }

    private static func find(_ needle: [UInt8], in haystack: [UInt8]) -> Range<Int>? {
        guard haystack.count >= needle.count else { return nil }
        for start in 0...(haystack.count - needle.count)
        where Array(haystack[start..<start + needle.count]) == needle {
            return start..<start + needle.count
        }
        return nil
    }
}

/// WebSocket (RFC 6455) の frame の符号化と読み。socket に触らない純関数で、検査が長さの符号化を直に見る。
nonisolated enum WebSocketFrames {
    struct Frame: Equatable {
        let fin: Bool
        let opcode: UInt8
        let payload: [UInt8]
    }

    enum Decoded: Equatable {
        /// まだ揃っていない。
        case incomplete
        /// 1 つ取り出せた。`consumed` は使ったバイト数。
        case frame(Frame, consumed: Int)
        /// 壊れている (長さが範囲外など)。
        case invalid(String)
    }

    /// 握手の応答の `Sec-WebSocket-Accept` (RFC 6455 4.2.2)。
    static func accept(for key: String) -> String {
        Data(Insecure.SHA1.hash(data: Data((key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").utf8))).base64EncodedString()
    }

    /// 1 つの frame の中身の上限。検査が扱う大きさの桁を大きく越えるものは、壊れたとみなす。
    static let payloadLimit = 1 << 26

    /// client の frame を作る。**client の frame は必ずマスクする** (RFC 6455 5.3)。`mask` は検査が固定できる。
    static func encode(
        opcode: UInt8, payload: [UInt8], fin: Bool = true,
        mask: [UInt8] = (0..<4).map { _ in UInt8.random(in: 0...255) }
    ) -> [UInt8] {
        var frame: [UInt8] = [(fin ? 0x80 : 0) | opcode]
        if payload.count < 126 {
            frame.append(0x80 | UInt8(payload.count))
        } else if payload.count <= 0xFFFF {
            frame += [0x80 | 126, UInt8(payload.count >> 8), UInt8(payload.count & 0xFF)]
        } else {
            frame.append(0x80 | 127)
            frame += (0..<8).map { UInt8((payload.count >> (8 * (7 - $0))) & 0xFF) }
        }
        frame += mask
        frame += payload.enumerated().map { $0.element ^ mask[$0.offset % 4] }
        return frame
    }

    /// 溜まったバイト列から frame を 1 つ取り出す。マスクされていれば外す (server の frame は普通マスクしない)。
    static func decode(_ pending: [UInt8]) -> Decoded {
        guard pending.count >= 2 else { return .incomplete }
        let fin = pending[0] & 0x80 != 0
        let opcode = pending[0] & 0x0F
        let masked = pending[1] & 0x80 != 0
        var length = UInt64(pending[1] & 0x7F)
        var offset = 2
        if length == 126 {
            guard pending.count >= 4 else { return .incomplete }
            length = UInt64(pending[2]) << 8 | UInt64(pending[3])
            offset = 4
        } else if length == 127 {
            guard pending.count >= 10 else { return .incomplete }
            length = (2..<10).reduce(UInt64(0)) { $0 << 8 | UInt64(pending[$1]) }
            offset = 10
        }
        guard length <= UInt64(payloadLimit) else {
            return .invalid("payload length \(length) is out of range (limit \(payloadLimit))")
        }
        let size = Int(length)
        var mask: [UInt8] = []
        if masked {
            guard pending.count >= offset + 4 else { return .incomplete }
            mask = Array(pending[offset..<offset + 4])
            offset += 4
        }
        guard pending.count >= offset + size else { return .incomplete }
        var payload = Array(pending[offset..<offset + size])
        if masked { for index in payload.indices { payload[index] ^= mask[index % 4] } }
        return .frame(Frame(fin: fin, opcode: opcode, payload: payload), consumed: offset + size)
    }
}
