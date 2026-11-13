// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import simd

// 合成の単位 ([#3560]・親は [#2878] の 1 段目)。
//
// 重なる子を持つ群は、子の色ごとに不透明度を掛けると重なりだけ濃く描かれる。群全体にかかる
// 不透明度は、**群を 1 枚に描き切ってから 1 度だけ掛けて重ねる**ものである。その「1 枚に描き切って
// 1 度だけ重ねる」を、描画の内側に 1 つの口として持つ。**公開の口は足さない** — 公開する層の口は、
// 作例を置いた `Feature` から後で足す ([ADR-0043] 決定 2)。使い手は 2 段目 ([#3564]・SVG の群と要素)。
//
// 組み方は新しい仕組みを持たない。**中間面は ``createGraphics(_:_:)`` の描き場所そのもの**で、
// 重ねるのは画像として置く口と同じ 1 本の経路 (``appendImageQuad(_:x:y:width:height:uvMin:uvMax:color:)``)
// である。違うのは次の 3 点だけ。
//
// - 大きさは、中に描くものの外接 (描く先の座標で見た箱) に絞る
// - 中の変換は、置く側の変換に箱の左上への平行移動を掛けたもの (既定の視点で、描く格子が座標の格子と同じなら、
//   中の 1 画素が置く側の 1 画素に重なる)
// - 重ねる色は、不透明度を掛けた白 (乗算済み) — 絵の色は変えず、被覆と色を同じ割合で薄める
//
// [#2878]: https://github.com/mokume-metal/mokume/issues/2878
// [#3560]: https://github.com/mokume-metal/mokume/issues/3560
// [#3564]: https://github.com/mokume-metal/mokume/issues/3564
// [ADR-0043]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0043-features-start-from-examples.md
extension Canvas {
    /// 縁の余白 (座標の単位)。箱の外へにじむ縁の被覆 (アンチエイリアス) を、箱で切り落とさないための 1 つ分。
    static let compositeGroupMargin: Float = 1

