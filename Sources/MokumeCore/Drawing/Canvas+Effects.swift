// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation
import Metal
import MokumeDiagnostics
import simd

// 効果。意味の説明は利用者が最初に触る層 (`Sketch`) が正本で、ここは受け口である
// ([ADR-0020] 決定 4)。
//
// **段は絵から絵への変換 1 種類** ([ADR-0023] 決定 1)。種類ごとの呼び出し口を生やすと
// 「段の並びは値」が失われ、後から差し込む先が無くなる。だから口は `effects(_:)` 1 本で、
// 組み込みも利用者の効果も同じ並びへ入る。
//
// [ADR-0020]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0020-api-naming-and-surface.md
// [ADR-0023]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0023-frame-stages-and-outputs.md
extension Canvas {
    /// このフレームにかける効果の並びを決める。
    public func effects(_ effects: [Effect]) {
        pendingEffects = effects
    }

    /// 文字列から効果を作る。
    public func makeEffect(
        _ body: String, name: String = "effect", values: [String: ShaderValue] = [:]
    ) throws(ShaderFailure) -> EffectShader {
        try makeEffect(name: name, url: nil, body: body, values: values)
    }

    /// ファイルから効果を読み込む。
    public func loadEffect(
        _ path: String, values: [String: ShaderValue] = [:]
    ) throws(ShaderFailure) -> EffectShader {
        let candidates = ImageFile.candidates(for: path)
        guard
            let url = candidates.first(where: { FileManager.default.fileExists(atPath: $0.path) }),
            let body = try? String(contentsOf: url, encoding: .utf8)
        else {
            throw .notFound(path: path, searched: candidates.map(\.path))
        }
        let name = url.deletingPathExtension().lastPathComponent
        return try makeEffect(name: name, url: url, body: body, values: values)
    }

    private func makeEffect(
        name: String, url: URL?, body: String, values: [String: ShaderValue]
    ) throws(ShaderFailure) -> EffectShader {
        guard values.count * 4 <= EffectPipeline.valueSlotCapacity else {
            throw .notCompilable(
                path: url?.path ?? name,
                reason: "1 つの効果に渡せる値は \(EffectPipeline.valueSlotCapacity / 4) 個までです")
        }
        do {
            let shader = try EffectShader(
                name: name, url: url, body: body, values: values,
                gpu: gpu, pipeline: try effectPipeline())
            effectShaders.append(shader)
            return shader
        } catch {
            throw .notCompilable(path: url?.path ?? name, reason: "\(error)")
        }
    }

    /// 効果のパイプライン。**頼まれてはじめて作る。**
    func effectPipeline() throws(RenderFailure) -> EffectPipeline {
        if let effectPipelineStorage { return effectPipelineStorage }
        let made = try EffectPipeline(
            gpu: gpu, width: Int(width), height: Int(height),
            pixelFormat: RenderTarget.pixelFormat)
        effectPipelineStorage = made
        return made
    }

    // MARK: - 通す

    /// 頼まれた効果を、描き終えた絵へ通す。
    ///
    /// **入りの絵には最後まで書かない。** 段は控えの間だけを往復し、最後に 1 度だけ
    /// 写し戻す。だから**途中で失敗しても「途中の絵」は出ない** — 写し戻す手前で
    /// 止まれば、入りの絵は 1 ビットも変わっていない。
    ///
    /// 頼まれていなければ段を 1 つも立てないので、効果を使わないスケッチはここで
    /// 何も払わない (代表シーンの台帳が動かないのもこれによる)。
    /// 効果を通す。**失敗しても投げない。**
    ///
    /// 効果は毎フレーム走るので、投げると 1 段の失敗でフレームごと落ちる ([ADR-0020]
    /// 決定 5)。書き戻す手前で止まれば入りの絵は無傷なので、**入りをそのまま通して**
    /// 理由を知らせる。
    ///
    /// [ADR-0020]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0020-api-naming-and-surface.md
    func applyEffects(into commands: any MTL4CommandBuffer) {
        do {
            try encodeEffects(into: commands)
        } catch {
            guard !warnedEffectFailed else { return }
            warnedEffectFailed = true
            Diagnostics.warn(
                "効果を通せませんでした: \(error)。このフレームは効果をかける前の絵を出します")
        }
    }

