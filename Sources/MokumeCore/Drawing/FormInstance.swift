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
/// (``ShapeVertex`` と同じ理由で、大きさを ``expectedStride`` として持つ)。
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
    /// x: 種別, y: 端の形, z: 折れ目の形, w: 旗。番号はシェーダ側の定数と対応する。
    var meta: SIMD4<UInt32>

    /// シェーダ側の構造体と一致すべき大きさ (バイト)。
    static let expectedStride = 96

    /// 形の種別。シェーダ側の `kForm*` と同じ番号。
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

    init(
        kind: Kind, linear: SIMD4<Float>, offset: SIMD2<Float>, half: SIMD2<Float>,
        arc: SIMD2<Float> = .zero, halfWeight: Float,
        fill: LinearRGBA?, stroke: LinearRGBA?, cap: StrokeCap, join: StrokeJoin
    ) {
        self.linear = linear
        self.offset = SIMD4(offset.x, offset.y, arc.x, arc.y)
        self.size = SIMD4(half.x, half.y, stroke == nil ? 0 : halfWeight, 0)
        self.fill = fill.map { SIMD4($0.red, $0.green, $0.blue, $0.alpha) } ?? .zero
        self.stroke = stroke.map { SIMD4($0.red, $0.green, $0.blue, $0.alpha) } ?? .zero
        self.meta = SIMD4(
            kind.rawValue, Self.code(of: cap), Self.code(of: join),
            (fill == nil ? 0 : Self.fillsFlag) | (stroke == nil ? 0 : Self.strokesFlag))
    }

    /// 端の形の番号。シェーダ側の `kFormCap*` と同じ。
    static func code(of cap: StrokeCap) -> UInt32 {
        switch cap {
        case .round: 0
        case .square: 1
        case .project: 2
        }
    }

    /// 折れ目の形の番号。シェーダ側の `kFormJoin*` と同じ。
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
