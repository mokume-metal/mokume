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
    @Test("投げる 8 口は、ポートを開く前・繋ぐ前に呼んだ口の名前で notRunning を投げ、口ごとに 1 度だけ警告する")
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
                #expect(throws: NetworkFailure.notRunning(call: "createTCPClient(_:_:)")) {
                    try sketch.createTCPClient("127.0.0.1", 7000)
                }
                #expect(throws: NetworkFailure.notRunning(call: "createWebSocketClient(_:)")) {
                    try sketch.createWebSocketClient("ws://127.0.0.1:8025")
                }
                #expect(throws: NetworkFailure.notRunning(call: "createUDP(listen:send:)")) {
                    try sketch.createUDP(listen: 6000, send: ("127.0.0.1", 6001))
                }
                #expect(throws: OSCFailure.notRunning(call: "createOSC(listen:send:)")) {
                    try sketch.createOSC(listen: 9000, send: ("127.0.0.1", 7000))
                }
                #expect(throws: OSCFailure.notRunning(call: "createOSC(send:)")) {
                    try sketch.createOSC(send: ("127.0.0.1", 7000))
                }
                // ポートを開く前に断る (#2837)。足されなければ開かず、state も unavailable のまま変わらない
                #expect(throws: SerialFailure.notRunning(call: "createSerial(_:baudRate:)")) {
                    try sketch.createSerial(SerialPort(id: "/dev/cu.usbmodem14101", name: "Arduino Uno"), baudRate: 9600)
                }
            }
            let calls = [
                "createTCPServer(_:)", "createWebSocketServer(_:)", "createTCPClient(_:_:)",
                "createWebSocketClient(_:)", "createUDP(listen:send:)",
                "createOSC(listen:send:)", "createOSC(send:)", "createSerial(_:baudRate:)",
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

    @Test("投げない 7 口は、今までどおり足されていないポートを返し、呼んだ口の名前で 1 度だけ警告する")
    func recordedMakersWarnByTheirOwnName() {
        let log = OutsideRun()
        OutsideRun.$current.withValue(log) {
            let sketch = IdleSketch()
            for _ in 0..<2 {
                let tcp = sketch.createTCPServer(messages: [["a"]])
                let socket = sketch.createWebSocketServer(messages: [["a"]])
                let tcpClient = sketch.createTCPClient(messages: [["a"]])
                let socketClient = sketch.createWebSocketClient(messages: [["a"]])
                let udp = sketch.createUDP(messages: [["a"]])
                let osc = sketch.createOSC(messages: [[OSCMessage("/a", 1)]])
                let serial = sketch.createSerial(lines: [["1"]])
                // 足されていないので、回されず何も届かない (今までどおり)
                #expect(tcp.messages.isEmpty && socket.messages.isEmpty && udp.messages.isEmpty)
                #expect(tcpClient.messages.isEmpty && socketClient.messages.isEmpty)
                #expect(osc.messages.isEmpty && serial.lines.isEmpty)
            }
            let calls = [
                "createTCPServer(messages:)", "createWebSocketServer(messages:)",
                "createTCPClient(messages:)", "createWebSocketClient(messages:)", "createUDP(messages:)",
                "createOSC(messages:)", "createSerial(lines:)",
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

    @Test("ボーレートが使えなければ、外で呼んでも notRunning より先に invalidBaudRate を投げる")
    func unusableValueComesBeforeTheEntrance() {
        let log = OutsideRun()
        OutsideRun.$current.withValue(log) {
            let port = SerialPort(id: "/dev/cu.usbmodem14101", name: "Arduino Uno")
            #expect(throws: SerialFailure.invalidBaudRate(0)) {
                try IdleSketch().createSerial(port, baudRate: 0)
            }
            #expect(log.messages.isEmpty, "値の検めで断ったので、入口の警告は出ない")
        }
    }

    @Test("外で止める口 stop() は、呼んでいない detach() ではなく stop() を名乗り、1 度だけ警告する")
    func stopNamesItselfOutsideTheRun() {
        let sketch = IdleSketch()
        // 作って、2 度止める。止める前の作る口の警告は `stop()` を含まないので数えない
        let cases: [(type: String, run: () -> Void)] = [
            ("TCPServer", { let port = sketch.createTCPServer(messages: [["a"]]); port.stop(); port.stop() }),
            ("WebSocketServer", { let port = sketch.createWebSocketServer(messages: [["a"]]); port.stop(); port.stop() }),
            ("TCPClient", { let port = sketch.createTCPClient(messages: [["a"]]); port.stop(); port.stop() }),
            ("WebSocketClient", { let port = sketch.createWebSocketClient(messages: [["a"]]); port.stop(); port.stop() }),
            ("UDPPort", { let port = sketch.createUDP(messages: [["a"]]); port.stop(); port.stop() }),
            ("OSCPort", { let port = sketch.createOSC(messages: [[OSCMessage("/a", 1)]]); port.stop(); port.stop() }),
            ("Serial", { let port = sketch.createSerial(lines: [["1"]]); port.stop(); port.stop() }),
        ]
        // **控えは 1 つを共有する。** `Task` の中で続けて止めたとき、先に言った型が後の型を黙らせてはならない。
        // 口の名前は型を含み、型ごとに 1 度ずつ言う
        let log = OutsideRun()
        OutsideRun.$current.withValue(log) {
            for (_, run) in cases { run() }
        }
        let said = log.messages.filter { $0.contains(".stop()") }
        #expect(said.count == cases.count, "型ごとに 1 行 (2 度呼んでも増えず、続けて呼んでも黙らない)")
        for (type, _) in cases {
            let message = log.message(for: "\(type).stop()")
            #expect(message?.hasPrefix("\(type).stop() only works inside setup()") == true, "\(type)")
            #expect(message?.contains("so it did nothing") == true, "\(type)")
        }
        #expect(log.message(for: "detach") == nil, "呼んでいない detach() を名乗らない")
        #expect(!log.messages.contains { $0.contains("detach()") })
    }

    @Test("notRunning の文面は口の名前と呼べる場所を名乗り、面の話をしない")
    func noticeNamesTheCallAndWhereItWorks() {
        for (failure, call) in [
            (NetworkFailure.notRunning(call: "createUDP(listen:send:)").description, "createUDP(listen:send:)"),
            (OSCFailure.notRunning(call: "createOSC(listen:send:)").description, "createOSC(listen:send:)"),
            (SerialFailure.notRunning(call: "createSerial(_:baudRate:)").description, "createSerial(_:baudRate:)"),
        ] {
            #expect(failure == OutsideRun.notAttachedNotice(call))
            #expect(failure.hasPrefix("\(call) only works inside setup(), draw() or an input callback"))
            #expect(!failure.contains("surface"))
            #expect(!failure.contains("not running"))
        }
    }
}
