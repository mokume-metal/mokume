// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Darwin
import Foundation
import Testing

@testable import MokumeCLI
@testable import MokumeCore

/// `--remote` の受け口の往復 (#4126)。ループバックに縛って開き、素の BSD socket で叩く
/// (`NWConnection` を相手にしない。#3537)。
///
/// 見るのは約束だけ: 合言葉の無い要求はページも配信も書き込みも断って面に何も置かない / 合言葉があれば
/// ページを返す / 書き込みは面の要求として型つきで置かれる / 面の応答が変わると配信に 1 件届く /
/// 作り直しの間は書き込みを断る。
@Suite("--remote: server", .serialized)
struct RemoteServerTests {
    private static let token = "0123456789abcdef0123456789abcdef"
    /// 待つ側が持つ期限。越えたら名乗って赤にする (`.timeLimit` は使わない)。
    private static let deadline: TimeInterval = 10

    private struct Running {
        let server: RemoteServer
        let port: UInt16
        let facet: URL
    }

    private func start() throws -> Running {
        let facet = FileManager.default.temporaryDirectory
            .appendingPathComponent("remote-\(UUID().uuidString)/.mokume/params", isDirectory: true)
        try FileManager.default.createDirectory(at: facet, withIntermediateDirectories: true)
        let server = RemoteServer(facet: facet, token: Self.token, host: "127.0.0.1", port: 0)
        let opened = Mailbox<RemoteServer.Opening>()
        server.start { opened.put($0) }
        let opening = try #require(opened.take(within: Self.deadline), "the server did not open")
        guard case .ready(let port) = opening else {
            Issue.record("the server did not open: \(opening)")
            throw CancellationError()
        }
        server.setState(.running)
        return Running(server: server, port: port, facet: facet)
    }

    private func stop(_ running: Running) {
        running.server.stop()
        try? FileManager.default.removeItem(at: running.facet.deletingLastPathComponent().deletingLastPathComponent())
    }

    private func report(_ params: String, revision: Int = 1, id: String? = nil) -> String {
        let echo = id.map { "\"id\":\"\($0)\"," } ?? ""
        return """
            {"schemaVersion":2,"revision":\(revision),\(echo)"rejected":[],"clamped":[],"discarded":[],"params":[\(params)]}
            """
    }

    private let sizeKnob = #"{"name":"size","type":"float","value":0.3,"min":0,"max":1}"#

    @Test("合言葉の無い要求は、ページも配信も書き込みも 403 で断り、面に要求を置かない")
    func refusesWithoutToken() throws {
        let running = try start()
        defer { stop(running) }
        // 長さだけ違う合言葉と、長さが同じで 1 字違う合言葉の両方を断る
        let sameLength = String(Self.token.dropLast()) + "0"
        for target in [
            "/", "/events", "/?t=wrong", "/events?t=" + String(Self.token.dropLast()), "/?t=" + sameLength,
            "/events?t=" + sameLength,
        ] {
            let reply = try RawHTTP.exchange(port: running.port, "GET \(target) HTTP/1.1\r\nHost: x\r\n\r\n")
            #expect(reply.hasPrefix("HTTP/1.1 403"), "GET \(target): \(reply.prefix(40))")
        }
        let body = #"{"name":"size","type":"float","value":0.9}"#
        for target in ["/set", "/set?t=" + sameLength] {
            let reply = try RawHTTP.exchange(
                port: running.port,
                "POST \(target) HTTP/1.1\r\nHost: x\r\nContent-Length: \(body.utf8.count)\r\n\r\n\(body)")
            #expect(reply.hasPrefix("HTTP/1.1 403"), "POST \(target): \(reply.prefix(40))")
        }
        Thread.sleep(forTimeInterval: 0.3)  // 拍を数回まわしても置かれないこと
        #expect(!FileManager.default.fileExists(atPath: WorkDirectory.requestURL(under: running.facet).path))
    }

    @Test("合言葉があればページを返す。知らないパスは 404")
    func servesThePage() throws {
        let running = try start()
        defer { stop(running) }
        let page = try RawHTTP.exchange(port: running.port, "GET /?t=\(Self.token) HTTP/1.1\r\nHost: x\r\n\r\n")
        #expect(page.hasPrefix("HTTP/1.1 200"))
        #expect(page.contains("text/html"))
        #expect(page.contains("new EventSource(\"/events\""))
        let missing = try RawHTTP.exchange(port: running.port, "GET /nope?t=\(Self.token) HTTP/1.1\r\nHost: x\r\n\r\n")
        #expect(missing.hasPrefix("HTTP/1.1 404"))
    }