    /// `body` が描いたものを 1 枚の中間面にまとめて描き、不透明度 `opacity` を **1 度だけ** 掛けて、この面の
    /// いまの位置へ重ねる。
    ///
    /// - 単位の中の重なりは、掛ける前に決まる。透明地に不透明な白い円を 2 つ重ねて `opacity` 0.5 の単位に
    ///   描くと、重なりも単独の部分も不透明度 0.5 になる (色ごとに 0.5 を掛けると重なりは 0.75 になる)。
    /// - **呼んだ順に重なる** ([ADR-0021] 決定 2)。単位の前に描いたものは下、後に描いたものは上。単位は
    ///   閉じる (この関数が返る) 時点でここの列へ置かれ、フレームの終わりまで待たない。
    /// - **入れ子は掛け合わさる。** 中の `body` がもう 1 つ単位を開くと、内側は外側の中間面へ重なり、外側が
    ///   閉じるときにもう 1 度掛かる (0.5 の中の 0.5 は 0.25)。
    /// - 線形・乗算済みで合成する ([ADR-0011])。同じ入力は同じ画素になる ([ADR-0025])。
    ///
    /// 中間面は ``createGraphics(_:_:)`` の描き場所で、`body` へ渡す。**座標は置く側のまま**で、中の
    /// 変換は置く側の変換に箱の左上への平行移動を掛けたもの。既定の視点で、描く格子が座標の格子と同じ
    /// (細かさ 1) なら、中の 1 画素が置く側の 1 画素に重なり、不透明度 1 の単位は単位なしと同じ画素に
    /// 載る — 検査が保証するのは ±1 (手元の GPU では全画素が同一だった)。中は透明で始まり、描き方
    /// (塗り・線・混ぜ方など) は既定から始まる。
    ///
    /// - Parameters:
    ///   - opacity: 0…1。**0 以下では `body` を呼ばない** (何も見えない)。1 を越える値 (+∞ を含む) は 1 に
    ///     締める。数でないときは何もしない。
    ///   - bounds: 中に描くものの外接 (この面のいまの変換の手前の座標)。**線の太さなど縁の余白は呼ぶ側が
    ///     含める。** 箱の外へ描いたものは出ない。中間面はこれを描く先の座標へ移した外接を、縁の余白
    ///     (``compositeGroupMargin``) の分だけ広げて整数へ丸め、この面の内側に絞った大きさになる。
    ///     絞った箱が空 (全部が面の外) なら `body` を呼ばない。
    ///   - settings: 中間面を置く四角の混ぜ方と塗り。`nil` なら置く側のもの。
    ///   - body: 中に描く。**平面の図形・字・絵だけを入れる** — 立体や視点は中間面の大きさで組まれるので、
    ///     置く側の視点を引き継がない。
    ///
    /// **置くときの設定 (断片・切り抜き・置く側の混ぜ方) は、置く側のものが単位の全体に 1 度効く。** 中の図形に
    /// 効かせたい設定は `body` の中で書く (中は既定の設定から始まる)。`settings` を渡すと、混ぜ方と断片は置く側の
    /// ものでなく `settings` で置く (保持した形の範囲は、記録したときの設定で置く・#3564 の反証 1)。
    ///
    /// - Returns: **単位にして描いたら (見えないので描くものが無い場合を含めて) `true`。単位にできなかった
    ///   ときは `body` を呼ばずに `false`。** 偽のとき何を描くか (子ごとに掛けるなど) は呼ぶ側が決める。
    ///   偽になるのは次のとき。
    ///   - 平面の図形が視点を通る (既定と違う視点を決めている・変換が奥行きを持つ。``currentFlatView``・#3830)。
    ///     素の場合 (既定の視点で、変換が平面を奥行き 0 の面に保つ) は変換の x・y がそのまま画素の位置だが、
    ///     視点を通る下では、中間面の画素と置く側の画素が重ならず、外接も移せない。
    ///   - 描く格子が座標の格子と違う (細かさを 1 未満にしている)。中間面は細かさ 1 の描き場所なので、
    ///     置く側の描く画素と重ならない。
    ///   - 四角を置く混ぜ方 (`settings` があればその混ぜ方、無ければ置く側の混ぜ方) が、透明な画素でも下地を
    ///     変える (``BlendMode/replace``)。単位の箱は四角で置かれ、
    ///     中の透明な画素もその混ぜ方で下地に載るので、`replace` では箱いっぱいの下地が消える。他のどの
    ///     混ぜ方もアルファ 0 の画素は下地を変えない (`CompositeGroupTests` が全部の混ぜ方で確かめる)。
    ///   - 形の組み立て (``createShape(_:)``) の中、またはフレームの外 (どちらも 1 度知らせる)。2 段目は、
    ///     保持した形を置く時点で呼ぶ。
    ///   - 外接の角が変換で数でない・無限になる (黙って箱を小さくしない)。
    ///   - 中間面を作れなかった (確保できない・1 度知らせる)。
    ///
    /// [ADR-0011]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0011-color-model.md
    /// [ADR-0021]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0021-solid-space-and-frame-assembly.md
    /// [ADR-0025]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0025-determinism-levels.md
    @discardableResult
    func withCompositeGroup(
        opacity: Float, covering bounds: PlaneBox, placedWith settings: (mode: BlendMode, paint: Shape.Paint)? = nil,
        _ body: (Canvas) -> Void
    ) -> Bool {
        // `replace` の判定は、四角を置く混ぜ方で見る (`settings` があればそちら)。保持した形の範囲は記録した
        // `blend` で置くので、置く側が `replace` でも単位にできる (#3564 の 2026-11-12 の決定)
        guard currentFlatView.clip == nil, target === output,
            (settings?.mode ?? style.blendMode).leavesBaseUnderTransparent
        else {
            return false
        }
        guard !recordingShape else {
            warnInsideShape(.compositeGroup)
            return false
        }
        guard writesToSurface else {
            warnOutsideFrame(.placing)
            return false
        }
        // 数でない不透明度は描かない。+∞ は 1 に締める (見えない側へは倒さない)
        guard !opacity.isNaN, opacity > 0 else { return true }
        let box: CompositeGroupBox
        switch compositeGroupBox(covering: bounds) {
        case .unplaceable: return false
        case .empty: return true
        case .box(let found): box = found
        }

        // **使い回すのは保持した形の範囲 (`settings` を渡す経路) だけ** (``compositeSurface(width:height:from:)``)
        let pool = settings != nil ? sketchCompositeSurfaces : nil
        let group: Canvas
        let reused: Bool
        do {
            (group, reused) = try compositeSurface(width: box.width, height: box.height, from: pool)
        } catch {
            // 保持した形の範囲 (`settings` を渡す) は、置く口が子ごとに掛けて描くことを 1 度知らせるので、ここでは
            // 重ねて知らせない (#3564 の反証 2 回目の 5)
            guard settings == nil else { return false }
            warnOnce(
                .compositeGroupSurface,
                "A composite group could not make its intermediate surface (\(error.headline)), so "
                    + "it was not drawn as one group")
            return false
        }

        group.beginDraw()
        // 使い回す面は前に描いた絵を持つので、透明へ塗り直す (作りたての面は作る時点で透明・#766)。
        // 塗り直しは描き切りの load 動作で済み、色も奥行きも作りたてと同じ値になる
        if reused { group.replaceSurface(with: .color(.transparent)) }
        // 箱の左上を中の原点にする。既定の視点では、平面の頂点は変換の x・y がそのまま画素の位置なので、
        // 平行移動を前から掛けるだけで、中の 1 画素が置く側の 1 画素に重なる
        let shift = simd_float4x4(
            SIMD4(1, 0, 0, 0), SIMD4(0, 1, 0, 0), SIMD4(0, 0, 1, 0),
            SIMD4(-Float(box.left), -Float(box.top), 0, 1))
        group.transform = Transform(matrix: shift * transform.matrix)
        if let failure = sketchCompositeSurfaces?.failSurfacesForTesting { group.failureForTesting = failure }
        body(group)
        // **描き切れなかった中間面は貼らない** (#4029 の反証 5)。描き切れなかったフレームは塗り直しの予定ごと
        // 捨てられるので、使い回した面は前に描いた別の置き場所の絵を持ったままである。作りたての面なら透明の
        // まま貼られて何も出なかったので、貼らずに同じ「何も出ない」にする。面は置き場へ戻さずに手放す。
        // 単位としては扱えた (呼ぶ側が子ごとに描き直さない) ので真を返す — 作りたての面のときと同じ
        guard group.closeDrawing() else {
            pool?.discard(group)
            return true
        }
        // 描いて伸びた置き場まで含めて、持ち越す重さを数え直す (上限を越えたら古い面から手放す)
        pool?.measure(group)

        placeCompositeGroup(group, in: box, opacity: min(opacity, 1), placedWith: settings)
        return true
    }

