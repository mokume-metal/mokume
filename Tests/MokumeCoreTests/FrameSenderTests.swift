// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import CoreGraphics
import Darwin
import Foundation
import IOSurface
import Metal
import MokumeTestSupport
import Testing

@testable import MokumeCore

/// 同じプロセスの中で受け手を模す ([#3920])。受信の port を作り、半精度の面を作って送り手へ繋ぐ。別のプロセスでの
/// 往復は #3922 の受け手が確かめる。
///
/// [#3920]: https://github.com/mokume-metal/mokume/issues/3920
@MainActor
final class ModelReceiver {
    let port: mach_port_t
    private(set) var surfaces: [IOSurfaceRef]
    /// 受け入れられたときの番号。
    private(set) var id: UInt32?

    init(width: Int, height: Int, count: Int, format: OSType = FrameLink.surfaceFormat) {
        var port: mach_port_t = 0
        mach_port_allocate(mach_task_self_, MACH_PORT_RIGHT_RECEIVE, &port)
        self.port = port
        surfaces = Self.makeSurfaces(width: width, height: height, count: count, format: format)
    }

    static func makeSurfaces(width: Int, height: Int, count: Int, format: OSType = FrameLink.surfaceFormat)
        -> [IOSurfaceRef]
    {
        (0..<count).compactMap { _ in
            IOSurfaceCreate(
                [
                    kIOSurfaceWidth: width, kIOSurfaceHeight: height, kIOSurfacePixelFormat: format,
                    kIOSurfaceBytesPerElement: 8,
                ] as [CFString: Any] as CFDictionary)
        }
    }

    /// 名乗る名前。`nil` なら名乗らない。
    var name: String?

    @discardableResult
    func connect(to service: mach_port_t, version: UInt32 = FrameLink.version) -> kern_return_t {
        FrameLink.connect(to: service, reply: port, surfaces: surfaces, version: version, name: name)
    }

    /// 面を作り直して繋ぎ直す (大きさの変更の後)。
    func reconnect(to service: mach_port_t, width: Int, height: Int) {
        surfaces = Self.makeSurfaces(width: width, height: height, count: surfaces.count)
        connect(to: service)
    }

    /// 届いているメッセージをすべて受ける。accepted なら番号を控える。
    func receiveAll() -> [FrameLink.Received] {
        var all: [FrameLink.Received] = []
        while let received = FrameLink.receive(on: port) {
            if received.kind == FrameLink.Kind.accepted.rawValue {
                var reader = received.payload.reader
                id = reader.uint32()
            }
            all.append(received)
        }
        return all
    }

    func release(slot: UInt32, to service: mach_port_t) {
        var payload = FrameLink.Payload()
        payload.append(id ?? 0)
        payload.append(slot)
        FrameLink.send(.release, to: service, payload: payload)
    }

    func disconnect(from service: mach_port_t) {
        var payload = FrameLink.Payload()
        payload.append(id ?? 0)
        FrameLink.send(.disconnect, to: service, payload: payload)
    }

    /// 受信の権利を壊す (受け手のプロセスが消えたのと同じ)。
    func die() {
        mach_port_mod_refs(mach_task_self_, port, MACH_PORT_RIGHT_RECEIVE, -1)
    }

    /// frame の中身。
    struct Frame: Equatable {
        var receiver: UInt32
        var slot: UInt32
        var frameCount: Int64
        var writes: Int64
        var hostTime: UInt64
    }

    static func frames(in messages: [FrameLink.Received]) -> [Frame] {
        messages.filter { $0.kind == FrameLink.Kind.frame.rawValue }.compactMap { message in
            var reader = message.payload.reader
            guard let receiver = reader.uint32(), let slot = reader.uint32(), let frameCount = reader.int64(),
                let writes = reader.int64(), let hostTime = reader.uint64()
            else { return nil }
            return Frame(receiver: receiver, slot: slot, frameCount: frameCount, writes: writes, hostTime: hostTime)
        }
    }

