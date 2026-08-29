// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Metal
import MokumeDiagnostics

/// GPU 側の一式を束ねる — デバイス・コマンドの発行口・コマンドの置き場・リソースの常駐。
///
/// ## なぜ常駐をここに集めるのか
///
/// この世代の Metal では、コマンドが触るリソースを常駐させるのは呼び出し側の責務で、
/// 常駐していないリソースを読むと結果が未定義になる。**常駐の管理を各所に散らすと
/// 「バインドしたのに描かれない」形の、症状からは原因の見えない失敗になる。**
/// そこで確保したリソースは必ずここを通し、常駐の集合をこの型が 1 つだけ持つ。
///
/// ## 使い方
///
/// ```swift
/// let gpu = try RenderDevice()
/// let commands = try gpu.beginCommands()
/// // …commands へ書き込む…
/// try gpu.commitAndWait(commands)
/// ```
///
/// ``commitAndWait(_:)`` は GPU の完了まで呼び出し元を止める。フレームを回す経路では
/// なく、1 枚だけ描く経路と検証で使う形である。
public final class RenderDevice {
    /// GPU が完了するのを待つ上限 (秒)。
    ///
    /// 待ちが返らないときに永久に止まらないための上限で、**検証がこの値そのものを
    /// 物差しにできるよう**定数で持つ (壁時計の絶対値をテストに書かない)。
    public static let waitLimitSeconds = 5

    /// この実行環境で描画の土台を組み立てられるか。
    ///
    /// **GPU があるかだけでは足りない。** 仮想化された実行環境には、GPU としては
    /// 見えるのにこの世代のコマンド構造に対応していないものがあり、そこでは
    /// コマンドの発行口が作れない。[ADR-0009] 決定 2 により旧世代へのフォールバック
    /// 経路は持たないので、そういう環境では描画そのものが成立しない。
    ///
    /// 判定を「実際に必要なところまで試す」形にしてあるのは、GPU の有無だけを見て
    /// 「使える」と答えると、GPU を要する検証がスキップされずに失敗するため。
    ///
    /// 隔離の外から呼べる形にしてあるのは、検査の実行可否を決める前提条件として
    /// 隔離の外で評価されるため。問い合わせは GPU を持ち出さないので状態を跨がない。
    ///
    /// [ADR-0009]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0009-platform-floor-and-toolchain.md
    public nonisolated static var isAvailable: Bool {
        guard let device = MTLCreateSystemDefaultDevice() else { return false }
        return device.makeMTL4CommandQueue() != nil
    }

    let device: any MTLDevice
    let queue: any MTL4CommandQueue

    /// コマンドの置き場ひとつぶん。
    ///
    /// 置き場は巻き戻して使い回すが、**巻き戻してよいのは、そこへ積んだコマンドを
    /// GPU が終えてから**である。だから「最後にここから投入した番号」を憶えておく。
    private struct Slot {
        let allocator: any MTL4CommandAllocator
        /// この置き場から最後に投入したコマンドの番号。まだ無ければ 0。
        var submission: UInt64 = 0
    }

    /// 置き場の環。
    ///
    /// 1 本を毎回巻き戻す形は、**待たない経路が 1 つでもあると壊れる** — 表示の経路
    /// (``commit(_:signalling:)``) は GPU の完了を待たないので、次の
    /// ``beginCommands()`` がまだ実行中のコマンドの載った置き場を巻き戻していた
    /// ([#222](https://github.com/mokume-metal/mokume/issues/222))。環にして 1 周ぶん
    /// 遅らせ、それでも終わっていなければ待つ。
    private var slots: [Slot]
    /// 次に使う置き場。
    private var nextSlot = 0
    /// 組み立て中のコマンドが、どの置き場に載っているか。
    ///
    /// 投入のときに番号を書き戻す先を引くために持つ。同時に複数本を組み立てても
    /// 取り違えないよう、コマンドそのものを鍵にする。
    private var slotOfOpenCommands: [ObjectIdentifier: Int] = [:]