    /// **形の組み立ての中で**、`body` が記録するものを合成の単位の範囲として形に残す ([#3564])。
    ///
    /// 単位は形を置く時点で開く (``withCompositeGroup(opacity:covering:_:)`` は組み立ての中では開けない) ので、
    /// 記録の中では範囲の印だけを残す (``Shape/compositeGroups``)。範囲の前後で列を閉じ、範囲が他の区間と
    /// 1 つの区間に畳まれないようにする。何も記録しなければ範囲を残さない。
    ///
    /// - Parameters:
    ///   - bounds: 中に記録するものの外接 (**形自身の座標**。いまの変換は掛けない)。線の太さなど縁の分を含める。
    ///   - settings: 置くときに中間面を置く四角の混ぜ方と塗り (``Shape/CompositeRange/mode``)。`nil` なら、
    ///     いまの記録の混ぜ方と塗り。入れ子の記録へ範囲を引き継ぐときは、元の範囲のものを渡す (外側の記録の
    ///     混ぜ方を読まない — 中の区間も元の区間の設定で記録される)。
    ///
    /// [#3564]: https://github.com/mokume-metal/mokume/issues/3564
    func recordCompositeGroup(
        opacity: Float, covering bounds: PlaneBox, placedWith settings: (mode: BlendMode, paint: Shape.Paint)? = nil,
        _ body: () -> Void
    ) {
        guard recordingShape else { return body() }
        closeBatch()
        // 範囲は開いた時点で並びに置く (外側が先に並ぶ)。記録の途中で置いた側を描き切る逃げ道
        // (``flushBeforeBuild()``) が列を引き戻すと、置いた範囲も同じだけずれる
        let slot = recordedCompositeGroups.count
        recordedCompositeGroups.append(
            Shape.CompositeRange(
                runs: batches.count..<batches.count, opacity: opacity, bounds: bounds,
                mode: settings?.mode ?? style.blendMode, paint: settings?.paint ?? effectivePaint))
        body()
        closeBatch()
        guard slot < recordedCompositeGroups.count else { return }
        let start = recordedCompositeGroups[slot].runs.lowerBound
        if batches.count > start {
            recordedCompositeGroups[slot].runs = start..<batches.count
        } else {
            // 何も記録しなかった。中で開いた範囲も空なので、もう除かれている
            recordedCompositeGroups.remove(at: slot)
        }
    }

