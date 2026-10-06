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
        guard value < 1, !range.isEmpty else { return }
        CoverageSpan.note(value, in: range, to: &coverageSpans)
        openBatchHasThinCoverage = true
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
    ///
    /// 1 をわずかに割る値は 1 に丸める (``roundedDrawnWeight(_:)``・#2039)。
    static func drawnWeight(
        _ weight: Float, along direction: SIMD2<Float>, by linear: simd_float2x2
    ) -> Float {
        let area = abs(simd_determinant(linear))
        let length = simd_length(direction)
        guard length > 0, length.isFinite else { return drawnPointWeight(weight, by: linear) }
        let stretched = simd_length(linear * (direction / length))
        guard stretched > 0 else { return 0 }
        return roundedDrawnWeight(weight * area / stretched)
    }

    /// 向きを持たない点 1 つの、描く画素での太さ (面積の倍率の平方根を掛けた値)。
    /// 1 をわずかに割る値は 1 に丸める (``roundedDrawnWeight(_:)``・#2039)。
    static func drawnPointWeight(_ weight: Float, by linear: simd_float2x2) -> Float {
        roundedDrawnWeight(weight * abs(simd_determinant(linear)).squareRoot())
    }

    /// どの向きの線でもいちばん細くなるときの描く画素での太さ (2x2 の最小の特異値を掛けた値)。
    /// これが 1 以上なら、どの片も補わない。
    ///
    /// **1 をわずかに割る値は 1 に丸める** (``roundedDrawnWeight(_:)``・#2039)。最小の特異値は
    /// 倍精度で、打ち消しの無い形で解く (``smallestSingularValue(of:)``)。
    static func thinnestDrawnWeight(_ weight: Float, by linear: simd_float2x2) -> Float {
        roundedDrawnWeight(Float(Double(weight) * smallestSingularValue(of: linear)))
    }

    /// 2x2 の最小の特異値 (どの向きでも、これ以上は縮まない)。**丸めない** — 2 つの行列に分けて
    /// 測る見積もり (``Shape/thinnestRecordedWeight``) は、丸めた値を掛け合わせると、合成の行列で
    /// 測ったときより細さを甘く見る。丸めるのは、補うかを決める最後の 1 度だけにする。
    ///
    /// **倍精度で、2 乗の差を引かない形で解く** (#2039)。`DᵀD` の固有値の `trace²/4 − det` を
    /// 引いてから平方根を取ると、回すだけの変換 (両方の特異値が 1) で打ち消しの誤差 1e-7 ほどが
    /// 平方根で 3e-4 ほどに膨らみ、太さ 1 の線が約 29% の角度で 0.9998 ほどに細く見えていた。
    /// ``splitScale(of:)`` と同じく `σ₁ ± σ₂ = √(trace ± 2|det|)` から大きいほうを出し、小さいほうは
    /// `|det| / σ₁` で出す (σ₁ σ₂ = |det|。σ₂ ≪ σ₁ でも桁が落ちない)。回すだけの単精度の行列は
    /// `trace − 2|det| = (a − d)² + (b + c)²` がちょうど 0 になり、σ₁ = σ₂ = √|det| (1 ± 6e-8) が出る。
    static func smallestSingularValue(of linear: simd_float2x2) -> Double {
        let a = Double(linear.columns.0.x)
        let b = Double(linear.columns.0.y)
        let c = Double(linear.columns.1.x)
        let d = Double(linear.columns.1.y)
        let trace = a * a + b * b + c * c + d * d
        let area = abs(a * d - b * c)
        let largest = ((trace + 2 * area).squareRoot() + max(trace - 2 * area, 0).squareRoot()) / 2
        // 潰れきった変換は 0。数でない・無限の成分は数でない値のまま返し、1 未満とは比べさせない
        if largest == 0 { return 0 }
        return area / largest
    }

    /// 描く画素での太さ `drawn` のうち、1 を誤差の幅 (``thinStrokeTolerance``) の内側でだけ割る値を、
    /// ちょうど 1 に丸める (#2039)。補うのは、丸めた値が 1 を割る線だけである。
    ///
    /// 回すだけ・映すだけの変換は太さを変えないはずだが、単精度の行列は成分が丸められ、描く画素での
    /// 太さは 1 ± 1e-7 ほどに揺れる。そのまま比べると、`rotate` だけで置いた太さ 1 の線が角度によって
    /// 補いの経路へ入り (被覆が 0.9999999 の帯に組み直され)、頂点の数が角度で変わっていた。
    ///
    /// **丸めるのは特異値ではなく、太さを掛けた後の値である。** 揺れは変換の大きさに対して相対で
    /// 乗るので、`scale(2)` の下の太さ 0.5 や、細かさ 0.5 の太さ 2 の線も、描く画素では 1 ± 1e-7 に
    /// なる。特異値を 1 の付近で丸めても、これらは拾えない。
    ///
    /// **幅 (``thinStrokeTolerance``) は、単精度の揺れだけを吸う狭さにする。** 分割数の拡大率の
    /// 丸め (``splitScaleTolerance``・相対 1e-3) と同じ幅にはしない — 丸めの帰結が違うからである。
    /// 拡大率の丸めは、半径を最大 0.1% 小さく見積もるだけで、絵は 0.25 画素の保証の内側に残る。
    /// こちらは、丸めた線が補いの経路を外れ、元の太さのまま AA の無い帯を組む。描く画素で 1 より
    /// わずかに細い軸に沿った帯は、被覆を掛けずに満濃度で出るうえ、縁が画素の中心の内側に入るので、
    /// 中心が画素の境目に乗ると**どの画素の中心も跨がず消えうる** (太さ 0.9995 の横線の帯
    /// [10.50025, 11.49975] は、中心 10.5 と 11.5 を外す。手元の GPU ではずれがラスタライザの格子への
    /// 寄せより小さく、消えずに満濃度で出たが、その精度には頼らない)。「1 画素より細い線は、置く位置に
    /// よらず太さに比例した濃さで出る」(`strokeWeight` の説明) を守るには、本当に細い線を丸めない。
    ///
    /// 幅は実測で選んだ (`RotatedThinStrokeFormulaTests`)。回転 1 つ・2 つの合成・平行移動と鏡映を
    /// 挟んだ合成・拡大や細かさとの組・立体の線の細かさでは、1 からの揺れは最大 2.4e-7。小さい回転を
    /// 1000 回重ねると 1.0014e-5 まで積もる。1e-5 では、この積み重ねが単精度で幅の端にちょうど
    /// 乗って余裕が無いので、1 桁広い 1e-4 にする。補いを外れるのは描く画素で [0.9999, 1) の太さの
    /// 線だけになる (`strokeWeight(0.9995)` は幅の外で、これまでどおり補う)。
    static func roundedDrawnWeight(_ drawn: Float) -> Float {
        drawn < 1 && drawn >= Float(1 - thinStrokeTolerance) ? 1 : drawn
    }

    /// 細い線とみなさない幅 (相対・``roundedDrawnWeight(_:)``)。単精度の揺れだけを吸う。
    static let thinStrokeTolerance = 1e-4

    /// 円板と周の分割数を決めるときの、形自身の座標から画面への拡大率 (#1645)。
    /// 行列の 2x2 (平面の点が写る先) の最大の特異値で、**どの向きでも、これ以上は伸びない**。
    /// 分割数は半径にこれを掛けて決めるので、縦横で倍率の違う変換は大きいほうで決まる。
    ///
    /// **拡大のときだけ効く。** 1 を下回るときは 1 を返し、縮めても分割を減らさない。
    /// 拡大しない絵と縮めた絵は、これまでと同じ分割数のまま動かない。
    ///
    /// **誤差の幅 (``splitScaleTolerance``) の内側は、ちょうど 1 に丸める。** 回すだけ・映すだけの
    /// 変換は長さを保つはずだが、単精度の行列は成分が丸められ、最大の特異値は 1 ± 1e-7 ほどに
    /// 揺れる。そのまま返すと、`scale` を掛けず `rotate` だけの絵で、約 5% の角度の拡大率が 1 を
    /// 越える (最大 1.00017)。既定の太さ 1 の丸い端の円板は、半径 0.5 が 3 分割と 4 分割の境目に
    /// 乗っているので、その角度だけ別の分割になり、回す絵が動き、畳みの鍵が割れ、保持した形を回して
    /// 置くと刻み直しが立った。幅は、回転や平行移動を重ねた誤差 (1e-6 ほど) より 3 桁大きく、
    /// 丸めたときに半径が最大 0.1% 小さく見積もられるだけ (0.25 画素の保証が 0.25025 画素になる)。
    ///
    /// **倍精度で解く。** 単精度の 2 乗は、成分が 1e19 を越えるとあふれて拡大率が 1 に化け、
    /// いちばん粗い多角形になる。桁違いの拡大は、**いちばん細かい側へ倒す** — 単精度に収まらない
    /// 大きさは単精度の最大で止め、`segmentCount(forRadius:scale:)` が上限 1024 へ倒す。成分が
    /// 数でない・無限の変換は、何も描かれないので 1 に倒す。
    ///
    /// **単位は出す画素** (座標や線の太さと同じ) で、`pixelDensity` を含まない。細かさを下げても
    /// 描く画素が粗くなるだけで、出す画素で 0.25 画素以内なら描く画素でも保証の内側にある
    /// (`DensityInvarianceTests` が言う、細かさによらない約束と同じ向き)。
    static func splitScale(of matrix: simd_float4x4) -> Float {
        let columns = matrix.columns
        let a = Double(columns.0.x)
        let b = Double(columns.0.y)
        let c = Double(columns.1.x)
        let d = Double(columns.1.y)
        // `DᵀD` の固有値 (特異値の 2 乗) の和と積
        let trace = a * a + b * b + c * c + d * d
        guard trace.isFinite else { return 1 }
        let determinant = a * d - b * c
        // 1 を越えて伸びない変換 (いちばんよくある) は、平方根を取らずに返す。固有値の大きいほうが
        // `limit` 以下なのは、`trace ≤ 2 · limit` かつ `limit² − trace · limit + det² ≥ 0` のとき
        let limit = (1 + splitScaleTolerance) * (1 + splitScaleTolerance)
        if trace <= 2 * limit, limit * limit - trace * limit + determinant * determinant >= 0 {
            return 1
        }
        // σ₁ + σ₂ = √(trace + 2|det|)、σ₁ − σ₂ = √(trace − 2|det|)。2 乗の差を引かない形で、
        // 大きいほうの特異値を出す
        let area = abs(determinant)
        let largest = ((trace + 2 * area).squareRoot() + max(trace - 2 * area, 0).squareRoot()) / 2
        if largest <= 1 + splitScaleTolerance { return 1 }
        return Float(min(largest, Double(Float.greatestFiniteMagnitude)))
    }

    /// 拡大とみなさない幅 (相対・``splitScale(of:)``)。
    static let splitScaleTolerance = 1e-3

    /// 立体の線の描く画素での太さ。**立体の線の太さは出す画素**で書かれている
    /// (視線に正対させて画面の画素で組む) ので、変換によらず、**置く面の細かさ**だけで決まる。
    ///
    /// 1 をわずかに割る値は 1 に丸める (``roundedDrawnWeight(_:)``・#2039)。細かさの比
    /// (幅 / 刻む幅) は単精度で丸められるので、細かさ 0.55・出す先 200 の太さ `1 / 0.55` は
    /// 0.99999994 になる。丸めないと、同じ絵の平面の線 (1 に丸まって補わない) と判断が食い違う。
    func drawnSolidWeight(_ weight: Float) -> Float {
        Self.drawnSolidWeight(weight, unitsPerDrawnPixel: unitsPerDrawnPixel)
    }

    /// ``drawnSolidWeight(_:)`` の式 (描く画素 1 つが `units` の土台)。
    static func drawnSolidWeight(_ weight: Float, unitsPerDrawnPixel units: SIMD2<Float>) -> Float {
        roundedDrawnWeight(weight / (units.x * units.y).squareRoot())
    }

    // MARK: - 平面の輪郭

    /// 輪郭の片ごとの補い。**片は描く画素の空間で組む** (#1637)。
    ///
    /// 形自身の座標で組んでから変換を掛けると、縦と横で倍率の違う変換や回転のもとで、広げた
    /// 帯に合わせた端・角・点が描く画素で歪む (`scale(4, 0.25)` の角が横へ 8 画素出る・回した点が
    /// 菱形になる)。そこで周の点を描く画素の空間へ写し (``linear``)、そこで片を組んでから
    /// 形自身の座標へ戻す (``inverse``)。変換を掛けると描く画素の空間の形にちょうど戻る。
    struct ThinOutline {
        /// 形自身の座標を描く画素の空間へ写す 2x2 (平行移動は持たない)。
        var linear: simd_float2x2
        /// その逆。組んだ片を形自身の座標へ戻す。
        var inverse: simd_float2x2
        /// 線分ごとの、描く画素で測った元の太さ (線の向きに垂直)。
        var bandWeight: [Float]
        /// 線分ごとの、組む帯の太さの半分 (描く画素)。細い帯は 0.5、そうでなければ元の太さの半分。
        var bandHalf: [Float]
        /// 線分ごとの被覆 (細い帯は元の太さ、そうでなければ 1)。
        var bandCoverage: [Float]
        /// 点 1 つの周か (描く画素 1 つの軸に沿った正方形にする)。
        var isPoint: Bool
        /// 点 1 つの周の被覆 (描く画素での面積)。
        var pointCoverage: Float
        /// 片のうちいちばん広い太さ (描く画素)。重なりを引く相手を探す幅に使う。
        var widest: Float
    }

    /// 輪郭の片ごとの補い。**どの片も細くならなければ `nil`** で、輪郭はこれまでどおり組む。
    ///
    /// 帯は**その帯の向きに垂直に測った**描く画素での太さで判断する。縦と横で倍率の違う変換
    /// (`scale(4, 0.25)`) では、横の辺だけが細くなる。点 1 つの周は向きを持たないので、面積の
    /// 倍率で測る。変換が潰れている (行列式 0) と何も補わない。
    func thinOutline(
        _ outline: Outline, weight: Float, placedBy matrix: simd_float4x4
    ) -> ThinOutline? {
        let linear = drawnLinear(matrix)
        let determinant = simd_determinant(linear)
        guard determinant != 0, determinant.isFinite,
            Self.thinnestDrawnWeight(weight, by: linear) < 1
        else { return nil }
        let points = outline.points
        let count = points.count
        if count == 1 {
            guard
                let thin = ThinStroke(
                    drawnWeight: Self.drawnPointWeight(weight, by: linear), isPoint: true)
            else { return nil }
            return ThinOutline(
                linear: linear, inverse: linear.inverse, bandWeight: [], bandHalf: [],
                bandCoverage: [], isPoint: true, pointCoverage: thin.coverage, widest: 1)
        }
        let segments = outline.isClosed ? count : count - 1
        var bandWeight = [Float](repeating: 0, count: segments)
        var bandHalf = [Float](repeating: 0, count: segments)
        var bandCoverage = [Float](repeating: 1, count: segments)
        var any = false
        for index in 0..<segments {
            let direction = points[(index + 1) % count] - points[index]
            let drawn = Self.drawnWeight(weight, along: direction, by: linear)
            bandWeight[index] = drawn
            bandHalf[index] = drawn / 2
            guard let thin = ThinStroke(drawnWeight: drawn, isPoint: false) else { continue }
            bandHalf[index] = 0.5
            bandCoverage[index] = thin.coverage
            any = true
        }
        guard any else { return nil }
        return ThinOutline(
            linear: linear, inverse: linear.inverse, bandWeight: bandWeight, bandHalf: bandHalf,
            bandCoverage: bandCoverage, isPoint: false, pointCoverage: 1,
            widest: 2 * max(bandHalf.max() ?? 0.5, 0.5))
    }

    /// 細い片を持つ輪郭の片を、**描く画素の空間で**集める (``ThinOutline``)。点は描く画素の
    /// 空間の座標で、呼ぶ側が ``ThinOutline/inverse`` で形自身の座標へ戻し、置き場所ぶんのずれを
    /// 足す。
    ///
    /// - 帯: 線分の向きに垂直に、``ThinOutline/bandHalf`` の幅で組む
    /// - 端 (開いた周の両端): **その帯の向きに沿っては元の太さの半分だけ**出し、横は帯と同じ幅に
    ///   する。丸い端は楕円、出っ張らせる端は長方形。広げた帯の幅で丸めると、端の光が元の
    ///   1 / 太さ 倍になる (細かさ 0.5 の太さ 1 で 2 倍)
    /// - 角: 2 本の帯の外側の縁を、それぞれの帯の幅で延ばして交わる所まで (`miter`)、または
    ///   2 つの縁の角を結んだ所まで (`bevel`)。尖りが太いほうの幅の √2 倍より遠ければ `bevel`
    ///   に倒す。丸める角と曲線の刻みは、細いほうの幅の円板と `bevel` の三角形で埋める
    /// - 点 1 つの周: 描く画素 1 つの、描く画素の軸に沿った正方形
    ///
    /// 角と端の被覆は、隣の帯の被覆の小さいほう (端はその帯の被覆)。
    func thinCarving(
        _ outline: Outline, thin: ThinOutline
    ) -> (carving: StrokeCarving, offset: SIMD2<Float>) {
        let (shapePoints, offset) = outline.unmoved ?? (outline.points, SIMD2<Float>(0, 0))
        var points: [SIMD2<Float>] = []
        points.reserveCapacity(shapePoints.count)
        for point in shapePoints { points.append(thin.linear * point) }
        let count = points.count
        var carving = StrokeCarving(
            points: points, isClosed: outline.isClosed, weight: thin.widest,
            wholeOutline: outline.strokesAsOneRegion)
        if thin.isPoint {
            let center = points[0]
            carving.addPoint(0, coverage: thin.pointCoverage) { polygon in
                polygon.append(center + SIMD2(-0.5, -0.5))
                polygon.append(center + SIMD2(0.5, -0.5))
                polygon.append(center + SIMD2(0.5, 0.5))
                polygon.append(center + SIMD2(-0.5, 0.5))
            }
            return (carving, offset)
        }
        let segments = thin.bandHalf.count
        /// 点に来る帯 (前・後)。開いた周の端は片方が無い。
        func bands(at index: Int) -> (before: Int?, after: Int?) {
            let after = index < segments ? index : nil
            let before = index > 0 ? index - 1 : (outline.isClosed ? segments - 1 : nil)
            return (before, after)
        }
        func isEnd(_ index: Int) -> Bool {
            !outline.isClosed && (index == 0 || index == count - 1)
        }
        func addCap(_ index: Int, round: Bool) {
            let band = index == 0 ? 0 : segments - 1
            let other = index == 0 ? points[1] : points[count - 2]
            let delta = other - points[index]
            let length = simd_length(delta)
            // 向きが決まらない (長さ 0 の線) ときは、描く画素の軸に沿って置く
            let u = length > 0 ? delta / length : SIMD2<Float>(1, 0)
            let n = SIMD2(-u.y, u.x)
            let center = points[index]
            let across = thin.bandHalf[band]
            let along = thin.bandWeight[band] / 2
            carving.addPoint(index, coverage: thin.bandCoverage[band]) { polygon in
                if round {
                    // 描く画素の空間で組むので、拡大率は 1 (画面の大きさがそのまま半径)
                    for offset in Self.arcOffsets(
                        radiusX: along, radiusY: across, from: 0, sweep: 2 * .pi, scale: 1)
                    {
                        polygon.append(center + u * offset.x + n * offset.y)
                    }
                } else {
                    polygon.append(center - u * along - n * across)
                    polygon.append(center + u * along - n * across)
                    polygon.append(center + u * along + n * across)
                    polygon.append(center - u * along + n * across)
                }
            }
        }
        /// 角を埋める。`join` が `nil` なら丸める角 (円板と三角形)。
        func addJoin(_ index: Int, previous: Int, next: Int, join: StrokeJoin?) {
            let (beforeBand, afterBand) = bands(at: index)
            let hBefore = beforeBand.map { thin.bandHalf[$0] } ?? 0.5
            let hAfter = afterBand.map { thin.bandHalf[$0] } ?? 0.5
            let coverage = min(
                beforeBand.map { thin.bandCoverage[$0] } ?? 1,
                afterBand.map { thin.bandCoverage[$0] } ?? 1)
            let center = points[index]
            let small = min(hBefore, hAfter)
            func disc() {
                // 描く画素の空間で組むので、拡大率は 1 (画面の大きさがそのまま半径)
                let rim = Self.arcOffsets(
                    radiusX: small, radiusY: small, from: 0, sweep: 2 * .pi, scale: 1)
                carving.addPoint(index, coverage: coverage) { polygon in
                    for offset in rim { polygon.append(center + offset) }
                }
            }
            let back = points[previous] - center
            let ahead = points[next] - center
            let backLength = simd_length(back)
            let aheadLength = simd_length(ahead)
            guard backLength > 0, aheadLength > 0 else { return disc() }
            let a1 = back / backLength
            let a2 = ahead / aheadLength
            let inward = a1 + a2
            // 一直線は隙間が無い。同じ向きへ折り返す角は円板で埋める
            guard simd_length(inward) > 1e-6 else { return }
            var n1 = SIMD2(-a1.y, a1.x)
            if dot(n1, inward) > 0 { n1 = -n1 }
            var n2 = SIMD2(-a2.y, a2.x)
            if dot(n2, inward) > 0 { n2 = -n2 }
            let e1 = center + n1 * hBefore
            let e2 = center + n2 * hAfter
            let inner = center + simd_normalize(inward) * (small / 64)
            if join == nil { disc() }
            // 外側の縁の延長どうしの交点: e1 + s·a1 = e2 + t·a2
            let determinant = a1.y * a2.x - a1.x * a2.y
            var tip: SIMD2<Float>?
            if join == .miter, abs(determinant) > 1e-6 {
                let rhs = e2 - e1
                let s = (rhs.y * a2.x - rhs.x * a2.y) / determinant
                let candidate = e1 + a1 * s
                if simd_length(candidate - center) <= Float(2).squareRoot() * max(hBefore, hAfter) {
                    tip = candidate
                }
            }
            carving.addPoint(index, coverage: coverage) { polygon in
                polygon.append(inner)
                polygon.append(e1)
                if let tip { polygon.append(tip) }
                polygon.append(e2)
            }
        }
        let join = style.strokeJoin
        strokeRing(
            count: count, isClosed: outline.isClosed, curveSteps: outline.curveSteps,
            samePlace: { shapePoints[$0] == shapePoints[$1] },
            endSquare: { index, _ in addCap(index, round: false) },
            band: { a, b in
                let half = thin.bandHalf[a]
                let (start, end) = (points[a], points[b])
                carving.addBand(segment: a, coverage: thin.bandCoverage[a]) { polygon in
                    let delta = end - start
                    let length = simd_length(delta)
                    guard length > 0 else { return }
                    let normal = SIMD2(-delta.y, delta.x) / length * half
                    polygon.append(start + normal)
                    polygon.append(end + normal)
                    polygon.append(end - normal)
                    polygon.append(start - normal)
                }
            },
            disc: { index in
                if isEnd(index) { return addCap(index, round: true) }
                let (before, after) = bands(at: index)
                addJoin(
                    index, previous: before ?? index, next: after.map { ($0 + 1) % count } ?? index,
                    join: nil)
            },
            square: { index in
                // 開いた周の端の四角い端 (点 1 つの周は上で済んでいる)
                if isEnd(index) { addCap(index, round: false) }
            },
            corner: { index, previous, next in
                addJoin(index, previous: previous, next: next, join: join)
            })
        return (carving, offset)
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
        _ recipe: ThinStrokeRecipe, placedBy matrix: simd_float4x4, cache: ThinStrokeCache,
        stroke: Int
    ) -> (vertices: [ShapeVertex], coverage: [CoverageSpan])? {
        let combined = matrix * recipe.transform.matrix
        let linear = drawnLinear(combined)
        // 点 1 つの周は描く画素の軸に沿って置くので、回転ごとに形が違う。それ以外は回転に依らない
        let key =
            recipe.outline.points.count == 1
            ? SIMD4<Float>(
                linear.columns.0.x, linear.columns.0.y, linear.columns.1.x, linear.columns.1.y)
            : Self.rotationFreeKey(linear)
        if let cached = cache.built(stroke, key) { return cached }
        let built = buildThinVertices(recipe, placedBy: combined)
        cache.remember(built, stroke, key)
        return built
    }

    /// 描く画素へ写す 2x2 のうち、**回転 (と鏡映) に依らない部分** `DᵀD` を、控えと畳みの鍵に
    /// する (#1637)。
    ///
    /// 片は描く画素の空間で、点どうしの向きと隔たりだけから組む (``thinCarving(_:thin:)``) ので、
    /// 描く画素の空間で回しても片は一緒に回る。形自身の座標へ戻した頂点は `DᵀD` が同じなら同じ
    /// である。回して置き続ける形 (回転の角度が毎回違う) も、控えた頂点と雛形を使い回せる。
    ///
    /// 単精度の丸めで、同じ大きさの回転どうしでも `DᵀD` の最下位の桁は揺れる (0.25 と
    /// 0.24999999 のように指数をまたぐこともある)。鍵は大きさ (対角の和) の対数と、和で割った
    /// 3 成分を、それぞれ 1/4096 の刻みに丸めて揃える (相対 2⁻¹² ほどの違いは同じ形として扱う)。
    static func rotationFreeKey(_ linear: simd_float2x2) -> SIMD4<Float> {
        let gram = linear.transpose * linear
        let trace = gram.columns.0.x + gram.columns.1.y
        guard trace > 0, trace.isFinite else { return SIMD4(repeating: 0) }
        func coarse(_ value: Float) -> Float { (value * 4096).rounded() / 4096 }
        return SIMD4(
            coarse(log2(trace)), coarse(gram.columns.0.x / trace), coarse(gram.columns.1.x / trace),
            coarse(gram.columns.1.y / trace))
    }

    private func buildThinVertices(
        _ recipe: ThinStrokeRecipe, placedBy combined: simd_float4x4
    ) -> (vertices: [ShapeVertex], coverage: [CoverageSpan])? {
        thinStrokesRebuilt += 1
        // 周は、置いた後の大きさで刻み直す (#1645)。円板は描く画素の空間で組む
        // (``thinCarving(_:thin:)``) ので、この分割数は使わない
        let outline = recipe.outline(atScale: Self.splitScale(of: combined))
        guard let thin = thinOutline(outline, weight: recipe.weight, placedBy: combined)
        else { return nil }
        let saved = (style.strokeCap, style.strokeJoin)
        style.strokeCap = thin.isPoint ? .square : recipe.cap
        style.strokeJoin = recipe.join
        // 細い片は描く画素の空間で組み、円板の分割数は使わない (0)
        let carved = carveRecipe(
            outline, half: recipe.weight / 2, thin: thin, transform: recipe.transform,
            color: recipe.color, uv: recipe.uv, discSegments: 0)
        (style.strokeCap, style.strokeJoin) = saved
        return carved.built()
    }
}

