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
    /// 初回だけ言い、並びの他の効果は掛ける。範囲を決めている数は端へ締め、**締めたときも 1 度だけ
    /// 言う** ([#1842]。`Effect.accepted`)。
    ///
    /// [#1544]: https://github.com/mokume-metal/mokume/issues/1544
    /// [#1842]: https://github.com/mokume-metal/mokume/issues/1842
    public func effects(_ effects: [Effect]) {
        // **効果はフレームを越えない** (ADR-0021 決定 4)。フレームの頭で捨てるので、外で
        // 決めた並びはどのフレームにも属さない。黙って捨てると「書いたのに効かない」だけが
        // 残るので、切り抜き (#1505) と同じく 1 度言って無視する (#1605)。形に焼き付かない
        // ので、形の組み立ての中ではフレームの中でも断る (`isShaping` ではなく `admits`・#1529)。
        // **値の検めより先に断る** — どのフレームにも属さない並びの値を言っても、直す先を
        // 指さない
        guard admits(.effects) else { return }
        pendingEffects = acceptedEffects(effects, calledBy: "effects")
        prepareEffectOutput()
    }

    /// 受け口で検めた効果の並び。**数でない値・無限を持つ効果は外して初回だけ言い、範囲の外の値は
    /// 端へ締めて 1 度だけ言う** ([#1544]・[#1842])。`effects(_:)` と `filter(_:)` が同じ検めを通る。
    ///
    /// [#1544]: https://github.com/mokume-metal/mokume/issues/1544
    /// [#1842]: https://github.com/mokume-metal/mokume/issues/1842
    func acceptedEffects(_ effects: [Effect], calledBy caller: String) -> [Effect] {
        effects.compactMap { effect in
            guard let accepted = effect.accepted else {
                warnOnce(
                    .badEffect,
                    "\(caller)(): the \(effect.name) effect held a value that is not a number, or an "
                        + "infinite one, so it was not applied")
                return nil
            }
            // 締めたときは、書いた値と違う値が効くことを 1 度だけ言う (#1842)。外した効果は締めない
            for rounding in effect.roundings {
                warnRounded(
                    rounding.warning, caller, rounding.quantity, takes: rounding.range,
                    passed: rounding.passed, used: rounding.used)
            }
            return accepted
        }
    }

    /// 呼んだ時点までに描いた絵へ、効果の並びを**その場で**掛ける。
    ///
    /// ``effects(_:)`` とは違い、フレームの終わりを待たない。**呼んだ後に描くものには掛からず、掛けた絵は
    /// 次のフレームへ持ち越す** (効果を通す前の絵に戻さない)。
    ///
    /// **寿命は「置いたもの」の側である** (図形・絵・背景・画素の書き込みと同じ・ADR-0021 決定 4 の追補
    /// (2026-09-27))。掛けた絵が次のフレームへ残るので、シーンの記述 (`effects()`) のようにフレームの中
    /// だけには限らず、持ち越しを約束する区間 — 本体の `setup()` と止まっている間のコールバック・描き場所の
    /// `beginDraw()`〜`endDraw()` — でも掛けられる。Processing の定番 (`setup()` で絵を置いて `filter(BLUR)`、
    /// `noLoop()`) が書ける。区間の外と、形の組み立ての中では 1 度言って何もしない。
    ///
    /// 呼んだ所は途中の描き切り (区切り) になる (``loadPixels()`` と同じ・ADR-0021 決定 3)。溜めた図形を
    /// 描き切ってから、描く先を入りとして効果の段を通し、通した絵を描く先へ書き戻す。書き戻しは全面の
    /// 写し 1 回である。**止まっている間に、効果を通した前のフレームの絵が描く先に残っているときは、
    /// 次のフレームの入りになる効果を通す前の絵 (控え) にも同じ並びを掛ける** (
    /// [#1524])。画面に出る絵と次のフレームの入りがずれない。効果を通せなかったときは、描く先はそのままで、
    /// 理由を 1 度知らせる。
    ///
    /// [#1524]: https://github.com/mokume-metal/mokume/issues/1524
    public func filter(_ effects: [Effect]) {
        guard admitsFilter() else { return }
        let accepted = acceptedEffects(effects, calledBy: "filter")
        guard !accepted.isEmpty else { return }
        do {
            try applyFilter(accepted)
        } catch {
            warnOnce(
                .filterFailed,
                "Could not run filter(): \(error.headline). The picture stays as it was before it")
        }
    }

    /// ``filter(_:)`` を受けてよいか。**持ち越しを約束する区間かフレームの中**で、形の組み立ての中ではない。
    ///
    /// 断るときは 1 度だけ理由を言う。区間の外は ``OutsideFrame/filter`` (置く口と同じ区間の言い方)、
    /// 組み立ての中は ``InsideShape/filter``。見るのは ``writesToSurface`` で、``isDrawing`` ではない —
    /// 掛けた絵は残るので、置いたものと同じ区間で許す (画素を書く口 ``admitsPixelWrite()`` と同じ形)。
    func admitsFilter() -> Bool {
        guard writesToSurface else {
            warnOutsideFrame(.filter)
            return false
        }
        // 描き切ってから掛けるので、組み立ての中で通すと溜め場を描き切って組み立ての区間を壊す
        guard !recordingShape else {
            warnInsideShape(.filter)
            return false
        }
        return true
    }

    /// ``filter(_:)`` の本体。描き切ってから、段を描く先 → 中間の絵と通し、最後の絵を描く先へ写す。
    ///
    /// **効果の控え (``EffectPipeline/carry()``) は取り替えない。** 控えは「効果を通す前の絵」を次のフレームの
    /// 入りに残すための面で、掛けた絵を持ち越すこの口とは役割が逆になる。取り替えず、中間の絵を経て写す。
    /// 止まっている間に控えが生きているとき (``changesGoIntoCarry``) は、控えにも同じ並びを掛けて写す。
    func applyFilter(_ effects: [Effect]) throws(RenderFailure) {
        let passes = effects.flatMap { $0.passes(drawnPerOutput: effectRadiusScale) }
        guard !passes.isEmpty else { return }
        // 途中の描き切り。効果は掛けない (フレームの終わりの `effects(_:)` が掛ける分は、まだ溜めたまま)
        try flush(applyingEffects: false)
        let pipeline = try effectPipeline()
        // 掛ける面。**描き切りの後で見る** — フレームの中の最初の描き切りは控えを描く先へ戻して印を下ろし、
        // 止まっている間の描き切りは控えにも図形を描いて印を残す
        var surfaces: [any EffectSurface] = [target]
        if changesGoIntoCarry, let carry = pipeline.existingCarry { surfaces.append(carry) }
        // 描く先を書き換える口は、書く前に置いた側へ写させる (#1942)
        settlePlacersBeforeChange()
        try frameRing.advance()
        stagePassesUsed = 0
        try pipeline.reservePasses(passes.count * surfaces.count)

        let held: [AnyObject] = effects.compactMap {
            if case .custom(let shader) = $0 { shader } else { nil }
        }
        _ = try gpu.withCommands { commands throws(RenderFailure) in
            for surface in surfaces {
                let (result, _) = try encodeEffectPasses(
                    passes, startingFrom: surface, using: pipeline, in: commands)
                // 通した絵 (最後の `.next`) を元の面へ写す。描く先へは出す先を書く最下層の口を通る
                // (関所の検算つき・``RenderTarget/encodeOverwrite(with:into:)``)
                if surface === target {
                    try target.encodeOverwrite(with: result.texture, into: commands)
                } else {
                    try RenderTarget.copy(result.texture, into: surface.texture, in: commands)
                }
            }
            return gpu.commit(
                commands, retaining: held, writing: surfacesWritten(drawing: true, upscaling: false))
        }
        frameRing.noteSubmission()
        // 描く先が変わった。細かさを下げた面は、出す先が追い付き直す。読んでおいた画素の写しは古い
        if upscaleStage != nil {
            targetChangedSinceUpscale = true
            placingCatchUpDeferred = false
        }
        hasLoadedPixels = false
    }

    /// 段の並びを `start` の絵から順に積む。**フレームの終わりの ``encodeEffects(into:)`` と
    /// ``applyFilter(_:)`` が同じ 1 本を通る** — 中間の絵の振り分けと往復の進め方を写さない。
    ///
    /// - Parameters:
    ///   - start: 入りの絵。最初の段はここから読む。
    ///   - lastOutput: 渡すと、最後の `.next` の段がここへ直接書く (``encodeEffects(into:)`` が出す面を
    ///     渡す。入りの絵は描く先なので、読んでいる面へ書くことにはならない・#755)。渡さなければ中間の絵に書く。
    /// - Returns: 最後に書いた絵と、`lastOutput` へ書いたか。段が `.next` に書かなければ、最後の絵は `start`。
    func encodeEffectPasses(
        _ passes: [EffectPass], startingFrom start: any EffectSurface,
        lastOutput: (any EffectSurface)? = nil,
        using pipeline: EffectPipeline, in commands: any MTL4CommandBuffer
    ) throws(RenderFailure) -> (current: any EffectSurface, wroteLastOutput: Bool) {
        /// いまの絵。**最初は入りの絵** — 控えへ写さずそのまま読む (#2388)。
        var current = start
        var nextSlot = 0
        var wroteLastOutput = false

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
            // **最後の段は出す面へ直接書く** (#755)。入りの絵は描く先なので、1 段だけの
            // 並びやにじみ単独の合成のように入りの絵を読む段でも、読んでいる面へ書く
            // ことにはならない (同じ面を読みながら描くのは Metal では未定義で、かつては
            // その並びだけ控えへ書いてから写し戻していた)。書いた絵が次のフレームの
            // 入りにならないのは、描く先と取り替わった控えから戻すため (#1469)
            let isLast = lastOutput != nil && position == passes.count - 1 && pass.output == .next
            let destination = isLast ? lastOutput! : try image(of: pass.output)
            try encode(
                pass, at: takeStagePass(), from: source.texture, paired: paired.texture,
                into: destination, using: pipeline, in: commands)
            if pass.output == .next {
                current = destination
                nextSlot = 1 - nextSlot
                wroteLastOutput = isLast
            }
        }
        return (current, wroteLastOutput)
    }

    /// 効果を通した絵の出す面 (``EffectPipeline/carry(startingTransparent:)``) を、組み立てに入る前に、塗って
    /// 作っておく ([#2388])。
    ///
    /// 出す面は、最初の効果を通すフレームの最後の段が書くまで何も書かれていない。取り替えは組み立ての最中に
    /// 済ませるので、その投入が打ち切られると、取り替えた描く先を読む側 (窓・書き出し・同じフレームに置いた
    /// 面) は、結末が届いて取り替えが戻るまでの間、書かれていない面を読む。作るときに透明な黒へ塗って
    /// おけば、そのとき読んでも未定義ではない。塗るのは自分の投入を 1 本積むので、組み立ての最中には
    /// できない — 利用者の描く手前の、ここで済ませる。作れなければ (資源が枯れた・組み立ての最中)、
    /// 描き切りが塗らずに作る。効果を頼まないスケッチは何も払わない。
    ///
    /// [#2388]: https://github.com/mokume-metal/mokume/issues/2388
    private func prepareEffectOutput() {
        guard !pendingEffects.isEmpty, let pipeline = try? effectPipeline(),
            pipeline.existingCarry == nil
        else { return }
        _ = try? pipeline.carry(startingTransparent: true)
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
    /// **描く先を入りの絵として読み、最後の段が控え (``EffectPipeline/carry()``) へ書く。** 控えは
    /// このフレームの出す面で、書けたら描く先と**面を取り替える** (``exchangeTargetWithCarry()``・
    /// [#2388])。取り替えた後の描く先が効果を通した絵 (画面・書き出し・読む画素はこれ) で、控えが
    /// 効果を通す前の絵 (次のフレームの入り) になる — 全画面を写す blit は 1 つも積まない。段の
    /// 失敗はすべてコマンドを組む時点で起きるので、最後の段の組み立てに失敗すれば控えへは 1 命令も
    /// 積まれず、取り替えも起きない。だから**途中で失敗しても「途中の絵」は出ない** — 描く先は 1 ビットも
    /// 変わっていない (#755 で書き戻しの段を消しても、ここは変わらない)。
    ///
    /// **描く先に残った効果は、次のフレームの入りにならない** ([#1469])。控えには効果を
    /// 通す前の絵が残るので、次のフレームの最初の描き切りがそこへ戻す (面を取り替える・
    /// ``Canvas/flush(applyingEffects:mirroringPixels:)``)。細かさ 1 では描く先と出す先が同じ 1 枚で、
    /// 出口へ届ける絵はその 1 枚に載るので、戻さなければ塗り直さずに描き足すスケッチで
    /// 効果がフレームごとに重なる。
    ///
    /// 頼まれていなければ段も取り替えも 1 つも積まず、控えも作らないので、効果を使わない
    /// スケッチはここで何も払わない (代表シーンの台帳が動かないのもこれによる)。
    ///
    /// 効果を通す。**失敗しても投げない。**
    ///
    /// 効果は毎フレーム走るので、投げると 1 段の失敗でフレームごと落ちる ([ADR-0020]
    /// 決定 5)。描く先を書く段の手前で止まれば描く先は無傷なので、**入りをそのまま
    /// 通して**理由を知らせる。
    ///
    /// - Returns: 効果を通した絵を出す面へ書き、面を取り替えたか。取り替えたなら、描く先が効果を通した
    ///   絵で、効果を通す前の絵は控えにある。
    ///
    /// [#1469]: https://github.com/mokume-metal/mokume/issues/1469
    /// [#2388]: https://github.com/mokume-metal/mokume/issues/2388
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
        // 数えてよい)
        try pipeline.reservePasses(stagePassesUsed + passes.count + upscalePassCount)
        /// 出す面。**最後の段が書く先で、描く先とは別の面** — 入りの絵を読みながら同じ面へ書く
        /// ことにならない (同じ面を読みながら描くのは Metal では未定義)。
        let output = try pipeline.carry()
        // 段は共通の 1 本 (``encodeEffectPasses(_:startingFrom:lastOutput:using:in:)``)。入りの絵は描く先で、
        // 控えへ写さずそのまま読む (#2388)
        let (_, wroteOutput) = try encodeEffectPasses(
            passes, startingFrom: target, lastOutput: output, using: pipeline, in: commands)

        // **出す面へ書いたら、描く先と取り替える。** 後の段 (拡大・読み戻し) は描く先を読むので、
        // ここで取り替えてから積む。途中で失敗すればここへ来ない
        guard wroteOutput else { return false }
        exchangeTargetWithCarry()
        return true
    }

    /// 描く先と効果の控えの面を取り替える ([#2388])。**写さない。**
    ///
    /// 効果を通すフレームの終わりと、次のフレームの最初の描き切りの 2 か所で使う。
    ///
    /// - フレームの終わり: 最後の段が控えへ書いた効果を通した絵が描く先になり、効果を通す前の絵
    ///   (描いてきた描く先) が控えになる
    /// - 次のフレームの頭 (塗り直さないとき): 効果を通す前の絵 (控え) が描く先に戻り、効果を通した絵は
    ///   控えへ退く。効果を通した絵はもう読まれない — 控えの中身は、次に最後の段が全画素を書き直す
    ///
    /// **自分に戻る** (2 回取り替えれば元の面)。組み立てが投げて投入されなかった描き切りは、取り替えを
    /// この口でもう一度取り替えて戻す ([#1183] と同じ作法・``flush(applyingEffects:mirroringPixels:)``)。
    /// 打ち切られた投入は、その投入の取り替えを ``carryDropped(_:)`` が戻す。取り替えるのは
    /// ``RenderTarget/exchangeTexture(with:)`` で、描く先と控えは**面だけを入れ替える** — 面を溜める側は
    /// 面を値で写し取らず描き場所を持つ (``HeldTexture``)。効果を通した絵がまだ無い面 (控えを作っていない面)
    /// では何もしない。
    ///
    /// [#1183]: https://github.com/mokume-metal/mokume/issues/1183
    /// [#2388]: https://github.com/mokume-metal/mokume/issues/2388
    func exchangeTargetWithCarry() {
        guard let carry = effectPipelineStorage?.existingCarry else { return }
        target.exchangeTexture(with: carry)
    }

    // MARK: - 止まっている間に変えた分 (#1524)

    /// 止まっている間に描く先を変えるなら、同じ変更を控え (効果を通す前の絵) にも加えるか ([#1524])。
    ///
    /// **効果を通したフレームの後、次のフレームが控えを戻すまでの間は、描く先と控えの 2 枚を保つ。**
    /// 描く先は効果を通した絵に変えた分を載せたもの (画面・書き出し・読む画素はこれ)、控えは効果を
    /// 通す前の絵に同じ変更を載せたもの (次のフレームの入りはこれ) である。変えるたびに両方へ
    /// 加えるので、混ぜ方 (縁の AA・半透明・足す混ぜ方) はどちらも置いた面の上で決まる。
    ///
    /// 控えは次のフレームの頭で描く先へ戻る (面の取り替え・``exchangeTargetWithCarry()``) ので、
    /// 塗り直すフレームでは使われない。
    ///
    /// [#1524]: https://github.com/mokume-metal/mokume/issues/1524
    var changesGoIntoCarry: Bool {
        carriesPictureBeforeEffects && effectPipelineStorage?.existingCarry != nil
    }

    /// 書き込み待ちの画素を描く先へ書き戻し、**同じ画素を控えにも書く** ([#1524])。控えへ加える
    /// 要が無ければ (``changesGoIntoCarry``)、ふつうに書き戻すだけである。
    ///
    /// 画素の書き込みは値そのものを置く (下地と混ぜない) ので、書き戻す前の描く先と比べて
    /// **値が変わった画素**だけを控えへ写す。値で見分けるので、描く先と同じ値を書いた画素
    /// (読んだ値をそのまま書き戻した画素を含む) は、書かなかった扱いになる (甲-1)。
    ///
    /// 描き切りの頭と出力段 (``RenderTarget/encodeToImage()``)・止まっている間のコールバックを配った
    /// 直後の追い付き (細かさを下げた面は ``catchUpOutput()``、細かさ 1 の面は
    /// ``writeBackPendingPixels()``) が、書き戻す口として呼ぶ。
    ///
    /// - Returns: 書き戻しを積んだか。**投入してから** `markPixelsWrittenBack(by:)` する ([#1183])。
    ///
    /// [#1183]: https://github.com/mokume-metal/mokume/issues/1183
    /// [#1524]: https://github.com/mokume-metal/mokume/issues/1524
    func encodePixelWriteBackKeepingCarry(into commands: any MTL4CommandBuffer)
        throws(RenderFailure) -> Bool
    {
        guard changesGoIntoCarry, target.hasPendingPixelWrites else {
            return try target.encodePixelWriteBack(into: commands)
        }
        try encodeKeepPicture(into: commands)
        let wroteBack = try target.encodePixelWriteBack(into: commands)
        try encodeKeepChanged(into: commands)
        return wroteBack
    }

    /// 描く先を、書き戻す前の写し (``EffectPipeline/pictureBeforeChange()``) へ写す blit を積む。
    func encodeKeepPicture(into commands: any MTL4CommandBuffer) throws(RenderFailure) {
        let kept = try effectPipeline().pictureBeforeChange()
        guard let encoder = commands.makeComputeCommandEncoder() else {
            throw .encoderUnavailable
        }
        encoder.barrier(
            afterQueueStages: [.fragment, .blit], beforeStages: .blit, visibilityOptions: .device)
        encoder.copy(sourceTexture: target.texture, destinationTexture: kept.texture)
        // **写し終わるのを、続く書き戻し・描画・読み戻しが待つ**
        encoder.barrier(
            afterStages: .blit, beforeQueueStages: [.vertex, .fragment, .blit],
            visibilityOptions: .device)
        encoder.endEncoding()
    }

    /// 描く先のうち、書き戻す前の絵 (``EffectPipeline/pictureBeforeChange()``) と**違う画素だけ**を、
    /// 効果を通す前の絵の控え (``EffectPipeline/carry()``) へ写す段を積む ([#1524])。画素を書き戻す
    /// たびに、その直後に積む (``encodePixelWriteBackKeepingCarry(into:)``)。
    ///
    /// **段の並びの外に置く。** 効果ではないので、効果の数 (``effectPassesEncoded``) にも入れない。
    ///
    /// 書き込む先は前の内容を読む (`.load`)。捨てた画素 (変わっていない画素) に、効果を通す前の
    /// 絵がそのまま残るためである。
    ///
    /// [#1524]: https://github.com/mokume-metal/mokume/issues/1524
    func encodeKeepChanged(into commands: any MTL4CommandBuffer) throws(RenderFailure) {
        let pipeline = try effectPipeline()
        guard let carry = pipeline.existingCarry else { return }
        let kept = try pipeline.pictureBeforeChange()
        let state = try pipeline.keepChangedState()
        // 段の採番からは取らない — 出力段からも積まれるため (``EffectPipeline/keepChangedTable()``)
        let table = try pipeline.keepChangedTable()
        table.setTexture(target.texture.gpuResourceID, index: EffectPipeline.sourceTextureIndex)
        table.setTexture(kept.texture.gpuResourceID, index: EffectPipeline.pairedTextureIndex)

        let pass = MTL4RenderPassDescriptor()
        let attachment = pass.colorAttachments[0]!
        attachment.texture = carry.texture
        attachment.loadAction = .load
        attachment.storeAction = .store
        guard let encoder = commands.makeRenderCommandEncoder(descriptor: pass) else {
            throw .encoderUnavailable
        }
        // **書き戻しと控えへの写し (blit) が終わるのを待つ** (#341)
        encoder.barrier(
            afterQueueStages: [.fragment, .blit], beforeStages: .fragment,
            visibilityOptions: .device)
        encoder.setRenderPipelineState(state)
        encoder.setViewport(
            MTLViewport(
                originX: 0, originY: 0, width: Double(carry.width), height: Double(carry.height),
                znear: 0, zfar: 1))
        encoder.setArgumentTable(table, stages: [.vertex, .fragment])
        encoder.drawPrimitives(primitiveType: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()
        effectChangesKeptEncoded += 1
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
        // 段の面の大きさと、出す大きさ。断片は位置と大きさを出す画素で受け取る (#1639) ので、
        // ラスタの位置 (段の面の画素) に掛ける比をこの 2 つから作る。段の面は縮めた脇の面の
        // こともあるので、``unitsPerDrawnPixel`` ではなく段ごとの大きさで割る
        var frame = (
            SIMD4<Float>(Float(destination.width), Float(destination.height), time, 0),
            SIMD4<Float>(width, height, 0, 0))
        block.advanced(by: EffectPipeline.frameOffset)
            .copyMemory(from: &frame, byteCount: EffectPipeline.frameSize)
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
        // 組み込みの効果は種別に特化したパイプラインで走る (``EffectPipeline/builtinState(for:)``)。
        // 組むのは投げうる仕事なので、口を開く前に済ませる
        let state: any MTLRenderPipelineState
        if let shader = pass.shader {
            state = shader.state
        } else {
            state = try pipeline.builtinState(for: pass.builtinKind)
        }
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

        encoder.setRenderPipelineState(state)
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
