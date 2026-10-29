// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Metal
import MokumeDiagnostics

// ``ShaderSurface/previousFrame`` の写し ([#2456])。
//
// 「前の絵」は、その面が次のフレームへ持ち越す絵である (ADR-0021 決定 4)。**フレームの最初の描き切りが
// 描く先を書き換える前に**、その絵を専用の写しへ 1 枚取り、断片はその写しを読む。描く先そのものを読ませ
// ない — 同じ面を読みながら書くのは Metal では未定義で、作例のように先に `background()` で消しても、
// 消す前の絵が読めなければならないからである。
//
// 払うのは、`.previousFrame` を宣言した断片を当てた面だけ。当てたフレームの次のフレームも写しを取り
// (当てるのが `draw()` の途中で、最初の描き切りより後のことがあるため)、読む列が無ければ止める。
//
// [#2456]: https://github.com/mokume-metal/mokume/issues/2456

extension Canvas {
    /// 前のフレームの絵を読む面 (``ShaderSurface/previousFrame``) として、溜める側へ渡す形。
    ///
    /// **写しは 1 枚を使い回す。** 写す時点はフレームの最初の描き切りで、1 つのフレームの列はどれも同じ
    /// 写しを読む。前のフレームの列が読み終わるのは、写すコマンドの前の関所が待つ (``encodePreviousFrameCopy(startsFrame:restoresCarry:drawsInFrame:into:)``)。
    /// 面の大きさが変わったときだけ作り直す (前の写しは、それを読む列が持ち主ごと抱えている)。
    func previousFrameHeld() -> HeldTexture {
        previousFrameRead = true
        let texture = target.texture
        if let copy = previousFrameCopy, copy.fits(texture) { return copy.held }
        do {
            let copy = try PlacedPictureCopy(gpu: gpu, like: texture)
            previousFrameCopy = copy
            previousFrameCopiesMade += 1
            return copy.held
        } catch {
            // 資源が枯れたときだけ。写しを作れないので、描く先そのものを読ませる (その枚は前の絵ではなく、
            // 描いている途中の絵が出る)
            Diagnostics.warn(
                "Could not make a copy for ShaderSurface.previousFrame, so the picture being drawn is read "
                    + "instead: \(error.headline)")
            return HeldTexture(texture: texture, owner: target)
        }
    }

    /// フレームの頭で、前のフレームに読んだかを引き継ぐ (``beginFrame()``)。
    func rollPreviousFrameUse() {
        previousFrameWatched = previousFrameRead
        previousFrameRead = false
        previousFrameCopiedThisFrame = false
    }

    /// 溜めた列のどれかが、前のフレームの写しを読むか。
    private func batchesReadPreviousFrame(_ copy: PlacedPictureCopy) -> Bool {
        for batch in batches {
            for surface in batch.run.paint.surfaces where surface.texture === copy.texture { return true }
        }
        return false
    }

    /// 前のフレームの写しを、描く先を書き換える前に積む。
    ///
    /// **描き切りの頭の 1 回だけ** (``previousFrameCopiedThisFrame``)。写すのはフレームの最初の描き切りで、
    /// 前のフレームが持ち越した絵は、
    /// - 前のフレームが効果を通していて、このフレームが塗り直す (`pendingBackground`) とき: 描く先には効果を
    ///   通した絵が残り、通す前の絵は控え (``EffectPipeline/carry()``) にある — 控えを写す
    /// - それ以外: 描く先。効果を通したフレームの後に塗り直さないなら、控えは描く先へ戻した後 (取り替えた後)
    ///   なので、描く先が通す前の絵である
    ///
    /// 最初の描き切りの後に初めて読む列が現れたとき (`draw()` の途中で `loadPixels()` などの後に当てたとき) は、
    /// 前の絵はもう書き換わっているので、その時点の描く先を写す。
    ///
    /// - Returns: 写しを積んだか。**投入した後で** ``previousFrameCopiedThisFrame`` を立てる (投げて
    ///   投入されなかった描き切りは、やり直す)。
    func encodePreviousFrameCopy(
        startsFrame: Bool, restoresCarry: Bool, drawsInFrame: Bool, into commands: any MTL4CommandBuffer
    ) throws(RenderFailure) -> Bool {
        guard drawsInFrame, !previousFrameCopiedThisFrame, let copy = previousFrameCopy else { return false }
        guard (startsFrame && previousFrameWatched) || batchesReadPreviousFrame(copy) else { return false }
        var source: any MTLTexture = target.texture
        if startsFrame, carriesPictureBeforeEffects, !restoresCarry,
            let carry = effectPipelineStorage?.existingCarry
        {
            source = carry.texture
        }
        // 面の大きさが変わった直後 (写しを作り直す前) は、写さずに次の描き切りへ任せる
        guard copy.fits(source) else { return false }
        guard let encoder = commands.makeComputeCommandEncoder() else { throw .encoderUnavailable }
        // 前のフレームの列が写しを読み終わるのを待ち、写し終わるのを後の段が待つ (この世代は encoder を
        // またぐ依存を自動では張らない・#341)
        encoder.barrier(
            afterQueueStages: [.dispatch, .fragment, .blit], beforeStages: .blit,
            visibilityOptions: .device)
        encoder.copy(sourceTexture: source, destinationTexture: copy.texture)
        encoder.barrier(
            afterStages: .blit, beforeQueueStages: [.dispatch, .fragment, .blit],
            visibilityOptions: .device)
        encoder.endEncoding()
        return true
    }
}