/// 保持した形の輪郭を、**置いた後の太さで細ければ**広げて組み直す素材 ([#1637] 完了条件 5)。
///
/// 描く画素での太さは、置き場所の行列が決まるまで分からない。記録した形を縮めて置けば
/// 細くなるので、記録のときには判断できない。記録した頂点はそのまま持ち、置くたびに
/// ``Canvas/thinVertices(_:placedBy:cache:stroke:)`` で細さを測って、細ければ組み直した頂点で
/// 区間を差し替える。細くならない置き方 (いちばんよくある) は費用を払わない — 形の中で最も細い
/// 線でも細くならなければ区間を走査しない (``Shape/thinnestRecordedWeight``)。組み直した頂点は
/// 形が控える (``ThinStrokeCache``) ので、同じ大きさで置き続ける形は組み直さない。
///
/// **値で持つ** (記録のたびに箱を作らない)。周の点の並びは図形が組んだものを共有する。
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
    /// 記録のときに円板の周を刻んだ一周あたりの分割数。円板を置かない輪郭は 0 (#1645)。
    /// 置いた後の拡大で要る分割数が、これと周の分割数 (``Canvas/Outline/Ring/segments``) を
    /// 越えるとき、輪郭を刻み直す (``Canvas/rescaledVertices(_:placedBy:translucent:cache:stroke:)``)。
    let discSegments: Int
    /// 記録した頂点が、片を引いて積んだものか (重ねたまま積んだものではないか)。刻み直すときも
    /// 記録のときの積み方に合わせる — 不透明の線は重ねたまま積み、引くと縁の画素が 1/1000 画素の
    /// 所で入れ替わりうる (``Canvas/strokeOverlapsShow``)。
    let recordedCarved: Bool
    /// 半透明の色を掛けて置くとき、重ねたまま積んだ頂点を引いて積み直す輪郭か (``StrokeRange/carved``
    /// を持つ輪郭と同じ)。`replace` の線と点 1 つの輪郭は、重なっても同じ色なので引かない。
    let carvesWhenTinted: Bool

    /// 置いた後の拡大で刻み直す余地があるか。周が楕円・弧の周か、円板を置く輪郭。
    var mayRescale: Bool { outline.ring != nil || discSegments > 0 }

    /// 記録のときの変換を掛けた後の、いちばん細くなる向きの太さ (入れ子の外側の行列も含む)。
    /// 形の中で最も細い線を見つけるのに使う。**丸めない** — 置くときの行列と掛け合わせた後で、
    /// 1 度だけ丸める (``Canvas/smallestSingularValue(of:)``・#2039)。
    var recordedWeight: Float {
        let columns = transform.matrix.columns
        let linear = simd_float2x2(
            SIMD2(columns.0.x, columns.0.y), SIMD2(columns.1.x, columns.1.y))
        return Float(Double(weight) * Canvas.smallestSingularValue(of: linear))
    }

    /// 別の保持した形の中で置かれた輪郭。行列と色を合成する (置くときに判断するのは同じ)。
    ///
    /// - Parameter carvedNow: 置いたとき、頂点を引いて積んだものへ差し替えたか。差し替えたなら、
    ///   外側の記録の頂点は引いて積んである (``recordedCarved``)。
    func moved(by matrix: simd_float4x4, tint: LinearRGBA?, carvedNow: Bool) -> ThinStrokeRecipe {
        var color = self.color
        if let tint {
            color = LinearRGBA(
                premultipliedRed: color.red * tint.red, green: color.green * tint.green,
                blue: color.blue * tint.blue, alpha: color.alpha * tint.alpha)
        }
        return ThinStrokeRecipe(
            outline: outline, weight: weight, cap: cap, join: join, color: color,
            transform: Transform(matrix: matrix * transform.matrix), uv: uv,
            discSegments: discSegments, recordedCarved: recordedCarved || carvedNow,
            carvesWhenTinted: carvesWhenTinted)
    }
}

