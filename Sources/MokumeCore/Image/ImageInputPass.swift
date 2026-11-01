// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Metal

/// 入力を既存の画像面へ直接描く (#1753)。全画素の中間 buffer は持たない。
/// shaderWrite を付けないので、未更新の画像でも使う Metal のロスレス圧縮を妨げない。
/// CPU が書く引数テーブルは Canvas のフレーム環に従い、画像ごと・段ごとに分ける。
@MainActor final class ImageInputPass {
    private let gpu: RenderDevice
    private let decodeState: any MTLRenderPipelineState
    private let surfaceState: any MTLRenderPipelineState
    private let patchState: any MTLRenderPipelineState
    private let lookup: any MTLBuffer
    private var tables: [ArgumentTablePool]
    /// 面に被せたテクスチャの持ち回し (#2962)。動画の読み手のプールは同じ面を巡らせるので、作って常駐させる
    /// のは初めて見た面だけにする — 毎フレーム作ると、作る・常駐の確定・外すを 1 枚ごとに main で払う。
    /// テクスチャは面の使用数を上げない (プールの使い回しを妨げない) が、面の記憶は抱えるので、しばらく
    /// 使わなかった面と上限を越えた古い面は手放す
    private var surfaceTextures: [(surface: IOSurface, texture: any MTLTexture, lastUse: UInt64)] = []
    /// 持ち回す面の数の上限。4K の動画 4 本のプール (1 本 6〜12 面) が収まる
    static let surfaceTextureLimit = 48
    /// この本数の投入のあいだ使わなかった面は手放す。止めた・閉じた動画の面を抱え続けない
    static let surfaceTextureIdleSubmissions: UInt64 = 120

    init(gpu: RenderDevice, slotCount: Int) throws(RenderFailure) {
        let library = try gpu.shaders.imageInputLibrary()
        let compiler = try gpu.shaders.compiler()
        func state(vertex: String, fragment: String) throws(RenderFailure)
            -> any MTLRenderPipelineState
        {
            let vertexFunction = MTL4LibraryFunctionDescriptor()
            vertexFunction.name = vertex
            vertexFunction.library = library
            let fragmentFunction = MTL4LibraryFunctionDescriptor()
            fragmentFunction.name = fragment
            fragmentFunction.library = library
            let descriptor = MTL4RenderPipelineDescriptor()
            descriptor.label = "mokume.image.\(fragment)"
            descriptor.vertexFunctionDescriptor = vertexFunction
            descriptor.fragmentFunctionDescriptor = fragmentFunction
            descriptor.colorAttachments[0]!.pixelFormat = .rgba16Float
            do {
                return try compiler.makeRenderPipelineState(descriptor: descriptor)
            } catch {
                throw .pipelineUnavailable(reason: error.localizedDescription)
            }
        }
        decodeState = try state(vertex: "imageInputVertex", fragment: "imageInputFragment")
        surfaceState = try state(vertex: "imageInputVertex", fragment: "imageSurfaceFragment")
        patchState = try state(vertex: "imagePatchVertex", fragment: "imagePatchFragment")
        let lookup = try gpu.makeReadableBuffer(byteCount: 512 * MemoryLayout<Float>.stride)
        // アルファも CPU と同じ丸めの表を使う。Metal の高速な除算近似に任せない。
        let values = OutputStage.decodeLinear + (0...255).map { Float($0) / 255 }
        values.withUnsafeBytes { source in
            lookup.contents().copyMemory(from: source.baseAddress!, byteCount: source.count)
        }
        lookup.label = "mokume.image.decode.lookup"
        self.lookup = lookup
        self.gpu = gpu
        tables = (0..<slotCount).map {
            ArgumentTablePool(
                gpu: gpu, label: "mokume.image.input.\($0)", bufferBindCount: 3, textureBindCount: 1)
        }
    }

    isolated deinit {
        gpu.retire(lookup)
        for entry in surfaceTextures { gpu.retire(entry.texture) }
    }

