// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Darwin
import Foundation
import IOSurface
import Metal
import MokumeTestSupport
import Testing

@testable import MokumeCLI
@testable import MokumeCore

/// 見張りの下では道具が目録へ名乗る ([ADR-0049] 決定 2・[#3919])。
///
/// 名乗りは本物 (bootstrap へ登録し、検査の置き場へ目録を置く)。台の知らせ (``WatchFrameListing/follow(_:)``) は
/// 手で渡す — 台が名乗りの中身を読む形は `SharedFrameStageTests` が持つ。
///
/// [ADR-0049]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0049-share-frames-to-other-processes.md
/// [#3919]: https://github.com/mokume-metal/mokume/issues/3919
@Suite("見張りの名乗り")
@MainActor
struct WatchFrameListingTests {
    private func makeListing(in directory: URL) -> WatchFrameListing {
        WatchFrameListing(identity: "/work/Bricks") { identity, share in
            FrameAnnouncement.announce(
                sketch: share.sketch, identity: identity, title: share.title, in: directory,
                warn: { Issue.record("名乗れなかった: \($0)") })
        }
    }

    @Test("映す世代が断っていなければ名乗り、保存で子が 3 回入れ替わっても項目は 1 件で名前も変わらない")
    func generationsKeepOneEntry() throws {
        let directory = try TestScratch.directory("mokume-frames")
        let listing = makeListing(in: directory)
        defer { listing.withdraw() }
        let share = FrameShare(sketch: "Bricks", title: "Bricks and ball")

        listing.follow(share)
        let first = try #require(FrameListing.entries(in: directory).first)
        #expect(first.sketch == "Bricks")
        #expect(first.identity == "/work/Bricks")
        #expect(first.pid == getpid(), "名乗るのは道具のプロセス")

        // 世代ごとに同じ中身の絵が届く (3 回の保存)
        for _ in 0..<3 {
            for _ in 0..<5 { listing.follow(share) }
        }
        let entries = FrameListing.entries(in: directory)
        #expect(entries.count == 1)
        #expect(entries.first?.serviceName == first.serviceName, "入れ替えで名前が変わった")

        // 題を書き換えて保存しても、名前は変わらない
        listing.follow(FrameShare(sketch: "Bricks", title: "Renamed"))
        #expect(FrameListing.entries(in: directory).map(\.title) == ["Renamed"])
        #expect(FrameListing.entries(in: directory).map(\.serviceName) == [first.serviceName])
    }

    @Test("新しい世代が断れば下ろし、断らない世代が来ればまた名乗る")
    func aRefusingGenerationWithdraws() throws {
        let directory = try TestScratch.directory("mokume-frames")
        let listing = makeListing(in: directory)
        defer { listing.withdraw() }
        let share = FrameShare(sketch: "Bricks", title: "Bricks and ball")
        listing.follow(share)
        let name = try #require(FrameListing.entries(in: directory).first?.serviceName)

        listing.follow(nil)
        #expect(FrameListing.entries(in: directory).isEmpty, "断った世代なのに目録に残っている")
        #expect(Bootstrap.lookUp(name).map { Bootstrap.releaseSend($0) } == nil, "名前を手放していない")

        listing.follow(share)
        #expect(FrameListing.entries(in: directory).count == 1)
    }

    @Test("子が自分のウィンドウへ倒れたら下ろし (倒れた子が名乗る)、共有面へ戻った世代の絵が来ればまた名乗る")
    func aFallenChildTakesOver() throws {
        let directory = try TestScratch.directory("mokume-frames")
        let listing = makeListing(in: directory)
        defer { listing.withdraw() }
        let share = FrameShare(sketch: "Bricks", title: "Bricks and ball")
        listing.follow(share)

        listing.fellBack()
        #expect(FrameListing.entries(in: directory).isEmpty, "倒れた子と道具の名乗りが 2 つ並ぶ")

        listing.follow(share)
        #expect(FrameListing.entries(in: directory).count == 1)
    }

    @Test("断っている世代 (名乗りの中身が無い) しか来なければ、1 度も名乗らない")
    func neverAnnouncesWithoutAShare() throws {
        let directory = try TestScratch.directory("mokume-frames")
        let listing = makeListing(in: directory)
        listing.follow(nil)
        listing.follow(nil)
        #expect(listing.announcement == nil)
        #expect(FrameListing.entries(in: directory).isEmpty)
    }
}


/// 見張りの道具が、子の面を受け手の面へ写す ([#3920])。GPU が要る。
///
/// [#3920]: https://github.com/mokume-metal/mokume/issues/3920
@Suite(
    "見張りの受け渡し",
    .enabled(
        if: RenderDevice.isAvailable,
        "この世代のコマンド構造に対応した GPU が無い実行環境ではスキップする")
)
@MainActor
struct WatchFrameHandOverTests {
    /// **番号は道具が数える** ([#3920])。保存で子が入れ替わって (面が変わって) も、受け手の見る番号は途切れない。
    ///
    /// [#3920]: https://github.com/mokume-metal/mokume/issues/3920
    /// **見張りの下で受け手と繋がっているのは道具** (ADR-0049 決定 6・[#3921](https://github.com/mokume-metal/mokume/issues/3921))。
    /// 道具が端末に 1 行ずつ言い、相手をプレビューへ渡す。
    @Test("受け手が繋がる・切れると、道具は端末に 1 行ずつ言い、相手の名前を知らせる")
    func toldWhoIsConnected() throws {
        let directory = try TestScratch.directory("mokume-frames")
        let gpu = try RenderDevice()
        let listing = WatchFrameListing(identity: "/work/Bricks", gpu: gpu) { identity, share in
            FrameAnnouncement.announce(
                sketch: share.sketch, identity: identity, title: share.title, in: directory, warn: { _ in })
        }
        var said: [String] = []
        var names: [[String]] = []
        listing.say = { said.append($0) }
        listing.onReceiversChanged = { names.append($0) }
        listing.follow(FrameShare(sketch: "Bricks", title: "Bricks"))
        let service = try #require(listing.announcement.flatMap { Bootstrap.lookUp($0.entry.serviceName) })
        defer { Bootstrap.releaseSend(service) }
        let texture = try childTexture(gpu: gpu)
        listing.handOver(texture)
        let receiver = try ReceiverForWatch(width: 16, height: 8, service: service, name: "mapper")
        listing.announcement?.sender?.drain()
        #expect(names == [["mapper"]])
        receiver.close()
        listing.announcement?.sender?.drain()
        #expect(names == [["mapper"], []])
        #expect(said == ["Handing this sketch's frames to mapper", "Stopped handing this sketch's frames to mapper"])
        listing.withdraw()
    }

