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
        listing.handOver(texture, isNew: true)
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
        listing.handOver(generations[0], isNew: true)  // 送り手を起こす (受け手はまだ居ない)
        let sender = try #require(listing.announcement?.sender)
        let receiver = try ReceiverForWatch(width: 16, height: 8, service: service)
        defer { receiver.close() }
        sender.drain()
        var counts: [Int64] = []
        for texture in [generations[0], generations[0], generations[1], generations[1], generations[1]] {
            sender.drain()
            listing.handOver(texture, isNew: true)
            _ = gpu.droppedWork(after: 0, through: gpu.submissionCount)
            counts += receiver.takeFrames()
        }
        #expect(counts == counts.sorted() && counts.count >= 3, "番号が途切れた: \(counts)")
        #expect(Set(counts).count == counts.count)
    }

    // MARK: - 作品のウィンドウの台から受け手まで (#3945・#3948)

    /// 本物の作品のウィンドウの台と子の面を、見張りと同じ口 (``WatchFrameListing/attach(to:)``) で繋いだ組。
    private struct Watched {
        let gpu: RenderDevice
        let window: SharedFrameWindow
        let listing: WatchFrameListing
        let sender: FrameSender
        let receiver: ReceiverForWatch
        let service: mach_port_t

        /// 表示のリフレッシュを `times` 回打つ。**子は描かない** (止まっている作品)。届いた frame の番号を返す。
        func refresh(_ times: Int) -> [Int64] {
            var counts: [Int64] = []
            for _ in 0..<times {
                sender.drain()
                window.stage.displayLinkFired()
                // 写しの結末を検査の側で揃える (送り手は待たない。次のリフレッシュで結末を見る)
                _ = gpu.droppedWork(after: 0, through: gpu.submissionCount)
                counts += receiver.takeFrames()
            }
            return counts
        }

        func close() {
            receiver.close()
            Bootstrap.releaseSend(service)
            listing.withdraw()
            window.stage.close()
        }
    }

    /// 子の面 (`watch` の子が作品のウィンドウへ差し出す面) を区画に置き、名乗りの中身を載せる。
    private func makeChild(in facet: URL, gpu: RenderDevice, offset: TimeInterval = 0) throws -> SharedFrameSurface {
        let child = try SharedFrameSurface(gpu: gpu, width: 16, height: 8, at: facet)
        child.frameShare = FrameShare(sketch: "Bricks", title: "Bricks")
        try child.publishManifest()
        // 見張りは目録の更新時刻が動いたときだけ読み直すので、入れ替えの目録は時刻をずらす
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(offset)],
            ofItemAtPath: facet.appendingPathComponent(SharedFrameSurface.manifestName).path)
        return child
    }

    /// 子の面へ 1 枚焼いて名乗らせる。色で絵を見分ける。
    private func draw(_ child: SharedFrameSurface, _ color: LinearRGBA, gpu: RenderDevice) throws {
        let source = try RenderTarget(gpu: gpu, width: 16, height: 8)
        try source.fill(with: color)
        let presenter = try FramePresenter(gpu: gpu, pixelFormat: RenderTarget.pixelFormat)
        try child.write(
            source, using: presenter,
            numbers: FrameNumbers(frameCount: 1, time: 0, frameRate: 60, frameTimeMs: 16.7))
        _ = gpu.droppedWork(after: 0, through: gpu.submissionCount)
        try child.publishPending()
    }

    /// 子の面を置いた区画で、作品のウィンドウの台を作り、見張りと同じ口で名乗りを繋ぎ、1 度リフレッシュして送り手を
    /// 起こしてから受け手を繋ぐ。
    private func watch(facet: URL, gpu: RenderDevice) throws -> Watched {
        let directory = try TestScratch.directory("mokume-frames")
        let window = try SharedFrameWindow(gpu: gpu, facet: facet, title: "Bricks")
        let listing = WatchFrameListing(identity: "/work/Bricks", gpu: gpu) { identity, share in
            FrameAnnouncement.announce(
                sketch: share.sketch, identity: identity, title: share.title, in: directory,
                warn: { Issue.record("名乗れなかった: \($0)") })
        }
        listing.say = { _ in }
        listing.attach(to: window)
        window.stage.displayLinkFired()
        let sender = try #require(listing.announcement?.sender, "1 枚目で送り手を起こしていない")
        let name = try #require(listing.announcement?.entry.serviceName)
        let service = try #require(Bootstrap.lookUp(name))
        let receiver = try ReceiverForWatch(width: 16, height: 8, service: service)
        return Watched(
            gpu: gpu, window: window, listing: listing, sender: sender, receiver: receiver, service: service)
    }

    /// **受け手へ渡すのは、子の新しい絵が来たときだけではない** ([#3945])。止まった作品 (`noLoop()`) へ後から繋いだ
    /// 受け手にも今の 1 枚が届き、繋がっている間に 1 回だけ描き直して止まっても、その 1 枚が GPU の完了の後に届く。
    /// どちらも同じ絵を写し直さない。
    ///
    /// [#3945]: https://github.com/mokume-metal/mokume/issues/3945
    @Test("止まった作品へ後から繋いでも今の 1 枚が届き、1 回だけ描き直して止まるとその 1 枚が届く。同じ絵は写し直さない")
    func aStillSketchReachesItsReceivers() throws {
        let facet = try TestScratch.directory("mokume-viewport")
        let gpu = try RenderDevice()
        let child = try makeChild(in: facet, gpu: gpu)
        try draw(child, .linear(red: 1, green: 0, blue: 0), gpu: gpu)
        let watched = try watch(facet: facet, gpu: gpu)
        defer { watched.close() }

        // 繋いだ後、子は 1 枚も描かない
        var submitted = gpu.submissionCount
        let late = watched.refresh(10)
        #expect(late.count == 1, "止まった作品の今の 1 枚が後から繋いだ受け手へ届かない: \(late)")
        #expect(late.allSatisfy { $0 > 0 }, "番号 0 の絵を渡した: \(late)")
        #expect(gpu.submissionCount - submitted == 1, "同じ絵を写し直した (写しの投入 \(gpu.submissionCount - submitted) 回)")
        #expect(watched.receiver.lastPixel().map { $0[0] > $0[1] } == true, "今の絵 (赤) でない: \(String(describing: watched.receiver.lastPixel()))")

        // 1 回だけ描き直して、また止まる
        try draw(child, .linear(red: 0, green: 1, blue: 0), gpu: gpu)
        submitted = gpu.submissionCount
        let redrawn = watched.refresh(10)
        #expect(redrawn.count == 1, "描き直した 1 枚が届かない: \(redrawn)")
        #expect(gpu.submissionCount - submitted == 1, "同じ絵を写し直した (写しの投入 \(gpu.submissionCount - submitted) 回)")
        #expect(watched.receiver.lastPixel().map { $0[1] > $0[0] } == true, "描き直した絵 (緑) でない: \(String(describing: watched.receiver.lastPixel()))")
        #expect((late + redrawn) == (late + redrawn).sorted() && Set(late + redrawn).count == 2, "\(late + redrawn)")
    }

    /// **台に出せる絵が無いリフレッシュでも、写した絵の GPU の完了を受け手へ知らせる** (#3945)。子が絵を出さなく
    /// なっても (面が引けない間など)、最後に写した 1 枚は次の絵を待たずに届く。
    @Test("絵が無いリフレッシュでも、写した絵の GPU の完了を受け手へ知らせる")
    func aCopyIsAnnouncedOnARefreshWithoutAFrame() throws {
        let directory = try TestScratch.directory("mokume-frames")
        let gpu = try RenderDevice()
        let listing = WatchFrameListing(identity: "/work/Bricks", gpu: gpu) { identity, share in
            FrameAnnouncement.announce(
                sketch: share.sketch, identity: identity, title: share.title, in: directory,
                warn: { Issue.record("名乗れなかった: \($0)") })
        }
        listing.say = { _ in }
        defer { listing.withdraw() }
        listing.follow(FrameShare(sketch: "Bricks", title: "Bricks"))
        let texture = try childTexture(gpu: gpu)
        listing.handOver(texture, isNew: true)  // 送り手を起こす (受け手はまだ居ない)
        let sender = try #require(listing.announcement?.sender)
        let service = try #require(listing.announcement.flatMap { Bootstrap.lookUp($0.entry.serviceName) })
        defer { Bootstrap.releaseSend(service) }
        let receiver = try ReceiverForWatch(width: 16, height: 8, service: service)
        defer { receiver.close() }
        sender.drain()
        listing.handOver(texture, isNew: true)  // 写す。完了は次のリフレッシュで見る
        _ = gpu.droppedWork(after: 0, through: gpu.submissionCount)
        #expect(receiver.takeFrames().isEmpty, "前提: 写した回には知らせない (GPU を待たない)")

        listing.handOver(nil, isNew: false)
        #expect(receiver.takeFrames().count == 1, "絵が無いリフレッシュで、写した絵の完了を知らせない")
    }

    /// **子の番号は子ごとに 1 から数える** ([#3948])。保存の前後の子がどちらも 3 枚目で止まっても、新しい世代の絵を
    /// 受け手へ渡す。
    ///
    /// [#3948]: https://github.com/mokume-metal/mokume/issues/3948
    @Test("保存の前後の子が同じ番号で止まっても、新しい世代の絵を受け手へ渡す")
    func aNewGenerationWithTheSameFrameNumberIsHandedOver() throws {
        let facet = try TestScratch.directory("mokume-viewport")
        let gpu = try RenderDevice()
        let before = try makeChild(in: facet, gpu: gpu)
        for _ in 0..<3 { try draw(before, .linear(red: 1, green: 0, blue: 0), gpu: gpu) }
        let watched = try watch(facet: facet, gpu: gpu)
        defer { watched.close() }
        let first = watched.refresh(5)
        #expect(first.count == 1, "\(first)")

        // 保存で子が入れ替わり、台が次に見るまでに新しい子が 3 枚描いて止まる
        let after = try makeChild(in: facet, gpu: gpu, offset: 5)
        for _ in 0..<3 { try draw(after, .linear(red: 0, green: 1, blue: 0), gpu: gpu) }
        let handed = watched.refresh(10)
        #expect(handed.count == 1, "新しい世代の絵を渡さない: \(handed)")
        #expect(watched.receiver.lastPixel().map { $0[1] > $0[0] } == true, "新しい世代の絵 (緑) でない: \(String(describing: watched.receiver.lastPixel()))")
        #expect(handed.allSatisfy { $0 > first.max() ?? 0 }, "道具の番号が進んでいない: \(first) → \(handed)")
        _ = before
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
    /// 最後に届いた frame の面。
    private(set) var lastSlot: Int?

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
            lastSlot = Int(slot)
            var payload = FrameLink.Payload()
            payload.append(receiver)
            payload.append(slot)
            FrameLink.send(.release, to: service, payload: payload)
        }
        return counts
    }

    /// 最後に届いた frame の面の真ん中の 1 画素 (半精度 4 成分)。まだ届いていなければ `nil`。面は返した後も読める
    /// (送り手は次に書くまで触らない)。
    func lastPixel() -> [Float]? {
        guard let lastSlot else { return nil }
        let surface = surfaces[lastSlot]
        IOSurfaceLock(surface, .readOnly, nil)
        defer { IOSurfaceUnlock(surface, .readOnly, nil) }
        let base = IOSurfaceGetBaseAddress(surface)
        let offset = (IOSurfaceGetHeight(surface) / 2) * IOSurfaceGetBytesPerRow(surface)
            + (IOSurfaceGetWidth(surface) / 2) * 8
        let components = base.advanced(by: offset).assumingMemoryBound(to: Float16.self)
        return (0..<4).map { Float(components[$0]) }
    }

    func close() {
        mach_port_mod_refs(mach_task_self_, port, MACH_PORT_RIGHT_RECEIVE, -1)
    }
}