    /// 中間面が覆う、描く先の整数の箱。外接を変換で移し、縁の余白を足し、この面の内側に絞る。
    private func compositeGroupBox(covering bounds: PlaneBox) -> CompositeGroupBoxResult {
        let corners = [
            transform.placed(x: bounds.minX, y: bounds.minY), transform.placed(x: bounds.maxX, y: bounds.minY),
            transform.placed(x: bounds.maxX, y: bounds.maxY), transform.placed(x: bounds.minX, y: bounds.maxY),
        ]
        // 角が 1 つでも数でない・無限なら、箱を組まない (PlaneBox は無限の角を黙って落とすので、
        // 見えているはずの部分を切り落とした小さい箱になる)
        guard corners.allSatisfy({ $0.x.isFinite && $0.y.isFinite }) else { return .unplaceable }
        var placed = PlaneBox(corners[0])
        for corner in corners.dropFirst() { placed.add(corner) }
        // **丸める前に面の内側へ絞る。** 桁の大きな座標を整数へ移すと落ちる
        let margin = Self.compositeGroupMargin
        let left = max(0, (placed.minX - margin).rounded(.down))
        let top = max(0, (placed.minY - margin).rounded(.down))
        let right = min(width, (placed.maxX + margin).rounded(.up))
        let bottom = min(height, (placed.maxY + margin).rounded(.up))
        guard right > left, bottom > top else { return .empty }
        return .box(
            CompositeGroupBox(
                left: Int(left), top: Int(top), width: Int(right - left), height: Int(bottom - top)))
    }

    /// 中間面を 1 枚用意する。置き場 `pool` に読み終えた同じ形の面があれば使い回し (`reused` が真)、
    /// 無ければ ``createGraphics(_:_:)`` で作って置き場に載せる ([#4029])。
    ///
    /// **使い回すのは保持した形の範囲 (`pool` を渡す) だけ。** そこで中に描くのは記録した区間の置き直し
    /// (``replaying(_:_:)``) で、描き方を出入りで戻すので、面の描き方は既定のまま残る。ほかの `body` は
    /// 描き方 (塗り・線・断片など、フレームを越えて残るもの) を書き換えうるので、使い回すと次の単位が
    /// 「既定から始まる」を破る。そちらは前と同じく毎回作る。
    ///
    /// [#4029]: https://github.com/mokume-metal/mokume/issues/4029
    private func compositeSurface(
        width: Int, height: Int, from pool: CompositeSurfacePool?
    ) throws(RenderFailure) -> (Canvas, reused: Bool) {
        guard let pool else { return (try createGraphics(width, height), false) }
        if let kept = pool.take(width: width, height: height, for: self) { return (kept, true) }
        let made = try createGraphics(width, height)
        pool.keep(made, for: self)
        return (made, false)
    }

