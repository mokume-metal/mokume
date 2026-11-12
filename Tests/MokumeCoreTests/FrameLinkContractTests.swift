// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Darwin
import Foundation
import IOSurface
import MokumeTestSupport
import Testing

@testable import MokumeCore

/// 本体の中の最小の受け手 (`frame-receiver`) を子として起こす ([ADR-0049] 決定 7・[#3922])。
///
/// [ADR-0049]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0049-share-frames-to-other-processes.md
/// [#3922]: https://github.com/mokume-metal/mokume/issues/3922
nonisolated final class FrameReceiverProcess: @unchecked Sendable {
    /// 組んだ受け手の実行ファイル。検査の束の隣にある (`ReplayRecordProcess.executable` と同じ探し方)。
    static let executable: URL? = {
        final class Anchor {}
        var candidates = [Bundle(for: Anchor.self).bundleURL.deletingLastPathComponent()]
        candidates += Bundle.allBundles.filter { $0.bundleURL.pathExtension == "xctest" }
            .map { $0.bundleURL.deletingLastPathComponent() }
        for directory in candidates {
            let url = directory.appendingPathComponent("frame-receiver")
            if FileManager.default.isExecutableFile(atPath: url.path) { return url }
        }
        return nil
    }()

    let process = Process()
    private let input = Pipe()
    private let output = Pipe()
    private let lock = NSLock()
    private var buffer = Data()
    private var collected: [[String: Any]] = []

    init(arguments: [String]) throws {
        process.executableURL = try #require(Self.executable)
        process.arguments = arguments
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        // 終わった受け手へ 1 行書いても、検査のプロセスを SIGPIPE で落とさない (書けなかったことは `try?` で捨てる)
        _ = fcntl(input.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            self?.take(handle.availableData)
        }
        try process.run()
    }

    private func take(_ data: Data) {
        lock.lock()
        defer { lock.unlock() }
        buffer += data
        while let newline = buffer.firstIndex(of: 0x0A) {
            let line = buffer[buffer.startIndex..<newline]
            buffer = Data(buffer[buffer.index(after: newline)...])
            if let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any] {
                collected.append(object)
            }
        }
    }

    /// これまでに出た出来事。
    var events: [[String: Any]] {
        lock.lock()
        defer { lock.unlock() }
        return collected
    }

    func events(named name: String) -> [[String: Any]] {
        events.filter { $0["event"] as? String == name }
    }

    /// 受け手に終わるよう言う (標準入力に 1 行)。
    func stop() {
        try? input.fileHandleForWriting.write(contentsOf: Data("stop\n".utf8))
    }

    /// 待ち行列を詰めて止まっている受け手 (`--clog-attempt`) に、読み始めるよう言う。
    func resume() {
        try? input.fileHandleForWriting.write(contentsOf: Data("resume\n".utf8))
    }

    /// 条件が立つまで待つ。**期限で諦める** (`body` は待つ間に回す仕事)。
    @MainActor @discardableResult
    func wait(upTo seconds: Double, doing body: () -> Void = {}, until condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            body()
            if condition() { return true }
            usleep(2_000)
        }
        return condition()
    }

    deinit {
        output.fileHandleForReading.readabilityHandler = nil
        if process.isRunning { kill(process.processIdentifier, SIGKILL) }
    }
}