/// 保持した形の、組み直した細い輪郭の控え (#1637)。**形 1 つに 1 つ**で、輪郭ごと・描く画素へ
/// 写す 2x2 (回転を除く・``Canvas/rotationFreeKey(_:)``) ごとに持つ。
///
/// 輪郭ごとに箱を持たないのは、記録のたびに輪郭の数だけ箱を作る費用を払わないためである
/// (細くならない形にも払わせることになる)。参照の箱にしてあるのは、形 (値型) を写しても控えを
/// 共有するため。控えるのは輪郭ごとに数件まで — 置き場所ごとに大きさの違う形は鍵が増え続ける
/// ので、上限を越えたらその輪郭の控えを捨てて控え直す。
final class ThinStrokeCache {
    typealias Built = (vertices: [ShapeVertex], coverage: [Canvas.CoverageSpan])
    /// 輪郭 (``Shape/strokeRanges`` の番号) ごとの控え。`nil` を控えた鍵は「細くならない」。
    private var entries: [Int: [SIMD4<Float>: Built?]] = [:]
    static let capacity = 8

    /// 置いた後の大きさで周と円板を刻み直した頂点の控えの鍵 (#1645)。
    struct ScaledKey: Hashable {
        /// 塗りの控えか (偽なら輪郭)。
        var isFill: Bool
        /// ``Shape/strokeRanges`` か ``Shape/fillRanges`` の番号。
        var index: Int
        /// 周と円板の分割数の組 (``scaledKey(ring:disc:carved:)``)。
        var splits: Int
    }

