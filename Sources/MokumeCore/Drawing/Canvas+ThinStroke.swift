// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT
//
// 三角形の経路と立体で、描く画素で 1 画素より細い線を補う仕組み (#1637)。

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
    /// **帯を広げ、太さの割合を被覆として断片の後で掛ける。** 広げる量は、**描く画素の軸に沿って
    /// 列 (行) が帯を切る長さ**がちょうど整数 n になる量で、被覆は「元の切る長さ / n」である
    /// (``widenedBand(_:along:)``・塗りの #2182 と同じ・[#2172])。列ごとに跨ぐ画素の中心がちょうど n 個に
    /// なるので、光の量は向きにも置く位置にもよらず太さに比例する。帯が横寄りなら列が、縦寄りなら行が
    /// 帯を切る。軸に沿った帯は n = 1 で、太さちょうど 1 へ広げる。元の太さが 1 未満なら切る長さは √2
    /// 未満なので、n は 1 か 2 である。
    ///
    /// 線に垂直な太さを 1 にする広げ方 (#1637 の当初の形) は、45° の帯で列が切る長さが √2 になり、
    /// 跨ぐ中心が置く位置で全部の列そろって 1 つか 2 つになって、光の量が 1/√2 倍か √2 倍に振れた
    /// (傾きが p/q なら位相は q 列で一巡して均されるが、45° は q = 1)。
    ///
    /// **畳む雛形も同じ広げ方である** ([#3733])。広げ方が向きで変わるので、雛形は向きごとに畳む
    /// (``ThinFold``)。相似な置き場所の矩形だけは、雛形に半幅の微分を持たせて頂点段で置き場所ごとに広げ直し、
    /// 回した置き場所も 1 つの雛形に畳む (``appendWidenedTemplateStroke(_:)``・``FlatFrame/thinStroke``)。
    ///
    /// 被覆は頂点の色ではなく別の値で運ぶ (`ShapeFragmentIn.coverage`) ので、利用者の断片が
    /// `in.color` を掛けずに色を返しても、`in.color.a` を読んでも、`stroke()` で渡した値のまま届く。
    /// 1 未満の被覆を持つ片の重なりは、その場で引く線なら型板が (#1948)、畳む雛形と保持した形なら
    /// 引いて積む経路 (#1536) が、1 回だけ混ぜる。
    ///
    /// **点は描く画素 1 つの軸に沿った正方形にして、被覆を面積 (太さの 2 乗) にする。** 直径 1 の
    /// 円板は置く位置によって画素の中心を 1 つも含まないので、丸い点もこの形にする (距離関数の
    /// 経路の細い点と同じ量 — `halfDensityPointsKeepTheirArea`)。
    ///
    /// 描く画素で 1 画素以上の線は何も変えない (この型が作られない)。
    ///
    /// [#1637]: https://github.com/mokume-metal/mokume/issues/1637
    /// [#2172]: https://github.com/mokume-metal/mokume/issues/2172
    /// [#3733]: https://github.com/mokume-metal/mokume/issues/3733
    ///
    /// **この型の `widen` は線に垂直に 1 へ広げる倍率である。** 平面の輪郭の帯は、ここで細いかを決めた後、
    /// ``thinOutline(_:weight:placedBy:)`` が整数 n の幅に置き換える。立体の線の帯も、帯ごとに画面の向きで
    /// 整数 n の幅に置き換える ([#3734]): CPU の帯は ``SolidThinBand``、GPU で広げる稜線は頂点段
    /// (`Shapes.metal` の `solidStrokeThinBand`)。`widen` のまま使うのは、向きを持たない片 (円板・点) だけである。
    ///
    /// [#3734]: https://github.com/mokume-metal/mokume/issues/3734
    struct ThinStroke {
        /// 太さに掛ける倍率。掛けると描く画素で、線に垂直に測ってちょうど 1 になる。
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
    /// 描く画素での太さ。距離関数の経路の `inverseRows` の行ノルム (の逆数) と同じ量で、距離関数の経路の
    /// 細い形の分岐の境目 (`reachPerPixel`・#2991) とは、**直線の縁では 45° で √2 食い違う** — 距離関数の経路は
    /// 帯の両縁が 1 つの画素に入るかを、画素の正方形を法線へ射影した幅 (行の絶対値の和・45° で行ノルムの √2 倍) で
    /// 決める (縁の被覆を面積で数えるため)。**三角形の経路は、これに揃えない。** 縁に AA が無く (ADR-0039
    /// 決定 3)、補う目的は「列ごとに画素の中心をちょうど整数個跨がせる」ことで、広げる量は列 (行) が帯を切る
    /// 長さで決める (``ThinStroke``・#2172)。細いかどうかの境目は、この法線の太さ 1 のままにする。
    /// そのため、描く画素での太さが 1〜1.41 の斜めの線は、距離関数の経路では細い形の分岐で面積に比例した濃さになり、
    /// 三角形の経路では補わず中心を数えた濃さになる (平均では面積に等しい)。
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
        /// 線分ごとの、組む帯の太さの半分 (描く画素)。細い帯は列 (行) が帯を切る長さを整数 n にする幅の半分
        /// (``widenedBand(_:along:)``。線に垂直に広げる輪郭は 0.5)、そうでなければ元の太さの半分。
        var bandHalf: [Float]
        /// 線分ごとの被覆 (細い帯は「元の切る長さ / n」・線に垂直に広げる輪郭は元の太さ、そうでなければ 1)。
        var bandCoverage: [Float]
        /// 点 1 つの周か (描く画素 1 つの軸に沿った正方形にする)。
        var isPoint: Bool
        /// 点 1 つの周の被覆 (描く画素での面積)。
        var pointCoverage: Float
        /// 片のうちいちばん広い太さ (描く画素)。重なりを引く相手を探す幅に使う。
        var widest: Float
        /// 形自身の座標の原点が落ちる、**描く画素の絶対座標** (置き場所の平行移動と線の半画素の寄せを含む)。
        /// 開いた端を描く画素の列 (行) の境目で切るのに使う (``thinEndCuts(_:thin:base:)``・#3745)。置き場所ごとに
        /// 位相が変わる所 (畳む雛形) では `nil` で、端は線に垂直に切る。
        var origin: SIMD2<Float>? = nil
    }

    /// 行列 `matrix` で置いた形自身の座標の原点が落ちる、描く画素の絶対座標 (``ThinOutline/origin``)。線の頂点は
    /// 置いた後に出す画素で (+0.5, +0.5) 寄せる (``strokePoint(x:y:)``・保持した形は置くとき) ので、それを含める。
    func drawnOrigin(of matrix: simd_float4x4) -> SIMD2<Float> {
        let units = unitsPerDrawnPixel
        return SIMD2(
            (matrix.columns.3.x + 0.5) / units.x, (matrix.columns.3.y + 0.5) / units.y)
    }

    /// 輪郭の片ごとの補い。**どの片も細くならなければ `nil`** で、輪郭はこれまでどおり組む。
    ///
    /// 帯は**その帯の向きに垂直に測った**描く画素での太さで判断する。縦と横で倍率の違う変換
    /// (`scale(4, 0.25)`) では、横の辺だけが細くなる。点 1 つの周は向きを持たないので、面積の
    /// 倍率で測る。変換が潰れている (行列式 0) と何も補わない。
    ///
    /// 細い帯の広げ方は ``ThinStroke`` の説明のとおり、列 (行) が帯を切る長さを整数 n にする
    /// (``widenedBand(_:along:)``・[#2172])。
    ///
    /// [#2172]: https://github.com/mokume-metal/mokume/issues/2172
    ///
    /// `snapped` は、組んだ片が `matrix` で置かれて線の半画素の寄せを受けるか (畳む雛形は偽)。真なら描く画素の
    /// 絶対座標 (``ThinOutline/origin``) を持たせ、開いた端を列 (行) の境目で切る (#3745)。
    func thinOutline(
        _ outline: Outline, weight: Float, placedBy matrix: simd_float4x4, snapped: Bool = false
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
            any = true
            // 描く画素での帯の向き。長さ 0 の線分 (向きが決まらない) は線に垂直に広げる
            let along = linear * direction
            let length = simd_length(along)
            guard length > 0, length.isFinite else {
                bandHalf[index] = 0.5
                bandCoverage[index] = thin.coverage
                continue
            }
            let widened = Self.widenedBand(drawn, along: along / length)
            bandHalf[index] = drawn * widened.widen / 2
            bandCoverage[index] = widened.coverage
        }
        guard any else { return nil }
        return ThinOutline(
            linear: linear, inverse: linear.inverse, bandWeight: bandWeight, bandHalf: bandHalf,
            bandCoverage: bandCoverage, isPoint: false, pointCoverage: 1,
            widest: 2 * max(bandHalf.max() ?? 0.5, 0.5), origin: snapped ? drawnOrigin(of: matrix) : nil)
    }

    /// 細い片を持つ輪郭の片を、**描く画素の空間で**集める (``ThinOutline``)。点は描く画素の
    /// 空間の座標で、呼ぶ側が ``ThinOutline/inverse`` で形自身の座標へ戻し、置き場所ぶんのずれを
    /// 足す。
    ///
    /// - 帯: 線分の向きに垂直に、``ThinOutline/bandHalf`` の幅で組む
    /// - 端 (開いた周の両端): 置き場所の絶対座標が分かる端は、端の形によらず描く画素の列 (行) の境目で切る
    ///   (``thinEnds(_:outline:thin:offset:)``・#3745・#3748)。`.project` は太さの半分、`.round` は面積の等しい
    ///   太さ × π / 8 だけ延ばす。切れない端 (破線の片・畳む雛形・重なる端・列の中で曲がる短い端) は、**帯の向きに
    ///   沿っては元の太さの半分だけ**出し、横は帯と同じ幅にする。丸い端は楕円、出っ張らせる端は長方形。広げた帯の
    ///   幅で丸めると、端の光が元の 1 / 太さ 倍になる (細かさ 0.5 の太さ 1 で 2 倍)
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
        // 開いた端は、描く画素の列 (行) の境目で切る (#3745・``ThinEndCut``)。**端の列の片は、ほかの片より先に
        // 積む** — 曲線の短い端の線分で、後の片 (折れ目・次の帯) が端の列に入っても、引き算と型板で端の列の片が勝ち、
        // 列の光の量は割合のとおりになる
        let ends = thinEnds(points, outline: outline, thin: thin, offset: offset)
        for (point, band, cut) in ends.pieces(count: count) {
            let piece = cut.piece
            carving.addPoint(point, coverage: thin.bandCoverage[band] * cut.fraction) { polygon in
                polygon.append(contentsOf: piece)
            }
        }
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
            // **`Optional.map` に閉包を渡さない** (#2376)。main actor の閉包は、呼ぶたびに実行時の隔離の検査が入る。
            // 帯が無い側 (開いた周の端) は、太さの半分 0.5・覆い 1
            var hBefore: Float = 0.5
            var coverageBefore: Float = 1
            if let band = beforeBand {
                hBefore = thin.bandHalf[band]
                coverageBefore = thin.bandCoverage[band]
            }
            var hAfter: Float = 0.5
            var coverageAfter: Float = 1
            if let band = afterBand {
                hAfter = thin.bandHalf[band]
                coverageAfter = thin.bandCoverage[band]
            }
            let coverage = min(coverageBefore, coverageAfter)
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
        /// 細い帯の本体を、点 `index` の側の端から内へ下げる長さ (帯に沿った描く画素・#3793・``thinBandPieces``)。
        /// 隣の帯の長方形と角の片 (`miter` の尖りは太いほうの半幅の √2 倍まで) が、帯 `band` の本体に届かない長さ。
        /// 開いた端は端の片 (太さの半分) の長さで、列の境目で切った端は 0 (本体は境目で切られ、切り口の 2 つの頂点は
        /// 同じ境目の上で写しの縁を別々に補間した点 — 単精度の誤差を除いて写し)。
        /// 隣の帯が折り返す・向きが決まらないなら `nil` (帯は割らない)。
        func bandMargin(at index: Int, band: Int, cut: Bool) -> Float? {
            let slack: Float = 1 / 64
            if isEnd(index) { return cut ? 0 : thin.bandWeight[band] / 2 + slack }
            let (before, after) = bands(at: index)
            let ahead = after != band
            guard var other = ahead ? after : before, other != band else { return nil }
            // 同じ位置の点が続く (長さ 0 の帯) なら、その先の帯を隣とする (角の片も同じ位置の点を飛ばして組む)
            func far(_ other: Int) -> SIMD2<Float> { ahead ? points[(other + 1) % count] : points[other] }
            var steps = 0
            while far(other) == points[index] {
                steps += 1
                guard steps < segments else { return nil }
                if ahead {
                    guard outline.isClosed || other + 1 < segments else { return nil }
                    other = (other + 1) % segments
                } else {
                    guard outline.isClosed || other > 0 else { return nil }
                    other = (other + segments - 1) % segments
                }
                guard other != band else { return nil }
            }
            // 点から帯の向こうへ向く向き (自分と隣)
            let mine = (index == band ? points[(band + 1) % count] : points[band]) - points[index]
            let theirs = far(other) - points[index]
            let (mineLength, theirLength) = (simd_length(mine), simd_length(theirs))
            guard mineLength > 0, theirLength > 0 else { return nil }
            let cosine = dot(mine, theirs) / (mineLength * theirLength)
            let sine = abs(mine.x * theirs.y - mine.y * theirs.x) / (mineLength * theirLength)
            let (own, near) = (thin.bandHalf[band], thin.bandHalf[other])
            let tip = Float(2).squareRoot() * max(own, near)
            guard sine > 1e-3 else { return cosine < 0 ? tip + slack : nil }
            // 隣の帯の長方形が自分の帯の中に入る所の、帯に沿った最も遠い位置: (h_i + h_j)·cot φ + h_j (φ は内角)
            return max((own + near) * max(0, cosine / sine) + near, tip) + slack
        }
        let join = style.strokeJoin
        strokeRing(
            count: count, isClosed: outline.isClosed, curveSteps: outline.curveSteps,
            samePlace: { shapePoints[$0] == shapePoints[$1] },
            endSquare: { index, _ in
                // 列の境目で切った端は、延ばした端点で切ってある (端の長方形は置かない)
                if !ends.cuts(index, count: count) { addCap(index, round: false) }
            },
            band: { a, b in
                let half = thin.bandHalf[a]
                var (start, end) = (points[a], points[b])
                // 列の境目で切る端の帯は、端の外まで延ばしてから境目で切る (端の列とその外は端の列の片が持つ)
                let (startCut, endCut) = (ends.start(of: a), ends.end(of: a))
                if let startCut { start = startCut.tip - startCut.inward * 4 }
                if let endCut { end = endCut.tip - endCut.inward * 4 }
                let delta = end - start
                let length = simd_length(delta)
                guard length > 0 else { return }
                let normal = SIMD2(-delta.y, delta.x) / length * half
                let corners = [start + normal, end + normal, end - normal, start - normal]
                func trimmed(_ piece: [SIMD2<Float>]) -> [SIMD2<Float>] {
                    var piece = piece
                    if let startCut { piece = startCut.trimmed(piece) }
                    if let endCut { piece = endCut.trimmed(piece) }
                    return piece
                }
                // 細い帯は、写しの本体と両端の片に割る (#3793・``thinBandPieces``)。本体は隣の帯と角の片に届かない所に
                // あるので、積む順によらず引かれない。片は帯に沿った順に積む (角の片が後から端の片を引く・割る前の帯と同じ順)
                if thin.bandWeight[a] < 1,
                    let startMargin = bandMargin(at: a, band: a, cut: startCut != nil),
                    let endMargin = bandMargin(at: b, band: a, cut: endCut != nil),
                    let split = Self.thinBandPieces(
                        corners, half: half, margins: (startMargin, endMargin))
                {
                    for part in split {
                        let piece = trimmed(part)
                        if !piece.isEmpty {
                            carving.addBand(segment: a, coverage: thin.bandCoverage[a]) { $0.append(contentsOf: piece) }
                        }
                    }
                    return
                }
                let piece = trimmed(corners)
                carving.addBand(segment: a, coverage: thin.bandCoverage[a]) { $0.append(contentsOf: piece) }
            },
            disc: { index in
                if isEnd(index) {
                    // 列の境目で切った丸い端は、面積の等しい平らな延長で切ってある (丸い片は置かない・#3748)
                    if !ends.cuts(index, count: count) { addCap(index, round: true) }
                    return
                }
                let (before, after) = bands(at: index)
                var next = index
                if let after { next = (after + 1) % count }
                addJoin(index, previous: before ?? index, next: next, join: nil)
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

    /// 細い帯の長方形 `corners` (`[始まり + 法線, 終わり + 法線, 終わり − 法線, 始まり − 法線]`・描く画素・半幅 `half`) を、
    /// **縁を写しにした片**に割る (#3793)。帯に沿った順に、始まりの三角形・始まりの写しの平行四辺形・本体・終わりの写しの
    /// 平行四辺形・終わりの三角形を返す (空の片は返さない)。割れない (本体が残らない) なら `nil`。
    ///
    /// 帯の 2 本の縁は、帯を切る軸 (横寄りの帯なら y) に沿ってちょうど n (``widenedBand(_:along:)`` の帯の数) 離れて
    /// いる。長方形の 4 隅をそのまま置くと、GPU が頂点を描く画素の 1/256 へ丸めたときに 2 本の縁が別々に動き、縁が
    /// 画素の中心とほぼ重なる列で中心を 2 つ (か 0 個) 数える (#3788 の額縁・#3763 の塗りと同じ根)。そこで一方の縁の
    /// 頂点 X を、もう一方の縁の頂点の写し Y = X + n にする。
    ///
    /// - **三角形** (A, X₀, Y₀, D): 写しが端の長方形に収まる位置 X₀ (写しが帯に沿って端の側へ戻る分) までの残り。縁を
    ///   別々に置くのはここだけで、帯に沿って高々 n·(帯の向きの短い成分) の長さ
    /// - **写しの平行四辺形** (X₀ … X_m): 隣の帯と角の片が届きうる区間。縁は写しだが、重なりを引く輪郭では引かれて
    ///   頂点が増えうる。区間を分けてあるので、そうなっても本体の縁は傾かない
    /// - **本体** (X_m … X′_m): 両端から `margins` (帯に沿った長さ) より内側。写しの頂点も含めてどの片とも重ならない
    ///   ので、積む順によらず引かれず、写しのまま残る。呼ぶ側は、隣の帯と角の片 (と開いた端の片) が届かない長さを渡す
    ///
    /// 帯の領域は割る前と同じで、隣り合う片は頂点を共有する。写しは描く画素の空間で足すので、出す座標へ戻して写し
    /// 直す単精度の往復の誤差は残る (塗りの帯と同じ・``thinFillPieces(_:by:)``)。
    static func thinBandPieces(
        _ corners: [SIMD2<Float>], half: Float, margins: (start: Float, end: Float)
    ) -> [[SIMD2<Float>]]? {
        guard corners.count == 4 else { return nil }
        let (a, b, c, d) = (corners[0], corners[1], corners[2], corners[3])
        let along = b - a
        let length = simd_length(along)
        guard length > 0, length.isFinite, half > 0 else { return nil }
        let u = along / length
        // 写しの軸 (帯が横寄りなら y) と、縁 1 (a, b) から縁 2 (d, c) への写し
        let axis = abs(u.x) >= abs(u.y) ? 1 : 0
        let major = max(abs(u.x), abs(u.y))
        let crossings = (2 * half / major).rounded()
        guard crossings >= 1 else { return nil }
        var copy = SIMD2<Float>(0, 0)
        copy[axis] = d[axis] - a[axis] >= 0 ? crossings : -crossings
        // 写し Y = X + copy は、帯に沿って X から dot(copy, u) ずれる。写しが端の長方形に収まる位置 (三角形の終わり) と、
        // X と Y の**両方**が余白より内に入る位置 (本体の始まり)
        let shift = dot(copy, u)
        let slack: Float = 1 / 64
        let startFit = max(0, -shift) + slack
        let endFit = max(0, shift) + slack
        let startCore = startFit + margins.start
        let endCore = endFit + margins.end
        guard startCore + endCore < length else { return nil }
        let (x0, xs) = (a + u * startFit, a + u * startCore)
        let (xe, x1) = (b - u * endCore, b - u * endFit)
        var pieces: [[SIMD2<Float>]] = [[a, x0, x0 + copy, d]]
        if margins.start > 0 { pieces.append([x0, xs, xs + copy, x0 + copy]) }
        pieces.append([xs, xe, xe + copy, xs + copy])
        if margins.end > 0 { pieces.append([xe, x1, x1 + copy, xe + copy]) }
        pieces.append([b, c, x1 + copy, x1])
        return pieces
    }

    /// 開いた周の両端の、描く画素の列 (行) の境目での切り方 (#3745・``ThinEndCut``)。
    ///
    /// 切るのは、開いた周で、端の帯 (同じ位置の点を飛ばした最初と最後の帯) が細い (広げた) 帯で、置き場所の描く画素の
    /// 絶対座標が分かる (``ThinOutline/origin``) 端だけである。端の形はどれも切る (`.round` は面積の等しい平らな延長に
    /// する・#3748・``ThinEndCut/extent(of:weight:)``)。
    ///
    /// - 1 本の帯の両端が同じ列に入る (描く画素で短い線) なら、1 つの片にして割合は両端の差にする
    /// - 両端の列の片が重なる (端点の重なる開いた周・ごく短い折れ線) なら、両端とも切らない (線に垂直に切る)。
    ///   片の割合が同じ列を 2 度数えるからである
    func thinEnds(
        _ points: [SIMD2<Float>], outline: Outline, thin: ThinOutline, offset: SIMD2<Float>
    ) -> ThinEnds {
        let cap = style.strokeCap
        let count = points.count
        guard !outline.isClosed, !outline.isDashPiece, count >= 2, let origin = thin.origin,
            let first = (0..<(count - 1)).first(where: { points[$0 + 1] != points[$0] }),
            let last = (0..<(count - 1)).last(where: { points[$0 + 1] != points[$0] })
        else { return ThinEnds() }
        let base = origin + thin.linear * offset
        func cut(band: Int, end: Int, far: Int, axis: Int?) -> ThinEndCut? {
            let weight = thin.bandWeight[band]
            guard weight > 0, weight < 1 else { return nil }
            return ThinEndCut(
                end: points[end], far: points[far], extend: ThinEndCut.extent(of: cap, weight: weight),
                half: thin.bandHalf[band], base: base, axis: axis)
        }
        var ends = ThinEnds()
        ends.startBand = first
        ends.endBand = last
        ends.startCut = cut(band: first, end: first, far: first + 1, axis: nil)
        // 同じ帯の両端は、軸を揃える (45° ちょうどで向きの丸めにより軸が割れないように)
        ends.endCut = cut(band: last, end: last + 1, far: last, axis: first == last ? ends.startCut?.axis : nil)
        // 端の帯が端の列より短い折れ線は、列の中で線が端の帯の向きからそれないときだけ切る (#3745 の反証 3)。
        // それる (列の中で曲がる) と、端の列の片が角を越えて境目まで出て、後の片を消す
        if first != last {
            if let start = ends.startCut {
                var index = first
                if !start.staysStraight({
                    index += 1
                    return index < count ? points[index] : nil
                }) {
                    ends.startCut = nil
                }
            }
            if let end = ends.endCut {
                var index = last + 1
                if !end.staysStraight({
                    index -= 1
                    return index >= 0 ? points[index] : nil
                }) {
                    ends.endCut = nil
                }
            }
        }
        if let start = ends.startCut, let end = ends.endCut {
            if first == last, let one = ThinEndCut.merged(start, end) {
                ends.mergedCut = one
            } else if first != last, start.overlaps(end) {
                return ThinEnds()
            }
        }
        return ends
    }

    /// 開いた周の両端の切り方 (``thinEnds(_:outline:thin:offset:)``)。
    struct ThinEnds {
        var startCut: ThinEndCut?
        var startBand = -1
        var endCut: ThinEndCut?
        var endBand = -1
        /// 1 本の帯の両端が同じ列に入るときの、1 つにした片。
        var mergedCut: ThinEndCut?

        /// 帯 `band` の始まりの端の切り方。
        func start(of band: Int) -> ThinEndCut? { band == startBand ? startCut : nil }
        /// 帯 `band` の終わりの端の切り方。
        func end(of band: Int) -> ThinEndCut? { band == endBand ? endCut : nil }

        /// 点 `index` が列の境目で切った端か。
        func cuts(_ index: Int, count: Int) -> Bool {
            (index == 0 && startCut != nil) || (index == count - 1 && endCut != nil)
        }

        /// 積む端の列の片 (点・端の帯・切り方)。
        func pieces(count: Int) -> [(point: Int, band: Int, cut: ThinEndCut)] {
            if let mergedCut { return [(0, startBand, mergedCut)] }
            var found: [(point: Int, band: Int, cut: ThinEndCut)] = []
            if let startCut { found.append((0, startBand, startCut)) }
            if let endCut { found.append((count - 1, endBand, endCut)) }
            return found
        }
    }

    /// 平面の輪郭を補うときに細さを測る行列。**最後の変換が決まらない所では測らない** —
    /// 保持する形の記録 (置くときに測る・``ThinStrokeRecipe``)。畳みの雛形は、雛形の鍵が持つ
    /// 置き場所の変換 (``templateStrokeMatrix``・細い線の雛形は同じ 2x2 の置き場所か、頂点段で広げ直す矩形だけで畳む)
    /// で測る。線の半画素の寄せ (`strokePoint`) を先送りする所と同じである。
    var thinStrokeMatrix: simd_float4x4? {
        if recordingShape { return nil }
        if buildingFlatTemplate { return templateStrokeMatrix }
        return flatTransform.matrix
    }

    // MARK: - 細い矩形の輪郭 (額縁)

    /// 相似な置き場所の矩形の細い輪郭を組む片 (#3733)。頂点ごとに、形自身の座標の点 `bases` と、形自身の座標の
    /// 半幅 t に掛ける向き `slopes` を持ち、置く点は `bases + t × slopes` である。ただし先頭の
    /// ``thinRectBandVertexCount`` 個 (4 本の帯) の写しの頂点は、頂点の番号で決まる役割 (``thinRectRole(_:)``) に従って
    /// 同じ端の 2 点から組む (#3788・``thinRectPoints(_:units:place:)``)。
    struct ThinRectFrame {
        var bases: [SIMD2<Float>]
        var slopes: [SIMD2<Float>]
        /// 形自身の座標の半幅 t (= 描く画素の半幅 / 拡大率)。
        var half: Float
        /// 被覆 (4 本の帯で同じ)。
        var coverage: Float
        /// 列 (行) が帯を切る長さ n (``widenedBand(_:along:)`` の帯の数・4 本の帯で同じ・#3788)。
        var crossings: Float
        /// 置き場所の描く画素の 2x2 (``drawnLinear(_:)``)。写しの向きを決める (#3788)。
        var drawn: simd_float2x2
    }

    /// 額縁の 4 本の帯の頂点の数 (帯 1 本で 30・#3788)。帯は形の y0 の辺・y1 の辺 (x の帯)・x0 の辺・x1 の辺
    /// (y の帯) の順で、1 本は「始まりの端の片 12・本体の平行四辺形 6・終わりの端の片 12」である。
    static let thinRectBandVertexCount = 120

    /// 額縁の帯の頂点 `ordinal` の役割 (#3788)。`role` は 0 が角を置いた点、1 が外の縁の写しの頂点 X、
    /// 2 が内の縁の写しの頂点 Y で、写しの頂点は `bases`・`slopes` に同じ端の内側の角 F を持ち、`outer` は同じ端の
    /// 外の縁の端点 A の番号である。**頂点段 (`Shapes.metal` の `mokume_thinRectRole`) と同じ表** — 片の並びを
    /// 変えるときは両方を同時に変える。
    ///
    /// 端の片は (P, A, X)・(P, X, Y)・(P, Y, F)・(P, F, B) の扇で、P は miter で A、bevel で端の辺に乗る角の片の
    /// 頂点、B は内の縁の端点 (y の帯では F と同じ点)。本体は (X, X′, Y′)・(X, Y′, Y) (′ は終わりの端)。
    static func thinRectRole(_ ordinal: Int) -> (role: Int, outer: Int) {
        guard ordinal < thinRectBandVertexCount else { return (0, 0) }
        let band = ordinal / 30 * 30
        let slot = ordinal % 30
        if slot >= 12, slot < 18 {
            let (end, role) = [(0, 1), (18, 1), (18, 2), (0, 1), (18, 2), (0, 2)][slot - 12]
            return (role, band + end + 1)
        }
        let end = slot >= 18 ? 18 : 0
        let index = slot - end
        let role = index == 2 || index == 4 ? 1 : (index == 5 || index == 7 ? 2 : 0)
        return (role, band + end + 1)
    }

    /// 出す座標の点 `placed` を、描く画素の 1/256 の格子へ丸める (#3788)。GPU は頂点を描く画素の 1/256 へ丸めて
    /// 三角形を刻むので、先に同じ格子へ置いておけば、写し (格子の点 + 整数) は刻むときも写しのままになる。
    /// 出す座標へ戻すと単精度で 1/256 の格子からわずかにずれるが、ずれは格子の半分よりずっと小さい。
    /// **頂点段の `mokume_thinRectGrid` と同じ順。**
    static func thinRectGrid(_ placed: SIMD2<Float>, units: SIMD2<Float>) -> SIMD2<Float> {
        ((placed / units) * 256).rounded(.toNearestOrEven) * (1 / 256)
    }

    /// 帯の端の写しの頂点 (描く画素の格子) を、同じ端の外の縁の端点 `outer` と内側の角 `inner` から組む (#3788)。
    /// `slope` は内側の角の向き (形自身の座標で、角から矩形の内へ向く (±1, ±1))。
    ///
    /// 帯を切る軸 (帯が x 寄りなら y) に沿った外 → 内の写し c (長さ n)。内側の角が、切る軸でない軸の座標で外の縁の端点
    /// より帯の内向きにあれば、X = 内側の角 − c・Y = 内側の角 (内側の角を端の片と共有する)、そうでなければ X = 外の縁の
    /// 端点・Y = 外の縁の端点 + c。どちらでも X と Y は格子の上の写しで、本体の 2 本の縁は列 (行) ごとにちょうど n 個の
    /// 画素の中心を挟む。**頂点段の `mokume_thinRectCopy` と同じ順。**
    static func thinRectCopy(
        outer: SIMD2<Float>, inner: SIMD2<Float>, slope: SIMD2<Float>, drawn: simd_float2x2, crossings: Float,
        xBand: Bool, isInner: Bool
    ) -> SIMD2<Float> {
        // 帯をこの端から内へ進む向きと、外 → 内の向き (描く画素)
        let inward = xBand ? drawn.columns.0 * slope.x : drawn.columns.1 * slope.y
        let across = xBand ? drawn.columns.1 * slope.y : drawn.columns.0 * slope.x
        let axis = abs(inward.x) >= abs(inward.y) ? 1 : 0
        let other = 1 - axis
        var copy = SIMD2<Float>(0, 0)
        copy[axis] = across[axis] >= 0 ? crossings : -crossings
        let fromInner = (inner[other] - outer[other]) * (inward[other] >= 0 ? 1 : -1) >= 0
        if isInner { return fromInner ? inner : outer + copy }
        return fromInner ? inner - copy : outer
    }

    /// 額縁の頂点を出す座標で求める (#3788)。`place` は形自身の座標の点を出す座標へ置く (直に描く口は `strokePoint`)。
    /// 角を置いた点は描く画素の格子へ丸め (``thinRectGrid(_:units:)``)、帯の写しの頂点は ``thinRectCopy`` で組む。
    static func thinRectPoints(
        _ frame: ThinRectFrame, units: SIMD2<Float>, place: (SIMD2<Float>) -> SIMD2<Float>
    ) -> [SIMD2<Float>] {
        func grid(_ index: Int) -> SIMD2<Float> {
            thinRectGrid(place(frame.bases[index] + frame.half * frame.slopes[index]), units: units)
        }
        return frame.bases.indices.map { index in
            let (role, outer) = thinRectRole(index)
            let pixel =
                role == 0
                ? grid(index)
                : thinRectCopy(
                    outer: grid(outer), inner: grid(index), slope: frame.slopes[index], drawn: frame.drawn,
                    crossings: frame.crossings, xBand: index < thinRectBandVertexCount / 2, isInner: role == 2)
            return pixel * units
        }
    }

    /// 細い矩形の輪郭を額縁の片で組めるか。**畳みの鍵** (``thinStrokeLinear(form:)``) **と直に描く口が同じ規則を
    /// 使う** — 畳むかどうかで積み方を変えない。
    ///
    /// 置き場所の描く画素の 2x2 が相似 (回転と一様な拡大) で、角が丸くなく (`round` は円板の刻みが半径で変わる)、
    /// 描く画素での辺の長さが 4 以上 (額縁の内側が潰れない) のときだけ組む。
    static func framesThinRect(
        width: Float, height: Float, weight: Float, join: StrokeJoin, drawn: simd_float2x2
    ) -> Bool {
        guard join != .round, isSimilarity(drawn) else { return false }
        let scale = abs(simd_determinant(drawn)).squareRoot()
        // 細いかは額縁を組む口と同じ式で決める (畳みの鍵と食い違うと、鍵が頂点段を約束したのに組めない)
        return min(abs(width), abs(height)) * scale >= 4
            && ThinStroke(drawnWeight: roundedDrawnWeight(weight * scale), isPoint: false) != nil
    }

    /// 矩形の細い輪郭を、**重ならない片**で組む (#3733)。組めなければ `nil` で、呼ぶ側はこれまでどおり
    /// 片を組んで引く (``thinCarving(_:thin:)``)。
    ///
    /// 相似な置き場所では、矩形の 4 本の帯はどれも同じ描く画素の太さと「軸の成分」を持つので、広げた半幅 h と
    /// 被覆は 1 つに決まる (``widenedBand(_:along:)``)。輪郭は、矩形を半幅 t だけ外へ広げた枠から内へ縮めた枠を
    /// 抜いた額縁で、角の形 (`miter` は正方形・`bevel` は外の角を斜めに落とした三角形) も含めて、片の頂点は
    /// どれも「矩形の角 + t × 決まった向き」になる。片を引いて積む (``StrokeCarving``) のと同じ領域を、
    /// 引かずに重ならない片で覆う。
    ///
    /// - 上下の帯: `miter` は角の正方形まで含めて横に通す。`bevel` は角の点まで
    /// - 左右の帯: 上下の帯の間 (`bevel` は外側の半分だけ角の点まで延ばす)
    /// - `bevel` の角: 角の点と、2 本の帯の外の縁の角を結んだ三角形
    ///
    /// **帯の長方形は、2 本の長い縁を写しにした平行四辺形と両端の片に割る** (#3788・``thinRectRole(_:)``)。
    /// 帯の 2 本の縁は、帯を切る軸に沿ってちょうど n 離れているが、別々の頂点で組むと GPU が頂点を描く画素の 1/256 へ
    /// 丸めたときに別々に動き、45° 近くで縁が画素の中心とほぼ重なる行が続くと、中心を 2 つ (または 0 個) 数える。
    /// 本体の一方の縁を他方の縁 + n の写しにすれば、列 (行) ごとにちょうど n 個になる。端の片は帯の長方形の残りを
    /// 埋め、内側の角 (隣の帯の端の頂点) も頂点に持つので、帯の領域・角の片・角の形は割る前と同じで、片どうしは
    /// 頂点を共有して継ぎ目に T 字を作らない。
    ///
    /// 頂点が t について線形なので、雛形は角と向きを持たせて頂点段で置き場所ごとに広げ直せる
    /// (``appendWidenedTemplateStroke(_:)``)。**半幅と被覆の式と、頂点の組み方 (``thinRectPoints(_:units:place:)``)
    /// は、頂点段 (`Shapes.metal` の `mokume_thinRectBand`・`mokume_thinRectVertex`) と 1 つずつ同じ順である** —
    /// 1 つ目 (ここで直に組む) と雛形で額縁の頂点が 1 ulp も違わないよう、式を変えるときは両方を同時に変える (#3555)。
    func thinRectFrame(_ outline: Outline, placedBy matrix: simd_float4x4) -> ThinRectFrame? {
        guard outline.isClosed, outline.points.count == 4, outline.cornerDiagonals.count == 4 else { return nil }
        let points = outline.points
        let (x0, x1) = (min(points[0].x, points[2].x), max(points[0].x, points[2].x))
        let (y0, y1) = (min(points[0].y, points[2].y), max(points[0].y, points[2].y))
        let join = style.strokeJoin
        let drawn = drawnLinear(matrix)
        guard
            Self.framesThinRect(
                width: x1 - x0, height: y1 - y0, weight: style.strokeWeight, join: join, drawn: drawn)
        else { return nil }
        let scale = abs(simd_determinant(drawn)).squareRoot()
        let drawnWeight = Self.roundedDrawnWeight(style.strokeWeight * scale)
        let along = drawn * SIMD2<Float>(1, 0)
        let length = simd_length(along)
        guard length > 0, length.isFinite else { return nil }
        let direction = along / length
        let widened = Self.widenedBand(drawnWeight, along: direction)
        // 帯の数 n (``widenedBand(_:along:)`` の中と同じ式)
        let crossings: Float = drawnWeight / max(abs(direction.x), abs(direction.y)) <= 1 ? 1 : 2
        let drawnHalf = drawnWeight * widened.widen / 2
        var bases: [SIMD2<Float>] = []
        var slopes: [SIMD2<Float>] = []
        /// 角を `(x, sx, y, sy)` (点は `(x + t·sx, y + t·sy)`) で並べた凸多角形を、最初の点からの扇に割る
        func piece(_ corners: [(Float, Float, Float, Float)]) {
            for index in 2..<corners.count {
                for corner in [corners[0], corners[index - 1], corners[index]] {
                    bases.append(SIMD2(corner.0, corner.2))
                    slopes.append(SIMD2(corner.1, corner.3))
                }
            }
        }
        /// 軸に沿った長方形 (x の範囲・y の範囲)
        func box(_ left: (Float, Float), _ right: (Float, Float), _ top: (Float, Float), _ bottom: (Float, Float)) {
            piece([
                (left.0, left.1, top.0, top.1), (right.0, right.1, top.0, top.1),
                (right.0, right.1, bottom.0, bottom.1), (left.0, left.1, bottom.0, bottom.1),
            ])
        }
        // 4 本の帯 (``thinRectRole(_:)`` の並び)。帯の長方形は main の額縁と同じで、`miter` の上下の帯は角の正方形
        // まで横に通し、`bevel` の上下の帯は角の点まで、左右の帯は上下の帯の間。端ごとに、矩形の角と、角から矩形の内へ
        // 向く (ix, iy) で、P (扇の要)・A (外の縁の端点)・F (内側の角)・B (内の縁の端点) を決める
        let miter = join == .miter
        for (xBand, start, end) in [
            (true, SIMD2(x0, y0), SIMD2(x1, y0)), (true, SIMD2(x0, y1), SIMD2(x1, y1)),
            (false, SIMD2(x0, y0), SIMD2(x0, y1)), (false, SIMD2(x1, y0), SIMD2(x1, y1)),
        ] {
            func inward(_ corner: SIMD2<Float>) -> SIMD2<Float> {
                SIMD2(corner.x == x0 ? 1 : -1, corner.y == y0 ? 1 : -1)
            }
            func endPieces(_ corner: SIMD2<Float>) {
                let inner = inward(corner)
                let (ix, iy) = (inner.x, inner.y)
                let outer = xBand ? SIMD2(miter ? -ix : 0, -iy) : SIMD2(-ix, iy)
                let side = xBand ? SIMD2(miter ? -ix : 0, iy) : inner
                let pivot = miter ? outer : (xBand ? SIMD2<Float>(0, 0) : SIMD2(0, iy))
                // (P, A, X)・(P, X, Y)・(P, Y, F)・(P, F, B)。写しの頂点 X・Y は内側の角を持つ
                for slope in [pivot, outer, inner, pivot, inner, inner, pivot, inner, inner, pivot, inner, side] {
                    bases.append(corner)
                    slopes.append(slope)
                }
            }
            endPieces(start)
            // 本体の平行四辺形 (X, X′, Y′)・(X, Y′, Y)
            for corner in [start, end, end, start, end, start] {
                bases.append(corner)
                slopes.append(inward(corner))
            }
            endPieces(end)
        }
        if !miter {
            // 左右の帯の外側の半分を角の点まで
            box((x0, -1), (x0, 0), (y0, 0), (y0, 1))
            box((x0, -1), (x0, 0), (y1, -1), (y1, 0))
            box((x1, 0), (x1, 1), (y0, 0), (y0, 1))
            box((x1, 0), (x1, 1), (y1, -1), (y1, 0))
            // 外の角を斜めに落とした三角形
            piece([(x0, 0, y0, 0), (x0, 0, y0, -1), (x0, -1, y0, 0)])
            piece([(x1, 0, y0, 0), (x1, 1, y0, 0), (x1, 0, y0, -1)])
            piece([(x1, 0, y1, 0), (x1, 0, y1, 1), (x1, 1, y1, 0)])
            piece([(x0, 0, y1, 0), (x0, -1, y1, 0), (x0, 0, y1, 1)])
        }
        return ThinRectFrame(
            bases: bases, slopes: slopes, half: drawnHalf / scale, coverage: widened.coverage,
            crossings: crossings, drawn: drawn)
    }

    /// 額縁の片を、いまの変換で積む (直に描く口)。被覆を頂点に付ける。面積 0 の片 (端の片の使わない側) も
    /// 積む — 雛形と頂点の数を揃える。
    func appendThinRectFrame(_ frame: ThinRectFrame) {
        let start = vertices.count
        let points = Self.thinRectPoints(frame, units: unitsPerDrawnPixel) { strokePoint(x: $0.x, y: $0.y) }
        var index = 0
        while index + 2 < points.count {
            appendTriangle(points[index], points[index + 1], points[index + 2], color: style.stroke)
            index += 3
        }
        noteCoverage(frame.coverage, in: start..<vertices.count)
    }

    // MARK: - 頂点段で広げ直す雛形

    /// 相似な置き場所の矩形の雛形の細い輪郭を、**頂点段で置き場所ごとに広げ直す形で**積む (#3733・
    /// ``ThinFold/widensInVertexStage``)。返すのは列に渡す値 (``FlatFrame/thinStrokeParams``)。積めなければ
    /// `nil` で、呼ぶ側はこれまでどおり積む。
    ///
    /// 片は直に描く口と同じ額縁 (``thinRectFrame(_:placedBy:)``) で、頂点の `position` に片の角 (`bases`・形自身の
    /// 座標)、`uv` に角から広げる向き (`slopes`・各成分 −1・0・1) を入れる。頂点段 (`shapeVertexMain`) は置き場所の
    /// 2x2 から半幅と被覆を ``thinRectFrame(_:placedBy:)`` と同じ式で求め、`(角 + 位置) + 半幅 × 向き` に置く —
    /// 1 つ目を直に組むときの `ずらした角 + 半幅 × 向き` と同じ順で、畳んだ頂点が 1 ビットも違わない (#3555)。
    /// 鍵の置き場所で組んだ半幅を雛形に焼いて置き場所ごとに差分を足す形にすると、丸めが 1 つ目と違う。
    /// 帯の写しの頂点は、頂点段が輪郭の何番目の頂点かで役割を引き (``thinRectRole(_:)``)、同じ端の外の縁の端点を
    /// 雛形から読んで ``thinRectPoints(_:units:place:)`` と同じ順で組む (#3788)。
    func appendWidenedTemplateStroke(_ outline: Outline) -> SIMD4<Float>? {
        guard let matrix = thinStrokeMatrix, let frame = thinRectFrame(outline, placedBy: matrix) else {
            return nil
        }
        let start = vertices.count
        // 角だけを積む (半幅を足さない)。雛形は変換を掛けずに積むので、角は形自身の座標のまま
        var index = 0
        while index + 2 < frame.bases.count {
            appendTriangle(
                frame.bases[index], frame.bases[index + 1], frame.bases[index + 2], color: style.stroke)
            index += 3
        }
        // 被覆は頂点段が置き場所ごとに求める (頂点に被覆を付けない)。鍵の置き場所でちょうど 1 でも、
        // 回した置き場所では 1 未満になりうるので、置き換える列は下地を読む組で描く印を必ず立てる (#3111)
        openBatchHasThinCoverage = true
        for (offset, slope) in frame.slopes.enumerated() {
            vertices[start + offset].uv = slope
        }
        return SIMD4(style.strokeWeight, Float(1 - Self.thinStrokeTolerance), whiteUV.x, whiteUV.y)
    }

    // MARK: - 立体の線

    /// 立体の線の補い。**記録の間は判断しない** — 置く面 (細かさ) が決まるのは置くときで、
    /// 記録した部品は置くときに組み直す (``rebuiltSolidStroke(_:)``)。
    func thinSolidStroke(weight: Float, isPoint: Bool) -> ThinStroke? {
        guard !recordingShape else { return nil }
        return ThinStroke(drawnWeight: drawnSolidWeight(weight), isPoint: isPoint)
    }

    /// 補いを当てた立体の線の設定 (太さ・被覆・点の端の形) で `body` を走らせ、元へ戻す。
    ///
    /// 太さと被覆は線に垂直に 1 へ広げたもので、帯を持たない片 (円板・点) が使う。帯は帯ごとに画面の向きで
    /// 広げ直す (``solidThinBand``・``SolidThinBand``・[#3734])。
    ///
    /// [#3734]: https://github.com/mokume-metal/mokume/issues/3734
    func withThinSolidStroke(_ thin: ThinStroke?, isPoint: Bool, _ body: () -> Void) {
        guard let thin else { return body() }
        let saved = (style.strokeWeight, style.strokeCap, solidStrokeCoverage, solidThinBand)
        solidThinBand = isPoint ? nil : solidThinBand(weight: style.strokeWeight)
        style.strokeWeight *= thin.widen
        solidStrokeCoverage = thin.coverage
        // 向きの無い点の四角い端は、画面の軸に沿った正方形
        if isPoint { style.strokeCap = .square }
        body()
        (style.strokeWeight, style.strokeCap, solidStrokeCoverage, solidThinBand) = saved
    }

    /// 細い立体の線の帯の広げ方の元。**帯ごとに、画面に写した帯の向きで広げる** ([#3734])。
    ///
    /// 平面の線と同じく、描く画素の軸に沿って列 (行) が帯を切る長さを整数 n にする (``widenedBand(_:along:)``・
    /// [#2172])。線に垂直に 1 へ広げると、45° の帯で列が切る長さが √2 になり、光の量が置く位置で 1/√2 倍か
    /// √2 倍に振れる。立体の線は画面に正対させて出す画素で組むので、帯の向きは画面に写した向き
    /// (``screenToward``) で測り、出す画素へ戻して半幅にする。
    ///
    /// [#2172]: https://github.com/mokume-metal/mokume/issues/2172
    /// [#3734]: https://github.com/mokume-metal/mokume/issues/3734
    struct SolidThinBand {
        /// 描く画素での元の太さ (1 未満)。
        var drawn: Float
        /// 描く画素 1 つの、出す画素での長さ。
        var outputPerDrawn: Float

        /// 線に沿って出す長さの半分 (出す画素)。列の境目で切れない端 (点の群の端・曲線の刻みの端・重なる端など。
        /// ``Canvas/solidEndCuts(world:edges:curveSteps:thin:camera:)``) と GPU の骨の丸い端の形は、線の向きには元の
        /// 太さの半分だけ出す (平面の ``thinCarving(_:thin:)`` の切れない端と同じ)。切れる端は ``ThinEndCut`` が延ばす。
        var alongHalf: Float { drawn * outputPerDrawn / 2 }

        /// 画面の向き `toward` (長さ 1) の帯の、出す画素での半幅と被覆。量は ``Canvas/widenedBand(_:along:)`` と同じで、
        /// **式は GPU の頂点段 (`Shapes.metal` の `solidStrokeThinBand`) と同じ順で書く** — 同じ稜が骨に乗るか
        /// CPU の帯へ戻るかで、半幅が 1 ulp 違わないようにする (`drawn × (target / drawn)` は `target` にならない
        /// ことがある・#3734 の反証 #4)。
        func band(along toward: SIMD2<Float>) -> (half: Float, coverage: Float) {
            let axis = max(abs(toward.x), abs(toward.y))
            let crossings: Float = drawn / axis <= 1 ? 1 : 2
            let target = crossings * axis
            return (target * outputPerDrawn * 0.5, drawn / target)
        }
    }

    /// 出す画素での太さ `weight` の立体の線の、帯の広げ方の元 (``SolidThinBand``)。細くなければ `nil`。
    func solidThinBand(weight: Float) -> SolidThinBand? {
        let drawn = drawnSolidWeight(weight)
        guard drawn > 0, drawn < 1, drawn.isFinite else { return nil }
        return SolidThinBand(drawn: drawn, outputPerDrawn: (unitsPerDrawnPixel.x * unitsPerDrawnPixel.y).squareRoot())
    }

    // MARK: - 保持した形

    /// 保持した形の輪郭を、置いた後の太さで組み直した頂点と被覆の区間。**どの片も細くならなければ
    /// `nil`** で、呼ぶ側は記録した頂点をそのまま置く。
    ///
    /// 頂点は記録した頂点と同じ座標 (形自身の座標に記録のときの変換を掛け、半画素寄せの前)
    /// で返すので、呼ぶ側は記録した頂点と同じく置き場所の行列と色を掛けて寄せる。**組み直しは
    /// 置き場所の 2x2 ごとに 1 度だけ** — 同じ大きさ・向きで置き続ける形は、控えた頂点を移すだけで
    /// 済む (``ThinStrokeRecipe``)。回して置き続ける形は、向きごとに組み直す (#2172)。
    func thinVertices(
        _ recipe: ThinStrokeRecipe, placedBy matrix: simd_float4x4, cache: ThinStrokeCache,
        stroke: Int
    ) -> (vertices: [ShapeVertex], coverage: [CoverageSpan])? {
        let combined = matrix * recipe.transform.matrix
        let linear = drawnLinear(combined)
        // 点 1 つの周は描く画素の軸に沿って置くので、回転ごとに形が違う。それ以外は回転に依らない
        // 細い帯は列 (行) が帯を切る長さで広げる (#2172) ので、向きごとに形が違う。点 1 つの周も描く
        // 画素の軸に沿って置く。鍵は 2x2 そのもの — 回して置き続ける形は、向きごとに組み直す
        //
        // **開いた端を持つ輪郭は、副画素の位相も鍵に足す** (#3745 の決定 A。丸い端も #3748 から)。端を描く画素の
        // 列 (行) の境目で切る (``ThinEndCut``) ので、置き場所の平行移動の端数で片が変わる。整数の画素だけずれた
        // 置き場所は同じ片になる。閉じた輪郭は、これまでどおり 2x2 だけで使い回す
        var phase = SIMD2<Float>(0, 0)
        if recipe.cutsEndsAtColumns {
            let origin = drawnOrigin(of: combined)
            phase = origin - origin.rounded(.down)
        }
        let key = ThinStrokeCache.Key(
            linear: SIMD4(linear.columns.0.x, linear.columns.0.y, linear.columns.1.x, linear.columns.1.y),
            phase: phase)
        if let cached = cache.built(stroke, key) { return cached }
        let built = buildThinVertices(recipe, placedBy: combined)
        cache.remember(built, stroke, key)
        return built
    }

    /// 描く画素へ写す 2x2 のうち、**回転 (と鏡映) に依らない部分** `DᵀD`。額縁の片で組める矩形の畳みの鍵に
    /// する (``ThinFold/widensInVertexStage``・#3733)。
    ///
    /// **#2172 からは、`DᵀD` が同じでも片は同じにならない** — 細い帯は列 (行) が帯を切る長さで広げるので、
    /// 回すと広げ方が変わる。回転だけが違う置き場所に 1 つの雛形を使い回せるのは、頂点段で置き場所ごとに
    /// 広げ直す矩形だけである。保持した形の控えとほかの形の畳みの鍵は 2x2 そのもの
    /// (``thinVertices(_:placedBy:cache:stroke:)``・``thinStrokeLinear(form:)``)。
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
            coarse(RuntimeMath.log2(trace)), coarse(gram.columns.0.x / trace), coarse(gram.columns.1.x / trace),
            coarse(gram.columns.1.y / trace))
    }

    private func buildThinVertices(
        _ recipe: ThinStrokeRecipe, placedBy combined: simd_float4x4
    ) -> (vertices: [ShapeVertex], coverage: [CoverageSpan])? {
        thinStrokesRebuilt += 1
        // 周は、置いた後の大きさで刻み直す (#1645)。円板は描く画素の空間で組む
        // (``thinCarving(_:thin:)``) ので、この分割数は使わない
        let outline = recipe.outline(atScale: Self.splitScale(of: combined))
        // 置いた頂点は置くときに半画素寄せる (``Canvas/place(_:of:at:)``) ので、描く画素の絶対座標が決まる
        guard let thin = thinOutline(outline, weight: recipe.weight, placedBy: combined, snapped: true)
        else { return nil }
        let saved = (style.strokeCap, style.strokeJoin)
        style.strokeCap = thin.isPoint ? .square : recipe.cap
        style.strokeJoin = recipe.join
        // 細い片は描く画素の空間で組み、円板の分割数は使わない (0)
        let carved = carveRecipe(
            outline, half: recipe.weight / 2, thin: thin, transform: recipe.transform,
            color: recipe.color, uv: recipe.uv, discSegments: 0)
        (style.strokeCap, style.strokeJoin) = saved
        // 1 つの領域として引けない輪郭は、引かずに積む。置く側が型板の区間に入れて 1 回だけ混ぜる
        // (段 5 の直に描く細い線と同じ・#3580・``Canvas/place(_:of:at:carved:)``)
        return carved.built(stacked: !outline.strokesAsOneRegion)
    }
}

