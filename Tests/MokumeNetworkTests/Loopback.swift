// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Darwin
import Foundation
import Network
import Synchronization
import Testing

@testable import MokumeNetwork

// 同じ機械の中で送って受ける検査が共有する道具。通信は 127.0.0.1 だけで行う。
//
// **待つ側が期限を持つ** — 届くのを待つ検査は、期限を越えたら満たされなかったとして落ちる
// (AGENTS.md「待ちを含む検査を書く」)。

/// 期限まで、条件が満ちるのを待つ。満ちなければ偽。
func until(_ seconds: TimeInterval = 5, _ condition: () -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(seconds)
    while Date() < deadline {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return condition()
}

/// フレームを回すように取り出しを続け、`count` 個届くまで (か期限まで) 集める。
func collect(_ port: TextPort, count: Int, within seconds: TimeInterval = 5) async -> [String] {
    var received: [String] = []
    _ = await until(seconds) {
        port.supply()
        received += port.messages
        return received.count >= count
    }
    return received
}

/// 受けた文字列を作例のスケッチと同じく読んだ結果 (数は大きさを置き換え、`hit` を数える)。
struct TextOutcome: Equatable {
    var size: Float = 0.5
    var hits = 0

    init(size: Float, hits: Int) {
        self.size = size
        self.hits = hits
    }

    init(_ messages: [String]) {
        for text in messages {
            if let value = Float(text) {
                size = value
            } else if text == "hit" {
                hits += 1
            }
        }
    }
}

/// 送る文字列の台本。大きさを動かし、当たりを数える。
let textScript = ["0.25", "hit", "0.75", "fade", "hit"]

/// 受け始めるまで待って、実際に開いたポートを返す。
func boundPort(of server: TextPort, source: StreamSource) async throws -> Int {
    #expect(await until { server.state == .running })
    return try #require(source.boundPort)
}

/// フレームを回すように取り出しを続け、繋いでいる相手の数が `count` になるまで (か期限まで) 待つ。
func clients(_ server: TextPort, reach count: Int) async -> Bool {
    await until {
        server.supply()
        return server.connected == count
    }
}

/// 127.0.0.1 のポートへ、素の BSD socket から datagram を送る相手 (他のアプリの代わり)。
///
/// **1 つの socket から送るので、受け口からは 1 つの送り元に見える。** 間を空けずに続けて送れば、
/// 後ろの datagram は受け口の同じ繋ぎに積まれている。送る上限 (`SO_SNDBUF`) を広げてあり、
/// macOS の既定 (`net.inet.udp.maxdgram` の 9216 バイト) を超える datagram も送れる —
/// ``DatagramSender`` は超えると `Message too long` で送れない。
nonisolated final class RawDatagramSocket: Sendable {
    private let descriptor: Int32

    init() throws {
        let descriptor = socket(AF_INET, SOCK_DGRAM, 0)
        guard descriptor >= 0 else { throw PortHolder.Failure(call: "socket", code: errno) }
        var size: Int32 = 1 << 20
        guard
            setsockopt(
                descriptor, SOL_SOCKET, SO_SNDBUF, &size, socklen_t(MemoryLayout<Int32>.size)) == 0
        else {
            let code = errno
            close(descriptor)
            throw PortHolder.Failure(call: "setsockopt", code: code)
        }
        self.descriptor = descriptor
    }

    /// 1 つの datagram として送る。送れたバイト数を返す (送れなければ -1)。
    func send(_ bytes: [UInt8], to port: Int) -> Int {
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(UInt16(port).bigEndian)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        return bytes.withUnsafeBytes { buffer in
            withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    sendto(
                        descriptor, buffer.baseAddress, bytes.count, 0, $0,
                        socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }
    }

    func release() { close(descriptor) }
}

/// 127.0.0.1 のポートへ TCP で繋ぐ相手 (`nc` の代わり)。届いたバイト列を溜める。
nonisolated final class StreamClient: @unchecked Sendable {
    // `@unchecked Sendable`: 可変の状態は錠の内側だけ。手続きは ``queue`` で走る。
    private let queue = DispatchQueue(label: "org.mokume.test.client")
    private let connection: NWConnection
    private let bytes = Mutex<[UInt8]>([])
    private let ready = Mutex(false)
    private let ended = Mutex(false)

    init(port: Int) {
        connection = NWConnection(
            host: "127.0.0.1", port: NWEndpoint.Port(rawValue: UInt16(port)) ?? .any, using: .tcp)
        connection.stateUpdateHandler = { [weak self] state in
            if case .ready = state { self?.ready.withLock { $0 = true } }
        }
        connection.start(queue: queue)
        receive()
    }

    /// 繋がったか。
    var isReady: Bool { ready.withLock { $0 } }
    /// 届いたバイト列を文字列にしたもの。
    var received: String { String(decoding: bytes.withLock { $0 }, as: UTF8.self) }
    /// 向こうが閉じたか。
    var closedByPeer: Bool { ended.withLock { $0 } }

    func send(_ text: String) { send(Array(text.utf8)) }

    func send(_ raw: [UInt8]) {
        connection.send(content: Data(raw), completion: .idempotent)
    }

    /// 送る向きを閉じる (送ったものの後に、終わりの印が届く)。受ける向きは開いたまま。
    func finish() {
        connection.send(content: nil, contentContext: .finalMessage, isComplete: true, completion: .idempotent)
    }

    /// 繋ぎを切る。
    func close() { connection.cancel() }

    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) {
            [weak self] content, _, isComplete, error in
            guard let self else { return }
            if let content { bytes.withLock { $0 += content } }
            if isComplete || error != nil {
                ended.withLock { $0 = true }
                return
            }
            receive()
        }
    }
}

