// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Testing

@testable import MokumeCore
@testable import MokumeNetwork

/// 走っている実行へ足せない所 (`setup()`・`draw()`・入力のコールバックの外) から、通信の作る口を呼ぶ ([#2740])。
///
/// **呼んだ口の名前で言う。** 以前は作る口の中の ``SketchPart/attach(_:)-(Inlet)`` が黙って `false` を返し、
/// 足されていない (受けない・終わっても閉じられない) ポートを成功として返していた。送るだけならそれでも届いていた
/// (`send` は足されているかを見ない)。警告は利用者が呼んでいない `attach()` を名乗り、投げる口
/// (`createTCPServer(_:)` など) も投げなかった。#2683 (#2741) のカメラの口と同じ形に揃える。
///
/// 走らせずに投げる・警告することを見るので、GPU は要らない。ポートも開かない (足さないので開かない)。
///
/// [#2740]: https://github.com/mokume-metal/mokume/issues/2740
@MainActor
@Suite("走っている実行の外から呼んだ通信の作る口")
struct NetworkOutsideRunTests {
    @Test("投げる 4 口は、ポートを開く前に呼んだ口の名前で notRunning を投げ、口ごとに 1 度だけ警告する")
    func throwingMakersThrowNotRunning() throws {
        let log = OutsideRun()
        try OutsideRun.$current.withValue(log) {
            let sketch = IdleSketch()
            for _ in 0..<2 {
                #expect(throws: NetworkFailure.notRunning(call: "createTCPServer(_:)")) {
                    try sketch.createTCPServer(5204)
                }
                #expect(throws: NetworkFailure.notRunning(call: "createWebSocketServer(_:)")) {
                    try sketch.createWebSocketServer(8025)
                }
                #expect(throws: NetworkFailure.notRunning(call: "createUDP(listen:send:)")) {
                    try sketch.createUDP(listen: 6000, send: ("127.0.0.1", 6001))
                }
                #expect(throws: OSCFailure.notRunning(call: "createOSC(listen:send:)")) {
                    try sketch.createOSC(listen: 9000, send: ("127.0.0.1", 7000))
                }
            }
            let calls = [
                "createTCPServer(_:)", "createWebSocketServer(_:)", "createUDP(listen:send:)",
                "createOSC(listen:send:)",
            ]
            #expect(log.messages.count == calls.count, "口ごとに 1 行")
            for call in calls {
                let message = try #require(log.message(for: call), "\(call) が言っていない")
                #expect(message.hasPrefix("\(call) only works inside setup()"))
                #expect(message.contains("It threw an error instead of returning anything."))
            }
            #expect(log.message(for: "attach") == nil)
            #expect(!log.messages.contains { $0.contains("attach()") })
        }
    }

    @Test("投げない 4 口は、今までどおり足されていないポートを返し、呼んだ口の名前で 1 度だけ警告する")
    func recordedMakersWarnByTheirOwnName() {
        let log = OutsideRun()
        OutsideRun.$current.withValue(log) {
            let sketch = IdleSketch()
            for _ in 0..<2 {
                let tcp = sketch.createTCPServer(messages: [["a"]])
                let socket = sketch.createWebSocketServer(messages: [["a"]])
                let udp = sketch.createUDP(messages: [["a"]])
                let osc = sketch.createOSC(messages: [[OSCMessage("/a", 1)]])
                // 足されていないので、回されず何も届かない (今までどおり)
                #expect(tcp.messages.isEmpty && socket.messages.isEmpty && udp.messages.isEmpty)
                #expect(osc.messages.isEmpty)
            }
            let calls = [
                "createTCPServer(messages:)", "createWebSocketServer(messages:)", "createUDP(messages:)",
                "createOSC(messages:)",
            ]
            #expect(log.messages.count == calls.count, "口ごとに 1 行")
            for call in calls {
                let message = log.message(for: call)
                #expect(message?.hasPrefix("\(call) only works inside setup()") == true, "\(call)")
                #expect(message?.contains("was returned instead") == true, "\(call)")
            }
            #expect(log.message(for: "attach") == nil)
        }
    }

    @Test("notRunning の文面は口の名前と呼べる場所を名乗り、面の話をしない")
    func noticeNamesTheCallAndWhereItWorks() {
        for (failure, call) in [
            (NetworkFailure.notRunning(call: "createUDP(listen:send:)").description, "createUDP(listen:send:)"),
            (OSCFailure.notRunning(call: "createOSC(listen:send:)").description, "createOSC(listen:send:)"),
        ] {
            #expect(failure == OutsideRun.notAttachedNotice(call))
            #expect(failure.hasPrefix("\(call) only works inside setup(), draw() or an input callback"))
            #expect(!failure.contains("surface"))
            #expect(!failure.contains("not running"))
        }
    }
}