    /// 環の既定の本数。
    ///
    /// 描画・読み戻し・表示で 1 フレームあたり 2〜3 本使うので、3 本あれば
    /// 巻き戻す番が回ってくる頃には 1 フレームぶん前の仕事になっている。**正しさは
    /// 本数に依らない** (足りなければ待つ) ので、ここは速さのための値である。
    static let defaultSlotCount = 3

    /// 診断: 実行中のコマンドが載った置き場を巻き戻した回数。**常に 0 でなければならない。**
    private(set) var resetsWhileInFlight = 0
    /// 診断: 置き場が空くのを待った回数。
    private(set) var slotWaits = 0

    /// 常駐させるリソースの集合。この型を通して確保したものがすべて入る。
    let residencySet: any MTLResidencySet

    /// GPU の完了を知るための合図。投入のたびに 1 つ進める。
    private let completion: any MTLSharedEvent
    private var submissionCount: UInt64 = 0

    /// 既定の GPU で作る。
    public convenience init() throws(RenderFailure) {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw .deviceUnavailable
        }
        try self.init(device: device)
    }

    /// GPU を指定して作る。
    public convenience init(device: any MTLDevice) throws(RenderFailure) {
        try self.init(device: device, slotCount: RenderDevice.defaultSlotCount)
    }

    /// 置き場の本数を指定できる入口 (検査用)。
    ///
    /// 1 本にすると「待たない経路の直後に必ず同じ置き場が回ってくる」形になり、
    /// 環が実際に待っていることを検査から確かめられる。
    init(device: any MTLDevice, slotCount: Int) throws(RenderFailure) {
        self.device = device

        guard let queue = device.makeMTL4CommandQueue() else {
            throw .commandQueueUnavailable
        }
        self.queue = queue

        var slots: [Slot] = []
        for _ in 0..<max(1, slotCount) {
            guard let allocator = device.makeCommandAllocator() else {
                throw .commandAllocatorUnavailable
            }
            slots.append(Slot(allocator: allocator))
        }
        self.slots = slots

        let residencyDescriptor = MTLResidencySetDescriptor()
        residencyDescriptor.label = "mokume.residency"
        let residencySet: any MTLResidencySet
        do {
            residencySet = try device.makeResidencySet(descriptor: residencyDescriptor)
        } catch {
            throw .residencySetUnavailable(reason: error.localizedDescription)
        }
        self.residencySet = residencySet
        queue.addResidencySet(residencySet)

        guard let completion = device.makeSharedEvent() else {
            throw .synchronizationUnavailable
        }
        self.completion = completion
    }

    // MARK: - リソース

    /// リソースを常駐させる。確保したリソースは必ずここを通す。
    ///
    /// 常駐は集合への追加だけでは効かず、追加のあとに確定させる必要がある。
    /// 呼ぶたびに確定させるので、確保の直後に 1 回呼べばよい。
    func makeResident(_ allocation: any MTLAllocation) {
        residencySet.addAllocation(allocation)
        residencySet.commit()
        residencySet.requestResidency()
    }

    /// 描画先にできるテクスチャを確保して常駐させる。
    func makeTexture(descriptor: MTLTextureDescriptor) throws(RenderFailure) -> any MTLTexture {
        guard let texture = device.makeTexture(descriptor: descriptor) else {
            throw .textureUnavailable(width: descriptor.width, height: descriptor.height)
        }
        makeResident(texture)
        return texture
    }

    /// CPU から読める領域を確保して常駐させる。
    func makeReadableBuffer(byteCount: Int) throws(RenderFailure) -> any MTLBuffer {
        guard let buffer = device.makeBuffer(length: byteCount, options: .storageModeShared) else {
            throw .bufferUnavailable(byteCount: byteCount)
        }
        makeResident(buffer)
        return buffer
    }

    /// 領域の上にテクスチャを載せるときの、1 行あたりのバイト数。
    ///
    /// 行の先頭が揃っていないとテクスチャを載せられない。**幅を切り上げるのではなく
    /// 行の間隔を広げる**ので、どんな幅でも載せられる — 幅を切り上げると、利用者の
    /// 指定した大きさと描かれる大きさが食い違う。
    func alignedBytesPerRow(_ natural: Int) -> Int {
        let alignment = device.minimumLinearTextureAlignment(for: RenderTarget.pixelFormat)
        guard alignment > 1 else { return natural }
        return (natural + alignment - 1) / alignment * alignment
    }

    /// CPU から読める領域の上にテクスチャを載せて確保する。
    ///
    /// こうして作ったテクスチャへ描くと、結果は**同じメモリ**に現れる。写しを取らずに
    /// CPU から読めるのはこのためで、統一メモリの機械でしか成立しない ([ADR-0009])。
    ///
    /// **同じメモリでも、常駐は置き場とテクスチャで別々に数えられる。** 置き場を通した
    /// だけでは足りず、載せたテクスチャも通す — 通し忘れると検証レイヤが「どの residency
    /// set にも入っていない」と言う ([#351])。絵は普段どおり出てしまうので、症状からは
    /// 見つからない。
    ///
    /// [ADR-0009]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0009-platform-floor.md
    /// [#351]: https://github.com/mokume-metal/mokume/issues/351
    func makeBufferBackedTexture(
        descriptor: MTLTextureDescriptor, bytesPerRow: Int
    ) throws(RenderFailure) -> (texture: any MTLTexture, storage: any MTLBuffer) {
        let storage = try makeReadableBuffer(byteCount: bytesPerRow * descriptor.height)
        guard
            let texture = storage.makeTexture(
                descriptor: descriptor, offset: 0, bytesPerRow: bytesPerRow)
        else {
            throw .textureUnavailable(width: descriptor.width, height: descriptor.height)
        }
        makeResident(texture)
        return (texture, storage)
    }

    // MARK: - コマンド

    /// コマンドを 1 本組み立て始める。
    ///
    /// 環から次の置き場を取り、**そこへ積んだ前回のコマンドが終わっていなければ待つ**。
    func beginCommands() throws(RenderFailure) -> any MTL4CommandBuffer {
        let index = nextSlot
        nextSlot = (nextSlot + 1) % slots.count

        try waitForSlot(index)
        if slots[index].submission > 0, completion.signaledValue < slots[index].submission {
            // ここに来たら、待ちの規律が壊れている。数えて検査から読めるようにする
            resetsWhileInFlight += 1
        }
        slots[index].allocator.reset()

        guard let commands = device.makeCommandBuffer() else {
            throw .commandBufferUnavailable
        }
        commands.beginCommandBuffer(allocator: slots[index].allocator)
        slotOfOpenCommands[ObjectIdentifier(commands)] = index
        return commands
    }

    /// 指定した置き場から投入したコマンドが終わるまで待つ。
    private func waitForSlot(_ index: Int) throws(RenderFailure) {
        let pending = slots[index].submission
        guard pending > 0, completion.signaledValue < pending else { return }

        slotWaits += 1
        let limit = UInt64(Self.waitLimitSeconds * 1000)
        guard completion.wait(untilSignaledValue: pending, timeoutMS: limit) else {
            Diagnostics.warn(
                "コマンドの置き場が空くのを \(Self.waitLimitSeconds) 秒待っても返りませんでした")
            throw .timedOut(seconds: Self.waitLimitSeconds)
        }
    }

    /// 投入に番号を振り、合図を出し、置き場へ書き戻す。
    ///
    /// **待つ経路も待たない経路も必ずここを通す。** 通さない経路があると、その置き場は
    /// 「終わったかどうか分からないまま巻き戻してよい」ことになってしまう。
    @discardableResult
    private func recordSubmission(of commands: any MTL4CommandBuffer) -> UInt64 {
        submissionCount += 1
        queue.signalEvent(completion, value: submissionCount)
        if let index = slotOfOpenCommands.removeValue(forKey: ObjectIdentifier(commands)) {
            slots[index].submission = submissionCount
        }
        return submissionCount
    }

    /// 組み立てたコマンドを投入し、GPU が終わるまで待つ。
    func commitAndWait(_ commands: any MTL4CommandBuffer) throws(RenderFailure) {
        commands.endCommandBuffer()
        queue.commit([commands])

        let submission = recordSubmission(of: commands)

        let limit = UInt64(Self.waitLimitSeconds * 1000)
        guard completion.wait(untilSignaledValue: submission, timeoutMS: limit) else {
            // **黙って捨てない。** 詰まったことが分からないと、症状 (絵が止まる・
            // 観測が遅い) から原因へ辿る手がかりが 1 つも残らない
            Diagnostics.warn(
                "GPU の完了を \(Self.waitLimitSeconds) 秒待っても返りませんでした。このフレームは捨てます")
            throw .timedOut(seconds: Self.waitLimitSeconds)
        }
    }
}

