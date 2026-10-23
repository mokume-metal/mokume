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
    /// w: 矩形の角の半径 (形自身の座標・半幅と半高の小さいほう以下。角を丸めない矩形は 0・[#2757])。
    /// **扇だけは、同じ欄が閉じ方 (``ArcClosure``) の番号を持つ** (扇は角の半径を持たない・[#2428])。
    /// 楕円と線は 0。
    ///
    /// [#2757]: https://github.com/mokume-metal/mokume/issues/2757
    /// [#2428]: https://github.com/mokume-metal/mokume/issues/2428
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

    /// 扇 (``Kind/arc``) の閉じ方 ([#2428])。置き場所の ``size`` の w が持つ。**列を切る旗 (`meta.w`) には
    /// 入れない** ので、閉じ方違いも、寸法違いや種別違いと同じ 1 列に並ぶ。
    ///
    /// 番号の正本は `Shaders/Kinds.metal` の `kArc*` (`KindLayoutTests` が突き合わせる)。0 は、この欄が
    /// 角の半径でなかった頃から扇の置き場所が持っていた値で、塗りも輪郭も扇である。
    ///
    /// | 閉じ方 | 塗り | 輪郭 |
    /// | --- | --- | --- |
    /// | `pie` | 扇 | 扇の周 (中心への 2 本の半径と弧) |
    /// | `standard` | 扇 | 開いた弧の帯 (引数に閉じ方を渡さない `arc` の既定) |
    /// | `chord` | 弧の両端を弦で結んだ形 | 弦で結んだ形の周 |
    /// | `open` | 弧の両端を弦で結んだ形 | 開いた弧の帯 |
    ///
    /// [#2428]: https://github.com/mokume-metal/mokume/issues/2428
    enum ArcClosure: UInt32 {
        case pie = 0
        case standard = 1
        case chord = 2
        case open = 3

        /// 塗りが、弧の両端を弦で結んだ形か (そうでなければ扇)。
        var fillsChord: Bool { self == .chord || self == .open }
        /// 輪郭が、閉じない弧の帯か (そうでなければ、扇か弦で結んだ形の周の帯)。
        var strokesOpenArc: Bool { self == .standard || self == .open }
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

    /// 縁が画素の軸に斜めになりうる形を含む列の旗 ([#2991])。**列の旗** (``thinFillsFlag`` と同じく、
    /// 変わっても列を切らない)。
    ///
    /// 立っていれば、断片に「縁の被覆を半平面と画素の正方形の重なりの面積で数える」枝を残した組
    /// (`kFormHasObliqueEdge`) で描く。立っていない列は、その枝を原稿から外す — 軸に沿った `rect`・線だけの
    /// 列 (面を覆う塗りなど) の費用を、枝が在るだけで増やさないため。**迷ったら「含む」と答える**
    /// (``mayHaveObliqueEdge(unitsPerDrawnPixel:)``)。
    ///
    /// [#2991]: https://github.com/mokume-metal/mokume/issues/2991
    static let obliqueEdgesFlag: UInt32 = 8

    /// 基本図形の縁の分類 ([#2991])。**境目 (細い枝との境の測り方) と被覆 (縁 1 本を線形の渡しか面積で数えるか)
    /// の両方が、この 1 つの表を読む。** 正本は `Shaders/Kinds.metal` の `mokume_formEdgeClass` ほか (同じ表)。
    /// `KindLayoutTests` が GPU 自身にその関数を評価させ、CPU のこの表と突き合わせる。
    ///
    /// | 分類 | 形 | 境目 (塗り・線の太さ) | 被覆 (軸に沿う / 回した) |
    /// | --- | --- | --- | --- |
    /// | `straight` | 角を丸めない `rect`・四角い端の線・四角い点 | 直線 (法線向きの幅) | 線形 / 面積 |
    /// | `curved` | 楕円・扇 | 曲線 (行ノルム) | 面積 / 面積 |
    /// | `rounded` | 角の半径 > 0 の `rect` | 曲線 (円と同じ) | 角だけ面積 / 面積 |
    /// | `joined` | 折れ目が round・bevel の輪郭の `rect` | 直線 | 折れ目の領域だけ面積 / 面積 |
    /// | `roundLine` | 丸い端の線 | 点から線へつなぐ | 線形 / 辺は面積・端は線形 |
    /// | `point` | 丸い端で長さ 0 (`point()`) | 曲線 | 線形 / 線形 (**回転によらず常に**) |
    ///
    /// 帯の穴の境目は、楕円・扇の穴と、内縁に丸い角が残る `rect` (角の半径が太さの半分より大きい) の穴だけ
    /// 曲線 (``holeReachIsCurved``)。
    ///
    /// [#2991]: https://github.com/mokume-metal/mokume/issues/2991
    enum EdgeClass: UInt32 {
        case straight = 0
        case curved = 1
        case rounded = 2
        case joined = 3
        case roundLine = 4
        case point = 5
    }

    /// 縁の被覆の数え方。番号の正本は `Shaders/Kinds.metal` の `kCoverage*`。
    enum CoverageMode: UInt32 {
        /// 縁 1 本ごとに、半平面と画素の正方形の重なりの面積。
        case area = 0
        /// 従来の線形の渡し (縁の法線に幅 1)。
        case linear = 1
        /// 辺は線形の渡しで、曲がった部分 (角丸の角・丸い折れ目・削ぎ) の領域だけ面積。軸に沿う `rect` だけ。
        case linearExceptCorners = 2
        /// 辺は面積で、丸い端の領域だけ線形の渡し。回した丸い端の線だけ。
        case linearExceptCaps = 3
    }

    /// この形の縁の分類。`Kinds.metal` の `mokume_formEdgeClass` と同じ式。
    var edgeClass: EdgeClass {
        let kind = meta.x
        if kind == Kind.ellipse.rawValue || kind == Kind.arc.rawValue { return .curved }
        if kind == Kind.line.rawValue {
            if meta.y != Self.code(of: StrokeCap.round) { return .straight }
            return size.x > 0 ? .roundLine : .point
        }
        if size.w > 0 { return .rounded }
        let join = meta.z
        if meta.w & Self.strokesFlag != 0,
            join == Self.code(of: StrokeJoin.round) || join == Self.code(of: StrokeJoin.bevel)
        {
            return .joined
        }
        return .straight
    }

    /// 扇の閉じ方 (``ArcClosure``)。扇でない形は `.pie` を返す (読まない)。
    var arcClosure: ArcClosure {
        meta.x == Kind.arc.rawValue ? ArcClosure(rawValue: UInt32(max(size.w, 0))) ?? .pie : .pie
    }

    /// 細い枝の境目を測る幅の、行ノルムの割合 (0: 画素の法線向きの幅・1: 行ノルム)。塗りと線の太さの境目が読む。
    /// `Kinds.metal` の `mokume_formReachCurved` と同じ式。丸い端の線は、半分の長さが太さの半分の 1/4 までは
    /// 丸い点から直線の線へつなぐ (点と長さ 1e-3 の線の間で境目が跳ばない。辺が画素ほど長い線は和で測る)。
    var reachCurved: Float {
        switch edgeClass {
        case .curved, .rounded, .point: return 1
        case .roundLine: return 1 - min(max(size.x / max(0.25 * size.z, 1e-30), 0), 1)
        case .straight, .joined: return 0
        }
    }

    /// 輪郭の帯の穴の境目を、行ノルムで測るか。`Kinds.metal` の `mokume_formHoleCurved` と同じ式。
    var holeReachIsCurved: Bool {
        let edgeClass = edgeClass
        return edgeClass == .curved || (edgeClass == .rounded && size.w > size.z)
    }

    /// 縁の被覆の数え方。`aligned` は、形の軸が描く画素の軸に沿うか。`Kinds.metal` の
    /// `mokume_formCoverageMode` と同じ式。**点は回転によらず常に線形** (`point()` の例外)。
    func coverageMode(aligned: Bool) -> CoverageMode {
        let edgeClass = edgeClass
        if edgeClass == .point { return .linear }
        if aligned {
            switch edgeClass {
            case .curved: return .area
            case .rounded, .joined: return .linearExceptCorners
            default: return .linear
            }
        }
        return edgeClass == .roundLine ? .linearExceptCaps : .area
    }

    /// 形の軸が、描く画素の軸に沿っているか。断片の `mokume_rowsAlignToPixels` (逆行列の各行の小さいほうの
    /// 成分が、大きいほうの 1e-5 倍以下) と同じ式を、境目の半分 (0.5e-5) で解く — CPU と GPU の丸めの違いで、
    /// 断片が斜めと読む形を見落とさないため (CPU が「沿う」と答えれば GPU も沿うと読む)。見落としても、
    /// 断片は従来の式に戻るだけで、1e-5 の傾きの縁は絵に見えない。逆行列の行は余因子 / 行列式で、行列式は
    /// 行ごとに共通なので比べるときに要らない。
    func isAxisAligned(unitsPerDrawnPixel: SIMD2<Float>) -> Bool {
        let firstRow = SIMD2(abs(linear.w) * unitsPerDrawnPixel.x, abs(linear.z) * unitsPerDrawnPixel.y)
        let secondRow = SIMD2(abs(linear.y) * unitsPerDrawnPixel.x, abs(linear.x) * unitsPerDrawnPixel.y)
        let tolerance: Float = 0.5e-5
        func aligned(_ row: SIMD2<Float>) -> Bool { min(row.x, row.y) <= tolerance * max(row.x, row.y) }
        return aligned(firstRow) && aligned(secondRow)
    }

    /// この形が、**画素の軸に斜めの縁**を持ちうるか ([#2991])。断片の縁の被覆の枝
    /// (`mokume_formCoverage` の面積) を残した組で描くかを決める。**縁の分類の表** (``EdgeClass``) の被覆の
    /// 数え方が、線形の渡しだけでなければ「含む」。
    ///
    /// - 楕円・扇は、軸に沿っていても常に「含む」。軸に沿う `rect` も、曲がった部分 (角丸・丸い折れ目・削ぎ)
    ///   があれば「含む」
    /// - 直線の縁だけの形 (`rect`・線) は、形の軸が画素の軸に沿っていれば「含まない」
    /// - **点は回転によらず「含まない」** (線形の渡しのまま)。軸に沿う丸い端の線も「含まない」。回した丸い端の線は
    ///   辺が面積になるので「含む」
    ///
    /// 迷ったら「含む」と答える (``isAxisAligned(unitsPerDrawnPixel:)`` は GPU より狭く沿うと読む)。
    ///
    /// [#2991]: https://github.com/mokume-metal/mokume/issues/2991
    func mayHaveObliqueEdge(unitsPerDrawnPixel: SIMD2<Float>) -> Bool {
        coverageMode(aligned: isAxisAligned(unitsPerDrawnPixel: unitsPerDrawnPixel)) != .linear
    }

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
        return isThin(
            half: SIMD2(size.x, size.y), unitsPerDrawnPixel: unitsPerDrawnPixel, curved: reachCurved)
    }

    /// 半幅 `half` (形自身の座標) の向きのどちらかが、描く画素で 1 画素より細いか。断片の境目
    /// (`2 × 半幅 × (1 + 2/256) < 描く画素 1 つの幅`) を、``thinFillSlack`` だけ「細い」側へ広げて解く。
    ///
    /// **幅は縁の形で分ける** (#2991・``EdgeClass``・断片の `mokume_reachPerPixel`): `curved` が 0 なら直線の縁の
    /// 幅 (画素の正方形を形自身の軸へ射影した法線向きの幅・逆行列の行の絶対値の和・45° で行ノルムの √2 倍)、
    /// 1 なら曲線の縁の幅 (向きによらない行ノルム)、その間は両者をつなぐ (丸い端の線)。
    private func isThin(
        half: SIMD2<Float>, unitsPerDrawnPixel: SIMD2<Float>, axes: ThinAxes = .both, curved: Float
    ) -> Bool {
        let determinant = linear.x * linear.w - linear.y * linear.z
        let rowX = simd_length_squared(SIMD2(linear.w, -linear.z) * unitsPerDrawnPixel)
        let rowY = simd_length_squared(SIMD2(-linear.y, linear.x) * unitsPerDrawnPixel)
        let (reachX, reachY) = reachTimesDeterminant(unitsPerDrawnPixel)
        return Self.isThinSpan(
            2 * half * (1 + 2.0 / 256), axes: axes, curved: curved, determinant: determinant,
            rowNormsSquared: SIMD2(rowX, rowY), sums: SIMD2(reachX, reachY))
    }

    /// ``isThin(half:unitsPerDrawnPixel:axes:curved:)`` の比べ。`span` は半幅の 2 倍 (遊びを込めたもの)、
    /// `rowNormsSquared` は逆行列の行に描く画素の大きさを掛けたものの長さの 2 乗 (行列式の 2 乗を掛けた形)、
    /// `sums` は法線向きの幅に行列式の絶対値を掛けたもの。
    private static func isThinSpan(
        _ span: SIMD2<Float>, axes: ThinAxes, curved: Float, determinant: Float,
        rowNormsSquared: SIMD2<Float>, sums: SIMD2<Float>
    ) -> Bool {
        let slack = 1 + thinFillSlack
        if curved >= 1 {
            // 断片が読む行ノルム (描く画素 1 つが形自身の座標でいくらか) は、逆行列の行に
            // 描く画素の大きさを掛けたものの長さ。逆行列は余因子 / 行列式なので、両辺に
            // 行列式の 2 乗を掛けて、割り算と平方根を使わずに 2 乗どうしで比べる
            let squared = determinant * determinant
            let thinX = axes == .both && span.x * span.x * squared < rowNormsSquared.x * slack * slack
            return thinX || span.y * span.y * squared < rowNormsSquared.y * slack * slack
        }
        let absDeterminant = abs(determinant)
        if curved <= 0 {
            // 直線の縁が読むのは、描く画素 1 つの**法線向きの幅** (逆行列の各行の絶対値の和)。逆行列は余因子 /
            // 行列式なので、両辺に行列式の絶対値を掛けて、割り算を使わずに比べる
            let thinX = axes == .both && span.x * absDeterminant < sums.x * slack
            return thinX || span.y * absDeterminant < sums.y * slack
        }
        // つなぐ幅 (丸い端の線): 法線向きの幅と行ノルムの割合 `curved` の混ぜ。和は行ノルム以上なので、
        // 軸に沿う形 (断片は行ノルムを返す) では含む側に倒れる
        let reachX = (1 - curved) * sums.x + curved * rowNormsSquared.x.squareRoot()
        let reachY = (1 - curved) * sums.y + curved * rowNormsSquared.y.squareRoot()
        let thinX = axes == .both && span.x * absDeterminant < reachX * slack
        return thinX || span.y * absDeterminant < reachY * slack
    }

    /// 描く画素 1 つの法線向きの幅 (逆行列の行の絶対値の和・断片の `mokume_reachPerPixel` の直線の縁の式) に、
    /// 行列式の絶対値を掛けたもの。形自身の x の向きと y の向き。**行の軸が画素の軸に沿うときは、
    /// 断片は行ノルムで測り、それは和と一致する (和は行ノルム以上) ので、ここは常に含む側に倒れる。**
    private func reachTimesDeterminant(_ unitsPerDrawnPixel: SIMD2<Float>) -> (Float, Float) {
        (
            abs(linear.w) * unitsPerDrawnPixel.x + abs(linear.z) * unitsPerDrawnPixel.y,
            abs(linear.y) * unitsPerDrawnPixel.x + abs(linear.x) * unitsPerDrawnPixel.y
        )
    }

    /// ``isThin(half:unitsPerDrawnPixel:axes:)`` が見る向き。線の枝は太さの向き (y) だけを見る。
    private enum ThinAxes { case both, y }

    /// この形の輪郭の帯の穴 (内縁の内) が、**描く画素で 1 画素より細いか潰れている**ことがありうるか
    /// ([#2186])。
    ///
    /// 断片の `rect` と楕円の輪郭の、帯の穴を両縁を見る積で数える枝 (`Shapes.metal` の
    /// `mokume_thinHole`) を残した組で描くかを決める。``mayHaveThinFill(unitsPerDrawnPixel:)`` と
    /// 同じく**迷ったら「含む」と答える** — 立て損なうと、潰れた穴を縁 1 本で数えて帯が欠ける。
    /// 穴の大きさは断片と同じ式で出す (`rect` は半幅 − 太さの半分、楕円は ``ellipseHole(radii:halfWeight:)``)。
    /// 潰れた穴 (どちらかの向きが 0 以下) は、描く画素によらず「含む」。
    ///
    /// 扇 (`arc`) の穴は、内接円の半径の上限 (``sectorDepthBound(radii:sweep:)``) から太さの半分を引いた
    /// 1 つの半径で測る ([#2747])。弦で結んだ形の周は弓形の内接円で測る (``chordDepthLower(radii:sweep:)``)。
    /// **開いた弧の帯は穴を持たない**ので「含まない」(帯の細さは ``mayHaveThinPart(unitsPerDrawnPixel:)`` が見る)。
    /// 線・点、輪郭の無い形は枝を持たないので、常に「含まない」。
    ///
    /// [#2186]: https://github.com/mokume-metal/mokume/issues/2186
    /// [#2747]: https://github.com/mokume-metal/mokume/issues/2747
    func mayHaveThinHole(unitsPerDrawnPixel: SIMD2<Float>) -> Bool {
        guard meta.w & Self.strokesFlag != 0,
            meta.x == Kind.rect.rawValue || meta.x == Kind.ellipse.rawValue
                || (meta.x == Kind.arc.rawValue && !arcClosure.strokesOpenArc)
        else { return false }
        let hole = holeHalfSize()
        guard hole.x > 0, hole.y > 0 else { return true }
        return isThin(
            half: hole, unitsPerDrawnPixel: unitsPerDrawnPixel, curved: holeReachIsCurved ? 1 : 0)
    }

    /// 列の旗 (``thinFillsFlag``) を立てるか: 塗りが細い (``mayHaveThinFill(unitsPerDrawnPixel:)``) か、
    /// 輪郭の帯の穴が細い・潰れている (``mayHaveThinHole(unitsPerDrawnPixel:)``) ことがありうるか。
    ///
    /// 輪郭の楕円 (扇) が近似の距離場では位置がずれすぎるか (``mayNeedExactRing(unitsPerDrawnPixel:)``・
    /// #2742) も、同じ口で解く。答えは **3 つの論理和と同じ**。
    ///
    /// **1 度の行列式と、縁の形で分けた幅 (直線の縁は行の絶対値の和・曲線の縁は行ノルム・#2991) で解く。**
    /// 図形を置くたびに走る費用は、release で判定だけが図形 1 つ
    /// あたり 5.8 ns から 13.4 ns、寸法違いの円 20 万個を置く本体が 1 つあたり 51.7 ns から 56.8 ns
    /// になった (帯の穴の判定を足す前と比べて・#2186)。3 つ目の判定 (#2742) は、release で図形 1 つ
    /// あたり、円が 4.7 ns から 5.6 ns、矩形が 3.3 ns から 4.0 ns、非円の楕円 (長さ 100〜200・厚み 0.6 倍・
    /// 太さ 2) が 4.2 ns から 16.6 ns になる (20 万個ずつ・9 回の中央値)。非円の楕円は見積もりの割り算と
    /// 特異値の上下の端の比べを解くぶん増える。特異値の端を平方根を使わずに 2 乗で比べて、決まらないときだけ
    /// 特異値を解く形にして、19.8 ns から縮めた。
    ///
    /// 扇 (#2747) は、以前は常に偽で費用が無視できたが、中心の角の判定 (``mayNeedApexSampling()``) が三角関数を
    /// 解くので、図形 1 つあたり、円の扇 21.7 ns・楕円の扇 30.6 ns になった (release・20 万個ずつ・9 回の中央値)。
    func mayHaveThinPart(unitsPerDrawnPixel: SIMD2<Float>) -> Bool {
        // 線と点 (#2226): 太さが描く画素で 1 画素より細いか。断片の線の枝の境目
        // (`2 × 太さの半分 × (1 + 2/256) < 描く画素 1 つの太さの向きの長さ`) と同じ式で、
        // 太さの向き (形自身の y) だけを見る
        if meta.x == Kind.line.rawValue {
            guard meta.w & Self.strokesFlag != 0 else { return false }
            return isThin(
                half: SIMD2(0, size.z), unitsPerDrawnPixel: unitsPerDrawnPixel, axes: .y, curved: reachCurved)
        }
        let isArc = meta.x == Kind.arc.rawValue
        guard meta.x == Kind.rect.rawValue || meta.x == Kind.ellipse.rawValue || isArc else { return false }
        // 扇の塗りは細い枝を持たない
        let fills = meta.w & Self.fillsFlag != 0 && !isArc
        let strokes = meta.w & Self.strokesFlag != 0
        let half = SIMD2(size.x, size.y)
        // 開いた弧の帯は閉じた周が無いので穴を持たない ([#2428])。帯そのものが描く画素で 1 画素より細いかを
        // 見る (線の細い枝と同じ。断片は画素ごとに、距離場の勾配の向きの幅で決める)
        let hasHole = strokes && !(isArc && arcClosure.strokesOpenArc)
        var hole = SIMD2<Float>(1, 1)
        if strokes && !hasHole { if mayHaveThinBand(unitsPerDrawnPixel: unitsPerDrawnPixel) { return true } }
        if hasHole {
            hole = holeHalfSize()
            // 潰れた穴は描く画素によらず細い
            if hole.x <= 0 || hole.y <= 0 { return true }
        }
        guard fills || strokes else { return false }
        let determinant = linear.x * linear.w - linear.y * linear.z
        let rowX = simd_length_squared(SIMD2(linear.w, -linear.z) * unitsPerDrawnPixel)
        let rowY = simd_length_squared(SIMD2(-linear.y, linear.x) * unitsPerDrawnPixel)
        // 細い枝の境目は、縁の形で分けた幅 (#2991・``EdgeClass``): 塗りは ``reachCurved``、穴は
        // ``holeReachIsCurved`` で、行の絶対値の和と行ノルムのどちらで測るかを決める
        let (reachX, reachY) = reachTimesDeterminant(unitsPerDrawnPixel)
        let fillCurved = reachCurved
        let holeCurved: Float = holeReachIsCurved ? 1 : 0
        func thin(_ half: SIMD2<Float>, curved: Float) -> Bool {
            Self.isThinSpan(
                2 * half * (1 + 2.0 / 256), axes: .both, curved: curved, determinant: determinant,
                rowNormsSquared: SIMD2(rowX, rowY), sums: SIMD2(reachX, reachY))
        }
        if (fills && thin(half, curved: fillCurved)) || (hasHole && thin(hole, curved: holeCurved)) { return true }
        if isArc, mayNeedApexSampling() { return true }
        // 近似の距離場では輪郭の位置がずれすぎる楕円 (``mayNeedExactRing(unitsPerDrawnPixel:)``)
        return strokes && (meta.x == Kind.ellipse.rawValue || isArc) && size.x != size.y
            && Self.exactRingIsNeeded(
                radii: half, halfWeight: size.z, rowNormsSquared: rowX + rowY,
                determinant: determinant, unitsPerDrawnPixel: unitsPerDrawnPixel)
    }

    /// 開いた弧の帯 (``ArcClosure/strokesOpenArc``) が、描く画素で 1 画素より細いことがありうるか ([#2428])。
    ///
    /// 断片の `mokume_arcBandField` は、帯の太さ (`2 × 太さの半分 × (1 + 2/256)`) を、**画素ごとに**、その画素で
    /// 帯の縁が向く法線の方向の画素の幅 (距離場の勾配を画面へ写した長さ) と比べる。その幅は「描く画素 →
    /// 形自身の座標」の行列の最大の特異値以下なので、ここは全成分の 2 乗和の平方根 (それ以上の上界) と比べて、
    /// 迷ったら「含む」と答える。
    ///
    /// [#2428]: https://github.com/mokume-metal/mokume/issues/2428
    func mayHaveThinBand(unitsPerDrawnPixel: SIMD2<Float>) -> Bool {
        guard meta.w & Self.strokesFlag != 0, size.z > 0 else { return false }
        let determinant = linear.x * linear.w - linear.y * linear.z
        let rowX = simd_length_squared(SIMD2(linear.w, -linear.z) * unitsPerDrawnPixel)
        let rowY = simd_length_squared(SIMD2(-linear.y, linear.x) * unitsPerDrawnPixel)
        let span = SIMD2(repeating: 2 * size.z * (1 + 2.0 / 256))
        return Self.isThinSpan(
            span, axes: .both, curved: 1, determinant: determinant,
            rowNormsSquared: SIMD2(repeating: rowX + rowY), sums: .zero)
    }

    /// 輪郭の帯の穴の、形自身の座標での半幅・半径 (種別ごと。潰れていれば 0 以下)。`rect` は半幅 − 太さの
    /// 半分、楕円は ``ellipseHole(radii:halfWeight:)``、扇は内接円の半径の上限から太さの半分を引いた 1 つの
    /// 半径 (``sectorDepthBound(radii:sweep:)``・#2747)。断片の頂点関数と同じ式。
    private func holeHalfSize() -> SIMD2<Float> {
        let half = SIMD2(size.x, size.y)
        switch meta.x {
        case Kind.ellipse.rawValue:
            return Self.ellipseHole(radii: half, halfWeight: size.z)
        case Kind.arc.rawValue:
            // 内接円の半径の下限から太さの半分を引いた半径を、画素の ``sectorHoleReach`` 個分で測る
            // (`mokume_thinHole` は半幅が画素の半分より小さいかを見るので、2 · ``sectorHoleReach`` で割る)
            let lower = arcClosure == .chord
                ? Self.chordDepthLower(radii: half, sweep: offset.w)
                : Self.sectorDepthLower(radii: half, sweep: offset.w)
            return SIMD2(repeating: (lower - size.z) / (2 * Self.sectorHoleReach))
        default:
            return half - size.z
        }
    }

    /// 扇の穴の半径が、描く画素のいくつ分より小さければ「細い」か。断片の `kFormSectorHoleReach`。
    static let sectorHoleReach: Float = 3

    /// 扇の中で、輪郭から最も深い所の深さの下限 (形自身の座標)。断片の `mokume_sectorDepthLower` と同じ式。
    static func sectorDepthLower(radii: SIMD2<Float>, sweep: Float) -> Float {
        let halfSine = RuntimeMath.sin(0.5 * min(sweep, Float.pi))
        return min(radii.x, radii.y) * halfSine / (1 + halfSine)
    }

    /// 扇の中心の角が作る穴の尖りが、尖っているか (掃引が π 未満で角の半分の正弦が 0.5 未満)。断片の
    /// `mokume_sectorApex` と同じ式で、理由もそちらにある。
    static func sectorApexIsSharp(radii: SIMD2<Float>, start: Float, sweep: Float) -> Bool {
        guard sweep < Float.pi else { return false }
        let direction1 = simd_normalize(radii * SIMD2(RuntimeMath.cos(start), RuntimeMath.sin(start)))
        let direction2 = simd_normalize(radii * SIMD2(RuntimeMath.cos(start + sweep), RuntimeMath.sin(start + sweep)))
        let bisector = simd_normalize(direction1 + direction2)
        let sineHalf = abs(direction1.x * bisector.y - direction1.y * bisector.x)
        return sineHalf < 0.5
    }

    /// 弦で結んだ形の 2 つの角 (弧と弦が出会う弧の両端) のどちらかが尖っているか (角が 60° 未満)。断片の
    /// `mokume_chordApex` と同じ式。弓形が薄い (掃引が小さい) ほど鋭い。
    static func chordApexIsSharp(radii: SIMD2<Float>, start: Float, sweep: Float) -> Bool {
        let end1 = radii * SIMD2(RuntimeMath.cos(start), RuntimeMath.sin(start))
        let end2 = radii * SIMD2(RuntimeMath.cos(start + sweep), RuntimeMath.sin(start + sweep))
        func sharp(end: SIMD2<Float>, other: SIMD2<Float>, tangent: SIMD2<Float>) -> Bool {
            let along = tangent * (1 / max(simd_dot(tangent, tangent), 1e-30).squareRoot())
            let chord = other - end
            let across = chord * (1 / max(simd_dot(chord, chord), 1e-30).squareRoot())
            let sum = along + across
            let sumLength = simd_length(sum)
            guard sumLength >= 1e-4 else { return false }
            let bisector = sum / sumLength
            return abs(along.x * bisector.y - along.y * bisector.x) < 0.5
        }
        let tangent1 = radii * SIMD2(-RuntimeMath.sin(start), RuntimeMath.cos(start))
        let tangent2 = radii * SIMD2(-RuntimeMath.sin(start + sweep), RuntimeMath.cos(start + sweep))
        return sharp(end: end1, other: end2, tangent: tangent1)
            || sharp(end: end2, other: end1, tangent: -tangent2)
    }

    /// 穴は細くなくても、中心の角が尖った扇か ([#2747])。尖りの先の画素を標本で数える枝に入る。弦で結んだ形の周は
    /// 弧の両端の 2 つの角のどちらかが尖っているか (``chordApexIsSharp(radii:start:sweep:)``)。輪郭の無い
    /// 扇、開いた弧の帯 (角が無い)、扇でない形は「含まない」。
    ///
    /// [#2747]: https://github.com/mokume-metal/mokume/issues/2747
    func mayNeedApexSampling() -> Bool {
        guard meta.w & Self.strokesFlag != 0, meta.x == Kind.arc.rawValue else { return false }
        let radii = SIMD2(size.x, size.y)
        switch arcClosure {
        case .pie: return Self.sectorApexIsSharp(radii: radii, start: offset.z, sweep: offset.w)
        case .chord: return Self.chordApexIsSharp(radii: radii, start: offset.z, sweep: offset.w)
        case .standard, .open: return false
        }
    }

    /// 弦で結んだ形の中で、輪郭から最も深い所の深さの下限 (形自身の座標)。断片の `mokume_chordDepthLower` と
    /// 同じ式 — 媒介変数の空間では単位円の弓形で、内接円の半径は `(1 − cos(掃引 / 2)) / 2` (大きい弓形でも成り立つ)。
    static func chordDepthLower(radii: SIMD2<Float>, sweep: Float) -> Float {
        min(radii.x, radii.y) * 0.5 * (1 - RuntimeMath.cos(0.5 * sweep))
    }

    /// 扇の中で、輪郭から最も深い所の深さ (扇に内接する円の半径) の上限 (形自身の座標)。断片の
    /// `mokume_sectorDepthBound` (`Shapes.metal`) と同じ式で、理由もそちらにある。
    static func sectorDepthBound(radii: SIMD2<Float>, sweep: Float) -> Float {
        let longRadius = max(radii.x, radii.y)
        let shortRadius = min(radii.x, radii.y)
        let halfSine = RuntimeMath.sin(0.5 * min(sweep, Float.pi))
        return min(shortRadius, longRadius * halfSine / (1 + halfSine))
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
        guard meta.w & Self.strokesFlag != 0,
            meta.x == Kind.ellipse.rawValue || meta.x == Kind.arc.rawValue, size.x != size.y
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
        let slack = 1 + 4 * thinFillSlack
        // 大きい特異値 σ は √(F² / 2) ≤ σ ≤ √F² (F² は全成分の 2 乗和) に収まるので、平方根を使わずに
        // 2 乗どうしで比べて、どちらの端でも決まるときは答える。決まらない間だけ特異値を解く
        let lhs = error * error * slack * slack
        let rhs = exactRingTolerance * exactRingTolerance * area * area
        if lhs * 0.5 * rowNormsSquared > rhs { return true }
        if lhs * rowNormsSquared <= rhs { return false }
        let detM = abs(determinant) * area
        // 大きい特異値: √((F² + √(F⁴ − 4·det²)) / 2)
        let largest = (0.5 * (rowNormsSquared
            + (max(rowNormsSquared * rowNormsSquared - 4 * detM * detM, 0)).squareRoot())).squareRoot()
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
        arc: SIMD2<Float> = .zero, arcClosure: ArcClosure = .pie, halfWeight: Float,
        cornerRadius: Float = 0, fill: SIMD4<Float>, stroke: SIMD4<Float>, fills: Bool, strokes: Bool,
        cap: StrokeCap, join: StrokeJoin
    ) {
        self.linear = linear
        self.offset = SIMD4(offset.x, offset.y, arc.x, arc.y)
        // 扇は角の半径の欄に閉じ方を持つ (``size``)
        self.size = SIMD4(
            half.x, half.y, strokes ? halfWeight : 0,
            kind == .arc ? Float(arcClosure.rawValue) : cornerRadius)
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