/// 保持した形の輪郭を、**置いた後の太さで細ければ**広げて組み直す素材 ([#1637] 完了条件 5)。
///
/// 描く画素での太さは、置き場所の行列が決まるまで分からない。記録した形を縮めて置けば
/// 細くなるので、記録のときには判断できない。記録した頂点はそのまま持ち、置くたびに
/// ``Canvas/thinVertices(_:placedBy:cache:stroke:)`` で細さを測って、細ければ組み直した頂点で
/// 区間を差し替える。細くならない置き方 (いちばんよくある) は費用を払わない — 形の中で最も細い
/// 線でも細くならなければ区間を走査しない (``Shape/thinnestRecordedWeight``)。組み直した頂点は
/// 形が控える (``ThinStrokeCache``) ので、同じ大きさ・向きで置き続ける形は組み直さない。
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

    /// 置いた後に細くなれば、開いた端を描く画素の列 (行) の境目で切る輪郭か (``ThinEndCut``・#3745)。開いた周の
    /// もので、端の形は問わない (丸い端も切る・#3748)。組み直した片が置き場所の副画素の位相で変わる。
    var cutsEndsAtColumns: Bool {
        !outline.isClosed && !outline.isDashPiece && outline.points.count >= 2
    }

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
/// 写す 2x2 ごとに持つ (#2172 までは回転を除いた鍵だった。細い帯の広げ方が向きで変わるので、回転も含める)。
///
/// 輪郭ごとに箱を持たないのは、記録のたびに輪郭の数だけ箱を作る費用を払わないためである
/// (細くならない形にも払わせることになる)。参照の箱にしてあるのは、形 (値型) を写しても控えを
/// 共有するため。控えるのは輪郭ごとに数件まで — 置き場所ごとに大きさの違う形は鍵が増え続ける
/// ので、上限を越えたらその輪郭の控えを捨てて控え直す。
final class ThinStrokeCache {
    typealias Built = (vertices: [ShapeVertex], coverage: [Canvas.CoverageSpan])
    /// 輪郭 (``Shape/strokeRanges`` の番号) ごとの控え。`nil` を控えた鍵は「細くならない」。
    private var entries: [Int: [Key: Built?]] = [:]
    static let capacity = 8