/// 名乗り・目録・引く・繋ぐ・どちらかが消えたら相手が知る。**GPU を使わない** — hosted の runner でも走る
/// (GPU の要る段は ``FrameLinkContractGPUTests``)。
@Suite(
    "約束: 別のプロセスの受け手と名乗り・繋ぎ・別れを往復する",
    .serialized,
    .enabled(if: FrameReceiverProcess.executable != nil, "組んだ frame-receiver が要る")
)
@MainActor
struct FrameLinkContractTests {
    private func announce(in directory: URL) throws -> FrameAnnouncement {
        try #require(
            FrameAnnouncement.announce(
                sketch: "Contract", identity: "/work/Contract", title: "Contract", in: directory,
                warn: { Issue.record("名乗れなかった: \($0)") }))
    }

    /// 名乗りの port に届いた connect を 1 通受ける (期限つき)。
    private func receiveConnect(on port: mach_port_t) -> FrameLink.Received? {
        let deadline = Date().addingTimeInterval(20)
        while Date() < deadline {
            if let received = FrameLink.receive(on: port, timeout: 100),
                received.kind == FrameLink.Kind.connect.rawValue
            {
                return received
            }
        }
        return nil
    }

    @Test("名乗ると目録に載り、別のプロセスの受け手が名前を引いて繋ぎ、名乗りを下ろすと受け手が dead-name で知る")
    func theReceiverLearnsTheSenderWentAway() throws {
        let directory = try TestScratch.directory("mokume-frames")
        // 1. 名乗る
        let announcement = try announce(in: directory)
        // 2. 一覧に出る
        #expect(FrameListing.entries(in: directory) == [announcement.entry])

        // 3. 別のプロセスが名前を引いて繋ぐ
        let receiver = try FrameReceiverProcess(arguments: [
            "--service", announcement.entry.serviceName, "--width", "16", "--height", "8", "--name", "contract",
        ])
        let connect = try #require(receiveConnect(on: announcement.receivePort), "繋ぐ 1 通が届かない")
        #expect(connect.ports.count == 1 + 3, "受け手の port と面 3 枚が届いていない")
        var reader = connect.payload.reader
        #expect(reader.uint32() == FrameLink.version)
        #expect(reader.string(limit: FrameLink.nameLimit) == "contract")
        for name in connect.ports { FrameLink.releaseName(name) }

        // 6. 送り手が消えると、受け手が dead-name で知る
        announcement.withdraw()
        let told = receiver.wait(upTo: 20) { !receiver.events(named: "senderGone").isEmpty }
        #expect(told, "受け手が送り手の消えたことを知らない: \(receiver.events)")
        #expect(receiver.events(named: "lookupFailed").isEmpty)
    }

    @Test("受け手のプロセスが終わると、送り手が頼んだ dead-name の知らせが届く")
    func theSenderLearnsTheReceiverWentAway() throws {
        let directory = try TestScratch.directory("mokume-frames")
        let announcement = try announce(in: directory)
        defer { announcement.withdraw() }
        let receiver = try FrameReceiverProcess(arguments: [
            "--service", announcement.entry.serviceName, "--width", "16", "--height", "8",
        ])
        let connect = try #require(receiveConnect(on: announcement.receivePort), "繋ぐ 1 通が届かない")
        let reply = try #require(connect.ports.first)
        for name in connect.ports.dropFirst() { FrameLink.releaseName(name) }
        defer { FrameLink.releaseName(reply) }
        var previous: mach_port_t = 0
        #expect(
            mach_port_request_notification(
                mach_task_self_, reply, MACH_NOTIFY_DEAD_NAME, 0, announcement.receivePort,
                mach_msg_type_name_t(MACH_MSG_TYPE_MAKE_SEND_ONCE), &previous) == KERN_SUCCESS)

        // 7. 受け手が終わる
        receiver.stop()
        var dead: mach_port_t?
        let deadline = Date().addingTimeInterval(20)
        while dead == nil, Date() < deadline {
            if let received = FrameLink.receive(on: announcement.receivePort, timeout: 100),
                received.kind == FrameLink.deadNameID
            {
                dead = FrameLink.deadName(in: received)
            }
        }
        #expect(dead == reply, "受け手が終わったことが送り手に届かない")
    }

    /// 目録の 1 件は約束 (`Schemas/frame-listing.schema.json`) の形で書く。鍵を足す・改名するなら Schema と版を同じ PR で直す。
    @Test("目録の 1 件の鍵は、Schema の properties と required にそろう")
    func theEntryMatchesTheSchema() throws {
        let schemaURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Schemas/frame-listing.schema.json")
        let schema = try #require(
            try JSONSerialization.jsonObject(with: Data(contentsOf: schemaURL)) as? [String: Any])
        let properties = Set((schema["properties"] as? [String: Any] ?? [:]).keys)
        let required = Set(schema["required"] as? [String] ?? [])
        var entry = FrameListing.Entry(
            sketch: "S", identity: "/s", title: "S", pid: 1, startedAt: 1, serviceName: "org.mokume.frames.1.ab.main")
        // 大きさの無い項目 (旧い送り手と同じ形) は、必須の鍵だけを書く
        let unsized = try #require(
            try JSONSerialization.jsonObject(with: JSONEncoder().encode(entry)) as? [String: Any])
        #expect(Set(unsized.keys) == required)
        // 大きさは任意の欄で、揃って書く (#3949)
        entry.width = 173
        entry.height = 97
        let written = try #require(
            try JSONSerialization.jsonObject(with: JSONEncoder().encode(entry)) as? [String: Any])
        #expect(Set(written.keys) == properties)
        #expect(properties.subtracting(required) == ["width", "height"])
        let together = schema["dependentRequired"] as? [String: [String]]
        #expect(together?["width"] == ["height"] && together?["height"] == ["width"], "幅と高さを揃える定めが無い")
        let version = (schema["properties"] as? [String: Any])?["schemaVersion"] as? [String: Any]
        #expect(version?["const"] as? Int == FrameListing.schemaVersion)
        #expect(Int(FrameLink.version) == FrameListing.schemaVersion, "目録と手順の版がずれた")
    }

    // MARK: - 目録の大きさ (#3949)

    /// 旧い送り手の項目を置く (大きさの鍵を持たない)。名前は本物の名乗りのもの。
    private func placeOlderEntry(of announcement: FrameAnnouncement, in directory: URL) throws -> URL {
        var older = announcement.entry
        older.width = nil
        older.height = nil
        try FrameListing.place(older, in: directory)
        let file = FrameListing.url(for: older.serviceName, in: directory)
        let written = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        try #require(written["width"] == nil, "検査の前提: 旧い形の項目になっていない")
        return file
    }

    /// **新しい受け手 × 旧い送り手** ([#3949])。大きさの無い項目も v1 として読み、知っている大きさが無ければ、推し量らずに
    /// 利用者へ大きさの指定を頼む。
    ///
    /// [#3949]: https://github.com/mokume-metal/mokume/issues/3949
    @Test("大きさの無い旧い項目を読んだ受け手は、知っている大きさが無ければ繋がずに大きさの指定を頼む")
    func aReceiverAsksForTheSizeAnOlderSenderDidNotList() throws {
        let directory = try TestScratch.directory("mokume-frames")
        let announcement = try announce(in: directory)
        defer { announcement.withdraw() }
        let file = try placeOlderEntry(of: announcement, in: directory)
        let receiver = try FrameReceiverProcess(arguments: ["--listing", file.path, "--timeout", "5"])
        let ended = receiver.wait(upTo: 20) { !receiver.process.isRunning }
        #expect(ended, "受け手が終わらない: \(receiver.events)")
        let unknown = try #require(receiver.events(named: "sizeUnknown").first, "\(receiver.events)")
        let message = unknown["message"] as? String ?? ""
        #expect(message.contains("no width and height") && message.contains("--width"), "\(message)")
        #expect(receiver.process.terminationStatus == 6)
        #expect(receiver.events(named: "listingUnreadable").isEmpty, "旧い項目を v1 として読めない")
        // 推し量って繋ぎに来ない
        #expect(FrameLink.receive(on: announcement.receivePort, timeout: 100) == nil, "大きさが分からないのに繋いだ")
    }

    /// **受け手の見本も、Schema が断る大きさを大きさとして受けない** ([#3949])。`JSONSerialization` の真偽値は `as? Int` で
    /// 1 と読めてしまう。どの値でも、大きさの無い項目と同じく指定を頼んで終わる (繋ぎに行かない)。
    ///
    /// [#3949]: https://github.com/mokume-metal/mokume/issues/3949
    @Test(
        "受け手の見本は、真偽値・小数・文字列・0・負の大きさを受けず、大きさの指定を頼む",
        arguments: ["true, \"height\": true", "2.5, \"height\": 8", "\"16\", \"height\": 8", "0, \"height\": 8", "16, \"height\": -1"])
    func theReceiverRefusesSizesTheSchemaRefuses(_ size: String) throws {
        let directory = try TestScratch.directory("mokume-frames")
        let file = directory.appendingPathComponent("org.mokume.frames.1.a.main.json")
        try Data(
            """
            {"schemaVersion": 1, "sketch": "S", "window": "main", "identity": "/s", "title": "S", "pid": 1,
             "startedAt": 1, "serviceName": "org.mokume.frames.1.a.main", "width": \(size)}
            """.utf8
        ).write(to: file)
        let receiver = try FrameReceiverProcess(arguments: ["--listing", file.path, "--timeout", "5"])
        let ended = receiver.wait(upTo: 20) { !receiver.process.isRunning }
        #expect(ended, "受け手が終わらない: \(receiver.events)")
        #expect(receiver.events(named: "size").isEmpty, "\(size) を大きさとして受けた: \(receiver.events)")
        #expect(!receiver.events(named: "sizeUnknown").isEmpty, "\(receiver.events)")
        #expect(receiver.process.terminationStatus == 6)
    }

    @Test("大きさの無い旧い項目でも、知っている大きさを渡せばその大きさの面で繋ぐ")
    func aReceiverUsesAKnownSizeForAnOlderSender() throws {
        let directory = try TestScratch.directory("mokume-frames")
        let announcement = try announce(in: directory)
        defer { announcement.withdraw() }
        let file = try placeOlderEntry(of: announcement, in: directory)
        let receiver = try FrameReceiverProcess(arguments: ["--listing", file.path, "--width", "16", "--height", "8"])
        defer { receiver.stop() }
        let connect = try #require(receiveConnect(on: announcement.receivePort), "繋ぐ 1 通が届かない")
        defer { for name in connect.ports { FrameLink.releaseName(name) } }
        let sizes = connect.ports.dropFirst().compactMap(IOSurfaceLookupFromMachPort).map {
            [IOSurfaceGetWidth($0), IOSurfaceGetHeight($0)]
        }
        #expect(sizes == Array(repeating: [16, 8], count: 3), "\(sizes)")
    }
}