    static func refusals(in messages: [FrameLink.Received]) -> [UInt32] {
        messages.filter { $0.kind == FrameLink.Kind.refused.rawValue }.compactMap {
            var reader = $0.payload.reader
            return reader.uint32()
        }
    }

    /// 面の 1 画素 (半精度 4 成分)。
    static func pixel(of surface: IOSurfaceRef, x: Int, y: Int) -> [Float] {
        IOSurfaceLock(surface, .readOnly, nil)
        defer { IOSurfaceUnlock(surface, .readOnly, nil) }
        let base = IOSurfaceGetBaseAddress(surface)
        let offset = y * IOSurfaceGetBytesPerRow(surface) + x * 8
        let components = base.advanced(by: offset).assumingMemoryBound(to: Float16.self)
        return (0..<4).map { Float(components[$0]) }
    }
}

/// 繋いできた受け手の面へ、繋がっている間だけ絵を書く ([ADR-0049] 決定 3・4・[#3920])。
///
/// [ADR-0049]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0049-share-frames-to-other-processes.md
/// [#3920]: https://github.com/mokume-metal/mokume/issues/3920
@Suite(
    "繋いできた受け手の面へ渡す",
    .serialized,
    .enabled(
        if: RenderDevice.isAvailable,
        "この世代のコマンド構造に対応した GPU が無い実行環境ではスキップする")
)
@MainActor
struct FrameSenderTests {
    static let width = 16
    static let height = 8
    /// 1.0 を超える値を含む色 (画面と同じ値なら、半精度のまま残る)。
    static let color = LinearRGBA.linear(red: 2, green: 0.5, blue: 0.25)

    /// 送り手と、受け手が送るための送信の権利つきの受信の port。
    private struct Harness {
        let gpu: RenderDevice
        let sender: FrameSender
        let service: mach_port_t
        let source: RenderTarget
        let presenter: FramePresenter

        /// 1 フレーム進める (受け手の頼みを捌き、書き、GPU の結末を待つ)。
        func step(frame: Int64, width: Int = FrameSenderTests.width, height: Int = FrameSenderTests.height) throws {
            sender.drain()
            try sender.deliver(width: width, height: height, frameCount: frame, hostTime: UInt64(frame) * 1000) {
                texture throws(RenderFailure) in
                try presenter.draw(source, into: texture)
            }
            _ = gpu.droppedWork(after: 0, through: gpu.submissionCount)
        }
    }

    private func makeHarness() throws -> Harness {
        let gpu = try RenderDevice()
        var service: mach_port_t = 0
        mach_port_allocate(mach_task_self_, MACH_PORT_RIGHT_RECEIVE, &service)
        mach_port_insert_right(mach_task_self_, service, service, mach_msg_type_name_t(MACH_MSG_TYPE_MAKE_SEND))
        let sender = FrameSender(gpu: gpu, port: service, width: Self.width, height: Self.height)
        let source = try RenderTarget(gpu: gpu, width: Self.width, height: Self.height)
        try source.fill(with: Self.color)
        let presenter = try FramePresenter(gpu: gpu, pixelFormat: RenderTarget.pixelFormat)
        return Harness(gpu: gpu, sender: sender, service: service, source: source, presenter: presenter)
    }

