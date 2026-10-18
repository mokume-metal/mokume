// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import simd

/// 平面の基本図形 (矩形・楕円・扇形・線・点) を 1 つ置く。
///
/// **形の寸法まで置き場所が持つ。** 平面の雛形 (``FlatInstance``) は「どこへ・どの色で」
/// しか持たず、形は頂点の並びが持っていた — だから寸法が違う図形は別の雛形になり、
/// 寸法違いの円 4000 個は 4000 回組み立てられていた ([#752])。ここでは形は頂点を
/// 持たず、頂点関数がクアッドの 4 角を置き、断片関数が距離関数で形を出す。寸法違い
/// でも種別違いでも 1 つの列に並ぶ。
///
/// 並びは `Drawing/Shaders/Shapes.metal` の同名の構造体と一致していなければならない
/// (``ShapeVertex`` と同じ理由で、`ShaderInterfaceTests` が反射と突き合わせる)。
///
/// [#752]: https://github.com/mokume-metal/mokume/issues/752
struct FormInstance {
    /// 形自身の座標を描画先の座標へ移す 2x2 (列 2 本を 4 成分に並べて持つ)。
    ///
    /// 線は線の向きの回転を含む — 形自身の座標では線は横に寝ている。**線幅もここで
    /// 拡大縮小される** (``FlatInstance/linear`` と同じ)。
    var linear: SIMD4<Float>
    /// xy: 平行移動 (形の中心)。zw: 扇形の開始角と掃引 (それ以外は 0)。
    var offset: SIMD4<Float>
    /// xy: 半幅・半高 (楕円は半径。線は半分の長さと 0)。z: 線幅の半分 (輪郭が無ければ 0)。
    /// w: 矩形の角の半径 (形自身の座標・半幅と半高の小さいほう以下。角を丸めない矩形と、
    /// 矩形以外は 0・[#2757])。
    ///
    /// [#2757]: https://github.com/mokume-metal/mokume/issues/2757
    var size: SIMD4<Float>
    /// 塗り (乗算済み線形)。塗りが無ければ 0。
    var fill: SIMD4<Float>
    /// 輪郭 (乗算済み線形)。輪郭が無ければ 0。
    var stroke: SIMD4<Float>
    /// x: 種別, y: 端の形, z: 折れ目の形, w: 旗。番号の正本は `Shaders/Kinds.metal`。
    var meta: SIMD4<UInt32>

    /// 形の種別。
    ///
    /// **正本は `Shaders/Kinds.metal`** (`kFormRect` …)。割れたら `KindLayoutTests`
    /// が落ちる ([#802])。
    ///
    /// [#802]: https://github.com/mokume-metal/mokume/issues/802
    enum Kind: UInt32 {
        case rect = 0
        case ellipse = 1
        case arc = 2
        case line = 3
    }

    /// 塗りを持つ。
    static let fillsFlag: UInt32 = 1
    /// 輪郭を持つ。
    static let strokesFlag: UInt32 = 2
    /// 描く画素で 1 画素より細い塗りか、1 画素より細い (潰れた) 輪郭の帯の穴か、近似の距離場では
    /// 輪郭の位置がずれすぎる楕円を含みうる。
    /// **列だけが持つ旗で、置き場所には入れない** (``mayHaveThinFill(unitsPerDrawnPixel:)``・
    /// ``mayHaveThinHole(unitsPerDrawnPixel:)``・``mayNeedExactRing(unitsPerDrawnPixel:)``)。
    ///
    /// 塗り・輪郭の旗と違って、変わっても列を切らない。含む図形が 1 つでもある列は、
    /// 断片の枝を残した組で描く ([#1477])。名前は細い塗りの旗として入ったときのままで、
    /// 帯の細い穴の枝 ([#2186]) と、楕円の輪郭を真の距離で解く枝 ([#2742]) も同じ旗に乗る — 枝は
    /// 図形ごとの判定でさらに分かれるので、片方しか含まない列も絵は変わらない。
    ///
    /// [#1477]: https://github.com/mokume-metal/mokume/issues/1477
    /// [#2186]: https://github.com/mokume-metal/mokume/issues/2186
    /// [#2742]: https://github.com/mokume-metal/mokume/issues/2742
    static let thinFillsFlag: UInt32 = 4

