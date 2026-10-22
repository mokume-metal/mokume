// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation
import Testing

@testable import MokumeCore
@testable import MokumeNetwork

/// `setup()` と `draw()` で、検査が渡した手続きを走らせるスケッチ。
final class OSCSketch: Sketch {
    nonisolated(unsafe) static var onSetup: (OSCSketch) -> Void = { _ in }
    nonisolated(unsafe) static var onDraw: (OSCSketch) -> Void = { _ in }
    init() {}
    var settings: SketchSettings { SketchSettings(width: 8, height: 8) }
    func setup() { Self.onSetup(self) }
    func draw() {
        background(0, 0, 0)
        Self.onDraw(self)
    }
}

/// 作る口で作った OSC の入り口を、走っているスケッチの中で回す (#1962)。GPU を要する。
///
/// 注入した列で回すので、ポートは開かない。**どのメッセージがどのフレームの `draw()` に届くかが
/// フレームの数え方だけで決まる**ことが約束で、これが水準 2 を名乗れる根拠になる
/// (ADR-0028 決定 7)。
@Suite(
    "OSC の入り口 (走っているスケッチ)",
    .serialized,
    .enabled(
        if: RenderDevice.isAvailable,
        "この世代のコマンド構造に対応した GPU が無い実行環境ではスキップする")
)
struct OSCSketchTests {
    /// 注入した列を流し、`draw()` ごとに届いたメッセージを集める。
    private func record(
        _ batches: [[OSCMessage]], frames: Int, stopAt: Int? = nil
    ) throws -> (frames: [[OSCMessage]], osc: OSCPort?) {
        var osc: OSCPort?
        var seen: [[OSCMessage]] = []
        OSCSketch.onSetup = { sketch in osc = sketch.createOSC(messages: batches) }
        OSCSketch.onDraw = { _ in
            seen.append(osc?.messages ?? [])
            if seen.count == stopAt { osc?.stop() }
        }
        let runtime = try SketchRuntime(sketch: OSCSketch(), gpu: try RenderDevice())
        for _ in 0..<frames { try runtime.advance() }
        return (seen, osc)
    }

    @Test("setup() で作った注入の入り口は、最初の draw() から 1 束ずつ、同じ並びで渡す")
    func injectedBatchesReachDrawInOrder() throws {
        let batches = [
            [OSCMessage("/size", Float(0.25))], [], [OSCMessage("/hit", 1), OSCMessage("/size", Float(0.5))],
        ]
        let first = try record(batches, frames: 5)
        #expect(first.frames == batches + batches.prefix(2))
        #expect(first.osc?.state == .running)
        #expect(first.osc?.lastArrival?.frame != nil)

        // 何度回しても、同じメッセージが同じフレームに届く
        let second = try record(batches, frames: 5)
        #expect(second.frames == first.frames)
    }

    /// **走っている所で呼べば、投げる 4 口は渡したポートで作ったものを足して返す** ([#2740](https://github.com/mokume-metal/mokume/issues/2740))。
    /// 走らせない検査は投げることしか見られないので、成功する側をここで見る (端の 65535 も)。足されたことは、
    /// 終わり (`closePlugins()`) に閉じられて `stopped` になることで見る — 足されていなければ誰も閉じない。
    /// ポートは実際に開く (すべての口で受ける) が、何も送らず、すぐ閉じる。
    @Test("setup() で呼んだ投げる 4 口は、渡したポートで作ったものを走っているスケッチへ足して返す (#2740)")
    func throwingMakersSucceedWhileRunning() throws {
        var tcp: TCPServer?
        var socket: WebSocketServer?
        var udp: UDPPort?
        var osc: OSCPort?
        var failures: [String] = []
        let log = OutsideRun()
        try OutsideRun.$current.withValue(log) {
            OSCSketch.onSetup = { sketch in
                do {
                    tcp = try sketch.createTCPServer(65535)
                    socket = try sketch.createWebSocketServer(65534)
                    udp = try sketch.createUDP(listen: 65533, send: ("127.0.0.1", 1))
                    osc = try sketch.createOSC(listen: 65532, send: ("127.0.0.1", 1))
                } catch {
                    failures.append("\(error)")
                }
            }
            OSCSketch.onDraw = { _ in }
            defer { OSCSketch.onSetup = { _ in } }
            let runtime = try SketchRuntime(sketch: OSCSketch(), gpu: try RenderDevice())
            try runtime.advance()
            #expect(failures.isEmpty, "\(failures)")
            #expect(tcp?.port == 65535)
            #expect(socket?.port == 65534)
            #expect(udp?.port == 65533)
            #expect(osc?.port == 65532)
            #expect(log.messages.isEmpty, "走っている所では何も言わない: \(log.messages)")
            runtime.closePlugins()
        }
        #expect(tcp?.state == .stopped)
        #expect(socket?.state == .stopped)
        #expect(udp?.state == .stopped)
        #expect(osc?.state == .stopped)
    }