    /// 置いた後の大きさで周と円板を刻み直した頂点 (#1645)。輪郭・塗りごと、分割数の組ごとに持つ。
    /// 分割数は拡大の違う置き場所の間で同じになりやすいので、拡大そのものを鍵にしない。
    ///
    /// **形 1 つにつき、頂点の総量で切る** (``scaledBudget``)。輪郭の数に上限が無いので、輪郭ごとの
    /// 件数では切れない。拡大を連続して変える形 (ズーム) は、輪郭の数 × 変えた回数の頂点を溜めうる
    /// し、周が上限 1024 に張り付く大きさでは 1 件が数万頂点になる。超えたら古い順に捨てる
    /// (``BoundedCache``)。
    private var scaled = BoundedCache<ScaledKey, [ShapeVertex]>(
        budget: ThinStrokeCache.defaultScaledBudget, weight: \.count)
    /// 刻み直した頂点の控えの上限 (頂点の数)。1 つ 32 バイトなので 4 MiB。**変えられるのは検査のため。**
    static let defaultScaledBudget = 1 << 17
    var scaledBudget: Int {
        get { scaled.budget }
        set { scaled.budget = newValue }
    }
    /// いま控えている刻み直した頂点の数 (検査用)。
    var scaledVertexTotal: Int { scaled.total }
    /// 刻み直した回数 (検査用)。控えが効いていれば、同じ大きさで置き続けても増えない。
    private(set) var strokesRescaled = 0
    private(set) var fillsRescaled = 0

