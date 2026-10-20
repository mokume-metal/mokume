// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import simd

// 勾配で塗る。意味の説明は ``Gradient`` と ``SketchPart/fill(_:)-(Gradient)`` が正本で、ここは受け口である
// ([ADR-0020] 決定 4)。
//
// **勾配は利用者の断片と同じ経路で描く。** 勾配を持つ間は、面が持つ勾配の断片 (``GradientShader``) を
// 塗りの断片 (``currentShader``) に置く。基本図形の列は断片が効いている間は使えない
// (``formAllowed(fills:)``) ので、円も字も三角形の経路で、利用者の断片で塗るのと同じ道を通る。
// 勾配の頂点は不透明度が負の印の色を持ち (``fillVertexColor``)、断片が勾配の頂点だけを勾配で塗る —
// 輪郭と線は色のままである。利用者が `shader(_:)` を置けばそちらが勝ち、勾配は効かない。
//
// [ADR-0020]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0020-api-naming-and-surface.md
extension Canvas {
    /// 勾配の頂点の色。**不透明度を負にして印にする** — 勾配の断片が見分け、色は掛け、不透明度は符号を
    /// 戻して掛ける (置き場所の色 `Placement.fill` が勾配に掛かる)。
    static let gradientMarker = LinearRGBA(premultipliedRed: 1, green: 1, blue: 1, alpha: -1)

    /// いま勾配の断片が塗りを持っているか。**不変条件:** `true` なら ``Style/gradient`` がある。
    var paintsWithGradient: Bool {
        guard let shader = gradientShaderStorage else { return false }
        return currentShader === shader
    }

    /// 塗りの頂点が持つ色。勾配で塗るときは印の色、そうでなければ塗りの色。
    ///
    /// **畳む雛形の頂点は印を付けない** (``buildingFlatTemplate``)。雛形の頂点の色は白で、色は置き場所
    /// (``FlatInstance/fill``) が持ち、頂点の色と掛け合わさる — 両方に印を付けると、負の不透明度どうしが
    /// 掛かって印が消える。
    var fillVertexColor: LinearRGBA {
        paintsWithGradient && !buildingFlatTemplate ? Self.gradientMarker : style.fill
    }

    /// 描く状態の塗りを勾配にする。
    ///
    /// 勾配を受けられなければ (区切りが無い・数でない値・点がつぶれている)、塗りは前のまま 1 度だけ知らせる。
    public func fill(_ gradient: Gradient) {
        let (resolved, problem) = ResolvedGradient.resolve(
            gradient, under: Affine2(transform.matrix))
        if let problem { warnGradient(problem) }
        guard let resolved else { return }
        setGradient(resolved)
        style.hasFill = true
        syncGradientShader()
    }

    /// 勾配を差し替える。**勾配で塗っている列は、変える前に閉じる** — 置いた図形が後の勾配で描かれない
    /// ように (列の値は閉じる時点の勾配が持つ・``livePaint``)。
    func setGradient(_ gradient: ResolvedGradient?) {
        guard style.gradient != gradient else { return }
        if paintsWithGradient { closeBatch() }
        style.gradient = gradient
    }

    /// 勾配の断片を、塗りの状態と合わせる。**呼ぶのは塗りの状態が変わるところ** — `fill(_:)`・`noFill()`・
    /// 状態の積み降ろし (``currentStyle``)・`resetShader()`。
    ///
    /// 勾配で塗るのは、塗りを持ち (`noFill()` でない)、勾配があり、利用者の断片が無いときだけである。
    /// 勾配が要らなくなれば断片を外し、輪郭は基本図形の列へ戻る。
    func syncGradientShader() {
        let wanted = style.hasFill && style.gradient != nil
        if wanted {
            // 利用者の断片が効いていれば、そちらが勝つ。勾配は覚えておくだけ
            guard currentShader == nil else { return }
            guard let shader = gradientShader() else {
                style.gradient = nil
                return
            }
            closeBatch()
            currentShader = shader
        } else if paintsWithGradient {
            closeBatch()
            currentShader = nil
        }
    }

    /// 勾配の断片。**初めて要るときに組む。** 組めなければ `nil` で、1 度だけ知らせる。
    private func gradientShader() -> Shader? {
        if let shader = gradientShaderStorage { return shader }
        guard !gradientShaderFailed else { return nil }
        do {
            let shader = try Shader(
                name: "mokume.gradient", url: nil, body: GradientShader.body,
                values: GradientShader.declarations, gpu: gpu, pipeline: pipeline)
            gradientShaderStorage = shader
            return shader
        } catch {
            gradientShaderFailed = true
            warnOnce(
                .gradientUnavailable,
                "fill(): the gradient shader could not be built (\(error)), so the fill was left as it was")
            return nil
        }
    }

    /// 開いている列が持つ塗りの値。**勾配の断片は、値を断片の宣言ではなく、いまの勾配から出す。**
    var gradientValues: [Float]? {
        guard paintsWithGradient, let gradient = style.gradient else { return nil }
        return gradient.packedValues
    }

    /// 形を組み立てる入口で、外で決めた勾配を形自身の座標で読み直す。組み立ての中は変換が単位から
    /// 始まるので、外の変換で決めた勾配の座標をそのまま持ち込むと、置く前の座標とずれる。
    func rebaseGradientForShapeAssembly() {
        guard let gradient = style.gradient else { return }
        setGradient(gradient.rebased(to: Affine2(transform.matrix)) ?? gradient)
    }

    /// 保持した形の区間を置くとき、記録した勾配の式へ置く変換 (`matrix`) の逆を掛け直した塗りを返す。
    /// 勾配の断片で塗った区間だけが対象で、ほかの塗りはそのまま返す。
    func paint(_ paint: Shape.Paint, placedBy matrix: simd_float4x4) -> Shape.Paint {
        guard let shader = gradientShaderStorage, paint.shader === shader,
            let values = ResolvedGradient.rebasing(paint.values, by: Affine2(matrix))
        else { return paint }
        var moved = paint
        moved.values = values
        return moved
    }

    /// 受けられなかった勾配を、初回だけ知らせる。
    private func warnGradient(_ problem: ResolvedGradient.Problem) {
        switch problem {
        case .noStops:
            warnOnce(.badGradient, "fill(): the gradient has no stops, so the fill was left as it was")
        case .badStop:
            warnOnce(
                .badGradient,
                "fill(): a gradient stop has a position or a colour that is not a number, or an infinite one, so the fill was left as it was"
            )
        case .badGeometry:
            warnOnce(
                .badGradient,
                "fill(): the gradient has no extent (the two points are the same, the radius is 0 or less, or a value is not a number), so the fill was left as it was"
            )
        case .tooManyStops:
            warnOnce(
                .tooManyGradientStops,
                "fill(): a gradient takes at most \(ResolvedGradient.stopCapacity) stops, so the first \(ResolvedGradient.stopCapacity) by position were used"
            )
        }
    }
}
