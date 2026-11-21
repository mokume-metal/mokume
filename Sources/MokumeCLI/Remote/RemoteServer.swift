// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation
import Network
import mokume

/// `--remote` の受け口。LAN に素の HTTP を 1 ポート開き、スマホへページとつまみの状態を配り、
/// 動かされた値をつまみの面 (`.mokume/params/`) の要求として置く。
///
/// **スケッチはポートを開かない。** 開くのはこの受け口だけで、どの要求もトークン (`?t=`) を確かめる。
/// 面とのやりとりは窓のつまみと同じ区画と規約に乗る (ADR-0030 決定 2) ので、子の側は何も変わらない。
///
/// **main の外で動く。** `run` は子を待つ間 main を塞ぐ (#1937) ので、通信も面の読み書きも、この
/// 受け口の直列の列の上で回す。
nonisolated final class RemoteServer: @unchecked Sendable {
    /// 受け口の様子。案内を出す呼び手へ 1 度だけ知らせる。
    enum Opening: Equatable {
        case ready(port: UInt16)
        case failed(String)
    }

    let token: String
    /// つまみの面の区画 (`.mokume/params`)。
    let facet: URL

    private let queue = DispatchQueue(label: "mokume.remote")
    private let host: String?
    private let requestedPort: UInt16
    private var listener: NWListener?
    private var clients: [ObjectIdentifier: Client] = [:]
    private var timer: DispatchSourceTimer?
    private var stopped = false
    /// 開いた結果をまだ知らせていない呼び手。
    private var pendingOpening: (@Sendable (Opening) -> Void)?

    private var state: RemoteKnobs.State = .waiting
    private var payload = RemoteKnobs.Payload.waiting()
    private var reportStamp: Date?
    private var writes = PendingParamWrites()
    private var ticks = 0
    private var everConnected = false
    private var writeFailureSaid = false

    /// 同時に持つ接続の上限。スマホ数台とつなぎ直しの重なりに足りる。
    static let maxClients = 16
    /// 面を見る間隔。
    static let tickInterval: DispatchTimeInterval = .milliseconds(50)
    /// 状態の配信が黙っている間に送る空行の間隔 (拍の数)。途中の機器に切られないため。
    static let keepAliveTicks = 300

    /// 最初のスマホが状態の配信につながった (窓の QR を下げる合図)。列の上で呼ばれる。
    var onFirstConnection: (@Sendable () -> Void)?
    /// 名乗り (面に要求を置けなかったなど)。列の上で呼ばれる。
    var warn: @Sendable (String) -> Void = { FileHandle.standardError.write(Data(($0 + "\n").utf8)) }

    /// - Parameters:
    ///   - facet: つまみの面の区画。
    ///   - token: 起動ごとの合言葉。既定は 128 bit の乱数。
    ///   - host: 待ち受けるアドレス。`nil` はすべての口 (LAN)。検査はループバックに縛る。
    ///   - port: 待ち受けるポート。0 は OS に選ばせる。
    init(facet: URL, token: String = RemoteServer.makeToken(), host: String? = nil, port: UInt16 = 0) {
        self.facet = facet
        self.token = token
        self.host = host
        self.requestedPort = port
    }

    /// 起動ごとの合言葉 (16 進 32 桁)。
    static func makeToken() -> String {
        var generator = SystemRandomNumberGenerator()
        return (0..<2).map { _ in String(format: "%016llx", generator.next() as UInt64) }.joined()
    }

    /// 開く。結果は `opened` に 1 度だけ届く (列の上)。
    func start(opened: @escaping @Sendable (Opening) -> Void) {
        queue.async { self.open(opened) }
    }

    /// 閉じる。つながっている相手も切る。戻ったときには閉じ終えている。
    func stop() {
        queue.sync {
            stopped = true
            timer?.cancel()
            timer = nil
            listener?.cancel()
            listener = nil
            for client in clients.values { client.connection.cancel() }
            clients.removeAll()
        }
    }

    /// スケッチの様子を変える (`watch` の作り直しの始まりと終わり)。
    func setState(_ newState: RemoteKnobs.State) {
        queue.async {
            guard self.state != newState else { return }
            self.state = newState
            self.reportStamp = nil  // 作り直しの後は、変わっていなくても読み直して配る
            self.payload.state = self.effectiveState
            self.broadcast()
        }
    }

    // MARK: - 列の上

    private var effectiveState: RemoteKnobs.State {
        state == .running && payload.revision == nil ? .waiting : state
    }

    private func open(_ opened: @escaping @Sendable (Opening) -> Void) {
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        let port = NWEndpoint.Port(rawValue: requestedPort) ?? .any
        let created: NWListener
        do {
            if let host {
                parameters.requiredLocalEndpoint = .hostPort(host: NWEndpoint.Host(host), port: port)
                created = try NWListener(using: parameters)
            } else {
                created = try NWListener(using: parameters, on: port)
            }
        } catch {
            opened(.failed("\(error)"))
            return
        }
        listener = created
        pendingOpening = opened
        created.stateUpdateHandler = { [weak self] update in
            guard let self, let opened = self.pendingOpening else { return }
            switch update {
            case .ready:
                self.pendingOpening = nil
                self.startTicking()
                opened(.ready(port: created.port?.rawValue ?? 0))
            case .failed(let error), .waiting(let error):
                self.pendingOpening = nil
                opened(.failed("\(error)"))
            default:
                break
            }
        }
        created.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
        created.start(queue: queue)
    }

    private func startTicking() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: RemoteServer.tickInterval)
        timer.setEventHandler { [weak self] in self?.tick() }
        timer.resume()
        self.timer = timer
    }

    /// 1 拍。応答が変わっていれば読んで配り、溜まった書き込みを要求として置く。
    private func tick() {
        guard !stopped else { return }
        ticks += 1
        readReportIfChanged()
        placeRequest()
        if ticks % RemoteServer.keepAliveTicks == 0 {
            for client in clients.values where client.streaming { client.send(Data(": keep-alive\n\n".utf8)) }
        }
    }

    private func readReportIfChanged() {
        let url = WorkDirectory.reportURL(under: facet)
        let stamp = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
        guard let stamp, stamp != reportStamp else { return }
        guard let data = try? Data(contentsOf: url), let read = RemoteKnobs.payload(from: data) else {
            return  // 書きかけ・読めない外枠は確定させず、次の拍で読み直す
        }
        reportStamp = stamp
        writes.observe(echo: read.id)
        var next = read
        next.state = state == .running ? .running : state
        guard next != payload else { return }
        payload = next
        broadcast()
    }

    private func placeRequest() {
        guard state == .running else { return }
        let echo = currentEcho()
        let id = "remote-" + UUID().uuidString
        guard let values = writes.nextRequest(echoNow: echo, id: id) else { return }
        do {
            try AtomicFile.writeJSON(Request(id: id, values: values), to: WorkDirectory.requestURL(under: facet))
        } catch {
            guard !writeFailureSaid else { return }
            writeFailureSaid = true
            warn(
                "Could not pass a knob change from the phone to the sketch (\(facet.path)): \(error)"
                    + " — further failures will not be reported")
        }
    }

    /// 置く直前に応答が echo している識別子。窓のつまみと同じく、置く前に読み直す
    /// (最後に読んだ応答は 1 拍古いことがある)。
    private func currentEcho() -> String? {
        struct Echo: Decodable { let id: String? }
        guard let data = try? Data(contentsOf: WorkDirectory.reportURL(under: facet)),
            let echo = try? JSONDecoder().decode(Echo.self, from: data)
        else { return payload.id }
        return echo.id
    }

    /// 面の要求の形 (`Schemas/params-request.schema.json`)。
    private struct Request: Encodable {
        let id: String
        let values: [NamedParamValue]
    }

    private func broadcast() {
        guard let event = event(for: payload) else { return }
        for client in clients.values where client.streaming { client.send(event) }
    }

    private func event(for payload: RemoteKnobs.Payload) -> Data? {
        var shown = payload
        shown.state = effectiveState
        guard let json = try? JSONEncoder().encode(shown) else { return nil }
        return Data("data: ".utf8) + json + Data("\n\n".utf8)
    }

    // MARK: - 接続

    private func accept(_ connection: NWConnection) {
        guard !stopped, clients.count < RemoteServer.maxClients else {
            connection.cancel()
            return
        }
        let client = Client(connection: connection)
        let key = ObjectIdentifier(client)
        clients[key] = client
        connection.stateUpdateHandler = { [weak self] update in
            switch update {
            case .failed, .cancelled: self?.clients[key] = nil
            default: break
            }
        }
        connection.start(queue: queue)
        receive(client)
    }

    private func receive(_ client: Client) {
        client.connection.receive(minimumIncompleteLength: 1, maximumLength: 16 * 1024) {
            [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data { client.buffer.append(data) }
            switch HTTPRequest.parse(client.buffer) {
            case .incomplete:
                if isComplete || error != nil {
                    client.connection.cancel()
                } else {
                    self.receive(client)
                }
            case .tooLarge:
                client.respond(status: "413 Content Too Large")
            case .invalid:
                client.respond(status: "400 Bad Request")
            case .complete(let request, _):
                self.handle(request, from: client)
            }
        }
    }

    private func handle(_ request: HTTPRequest, from client: Client) {
        guard RemoteServer.sameToken(request.query["t"] ?? "", token) else {
            client.respond(status: "403 Forbidden")
            return
        }
        switch (request.method, request.path) {
        case ("GET", "/"), ("GET", "/index.html"):
            client.respond(
                status: "200 OK", type: "text/html; charset=utf-8", body: Data(RemotePage.html.utf8))
        case ("GET", "/events"):
            client.streaming = true
            client.send(
                Data(
                    ("HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nCache-Control: no-store\r\n"
                        + "Connection: keep-alive\r\n\r\n").utf8))
            if let event = event(for: payload) { client.send(event) }
            if !everConnected {
                everConnected = true
                onFirstConnection?()
            }
        case ("POST", "/set"):
            guard effectiveState == .running else {
                client.respond(status: "409 Conflict")
                return
            }
            guard let write = RemoteWrite.parse(request.body, knobs: payload.knobs) else {
                client.respond(status: "400 Bad Request")
                return
            }
            writes.record(write)
            client.respond(status: "204 No Content")
        case (_, "/"), (_, "/index.html"), (_, "/events"), (_, "/set"):
            client.respond(status: "405 Method Not Allowed")
        default:
            client.respond(status: "404 Not Found")
        }
    }

    /// 合言葉を、長さ以外で時間差の出ない形で比べる。
    static func sameToken(_ given: String, _ expected: String) -> Bool {
        let lhs = Array(given.utf8)
        let rhs = Array(expected.utf8)
        guard lhs.count == rhs.count, !rhs.isEmpty else { return false }
        var difference: UInt8 = 0
        for index in rhs.indices { difference |= lhs[index] ^ rhs[index] }
        return difference == 0
    }

    /// つながっている相手 1 つ。列の上でだけ触る。
    private final class Client: @unchecked Sendable {
        let connection: NWConnection
        var buffer = Data()
        /// 状態の配信を受けている (接続を開けたままにする)。
        var streaming = false

        init(connection: NWConnection) { self.connection = connection }

        func send(_ data: Data) {
            connection.send(
                content: data,
                completion: .contentProcessed { [connection] error in if error != nil { connection.cancel() } })
        }

        /// 応えて閉じる。
        func respond(status: String, type: String? = nil, body: Data = Data()) {
            var head = "HTTP/1.1 \(status)\r\nContent-Length: \(body.count)\r\nCache-Control: no-store\r\n"
            if let type { head += "Content-Type: \(type)\r\n" }
            head += "Connection: close\r\n\r\n"
            connection.send(
                content: Data(head.utf8) + body,
                completion: .contentProcessed { [connection] _ in connection.cancel() })
        }
    }
}