    /// 組み直した輪郭の控えの鍵。描く画素へ写す 2x2 と、開いた端を列の境目で切る輪郭だけが持つ副画素の位相
    /// (``ThinStrokeRecipe/cutsEndsAtColumns``・#3745。ほかの輪郭は 0)。
    struct Key: Hashable {
        var linear: SIMD4<Float>
        var phase: SIMD2<Float>
    }

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

    func built(_ stroke: Int, _ key: Key) -> Built?? {
        guard let table = entries[stroke] else { return nil }
        return table[key]
    }

    func remember(_ value: Built?, _ stroke: Int, _ key: Key) {
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

/// 細い線の開いた端を、**描く画素の列 (行) の境目で切る**形 ([#3745])。
///
/// 細い帯は、列 (行) が帯を切る長さを整数 n にして広げる (``Canvas/widenedBand(_:along:)``・#2172) ので、端から
/// 離れた列はどれも画素の中心をちょうど n 個拾う。端を線に垂直に切ると、斜めの帯では端の列が帯を切る区間が欠け、
/// その列が拾う中心が置く位置 (副画素の位相) で 0 か 1 個に振れる。描く画素で短い線では ±1 個が光の量の ±10% を
/// 越えた (#3745 の 2 つの seed)。
///
/// そこで端を、帯の主軸 (横寄りなら x) の**列の境目**で切る。端点を含む列は 1 列ぶんの平行四辺形 (``piece``) にし、
/// 被覆に「その列の中で線が占める長さの割合」(``fraction``) を掛ける。残りの帯は境目から先だけにする (``trimmed(_:)``)。
/// どの列の片も縁が列ごとに n だけ離れ、切り口の頂点は境目 (整数の座標) に乗るので、頂点を GPU の副画素の精度へ
/// 丸めても列ごとの中心は n 個のままで、光の量は `被覆 × n × 主軸に沿った長さ` = `太さ × 長さ` に一致する。
///
/// `.project` の端は、太さの半分だけ延ばした端点 (``tip``) で同じ切り方をする (端の長方形の片は置かない)。
/// `.round` の端は、丸い端と面積の等しい平らな延長として、太さ × π / 8 だけ延ばした端点で切る
/// ([#3748]・``extent(of:weight:)``)。
///
/// 座標は描く画素の空間で、`base` を足すと描く画素の絶対座標になる (``Canvas/ThinOutline/origin``)。
///
/// [#3745]: https://github.com/mokume-metal/mokume/issues/3745
/// [#3748]: https://github.com/mokume-metal/mokume/issues/3748
nonisolated struct ThinEndCut: Equatable {
    /// 端の形 `cap` の端点を外へ延ばす長さ (描く画素の太さ `weight` で書く)。
    ///
    /// 丸い端は、半円の片 (面積 π × 太さ² / 8) と面積の等しい長さ π × 太さ / 8 の平らな延長にする (#3748 の決定 A)。
    /// 丸い片のまま線に垂直に切ると、片が拾う画素の中心が置く位置で 0〜2 個に振れ、描く画素で短い線では光の量が
    /// ±10% を越えた (`DensityInvarianceTests` の `diagonalRound` の行)。形の差は描く画素の 1 画素の中に収まる。
    static func extent(of cap: StrokeCap, weight: Float) -> Float {
        switch cap {
        case .square: 0
        case .project: weight / 2
        case .round: .pi * weight / 8
        }
    }

    /// 切る軸 (0 = x で列・1 = y で行)。帯の主軸。
    var axis: Int
    /// 線が端から内へ進む向き (長さ 1)。
    var inward: SIMD2<Float>
    /// 延ばした端点 (`.project` は太さの半分・`.round` は太さ × π / 8 だけ外へ)。
    var tip: SIMD2<Float>
    /// 端の列の内側の境目 (``axis`` の成分)。端の列は、ここから外へ 1 の幅である。
    var boundary: Float
    /// 端の列の幅 1 のうち、線が占める割合 (0 より大きく 1 以下)。
    var fraction: Float
    /// 帯の半幅 (描く画素)。
    var half: Float
    /// 端の列の、主軸の絶対座標での下の境目 (整数)。2 つの端が同じ列かを比べる。
    var column: Float

    /// 内へ進む向きの、主軸の成分の符号。
    var sign: Float { inward[axis] < 0 ? -1 : 1 }

    /// 端 `end` から隣の点 `far` へ向かう帯の端の切り方。決まらない (長さ 0・数でない値) と `nil`。
    ///
    /// - Parameters:
    ///   - extend: 端点を外へ延ばす長さ (``extent(of:weight:)``)
    ///   - half: 帯の半幅 (描く画素)
    ///   - base: 座標に足すと描く画素の絶対座標になるずれ
    ///   - axis: 切る軸を決めて渡す (同じ帯の両端で軸を揃える)。`nil` なら帯の主軸
    init?(
        end: SIMD2<Float>, far: SIMD2<Float>, extend: Float, half: Float, base: SIMD2<Float>,
        axis given: Int? = nil
    ) {
        let delta = far - end
        let length = simd_length(delta)
        guard length > 0, length.isFinite, half > 0, half.isFinite, base.x.isFinite, base.y.isFinite else {
            return nil
        }
        let inward = delta / length
        let axis = given ?? (abs(inward.x) >= abs(inward.y) ? 0 : 1)
        // 主軸の成分が 0 の帯 (渡された軸に直交する) は列で切れない
        guard inward[axis] != 0 else { return nil }
        let sign: Float = inward[axis] < 0 ? -1 : 1
        let tip = end - inward * extend
        // 内へ進む向きを正にした絶対座標 t で、端点を含む列は [⌊t⌋, ⌊t⌋ + 1]、内側の境目は ⌊t⌋ + 1
        let along = sign * (tip[axis] + base[axis])
        guard along.isFinite, abs(along) < 4_194_304 else { return nil }
        let inner = along.rounded(.down) + 1
        self.axis = axis
        self.inward = inward
        self.tip = tip
        boundary = sign * inner - base[axis]
        fraction = inner - along
        self.half = half
        column = sign > 0 ? inner - 1 : -inner
    }

    /// 帯 (向き ``inward``・半幅 ``half``) を ``tip`` から前後へ 4 画素ずつ延ばした長方形。主軸の成分は 1/√2 以上なので、
    /// 端の列の前後 2 列を越えて覆う。
    private var strip: [SIMD2<Float>] {
        let normal = SIMD2(-inward.y, inward.x) * half
        let (a, b) = (tip - inward * 4, tip + inward * 4)
        return [a + normal, b + normal, b - normal, a - normal]
    }

    /// 端の列の片 (帯 ∩ 端の列)。被覆には ``fraction`` を掛ける。
    var piece: [SIMD2<Float>] {
        // 端の列は、内側の境目から外へ 1 の幅
        let outer = Self.clipped(strip, axis: axis, keeping: sign, from: boundary - sign)
        return Self.clipped(outer, axis: axis, keeping: -sign, from: boundary)
    }

    /// 帯の片 `polygon` (凸多角形) から、端の列とその外を除いた残り。
    func trimmed(_ polygon: [SIMD2<Float>]) -> [SIMD2<Float>] {
        Self.clipped(polygon, axis: axis, keeping: sign, from: boundary)
    }

    /// 同じ帯の両端 `start`・`end` が同じ列に入るなら、1 つの片にした切り方 (割合は両端の差)。
    static func merged(_ start: ThinEndCut, _ end: ThinEndCut) -> ThinEndCut? {
        guard start.axis == end.axis, start.column == end.column else { return nil }
        var one = start
        one.fraction = min(max(start.sign * (end.tip[start.axis] - start.tip[start.axis]), 0), 1)
        return one
    }

    /// 2 つの端の列の片が重なるか (囲みの箱で見る。境目で接するだけなら重ならない)。
    func overlaps(_ other: ThinEndCut) -> Bool {
        guard let mine = box, let theirs = other.box else { return false }
        return Self.overlap(mine, theirs)
    }

    /// 端の列の片の囲みの箱。片が空なら `nil`。
    var box: (low: SIMD2<Float>, high: SIMD2<Float>)? {
        let corners = piece
        guard var low = corners.first else { return nil }
        var high = low
        for corner in corners {
            low = simd_min(low, corner)
            high = simd_max(high, corner)
        }
        return (low, high)
    }

    /// 2 つの囲みの箱が重なるか。境目で接するだけ (隔たり 1/1000 画素以内) なら重ならない。
    static func overlap(
        _ one: (low: SIMD2<Float>, high: SIMD2<Float>), _ other: (low: SIMD2<Float>, high: SIMD2<Float>)
    ) -> Bool {
        let shared = simd_min(one.high, other.high) - simd_max(one.low, other.low)
        return shared.x > 1e-3 && shared.y > 1e-3
    }

    /// 端から順に `next` が返す線の点 (端の帯の向こうの点から) が、端の列を出るまで端の帯の向きからそれないか
    /// (#3745 の反証 3)。端の列の中の点と、列の境目を横切る所が、端の帯の中心線から ``straightness`` 以内なら真。
    /// 列を出る前に線が尽きれば偽。
    ///
    /// 端の列の片は端の帯の向きの帯で列を覆い、後の片を消す。列の中で線が曲がると、片が角を越えて境目まで出る。
    /// 一直線を細かく刻んだ線 (曲線のゆるい所) は、端の線分が 1 列より短くても切ってよい。
    func staysStraight(_ next: () -> SIMD2<Float>?) -> Bool {
        let normal = SIMD2(-inward.y, inward.x)
        var last = tip
        while let point = next() {
            let beyond = sign * (point[axis] - boundary)
            if beyond >= 0 {
                let before = sign * (last[axis] - boundary)
                let crossing = before < beyond ? last + (point - last) * (before / (before - beyond)) : point
                return abs(dot(crossing - tip, normal)) <= Self.straightness
            }
            if abs(dot(point - tip, normal)) > Self.straightness { return false }
            last = point
        }
        return false
    }

    /// 端の列の中で線がそれてよい幅 (描く画素)。半径 10 画素の弧は、端の列の中で 0.1 画素ほどそれる。
    static let straightness: Float = 0.125

    /// 凸多角形 `polygon` のうち、`keeping × (p[axis] − bound) ≥ 0` の側を残す。切り口の頂点は ``axis`` の成分を
    /// ちょうど `bound` にする (境目の整数の座標に乗せる)。
    static func clipped(
        _ polygon: [SIMD2<Float>], axis: Int, keeping side: Float, from bound: Float
    ) -> [SIMD2<Float>] {
        guard polygon.count >= 3 else { return [] }
        var kept: [SIMD2<Float>] = []
        kept.reserveCapacity(polygon.count + 2)
        for index in polygon.indices {
            let current = polygon[index]
            let next = polygon[(index + 1) % polygon.count]
            let (here, there) = (side * (current[axis] - bound), side * (next[axis] - bound))
            if here >= 0 { kept.append(current) }
            if (here >= 0) != (there >= 0), here != there {
                var cut = current + (next - current) * (here / (here - there))
                cut[axis] = bound
                kept.append(cut)
            }
        }
        return kept.count >= 3 ? kept : []
    }
}
