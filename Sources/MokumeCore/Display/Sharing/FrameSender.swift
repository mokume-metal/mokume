// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import CoreGraphics
import Darwin
import Foundation
import IOSurface
import Metal
import MokumeDiagnostics

/// 繋いできた受け手の面へ、繋がっている間だけ絵を書く送り手 ([ADR-0049] 決定 3・4・[#3920])。
///
/// 名乗り (``FrameAnnouncement``) が登録した受信の port で受け手の頼みを受け、受け手ごとに面を持つ。毎フレーム
/// ``deliver(width:height:frameCount:hostTime:write:)`` で、空いた面へ書いて GPU の完了を確かめてから知らせる。
///
/// ## 送り手は受け手を待たない
///
/// - 面が届くまでは写しも送りもしない (受け手 0 なら描く大きさを覚えるだけで返る。繋がっていない間の費用はこれだけ・
///   #3946)
/// - 受け手が面を全部掴んでいるフレームは書かずに見送り、その枚数を数える (``skippedFrames``)
/// - 送りは待ち時間 0 (``FrameLink``)。受け手が読まずに待ち行列が埋まっていれば、その面は書かなかったことにして
///   空きへ戻す。落ちた大きさの変更は、以後のリフレッシュで最新の大きさの `resized` を送り直す (#3947)
/// - GPU の完了は待たない。結末が届いていない焼きは次のフレームで知らせる (`RenderDevice.undelivered(_:)`)
///
/// ## 受け手が消えたら外す
///
/// 受け手を受け入れたとき、その port に dead-name の知らせを頼む。知らせ (または disconnect) が来たら、その受け手の
/// 面を手放して外す。**頼めない (返信先が既に死んでいる) connect は受け入れない** (#3968)。時計は使わない。
///
/// [ADR-0049]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0049-share-frames-to-other-processes.md
/// [#3920]: https://github.com/mokume-metal/mokume/issues/3920
package final class FrameSender {
    /// 受け入れた受け手 1 つ。
    private final class Receiver {
        let id: UInt32
        /// 受け手が名乗った名前。メニューバーの名乗りと診断に出す。
        let name: String
        /// 受け手の port (送信の権利)。
        let port: mach_port_t
        var surfaces: [HandedSurface]
        /// 書いてから返されるまでの面。
        var held: [Bool]
        /// 書いて、まだ知らせていない焼き。
        var pending: [(slot: Int, submission: UInt64, frameCount: Int64, writes: Int64, hostTime: UInt64)] = []
        /// 面へ書いた回数。
        var writes: Int64 = 0
        /// 最後に書いたフレームの番号。同じ番号の絵を 2 度書かない。**書いた絵を GPU が打ち切ったら戻す** —
        /// 止まった作品では次の番号が来ないので、戻さないと受け手は今の絵を受け取れない (#3945)。
        var lastFrameCount: Int64?
        /// 面が全部掴まれていて見送ったフレームの番号。同じ番号を何度呼ばれても 1 枚と数える。
        var lastSkippedFrameCount: Int64?
        /// 大きさの変更を知らせ損ねている (待ち行列が埋まっていた)。送れるまで、以後のリフレッシュで最新の大きさを
        /// 送り直す。繋ぎ直しを受け入れたら下ろす (`accepted` が大きさを運ぶ・#3947)。
        var owesResized = false

        init(id: UInt32, name: String, port: mach_port_t, surfaces: [HandedSurface]) {
            self.id = id
            self.name = name
            self.port = port
            self.surfaces = surfaces
            self.held = Array(repeating: false, count: surfaces.count)
        }
    }

    private let gpu: RenderDevice
    /// 名乗りの受信の port。**持ち主は名乗り** (``FrameAnnouncement``) で、ここでは手放さない。
    let port: mach_port_t
    /// いまの面の大きさ (描く解像度)。
    package private(set) var width: Int
    package private(set) var height: Int
    /// 面に載せる色空間の名前。道具は子の面の値を写す。
    package var colorSpace = CGColorSpace.extendedLinearDisplayP3 as String
    /// 面に載せる alpha の扱い。
    package var alpha = "premultiplied"
    /// 人へ 1 行伝える口。**検査から差し替える。**
    package var warn: (String) -> Void = { Diagnostics.warn($0) }
    /// 繋がっている相手の名前が変わったときの知らせ (受け入れた・外した)。メニューバーの名乗りに出す
    /// ([ADR-0049] 決定 6・#3921)。
    package var onReceiversChanged: (([String]) -> Void)?
    /// 描く解像度が変わったときの知らせ (新しい幅・高さ)。名乗りが目録の大きさを書き換える (#3949)。**受け手へ知らせる前、
    /// 次の頼みを捌く前に呼ぶ** — 新しい大きさで断った受け手が目録を読み直したとき、もう新しい大きさが載っている。
    package var onResize: ((Int, Int) -> Void)?

    /// 繋がっている相手の名前 (繋いだ順)。
    package var receiverNames: [String] { receivers.map(\.name) }

    private var receivers: [Receiver] = []
    private var nextID: UInt32 = 1
    private var source: (any DispatchSourceMachReceive)?

    /// 受け手が面を全部掴んでいて、書かずに見送ったフレームの数 (受け手ごとに 1 と数える。作ってから通算)。
    package private(set) var skippedFrames = 0
    /// 知らせた (frame を送れた) 回数 (作ってから通算)。
    package private(set) var deliveredFrames = 0

    /// 繋がっている受け手の数。
    package var receiverCount: Int { receivers.count }

    init(gpu: RenderDevice, port: mach_port_t, width: Int, height: Int) {
        self.gpu = gpu
        self.port = port
        self.width = width
        self.height = height
    }

    // MARK: - 受け口

    /// 頼みを main queue で受け始める。**検査は呼ばずに ``drain()`` を直に呼ぶ。**
    package func start() {
        guard source == nil else { return }
        let source = DispatchSource.makeMachReceiveSource(port: port, queue: .main)
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.drain() }
        }
        source.resume()
        self.source = source
    }

    /// 受け口を畳み、すべての受け手を外す。**受信の port は手放さない** (持ち主は名乗り)。
    package func stop() {
        source?.cancel()
        source = nil
        let cut = receivers
        receivers.removeAll()
        for receiver in cut {
            forget(receiver)
            warn("Stopped handing this sketch's frames to \(receiver.name)")
        }
        if !cut.isEmpty { onReceiversChanged?([]) }
    }

    /// 届いている頼みをすべて捌く。待たない。
    package func drain() {
        while let received = FrameLink.receive(on: port) {
            handle(received)
        }
    }

    private func handle(_ received: FrameLink.Received) {
        if received.kind == FrameLink.deadNameID {
            if let name = FrameLink.deadName(in: received) { removeReceiver(port: name) }
            return
        }
        switch FrameLink.Kind(rawValue: received.kind) {
        case .connect?: connect(received)
        case .release?:
            var reader = received.payload.reader
            guard let id = reader.uint32(), let slot = reader.uint32(),
                let receiver = receivers.first(where: { $0.id == id }), Int(slot) < receiver.held.count
            else { return }
            receiver.held[Int(slot)] = false
        case .disconnect?:
            var reader = received.payload.reader
            guard let id = reader.uint32(), let receiver = receivers.first(where: { $0.id == id }) else { return }
            remove(receiver)
        default:
            // 知らない頼み・port の削除の知らせなど。届いた権利は手放す
            for name in received.ports { FrameLink.releaseName(name) }
        }
    }

    /// 繋ぐ頼みを検めて、受け入れるか断る。
    private func connect(_ received: FrameLink.Received) {
        guard let reply = received.ports.first else {
            for name in received.ports { FrameLink.releaseName(name) }
            return
        }
        let surfacePorts = Array(received.ports.dropFirst())
        // 面の port は引いたら手放す (面は IOSurface の参照で持つ)
        let surfaces = surfacePorts.map { name -> IOSurfaceRef? in
            defer { FrameLink.releaseName(name) }
            return IOSurfaceLookupFromMachPort(name)
        }
        var reader = received.payload.reader
        let version = reader.uint32()
        let name = reader.string(limit: FrameLink.nameLimit).flatMap { $0.isEmpty ? nil : $0 }
            ?? FrameLink.unnamedReceiver
        let existing = receivers.first { $0.port == reply }
        let refusal: FrameLink.Refusal? =
            if version != FrameLink.version {
                .version
            } else if !FrameLink.surfaceCountRange.contains(surfaces.count) {
                .surfaceCount
            } else if existing == nil, receivers.count >= FrameLink.receiverLimit {
                .receiverLimit
            } else if surfaces.contains(where: {
                $0.map { IOSurfaceGetPixelFormat($0) != FrameLink.surfaceFormat } ?? true
            }) {
                .surfaceFormat
            } else if surfaces.contains(where: {
                $0.map { IOSurfaceGetWidth($0) != width || IOSurfaceGetHeight($0) != height } ?? true
            }) {
                .surfaceSize
            } else {
                nil
            }
        if let refusal {
            refuse(reply, refusal, isKnown: existing != nil)
            return
        }
        var handed: [HandedSurface] = []
        do throws(RenderFailure) {
            for case let surface? in surfaces { handed.append(try HandedSurface(gpu: gpu, surface: surface)) }
        } catch {
            for surface in handed { surface.release(gpu: gpu) }
            refuse(reply, .surfaceFormat, isKnown: existing != nil)
            return
        }
        if let existing {
            // 同じ受け手が面を送り直した (大きさの変更の後)。届いた送信の権利は既に持っている名前に重なる
            FrameLink.releaseOneSend(reply)
            for surface in existing.surfaces { surface.release(gpu: gpu) }
            existing.surfaces = handed
            existing.held = Array(repeating: false, count: handed.count)
            existing.pending.removeAll()
            existing.lastFrameCount = nil
            // 受け入れが大きさを運ぶので、知らせ損ねた大きさの変更はもう要らない (#3947)
            // 受け入れが満杯で落ちたら、受け手が期限で立ち直る (`Schemas/frame-link.md`・#3968)
            existing.owesResized = false
            accept(existing)
            return
        }
        // **返信先が死んでいれば登録しない** (#3968)。受け手が答えを待ちきれずに port を捨てた後で、この connect を読んだ。
        // 死んだ返信先 (届いた名前が `MACH_PORT_DEAD`、または受けた後に死んだ名前) には dead-name の知らせを頼めない
        // (`KERN_INVALID_ARGUMENT`) ので、登録すると外す契機が無く、枠を握ったまま書き続ける。答えも送らない (届かない)
        var previous: mach_port_t = 0
        guard
            mach_port_request_notification(
                mach_task_self_, reply, MACH_NOTIFY_DEAD_NAME, 0, port,
                mach_msg_type_name_t(MACH_MSG_TYPE_MAKE_SEND_ONCE), &previous) == KERN_SUCCESS
        else {
            for surface in handed { surface.release(gpu: gpu) }
            FrameLink.releaseName(reply)
            return
        }
        let receiver = Receiver(id: nextID, name: name, port: reply, surfaces: handed)
        nextID &+= 1
        receivers.append(receiver)
        accept(receiver)
        // **繋がったことを 1 行言う** (ADR-0020 決定 5・ADR-0049 決定 6)
        warn("Handing this sketch's frames to \(name)")
        onReceiversChanged?(receiverNames)
    }

    private func accept(_ receiver: Receiver) {
        var payload = FrameLink.Payload()
        payload.append(receiver.id)
        payload.append(UInt32(width))
        payload.append(UInt32(height))
        FrameLink.send(.accepted, to: receiver.port, payload: payload)
    }

    private func refuse(_ reply: mach_port_t, _ refusal: FrameLink.Refusal, isKnown: Bool) {
        var payload = FrameLink.Payload()
        payload.append(refusal.rawValue)
        FrameLink.send(.refused, to: reply, payload: payload)
        warn("A receiver asked for this sketch's frames and was refused: \(refusal)")
        // 受け入れていない受け手の権利は持たない。受け入れ済みの受け手なら、重なった 1 つだけ返す
        if isKnown { FrameLink.releaseOneSend(reply) } else { FrameLink.releaseName(reply) }
    }

    private func removeReceiver(port name: mach_port_t) {
        if let receiver = receivers.first(where: { $0.port == name }) {
            remove(receiver)
        } else {
            FrameLink.releaseName(name)
        }
    }

    private func remove(_ receiver: Receiver) {
        receivers.removeAll { $0 === receiver }
        forget(receiver)
        warn("Stopped handing this sketch's frames to \(receiver.name)")
        onReceiversChanged?(receiverNames)
    }

    private func forget(_ receiver: Receiver) {
        for surface in receiver.surfaces { surface.release(gpu: gpu) }
        receiver.surfaces = []
        FrameLink.releaseName(receiver.port)
    }

    // MARK: - 書く

    /// 繋がっている受け手の面へ、1 フレームを書く。**受け手が居なければ、描く大きさを覚えるだけで写しも送りもしない**
    /// (#3946)。
    ///
    /// **表示のリフレッシュごとに呼んでよい** (#3945)。同じ番号の絵は受け手ごとに 1 度だけ書くので、止まった作品へ
    /// 後から繋いだ受け手には今の絵を 1 度書き、前に書いた絵の GPU の完了は呼ばれるたびに見て知らせる。
    ///
    /// - Parameters:
    ///   - width: いまの描く解像度。前と違えば、受け手に大きさの変更を知らせて面を手放す (``resize(width:height:)``)
    ///   - frameCount: フレームの番号。その受け手へ前に書いた番号と同じなら書かない (止まっている作品)
    ///   - hostTime: 描いた時刻
    ///   - write: 与えた面へ絵を書く投入をして、その番号を返す。待たない
    package func deliver(
        width: Int, height: Int, frameCount: Int64, hostTime: UInt64,
        write: (any MTLTexture) throws(RenderFailure) -> UInt64
    ) throws(RenderFailure) {
        // **大きさは受け手が居なくても覚える** (#3946)。覚えないと、後から新しい大きさの面で繋いだ受け手を
        // 古い大きさで断る。覚えるだけで写しはしない
        if width != self.width || height != self.height { resize(width: width, height: height) }
        guard !receivers.isEmpty else { return }
        for receiver in receivers {
            announce(receiver)
            guard receiver.lastFrameCount != frameCount, !receiver.surfaces.isEmpty else { continue }
            let busy = Set(receiver.pending.map(\.slot))
            guard let slot = receiver.held.indices.first(where: { !receiver.held[$0] && !busy.contains($0) })
            else {
                if receiver.lastSkippedFrameCount != frameCount {
                    receiver.lastSkippedFrameCount = frameCount
                    skippedFrames += 1
                }
                continue
            }
            let submission = try write(receiver.surfaces[slot].texture)
            receiver.writes += 1
            receiver.held[slot] = true
            receiver.lastFrameCount = frameCount
            receiver.pending.append((slot, submission, frameCount, receiver.writes, hostTime))
        }
    }

    /// 見張りの道具が、子の面の絵を受け手の面へ写す ([ADR-0049] 決定 2)。**焼き直さない** — 子が焼いた半精度の値を
    /// そのまま写す (ADR-0032 決定 2)。色空間と alpha の扱いも、子が面に載せた値を写す (載っていない古いライブラリの
    /// 子なら既定のまま)。
    ///
    /// - Parameters:
    ///   - source: 子の面のテクスチャ。常駐の集合に入っていること (台が入れている)。
    ///   - frameCount: 道具が数えるフレームの番号 (保存で子が入れ替わっても途切れない)。
    package func deliver(copying source: any MTLTexture, frameCount: Int64, hostTime: UInt64) throws(RenderFailure) {
        // 受け手が居なくても大きさは覚える (#3946・下の `deliver` の入口)。面の属性を読むのは居るときだけ
        if !receivers.isEmpty, let surface = source.iosurface {
            if let name = IOSurfaceCopyValue(surface, FrameLink.Attribute.colorSpace as CFString) as? String {
                colorSpace = name
            }
            if let name = IOSurfaceCopyValue(surface, FrameLink.Attribute.alpha as CFString) as? String {
                alpha = name
            }
        }
        try deliver(
            width: source.width, height: source.height, frameCount: frameCount, hostTime: hostTime
        ) { [gpu] destination throws(RenderFailure) in
            try gpu.withCommands { commands throws(RenderFailure) in
                guard let encoder = commands.makeComputeCommandEncoder() else { throw .encoderUnavailable }
                // この世代は encoder をまたぐ依存を自動では張らない (#341)。前の仕事が面を読み終わるのを待ち、写し終わるのを
                // 後の仕事が待つ (`Canvas+PreviousFrame.swift` と同じ)
                encoder.barrier(
                    afterQueueStages: [.dispatch, .fragment, .blit], beforeStages: .blit,
                    visibilityOptions: .device)
                encoder.copy(sourceTexture: source, destinationTexture: destination)
                encoder.barrier(
                    afterStages: .blit, beforeQueueStages: [.dispatch, .fragment, .blit],
                    visibilityOptions: .device)
                encoder.endEncoding()
                return gpu.commit(commands)
            }
        }
    }

    /// 書いた焼きのうち、GPU が無事に終えたものを知らせる。**書く絵が無いリフレッシュに呼ぶ** — 止まった作品でも、
    /// 最後に書いた絵を次の絵を待たずに知らせる (#3945)。待たない。
    package func announceCompleted() {
        for receiver in receivers { announce(receiver) }
    }

    /// 控えた焼きのうち、GPU が無事に終えたものを知らせる。結末がまだなら次へ回す。大きさの変更を知らせ損ねて
    /// いれば、先に送り直す (#3947)。
    private func announce(_ receiver: Receiver) {
        if receiver.owesResized { sendResized(to: receiver) }
        while let burn = receiver.pending.first {
            switch gpu.undelivered(burn.submission) {
            case nil:
                return
            case true?:
                // 打ち切られた焼きは知らせない (中身が揃っていない)。それが最後に書いた絵なら、同じ番号でも書き直す
                // (止まった作品では次の番号が来ない・#3945)
                receiver.pending.removeFirst()
                receiver.held[burn.slot] = false
                if receiver.lastFrameCount == burn.frameCount { receiver.lastFrameCount = nil }
            case false?:
                receiver.pending.removeFirst()
                let surface = receiver.surfaces[burn.slot].surface
                IOSurfaceSetValue(surface, FrameLink.Attribute.frameCount as CFString, NSNumber(value: burn.frameCount))
                IOSurfaceSetValue(surface, FrameLink.Attribute.writes as CFString, NSNumber(value: burn.writes))
                IOSurfaceSetValue(surface, FrameLink.Attribute.hostTime as CFString, NSNumber(value: burn.hostTime))
                IOSurfaceSetValue(surface, FrameLink.Attribute.colorSpace as CFString, colorSpace as CFString)
                IOSurfaceSetValue(surface, FrameLink.Attribute.alpha as CFString, alpha as CFString)
                var payload = FrameLink.Payload()
                payload.append(receiver.id)
                payload.append(UInt32(burn.slot))
                payload.append(burn.frameCount)
                payload.append(burn.writes)
                payload.append(burn.hostTime)
                if FrameLink.send(.frame, to: receiver.port, payload: payload) == KERN_SUCCESS {
                    deliveredFrames += 1
                } else {
                    // 受け手が読んでいない (待ち行列が埋まった)・消えた。知らせていない面は掴まれていない。それが最後に
                    // 書いた絵なら、後のリフレッシュで空いた面へ書き直す (止まった作品では次の番号が来ない・#3945)
                    receiver.held[burn.slot] = false
                    if receiver.lastFrameCount == burn.frameCount { receiver.lastFrameCount = nil }
                }
            }
        }
    }

    /// 描く解像度が変わった。受け手の面を手放し、新しい大きさを知らせる。受け手は面を作り直して繋ぎ直す。目録の大きさは
    /// ``onResize`` で、受け手へ知らせるより前に書き換わる (#3949)。
    ///
    /// **大きさは受け手の数と関係なく送り手の状態である** (#3946)。受け手が居なければ覚えるだけで、写しも送りもしない。
    /// **知らせは受け手に届くまで送り手の状態である** (#3947)。待ち時間 0 の送りが待ち行列の満杯で落ちたら、受け手ごとに
    /// 覚えて、以後のリフレッシュで最新の大きさを送り直す (``announce(_:)``)。受け手は新しい大きさを知るまで面を作り
    /// 直さない約束なので、落としたままにすると二度と繋ぎ直さない。
    package func resize(width: Int, height: Int) {
        guard width != self.width || height != self.height else { return }
        self.width = width
        self.height = height
        onResize?(width, height)
        for receiver in receivers {
            for surface in receiver.surfaces { surface.release(gpu: gpu) }
            receiver.surfaces = []
            receiver.held = []
            receiver.pending.removeAll()
            receiver.lastFrameCount = nil
            sendResized(to: receiver)
        }
    }

    /// いまの大きさを受け手へ知らせる。送れなければ ``Receiver/owesResized`` を立てたままにし、送れたら下ろす。待たない。
    private func sendResized(to receiver: Receiver) {
        var payload = FrameLink.Payload()
        payload.append(UInt32(width))
        payload.append(UInt32(height))
        receiver.owesResized = FrameLink.send(.resized, to: receiver.port, payload: payload) != KERN_SUCCESS
    }
}

/// 受け手が渡した面を、書けるテクスチャに包んだもの。
struct HandedSurface {
    let surface: IOSurfaceRef
    let texture: any MTLTexture

    /// 包む。**常駐の集合へ入れる** (`SharedFrameSurface` の面と同じ)。寸法の関所を通す。
    init(gpu: RenderDevice, surface: IOSurfaceRef) throws(RenderFailure) {
        let width = IOSurfaceGetWidth(surface)
        let height = IOSurfaceGetHeight(surface)
        try RenderDevice.checkTextureSize(width: width, height: height)
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: RenderTarget.pixelFormat, width: width, height: height, mipmapped: false)
        descriptor.usage = [.renderTarget, .shaderRead]
        guard let texture = gpu.device.makeTexture(descriptor: descriptor, iosurface: surface, plane: 0) else {
            throw .textureUnavailable(width: width, height: height)
        }
        gpu.makeResident(texture)
        self.surface = surface
        self.texture = texture
    }

    /// 手放す。常駐から外すのは、そのとき投入済みの仕事が終わってから (`RenderDevice.retire(_:)`)。
    func release(gpu: RenderDevice) {
        gpu.retire(texture)
    }
}
