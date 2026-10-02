// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT
//
// 三角形の経路と立体で、描く画素で 1 画素より細い線を補う仕組み (#1637)。
//
// **説明文は置かない。** 正本は上の層 (ADR-0020 決定 4) で、api-surface.py の
// slash_doc は宣言の直前に積んだ `//` も説明文として拾う。この覚え書きが
// 拾われないよう、宣言との間は必ず 1 行空ける。

import simd

extension Canvas {

    /// 描く画素で 1 画素より細い線・輪郭・点の補い ([#1637])。
    ///
    /// 三角形の経路の縁には AA が無い (ADR-0039 決定 3) ので、描く画素で 1 画素より細い帯は、
    /// 画素の中心を跨ぐかどうかで**丸ごと消えるか、満濃度の 1 行になる**。光の量が置く位置で
    /// 0 か 2 倍かに振れ、`pixelDensity` 0.5 の太さ 1 の線がこれに当たる (細かさ 1 の太さ 0.5 も
    /// 同じ)。`strokeWeight` の説明 (「1 画素より細い線は、置く位置によらず太さに比例した濃さで
    /// 出る」) は経路を限らないので、距離関数の経路 (#1488) と同じ約束をここで守る。
    ///
    /// **帯を描く画素 1 つの太さへ広げ、色の不透明度を太さの割合に下げる。** 太さちょうど 1 の
    /// 帯は、向きが軸に沿っていれば置く位置によらず 1 行 (1 列) の画素の中心を跨ぐので、光の量が
    /// 太さに比例する。斜めの帯は列ごとに 1 行か 2 行になるが、跨ぐ中心の数の平均は面積に等しい。
    /// 不透明度が 1 未満になるので、片 (帯・角・端) の重なりは引いて積む経路 (#1536) が 1 回だけ
    /// 混ぜる。
    ///
    /// **点は描く画素 1 つの軸に沿った正方形にして、不透明度を面積 (太さの 2 乗) に下げる。**
    /// 直径 1 の円板は置く位置によって画素の中心を 1 つも含まないので、丸い点もこの形にする
    /// (距離関数の経路の細い点と同じ量 — `halfDensityPointsKeepTheirArea`)。
    ///
    /// 描く画素で 1 画素以上の線は何も変えない (この型が作られない)。
    ///
    /// [#1637]: https://github.com/mokume-metal/mokume/issues/1637
    struct ThinStroke {
        /// 太さに掛ける倍率。掛けると描く画素でちょうど 1 になる。
        let widen: Float
        /// 色の不透明度 (乗算済みの全成分) に掛ける値。線は太さ、点は面積。
        let opacity: Float
        /// 点 (端点の形だけの周) か。描く画素 1 つの正方形にする。
        let isPoint: Bool

        /// 描く画素での太さが 1 未満のときだけ作る。0 (潰れた変換) と数でない値は補わない。
        init?(drawnWeight: Float, isPoint: Bool) {
            guard drawnWeight > 0, drawnWeight < 1, drawnWeight.isFinite else { return nil }
            widen = 1 / drawnWeight
            opacity = isPoint ? drawnWeight * drawnWeight : drawnWeight
            self.isPoint = isPoint
        }

        /// 補った線の色。
        func color(_ color: LinearRGBA) -> LinearRGBA {
            LinearRGBA(
                premultipliedRed: color.red * opacity, green: color.green * opacity,
                blue: color.blue * opacity, alpha: color.alpha * opacity)
        }
    }

    /// 形自身の座標の太さ `weight` を、行列 `matrix` で置いたときの描く画素での太さ。
    ///
    /// 出す画素から描く画素への比は ``unitsPerDrawnPixel`` から取る (#1686 完了条件 5)。
    /// **倍率は 2x2 の行列式 (面積の倍率) の平方根で測る** — 拡大・回転・一様な伸び縮みでは
    /// 太さの倍率そのものである。縦と横で倍率の違う変換では、線の向きによって描く画素での太さが
    /// 違うのに 1 つの値で判断する近似になる (補いが要らない向きの線も、不透明度を下げて広げる)。
    func drawnWeight(_ weight: Float, placedBy matrix: simd_float4x4) -> Float {
        let columns = matrix.columns
        let area = abs(columns.0.x * columns.1.y - columns.0.y * columns.1.x)
        let units = unitsPerDrawnPixel
        return weight * (area / (units.x * units.y)).squareRoot()
    }

    /// 立体の線の描く画素での太さ。**立体の線の太さは出す画素**で書かれている
    /// (視線に正対させて画面の画素で組む) ので、変換によらず細かさだけで決まる。
    func drawnSolidWeight(_ weight: Float) -> Float {
        let units = unitsPerDrawnPixel
        return weight / (units.x * units.y).squareRoot()
    }