/// 面を送り、番号と画素と属性が届き、受け手が去れば送り手が外す ([#3922])。GPU が要るので専用機で走る。
///
/// [#3922]: https://github.com/mokume-metal/mokume/issues/3922
@Suite(
    "約束: 別のプロセスの受け手へ絵を渡す",
    .serialized,
    .enabled(
        if: RenderDevice.isAvailable && FrameReceiverProcess.executable != nil,
        "この世代のコマンド構造に対応した GPU と、組んだ frame-receiver が要る")
)
@MainActor
struct FrameLinkContractGPUTests {
    @Test("受け手が 3 枚で繋ぐと、番号が 1 ずつ進み、画面と同じ値と属性が届き、受け手が去ると送り手が外す")
    func handsFramesToAnotherProcess() throws {
        let directory = try TestScratch.directory("mokume-frames")
        let gpu = try RenderDevice()
        let announcement = try #require(
            FrameAnnouncement.announce(
                sketch: "Contract", identity: "/work/Contract", title: "Contract", in: directory,
                warn: { Issue.record("名乗れなかった: \($0)") }))
        defer { announcement.withdraw() }
        let sender = try #require(announcement.startSending(gpu: gpu, width: 16, height: 8, startsListening: false))
        sender.warn = { _ in }
        let source = try RenderTarget(gpu: gpu, width: 16, height: 8)
        try source.fill(with: .linear(red: 2, green: 0.5, blue: 0.25))
        let presenter = try FramePresenter(gpu: gpu, pixelFormat: RenderTarget.pixelFormat)

        let receiver = try FrameReceiverProcess(arguments: [
            "--service", announcement.entry.serviceName, "--width", "16", "--height", "8", "--surfaces", "3",
            "--exit-after", "5",
        ])
        // 4. 面が届く (繋がる) まで待つ
        let connected = receiver.wait(upTo: 20, doing: { sender.drain() }) { sender.receiverCount == 1 }
        try #require(connected, "受け手が繋がらない: \(receiver.events)")

        // 5. 1 枚ずつ書いて、受け手が受けて返すのを待ってから次へ (番号が飛ばないよう歩調を合わせる)
        for frame in Int64(1)...5 {
            func deliver() throws {
                try sender.deliver(width: 16, height: 8, frameCount: frame, hostTime: UInt64(frame)) {
                    texture throws(RenderFailure) in
                    try presenter.draw(source, into: texture)
                }
            }
            try deliver()
            _ = gpu.droppedWork(after: 0, through: gpu.submissionCount)
            let delivered = receiver.wait(
                upTo: 20,
                doing: {
                    sender.drain()
                    try? deliver()  // 同じ番号は書かず、結末の届いた焼きを知らせる
                }
            ) { receiver.events(named: "frame").count >= Int(frame) }
            try #require(delivered, "\(frame) 枚目が届かない: \(receiver.events)")
        }
        let frames = receiver.events(named: "frame")
        #expect(frames.compactMap { ($0["frameCount"] as? NSNumber)?.int64Value } == [1, 2, 3, 4, 5])
        #expect(frames.compactMap { ($0["writes"] as? NSNumber)?.int64Value } == [1, 2, 3, 4, 5])