    @Test("書き込みは面の要求として型つきで置かれ、別の名前の書き込みは同じ要求に束ねられる")
    func placesWritesAsARequest() throws {
        let running = try start()
        defer { stop(running) }
        try report(sizeKnob + #",{"name":"on","type":"bool","value":false}"#)
            .write(to: WorkDirectory.reportURL(under: running.facet), atomically: true, encoding: .utf8)
        try waitUntil("the report is read") {
            // 応答を読むまでは書き込みを断る (スケッチを待つ間)
            let body = #"{"name":"on","type":"bool","value":true}"#
            return try RawHTTP.exchange(
                port: running.port,
                "POST /set?t=\(Self.token) HTTP/1.1\r\nHost: x\r\nContent-Length: \(body.utf8.count)\r\n\r\n\(body)"
            ).hasPrefix("HTTP/1.1 204")
        }
        let body = #"{"name":"size","type":"float","value":0.9}"#
        let reply = try RawHTTP.exchange(
            port: running.port,
            "POST /set?t=\(Self.token) HTTP/1.1\r\nHost: x\r\nContent-Length: \(body.utf8.count)\r\n\r\n\(body)")
        #expect(reply.hasPrefix("HTTP/1.1 204"))
        let requestURL = WorkDirectory.requestURL(under: running.facet)
        var values: [[String: Any]] = []
        try waitUntil("both writes are placed in one request") {
            guard let data = try? Data(contentsOf: requestURL),
                let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                let placed = object["values"] as? [[String: Any]]
            else { return false }
            values = placed
            return placed.count == 2
        }
        let byName = Dictionary(uniqueKeysWithValues: values.map { ($0["name"] as! String, $0) })
        #expect(byName["size"]?["type"] as? String == "float")
        #expect(byName["size"]?["value"] as? Double == 0.9)
        #expect(byName["on"]?["value"] as? Bool == true)
    }

    @Test("面の応答が変わると、配信に新しい状態が 1 件届く")
    func streamsReportChanges() throws {
        let running = try start()
        defer { stop(running) }
        let stream = try RawHTTP.Stream(port: running.port, "GET /events?t=\(Self.token) HTTP/1.1\r\nHost: x\r\n\r\n")
        defer { stream.close() }
        try stream.waitFor("\"state\":\"waiting\"", within: Self.deadline)
        try report(sizeKnob, revision: 4)
            .write(to: WorkDirectory.reportURL(under: running.facet), atomically: true, encoding: .utf8)
        try stream.waitFor("\"revision\":4", within: Self.deadline)
        #expect(stream.received.contains("\"kind\":\"slider\""))
        #expect(stream.received.contains("text/event-stream"))
    }

    /// 子は応答を `rename` で置き換える。時刻の刻みの粗い置き場では、続けて置いた 2 つの応答の更新時刻と
    /// 大きさが揃いうる。置き換わったことは inode (と状態変更時刻) でしか分からない (#4148)。
    @Test("面の応答が、更新時刻と大きさの同じ応答へ rename で置き換わっても配信に届く")
    func streamsAReportReplacedWithTheSameTimeAndSize() throws {
        let running = try start()
        defer { stop(running) }
        let reportURL = WorkDirectory.reportURL(under: running.facet)
        var sizes: [Int] = []
        func publish(revision: Int) throws {
            let staged = running.facet.appendingPathComponent("staged.json")
            let bytes = Data(report(sizeKnob, revision: revision).utf8)
            sizes.append(bytes.count)
            try bytes.write(to: staged)
            try FileManager.default.setAttributes(
                [.modificationDate: Date(timeIntervalSince1970: 7)], ofItemAtPath: staged.path)
            #expect(rename(staged.path, reportURL.path) == 0)
        }
        let stream = try RawHTTP.Stream(port: running.port, "GET /events?t=\(Self.token) HTTP/1.1\r\nHost: x\r\n\r\n")
        defer { stream.close() }
        try stream.waitFor("\"state\":\"waiting\"", within: Self.deadline)
        try publish(revision: 4)
        try stream.waitFor("\"revision\":4", within: Self.deadline)
        try publish(revision: 5)
        #expect(sizes.count == 2 && sizes[0] == sizes[1], "前提: 2 つの応答の大きさが揃っている: \(sizes)")
        try stream.waitFor("\"revision\":5", within: Self.deadline)
    }

    @Test("作り直しの間は書き込みを 409 で断り、配信は rebuilding を伝える")
    func refusesWritesWhileRebuilding() throws {
        let running = try start()
        defer { stop(running) }
        try report(sizeKnob).write(to: WorkDirectory.reportURL(under: running.facet), atomically: true, encoding: .utf8)
        let stream = try RawHTTP.Stream(port: running.port, "GET /events?t=\(Self.token) HTTP/1.1\r\nHost: x\r\n\r\n")
        defer { stream.close() }
        try stream.waitFor("\"state\":\"running\"", within: Self.deadline)
        running.server.setState(.rebuilding)
        try stream.waitFor("\"state\":\"rebuilding\"", within: Self.deadline)
        let body = #"{"name":"size","type":"float","value":0.9}"#
        let reply = try RawHTTP.exchange(
            port: running.port,
            "POST /set?t=\(Self.token) HTTP/1.1\r\nHost: x\r\nContent-Length: \(body.utf8.count)\r\n\r\n\(body)")
        #expect(reply.hasPrefix("HTTP/1.1 409"))
    }

    private func waitUntil(_ what: String, _ condition: () throws -> Bool) throws {
        let end = Date().addingTimeInterval(Self.deadline)
        while Date() < end {
            if try condition() { return }
            Thread.sleep(forTimeInterval: 0.05)
        }
        Issue.record("waited \(Self.deadline) s but \(what) did not happen")
        throw CancellationError()
    }
}

/// 1 つの値を、別の糸から渡して期限つきで受け取る箱。
private nonisolated final class Mailbox<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private let arrived = DispatchSemaphore(value: 0)
    private var value: Value?