extension RenderDevice {
    /// 同梱したシェーダを読み込む。
    ///
    /// シェーダの原文は資源として運ばれ、ここで組み立てる — この道具立てでは原文を
    /// ビルドに含める手がないため。**原文の誤りはここまで来ないと分からない**ので、
    /// `make ci-check` が別途ビルド時に組み立てて落とす (`scripts/check-shaders.sh`)。
    func makeLibrary(named name: String) throws(RenderFailure) -> any MTLLibrary {
        let source = try bundledShaderSource(named: name)
        do {
            return try device.makeLibrary(source: source, options: nil)
        } catch {
            throw .shaderCompilationFailed(
                name: "\(name).metal", reason: error.localizedDescription)
        }
    }

    /// 図形を塗る断片を、共通部分を前置きしてから組み立てる。
    ///
    /// **前置きは無条件。** 断片が既に宣言を持っているかは見ない (ShaderSource を参照)。
    func makeShapeLibrary(
        named name: String, body: String, values: [String: ShaderValue] = [:]
    ) throws(RenderFailure) -> any MTLLibrary {
        let common = try bundledShaderSource(named: "Common")
        let source = ShaderSource.assemble(common: common, values: values, body: body)
        do {
            return try device.makeLibrary(source: source, options: nil)
        } catch {
            throw .shaderCompilationFailed(
                name: name, reason: error.localizedDescription)
        }
    }