    /// 周と円板の分割数と、引いて積んだかを 1 つの鍵にする。分割数はどちらも 1024 以下。
    static func scaledKey(ring: Int, disc: Int, carved: Bool) -> Int {
        (ring &* 2048 &+ disc) &* 2 &+ (carved ? 1 : 0)
    }

    func rescaledStroke(_ stroke: Int, _ splits: Int) -> [ShapeVertex]? {
        scaled[ScaledKey(isFill: false, index: stroke, splits: splits)]
    }

    func rememberRescaledStroke(_ vertices: [ShapeVertex], _ stroke: Int, _ splits: Int) {
        strokesRescaled += 1
        scaled.insert(vertices, for: ScaledKey(isFill: false, index: stroke, splits: splits))
    }

    func rescaledFill(_ fill: Int, _ splits: Int) -> [ShapeVertex]? {
        scaled[ScaledKey(isFill: true, index: fill, splits: splits)]
    }

    func rememberRescaledFill(_ vertices: [ShapeVertex], _ fill: Int, _ splits: Int) {
        fillsRescaled += 1
        scaled.insert(vertices, for: ScaledKey(isFill: true, index: fill, splits: splits))
    }

    func built(_ stroke: Int, _ key: SIMD4<Float>) -> Built?? {
        guard let table = entries[stroke] else { return nil }
        return table[key]
    }

