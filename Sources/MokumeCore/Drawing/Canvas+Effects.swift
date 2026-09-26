// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation
import Metal
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
    ///
    /// **受け口で検める** ([#1544])。数でない値・無限を持つ効果はその 1 つだけを外して
    /// 初回だけ言い、並びの他の効果は掛ける。範囲を決めている数は端へ締める
    /// (`Effect.accepted`)。
    ///
    /// [#1544]: https://github.com/mokume-metal/mokume/issues/1544
    public func effects(_ effects: [Effect]) {
        pendingEffects = effects.compactMap { effect in
            guard let accepted = effect.accepted else {
                warnOnce(
                    .badEffect,
                    "effects(): the \(effect.name) effect held a value that is not a number, or an "
                        + "infinite one, so it was not applied")
                return nil
            }
            return accepted
        }
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
        let (url, body, name) = try ShaderSource.read(at: path)
        return try makeEffect(name: name, url: url, body: body, values: values)
    }

    private func makeEffect(
        name: String, url: URL?, body: String, values: [String: ShaderValue]
    ) throws(ShaderFailure) -> EffectShader {
        guard values.count * 4 <= EffectPipeline.valueSlotCapacity else {
            throw .notCompilable(
                path: url?.path ?? name,
                reason: "At most \(EffectPipeline.valueSlotCapacity / 4) values can go into one effect")
        }
        do {
            // **弱く持って、失敗だけを読む** ([#787])。強く持つと利用者が手放した断片まで
            // 面と同じ寿命になるので抱えない ([#738]) が、抱えないだけにすると差し替えに
            // 失敗した効果が黙って前の絵を出し続ける。控えは観測 (`shaderFailures`) の
            // ためにある
            //
            // [#787]: https://github.com/mokume-metal/mokume/issues/787
            // [#738]: https://github.com/mokume-metal/mokume/issues/738
            let effect = try EffectShader(
                name: name, url: url, body: body, values: values,
                gpu: gpu, pipeline: try effectPipeline())
            remember(effect)
            return effect
        } catch {
            throw .notCompilable(path: url?.path ?? name, reason: "\(error)")
        }
    }

    /// 効果のパイプライン。**頼まれてはじめて作る。**
    func effectPipeline() throws(RenderFailure) -> EffectPipeline {
        if let effectPipelineStorage { return effectPipelineStorage }
        // **控えは描く細かさで作る。** 効果は描き終えた絵の上で働くので、拡大より
        // 手前 = 描く細かさの側にいる
        let made = try EffectPipeline(
            gpu: gpu, ring: frameRing, width: pixelWidth, height: pixelHeight,
            pixelFormat: RenderTarget.pixelFormat)
        effectPipelineStorage = made
        return made
    }

    // MARK: - 通す

    /// 頼まれた効果を、描き終えた絵へ通す。
    ///
    /// **描く先へ書くのは最後の 1 段だけ。** 描き終えた絵をまず控え
    /// (``EffectPipeline/carry()``) へ写し、段はそれを入りの絵として読んで中間の絵の間を
    /// 往復し、並びの最後の段が描く先へ書く。段の失敗はすべてコマンドを組む時点で起きるので、
    /// 最後の段の組み立てに失敗すれば描く先へは 1 命令も積まれない。だから**途中で失敗しても
    /// 「途中の絵」は出ない** — 描く先は 1 ビットも変わっていない (#755 で書き戻しの段を
    /// 消しても、ここは変わらない)。
    ///
    /// **描く先に残った効果は、次のフレームの入りにならない** ([#1469])。控えには効果を
    /// 通す前の絵が残るので、次のフレームの最初の描き切りがそこから戻す
    /// (``encodeCarryRestore(into:)``)。細かさ 1 では描く先と出す先が同じ 1 枚なので、
    /// 出口へ届ける絵は描く先へ書くしかなく、戻さなければ塗り直さずに描き足すスケッチで
    /// 効果がフレームごとに重なる。
    ///
    /// 頼まれていなければ段も写しも 1 つも積まず、控えも作らないので、効果を使わない
    /// スケッチはここで何も払わない (代表シーンの台帳が動かないのもこれによる)。
    ///
    /// 効果を通す。**失敗しても投げない。**
    ///
    /// 効果は毎フレーム走るので、投げると 1 段の失敗でフレームごと落ちる ([ADR-0020]
    /// 決定 5)。描く先を書く段の手前で止まれば描く先は無傷なので、**入りをそのまま
    /// 通して**理由を知らせる。
    ///
    /// - Returns: 描く先へ効果を通した絵を書いたか。書いたなら、効果を通す前の絵は控えにある。
    ///
    /// [#1469]: https://github.com/mokume-metal/mokume/issues/1469
    /// [ADR-0020]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0020-api-naming-and-surface.md
    func applyEffects(into commands: any MTL4CommandBuffer) -> Bool {
        do {
            return try encodeEffects(into: commands)
        } catch {
            warnOnce(
                .effectFailed,
                "Could not run the effect: \(error.headline). This frame comes out as it stood before "
                    + "the effect")
            return false
        }
    }

    func encodeEffects(into commands: any MTL4CommandBuffer) throws(RenderFailure) -> Bool {
        // **半径は出す画素で書かれている** ([#1545])。段は描く細かさの絵の上で回るので、
        // 展開する前に描く画素へ換算する (縮め幅もこの半径で決まる)
        let scale = effectRadiusScale
        let passes = pendingEffects.flatMap { $0.passes(drawnPerOutput: scale) }
        guard !passes.isEmpty else { return false }
        let pipeline = try effectPipeline()
        // **このフレームで使う枠を、1 枠も書かないうちに数え切る。** 取り直すと領域が
        // 入れ替わるので、既に束ねた番地の指す先を生かしておくことに頼ることになる。
        // 数え切っておけば、そもそも途中で取り直さない (拡大のぶんを足す — 上限で
        // 数えてよい)。控えへの写しは段ではないので枠を取らない
        try pipeline.reservePasses(stagePassesUsed + passes.count + upscalePassCount)
        let carry = try pipeline.carry()
        try encodeCarry(into: carry, in: commands)

        /// いまの絵。**最初は控え** — 入りの絵を描く先から読まないので、最後の段は
        /// 読んでいる面へ書くことにならない。
        var current: any EffectSurface = carry
        var nextSlot = 0

        func image(of slot: EffectPass.Slot) throws(RenderFailure) -> any EffectSurface {
            switch slot {
            case .current: return current
            case .next: return try pipeline.scratch(at: nextSlot)
            // 全解像度の脇は往復の 2 枚の後ろに置く。縮めた絵は別の列なので先頭から
            case .side(let index, let level):
                return try pipeline.scratch(at: level == 0 ? 2 + index : index, level: level)
            }
        }

        for (position, pass) in passes.enumerated() {
            let source = try image(of: pass.input)
            let paired = try image(of: pass.paired ?? pass.input)
            // **最後の段は描く先へ直接書く** (#755)。入りの絵は控えなので、1 段だけの
            // 並びやにじみ単独の合成のように入りの絵を読む段でも、読んでいる面へ書く
            // ことにはならない (同じ面を読みながら描くのは Metal では未定義で、かつては
            // その並びだけ控えへ書いてから写し戻していた)。ここで書いた絵が次の
            // フレームの入りにならないのは、控えから戻すため (#1469)
            let destination =
                position == passes.count - 1 && pass.output == .next
                ? target : try image(of: pass.output)
            try encode(
                pass, at: takeStagePass(), from: source.texture, paired: paired.texture,
                into: destination, using: pipeline, in: commands)
            if pass.output == .next {
                current = destination
                nextSlot = 1 - nextSlot
            }
        }

        // **描く先へ書くのはここまでで 1 度きり。** 途中で失敗すればここへ来ない
        return current === target
    }

    /// 描き終えた絵を、控えへ写す blit を積む ([#1469])。
    ///
    /// **段の外に置く。** 段にすると採番 (``takeStagePass()``) と置き場の数え切りに入り、
    /// 「段の数は並びが宣言する段の数」が崩れる。待つ仕掛けは描画先の読み戻しと同じ形
    /// (``RenderTarget/encodePixelReadback(into:)``)。
    ///
    /// [#1469]: https://github.com/mokume-metal/mokume/issues/1469
    private func encodeCarry(into carry: StageImage, in commands: any MTL4CommandBuffer)
        throws(RenderFailure)
    {
        guard let encoder = commands.makeComputeCommandEncoder() else {
            throw .encoderUnavailable
        }
        // **描き終わるのを待つ。** この世代は encoder をまたぐ依存を自動では張らない
        // (#341)。前の戻し・書き戻し (blit) も待つ — 控えは戻しが読んだ面でもある
        encoder.barrier(
            afterQueueStages: [.fragment, .blit], beforeStages: .blit,
            visibilityOptions: .device)
        encoder.copy(sourceTexture: target.texture, destinationTexture: carry.texture)
        // **写し終わるのを、控えを読む段と描く先へ書く段が待つ。** `.device` を渡さないと
        // 実行順だけ揃って中身が見えない (#341 で実測)
        encoder.barrier(
            afterStages: .blit, beforeQueueStages: .fragment, visibilityOptions: .device)
        encoder.endEncoding()
        effectCarriesEncoded += 1
    }

    /// 控えから描く先へ、効果を通す前の絵を戻す blit を積む ([#1469])。**控えが無ければ
    /// 何も積まない。**
    ///
    /// 描き切りのコマンドの**先頭**に積む (CPU の画素の書き戻しより前)。前の投入とは投入の
    /// 順で直列になっている (``RenderDevice/commit(_:retaining:)`` の `orderAfter`) ので、
    /// 頭に待つ仕掛けは要らない。積んだ blit を後続の段が待つ仕掛けは、書き戻しと同じ形で
    /// ここで積む。
    ///
    /// [#1469]: https://github.com/mokume-metal/mokume/issues/1469
    func encodeCarryRestore(into commands: any MTL4CommandBuffer) throws(RenderFailure) {
        guard let carry = effectPipelineStorage?.existingCarry else { return }
        guard let encoder = commands.makeComputeCommandEncoder() else {
            throw .encoderUnavailable
        }
        encoder.copy(sourceTexture: carry.texture, destinationTexture: target.texture)
        // **戻し終わるのを、続く書き戻し・描画・効果・読み戻しが待つ**
        encoder.barrier(
            afterStages: .blit, beforeQueueStages: [.vertex, .fragment, .blit],
            visibilityOptions: .device)
        encoder.endEncoding()
        effectCarryRestoresEncoded += 1
    }

    /// 次の段の枠を 1 つ取る。**効果も拡大もここから取る** (採番は 1 系統)。
    func takeStagePass() -> Int {
        defer { stagePassesUsed += 1 }
        return stagePassesUsed
    }

    func encode(
        _ pass: EffectPass, at index: Int, from source: any MTLTexture,
        paired: any MTLTexture, into destination: any EffectSurface,
        using pipeline: EffectPipeline, in commands: any MTL4CommandBuffer
    ) throws(RenderFailure) {
        // **投げうる仕事は、口を開く前に済ませる** ([#1184])。開いた後で投げると口が開いたまま
        // `applyEffects` が握って投入し、検証層では投入の時点で落ちる。閉じてから抜ける
        // のでも足りない — 書き込む先は前の内容を読まない (`.dontCare`) ので、最後の段が
        // 描く先へ開いた口を閉じるだけで、描く先の中身が保証されなくなる。だから口を
        // 開いた後には投げる行を置かない
        //
        // [#1184]: https://github.com/mokume-metal/mokume/issues/1184
        let base = index * EffectPipeline.passStride
        let block = pipeline.passBuffer.contents().advanced(by: base)
        var control = [pass.control.0, pass.control.1]
        block.advanced(by: EffectPipeline.controlOffset)
            .copyMemory(from: &control, byteCount: 32)
        var frame = SIMD4<Float>(
            Float(destination.width), Float(destination.height), time, 0)
        block.advanced(by: EffectPipeline.frameOffset)
            .copyMemory(from: &frame, byteCount: 16)
        var values = pass.shader?.packedValues ?? [0, 0, 0, 0]
        while values.count < EffectPipeline.valueSlotCapacity { values.append(0) }
        block.advanced(by: EffectPipeline.valuesOffset)
            .copyMemory(
                from: &values,
                byteCount: EffectPipeline.valueSlotCapacity * MemoryLayout<Float>.stride)

        if failEffectPassForTesting == index {
            throw .argumentTableUnavailable(reason: "failed for testing")
        }
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

        encoder.setRenderPipelineState(pass.shader?.state ?? pipeline.builtin)
        // **窓は書き込む先の大きさで測る。** 段は入りと出りで大きさが違いうる
        // (拡大がそれ) ので、面の大きさを 1 つに決め打つと出りが埋まらない
        encoder.setViewport(
            MTLViewport(
                originX: 0, originY: 0,
                width: Double(destination.width), height: Double(destination.height),
                znear: 0, zfar: 1))
        encoder.setArgumentTable(table, stages: [.vertex, .fragment])
        encoder.drawPrimitives(primitiveType: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()
        effectPassesEncoded += 1
    }
}

// MARK: - 半径は出す画素 (#1545)

extension Canvas {
    /// 出す画素 1 つが描く画素でいくらか。効果の半径 (出す画素) をこれで描く画素へ換算する
    /// ([#1545])。
    ///
    /// 描く大きさは縦横それぞれ丸める (`drawnSize`) ので、縦と横の比は僅かにずれうる。
    /// 半径は 1 つなので、2 つの平均を取る。**細かさ 1 ではちょうど 1** — 描く先と出す先が
    /// 同じ 1 枚で、幅を幅で割るため (``unitsPerDrawnPixel`` と同じ)。
    ///
    /// [#1545]: https://github.com/mokume-metal/mokume/issues/1545
    var effectRadiusScale: Float {
        let drawnPerOutput = 1 / unitsPerDrawnPixel
        return (drawnPerOutput.x + drawnPerOutput.y) / 2
    }
}