    @Test("stop() の後は何も届かず、状態は stopped を名乗る")
    func stopEndsDelivery() throws {
        let batches = [[OSCMessage("/tick", 1)]]
        let result = try record(batches, frames: 4, stopAt: 2)
        #expect(result.frames.prefix(2).allSatisfy { $0 == batches[0] })
        #expect(result.frames.dropFirst(2).allSatisfy { $0.isEmpty })
        #expect(result.osc?.state == .stopped)
    }

    /// **`createOSC(send:)` は、受けるポートを開かずに、`createOSC(listen:send:)` と同じ送り手で送る** (#2469)。
    /// 受け手は検査が別に開く (番号は OS が選ぶ)。送るだけの口は `port` が `nil` で、観測の `inputs` に出ず、
    /// 作ったスケッチが終わると閉じられて `stopped` になる (足されていなければ誰も閉じない)。
    @Test("setup() で呼んだ createOSC(send:) は、受けるポートを開かず送れて、観測の inputs に行を出さない (#2469)")
    func sendOnlyMakerSendsToAnotherPort() async throws {
        let told = Told()
        let source = NetworkOSCSource(port: 0, host: "127.0.0.1", retryAfter: 0.05, warn: told.append)
        let receiver = OSCPort(
            port: 0, name: "osc :0", source: source, outbound: nil, owner: nil, warn: told.append)
        try receiver.open()
        defer { receiver.close() }
        try await requireState(told: told, tracing: source) { receiver.state }
        let target = try #require(source.boundPort)

        var sender: OSCPort?
        var failure: String?
        let runtime = try OutsideRun.$current.withValue(OutsideRun()) {
            OSCSketch.onSetup = { sketch in
                do { sender = try sketch.createOSC(send: ("127.0.0.1", target)) } catch { failure = "\(error)" }
            }
            OSCSketch.onDraw = { _ in sender?.send("/hit", 1) }
            defer { OSCSketch.onSetup = { _ in }; OSCSketch.onDraw = { _ in } }
            let runtime = try SketchRuntime(sketch: OSCSketch(), gpu: try RenderDevice())
            try runtime.advance()
            return runtime
        }
        #expect(failure == nil)
        let port = try #require(sender)
        #expect(port.port == nil)
        #expect(port.report == nil)
        #expect(port.state == .running)

        var received: [OSCMessage] = []
        // `createOSC(send:)` が組む送り手から送った 1 通が読まれる前提。読まれなかった回は、送り手と受け口の
        // 様子を名乗って止まる (#3001)
        let log = SendLog()
        log.watch { port.sendTrace }
        let started = Date()
        _ = await until {
            receiver.supply()
            received += receiver.messages
            return !received.isEmpty
        }
        log.record(
            label: "送り", expected: 1, heard: min(received.count, 1), missing: nil, replacements: 0,
            heardAfterReplacement: 0, waited: Date().timeIntervalSince(started), limit: 5)
        try await requireSent(
            !received.isEmpty, "1 通のうち読めたのは \(received.count) 通 (createOSC(send:) の送り手から)", log: log,
            landing: landing(of: receiver, port: target, told: told))
        #expect(received.first == OSCMessage("/hit", 1))
        #expect(port.messages.isEmpty)
        #expect(port.latest("/hit") == nil)

        runtime.closePlugins()
        #expect(port.state == .stopped)
    }
}