    @Test("子の面を受け手へ写し、子が入れ替わっても番号は道具の側で途切れず進む")
    func handsOverAcrossGenerations() throws {
        let directory = try TestScratch.directory("mokume-frames")
        let gpu = try RenderDevice()
        let listing = WatchFrameListing(identity: "/work/Bricks", gpu: gpu) { identity, share in
            FrameAnnouncement.announce(
                sketch: share.sketch, identity: identity, title: share.title, in: directory,
                warn: { Issue.record("名乗れなかった: \($0)") })
        }
        defer { listing.withdraw() }
        listing.follow(FrameShare(sketch: "Bricks", title: "Bricks"))
        let name = try #require(listing.announcement?.entry.serviceName)
        let service = try #require(Bootstrap.lookUp(name))
        defer { Bootstrap.releaseSend(service) }

        // 2 つの世代の子の面
        let generations = try (0..<2).map { _ in try childTexture(gpu: gpu) }
        listing.handOver(generations[0])  // 送り手を起こす (受け手はまだ居ない)
        let sender = try #require(listing.announcement?.sender)
        let receiver = try ReceiverForWatch(width: 16, height: 8, service: service)
        defer { receiver.close() }
        sender.drain()
        var counts: [Int64] = []
        for texture in [generations[0], generations[0], generations[1], generations[1], generations[1]] {
            sender.drain()
            listing.handOver(texture)
            _ = gpu.droppedWork(after: 0, through: gpu.submissionCount)
            counts += receiver.takeFrames()
        }
        #expect(counts == counts.sorted() && counts.count >= 3, "番号が途切れた: \(counts)")
        #expect(Set(counts).count == counts.count)
    }
}

/// 見張りの検査が使う、子の面のテクスチャ。
@MainActor
private func childTexture(gpu: RenderDevice) throws -> any MTLTexture {
    let surface = try #require(
        IOSurfaceCreate(
            [
                kIOSurfaceWidth: 16, kIOSurfaceHeight: 8, kIOSurfacePixelFormat: FrameLink.surfaceFormat,
                kIOSurfaceBytesPerElement: 8,
            ] as [CFString: Any] as CFDictionary))
    let descriptor = MTLTextureDescriptor.texture2DDescriptor(
        pixelFormat: RenderTarget.pixelFormat, width: 16, height: 8, mipmapped: false)
    descriptor.usage = [.renderTarget, .shaderRead]
    let texture = try #require(gpu.device.makeTexture(descriptor: descriptor, iosurface: surface, plane: 0))
    gpu.makeResident(texture)
    return texture
}

/// 見張りの検査が使う、同じプロセスの受け手 (MokumeCoreTests の `ModelReceiver` と同じ手順の最小形)。
@MainActor
private final class ReceiverForWatch {
    let port: mach_port_t
    let service: mach_port_t
    let surfaces: [IOSurfaceRef]
    var id: UInt32 = 0

    init(width: Int, height: Int, service: mach_port_t, name: String? = nil) throws {
        var port: mach_port_t = 0
        mach_port_allocate(mach_task_self_, MACH_PORT_RIGHT_RECEIVE, &port)
        self.port = port
        self.service = service
        surfaces = (0..<3).compactMap { _ in
            IOSurfaceCreate(
                [
                    kIOSurfaceWidth: width, kIOSurfaceHeight: height, kIOSurfacePixelFormat: FrameLink.surfaceFormat,
                    kIOSurfaceBytesPerElement: 8,
                ] as [CFString: Any] as CFDictionary)
        }
        try #require(FrameLink.connect(to: service, reply: port, surfaces: surfaces, name: name) == KERN_SUCCESS)
    }

    /// 届いた frame の番号を読み、面を返す。
    func takeFrames() -> [Int64] {
        var counts: [Int64] = []
        while let received = FrameLink.receive(on: port) {
            var reader = received.payload.reader
            if received.kind == FrameLink.Kind.accepted.rawValue { id = reader.uint32() ?? 0 }
            guard received.kind == FrameLink.Kind.frame.rawValue, let receiver = reader.uint32(),
                let slot = reader.uint32(), let count = reader.int64()
            else { continue }
            counts.append(count)
            var payload = FrameLink.Payload()
            payload.append(receiver)
            payload.append(slot)
            FrameLink.send(.release, to: service, payload: payload)
        }
        return counts
    }

    func close() {
        mach_port_mod_refs(mach_task_self_, port, MACH_PORT_RIGHT_RECEIVE, -1)
    }
}
