// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Darwin
import Foundation
import Synchronization
import Testing

@testable import MokumeCore
@testable import MokumeNetwork

/// 擬似端末の対。検査は相手の側 (master) に書き、入り口は端末の側 (`path`) を termios で開く。
/// Arduino の代わりに、USB のシリアルポートと同じ経路 (open・tcsetattr・read) を通す。
nonisolated final class PseudoTerminal: @unchecked Sendable {
    // `@unchecked Sendable`: 可変の状態 (``closed``) は検査のスレッドでだけ触る。

    struct Failure: Error {
        let call: String
        let code: Int32
    }

    /// 端末の側の経路 (`/dev/ttys005` など)。
    let path: String
    private let master: Int32
    private var closed = false

    init() throws {
        let master = posix_openpt(O_RDWR | O_NOCTTY)
        guard master >= 0 else { throw Failure(call: "posix_openpt", code: errno) }
        guard grantpt(master) == 0, unlockpt(master) == 0, let name = ptsname(master) else {
            let code = errno
            close(master)
            throw Failure(call: "grantpt", code: code)
        }
        // **書く側も待たない。** 端末の側を誰も開いていないと、書いたものが読まれずに詰まって
        // write が戻らなくなる (入り口が開き直せなかったときに、検査ごと止まった)
        _ = fcntl(master, F_SETFL, O_NONBLOCK)
        self.master = master
        path = String(cString: name)
    }

    /// 相手 (Arduino) が送ったかのように書く。読まれずに詰まったら、期限で書くのをやめる
    /// (届かなかったことは、受ける側の検査が落として知らせる)。
    func send(_ text: String) { send(Array(text.utf8)) }

    func send(_ bytes: [UInt8], within seconds: TimeInterval = 5) {
        let deadline = Date().addingTimeInterval(seconds)
        var offset = 0
        while offset < bytes.count, Date() < deadline {
            let written = bytes[offset...].withUnsafeBufferPointer {
                write(master, $0.baseAddress, $0.count)
            }
            if written < 0 {
                if errno == EINTR { continue }
                guard errno == EAGAIN else { return }
                usleep(1000)
                continue
            }
            offset += written
        }
    }

    /// 相手の側を閉じる。端末の側の読み取りは終わり (0) を返す (抜かれたのと同じ)。
    func hangUp() {
        guard !closed else { return }
        closed = true
        close(master)
    }

    deinit { hangUp() }
}

/// 一時の場所に置いた symlink。**同じ識別子のポートを抜いて挿し直す**のを作る — 擬似端末の経路は
/// 作るたびに変わるので、入り口にはこちらの経路を開かせ、指す先を差し替える。
nonisolated final class PortLink: @unchecked Sendable {
    let path: String
    private let directory: URL

    init() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("mokume-serial-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        path = directory.appendingPathComponent("cu.usbmodem-test").path
    }

    /// 挿す (指す先を `target` にする)。
    func plug(into target: String) throws {
        unplug()
        try FileManager.default.createSymbolicLink(atPath: path, withDestinationPath: target)
    }

    /// 抜く (経路を消す)。
    func unplug() {
        try? FileManager.default.removeItem(atPath: path)
    }

    deinit { try? FileManager.default.removeItem(at: directory) }
}

/// 書き手を検査が握る pipe。**開く手を差し替えて**、読み手を入り口に渡す。書き手を閉じると、
/// 溜まっていた分を読み終えた後に終わり (0) が来る — 擬似端末と違い、閉じたときに溜まっていた
/// 分が消えないので、抜かれたときの残りの扱いを決まった順で確かめられる。
nonisolated final class PipeDevice: @unchecked Sendable {
    private let reader: Int32
    private let writer: Int32
    private let handed = Mutex(false)

    init() throws {
        var ends: [Int32] = [0, 0]
        guard pipe(&ends) == 0 else { throw PseudoTerminal.Failure(call: "pipe", code: errno) }
        reader = ends[0]
        writer = ends[1]
        _ = fcntl(reader, F_SETFL, O_NONBLOCK)
    }

    /// 1 度目は読み手を渡し、2 度目からは繋がっていない (抜かれた後) と答える開く手。
    var opener: SerialDevice.Opener {
        { [self] _, _ in
            let first = handed.withLock { handed in defer { handed = true }; return !handed }
            return first ? .success(reader) : .failure(.absent)
        }
    }

    func send(_ text: String) {
        _ = Array(text.utf8).withUnsafeBufferPointer { write(writer, $0.baseAddress, $0.count) }
    }

    func closeWriter() { close(writer) }
}