    func remember(_ value: Built?, _ stroke: Int, _ key: SIMD4<Float>) {
        if (entries[stroke]?.count ?? 0) >= Self.capacity { entries[stroke] = [:] }
        entries[stroke, default: [:]][key] = value
    }

    /// 置いた後に細くなった名指しの基本図形の塗りを広げた頂点の控えの鍵 (#1934)。
    struct ThinFillKey: Hashable {
        /// ``Shape/fillRanges`` の番号。
        var fill: Int
        /// 描く画素へ写す 2x2 そのもの (広げ方が帯の向きで決まるので、回転を除かない)。
        var linear: SIMD4<Float>
    }

    /// 置いた後に細くなった名指しの基本図形の塗りを広げた頂点 (#1934・
    /// ``Canvas/thinFillVertices(_:placedBy:cache:fill:)``)。`nil` を控えた鍵は「細くならない」。
    ///
    /// **形 1 つにつき、頂点の総量で切る** (``thinFillBudget``・刻み直した頂点の控え ``scaled`` と同じ
    /// 切り方)。塗りの数に上限が無く、回して置き続ける形は塗りの数 × 置いた向きの数だけ鍵が増える
    /// うえ、細長い楕円は 1 件が最大で 6 × ``Canvas/thinEllipseSliceLimit`` 頂点になる。件数では切れ
    /// ない (#1934 の反証 5)。
    ///
    /// **重さは実体の大きさを頂点の数へ直して数える** (#1934 の 2 回目の反証 9)。頂点と被覆の区間の
    /// ほかに、1 件ごとに鍵・項目・使った順の記録・辞書の余りで 200 バイトほどを持つので、頂点
    /// ``thinFillEntryOverhead`` 個ぶんを足す。細くならない答え (`nil`) も同じだけ重い — 1 と数えて
    /// いた頃は、回して置き続ける形 1 つで答えだけが数十 MB まで溜まりえた。
    private var thinFills = BoundedCache<ThinFillKey, Built?>(
        budget: ThinStrokeCache.defaultScaledBudget,
        weight: {
            ThinStrokeCache.thinFillEntryOverhead + ($0?.vertices.count ?? 0)
                + ($0?.coverage.count ?? 0)
        })
    /// 細い塗りの控え 1 件が、頂点と被覆の区間のほかに持つ大きさ (頂点の数・頂点 1 つは 32 バイト)。
    static let thinFillEntryOverhead = 6
    /// いま控えている細い塗りの件数 (検査用・細くならない答えも数える)。
    var thinFillEntryCount: Int { thinFills.count }
    /// 細い塗りの控えの上限 (頂点の数)。**変えられるのは検査のため。**
    var thinFillBudget: Int {
        get { thinFills.budget }
        set { thinFills.budget = newValue }
    }
    /// いま控えている細い塗りの重さの合計 (検査用・頂点の数に直した実体の大きさ)。
    var thinFillVertexTotal: Int { thinFills.total }
    /// 細い塗りを測って組み直した回数 (検査用・細くならなかった回も数える)。控えが効いていれば、
    /// 同じ大きさ・向きで置き続けても増えない。
    var fillsThinned: Int { thinFills.made }

    func thinFill(_ fill: Int, _ key: SIMD4<Float>) -> Built?? {
        thinFills[ThinFillKey(fill: fill, linear: key)]
    }

    func rememberThinFill(_ value: Built?, _ fill: Int, _ key: SIMD4<Float>) {
        thinFills.insert(value, for: ThinFillKey(fill: fill, linear: key))
    }
}