    /// 判定を保守側へ倒す幅 (相対)。
    ///
    /// 断片の境目 (`2 × 半幅 × (1 + 2/256) < 描く画素 1 つ`) と同じ式を CPU で解くが、
    /// 逆行列と長さの丸めは GPU と 1 ビットまでは揃わない (1e-7 ほど)。境目の近くで
    /// 「含まない」と答えると、断片が細い枝に入るはずの形を枝の無い組で描いて絵が変わる
    /// ので、1/1024 だけ「含む」側へ広げる。幅 1 画素の塗りは境目から 0.8% 離れている
    /// ので、広げても「含む」側に入らない。
    private static let thinFillSlack: Float = 1.0 / 1024

    /// この形の塗りが、**描く画素で 1 画素より細い向き**を持ちうるか ([#1477])。
    ///
    /// 断片の `rect` と楕円の塗りの枝 (`Shapes.metal` の `mokume_formPaint`) に入るかを、
    /// 置いた時点の変換 (``linear``) と大きさから CPU で先に判定する。立った列だけが枝を
    /// 残した組で描かれる (`kFormHasThinFill`)。**迷ったら「含む」と答える** — 余計に
    /// 立てても速さを失うだけだが、立て損なうと細い塗りの濃さが置く位置で揺れる形に戻る。
    ///
    /// 扇 (`arc`) の塗りと線・点は枝を持たないので、常に「含まない」。
    ///
    /// - Parameter unitsPerDrawnPixel: 描く画素 1 つが描画先の座標でいくらか
    ///   (細かさ 1 なら 1。`FlatFrame.unitsPerDrawnPixel` と同じ値)。
    ///
    /// [#1477]: https://github.com/mokume-metal/mokume/issues/1477
    func mayHaveThinFill(unitsPerDrawnPixel: SIMD2<Float>) -> Bool {
        guard meta.w & Self.fillsFlag != 0,
            meta.x == Kind.rect.rawValue || meta.x == Kind.ellipse.rawValue
        else { return false }
        return isThin(half: SIMD2(size.x, size.y), unitsPerDrawnPixel: unitsPerDrawnPixel)
    }

    /// 半幅 `half` (形自身の座標) の向きのどちらかが、描く画素で 1 画素より細いか。断片の境目
    /// (`2 × 半幅 × (1 + 2/256) < 描く画素 1 つ`) を、``thinFillSlack`` だけ「細い」側へ広げて解く。
    private func isThin(half: SIMD2<Float>, unitsPerDrawnPixel: SIMD2<Float>) -> Bool {
        // 断片が読む行ノルム (描く画素 1 つが形自身の座標でいくらか) は、逆行列の行に
        // 描く画素の大きさを掛けたものの長さ。逆行列は余因子 / 行列式なので、両辺に
        // 行列式の 2 乗を掛けて、割り算と平方根を使わずに 2 乗どうしで比べる
        let determinant = linear.x * linear.w - linear.y * linear.z
        let rowX = SIMD2(linear.w, -linear.z) * unitsPerDrawnPixel
        let rowY = SIMD2(-linear.y, linear.x) * unitsPerDrawnPixel
        let span = 2 * half * (1 + 2.0 / 256)
        let reach = (1 + Self.thinFillSlack) * (1 + Self.thinFillSlack)
        let squared = determinant * determinant
        return span.x * span.x * squared < simd_length_squared(rowX) * reach
            || span.y * span.y * squared < simd_length_squared(rowY) * reach
    }