    @Test("3 枚の面で繋ぐと受け入れ、番号が 1 ずつ進み、画面と同じ値 (1.0 超を含む) と属性が面に載る")
    func handsFramesToTheReceiver() throws {
        let harness = try makeHarness()
        defer { harness.sender.stop() }
        let receiver = ModelReceiver(width: Self.width, height: Self.height, count: 3)
        defer { receiver.die() }
        #expect(receiver.connect(to: harness.service) == KERN_SUCCESS)
        harness.sender.drain()
        let accepted = receiver.receiveAll()
        #expect(accepted.map(\.kind) == [FrameLink.Kind.accepted.rawValue])
        #expect(harness.sender.receiverCount == 1)

        var frames: [ModelReceiver.Frame] = []
        for frame in Int64(1)...6 {
            try harness.step(frame: frame)
            for got in ModelReceiver.frames(in: receiver.receiveAll()) {
                frames.append(got)
                receiver.release(slot: got.slot, to: harness.service)
            }
        }
        // 最後の焼きは次のフレームで知らせる (GPU を待たない)
        #expect(frames.map(\.frameCount) == [1, 2, 3, 4, 5])
        #expect(frames.map(\.writes) == [1, 2, 3, 4, 5])
        #expect(frames.allSatisfy { $0.receiver == receiver.id })
        #expect(harness.sender.skippedFrames == 0)

        // 画素は、同じ経路で普通のテクスチャへ書いたもの (画面に出す値) と一致する
        let ordinary = try RenderTarget(gpu: harness.gpu, width: Self.width, height: Self.height)
        try harness.presenter.draw(harness.source, into: ordinary.texture)
        let expected = try ordinary.readPixels()[8, 4]
        let last = try #require(frames.last)
        let surface = receiver.surfaces[Int(last.slot)]
        let actual = ModelReceiver.pixel(of: surface, x: 8, y: 4)
        #expect(actual == [expected.red, expected.green, expected.blue, expected.alpha])
        #expect(actual[0] > 1, "1.0 を超える値が残っていない: \(actual)")

        func attribute(_ name: String) -> Any? { IOSurfaceCopyValue(surface, name as CFString) }
        #expect((attribute(FrameLink.Attribute.frameCount) as? NSNumber)?.int64Value == last.frameCount)
        #expect((attribute(FrameLink.Attribute.writes) as? NSNumber)?.int64Value == last.writes)
        #expect((attribute(FrameLink.Attribute.hostTime) as? NSNumber)?.uint64Value == last.hostTime)
        #expect(attribute(FrameLink.Attribute.colorSpace) as? String == CGColorSpace.extendedLinearDisplayP3 as String)
        #expect(attribute(FrameLink.Attribute.alpha) as? String == "premultiplied")
    }

    /// **書いたことは GPU の完了を確かめてから知らせる** (#3920)。打ち切られた焼きは中身が揃っていないので知らせず、
    /// 結末がまだ届いていない焼きは、届くまで知らせを次のフレームへ回す (待たない)。
    @Test("GPU が打ち切った焼きは知らせず、結末の届いていない焼きは届いてから知らせる")
    func announcesOnlyCompletedBurns() throws {
        let harness = try makeHarness()
        defer { harness.sender.stop() }
        harness.gpu.outcomeWaitLimit = .milliseconds(50)
        let receiver = ModelReceiver(width: Self.width, height: Self.height, count: 3)
        defer { receiver.die() }
        receiver.connect(to: harness.service)
        harness.sender.drain()
        _ = receiver.receiveAll()

        harness.gpu.dropsNextSubmissionForTesting = "検査の打ち切り"
        try harness.step(frame: 1)
        // 結末を抱えている間は待たずに進める (検査の側で待つと、抱えた結末を届かなかったものとみなす)
        harness.gpu.holdsNextOutcomeForTesting = true
        for frame in Int64(2)...3 {
            harness.sender.drain()
            try harness.sender.deliver(
                width: Self.width, height: Self.height, frameCount: frame, hostTime: 0
            ) { texture throws(RenderFailure) in
                try harness.presenter.draw(harness.source, into: texture)
            }
        }
        #expect(ModelReceiver.frames(in: receiver.receiveAll()).isEmpty, "揃っていない焼きを知らせた")

        harness.gpu.releaseHeldOutcomesForTesting()
        _ = harness.gpu.droppedWork(after: 0, through: harness.gpu.submissionCount)
        try harness.step(frame: 4)
        let announced = ModelReceiver.frames(in: receiver.receiveAll()).map(\.frameCount)
        #expect(announced == [2, 3], "知らせた番号: \(announced)")
    }