    func encodeEffects(into commands: any MTL4CommandBuffer) throws(RenderFailure) {
        let passes = pendingEffects.flatMap(\.passes)
        guard !passes.isEmpty else { return }
        let pipeline = try effectPipeline()
        // 最後の写し戻しぶんを足して数える
        try pipeline.reservePasses(passes.count + 1)

        /// いまの絵。`nil` は入りの絵 (描き終えた描画先)。
        var current: RenderTarget?
        var nextSlot = 0

        func image(of slot: EffectPass.Slot) throws(RenderFailure) -> RenderTarget? {
            switch slot {
            case .current: return current
            case .next: return try pipeline.scratch(at: nextSlot)
            // 脇は往復の 2 枚の後ろに置く
            case .side(let index): return try pipeline.scratch(at: 2 + index)
            }
        }

        for (index, pass) in passes.enumerated() {
            let source = try image(of: pass.input) ?? target
            let paired = try image(of: pass.paired ?? pass.input) ?? target
            guard let destination = try image(of: pass.output) else {
                throw .encoderUnavailable
            }
            try encode(
                pass, at: index, from: source.texture, paired: paired.texture,
                into: destination, using: pipeline, in: commands)
            if pass.output == .next {
                current = destination
                nextSlot = 1 - nextSlot
            }
        }

        // **ここではじめて入りの絵へ書く。** 1 度きりで、途中で失敗すればここへ来ない
        guard let result = current else { return }
        try encode(
            EffectPass(control: (SIMD4(0, 0, 0, 0), SIMD4(0, 0, 0, 0))), at: passes.count,
            from: result.texture, paired: result.texture, into: target,
            using: pipeline, in: commands)
    }

    private func encode(
        _ pass: EffectPass, at index: Int, from source: any MTLTexture,
        paired: any MTLTexture, into destination: RenderTarget,
        using pipeline: EffectPipeline, in commands: any MTL4CommandBuffer
    ) throws(RenderFailure) {
        if failEffectPassForTesting == index { throw .encoderUnavailable }
        guard let encoder = commands.makeRenderCommandEncoder(
            descriptor: destination.makeEffectPass())
        else {
            throw .encoderUnavailable
        }
        // **前の段が書き終わるのを待つ。** この世代のコマンド構造は口をまたぐ依存を
        // 自動では張らないので、積まなければ次の段が書き終わる前の絵を読む
        // ([#341] で影の焼き付けと画面のパスが実際にそうなった)
        //
        // [#341]: https://github.com/mokume-metal/mokume/issues/341
        encoder.barrier(
            afterQueueStages: .fragment, beforeStages: .fragment, visibilityOptions: .device)
        effectBarriersEncoded += 1

        let base = index * EffectPipeline.passStride
        let block = pipeline.passBuffer.contents().advanced(by: base)
        var control = [pass.control.0, pass.control.1]
        block.advanced(by: EffectPipeline.controlOffset)
            .copyMemory(from: &control, byteCount: 32)
        var frame = SIMD4<Float>(Float(width), Float(height), time, 0)
        block.advanced(by: EffectPipeline.frameOffset)
            .copyMemory(from: &frame, byteCount: 16)
        var values = pass.shader?.packedValues ?? [0, 0, 0, 0]
        while values.count < EffectPipeline.valueSlotCapacity { values.append(0) }
        block.advanced(by: EffectPipeline.valuesOffset)
            .copyMemory(
                from: &values,
                byteCount: EffectPipeline.valueSlotCapacity * MemoryLayout<Float>.stride)

        let table = try pipeline.table(at: index)
        let address = pipeline.passBuffer.gpuAddress + UInt64(base)
        table.setAddress(
            address + UInt64(EffectPipeline.valuesOffset),
            index: EffectPipeline.valuesBufferIndex)
        table.setAddress(
            address + UInt64(EffectPipeline.controlOffset),
            index: EffectPipeline.controlBufferIndex)
        table.setAddress(
            address + UInt64(EffectPipeline.frameOffset),
            index: EffectPipeline.frameBufferIndex)
        table.setTexture(source.gpuResourceID, index: EffectPipeline.sourceTextureIndex)
        table.setTexture(paired.gpuResourceID, index: EffectPipeline.pairedTextureIndex)

        encoder.setRenderPipelineState(pass.shader?.state ?? pipeline.builtin)
        encoder.setViewport(
            MTLViewport(
                originX: 0, originY: 0, width: Double(width), height: Double(height),
                znear: 0, zfar: 1))
        encoder.setArgumentTable(table, stages: [.vertex, .fragment])
        encoder.drawPrimitives(primitiveType: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()
        effectPassesEncoded += 1
    }
}