    /// この面がいま確保している GPU のバイト数 — 色と奥行きの面・字形の焼き場の頁・環に載る置き場
    /// (``FrameRing/bufferBytes``) の `allocatedSize` の合計。中間面の置き場が持ち越す重さに数える ([#4029])。
    ///
    /// 型板は memoryless なので数えない。ほかに面が持つもの (混ぜ方の番号の置き場・空の数の並び) は
    /// 数百バイトで、合計の検査 (`CompositeSurfacePoolTests`) が常駐の集合の増え方と突き合わせる。細かさを
    /// 下げた面の描く先も数える (中間面は細かさ 1 なので持たない)。
    ///
    /// [#4029]: https://github.com/mokume-metal/mokume/issues/4029
    var allocatedBytes: Int {
        let drawn = target === output ? 0 : target.allocatedBytes
        return output.allocatedBytes + drawn + atlas.texture.allocatedSize + frameRing.bufferBytes
    }

    /// 閉じた中間面を、不透明度を掛けて、この面へ画像として置く。置き先は箱の位置で、変換は掛けない
    /// (中の変換が既に箱の左上を原点にしている)。
    ///
    /// `settings` があれば、四角はその混ぜ方と塗りで置き、置く側の設定へ戻す (``replaying(_:_:)`` と同じ出入り。
    /// 同じなら列を閉じない)。
    private func placeCompositeGroup(
        _ group: Canvas, in box: CompositeGroupBox, opacity: Float,
        placedWith settings: (mode: BlendMode, paint: Shape.Paint)?
    ) {
        note(placing: group)
        // 絵はベクターへ埋め込まない (#3139)。**保持した形の範囲 (`settings` を渡す) は数えない** — 置く口が
        // `.retainedShape` として既に数えていて、利用者は画像を描いていない (#3564 の反証 2 回目の 6)
        if settings == nil { noteVectorDrop(.image) }
        let kept = transform
        transform = .identity
        defer { transform = kept }
        let savedMode = style.blendMode
        let savedPaint = replayedPaint
        if let settings {
            blendMode(settings.mode)
            usePaint(settings.paint)
        }
        // 乗算済みの白に不透明度を掛けたものを色に渡す。絵の被覆も色も同じ割合で薄まる
        appendImageQuad(
            group.drawnPicture, x: Float(box.left), y: Float(box.top),
            width: Float(box.width), height: Float(box.height),
            uvMin: .zero, uvMax: SIMD2(1, 1),
            color: LinearRGBA(
                premultipliedRed: opacity, green: opacity, blue: opacity, alpha: opacity))
        guard settings != nil else { return }
        // 戻す操作が列を閉じるので、いま置いた四角は記録した設定で描かれる
        blendMode(savedMode)
        if let savedPaint { usePaint(savedPaint) } else { stopReplayingPaint() }
    }
}

/// 合成の単位の中間面の置き場 ([#4029])。**スケッチに 1 つ** — 時刻の置き場の持ち主の面が持ち
/// (``Canvas/compositeSurfaces``)、描き場所も入れ子の中間面も、その 1 つから取る (``Canvas/sketchCompositeSurfaces``)。
///
/// 中間面は置き場所ごと・単位ごとに 1 枚要り、作るたびに描画先の確保・透明への塗り・面の組み立て
/// (列の置き場) を払っていた (100 個で 1 フレーム約 41 ms)。**同じ形の面を、読み終えたら使い回す。**
///
/// - **置いた側が読み終えるまで使い回さない。** 置いた面の絵は置いた側の描き切りまで読まれるので、その前に
///   描き換えると置いた側に写しを取らせることになる (``Canvas/settlePlacersBeforeChange()``)。面は置いた側が
///   フレームを出るとき (描き切った後か、捨てた後) に空きへ戻る (``leaveFrame(of:sweeping:)``)。入れ子の単位の
///   面は、外側の中間面が描き切った時点で空きへ戻るので、同じフレームの次の単位が使い回せる
/// - **形が完全に一致する面だけを使う** — 座標の大きさと書き出しの倍率 (画素の大きさ)・字形を置くか・GPU。
///   大きい面の一部を使うと、四角の貼り方 (uv) が変わり絵が 1 ビットでも変わりうる
/// - **寿命: 持ち主のフレームを 1 つ使われずに過ぎた面は、そのフレームの終わりに手放す。** 描き場所の中の面も
///   持ち主のフレームで数えるので、`setup()` で 1 度だけ描いた描き場所の面も持ち主の 2 フレーム目の終わりに
///   手放す。止めたスケッチ (`noLoop()`) は次のフレームが来ないので、止まったフレームの後に全部手放す
///   (``releaseAll()``・ランタイムが呼ぶ)
/// - **上限: 置き場が持つ面の合計 (使用中と空きの両方) が ``byteLimit`` まで。** 面の重さは実際に確保した
///   バイト数 (``Canvas/allocatedBytes``) で、描いた後に数え直す。越えたら古い空きから手放し、それでも越えるなら
///   その面を残さない (前と同じく、置き終えたら手放される)
///
/// [#4029]: https://github.com/mokume-metal/mokume/issues/4029
final class CompositeSurfacePool {
    /// 置き場が持つ中間面の合計の上限 (実際に確保したバイト数)。
    ///
    /// **#4029 の例 (152×122 の面を 100 枚) が収まる値にした。** 中間面 1 枚の確保は色と奥行きの面 (約 0.33 MB) より、
    /// 面ごとに持つ字形の焼き場の頁 (約 0.54 MB) と環に載る列の置き場 (描いた後で約 0.76 MB) のほうが重く、
    /// 152×122 で約 1.6 MB になる。100 枚で約 163 MB。上限はそれに余裕を足した 192 MiB で、1920×1080 の
    /// 中間面なら約 7 枚 (1 枚約 26 MB) にあたる。
    ///
    /// **使い回しが効かない置き方 (大きさが毎フレーム変わる) で、直す前より常駐が増えるのはこの上限まで。**
    /// 直す前は、作った面を GPU が読み終えれば手放していた (持ち越し 0)。
    static let defaultByteLimit = 192 << 20