    /// この形の輪郭の帯の穴 (内縁の内) が、**描く画素で 1 画素より細いか潰れている**ことがありうるか
    /// ([#2186])。
    ///
    /// 断片の `rect` と楕円の輪郭の、帯の穴を両縁を見る積で数える枝 (`Shapes.metal` の
    /// `mokume_thinHole`) を残した組で描くかを決める。``mayHaveThinFill(unitsPerDrawnPixel:)`` と
    /// 同じく**迷ったら「含む」と答える** — 立て損なうと、潰れた穴を縁 1 本で数えて帯が欠ける。
    /// 穴の大きさは断片と同じ式で出す (`rect` は半幅 − 太さの半分、楕円は ``ellipseHole(radii:halfWeight:)``)。
    /// 潰れた穴 (どちらかの向きが 0 以下) は、描く画素によらず「含む」。
    ///
    /// 扇 (`arc`) と線・点、輪郭の無い形は枝を持たないので、常に「含まない」。
    ///
    /// [#2186]: https://github.com/mokume-metal/mokume/issues/2186
    func mayHaveThinHole(unitsPerDrawnPixel: SIMD2<Float>) -> Bool {
        guard meta.w & Self.strokesFlag != 0,
            meta.x == Kind.rect.rawValue || meta.x == Kind.ellipse.rawValue
        else { return false }
        let half = SIMD2(size.x, size.y)
        let hole = meta.x == Kind.ellipse.rawValue
            ? Self.ellipseHole(radii: half, halfWeight: size.z) : half - size.z
        guard hole.x > 0, hole.y > 0 else { return true }
        return isThin(half: hole, unitsPerDrawnPixel: unitsPerDrawnPixel)
    }

    /// 列の旗 (``thinFillsFlag``) を立てるか: 塗りが細い (``mayHaveThinFill(unitsPerDrawnPixel:)``) か、
    /// 輪郭の帯の穴が細い・潰れている (``mayHaveThinHole(unitsPerDrawnPixel:)``) ことがありうるか。
    ///
    /// **2 つの判定を 1 度の行列式と行ノルムで解く。** 答えは 2 つの論理和と同じ。図形を置くたびに
    /// 走る費用は、release で判定だけが図形 1 つあたり 5.8 ns から 13.4 ns、寸法違いの円 20 万個を
    /// 置く本体が 1 つあたり 51.7 ns から 56.8 ns になった (帯の穴の判定を足す前と比べて・#2186)。
    /// 2 つを順に呼んでも同じ速さだったが、置く口を 1 つにするためにまとめてある。
    func mayHaveThinPart(unitsPerDrawnPixel: SIMD2<Float>) -> Bool {
        guard meta.x == Kind.rect.rawValue || meta.x == Kind.ellipse.rawValue else { return false }
        let fills = meta.w & Self.fillsFlag != 0
        let strokes = meta.w & Self.strokesFlag != 0
        let half = SIMD2(size.x, size.y)
        var hole = SIMD2<Float>(1, 1)
        if strokes {
            hole = meta.x == Kind.ellipse.rawValue
                ? Self.ellipseHole(radii: half, halfWeight: size.z) : half - size.z
            // 潰れた穴は描く画素によらず細い
            if hole.x <= 0 || hole.y <= 0 { return true }
        }
        guard fills || strokes else { return false }
        let determinant = linear.x * linear.w - linear.y * linear.z
        let rowX = simd_length_squared(SIMD2(linear.w, -linear.z) * unitsPerDrawnPixel)
        let rowY = simd_length_squared(SIMD2(-linear.y, linear.x) * unitsPerDrawnPixel)
        let reach = (1 + Self.thinFillSlack) * (1 + Self.thinFillSlack)
        let squared = determinant * determinant
        func thin(_ half: SIMD2<Float>) -> Bool {
            let span = 2 * half * (1 + 2.0 / 256)
            return span.x * span.x * squared < rowX * reach || span.y * span.y * squared < rowY * reach
        }
        if (fills && thin(half)) || (strokes && thin(hole)) { return true }
        // 近似の距離場では輪郭の位置がずれすぎる楕円 (``mayNeedExactRing(unitsPerDrawnPixel:)``)
        return strokes && meta.x == Kind.ellipse.rawValue && size.x != size.y
            && Self.exactRingIsNeeded(
                radii: half, halfWeight: size.z, rowNormsSquared: rowX + rowY,
                determinant: determinant, unitsPerDrawnPixel: unitsPerDrawnPixel)
    }

