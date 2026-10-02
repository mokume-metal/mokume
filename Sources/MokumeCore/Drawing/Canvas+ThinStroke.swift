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
    /// **帯を描く画素 1 つの太さへ広げ、太さの割合を被覆として断片の後で掛ける。** 太さちょうど
    /// 1 の帯は、向きが軸に沿っていれば置く位置によらず 1 行 (1 列) の画素の中心を跨ぐので、
    /// 光の量が太さに比例する。斜めの帯は列ごとに 1 行か 2 行になるが、跨ぐ中心の数の平均は
    /// 面積に等しい。被覆は頂点の色ではなく別の値で運ぶ (`ShapeFragmentIn.coverage`) ので、
    /// 利用者の断片が `in.color` を掛けずに色を返しても、`in.color.a` を読んでも、`stroke()` で
    /// 渡した値のまま届く。1 未満の被覆を持つ片の重なりは、引いて積む経路 (#1536) が 1 回だけ
    /// 混ぜる。
    ///
    /// **点は描く画素 1 つの軸に沿った正方形にして、被覆を面積 (太さの 2 乗) にする。** 直径 1 の
    /// 円板は置く位置によって画素の中心を 1 つも含まないので、丸い点もこの形にする (距離関数の
    /// 経路の細い点と同じ量 — `halfDensityPointsKeepTheirArea`)。
    ///
    /// 描く画素で 1 画素以上の線は何も変えない (この型が作られない)。
    ///
    /// [#1637]: https://github.com/mokume-metal/mokume/issues/1637
    struct ThinStroke {
        /// 太さに掛ける倍率。掛けると描く画素でちょうど 1 になる。
        let widen: Float
        /// 断片の後で掛ける被覆。線は太さ、点は面積。
        let coverage: Float

        /// 描く画素での太さが 1 未満のときだけ作る。0 (潰れた変換) と数でない値は補わない。
        init?(drawnWeight: Float, isPoint: Bool) {
            guard drawnWeight > 0, drawnWeight < 1, drawnWeight.isFinite else { return nil }
            widen = 1 / drawnWeight
            coverage = isPoint ? drawnWeight * drawnWeight : drawnWeight
        }
    }

    /// 平面の頂点のうち、被覆が 1 でない区間 (#1637)。
    struct CoverageSpan: Equatable {
        var range: Range<Int>
        var value: Float

        /// 区間 `range` に被覆 `value` を付ける。1 なら何もしない。直前の区間と続いていて同じ値
        /// なら、延ばして 1 つにまとめる。区間は番号の順に足すこと。
        static func note(_ value: Float, in range: Range<Int>, to spans: inout [CoverageSpan]) {
            guard value < 1, !range.isEmpty else { return }
            if let last = spans.last, last.value == value, last.range.upperBound == range.lowerBound {
                spans[spans.count - 1].range = last.range.lowerBound..<range.upperBound
            } else {
                spans.append(CoverageSpan(range: range, value: value))
            }
        }
    }

    /// 平面の頂点 `range` に被覆 `value` を付ける (``coverageSpans``)。
    func noteCoverage(_ value: Float, in range: Range<Int>) {
        CoverageSpan.note(value, in: range, to: &coverageSpans)
    }

    /// 平面の頂点を `count` 個まで切り詰めたとき、その先を指す被覆の区間を落とす。
    func trimCoverage(to count: Int) {
        while let last = coverageSpans.last, last.range.upperBound > count {
            guard last.range.lowerBound < count else {
                coverageSpans.removeLast()
                continue
            }
            coverageSpans[coverageSpans.count - 1].range = last.range.lowerBound..<count
            break
        }
    }

    // MARK: - 描く画素での太さ

    /// 形自身の座標を、行列 `matrix` で置いて描く画素へ写す 2x2 (出す画素から描く画素への比は
    /// ``unitsPerDrawnPixel`` から取る・#1686 完了条件 5)。
    func drawnLinear(_ matrix: simd_float4x4) -> simd_float2x2 {
        let columns = matrix.columns
        let units = unitsPerDrawnPixel
        return simd_float2x2(
            SIMD2(columns.0.x / units.x, columns.0.y / units.y),
            SIMD2(columns.1.x / units.x, columns.1.y / units.y))
    }

    /// 形自身の座標で向き `direction` に走る太さ `weight` の線の、**線に垂直な向きで測った**
    /// 描く画素での太さ。距離関数の経路が軸ごとに測る (`inverseRows`) のと同じ量である。
    ///
    /// 帯の面積は太さ × 長さで、写すと `|det|` 倍になる。長さは `|D·向き|` 倍になるので、
    /// 写した帯の太さは `太さ × |det| / |D·向き|`。向きが決まらない (長さ 0) ときは、どの向き
    /// にもならした値 (面積の倍率の平方根) を使う。
    static func drawnWeight(
        _ weight: Float, along direction: SIMD2<Float>, by linear: simd_float2x2
    ) -> Float {
        let area = abs(simd_determinant(linear))
        let length = simd_length(direction)
        guard length > 0, length.isFinite else { return weight * area.squareRoot() }
        let stretched = simd_length(linear * (direction / length))
        guard stretched > 0 else { return 0 }
        return weight * area / stretched
    }

    /// どの向きの線でもいちばん細くなるときの描く画素での太さ (2x2 の最小の特異値を掛けた値)。
    /// これが 1 以上なら、どの片も補わない。
    static func thinnestDrawnWeight(_ weight: Float, by linear: simd_float2x2) -> Float {
        let product = linear.transpose * linear
        let trace = product.columns.0.x + product.columns.1.y
        let determinant = simd_determinant(product)
        let gap = max(trace * trace / 4 - determinant, 0).squareRoot()
        return weight * max(trace / 2 - gap, 0).squareRoot()
    }

    /// 立体の線の描く画素での太さ。**立体の線の太さは出す画素**で書かれている
    /// (視線に正対させて画面の画素で組む) ので、変換によらず、**置く面の細かさ**だけで決まる。
    func drawnSolidWeight(_ weight: Float) -> Float {
        let units = unitsPerDrawnPixel
        return weight / (units.x * units.y).squareRoot()
    }

    // MARK: - 平面の輪郭

    /// 輪郭の片ごとの補い。帯は線分ごと、点の形 (端・折れ目・刻みの円板) は点ごとに持つ。
    struct ThinOutline {
        /// 線分ごとの太さの半分 (形自身の座標)。
        var bandHalf: [Float]
        var bandCoverage: [Float]
        /// 点ごとの太さの半分。両隣の帯のうち広いほうに合わせる (帯の端を覆い切るため)。
        var pointHalf: [Float]
        var pointCoverage: [Float]
        /// 点 1 つの周か (描く画素 1 つの正方形にする)。
        var isPoint: Bool
        /// 片のうちいちばん広い太さ (形自身の座標)。重なりを引く相手を探す幅に使う。
        var widest: Float
    }

    /// 輪郭の片ごとの補い。**どの片も細くならなければ `nil`** で、輪郭はこれまでどおり組む。
    ///
    /// 帯は**その帯の向きに垂直に測った**描く画素での太さで判断する。縦と横で倍率の違う変換
    /// (`scale(4, 0.25)`) では、横の辺だけが細くなる。点 1 つの周は向きを持たないので、面積の
    /// 倍率で測る。
    func thinOutline(
        _ outline: Outline, weight: Float, placedBy matrix: simd_float4x4
    ) -> ThinOutline? {
        let linear = drawnLinear(matrix)
        guard Self.thinnestDrawnWeight(weight, by: linear) < 1 else { return nil }
        let points = outline.points
        let count = points.count
        let half = weight / 2
        if count == 1 {
            guard
                let thin = ThinStroke(
                    drawnWeight: weight * abs(simd_determinant(linear)).squareRoot(),
                    isPoint: true)
            else { return nil }
            return ThinOutline(
                bandHalf: [], bandCoverage: [], pointHalf: [half * thin.widen],
                pointCoverage: [thin.coverage], isPoint: true, widest: weight * thin.widen)
        }
        let segments = outline.isClosed ? count : count - 1
        var bandHalf = [Float](repeating: half, count: segments)
        var bandCoverage = [Float](repeating: 1, count: segments)
        var any = false
        for index in 0..<segments {
            let direction = points[(index + 1) % count] - points[index]
            guard
                let thin = ThinStroke(
                    drawnWeight: Self.drawnWeight(weight, along: direction, by: linear),
                    isPoint: false)
            else { continue }
            bandHalf[index] = half * thin.widen
            bandCoverage[index] = thin.coverage
            any = true
        }
        guard any else { return nil }
        var pointHalf = [Float](repeating: half, count: count)
        var pointCoverage = [Float](repeating: 1, count: count)
        for index in 0..<count {
            // 点に来る帯 (閉じた周は前後の 2 本、開いた周の端は 1 本)
            var neighbors: [Int] = []
            if index < segments { neighbors.append(index) }
            if index > 0 { neighbors.append(index - 1) } else if outline.isClosed { neighbors.append(segments - 1) }
            for band in neighbors where bandHalf[band] > pointHalf[index] {
                pointHalf[index] = bandHalf[band]
                pointCoverage[index] = bandCoverage[band]
            }
        }
        return ThinOutline(
            bandHalf: bandHalf, bandCoverage: bandCoverage, pointHalf: pointHalf,
            pointCoverage: pointCoverage, isPoint: false,
            widest: 2 * max(bandHalf.max() ?? half, pointHalf.max() ?? half))
    }

    /// 平面の輪郭を補うときに細さを測る行列。**最後の変換が決まらない所では測らない** —
    /// 保持する形の記録 (置くときに測る・``ThinStrokeRecipe``)。畳みの雛形は、雛形の鍵が持つ
    /// 置き場所の変換 (``templateStrokeMatrix``・細い線の雛形は同じ変換の置き場所だけで畳む)
    /// で測る。線の半画素の寄せ (`strokePoint`) を先送りする所と同じである。
    var thinStrokeMatrix: simd_float4x4? {
        if recordingShape { return nil }
        if buildingFlatTemplate { return templateStrokeMatrix }
        return transform.matrix
    }

    // MARK: - 立体の線

    /// 立体の線の補い。**記録の間は判断しない** — 置く面 (細かさ) が決まるのは置くときで、
    /// 記録した部品は置くときに組み直す (``rebuiltSolidStroke(_:)``)。
    func thinSolidStroke(weight: Float, isPoint: Bool) -> ThinStroke? {
        guard !recordingShape else { return nil }
        return ThinStroke(drawnWeight: drawnSolidWeight(weight), isPoint: isPoint)
    }

    /// 補いを当てた立体の線の設定 (太さ・被覆・点の端の形) で `body` を走らせ、元へ戻す。
    func withThinSolidStroke(_ thin: ThinStroke?, isPoint: Bool, _ body: () -> Void) {
        guard let thin else { return body() }
        let saved = (style.strokeWeight, style.strokeCap, solidStrokeCoverage)
        style.strokeWeight *= thin.widen
        solidStrokeCoverage = thin.coverage
        // 向きの無い点の四角い端は、画面の軸に沿った正方形
        if isPoint { style.strokeCap = .square }
        body()
        (style.strokeWeight, style.strokeCap, solidStrokeCoverage) = saved
    }

    // MARK: - 保持した形

    /// 保持した形の輪郭を、置いた後の太さで組み直した頂点と被覆の区間。**どの片も細くならなければ
    /// `nil`** で、呼ぶ側は記録した頂点をそのまま置く。
    ///
    /// 頂点は記録した頂点と同じ座標 (形自身の座標に記録のときの変換を掛け、半画素寄せの前)
    /// で返すので、呼ぶ側は記録した頂点と同じく置き場所の行列と色を掛けて寄せる。**組み直しは
    /// 置き場所の 2x2 ごとに 1 度だけ** — 同じ大きさで置き続ける形は、控えた頂点を移すだけで
    /// 済む (``ThinStrokeRecipe``)。
    func thinVertices(
        _ recipe: ThinStrokeRecipe, placedBy matrix: simd_float4x4
    ) -> (vertices: [ShapeVertex], coverage: [CoverageSpan])? {
        let combined = matrix * recipe.transform.matrix
        let linear = drawnLinear(combined)
        let key = SIMD4<Float>(
            linear.columns.0.x, linear.columns.0.y, linear.columns.1.x, linear.columns.1.y)
        if let cached = recipe.built[key] { return cached }
        let built = buildThinVertices(recipe, placedBy: combined)
        recipe.remember(built, for: key)
        return built
    }

    private func buildThinVertices(
        _ recipe: ThinStrokeRecipe, placedBy combined: simd_float4x4
    ) -> (vertices: [ShapeVertex], coverage: [CoverageSpan])? {
        thinStrokesRebuilt += 1
        guard let thin = thinOutline(recipe.outline, weight: recipe.weight, placedBy: combined)
        else { return nil }
        let saved = (style.strokeCap, style.strokeJoin)
        style.strokeCap = thin.isPoint ? .square : recipe.cap
        style.strokeJoin = recipe.join
        let carved = carveRecipe(
            recipe.outline, half: recipe.weight / 2, thin: thin, transform: recipe.transform,
            color: recipe.color, uv: recipe.uv)
        (style.strokeCap, style.strokeJoin) = saved
        return carved.built()
    }
}