/// 127.0.0.1 のポートへ WebSocket で繋ぐ相手 (ブラウザの代わり)。届いた text を 1 通ずつ溜める。
nonisolated final class WebSocketClient: @unchecked Sendable {
    // `@unchecked Sendable`: 可変の状態は錠の内側だけ。手続きは ``queue`` で走る。
    private let queue = DispatchQueue(label: "org.mokume.test.websocket")
    private let connection: NWConnection
    private let texts = Mutex<[String]>([])
    private let ended = Mutex(false)

    init(port: Int, path: String = "/") {
        let parameters = NWParameters.tcp
        parameters.defaultProtocolStack.applicationProtocols.insert(
            NWProtocolWebSocket.Options(), at: 0)
        connection = NWConnection(
            to: .url(URL(string: "ws://127.0.0.1:\(port)\(path)")!), using: parameters)
        connection.start(queue: queue)
        receive()
    }

    /// 届いた text。届いた順。
    var received: [String] { texts.withLock { $0 } }
    /// 向こうが閉じたか。
    var closedByPeer: Bool { ended.withLock { $0 } }

    /// 1 通の text として送る。
    func send(_ text: String) {
        send(Data(text.utf8), opcode: .text)
    }

    /// 1 通の binary として送る。
    func sendBinary(_ bytes: [UInt8]) {
        send(Data(bytes), opcode: .binary)
    }

    /// 繋ぎを切る。
    func close() { connection.cancel() }

    private func send(_ content: Data, opcode: NWProtocolWebSocket.Opcode) {
        let context = NWConnection.ContentContext(
            identifier: "message", metadata: [NWProtocolWebSocket.Metadata(opcode: opcode)])
        connection.send(content: content, contentContext: context, isComplete: true, completion: .idempotent)
    }

    private func receive() {
        connection.receiveMessage { [weak self] content, context, _, error in
            guard let self else { return }
            let metadata =
                context?.protocolMetadata(definition: NWProtocolWebSocket.definition)
                as? NWProtocolWebSocket.Metadata
            guard error == nil, let metadata, metadata.opcode != .close else {
                ended.withLock { $0 = true }
                return
            }
            // 空の 1 通は content が nil で届く。落とさずに空の文字列として積む
            if metadata.opcode == .text {
                texts.withLock { $0.append(String(decoding: content ?? Data(), as: UTF8.self)) }
            }
            receive()
        }
    }
}