    /// 持つ面の合計の上限。製品の経路では ``defaultByteLimit`` のままで、検査だけが小さくして越えたときを見る。
    var byteLimit = CompositeSurfacePool.defaultByteLimit

    struct Entry {
        let canvas: Canvas
        /// 描いた後に数え直した重さ (``Canvas/allocatedBytes``)。作って描く前は 0。
        var bytes: Int
        /// 置いた面。読み終える (置いた面がフレームを出る) まで `inUse` が立つ。
        weak var placer: Canvas?
        var inUse: Bool
        /// 最後に取った (作った) ときの持ち主のフレームの番号 (``epoch``)。
        var stamp: Int
    }

    /// 持っている面。古いものほど前にある (手放すのは前から)。
    private(set) var entries: [Entry] = []
    /// 持っている面の重さの合計。**上限と比べるのはこれ 1 つ。**
    private(set) var heldBytes = 0
    /// 持ち主のフレームの番号。持ち主のフレームの終わり (``leaveFrame(of:sweeping:)``) で進む。
    private(set) var epoch = 0
    /// 面を作った回数 (作ってから通算)。**使い回せていることを検査が見る。**
    private(set) var made = 0
    /// 使い回した回数 (作ってから通算)。
    private(set) var reused = 0

    /// 検査から「中間面を描き切れなかった」を作るための差し込み (``Canvas/failureForTesting`` を中間面に立てる)。
    /// 製品の経路では常に `nil`。
    var failSurfacesForTesting: RenderFailure?

    /// 空き (読み終えた面)。
    var free: [Entry] { entries.filter { !$0.inUse } }
    /// 使用中 (置いた側がまだ読む面)。
    var inUse: [Entry] { entries.filter(\.inUse) }

    /// `placer` が置く `width` × `height` (座標) の中間面に使える空きを、`placer` の使用中にして返す。
    func take(width: Int, height: Int, for placer: Canvas) -> Canvas? {
        guard
            let index = entries.firstIndex(where: { entry in
                !entry.inUse && entry.canvas.fits(width: width, height: height, placedBy: placer)
            })
        else { return nil }
        entries[index].inUse = true
        entries[index].placer = placer
        entries[index].stamp = epoch
        reused += 1
        return entries[index].canvas
    }

    /// 作った面を `placer` の使用中として載せる。重さは描いた後に数える (``measure(_:)``)。
    func keep(_ canvas: Canvas, for placer: Canvas) {
        made += 1
        entries.append(Entry(canvas: canvas, bytes: 0, placer: placer, inUse: true, stamp: epoch))
    }