    /// 面の入力を GPU が読む準備。面に被せたテクスチャと、色の表の置き場。
    struct SurfaceSource {
        let texture: any MTLTexture
        let table: any MTLBuffer
        let lease: SurfaceLease
    }

    /// 面の入力を読む準備をする。**作れなければ `nil`** — 呼び手はその 1 枚だけを CPU で届ける
    /// (表を CPU で引く)。他の絵の GPU の変換は止めない。
    func surfaceSource(for surface: PixelSurface) -> SurfaceSource? {
        guard let texture = surfaceTexture(for: surface.lease.surface),
            let table = try? gpu.colorTableBuffer(for: surface.conversion)
        else { return nil }
        return SurfaceSource(texture: texture, table: table, lease: surface.lease)
    }

    /// 面に被せた常駐済みのテクスチャ。持ち回しに無ければ作って常駐させる。
    ///
    /// 鍵は面そのもの (`===`)。持ち回しのテクスチャが面を抱えるので、同じ番地に別の面が来ることはない。
    private func surfaceTexture(for surface: IOSurface) -> (any MTLTexture)? {
        let now = gpu.submissionCount
        if let index = surfaceTextures.firstIndex(where: { $0.surface === surface }) {
            surfaceTextures[index].lastUse = now
            return surfaceTextures[index].texture
        }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm, width: surface.width, height: surface.height, mipmapped: false)
        // 読むだけ。`storageMode` は面が決めるので触らない
        descriptor.usage = .shaderRead
        guard let texture = gpu.device.makeTexture(descriptor: descriptor, iosurface: surface, plane: 0) else {
            return nil
        }
        gpu.makeResident(texture)
        surfaceTextures.append((surface, texture, now))
        if surfaceTextures.count > Self.surfaceTextureLimit,
            let oldest = surfaceTextures.indices.min(by: { surfaceTextures[$0].lastUse < surfaceTextures[$1].lastUse })
        {
            gpu.retire(surfaceTextures.remove(at: oldest).texture)
        }
        return texture
    }

    /// 持ち回している面のテクスチャの数 (検査が読む)。
    var surfaceTextureCount: Int { surfaceTextures.count }

    /// しばらく使わなかった面のテクスチャを手放す。届けるものが無いフレームも含めて、毎フレーム呼ぶ。
    func forgetIdleSurfaces() {
        guard !surfaceTextures.isEmpty else { return }
        let now = gpu.submissionCount
        surfaceTextures.removeAll { entry in
            guard now - entry.lastUse > Self.surfaceTextureIdleSubmissions else { return false }
            gpu.retire(entry.texture)
            return true
        }
    }

    /// 失敗しうる準備をすべて済ませてから積む。失敗時は呼び手が従来の CPU 経路へ戻す。
    ///
    /// - Parameter source: 面の入力を変換するときの準備 (``surfaceSource(for:)``)。8 bit の並びの入力と、
    ///   編集だけを届けるときは `nil`。
    func stage(
        _ image: Image, source: SurfaceSource?, into bytes: UnsafeMutableRawPointer, of staging: any MTLBuffer,
        at offset: Int, slot: Int, index: Int, in commands: any MTL4CommandBuffer
    ) throws(RenderFailure) -> UInt64 {
        let decodeTable = try tables[slot].table(at: index * 2)
        let patchTable = try tables[slot].table(at: index * 2 + 1)
        let picture = image.displayInput
        let rawByteCount = image.inputNeedsDecode ? picture?.bytes.count ?? 0 : 0
        let patchOffset = (rawByteCount + 7) & ~7
        let sizeOffset = patchOffset + image.inputPatches.count * 16
        // 予約は従来の半精度全画素と同じ。少数編集を足しても容量の倍増を起こさない。
        precondition(sizeOffset + 8 <= image.pendingUploadByteCount)
        let pass = MTL4RenderPassDescriptor()
        pass.colorAttachments[0]!.texture = image.texture
        pass.colorAttachments[0]!.loadAction = image.inputNeedsDecode ? .dontCare : .load
        pass.colorAttachments[0]!.storeAction = .store
        guard let encoder = commands.makeRenderCommandEncoder(descriptor: pass) else {
            throw .encoderUnavailable
        }
        // 前の仕事が画像を読み終わるのを待つ。この世代は encoder をまたぐ依存を自動では張らない
        // (#341)。書き換えた画像の面へ書くので、前のフレームの読みと重ねない
        encoder.barrier(
            afterQueueStages: [.dispatch, .fragment, .blit], beforeStages: [.vertex, .fragment],
            visibilityOptions: .device)
        bytes.storeBytes(
            of: SIMD2(UInt32(image.width), UInt32(image.height)), toByteOffset: sizeOffset,
            as: SIMD2<UInt32>.self)
        encoder.setViewport(MTLViewport(
            originX: 0, originY: 0, width: Double(image.width), height: Double(image.height),
            znear: 0, zfar: 1))
        if image.inputNeedsDecode, let source {
            // 面を読む。面と表は、この投入が終わるまで持つ (面は使用中の印ごと持つので、置き場に使い回されない)。
            // テクスチャは持ち回しが常駐させている
            decodeTable.setTexture(source.texture.gpuResourceID, index: 0)
            decodeTable.setAddress(source.table.gpuAddress, index: 0)
            decodeTable.setAddress(lookup.gpuAddress, index: 1)
            encoder.setRenderPipelineState(surfaceState)
            encoder.setArgumentTable(decodeTable, stages: [.vertex, .fragment])
            encoder.drawPrimitives(primitiveType: .triangle, vertexStart: 0, vertexCount: 3)
            gpu.holdUntilSubmittedWorkFinishes([source.texture, source.table, source.lease])
        } else if image.inputNeedsDecode, let picture {
            picture.bytes.withUnsafeBytes { source in
                bytes.copyMemory(from: source.baseAddress!, byteCount: source.count)
            }
            decodeTable.setAddress(staging.gpuAddress + UInt64(offset), index: 0)
            decodeTable.setAddress(lookup.gpuAddress, index: 1)
            decodeTable.setAddress(staging.gpuAddress + UInt64(offset + sizeOffset), index: 2)
            encoder.setRenderPipelineState(decodeState)
            encoder.setArgumentTable(decodeTable, stages: [.vertex, .fragment])
            encoder.drawPrimitives(primitiveType: .triangle, vertexStart: 0, vertexCount: 3)
        }
        if !image.inputPatches.isEmpty {
            var destination = bytes.advanced(by: patchOffset)
            for (index, texel) in image.inputPatches {
                destination.storeBytes(of: UInt32(index), as: UInt32.self)
                destination.storeBytes(of: UInt32(0), toByteOffset: 4, as: UInt32.self)
                destination.storeBytes(of: texel, toByteOffset: 8, as: SIMD4<Float16>.self)
                destination = destination.advanced(by: 16)
            }
            patchTable.setAddress(staging.gpuAddress + UInt64(offset + patchOffset), index: 0)
            patchTable.setAddress(staging.gpuAddress + UInt64(offset + sizeOffset), index: 2)
            encoder.setRenderPipelineState(patchState)
            encoder.setArgumentTable(patchTable, stages: [.vertex, .fragment])
            // 同じ render pass の画素への書き込み順が、復号してから最後の編集を載せる。
            encoder.drawPrimitives(
                primitiveType: .point, vertexStart: 0, vertexCount: image.inputPatches.count)
        }
        encoder.barrier(
            afterStages: .fragment, beforeQueueStages: [.dispatch, .vertex, .fragment, .blit],
            visibilityOptions: .device)
        encoder.endEncoding()
        return image.uploadGeneration
    }
}