/// 保持した形の輪郭を、**置いた後の太さで細ければ**広げて組み直す素材 ([#1637] 完了条件 5)。
///
/// 描く画素での太さは、置き場所の行列が決まるまで分からない。記録した形を縮めて置けば
/// 細くなるので、記録のときには判断できない。記録した頂点はそのまま持ち、置くたびに
/// ``Canvas/thinVertices(_:placedBy:)`` で細さを測って、細ければ組み直した頂点で区間を
/// 差し替える。細くならない置き方 (いちばんよくある) は費用を払わない — 形の中で最も細い線でも
/// 細くならなければ区間を走査しない (``Shape/thinnestRecordedWeight``)。
///
/// **組み直した頂点は、描く画素へ写す 2x2 ごとに控える** (置き場所の平行移動には依らない)。
/// 同じ大きさで置き続ける形は、置き場所ごと・フレームごとに組み直さない。控えるのは数件まで —
/// 置き場所ごとに大きさの違う形は鍵が増え続けるので、上限を越えたら捨てて控え直す。参照の箱に
/// してあるのは、形 (値型) を写しても控えを共有するため (``CarvedStroke`` と同じ)。
///
/// [#1637]: https://github.com/mokume-metal/mokume/issues/1637
final class ThinStrokeRecipe {
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
    /// 組み直した頂点の控え。`nil` を控えた鍵は「細くならない」。
    private(set) var built: [SIMD4<Float>: (vertices: [ShapeVertex], coverage: [Canvas.CoverageSpan])?] = [:]
    static let cacheCapacity = 8

    init(
        outline: Canvas.Outline, weight: Float, cap: StrokeCap, join: StrokeJoin,
        color: LinearRGBA, transform: Transform, uv: SIMD2<Float>
    ) {
        self.outline = outline
        self.weight = weight
        self.cap = cap
        self.join = join
        self.color = color
        self.transform = transform
        self.uv = uv
    }

    func remember(
        _ value: (vertices: [ShapeVertex], coverage: [Canvas.CoverageSpan])?,
        for key: SIMD4<Float>
    ) {
        if built.count >= Self.cacheCapacity { built.removeAll(keepingCapacity: true) }
        built[key] = value
    }

    /// 記録のときの変換を掛けた後の、いちばん細くなる向きの太さ (入れ子の外側の行列も含む)。
    /// 形の中で最も細い線を見つけるのに使う。
    var recordedWeight: Float {
        let columns = transform.matrix.columns
        let linear = simd_float2x2(
            SIMD2(columns.0.x, columns.0.y), SIMD2(columns.1.x, columns.1.y))
        return Canvas.thinnestDrawnWeight(weight, by: linear)
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