/// シリアルの入り口 (#1961)。GPU は要らない。機材も要らない — Arduino の代わりに擬似端末の対と
/// pipe を使う。
///
/// 入り口を走っているスケッチに足さず、フレームの代わりに ``Serial/supply()`` を自分で呼ぶ。
/// **待つ側が期限を持つ** — 届くのを待つ検査は、期限を越えたら満たされなかったとして落ちる。
@Suite("シリアルの入り口", .serialized)
struct SerialTests {
    /// `path` を開く入り口。開き直しの間隔は短くする。
    private func serial(
        path: String, told: Told, opener: @escaping SerialDevice.Opener = SerialDevice.open,
        input: ExternalQueue<String>? = nil
    ) throws -> Serial {
        let source = SerialSource(
            path: path, baudRate: 9600, retryAfter: 0.05, opener: opener, warn: told.append)
        let serial = Serial(name: "serial: \(path)", source: source, owner: nil, input: input)
        try serial.open()
        return serial
    }

    /// フレームを回すように取り出しを続け、`count` 行届くまで (か期限まで) 集める。
    private func collect(_ serial: Serial, count: Int) async -> [String] {
        var received: [String] = []
        _ = await until {
            serial.supply()
            received += serial.lines
            return received.count >= count
        }
        return received
    }

    // MARK: - 受ける

