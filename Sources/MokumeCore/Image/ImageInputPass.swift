// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Metal

/// 入力を既存の画像面へ直接描く (#1753)。全画素の中間 buffer は持たない。
/// shaderWrite を付けないので、未更新の画像でも使う Metal のロスレス圧縮を妨げない。
/// CPU が書く引数テーブルは Canvas のフレーム環に従い、画像ごと・段ごとに分ける。
@MainActor final class ImageInputPass {
    private let gpu: RenderDevice
    private let decodeState: any MTLRenderPipelineState
    private let patchState: any MTLRenderPipelineState
    private let lookup: any MTLBuffer
    private var tables: [ArgumentTablePool]

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
            ArgumentTablePool(gpu: gpu, label: "mokume.image.input.\($0)", bufferBindCount: 3)
        }
    }

    isolated deinit { gpu.retire(lookup) }

    /// 失敗しうる準備をすべて済ませてから積む。失敗時は呼び手が従来の CPU 経路へ戻す。
    func stage(
        _ image: Image, into bytes: UnsafeMutableRawPointer, of staging: any MTLBuffer,
        at offset: Int, slot: Int, index: Int, in commands: any MTL4CommandBuffer
    ) throws(RenderFailure) -> UInt64 {
        let decodeTable = try tables[slot].table(at: index * 2)
        let patchTable = try tables[slot].table(at: index * 2 + 1)
        let picture = image.displayInput!
        let rawByteCount = image.inputNeedsDecode ? picture.bytes.count : 0
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
        bytes.storeBytes(
            of: SIMD2(UInt32(image.width), UInt32(image.height)), toByteOffset: sizeOffset,
            as: SIMD2<UInt32>.self)
        encoder.setViewport(MTLViewport(
            originX: 0, originY: 0, width: Double(image.width), height: Double(image.height),
            znear: 0, zfar: 1))
        if image.inputNeedsDecode {
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
