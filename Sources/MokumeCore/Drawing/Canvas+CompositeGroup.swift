// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import MokumeDiagnostics
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
// - 中の変換は、置く側の変換に箱の左上への平行移動を掛けたもの (中の 1 画素が置く側の 1 画素に重なる)
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
    /// 変換は置く側の変換に箱の左上への平行移動を掛けたもの — `body` の中で描く図形は、単位の外で描いたと
    /// きと同じ画素に載る (不透明度 1 の単位は、単位なしと 1 ビットも違わない)。中は透明で始まり、
    /// 描き方 (塗り・線・混ぜ方など) は既定から始まる。
    ///
    /// - Parameters:
    ///   - opacity: 0…1。**0 以下では `body` を呼ばない** (何も見えない)。1 を越えるときは 1 に締める。
    ///     数でないときは何もしない。
    ///   - bounds: 中に描くものの外接 (この面のいまの変換の手前の座標)。**線の太さなど縁の余白は呼ぶ側が
    ///     含める。** 箱の外へ描いたものは出ない。中間面はこれを描く先の座標へ移した外接を、縁の余白
    ///     (``compositeGroupMargin``) の分だけ広げて整数へ丸め、この面の内側に絞った大きさになる。
    ///     絞った箱が空 (全部が面の外) なら `body` を呼ばない。
    ///   - body: 中に描く。**平面の図形・字・絵だけを入れる** — 立体や視点は中間面の大きさで組まれるので、
    ///     置く側の視点を引き継がない。
    ///
    /// **置くときの設定 (混ぜ方・断片・切り抜き) は、置く側のものが単位の全体に 1 度効く。** 中の図形に
    /// 効かせたい設定は `body` の中で書く (中は既定の設定から始まる)。
    ///
    /// **形の組み立て (``createShape(_:)``) の中では使わない。** 2 段目は、保持した形を置く時点で呼ぶ。
    /// 中間面を作れなかった (確保できない) ときは、1 度知らせて何も描かない。
    ///
    /// - Returns: 単位として扱えたか。**視点を決めているとき (``camera()`` ほか) だけ偽で、`body` を呼ばない。**
    ///   平面の頂点は変換の x・y を視点の投影に通して落ちる。面に合わせた既定の視点なら変換の x・y がそのまま
    ///   画素の位置だが、決めた視点の下では、中間面の画素と置く側の画素が重ならず、外接も移せない。そのとき
    ///   どう描くか (子ごとに掛けるなど) は呼ぶ側が決める。
    ///
    /// [ADR-0011]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0011-color-model.md
    /// [ADR-0021]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0021-solid-space-and-frame-assembly.md
    /// [ADR-0025]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0025-determinism-levels.md
    @discardableResult
    func withCompositeGroup(
        opacity: Float, covering bounds: PlaneBox, _ body: (Canvas) -> Void
    ) -> Bool {
        guard cameraStorage == nil else { return false }
        guard !recordingShape else {
            assertionFailure("a composite group is placed, not recorded")
            return true
        }
        guard writesToSurface else {
            warnOutsideFrame(.placing)
            return true
        }
        guard opacity.isFinite, opacity > 0, let box = compositeGroupBox(covering: bounds) else { return true }

        let group: Canvas
        do {
            group = try createGraphics(box.width, box.height)
        } catch {
            Diagnostics.warn("composite group: could not make the intermediate surface: \(error.headline)")
            return true
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

        placeCompositeGroup(group, in: box, opacity: min(opacity, 1))
        return true
    }

    /// 中間面が覆う、描く先の整数の箱。外接を変換で移し、縁の余白を足し、この面の内側に絞る。
    /// 絞った箱が空なら `nil`。
    private func compositeGroupBox(covering bounds: PlaneBox) -> CompositeGroupBox? {
        let corners = [
            transform.placed(x: bounds.minX, y: bounds.minY), transform.placed(x: bounds.maxX, y: bounds.minY),
            transform.placed(x: bounds.maxX, y: bounds.maxY), transform.placed(x: bounds.minX, y: bounds.maxY),
        ]
        var placed: PlaneBox?
        for corner in corners { placed.include(corner) }
        // 数でない・無限の角は箱に入らない。4 角とも入らなければ何も描かれない
        guard let placed else { return nil }
        // **丸める前に面の内側へ絞る。** 桁の大きな座標を整数へ移すと落ちる
        let margin = Self.compositeGroupMargin
        let left = max(0, (placed.minX - margin).rounded(.down))
        let top = max(0, (placed.minY - margin).rounded(.down))
        let right = min(width, (placed.maxX + margin).rounded(.up))
        let bottom = min(height, (placed.maxY + margin).rounded(.up))
        guard right > left, bottom > top else { return nil }
        return CompositeGroupBox(
            left: Int(left), top: Int(top), width: Int(right - left), height: Int(bottom - top))
    }

    /// 閉じた中間面を、不透明度を掛けて、この面へ画像として置く。置き先は箱の位置で、変換は掛けない
    /// (中の変換が既に箱の左上を原点にしている)。
    private func placeCompositeGroup(_ group: Canvas, in box: CompositeGroupBox, opacity: Float) {
        note(placing: group)
        // 絵はベクターへ埋め込まない (#3139)。単位をベクターへどう書くかは 2 段目が決める
        noteVectorDrop(.image)
        let kept = transform
        transform = .identity
        defer { transform = kept }
        // 乗算済みの白に不透明度を掛けたものを色に渡す。絵の被覆も色も同じ割合で薄まる
        appendImageQuad(
            group.drawnPicture, x: Float(box.left), y: Float(box.top),
            width: Float(box.width), height: Float(box.height),
            uvMin: .zero, uvMax: SIMD2(1, 1),
            color: LinearRGBA(
                premultipliedRed: opacity, green: opacity, blue: opacity, alpha: opacity))
    }
}

/// 中間面が覆う、描く先の座標の整数の箱。
struct CompositeGroupBox: Equatable {
    var left: Int
    var top: Int
    var width: Int
    var height: Int
}