    @Test("届いた行を届いた順に受け、行の途中で切れて届いてもつなぐ。println の \\r\\n の \\r は落とす")
    func receivesLinesInOrder() async throws {
        let told = Told()
        let terminal = try PseudoTerminal()
        let serial = try serial(path: terminal.path, told: told)
        defer { serial.close() }
        #expect(await until { serial.state == .running })

        terminal.send("0\r\n512\r\n")
        terminal.send("10")
        terminal.send("23\r\n")
        #expect(await collect(serial, count: 3) == ["0", "512", "1023"])
        #expect(serial.lastArrival != nil)
        #expect(
            serial.report
                == SourceReport(
                    name: "serial: \(terminal.path)", state: .running, lastArrival: serial.lastArrival))
        #expect(told.lines.isEmpty)
    }

    @Test("UTF-8 として読めない行・長すぎる行は捨てて数え、前後の行は届く")
    func unreadableLinesAreDiscardedAndCounted() async throws {
        let told = Told()
        let terminal = try PseudoTerminal()
        let serial = try serial(path: terminal.path, told: told)
        defer { serial.close() }
        #expect(await until { serial.state == .running })

        terminal.send("before\n")
        terminal.send([0x68, 0xFF, 0x0A])  // 'h' と、UTF-8 に現れないバイト
        terminal.send([UInt8](repeating: 0x61, count: SerialReader.lineLimit + 10) + [0x0A])
        terminal.send("after\n")
        #expect(await collect(serial, count: 2) == ["before", "after"])
        #expect(await until { serial.input.unreadable == 2 })
    }

    @Test("1 フレームの間に上限を超えて届いた行は古いものから捨て、捨てた数を次の取り出しで診断に出す")
    func overflowIsDroppedAndTold() async throws {
        let told = Told()
        let terminal = try PseudoTerminal()
        let queue = ExternalQueue<String>(
            name: "serial: knob", state: .unavailable, capacity: 4, warn: told.append, now: { 100 })
        let serial = try serial(path: terminal.path, told: told, input: queue)
        defer { serial.close() }
        #expect(await until { serial.state == .running })

        terminal.send((1...6).map { "\($0)\r\n" }.joined())
        #expect(await until { queue.overflowed == 2 })
        serial.supply()
        #expect(serial.lines == ["3", "4", "5", "6"])
        #expect(
            told.lines == ["serial: knob: 2 were dropped because 4 were already waiting to be read (2 in all)"])
    }

    @Test("Arduino と同じバイト列を擬似端末から流した結果と、記録した行で流した結果が同じになる")
    func terminalAndRecordedLinesAgree() async throws {
        let knob = ["0", "256", "512", "768", "1023"]
        let told = Told()
        let terminal = try PseudoTerminal()
        let live = try serial(path: terminal.path, told: told)
        defer { live.close() }
        #expect(await until { live.state == .running })
        for value in knob { terminal.send("\(value)\r\n") }
        let received = await collect(live, count: knob.count)

        let recorded = Serial(
            name: "serial (recorded)", source: RecordedSource(batches: [knob]), owner: nil)
        try recorded.open()
        recorded.supply()

        #expect(received == knob)
        #expect(recorded.lines == received)
        // 作例と同じく読んだ結果 (円の横の位置) も同じ
        let place = { (lines: [String]) in lines.compactMap(Float.init).map { $0 / 1023 * 960 } }
        #expect(place(recorded.lines) == place(received))
        #expect(recorded.state == .running)
    }

    // MARK: - 抜き差し

    @Test("抜くと disconnected になり、同じ識別子のポートを挿し直すと running に戻って受け始める")
    func replugReturnsToRunning() async throws {
        let told = Told()
        let link = try PortLink()
        let first = try PseudoTerminal()
        try link.plug(into: first.path)
        let serial = try serial(path: link.path, told: told)
        defer { serial.close() }
        #expect(await until { serial.state == .running })
        first.send("1\r\n")
        #expect(await collect(serial, count: 1) == ["1"])

        // 抜く。経路が消えてから、相手が閉じる (USB を抜いたときと同じ順)
        link.unplug()
        first.hangUp()
        #expect(await until { serial.state == .disconnected })
        // 開き直して開けなくても、抜かれたことを名乗り続ける (繋がっていない、には戻らない)
        #expect(await until { told.count(containing: "is not connected") == 1 })
        #expect(serial.state == .disconnected)

        // 挿し直す
        let second = try PseudoTerminal()
        try link.plug(into: second.path)
        #expect(await until { serial.state == .running })
        second.send("2\r\n")
        #expect(await collect(serial, count: 1) == ["2"])
        #expect(told.count(containing: "is not connected") == 1)
    }

    @Test("行の途中で抜かれたら、残りは渡さずに読めなかった数に入れる")
    func partialLineAtUnplugIsCounted() async throws {
        let told = Told()
        let device = try PipeDevice()
        let serial = try serial(path: "/dev/cu.pipe", told: told, opener: device.opener)
        defer { serial.close() }
        #expect(await until { serial.state == .running })

        device.send("1023\r\n10")
        device.closeWriter()
        #expect(await until { serial.state == .disconnected })
        #expect(await collect(serial, count: 1) == ["1023"])
        #expect(await until { serial.input.unreadable == 1 })
        serial.supply()
        #expect(serial.lines.isEmpty)
    }

    @Test("繋がっていないポートは unavailable を名乗って 1 度だけ知らせ、挿されたら受け始める")
    func absentPortStartsWhenPlugged() async throws {
        let told = Told()
        let link = try PortLink()
        let serial = try serial(path: link.path, told: told)
        defer { serial.close() }
        #expect(await until { told.count(containing: "is not connected") == 1 })
        #expect(serial.state == .unavailable)
        // 開き直しても、同じことは 2 度言わない
        try await Task.sleep(for: .milliseconds(200))
        #expect(told.count(containing: "The serial port \(link.path) is not connected") == 1)

        let terminal = try PseudoTerminal()
        try link.plug(into: terminal.path)
        #expect(await until { serial.state == .running })
        terminal.send("512\n")
        #expect(await collect(serial, count: 1) == ["512"])

        // 受け始めたら、また言えるように戻る
        link.unplug()
        terminal.hangUp()
        #expect(await until { told.count(containing: "is not connected") == 2 })
        #expect(serial.state == .disconnected)
    }

    @Test("他のアプリが使っているポートは unavailable を名乗って 1 度だけ知らせ、空けば受け始める")
    func busyPortStartsWhenFreed() async throws {
        let told = Told()
        let terminal = try PseudoTerminal()
        let attempts = Mutex(0)
        let held = Mutex(true)
        // 擬似端末では TIOCEXCL が効かない (2026-10-10 に実測) ので、使用中の答えは開く手が返す
        let opener: SerialDevice.Opener = { path, baudRate in
            attempts.withLock { $0 += 1 }
            return held.withLock { $0 } ? .failure(.busy) : SerialDevice.open(path, baudRate: baudRate)
        }
        let serial = try serial(path: terminal.path, told: told, opener: opener)
        defer { serial.close() }
        #expect(await until { attempts.withLock { $0 } >= 3 })
        #expect(serial.state == .unavailable)
        #expect(told.count(containing: "is in use by another app") == 1)

        held.withLock { $0 = false }
        #expect(await until { serial.state == .running })
        terminal.send("7\n")
        #expect(await collect(serial, count: 1) == ["7"])
    }

    @Test("機材がボーレートを受け付けなければ、1 度だけ知らせて開き直さない")
    func rejectedRateIsNotRetried() async throws {
        let told = Told()
        let attempts = Mutex(0)
        let opener: SerialDevice.Opener = { _, _ in
            attempts.withLock { $0 += 1 }
            return .failure(.rejectedRate(code: EINVAL))
        }
        let serial = try serial(path: "/dev/cu.usbmodem-test", told: told, opener: opener)
        defer { serial.close() }
        #expect(await until { told.count(containing: "does not accept 9600 baud") == 1 })
        try await Task.sleep(for: .milliseconds(200))
        #expect(attempts.withLock { $0 } == 1)
        #expect(serial.state == .unavailable)
    }

    // MARK: - 止める

    @Test("止めた後は何も届かず、state は stopped を名乗り、開き直さない")
    func stopEndsDelivery() async throws {
        let told = Told()
        let terminal = try PseudoTerminal()
        let attempts = Mutex(0)
        let opener: SerialDevice.Opener = { path, baudRate in
            attempts.withLock { $0 += 1 }
            return SerialDevice.open(path, baudRate: baudRate)
        }
        let serial = try serial(path: terminal.path, told: told, opener: opener)
        #expect(await until { serial.state == .running })
        terminal.send("1\n")
        #expect(await collect(serial, count: 1) == ["1"])

        serial.close()
        #expect(serial.state == .stopped)
        terminal.send("2\n")
        terminal.hangUp()
        try await Task.sleep(for: .milliseconds(200))
        serial.supply()
        #expect(serial.lines.isEmpty)
        #expect(serial.state == .stopped)
        #expect(attempts.withLock { $0 } == 1)
    }

    // MARK: - 作る口

    @Test("ボーレートが 1 より小さければ、作るときに投げる")
    func invalidBaudRateThrows() {
        let port = SerialPort(id: "/dev/cu.usbmodem14101", name: "Arduino Uno")
        #expect(throws: SerialFailure.invalidBaudRate(0)) { try IdleSketch().createSerial(port, baudRate: 0) }
        #expect(throws: SerialFailure.invalidBaudRate(-9600)) {
            try IdleSketch().createSerial(port, baudRate: -9600)
        }
        #expect("\(SerialFailure.invalidBaudRate(0))".contains("The baud rate 0 is not usable"))
    }

    @Test("open の errno を、繋がっていない・使用中・それ以外に読み替える")
    func openFailuresAreClassified() {
        #expect(SerialDevice.Failure(opening: ENOENT) == .absent)
        #expect(SerialDevice.Failure(opening: ENXIO) == .absent)
        #expect(SerialDevice.Failure(opening: EBUSY) == .busy)
        #expect(SerialDevice.Failure(opening: EACCES) == .failed(call: "open", code: EACCES))
        // ボーレートを受け付けないものは開き直さない (開くたびに Arduino がリセットされる)
        #expect(!SerialDevice.Failure.rejectedRate(code: EINVAL).retries)
        #expect(SerialDevice.Failure.busy.retries)
        #expect(SerialDevice.Failure.absent.retries)
    }

    @Test("無い経路を開く手は、繋がっていないと答える")
    func openingAMissingPathIsAbsent() {
        let path = "/dev/cu.mokume-missing-\(UUID().uuidString)"
        #expect(SerialDevice.open(path, baudRate: 9600) == .failure(.absent))
    }

    // MARK: - 一覧

    @Test("一覧は USB で繋いだものを先に、残りを後に並べ、どちらの組の中も識別子の順にする")
    func listPutsUSBFirst() {
        let entries = [
            IOSerialPorts.Entry(
                port: SerialPort(id: "/dev/cu.debug-console", name: "debug-console"), isUSB: false),
            IOSerialPorts.Entry(
                port: SerialPort(id: "/dev/cu.usbserial-A50285BI", name: "FT232R USB UART"), isUSB: true),
            IOSerialPorts.Entry(
                port: SerialPort(id: "/dev/cu.Bluetooth-Incoming-Port", name: "Bluetooth-Incoming-Port"),
                isUSB: false),
            IOSerialPorts.Entry(
                port: SerialPort(id: "/dev/cu.usbmodem14101", name: "Arduino Uno"), isUSB: true),
        ]
        #expect(
            SerialPort.ordered(entries).map(\.id) == [
                "/dev/cu.usbmodem14101", "/dev/cu.usbserial-A50285BI",
                "/dev/cu.Bluetooth-Incoming-Port", "/dev/cu.debug-console",
            ])
        #expect(SerialPort.ordered([]).isEmpty)
    }

    @Test("繋がっているポートの識別子は、どれもコールアウトの経路 (/dev/cu.*) で、重ならない")
    func connectedPortsUseCalloutPaths() {
        // 何が繋がっているかは機械による (CI の機械には 1 つも無いことがある)
        let ports = IdleSketch().serialPorts()
        #expect(ports.allSatisfy { $0.id.hasPrefix("/dev/cu.") && !$0.name.isEmpty })
        #expect(Set(ports.map(\.id)).count == ports.count)
    }
}