        let ordinary = try RenderTarget(gpu: gpu, width: 16, height: 8)
        try presenter.draw(source, into: ordinary.texture)
        let expected = try ordinary.readPixels()[8, 4]
        for frame in frames {
            let pixel = (frame["pixel"] as? [NSNumber])?.map(\.floatValue)
            #expect(pixel == [expected.red, expected.green, expected.blue, expected.alpha], "画素: \(frame)")
            let attributes = frame["attributes"] as? [String: Any] ?? [:]
            #expect(
                (attributes["frameCount"] as? NSNumber)?.int64Value
                    == (frame["frameCount"] as? NSNumber)?.int64Value, "面の属性に番号が無い: \(attributes)")
            #expect((attributes["frame"] as? NSNumber)?.int64Value == (frame["writes"] as? NSNumber)?.int64Value)
            #expect(attributes["hostTime"] is NSNumber)
            #expect(attributes["colorSpace"] as? String == "kCGColorSpaceExtendedLinearDisplayP3")
            #expect(attributes["alpha"] as? String == "premultiplied")
        }

        // 7. 受け手が去ると (5 枚で自分から終わる)、送り手が外す
        let removed = receiver.wait(upTo: 20, doing: { sender.drain() }) { sender.receiverCount == 0 }
        #expect(removed, "去った受け手を外していない")
    }

    /// **受け手が居ない間に作品の大きさが変わっても、目録を読んで繋いだ受け手は新しい大きさの面で 1 度で受け入れられる**
    /// ([#3946])。約束 (`Schemas/frame-link.md`) では、受け手は大きさを `accepted` で知り、合わなければ `surfaceSize` で断られる。
    ///
    /// [#3946]: https://github.com/mokume-metal/mokume/issues/3946
    @Test("受け手が居ない間に大きさが変わっても、別のプロセスの受け手は新しい大きさの面で 1 度で繋がり、絵を受ける")
    func aReceiverConnectsAtTheSizeChangedWhileNobodyListened() throws {
        let directory = try TestScratch.directory("mokume-frames")
        let gpu = try RenderDevice()
        let announcement = try #require(
            FrameAnnouncement.announce(
                sketch: "Contract", identity: "/work/Contract", title: "Contract", in: directory,
                warn: { Issue.record("名乗れなかった: \($0)") }))
        defer { announcement.withdraw() }
        let sender = try #require(announcement.startSending(gpu: gpu, width: 16, height: 8, startsListening: false))
        sender.warn = { _ in }
        let source = try RenderTarget(gpu: gpu, width: 32, height: 8)
        try source.fill(with: .linear(red: 2, green: 0.5, blue: 0.25))
        let presenter = try FramePresenter(gpu: gpu, pixelFormat: RenderTarget.pixelFormat)
        var frame: Int64 = 0
        func deliver() throws {
            try sender.deliver(width: 32, height: 8, frameCount: frame, hostTime: UInt64(frame)) {
                texture throws(RenderFailure) in
                try presenter.draw(source, into: texture)
            }
            _ = gpu.droppedWork(after: 0, through: gpu.submissionCount)
        }
        // 受け手が居ない間に 16×8 → 32×8
        for _ in 0..<3 {
            frame += 1
            try deliver()
        }

        let receiver = try FrameReceiverProcess(arguments: [
            "--service", announcement.entry.serviceName, "--width", "32", "--height", "8", "--surfaces", "3",
            "--exit-after", "2",
        ])
        let received = receiver.wait(
            upTo: 20,
            doing: {
                sender.drain()
                frame += 1
                try? deliver()
            }
        ) { receiver.events(named: "frame").count >= 2 || !receiver.events(named: "refused").isEmpty }
        #expect(receiver.events(named: "refused").isEmpty, "新しい大きさの面を断った: \(receiver.events)")
        #expect(receiver.events(named: "accepted").first?["width"] as? Int == 32, "\(receiver.events)")
        #expect(received, "絵が届かない: \(receiver.events)")
        _ = receiver.wait(upTo: 20, doing: { sender.drain() }) { sender.receiverCount == 0 }
    }

    // MARK: - 目録の大きさで繋ぐ (#3949)

    /// 名乗り、受け付ける大きさで送り手を起こす (受け手の頼みは検査が ``FrameSender/drain()`` で捌く)。
    private func startSender(
        in directory: URL, gpu: RenderDevice, width: Int, height: Int
    ) throws -> (FrameAnnouncement, FrameSender) {
        let announcement = try #require(
            FrameAnnouncement.announce(
                sketch: "Contract", identity: "/work/Contract", title: "Contract", in: directory,
                warn: { Issue.record("名乗れなかった: \($0)") }))
        let sender = try #require(
            announcement.startSending(gpu: gpu, width: width, height: height, startsListening: false))
        sender.warn = { _ in }
        return (announcement, sender)
    }

    /// 頼みを捌きながら、送り手のいまの大きさで絵を書き続け、受け手が `frames` 枚受けるか終わるまで待つ (期限つき)。
    private func feed(
        _ receiver: FrameReceiverProcess, sender: FrameSender, gpu: RenderDevice, frames: Int
    ) throws -> Bool {
        let presenter = try FramePresenter(gpu: gpu, pixelFormat: RenderTarget.pixelFormat)
        var source = try RenderTarget(gpu: gpu, width: sender.width, height: sender.height)
        var frame: Int64 = 0
        return receiver.wait(
            upTo: 20,
            doing: {
                sender.drain()
                frame += 1
                if source.width != sender.width || source.height != sender.height,
                    let resized = try? RenderTarget(gpu: gpu, width: sender.width, height: sender.height)
                {
                    source = resized
                }
                try? sender.deliver(
                    width: source.width, height: source.height, frameCount: frame, hostTime: UInt64(frame)
                ) { texture throws(RenderFailure) in try presenter.draw(source, into: texture) }
                _ = gpu.droppedWork(after: 0, through: gpu.submissionCount)
            }
        ) { receiver.events(named: "frame").count >= frames || !receiver.process.isRunning }
    }

    private func size(_ event: [String: Any]?) -> [Int?]? {
        event.map { [$0["width"] as? Int, $0["height"] as? Int] }
    }

    /// **初めて繋ぐ受け手は、目録だけで正しい大きさの面を用意できる** ([#3949])。作品を知らない受け手に、大きさを
    /// 渡さない。
    ///
    /// [#3949]: https://github.com/mokume-metal/mokume/issues/3949
    @Test("173×97 の作品を知らない受け手が、目録だけで 173×97 の面を用意して 1 度で繋がり、絵を受ける")
    func aFirstReceiverSizesItsSurfacesFromTheListing() throws {
        let directory = try TestScratch.directory("mokume-frames")
        let gpu = try RenderDevice()
        let (announcement, sender) = try startSender(in: directory, gpu: gpu, width: 173, height: 97)
        defer { announcement.withdraw() }
        let file = FrameListing.url(for: announcement.entry.serviceName, in: directory)
        let receiver = try FrameReceiverProcess(arguments: ["--listing", file.path, "--exit-after", "2"])
        let received = try feed(receiver, sender: sender, gpu: gpu, frames: 2)
        #expect(received && receiver.events(named: "frame").count >= 2, "絵が届かない: \(receiver.events)")
        #expect(size(receiver.events(named: "size").first) == [173, 97], "\(receiver.events)")
        #expect(receiver.events(named: "refused").isEmpty, "1 度で繋がらなかった: \(receiver.events)")
        #expect(size(receiver.events(named: "accepted").first) == [173, 97], "\(receiver.events)")
        _ = receiver.wait(upTo: 20, doing: { sender.drain() }) { sender.receiverCount == 0 }
    }

    /// **目録を読んでから繋ぐまでに大きさが変わったら、断られた受け手は目録を読み直して繋ぎ直す** ([#3949])。送り手は
    /// 断るより前に目録の大きさを書き換える。
    ///
    /// [#3949]: https://github.com/mokume-metal/mokume/issues/3949
    @Test("173×97 を読んだ後、繋ぐ前に 211×103 へ変わると、断られた受け手は目録を読み直して 211×103 で繋ぎ直し、絵を受ける")
    func aReceiverRereadsTheListingAfterASizeRefusal() throws {
        let directory = try TestScratch.directory("mokume-frames")
        let gpu = try RenderDevice()
        let (announcement, sender) = try startSender(in: directory, gpu: gpu, width: 173, height: 97)
        defer { announcement.withdraw() }
        let file = FrameListing.url(for: announcement.entry.serviceName, in: directory)
        let receiver = try FrameReceiverProcess(arguments: ["--listing", file.path, "--exit-after", "2"])
        // 受け手が 173×97 で connect を送るまで、頼みは捌かない
        let sent = receiver.wait(upTo: 20) { !receiver.events(named: "connected").isEmpty }
        try #require(sent, "受け手が繋ぎに来ない: \(receiver.events)")
        #expect(size(receiver.events(named: "size").first) == [173, 97], "\(receiver.events)")
        // 繋ぐ頼みを捌く前に、作品が 211×103 になる (受け手 0 なので、覚えて目録を書き換えるだけ)
        sender.resize(width: 211, height: 103)
        #expect(FrameListing.entries(in: directory).map { [$0.width, $0.height] } == [[211, 103]])

        let received = try feed(receiver, sender: sender, gpu: gpu, frames: 2)
        #expect(received && receiver.events(named: "frame").count >= 2, "絵が届かない: \(receiver.events)")
        #expect(receiver.events(named: "refused").map { $0["reason"] as? Int } == [4], "\(receiver.events)")
        #expect(size(receiver.events(named: "reread").first) == [211, 103], "\(receiver.events)")
        #expect(size(receiver.events(named: "accepted").first) == [211, 103], "\(receiver.events)")
        _ = receiver.wait(upTo: 20, doing: { sender.drain() }) { sender.receiverCount == 0 }
    }

    /// **旧い受け手 × 新しい送り手** ([#3949])。目録の版も connect の版も 1 のまま。知らない欄を読み飛ばす従来の受け手が、
    /// 知っている大きさで繋いで絵を受ける。
    ///
    /// [#3949]: https://github.com/mokume-metal/mokume/issues/3949
    @Test("知らない欄を読み飛ばす従来の受け手は、大きさの載った項目を v1 として読み、知っている大きさで繋いで絵を受ける")
    func anOlderReceiverIgnoresTheSize() throws {
        let directory = try TestScratch.directory("mokume-frames")
        let gpu = try RenderDevice()
        let (announcement, sender) = try startSender(in: directory, gpu: gpu, width: 173, height: 97)
        defer { announcement.withdraw() }
        // 従来の受け手の読み方: 大きさの欄を知らない型で読む (知らない鍵は読み飛ばす)
        struct OlderEntry: Decodable {
            let schemaVersion: Int
            let sketch, window, identity, title: String
            let pid: Int32
            let startedAt: Int64
            let serviceName: String
        }
        let data = try Data(contentsOf: FrameListing.url(for: announcement.entry.serviceName, in: directory))
        let written = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        try #require(written["width"] as? Int == 173, "検査の前提: 大きさが載っていない")
        let older = try JSONDecoder().decode(OlderEntry.self, from: data)
        #expect(older.schemaVersion == 1)
        #expect(FrameLink.version == 1)

        // 従来の形 (`--service`) の受け手は、目録の大きさを読まない
        let receiver = try FrameReceiverProcess(arguments: [
            "--service", older.serviceName, "--width", "173", "--height", "97", "--exit-after", "2",
        ])
        let received = try feed(receiver, sender: sender, gpu: gpu, frames: 2)
        #expect(received && receiver.events(named: "frame").count >= 2, "絵が届かない: \(receiver.events)")
        #expect(receiver.events(named: "refused").isEmpty, "\(receiver.events)")
        _ = receiver.wait(upTo: 20, doing: { sender.drain() }) { sender.receiverCount == 0 }
    }

    /// **新しい受け手 × 旧い送り手** ([#3949])。大きさの無い項目でも、知っている大きさで繋いで絵を受ける。
    ///
    /// [#3949]: https://github.com/mokume-metal/mokume/issues/3949
    @Test("大きさの無い旧い送り手の項目でも、新しい受け手は知っている大きさで繋いで絵を受ける")
    func aCurrentReceiverReachesAnOlderSender() throws {
        let directory = try TestScratch.directory("mokume-frames")
        let gpu = try RenderDevice()
        let (announcement, sender) = try startSender(in: directory, gpu: gpu, width: 16, height: 8)
        defer { announcement.withdraw() }
        var older = announcement.entry
        older.width = nil
        older.height = nil
        try FrameListing.place(older, in: directory)
        let file = FrameListing.url(for: older.serviceName, in: directory)
        let receiver = try FrameReceiverProcess(arguments: [
            "--listing", file.path, "--width", "16", "--height", "8", "--exit-after", "2",
        ])
        let received = try feed(receiver, sender: sender, gpu: gpu, frames: 2)
        #expect(received && receiver.events(named: "frame").count >= 2, "絵が届かない: \(receiver.events)")
        #expect(receiver.events(named: "sizeUnknown").isEmpty, "\(receiver.events)")
        _ = receiver.wait(upTo: 20, doing: { sender.drain() }) { sender.receiverCount == 0 }
    }

    // MARK: - 落ちた答えから立ち直る (#3968)

    /// 同じプロセスで繋いで枠を埋めるだけの受け手。面は返さない (送り手は書かずに見送る)。
    private final class Occupant {
        let port: mach_port_t
        let surfaces: [IOSurfaceRef]

        init(service: mach_port_t, width: Int, height: Int) throws {
            var port: mach_port_t = 0
            mach_port_allocate(mach_task_self_, MACH_PORT_RIGHT_RECEIVE, &port)
            self.port = port
            surfaces = (0..<2).compactMap { _ in
                IOSurfaceCreate(
                    [
                        kIOSurfaceWidth: width, kIOSurfaceHeight: height,
                        kIOSurfacePixelFormat: FrameLink.surfaceFormat, kIOSurfaceBytesPerElement: 8,
                    ] as [CFString: Any] as CFDictionary)
            }
            try #require(FrameLink.connect(to: service, reply: port, surfaces: surfaces) == KERN_SUCCESS)
        }

        deinit { mach_port_mod_refs(mach_task_self_, port, MACH_PORT_RIGHT_RECEIVE, -1) }
    }

    /// 送り手の枠を 1 つ残して埋める (上限は 4)。**残る 1 枠を古い繋がりが握ったままなら、繋ぎ直しは `receiverLimit` で
    /// 断られる** — 立ち直りが古い枠を回収したことを、繋がれたことで確かめる。
    private func occupyAllButOne(of announcement: FrameAnnouncement, sender: FrameSender) throws -> [Occupant] {
        let service = try #require(Bootstrap.lookUp(announcement.entry.serviceName))
        defer { Bootstrap.releaseSend(service) }
        // 1 通ずつ捌く (送り手の待ち行列は短い)
        let occupants = try (0..<(FrameLink.receiverLimit - 1)).map { _ in
            defer { sender.drain() }
            return try Occupant(service: service, width: sender.width, height: sender.height)
        }
        try #require(sender.receiverCount == FrameLink.receiverLimit - 1, "検査の前提: 枠を埋められない")
        return occupants
    }

    /// 新しい繋がり: 最後の時間切れより後の `accepted` と、それに続くその番号の最初の `frame`。
    private func newConnection(in events: [[String: Any]]) -> (accepted: Int, receiver: Int, frame: Int)? {
        guard let timedOut = events.lastIndex(where: { $0["event"] as? String == "answerTimedOut" }),
            let accepted = events[timedOut...].firstIndex(where: { $0["event"] as? String == "accepted" }),
            let receiver = events[accepted]["receiver"] as? Int,
            let frame = events[accepted...].firstIndex(where: {
                $0["event"] as? String == "frame" && $0["receiver"] as? Int == receiver
            })
        else { return nil }
        return (accepted, receiver, frame)
    }

    /// 送り手を回し (頼みを捌き、送り手のいまの大きさで絵を書く)、`until` が立つか受け手が終わるまで待つ (期限つき)。
    /// connect を送って止まった受け手 (`paused`) には、送り手が答えた (詰めた待ち行列なら落とした) 後で読み始めさせる。
    private func drive(
        _ receiver: FrameReceiverProcess, sender: FrameSender, gpu: RenderDevice,
        until condition: () -> Bool
    ) throws -> Bool {
        let presenter = try FramePresenter(gpu: gpu, pixelFormat: RenderTarget.pixelFormat)
        var source = try RenderTarget(gpu: gpu, width: sender.width, height: sender.height)
        try source.fill(with: .linear(red: 1, green: 0, blue: 0))
        var frame: Int64 = 0
        var resumed = 0
        return receiver.wait(
            upTo: 30,
            doing: {
                sender.drain()
                // 止まった受け手の connect は、connected を言う前に送られている。捌いてから読ませる
                let paused = receiver.events(named: "connected").filter { $0["paused"] as? Bool == true }.count
                if paused > resumed {
                    sender.drain()
                    resumed = paused
                    receiver.resume()
                }
                if source.width != sender.width || source.height != sender.height,
                    let resized = try? RenderTarget(gpu: gpu, width: sender.width, height: sender.height)
                {
                    try? resized.fill(with: .linear(red: 1, green: 0, blue: 0))
                    source = resized
                }
                frame += 1
                try? sender.deliver(
                    width: source.width, height: source.height, frameCount: frame, hostTime: UInt64(frame)
                ) { texture throws(RenderFailure) in try presenter.draw(source, into: texture) }
                _ = gpu.droppedWork(after: 0, through: gpu.submissionCount)
            }
        ) { condition() || !receiver.process.isRunning }
    }

    /// 新しい繋がりの最初の `frame` が届くか、受け手が終わるまで回す。
    private func driveRecovery(
        _ receiver: FrameReceiverProcess, sender: FrameSender, gpu: RenderDevice
    ) throws -> Bool {
        try drive(receiver, sender: sender, gpu: gpu) { newConnection(in: receiver.events) != nil }
    }

    private func attempts(_ receiver: FrameReceiverProcess, _ event: String) -> [Int] {
        receiver.events(named: event).compactMap { $0["attempt"] as? Int }
    }

    /// **送り手を止めて**、受け手が送り手の消えたことを知るまで待つ (期限つき)。立ち直った後の port にも、送り手が消えた
    /// 知らせを頼み直していること。
    private func expectTheReceiverLearnsTheSenderWentAway(
        _ receiver: FrameReceiverProcess, announcement: FrameAnnouncement
    ) {
        announcement.withdraw()
        let told = receiver.wait(upTo: 20) { !receiver.events(named: "senderGone").isEmpty }
        #expect(told, "立ち直った受け手が送り手の消えたことを知らない: \(receiver.events)")
    }

    /// **初めての `accepted` が落ちたら、受け手は自分の番号を知らない** ([#3968])。期限で受信の port を作り直して繋ぎ直す。
    /// 送り手は古い port の dead-name で古い枠を回収する。
    ///
    /// [#3968]: https://github.com/mokume-metal/mokume/issues/3968
    @Test("初めての accepted が満杯の待ち行列で落ちても、受け手は期限で port を作り直して繋ぎ直し、古い枠が空いて新しい繋がりの最初の絵を受ける")
    func aReceiverRecoversALostFirstAcceptance() throws {
        let directory = try TestScratch.directory("mokume-frames")
        let gpu = try RenderDevice()
        let (announcement, sender) = try startSender(in: directory, gpu: gpu, width: 16, height: 8)
        defer { announcement.withdraw() }
        let occupants = try occupyAllButOne(of: announcement, sender: sender)
        defer { withExtendedLifetime(occupants) {} }
        var said: [String] = []
        sender.warn = { said.append($0) }

        let receiver = try FrameReceiverProcess(arguments: [
            "--service", announcement.entry.serviceName, "--width", "16", "--height", "8",
            "--clog-attempt", "1", "--answer-timeout", "0.5",
        ])
        defer { receiver.stop() }
        let recovered = try driveRecovery(receiver, sender: sender, gpu: gpu)
        let events = receiver.events
        #expect(recovered, "新しい繋がりの絵が届かない: \(events)")
        #expect(
            receiver.events(named: "answerTimedOut").first?["known"] as? Bool == false,
            "番号を知らない時間切れとして扱っていない: \(events)")
        #expect(receiver.events(named: "accepted").count == 1, "落としたはずの accepted が届いた (検査の前提): \(events)")
        #expect(receiver.events(named: "refused").isEmpty, "古い枠が回収されず断られた: \(events)")
        #expect(sender.receiverCount == FrameLink.receiverLimit, "古い枠を回収していない (\(sender.receiverCount))")
        #expect(said.filter { $0.hasPrefix("Stopped handing") }.count == 1, "送り手が古い繋がりを外していない: \(said)")
        expectTheReceiverLearnsTheSenderWentAway(receiver, announcement: announcement)
    }

    /// **番号を知っている受け手の繋ぎ直しの `accepted` が落ちたら、期限でその番号を `disconnect` し、port を作り直して
    /// 繋ぎ直す** ([#3968])。古い面へ書かれた `frame` は成功に数えない。
    ///
    /// [#3968]: https://github.com/mokume-metal/mokume/issues/3968
    @Test("繋ぎ直しの accepted が満杯の待ち行列で落ちても、受け手は期限で disconnect して繋ぎ直し、古い枠が空いて新しい繋がりの最初の絵を受ける")
    func aReceiverRecoversALostReacceptance() throws {
        let directory = try TestScratch.directory("mokume-frames")
        let gpu = try RenderDevice()
        let (announcement, sender) = try startSender(in: directory, gpu: gpu, width: 16, height: 8)
        defer { announcement.withdraw() }
        let occupants = try occupyAllButOne(of: announcement, sender: sender)
        defer { withExtendedLifetime(occupants) {} }
        var said: [String] = []
        sender.warn = { said.append($0) }

        let receiver = try FrameReceiverProcess(arguments: [
            "--service", announcement.entry.serviceName, "--width", "16", "--height", "8",
            "--reconnect-after", "1", "--clog-attempt", "2", "--answer-timeout", "0.5",
        ])
        defer { receiver.stop() }
        let recovered = try driveRecovery(receiver, sender: sender, gpu: gpu)
        let events = receiver.events
        #expect(recovered, "新しい繋がりの絵が届かない: \(events)")
        let first = try #require(receiver.events(named: "accepted").first?["receiver"] as? Int, "\(events)")
        let timedOut = receiver.events(named: "answerTimedOut").first
        #expect(timedOut?["known"] as? Bool == true && timedOut?["receiver"] as? Int == first, "\(events)")
        let new = try #require(newConnection(in: events))
        #expect(new.receiver != first, "disconnect せずに繋ぎ直した (番号が同じ): \(events)")
        // 詰めた connect から新しい accepted までの間に、frame を数えていない (古い面への書き込み)
        let clogged = try #require(events.firstIndex { ($0["clogged"] as? Int ?? 0) > 0 })
        #expect(
            !events[clogged..<new.accepted].contains { $0["event"] as? String == "frame" },
            "答えを待つ間の frame を数えた: \(events)")
        // 送り手は落ちた accepted の後も新しい面へ書いて frame を送る。受け手はそれを、期限の前に読んで数えずにいる
        // (読む前に期限が来ていたら、この判定は試されていない)
        let timedOutAt = try #require(events.firstIndex { $0["event"] as? String == "answerTimedOut" })
        #expect(
            events[clogged..<timedOutAt].contains { $0["event"] as? String == "frameWhileWaiting" },
            "答えを待つ間に frame を読んでいない (検査の前提): \(events)")
        #expect(receiver.events(named: "refused").isEmpty, "\(events)")
        #expect(sender.receiverCount == FrameLink.receiverLimit, "古い枠を回収していない (\(sender.receiverCount))")
        #expect(said.filter { $0.hasPrefix("Stopped handing") }.count == 1, "送り手が古い繋がりを外していない: \(said)")
    }

    // MARK: - 遅れた答え (#3968)

    /// **答えは落ちずに遅れることもある** ([#3968])。番号を知らない受け手が期限で port を作り直した後に、送り手が古い
    /// connect を読む。その返信先は死んでいるので、送り手は登録しない — 登録すると枠が 1 つ戻らず、新しい connect が
    /// `receiverLimit` で断られる。立ち直った port にも、送り手が消えた知らせを頼み直している。
    ///
    /// [#3968]: https://github.com/mokume-metal/mokume/issues/3968
    @Test("初めての答えが遅れて受け手が port を作り直すと、送り手は死んだ返信先の connect を登録せず、新しい繋がりが最後の枠を取って絵を受ける")
    func aReceiverRecoversALateFirstAnswer() throws {
        let directory = try TestScratch.directory("mokume-frames")
        let gpu = try RenderDevice()
        let (announcement, sender) = try startSender(in: directory, gpu: gpu, width: 16, height: 8)
        defer { announcement.withdraw() }
        let occupants = try occupyAllButOne(of: announcement, sender: sender)
        defer { withExtendedLifetime(occupants) {} }
        var said: [String] = []
        sender.warn = { said.append($0) }

        let receiver = try FrameReceiverProcess(arguments: [
            "--service", announcement.entry.serviceName, "--width", "16", "--height", "8", "--answer-timeout", "0.5",
        ])
        defer { receiver.stop() }
        // 送り手は忙しい: 受け手が期限で port を作り直し、2 通目を送るまで、頼みを捌かない
        let gaveUpWaiting = receiver.wait(upTo: 20) { attempts(receiver, "connected").contains(2) }
        try #require(gaveUpWaiting, "受け手が期限で繋ぎ直さない: \(receiver.events)")
        try #require(sender.receiverCount == FrameLink.receiverLimit - 1, "検査の前提: 送り手が先に捌いた")

        let recovered = try driveRecovery(receiver, sender: sender, gpu: gpu)
        let events = receiver.events
        #expect(recovered, "新しい繋がりの絵が届かない: \(events)")
        #expect(receiver.events(named: "answerTimedOut").first?["known"] as? Bool == false, "\(events)")
        #expect(receiver.events(named: "refused").isEmpty, "死んだ返信先の connect が枠を取った: \(events)")
        #expect(receiver.events(named: "accepted").count == 1, "\(events)")
        #expect(sender.receiverCount == FrameLink.receiverLimit, "(\(sender.receiverCount))")
        #expect(said.filter { $0.hasPrefix("Handing") }.count == 1, "死んだ返信先を受け入れた: \(said)")
        expectTheReceiverLearnsTheSenderWentAway(receiver, announcement: announcement)
    }

    /// **番号を知っている受け手の答えが遅れても、遅れた答えは新しい繋がりに混ざらない** ([#3968])。受け手は期限で
    /// `disconnect` して port を作り直すので、送り手が後で古い connect に答えても、その `accepted` (前の番号) は届かない。
    ///
    /// [#3968]: https://github.com/mokume-metal/mokume/issues/3968
    @Test("繋ぎ直しの答えが遅れると、受け手は disconnect して port を作り直し、遅れた accepted を受けずに新しい番号で絵を受ける")
    func aReceiverRecoversALateReacceptance() throws {
        let directory = try TestScratch.directory("mokume-frames")
        let gpu = try RenderDevice()
        let (announcement, sender) = try startSender(in: directory, gpu: gpu, width: 16, height: 8)
        defer { announcement.withdraw() }
        let occupants = try occupyAllButOne(of: announcement, sender: sender)
        defer { withExtendedLifetime(occupants) {} }
        var said: [String] = []
        sender.warn = { said.append($0) }

        let receiver = try FrameReceiverProcess(arguments: [
            "--service", announcement.entry.serviceName, "--width", "16", "--height", "8",
            "--reconnect-after", "1", "--hold-attempt", "2", "--answer-timeout", "0.5",
        ])
        defer { receiver.stop() }
        // 1 枚受けて繋ぎ直す手前で止まるまで回す
        let holding = try drive(receiver, sender: sender, gpu: gpu) { attempts(receiver, "holding").contains(2) }
        try #require(holding, "受け手が繋ぎ直しに来ない: \(receiver.events)")
        let first = try #require(receiver.events(named: "accepted").first?["receiver"] as? Int, "\(receiver.events)")
        // 送り手は忙しい: 繋ぎ直しの connect を、受け手が期限で port を作り直して 3 通目を送るまで捌かない
        // 受け手は止まる前に 1 枚目の release を送っている。捌いておく (送り手の名前の待ち行列は短い — launchd が
        // 登録した port の上限は 2。connect と disconnect で埋まる)
        sender.drain()
        receiver.resume()
        let gaveUpWaiting = receiver.wait(upTo: 20) { attempts(receiver, "connected").contains(3) }
        try #require(gaveUpWaiting, "受け手が期限で繋ぎ直さない: \(receiver.events)")

        let recovered = try driveRecovery(receiver, sender: sender, gpu: gpu)
        let events = receiver.events
        #expect(recovered, "新しい繋がりの絵が届かない: \(events)")
        // 1 度目の時間切れは番号を知っている。disconnect は送り手の待ち行列に入った (止まる前の release は捌いた)。
        // その後の connect は待ち行列の上限で落ちうる (受け手はもう 1 度時間切れを数え、知らない側の手順で繋ぎ直す)
        let timedOut = try #require(receiver.events(named: "answerTimedOut").first, "\(events)")
        #expect(timedOut["known"] as? Bool == true && timedOut["receiver"] as? Int == first, "\(events)")
        #expect(timedOut["disconnect"] as? Int == Int(KERN_SUCCESS), "\(events)")
        let accepted = receiver.events(named: "accepted").compactMap { $0["receiver"] as? Int }
        #expect(accepted.count == 2 && accepted.last != first, "遅れた accepted を受けた: \(events)")
        #expect(receiver.events(named: "unexpectedAnswer").isEmpty, "\(events)")
        #expect(receiver.events(named: "refused").isEmpty, "\(events)")
        #expect(sender.receiverCount == FrameLink.receiverLimit, "(\(sender.receiverCount))")
        #expect(said.filter { $0.hasPrefix("Stopped handing") }.count == 1, "\(said)")
    }

    /// **繋ぐ前に待ち行列を読み切る** ([#3968])。前の繋がりの読み残しで待ち行列が埋まっていても、読み切ってから送れば
    /// 答えは落ちない。
    ///
    /// [#3968]: https://github.com/mokume-metal/mokume/issues/3968
    @Test("読み残しで待ち行列が埋まっていても、読み切ってから connect を送った受け手は、時間切れなしに 1 度で繋がる")
    func aReceiverReadsItsPortEmptyBeforeConnecting() throws {
        let directory = try TestScratch.directory("mokume-frames")
        let gpu = try RenderDevice()
        let (announcement, sender) = try startSender(in: directory, gpu: gpu, width: 16, height: 8)
        defer { announcement.withdraw() }
        let receiver = try FrameReceiverProcess(arguments: [
            "--service", announcement.entry.serviceName, "--width", "16", "--height", "8",
            "--leftovers-attempt", "1", "--answer-timeout", "0.5",
        ])
        defer { receiver.stop() }
        let received = try drive(receiver, sender: sender, gpu: gpu) { !receiver.events(named: "frame").isEmpty }
        let events = receiver.events
        #expect(received, "絵が届かない: \(events)")
        #expect(receiver.events(named: "answerTimedOut").isEmpty, "読み残しで答えが落ちた: \(events)")
        #expect(attempts(receiver, "connected") == [1], "\(events)")
    }

    /// **読み切るときも、送り手が消えた知らせと `resized` は捌く** ([#3968])。繋ぎ直す手前で止めた受け手の待ち行列に、
    /// 大きさの変更か送り手の消えた知らせを積んでから読ませる。
    ///
    /// [#3968]: https://github.com/mokume-metal/mokume/issues/3968
    @Test(
        "繋ぎ直す前の読み切りで、resized なら新しい大きさの面で繋ぎ、送り手が消えた知らせなら繋がずに終わる",
        arguments: ["resized", "withdrawn"])
    func aReceiverActsOnWhatItReadsBeforeConnecting(_ queued: String) throws {
        let directory = try TestScratch.directory("mokume-frames")
        let gpu = try RenderDevice()
        let (announcement, sender) = try startSender(in: directory, gpu: gpu, width: 16, height: 8)
        defer { announcement.withdraw() }
        let receiver = try FrameReceiverProcess(arguments: [
            "--service", announcement.entry.serviceName, "--width", "16", "--height", "8", "--surfaces", "2",
            "--reconnect-after", "1", "--hold-attempt", "2", "--answer-timeout", "0.5",
        ])
        defer { receiver.stop() }
        let holding = try drive(receiver, sender: sender, gpu: gpu) { attempts(receiver, "holding").contains(2) }
        try #require(holding, "受け手が繋ぎ直しに来ない: \(receiver.events)")
        // 止まっている間は絵を書かない (待ち行列の残りは面の数までの frame だけ。上限 5 に届かない)
        if queued == "resized" {
            sender.resize(width: 32, height: 8)
            receiver.resume()
            let received = try drive(receiver, sender: sender, gpu: gpu) {
                receiver.events(named: "accepted").count >= 2 && receiver.events.last?["event"] as? String == "frame"
            }
            let events = receiver.events
            #expect(received, "新しい大きさで繋がらない: \(events)")
            #expect(
                receiver.events(named: "resized").first?["whileReading"] as? Bool == true, "読み切りで捌いていない: \(events)")
            #expect(receiver.events(named: "accepted").last?["width"] as? Int == 32, "\(events)")
            #expect(receiver.events(named: "refused").isEmpty, "古い大きさで繋いだ: \(events)")
        } else {
            announcement.withdraw()
            receiver.resume()
            let ended = receiver.wait(upTo: 20) { !receiver.process.isRunning }
            let events = receiver.events
            #expect(ended, "\(events)")
            #expect(!receiver.events(named: "senderGone").isEmpty, "\(events)")
            #expect(!attempts(receiver, "connected").contains(2), "消えた送り手へ繋ぎに行った: \(events)")
        }
    }
}
