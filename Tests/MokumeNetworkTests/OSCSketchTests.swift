// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

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
}
