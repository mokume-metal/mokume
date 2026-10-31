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
    }
    private let inner = Mutex(Inner())

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
    final var state: PeerState { inner.withLock { $0.state } }

    /// 向こうが閉じた (または読めなくなった)。
    final var closedByPeer: Bool { inner.withLock { $0.ended } }

    /// 繋ぎの状態を決める。**繋がった後の `trouble` は無視する** (切れた相手は、受け口の数が示す)。
    final func setState(_ next: PeerState) {
        inner.withLock { inner in
            if case .trouble = next, inner.state == .ready { return }
            inner.state = next
        }
    }

    /// 向こうが閉じたと読む。
    final func markEnded() { inner.withLock { $0.ended = true } }

    /// 全部書く。繋がっていない・閉じた後は何もしない。書けなければ偽。
    @discardableResult
    final func write(_ bytes: [UInt8]) -> Bool {
        inner.withLock { inner in
            guard !inner.stopped, inner.connected, let descriptor = inner.descriptor else { return false }
            var offset = 0
            while offset < bytes.count {
                let written = bytes[offset...].withUnsafeBytes {
                    Darwin.send(descriptor, $0.baseAddress, $0.count, 0)
                }
                if written < 0 {
                    if errno == EINTR { continue }
                    return false
                }
                offset += written
            }
            return true
        }
    }

    /// 書く向きを閉じる (書いたものの後に、終わりの印が届く)。読む向きは開いたまま。
    final func finishWriting() {
        inner.withLock { inner in
            guard !inner.stopped, inner.connected, let descriptor = inner.descriptor else { return }
            shutdown(descriptor, SHUT_WR)
        }
    }

    /// 繋ぎを切る。読む thread も止まる。
    final func close() {
        inner.withLock { inner in
            inner.stopped = true
            if let descriptor = inner.descriptor { shutdown(descriptor, SHUT_RDWR) }
        }
    }

    // MARK: - 読む thread

    private func run() {
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else {
            setState(.trouble("socket failed (\(Self.describe(errno)))"))
            markEnded()
            return
        }
        defer {
            inner.withLock { $0.descriptor = nil }
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
            setState(
                .trouble(
                    "connect failed (errno \(code) \(Self.describe(code))・局所のポート \(local)・受け口のポート \(port))"))
            markEnded()
            return
        }
        _ = fcntl(descriptor, F_SETFL, flags)
        inner.withLock { $0.connected = true }
        connected()

        var buffer = [UInt8](repeating: 0, count: 65536)
        while true {
            let count = buffer.withUnsafeMutableBytes { recv(descriptor, $0.baseAddress, $0.count, 0) }
            if count > 0 {
                receive(Array(buffer[0..<count]))
                continue
            }
            if inner.withLock({ $0.stopped }) { return }
            if count < 0, errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR { continue }
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
            if ready < 0 {
                if errno == EINTR { continue }
                return errno
            }
            if ready > 0 {
                var failure: Int32 = 0
                var length = socklen_t(MemoryLayout<Int32>.size)
                getsockopt(descriptor, SOL_SOCKET, SO_ERROR, &failure, &length)
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

    /// 自分側のポート。繋げなかった socket では 0 のことがある。
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
    private let key: String
    private let texts = Mutex<[String]>([])

    // 読む thread だけが触る
    private var pending: [UInt8] = []
    private var shook = false
    private var fragments: [UInt8] = []
    private var fragmentIsText = false

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
        if !write(Array(request.utf8)) { setState(.trouble("handshake could not be written (受け口のポート \(port))")) }
    }

    override func receive(_ chunk: [UInt8]) {
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
        let expected = Data(
            Insecure.SHA1.hash(data: Data((key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").utf8))
        ).base64EncodedString()
        guard status.contains(" 101"), accept == expected else {
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
        while let frame = nextFrame() {
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
    }

    private func finishMessage() {
        // 空の 1 通は、空の文字列として積む。binary は積まない
        if fragmentIsText { texts.withLock { $0.append(String(decoding: fragments, as: UTF8.self)) } }
        fragments = []
    }

    private struct Frame {
        let fin: Bool
        let opcode: UInt8
        let payload: [UInt8]
    }

    /// 溜まったバイト列から frame を 1 つ取り出す。揃っていなければ nil。
    private func nextFrame() -> Frame? {
        guard pending.count >= 2 else { return nil }
        let fin = pending[0] & 0x80 != 0
        let opcode = pending[0] & 0x0F
        let masked = pending[1] & 0x80 != 0
        var length = Int(pending[1] & 0x7F)
        var offset = 2
        if length == 126 {
            guard pending.count >= 4 else { return nil }
            length = Int(pending[2]) << 8 | Int(pending[3])
            offset = 4
        } else if length == 127 {
            guard pending.count >= 10 else { return nil }
            length = (2..<10).reduce(0) { $0 << 8 | Int(pending[$1]) }
            offset = 10
        }
        var mask: [UInt8] = []
        if masked {
            guard pending.count >= offset + 4 else { return nil }
            mask = Array(pending[offset..<offset + 4])
            offset += 4
        }
        guard pending.count >= offset + length else { return nil }
        var payload = Array(pending[offset..<offset + length])
        if masked { for index in payload.indices { payload[index] ^= mask[index % 4] } }
        pending.removeSubrange(0..<offset + length)
        return Frame(fin: fin, opcode: opcode, payload: payload)
    }

    /// client の frame を 1 つ送る。**client の frame は必ずマスクする** (RFC 6455 5.3)。
    private func sendFrame(opcode: UInt8, payload: [UInt8]) {
        var frame: [UInt8] = [0x80 | opcode]
        if payload.count < 126 {
            frame.append(0x80 | UInt8(payload.count))
        } else if payload.count <= 0xFFFF {
            frame += [0x80 | 126, UInt8(payload.count >> 8), UInt8(payload.count & 0xFF)]
        } else {
            frame.append(0x80 | 127)
            frame += (0..<8).map { UInt8((payload.count >> (8 * (7 - $0))) & 0xFF) }
        }
        let mask = (0..<4).map { _ in UInt8.random(in: 0...255) }
        frame += mask
        frame += payload.enumerated().map { $0.element ^ mask[$0.offset % 4] }
        write(frame)
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