    func put(_ new: Value) {
        lock.lock()
        value = new
        lock.unlock()
        arrived.signal()
    }

    func take(within seconds: TimeInterval) -> Value? {
        guard arrived.wait(timeout: .now() + seconds) == .success else { return nil }
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}

/// 127.0.0.1 へ素の BSD socket で HTTP を話す、検査の側の相手。
private nonisolated enum RawHTTP {
    struct Failure: Error, CustomStringConvertible {
        let description: String
    }

    static func connect(port: UInt16) throws -> Int32 {
        let socket = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard socket >= 0 else { throw Failure(description: "socket: errno \(errno)") }
        var timeout = timeval(tv_sec: 10, tv_usec: 0)
        setsockopt(socket, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(socket, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard result == 0 else {
            let code = errno
            Darwin.close(socket)
            throw Failure(description: "connect to 127.0.0.1:\(port): errno \(code)")
        }
        return socket
    }

    static func send(_ socket: Int32, _ text: String) throws {
        let bytes = Array(text.utf8)
        var sent = 0
        while sent < bytes.count {
            let count = bytes[sent...].withUnsafeBytes { Darwin.write(socket, $0.baseAddress, $0.count) }
            guard count > 0 else { throw Failure(description: "write: errno \(errno)") }
            sent += count
        }
    }

    /// 要求を 1 件送り、相手が閉じるまで読む。
    static func exchange(port: UInt16, _ request: String) throws -> String {
        let socket = try connect(port: port)
        defer { Darwin.close(socket) }
        try send(socket, request)
        var received = Data()
        var buffer = [UInt8](repeating: 0, count: 16 * 1024)
        while true {
            let count = Darwin.read(socket, &buffer, buffer.count)
            if count > 0 {
                received.append(contentsOf: buffer[0..<count])
            } else if count == 0 {
                break
            } else {
                throw Failure(description: "read: errno \(errno) after \(received.count) bytes")
            }
        }
        return String(decoding: received, as: UTF8.self)
    }

    /// 開けたままの配信を読み続ける相手。
    final class Stream {
        private let socket: Int32
        private(set) var received = ""

        init(port: UInt16, _ request: String) throws {
            socket = try RawHTTP.connect(port: port)
            var timeout = timeval(tv_sec: 0, tv_usec: 100_000)
            setsockopt(socket, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
            try RawHTTP.send(socket, request)
        }

        /// `text` が届くまで読む。期限を越えたら、それまでに届いたものを添えて投げる。
        func waitFor(_ text: String, within seconds: TimeInterval) throws {
            let end = Date().addingTimeInterval(seconds)
            var buffer = [UInt8](repeating: 0, count: 16 * 1024)
            while !received.contains(text) {
                guard Date() < end else {
                    throw Failure(description: "waited \(seconds) s for \(text); received: \(received)")
                }
                let count = Darwin.read(socket, &buffer, buffer.count)
                if count > 0 { received += String(decoding: buffer[0..<count], as: UTF8.self) }
                if count == 0 { throw Failure(description: "the stream closed; received: \(received)") }
            }
        }

        func close() { Darwin.close(socket) }
    }
}