    /// 楕円の輪郭の内縁・外縁を、近似の距離場ではなく**真の距離**で解く枝に入りうるか ([#2742])。
    ///
    /// 断片の `mokume_needsExactRing` (`Shapes.metal`) と同じ式で、理由もそちらにある。円は距離場が
    /// 真の距離なので「含まない」。立て損なうと近似の距離場の外れた帯が出るので、**迷ったら「含む」と
    /// 答える** (``thinFillSlack`` だけ見積もりを広げる)。
    ///
    /// - Parameter unitsPerDrawnPixel: 描く画素 1 つが描画先の座標でいくらか
    ///   (``mayHaveThinFill(unitsPerDrawnPixel:)`` と同じ)。
    ///
    /// [#2742]: https://github.com/mokume-metal/mokume/issues/2742
    func mayNeedExactRing(unitsPerDrawnPixel: SIMD2<Float>) -> Bool {
        guard meta.w & Self.strokesFlag != 0, meta.x == Kind.ellipse.rawValue, size.x != size.y
        else { return false }
        let determinant = linear.x * linear.w - linear.y * linear.z
        let rowX = simd_length_squared(SIMD2(linear.w, -linear.z) * unitsPerDrawnPixel)
        let rowY = simd_length_squared(SIMD2(-linear.y, linear.x) * unitsPerDrawnPixel)
        return Self.exactRingIsNeeded(
            radii: SIMD2(size.x, size.y), halfWeight: size.z, rowNormsSquared: rowX + rowY,
            determinant: determinant, unitsPerDrawnPixel: unitsPerDrawnPixel)
    }

    /// ``mayNeedExactRing(unitsPerDrawnPixel:)`` の式。
    ///
    /// 断片は「見積もり · σmax(D) > 許容 · |det D|」(D: 描く画素 → 形自身の座標) で比べる。D は
    /// 変換の逆行列に描く画素の大きさを掛けたもので、`D = M / det` と書ける (M は `linear` の余因子に
    /// 描く画素の大きさを掛けた行列で、`rowNormsSquared` はその行の長さの 2 乗和)。`|det M| =
    /// ux · uy · |det|` なので、`det` は両辺で消えて「見積もり · σmax(M) > 許容 · ux · uy」になる。
    private static func exactRingIsNeeded(
        radii: SIMD2<Float>, halfWeight: Float, rowNormsSquared: Float, determinant: Float,
        unitsPerDrawnPixel: SIMD2<Float>
    ) -> Bool {
        let error = Self.exactRingError(radii: radii, halfWeight: halfWeight)
        let area = unitsPerDrawnPixel.x * unitsPerDrawnPixel.y
        let detM = abs(determinant) * area
        // 大きい特異値: √((F² + √(F⁴ − 4·det²)) / 2)。F² は全成分の 2 乗和
        let largest = (0.5 * (rowNormsSquared
            + (max(rowNormsSquared * rowNormsSquared - 4 * detM * detM, 0)).squareRoot())).squareRoot()
        let slack = 1 + 4 * thinFillSlack
        return error * largest * slack > exactRingTolerance * area
    }

    /// 近似の距離場が楕円の輪郭の内縁・外縁に落とす位置のずれの見積もり (形自身の座標)。断片の
    /// `mokume_needsExactRing` と同じ式で、係数の根拠もそちらにある。
    static func exactRingError(radii: SIMD2<Float>, halfWeight: Float) -> Float {
        let longRadius = max(radii.x, radii.y)
        let shortRadius = max(min(radii.x, radii.y), 1e-30)
        return 0.35 * halfWeight * halfWeight * (longRadius - shortRadius) / (shortRadius * shortRadius)
    }

    /// 楕円の輪郭の内縁・外縁の位置のずれを許す大きさ (描く画素に対する比)。断片の
    /// `kFormExactTolerance` と同じ値。
    private static let exactRingTolerance: Float = 1.0 / 200

    /// 楕円の輪郭の帯の穴の、短い向きの半幅と長い向きの端までの長さ (`radii` と同じ並び)。
    /// 断片の `mokume_ellipseHole` (`Shapes.metal`) と同じ式で、理由もそちらにある。
    static func ellipseHole(radii: SIMD2<Float>, halfWeight: Float) -> SIMD2<Float> {
        let shortRadius = min(radii.x, radii.y)
        let longRadius = max(radii.x, radii.y)
        let shortHole = shortRadius - halfWeight
        let longHole: Float
        if halfWeight * longRadius <= shortRadius * shortRadius {
            longHole = longRadius - halfWeight
        } else {
            let ratio = halfWeight / max(shortRadius, 1e-30)
            longHole = (max(longRadius * longRadius - shortRadius * shortRadius, 0)).squareRoot()
                * (max(1 - ratio * ratio, 0)).squareRoot()
        }
        return radii.x <= radii.y ? SIMD2(shortHole, longHole) : SIMD2(longHole, shortHole)
    }

