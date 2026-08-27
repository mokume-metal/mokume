// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Metal

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

    /// コマンドの置き場。``commitAndWait(_:)`` が GPU の完了まで待つので、次の
    /// ``beginCommands()`` で使い回してよい (実行中の置き場を巻き戻すことはない)。
    private let allocator: any MTL4CommandAllocator

    /// 常駐させるリソースの集合。この型を通して確保したものがすべて入る。
    private let residencySet: any MTLResidencySet

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
    public init(device: any MTLDevice) throws(RenderFailure) {
        self.device = device

        guard let queue = device.makeMTL4CommandQueue() else {
            throw .commandQueueUnavailable
        }
        self.queue = queue

        guard let allocator = device.makeCommandAllocator() else {
            throw .commandAllocatorUnavailable
        }
        self.allocator = allocator

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

    // MARK: - コマンド

    /// コマンドを 1 本組み立て始める。
    func beginCommands() throws(RenderFailure) -> any MTL4CommandBuffer {
        allocator.reset()
        guard let commands = device.makeCommandBuffer() else {
            throw .commandBufferUnavailable
        }
        commands.beginCommandBuffer(allocator: allocator)
        return commands
    }

    /// 組み立てたコマンドを投入し、GPU が終わるまで待つ。
    func commitAndWait(_ commands: any MTL4CommandBuffer) throws(RenderFailure) {
        commands.endCommandBuffer()
        queue.commit([commands])

        submissionCount += 1
        queue.signalEvent(completion, value: submissionCount)

        let limit = UInt64(Self.waitLimitSeconds * 1000)
        guard completion.wait(untilSignaledValue: submissionCount, timeoutMS: limit) else {
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
        guard let url = Bundle.module.url(forResource: name, withExtension: "metal"),
            let source = try? String(contentsOf: url, encoding: .utf8)
        else {
            throw .shaderSourceMissing(name: "\(name).metal")
        }
        do {
            return try device.makeLibrary(source: source, options: nil)
        } catch {
            throw .shaderCompilationFailed(
                name: "\(name).metal", reason: error.localizedDescription)
        }
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
    func commit(_ commands: any MTL4CommandBuffer, signalling drawable: any MTLDrawable) {
        commands.endCommandBuffer()
        queue.commit([commands])
        queue.signalDrawable(drawable)
    }
}
