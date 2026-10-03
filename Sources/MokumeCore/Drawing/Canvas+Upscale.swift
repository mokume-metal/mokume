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
    /// - Returns: 出す先が描く先に追い付いたか。**失敗を握り潰しても、呼び手には成否を返す** —
    ///   積めなかったのに「広げた」ことにすると、出す先は古い絵のまま追い付き直されない
    ///   ([#1882])。拡大の段が無い面 (細かさ 1) は、描く先が出す先そのものなので常に `true`。
    ///
    /// [ADR-0020]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0020-api-naming-and-surface.md
    /// [#1882]: https://github.com/mokume-metal/mokume/issues/1882
    func applyUpscale(into commands: any MTL4CommandBuffer) -> Bool {
        guard let stage = upscaleStage else { return true }
        do {
            try encodeUpscale(stage, into: commands)
            return true
        } catch {
            warnOnce(.upscaleFailed, "Could not run the upscale: \(error.headline)")
            return false
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
            // 空間方向は揺らさない (``UpscaleStage/jitter`` が 0)
            try encodeEnlargement(using: pipeline, offset: .zero, into: commands)
            return
        }

        let offset = stage.jitterInSource
        let blend = takeStagePass()
        let keep = takeStagePass()
        try pipeline.reservePasses(keep + 1)

        try encode(
            EffectPass(
                control: (
                    SIMD4(BuiltinEffectKind.accumulate.value, offset.x, offset.y, stage.weight), .zero
                )),
            at: blend, from: target.texture, paired: history.texture,
            into: output, using: pipeline, in: commands)
        // **控えるのは出した絵そのもの。** 別に作り直すと、次のフレームが混ぜる相手が
        // 出した絵と食い違う
        try encode(
            EffectPass(control: (SIMD4(BuiltinEffectKind.copy.value, 0, 0, 0), .zero)),
            at: keep, from: output.texture, paired: output.texture,
            into: history, using: pipeline, in: commands)
    }

    /// 描く先を三次補間で広げ、出す先へ書く 1 手。**前のフレームと混ぜない。**
    ///
    /// 空間方向の拡大そのものであり、止まっている間の追い付き (``catchUpOutput()``) は、時間方向でも
    /// これを通す。
    ///
    /// - Parameter offset: 読む位置のずれ (0…1)。描く先の絵が揺らしでずれているとき、その分を
    ///   戻す (``UpscaleStage/jitterInSource``)。
    private func encodeEnlargement(
        using pipeline: EffectPipeline, offset: SIMD2<Float>, into commands: any MTL4CommandBuffer
    ) throws(RenderFailure) {
        let index = takeStagePass()
        try pipeline.reservePasses(index + upscalePassCount)
        try encode(
            EffectPass(control: (SIMD4(BuiltinEffectKind.enlarge.value, offset.x, offset.y, 0), .zero)),
            at: index, from: target.texture, paired: target.texture,
            into: output, using: pipeline, in: commands)
    }

    // MARK: - 止まっている間の追い付き (#1882)

    /// 出す先が、描く先の最後の姿を広げたものでなくなっているか ([#1882])。
    ///
    /// **出す先を読む口 (出力段) が、読む前に尋ねる。** 拡大が積まれるのはフレームの終わりの描き
    /// 切りだけなので、止まっている間に描く先が変わると (画素を書く・図形や絵を置いて描き切らせる)、
    /// 出す先は変わる前の絵を映したままになる。変わったかは、描き切りが立てる印
    /// (``targetChangedSinceUpscale``) と、まだ描く先へ戻していない画素の書き込みで見る。
    /// **変えていなければ偽なので、出力段は何も積まない** (ADR-0023 決定 5)。拡大の段が無い面
    /// (細かさ 1) では、描く先が出す先そのものなので常に偽である。
    ///
    /// [#1882]: https://github.com/mokume-metal/mokume/issues/1882
    var needsOutputEnlargement: Bool {
        guard upscaleStage != nil else { return false }
        return targetChangedSinceUpscale || target.hasPendingPixelWrites
    }

    /// 止まっている間に変わった描く先を、出す先へ広げ直す ([#1882])。
    ///
    /// **積むのは書き戻しと拡大の 1 手だけ**で、1 本のコマンドにまとめる。
    ///
    /// - 書き戻し: 描く先へまだ戻していない画素の書き込みを戻す。効果を通した絵の後なら、
    ///   効果を通す前の絵 (次のフレームの入り) へも写す (``encodePixelWriteBackKeepingCarry(into:)``)。
    ///   広げるより前に戻さないと、書いた画素が出す先に届かない
    /// - 拡大: 描く先の絵を、そのまま出す先へ広げる。**時間方向でも前のフレームと混ぜず**
    ///   (`accumulate` は重み 0.2 で変えた分を薄める)、履歴も揺らしの位相 (`framesScaled`) も
    ///   動かさない。次に描くフレームは、これまでどおり履歴と混ぜる。**最後のフレームの揺らしは
    ///   戻す** (``UpscaleStage/lastJitterInSource``) — 描く先の絵はその分ずれているので、戻さないと
    ///   変えていない場所まで最大で描く画素 0.5 個ずれる。代償は、揺らして重ねて収束した絵が、変えた
    ///   瞬間に 1 枚ぶんの三次補間に落ちること (次に描くフレームから積み上がり直す)。止まっている間に
    ///   置いて描き切らせた図形は、次のフレームの揺らしで描かれるので、最大で描く画素 1 個ずれる
    ///
    /// 環を 1 つ進めてから積む — 拡大の段は CPU が置き場へ書くので、描き切りと同じく、そのスロットを
    /// 最後に読んだ投入が終わっていなければならない。
    ///
    /// **記帳は投入の後だけ** ([#1183])。組み立てが投げれば、コマンドは捨てられて書き戻しも
    /// されない。書き込み待ちも印も残るので、次の出力段がやり直す。**古い絵を黙って返さない**よう、
    /// 拡大の段のように握り潰さず、出力段が投げる。
    ///
    /// [#1183]: https://github.com/mokume-metal/mokume/issues/1183
    /// [#1882]: https://github.com/mokume-metal/mokume/issues/1882
    func catchUpOutput() throws(RenderFailure) {
        guard let stage = upscaleStage else { return }
        try frameRing.advance()
        stagePassesUsed = 0
        let pipeline = try effectPipeline()
        let offset = stage.lastJitterInSource
        let wroteBack = try gpu.withCommands { commands throws(RenderFailure) in
            let wroteBack = try encodePixelWriteBackKeepingCarry(into: commands)
            try encodeEnlargement(using: pipeline, offset: offset, into: commands)
            gpu.commit(commands)
            return wroteBack
        }
        frameRing.noteSubmission()
        if wroteBack { target.markPixelsWrittenBack() }
        targetChangedSinceUpscale = false
    }

    /// 描く先が出す先そのものの面 (細かさ 1) で、まだ描く先へ戻していない画素の書き込みを
    /// 書き戻す ([#1906])。**書いていなければ何も積まない** (ADR-0023 決定 5)。
    ///
    /// 画素の書き込み (`set()`・`pixels`) は CPU の写しに載り、テクスチャへ戻すのは次の描き切りか
    /// 出力段である。窓と共有の面はテクスチャを直に読み、どちらも通らないので、止まっている間に
    /// 書いた画素は戻すまで出ない。効果を通した絵の後なら、同じ画素を効果を通す前の絵 (次の
    /// フレームの入り) へも写す (``encodePixelWriteBackKeepingCarry(into:)``・[#1524]) — 写さずに
    /// 戻すと、次のフレームの頭が控えを戻したときに書いた画素が消える。
    ///
    /// 環は進めない。積むのは写しからの blit と控えへの写しだけで、CPU が環の置き場へ書かない
    /// (出力段が書き戻すときと同じ)。
    ///
    /// **記帳は投入の後だけ** ([#1183])。組み立てが投げれば、コマンドは捨てられて書き込み待ちが
    /// 残るので、次のリフレッシュか出力段がやり直す。
    ///
    /// [#1183]: https://github.com/mokume-metal/mokume/issues/1183
    /// [#1524]: https://github.com/mokume-metal/mokume/issues/1524
    /// [#1906]: https://github.com/mokume-metal/mokume/issues/1906
    func writeBackPendingPixels() throws(RenderFailure) {
        guard target.hasPendingPixelWrites else { return }
        let wroteBack = try gpu.withCommands { commands throws(RenderFailure) in
            let wroteBack = try encodePixelWriteBackKeepingCarry(into: commands)
            gpu.commit(commands)
            return wroteBack
        }
        if wroteBack { target.markPixelsWrittenBack() }
    }

    /// 出す先を、止まっている間に変わった描く先に追い付かせる。**失敗しても投げない。**
    ///
    /// 止まっている間のコールバックを配った直後に、ランタイムが呼ぶ。画面 (窓)・共有の面・
    /// 書き出し・観測・CPU の読み出しは、どれも出す先を読むので、**コールバックを配る 1 点で追い
    /// 付けば、どの口も同じ 1 枚を受け取る** (ADR-0023 決定 2)。追い付き方は細かさで分かれる。
    ///
    /// - 細かさを下げた面: 書き戻して、出す先へ広げ直す (``catchUpOutput()``・[#1882])
    /// - 細かさ 1 の面: 描く先が出す先そのものなので、書いた画素を書き戻すだけ
    ///   (``writeBackPendingPixels()``・[#1906])
    ///
    /// 投げないのは、呼び手 (`advance()`) が観測に応えてから投げる作りだからで、失敗しても書き込み
    /// 待ちと印は残る — 次のリフレッシュがもう一度試し、出力段はやり直せなければ投げる。変えて
    /// いなければ何も積まない。
    ///
    /// [#1882]: https://github.com/mokume-metal/mokume/issues/1882
    /// [#1906]: https://github.com/mokume-metal/mokume/issues/1906
    func catchUpOutputWithoutThrowing() {
        guard upscaleStage == nil else {
            guard needsOutputEnlargement else { return }
            do {
                try catchUpOutput()
            } catch {
                warnOnce(.upscaleFailed, "Could not run the upscale: \(error.headline)")
            }
            return
        }
        do {
            try writeBackPendingPixels()
        } catch {
            warnOnce(
                .pixelWriteBackFailed,
                "Could not write the changed pixels back to the canvas: \(error.headline)"
                    + " — trying again on the next refresh")
        }
    }
}