    @Test("同じフレームの番号は 2 度書かない (止まっている作品)")
    func aHeldFrameIsNotRewritten() throws {
        let harness = try makeHarness()
        defer { harness.sender.stop() }
        let receiver = ModelReceiver(width: Self.width, height: Self.height, count: 3)
        defer { receiver.die() }
        receiver.connect(to: harness.service)
        for _ in 0..<5 { try harness.step(frame: 7) }
        let frames = ModelReceiver.frames(in: receiver.receiveAll())
        #expect(frames.map(\.frameCount) == [7])
    }

    @Test("受け手が面を返さないと、書かずに見送った枚数が増え、送り手は止まらない")
    func aReceiverThatHoldsEverySurfaceIsSkipped() throws {
        let harness = try makeHarness()
        defer { harness.sender.stop() }
        let receiver = ModelReceiver(width: Self.width, height: Self.height, count: 2)
        defer { receiver.die() }
        receiver.connect(to: harness.service)
        for frame in Int64(1)...10 { try harness.step(frame: frame) }
        let frames = ModelReceiver.frames(in: receiver.receiveAll())
        #expect(frames.count == 2, "返していない面へ書いた")
        #expect(harness.sender.skippedFrames == 8)
    }

    @Test("受け手が読まずに待ち行列が埋まっても、送りは待たずに戻り、知らせていない面は空きへ戻る")
    func aFullQueueDoesNotBlock() throws {
        let harness = try makeHarness()
        defer { harness.sender.stop() }
        let receiver = ModelReceiver(width: Self.width, height: Self.height, count: 8)
        defer { receiver.die() }
        receiver.connect(to: harness.service)
        harness.sender.drain()
        _ = receiver.receiveAll()  // accepted だけ読む
        let started = Date()
        for frame in Int64(1)...40 { try harness.step(frame: frame) }
        #expect(Date().timeIntervalSince(started) < 10, "送りで止まった")
        // 待ち行列の上限 (既定 5 通) を越えた分は知らせていない。知らせていない面は空きへ戻るので、見送りは数えない
        #expect(harness.sender.deliveredFrames <= 5)
        #expect(harness.sender.skippedFrames < 40)
        #expect(ModelReceiver.frames(in: receiver.receiveAll()).count == harness.sender.deliveredFrames)
    }

    @Test(
        "形の合わない頼みは断り、理由を返して診断に 1 行出す",
        arguments: [
            (count: 1, format: FrameLink.surfaceFormat, width: 16, version: FrameLink.version, reason: FrameLink.Refusal.surfaceCount),
            (count: 9, format: FrameLink.surfaceFormat, width: 16, version: FrameLink.version, reason: .surfaceCount),
            (count: 2, format: OSType(0x4247_5241), width: 16, version: FrameLink.version, reason: .surfaceFormat),
            (count: 2, format: FrameLink.surfaceFormat, width: 32, version: FrameLink.version, reason: .surfaceSize),
            (count: 2, format: FrameLink.surfaceFormat, width: 16, version: 99, reason: .version),
        ])
    func refusesMalformedRequests(
        _ request: (count: Int, format: OSType, width: Int, version: UInt32, reason: FrameLink.Refusal)
    ) throws {
        let harness = try makeHarness()
        defer { harness.sender.stop() }
        var warnings: [String] = []
        harness.sender.warn = { warnings.append($0) }
        let receiver = ModelReceiver(width: request.width, height: Self.height, count: request.count, format: request.format)
        defer { receiver.die() }
        receiver.connect(to: harness.service, version: request.version)
        harness.sender.drain()
        #expect(ModelReceiver.refusals(in: receiver.receiveAll()) == [request.reason.rawValue])
        #expect(harness.sender.receiverCount == 0)
        #expect(warnings.count == 1)
    }

    @Test("受け手は上限まで。超えた頼みは断る")
    func refusesBeyondTheReceiverLimit() throws {
        let harness = try makeHarness()
        defer { harness.sender.stop() }
        harness.sender.warn = { _ in }
        let receivers = (0...FrameLink.receiverLimit).map { _ in
            ModelReceiver(width: Self.width, height: Self.height, count: 2)
        }
        defer { receivers.forEach { $0.die() } }
        for receiver in receivers { receiver.connect(to: harness.service) }
        harness.sender.drain()
        #expect(harness.sender.receiverCount == FrameLink.receiverLimit)
        let last = try #require(receivers.last)
        #expect(ModelReceiver.refusals(in: last.receiveAll()) == [FrameLink.Refusal.receiverLimit.rawValue])
    }