    /// 置き場所を 1 つ組む。**色は「持つか」を旗で渡し、`Optional` にしない。**
    ///
    /// `LinearRGBA?` を受け取る形だと、図形 1 つあたり 67 ns かかっていた (10 万個で
    /// 6.7 ms・実測)。`Float` に余った表現が無いので `Optional<LinearRGBA>` は別の
    /// 印を抱えることになり、渡すたびに印の読み書きが挟まる — 中身は 16 バイトの
    /// 数の並びなのに、束ねる側と解く側の両方が値の型を跨ぐ ([#771])。
    ///
    /// 旗は塗り・輪郭の有無をそのまま表すので、呼ぶ側が既に持っている真偽値が
    /// そのまま入る (`hasFill` / `hasStroke`)。
    ///
    /// [#771]: https://github.com/mokume-metal/mokume/issues/771
    init(
        kind: Kind, linear: SIMD4<Float>, offset: SIMD2<Float>, half: SIMD2<Float>,
        arc: SIMD2<Float> = .zero, halfWeight: Float, cornerRadius: Float = 0,
        fill: SIMD4<Float>, stroke: SIMD4<Float>, fills: Bool, strokes: Bool,
        cap: StrokeCap, join: StrokeJoin
    ) {
        self.linear = linear
        self.offset = SIMD4(offset.x, offset.y, arc.x, arc.y)
        self.size = SIMD4(half.x, half.y, strokes ? halfWeight : 0, cornerRadius)
        self.fill = fills ? fill : .zero
        self.stroke = strokes ? stroke : .zero
        self.meta = SIMD4(
            kind.rawValue, Self.code(of: cap), Self.code(of: join),
            (fills ? Self.fillsFlag : 0) | (strokes ? Self.strokesFlag : 0))
    }

    /// 端の形の番号。正本は `Shaders/Kinds.metal` の `kFormCap*`。
    static func code(of cap: StrokeCap) -> UInt32 {
        switch cap {
        case .round: 0
        case .square: 1
        case .project: 2
        }
    }

    /// 折れ目の形の番号。正本は `Shaders/Kinds.metal` の `kFormJoin*`。
    static func code(of join: StrokeJoin) -> UInt32 {
        switch join {
        case .miter: 0
        case .bevel: 1
        case .round: 2
        }
    }

    /// 置き場所の変換を**もう 1 段**掛けたもの。保持した形を置くときに使う。
    ///
    /// 頂点を CPU で移す代わりに 2x2 と平行移動を合成するだけなので、置く費用は形の
    /// 大きさによらない。`tint` は塗りと輪郭の両方に掛かる (置き場所の色は掛かる —
    /// ``Canvas/shape(_:at:)``)。
    func placed(by matrix: simd_float4x4, tint: LinearRGBA?) -> FormInstance {
        let columns = matrix.columns
        let c0 = SIMD2(columns.0.x, columns.0.y)
        let c1 = SIMD2(columns.1.x, columns.1.y)
        let x = c0 * linear.x + c1 * linear.y
        let y = c0 * linear.z + c1 * linear.w
        let moved = matrix * SIMD4<Float>(offset.x, offset.y, 0, 1)
        var result = self
        result.linear = SIMD4(x.x, x.y, y.x, y.y)
        result.offset = SIMD4(moved.x, moved.y, offset.z, offset.w)
        if let tint {
            let scale = SIMD4<Float>(tint.red, tint.green, tint.blue, tint.alpha)
            result.fill = fill * scale
            result.stroke = stroke * scale
        }
        return result
    }

    /// 2x2 が潰れていないか (潰れた形は面積を持たず、三角形のときも何も出なかった)。
    var isPlaceable: Bool {
        let determinant = linear.x * linear.w - linear.y * linear.z
        return determinant.isFinite && determinant != 0
            && offset.x.isFinite && offset.y.isFinite
    }
}
