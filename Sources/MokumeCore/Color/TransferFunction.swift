// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation

/// 線形の値とディスプレイのエンコードとの間の変換。
///
/// [ADR-0011] 決定 3 は「線形で計算し、境界で変換する」とし、境界は**入口と出口の
/// 2 箇所しかない**と言う。この型はその 2 箇所が使う変換の対を、対のまま持つ。
/// 片方だけ直して食い違うことが起きないよう、離して置かない。
///
/// [ADR-0011]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0011-color-model.md
enum TransferFunction {
    /// 直線の区間と曲線の区間の境目 (線形側)。
    static let linearThreshold: Float = 0.003_130_8
    /// 直線の区間の傾き。
    static let linearSlope: Float = 12.92
    /// 曲線の区間の指数。
    static let exponent: Float = 2.4
    /// 曲線の区間の倍率。
    static let scale: Float = 1.055
    /// 曲線の区間のずらし。
    static let offset: Float = 0.055

    /// 線形 → ディスプレイのエンコード (出口の境界)。
    static func encode(_ linear: Float) -> Float {
        if linear <= linearThreshold {
            return linearSlope * linear
        }
        return scale * pow(linear, 1 / exponent) - offset
    }

    /// ディスプレイのエンコード → 線形 (入口の境界)。
    ///
    /// **有限の値は有限の値へ移す** ([#1691])。曲線の区間は 2.4 乗なので、灰色でおよそ
    /// `color(3.05e18)` 以上では `Float` の最大を越えて +inf になる。それが原色の行列の
    /// 0 の係数と掛かると NaN になり、面へ移す関所 (``HalfSurface``) の手前で色が数でなく
    /// なる。越えた分は `Float` の最大で止める — 行列は行の係数の和が 1 以下なので、
    /// 止めた値は行列を通っても有限に残る。数でない値はそのまま通す (`min` は NaN を返す)。
    ///
    /// [#1691]: https://github.com/mokume-metal/mokume/issues/1691
    static func decode(_ encoded: Float) -> Float {
        if encoded <= linearSlope * linearThreshold {
            return encoded / linearSlope
        }
        return min(pow((encoded + offset) / scale, exponent), .greatestFiniteMagnitude)
    }
}