    @Test("描く大きさが変わると知らせ、受け手が面を作り直して繋ぎ直すと、同じ番号のまま新しい大きさで続く")
    func resizesAndReconnects() throws {
        let harness = try makeHarness()
        defer { harness.sender.stop() }
        let receiver = ModelReceiver(width: Self.width, height: Self.height, count: 2)
        defer { receiver.die() }
        receiver.connect(to: harness.service)
        try harness.step(frame: 1)
        _ = receiver.receiveAll()
        let id = try #require(receiver.id, "受け入れられていない")

        // 大きさが変わったフレーム
        try harness.step(frame: 2, width: 32, height: 8)
        let resized = receiver.receiveAll().filter { $0.kind == FrameLink.Kind.resized.rawValue }
        var reader = try #require(resized.first).payload.reader
        #expect(reader.uint32() == 32)
        #expect(reader.uint32() == 8)

        receiver.reconnect(to: harness.service, width: 32, height: 8)
        harness.sender.drain()
        _ = receiver.receiveAll()
        #expect(receiver.id == id, "繋ぎ直しで別の受け手になった")
        #expect(harness.sender.receiverCount == 1)
        for frame in Int64(3)...5 { try harness.step(frame: frame, width: 32, height: 8) }
        let frames = ModelReceiver.frames(in: receiver.receiveAll())
        #expect(!frames.isEmpty, "繋ぎ直した後に届かない")
        #expect(IOSurfaceGetWidth(receiver.surfaces[0]) == 32)
    }

    @Test("受け手が消えると dead-name の知らせで外し、切ると言われても外す")
    func removesReceiversThatGoAway() throws {
        let harness = try makeHarness()
        defer { harness.sender.stop() }
        let dying = ModelReceiver(width: Self.width, height: Self.height, count: 2)
        let leaving = ModelReceiver(width: Self.width, height: Self.height, count: 2)
        defer { leaving.die() }
        dying.connect(to: harness.service)
        leaving.connect(to: harness.service)
        harness.sender.drain()
        _ = leaving.receiveAll()
        #expect(harness.sender.receiverCount == 2)

        dying.die()
        harness.sender.drain()
        #expect(harness.sender.receiverCount == 1, "消えた受け手を外していない")

        leaving.disconnect(from: harness.service)
        harness.sender.drain()
        #expect(harness.sender.receiverCount == 0)
        // 受け手が居なければ何もしない
        try harness.step(frame: 1)
        #expect(harness.sender.deliveredFrames == 0)
    }

