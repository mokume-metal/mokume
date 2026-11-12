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
    ///   - 置く側の混ぜ方が、透明な画素でも下地を変える (``BlendMode/replace``)。単位の箱は四角で置かれ、
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
        // `replace` の判定は、四角を置く混ぜ方 (`settings`) ではなく置く側の混ぜ方で見る (#3564 の完了条件 9 が
        // 名指す場面。四角を記録した混ぜ方で置くときに外せるかは、条件 9 を改める判断が先)
        guard currentFlatView.clip == nil, target === output, style.blendMode.leavesBaseUnderTransparent else {
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

        let group: Canvas
        do {
            group = try createGraphics(box.width, box.height)
        } catch {
            warnOnce(
                .compositeGroupSurface,
                "A composite group could not make its intermediate surface (\(error.headline)), so "
                    + "it was not drawn as one group")
            return false
        }

        group.beginDraw()
        // 箱の左上を中の原点にする。既定の視点では、平面の頂点は変換の x・y がそのまま画素の位置なので、
        // 平行移動を前から掛けるだけで、中の 1 画素が置く側の 1 画素に重なる
        let shift = simd_float4x4(
            SIMD4(1, 0, 0, 0), SIMD4(0, 1, 0, 0), SIMD4(0, 0, 1, 0),
            SIMD4(-Float(box.left), -Float(box.top), 0, 1))
        group.transform = Transform(matrix: shift * transform.matrix)
        body(group)
        group.endDraw()

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
        // 絵はベクターへ埋め込まない (#3139)。単位をベクターへどう書くかは 2 段目が決める
        noteVectorDrop(.image)
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