    /// 描き切った面の重さを数え直す。合計が上限を越えたら古い空きから手放し、それでも越えるならこの面を
    /// 残さない。
    func measure(_ canvas: Canvas) {
        guard let index = entries.firstIndex(where: { $0.canvas === canvas }) else { return }
        let bytes = canvas.allocatedBytes
        heldBytes += bytes - entries[index].bytes
        entries[index].bytes = bytes
        while heldBytes > byteLimit, let oldest = entries.firstIndex(where: { !$0.inUse }) {
            remove(at: oldest)
        }
        if heldBytes > byteLimit, let index = entries.firstIndex(where: { $0.canvas === canvas }) {
            remove(at: index)
        }
    }

    /// 描き切れなかった面を手放す (置いた側へ貼らない面は、前の絵を持ったまま次に使わせない)。
    func discard(_ canvas: Canvas) {
        guard let index = entries.firstIndex(where: { $0.canvas === canvas }) else { return }
        remove(at: index)
    }

    /// `placer` がフレームを出た (置いた面を読み終えた)。`placer` の使用中の面を空きへ戻す。`sweeping` (持ち主の
    /// フレームの終わり) なら、このフレームで使わなかった面と置いた面が死んだ面を手放し、番号を進める。
    func leaveFrame(of placer: Canvas, sweeping: Bool) {
        for index in entries.indices where entries[index].inUse && entries[index].placer === placer {
            entries[index].inUse = false
            entries[index].placer = nil
        }
        guard sweeping else { return }
        for index in entries.indices.reversed() {
            let entry = entries[index]
            if entry.stamp < epoch || (entry.inUse && entry.placer == nil) { remove(at: index) }
        }
        epoch += 1
    }

    /// 全部手放す。次のフレームが来ない (止めた) ときにランタイムが呼ぶ。使用中の面を手放しても、置いた側の
    /// 列は面を自分で抱えている (``HeldTexture``) ので、読む前に解放されることはない。
    func releaseAll() {
        entries.removeAll()
        heldBytes = 0
    }

    private func remove(at index: Int) {
        heldBytes -= entries[index].bytes
        entries.remove(at: index)
    }
}

extension Canvas {
    /// この面を、`placer` が置く `width` × `height` (座標) の中間面として使えるか — `placer` の
    /// ``createGraphics(_:_:)`` が作る面と同じ形か。
    fileprivate func fits(width: Int, height: Int, placedBy placer: Canvas) -> Bool {
        outputScale == placer.outputScale && Int(self.width) == width && Int(self.height) == height
            && placesGlyphs == placer.placesGlyphs && gpu === placer.gpu
    }
}

/// 箱を求めた結果。
enum CompositeGroupBoxResult {
    /// 外接を移せない (角が数でない・無限)。
    case unplaceable
    /// 箱が空 (全部が面の外)。
    case empty
    case box(CompositeGroupBox)
}

extension BlendMode {
    /// アルファ 0 の画素 (透明な乗算済みの (0,0,0,0)) を、この混ぜ方で置いても下地が変わらないか。
    ///
    /// 合成の単位は箱いっぱいの四角で置くので、中の透明な画素も置く側の混ぜ方で下地に載る。変わるのは
    /// `replace` だけ — 形が掛かる画素を、アルファごと置いた色で置き換える。他の 8 つは `mokume_composite`
    /// (`blend` は固定機能の source-over) が、結果を `mix(下地, 混ぜた色, 置く側のアルファ)` で出すので
    /// アルファ 0 では下地そのもの。**全部の混ぜ方で実測した表が `CompositeGroupTests` にある** — 混ぜ方を
    /// 足すと、ここで決めるまでその検査が赤になる。
    var leavesBaseUnderTransparent: Bool {
        switch self {
        case .blend, .add, .subtract, .lightest, .darkest, .difference, .exclusion, .multiply, .screen: true
        case .replace: false
        }
    }
}

/// 中間面が覆う、描く先の座標の整数の箱。
struct CompositeGroupBox: Equatable {
    var left: Int
    var top: Int
    var width: Int
    var height: Int
}