    /// **繋がった・切れたことを 1 行ずつ言い、相手の名前をメニューバーの名乗りへ渡す** (ADR-0049 決定 6・#3921)。
    @Test("受け入れ・外し・畳むたびに相手の名前を知らせ、繋がった・切れたことを 1 行ずつ言う")
    func reportsWhoIsConnected() throws {
        let harness = try makeHarness()
        var lines: [String] = []
        var names: [[String]] = []
        harness.sender.warn = { lines.append($0) }
        harness.sender.onReceiversChanged = { names.append($0) }
        let mapper = ModelReceiver(width: Self.width, height: Self.height, count: 2)
        mapper.name = "mokumesh"
        let recorder = ModelReceiver(width: Self.width, height: Self.height, count: 2)
        recorder.name = "recorder"
        defer { recorder.die() }
        mapper.connect(to: harness.service)
        recorder.connect(to: harness.service)
        harness.sender.drain()
        #expect(names == [["mokumesh"], ["mokumesh", "recorder"]])
        #expect(harness.sender.receiverNames == ["mokumesh", "recorder"])

        mapper.die()
        harness.sender.drain()
        #expect(names.last == ["recorder"])
        harness.sender.stop()
        #expect(names.last == [])
        #expect(
            lines == [
                "Handing this sketch's frames to mokumesh", "Handing this sketch's frames to recorder",
                "Stopped handing this sketch's frames to mokumesh", "Stopped handing this sketch's frames to recorder",
            ])
    }

    @Test(
        "名乗らない受け手・長すぎる名前は、呼び名で呼ぶ。壊れた UTF-8 は置き換えて読む",
        arguments: [
            (name: String?.none, expected: FrameLink.unnamedReceiver),
            (name: "", expected: FrameLink.unnamedReceiver),
            (name: String(repeating: "x", count: FrameLink.nameLimit + 1), expected: FrameLink.unnamedReceiver),
            (name: String(repeating: "x", count: FrameLink.nameLimit), expected: String(repeating: "x", count: FrameLink.nameLimit)),
        ])
    func namesReceivers(_ request: (name: String?, expected: String)) throws {
        let harness = try makeHarness()
        defer { harness.sender.stop() }
        harness.sender.warn = { _ in }
        let receiver = ModelReceiver(width: Self.width, height: Self.height, count: 2)
        defer { receiver.die() }
        receiver.name = request.name
        receiver.connect(to: harness.service)
        harness.sender.drain()
        #expect(harness.sender.receiverNames == [request.expected])
    }

    @Test("壊れた UTF-8 の名前は置き換え文字で読み、断らない")
    func readsMalformedNames() {
        var payload = FrameLink.Payload()
        payload.append(UInt32(3))
        var bytes = payload.bytes
        bytes += [0x61, 0xFF, 0x62]
        var reader = FrameLink.Payload.Reader(bytes: bytes)
        #expect(reader.string(limit: FrameLink.nameLimit) == "a\u{FFFD}b")
        // 長さが並びより長い
        var short = FrameLink.Payload.Reader(bytes: payload.bytes + [0x61])
        #expect(short.string(limit: FrameLink.nameLimit) == nil)
    }

    @Test("見張りの道具は、子の面を焼き直さずに写し、子が面に載せた色空間と alpha の扱いを写す")
    func copiesTheChildSurface() throws {
        let harness = try makeHarness()
        defer { harness.sender.stop() }
        let receiver = ModelReceiver(width: Self.width, height: Self.height, count: 2)
        defer { receiver.die() }
        receiver.connect(to: harness.service)
        harness.sender.drain()
        _ = receiver.receiveAll()

        // 子の面を模す (子が焼いた値を持ち、色空間を載せた面)
        let child = try #require(ModelReceiver.makeSurfaces(width: Self.width, height: Self.height, count: 1).first)
        IOSurfaceSetValue(child, FrameLink.Attribute.colorSpace as CFString, "childSpace" as CFString)
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: RenderTarget.pixelFormat, width: Self.width, height: Self.height, mipmapped: false)
        descriptor.usage = [.renderTarget, .shaderRead]
        let texture = try #require(harness.gpu.device.makeTexture(descriptor: descriptor, iosurface: child, plane: 0))
        harness.gpu.makeResident(texture)
        try harness.presenter.draw(harness.source, into: texture)
        _ = harness.gpu.droppedWork(after: 0, through: harness.gpu.submissionCount)

        for frame in Int64(1)...2 {
            harness.sender.drain()
            try harness.sender.deliver(copying: texture, frameCount: frame, hostTime: 0)
            _ = harness.gpu.droppedWork(after: 0, through: harness.gpu.submissionCount)
        }
        let frames = ModelReceiver.frames(in: receiver.receiveAll())
        let first = try #require(frames.first)
        let surface = receiver.surfaces[Int(first.slot)]
        #expect(ModelReceiver.pixel(of: surface, x: 3, y: 3) == ModelReceiver.pixel(of: child, x: 3, y: 3))
        #expect(IOSurfaceCopyValue(surface, FrameLink.Attribute.colorSpace as CFString) as? String == "childSpace")
    }
}