    /// 平面の輪郭を、いまの変換で置いたときに補う量。**最後の変換が決まらない 2 か所では
    /// 判断しない** — 畳みの雛形 (置き場所ごとに変換が違う。細い置き場所は畳まない) と、
    /// 保持する形の記録 (置くときに判断する・``ThinStrokeRecipe``)。線の半画素の寄せ
    /// (`strokePoint`) を先送りする 2 か所と同じである。
    func thinStroke(for outline: Outline) -> ThinStroke? {
        guard !buildingFlatTemplate, !recordingShape else { return nil }
        return ThinStroke(
            drawnWeight: drawnWeight(style.strokeWeight, placedBy: transform.matrix),
            isPoint: outline.points.count == 1)
    }

    /// 補いを当てた線の設定 (太さ・色・点の端の形) で `body` を走らせ、元へ戻す。
    func withThinStroke(_ thin: ThinStroke?, _ body: () -> Void) {
        guard let thin else { return body() }
        let saved = (style.strokeWeight, style.stroke, style.strokeCap)
        style.strokeWeight *= thin.widen
        style.stroke = thin.color(style.stroke)
        // 向きの無い点の四角い端は、形の座標の軸に沿った正方形 (`appendSquare(at:half:)`)
        if thin.isPoint { style.strokeCap = .square }
        body()
        (style.strokeWeight, style.stroke, style.strokeCap) = saved
    }

    /// 保持した形の輪郭を、置いた後の太さで組み直した頂点。**細くならなければ `nil`** で、
    /// 呼ぶ側は記録した頂点をそのまま置く。
    ///
    /// 頂点は記録した頂点と同じ座標 (形自身の座標に記録のときの変換を掛け、半画素寄せの前)
    /// で返すので、呼ぶ側は記録した頂点と同じく置き場所の行列と色を掛けて寄せる。
    func thinVertices(
        _ recipe: ThinStrokeRecipe, placedBy matrix: simd_float4x4
    ) -> [ShapeVertex]? {
        guard
            let thin = ThinStroke(
                drawnWeight: drawnWeight(
                    recipe.weight, placedBy: matrix * recipe.transform.matrix),
                isPoint: recipe.outline.points.count == 1)
        else { return nil }
        let saved = (style.strokeCap, style.strokeJoin)
        style.strokeCap = thin.isPoint ? .square : recipe.cap
        style.strokeJoin = recipe.join
        let carved = carveRecipe(
            recipe.outline, half: recipe.weight * thin.widen / 2, transform: recipe.transform,
            color: thin.color(recipe.color), uv: recipe.uv)
        (style.strokeCap, style.strokeJoin) = saved
        return carved.vertices()
    }
}

/// 保持した形の輪郭を、**置いた後の太さで細ければ**広げて組み直す素材 ([#1637] 完了条件 5)。
///
/// 描く画素での太さは、置き場所の行列が決まるまで分からない。記録した形を縮めて置けば
/// 細くなるので、記録のときには判断できない。記録した頂点はそのまま持ち、置くたびに
/// ``Canvas/thinVertices(_:placedBy:)`` で細さを測って、細ければ組み直した頂点で区間を
/// 差し替える。細くならない置き方 (いちばんよくある) は費用を払わない — 測るのは行列式 1 つで、
/// 形の中で最も細い線でも細くならなければ区間を走査しない (``Shape/thinnestRecordedWeight``)。
///
/// [#1637]: https://github.com/mokume-metal/mokume/issues/1637
struct ThinStrokeRecipe {
    /// 形自身の座標の周 (記録のときの変換を掛ける前)。
    let outline: Canvas.Outline
    /// 形自身の座標の太さ。
    let weight: Float
    let cap: StrokeCap
    let join: StrokeJoin
    /// 記録のときの線の色。
    let color: LinearRGBA
    /// 記録のときの変換 (入れ子なら外側の置き場所の行列も合成したもの)。
    let transform: Transform
    let uv: SIMD2<Float>

    /// 記録のときの変換を掛けた後の太さ (入れ子の外側の行列も含む)。形の中で最も細い線を
    /// 見つけるのに使う。
    var recordedWeight: Float {
        let columns = transform.matrix.columns
        return weight * abs(columns.0.x * columns.1.y - columns.0.y * columns.1.x).squareRoot()
    }

    /// 別の保持した形の中で置かれた輪郭。行列と色を合成する (置くときに判断するのは同じ)。
    func moved(by matrix: simd_float4x4, tint: LinearRGBA?) -> ThinStrokeRecipe {
        var color = self.color
        if let tint {
            color = LinearRGBA(
                premultipliedRed: color.red * tint.red, green: color.green * tint.green,
                blue: color.blue * tint.blue, alpha: color.alpha * tint.alpha)
        }
        return ThinStrokeRecipe(
            outline: outline, weight: weight, cap: cap, join: join, color: color,
            transform: Transform(matrix: matrix * transform.matrix), uv: uv)
    }
}
