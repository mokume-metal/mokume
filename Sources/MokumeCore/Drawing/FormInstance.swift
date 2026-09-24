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
    /// xy: 半幅・半高 (楕円は半径。線は半分の長さと 0)。z: 線幅の半分 (輪郭が無ければ 0)。w: 0。
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
    /// 描く画素で 1 画素より細い塗りを含みうる。**列だけが持つ旗で、置き場所には入れない**
    /// (``mayHaveThinFill(unitsPerDrawnPixel:)``)。
    ///
    /// 塗り・輪郭の旗と違って、変わっても列を切らない。含む図形が 1 つでもある列は、
    /// 断片の枝を残した組で描く ([#1477])。
    ///
    /// [#1477]: https://github.com/mokume-metal/mokume/issues/1477
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
        // 断片が読む行ノルム (描く画素 1 つが形自身の座標でいくらか) は、逆行列の行に
        // 描く画素の大きさを掛けたものの長さ。逆行列は余因子 / 行列式なので、両辺に
        // 行列式の 2 乗を掛けて、割り算と平方根を使わずに 2 乗どうしで比べる
        let determinant = linear.x * linear.w - linear.y * linear.z
        let rowX = SIMD2(linear.w, -linear.z) * unitsPerDrawnPixel
        let rowY = SIMD2(-linear.y, linear.x) * unitsPerDrawnPixel
        let span = 2 * SIMD2(size.x, size.y) * (1 + 2.0 / 256)
        let reach = (1 + Self.thinFillSlack) * (1 + Self.thinFillSlack)
        let squared = determinant * determinant
        return span.x * span.x * squared < simd_length_squared(rowX) * reach
            || span.y * span.y * squared < simd_length_squared(rowY) * reach
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
        arc: SIMD2<Float> = .zero, halfWeight: Float,
        fill: SIMD4<Float>, stroke: SIMD4<Float>, fills: Bool, strokes: Bool,
        cap: StrokeCap, join: StrokeJoin
    ) {
        self.linear = linear
        self.offset = SIMD4(offset.x, offset.y, arc.x, arc.y)
        self.size = SIMD4(half.x, half.y, strokes ? halfWeight : 0, 0)
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