    /// 同梱している断片を読む。
    func bundledShaderSource(named name: String) throws(RenderFailure) -> String {
        guard let url = Bundle.module.url(forResource: name, withExtension: "metal"),
            let source = try? String(contentsOf: url, encoding: .utf8)
        else {
            throw .shaderSourceMissing(name: "\(name).metal")
        }
        return source
    }
}

extension RenderDevice {
    /// 表示に使う面が空くのを待つよう予約する。差し出す面へ書く前に呼ぶ。
    func waitForDrawable(_ drawable: any MTLDrawable) {
        queue.waitForDrawable(drawable)
    }

    /// 組み立てたコマンドを投入し、**GPU の完了を待たずに**表示の合図を出す。
    ///
    /// 待たないのは、待てば表示のたびに CPU が止まり、フレームレートが GPU の
    /// 往復に縛られるため。差し出す面の同期は Metal 側の合図で足りる。
    ///
    /// **待たなくても番号は進める。** 進めないと、この経路で使った置き場だけが
    /// 「いつ終わったか分からない」まま環へ戻り、次の巻き戻しが実行中のコマンドを
    /// 踏む ([#222](https://github.com/mokume-metal/mokume/issues/222))。
    func commit(_ commands: any MTL4CommandBuffer, signalling drawable: any MTLDrawable) {
        commands.endCommandBuffer()
        queue.commit([commands])
        recordSubmission(of: commands)
        queue.signalDrawable(drawable)
    }
}
