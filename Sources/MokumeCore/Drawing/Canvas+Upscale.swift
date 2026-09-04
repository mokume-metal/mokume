// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Metal
import simd

// 拡大。意味の説明は利用者が最初に触る層 (`Sketch`) が正本で、ここは受け口である
// ([ADR-0020] 決定 4)。
//
// **拡大は利用者の効果の並びへ入らない。** ADR-0015 決定 1 の「後処理の 1 つとしてでは
// なく解像度の決め方の一部として提供する」をそのまま採る。段の仕組み (絵から絵へ・
// 控えの使い回し・枠の採番) は効果と共有し、並びだけを共有しない。
//
// [ADR-0015]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0015-metalfx-role.md
// [ADR-0020]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0020-api-naming-and-surface.md
extension Canvas {
    /// 描き終えた絵を、出す細かさへ広げる。**失敗しても投げない。**
    ///
    /// 拡大は毎フレーム走るので、投げると 1 度の失敗でフレームごと落ちる ([ADR-0020]
    /// 決定 5)。広げられなければ**描く細かさの絵をそのまま出す先へ写す** — 小さいまま
    /// 出すと出口の大きさが変わってしまうので、写しだけは必ず通す。
    ///
    /// [ADR-0020]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0020-api-naming-and-surface.md
    func applyUpscale(into commands: any MTL4CommandBuffer) {
        guard let stage = upscaleStage else { return }
        do {
            try encodeUpscale(stage, into: commands)
        } catch {
            warnOnce(.upscaleFailed, "拡大を通せませんでした: \(error.headline)")
        }
    }

    /// 通す順は、空間方向なら 1 手・時間方向なら 2 手。
    ///
    /// 1. 描く先を三次補間で広げ、出す先へ書く (時間方向なら、前の結果と混ぜながら)
    /// 2. (時間方向のみ) 出した絵を、次のフレームのために控える
    ///
    /// **出す先へ書くのは 1 度きり。** 途中で失敗すればここへ来ないので、前のフレームの
    /// 絵が半端に混ざった 1 枚は出ない (効果の段と同じ構え)。
    private func encodeUpscale(_ stage: UpscaleStage, into commands: any MTL4CommandBuffer)
        throws(RenderFailure)
    {
        let pipeline = try effectPipeline()
        defer { stage.advance() }

        guard let history = stage.history else {
            let index = takeStagePass()
            try pipeline.reservePasses(index + upscalePassCount)
            try encode(
                EffectPass(control: (SIMD4(Effect.enlargeKind, 0, 0, 0), .zero)),
                at: index, from: target.texture, paired: target.texture,
                into: output, using: pipeline, in: commands)
            return
        }

        let offset = stage.jitterInSource
        let blend = takeStagePass()
        let keep = takeStagePass()
        try pipeline.reservePasses(keep + 1)

        try encode(
            EffectPass(
                control: (
                    SIMD4(Effect.accumulateKind, offset.x, offset.y, stage.weight), .zero
                )),
            at: blend, from: target.texture, paired: history.texture,
            into: output, using: pipeline, in: commands)
        // **控えるのは出した絵そのもの。** 別に作り直すと、次のフレームが混ぜる相手が
        // 出した絵と食い違う
        try encode(
            EffectPass(control: (SIMD4(0, 0, 0, 0), .zero)),
            at: keep, from: output.texture, paired: output.texture,
            into: history, using: pipeline, in: commands)
    }
}
