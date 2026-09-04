// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

/// 作業空間の色。
///
/// 色に対する計算はすべて**線形**の値で行う。色域は extended Display P3 で、
/// その範囲外の値 (負値および 1.0 超) を切り捨てない ([ADR-0011] 決定 1)。
/// ここに入っている値は「表示できる色」ではなく「計算のための値」であり、
/// 表示できる範囲へ収める変換は出力段でしか起きない (同 決定 3)。
///
/// **成分はアルファを乗算済み** (premultiplied)。乗算するのは色が作業空間へ入る
/// 境界の 1 箇所だけで、以降の経路では乗算済みであることを不変条件として扱う
/// ([ADR-0011] 決定 4)。利用者が指定する色は乗算していない (straight) 表現なので、
/// 境界を越えるときは ``init(straightRed:green:blue:alpha:)`` を通す。
///
/// [ADR-0011]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0011-color-model.md
public struct LinearRGBA: Equatable, Sendable {
    /// 赤成分 (線形・アルファ乗算済み)。
    public var red: Float
    /// 緑成分 (線形・アルファ乗算済み)。
    public var green: Float
    /// 青成分 (線形・アルファ乗算済み)。
    public var blue: Float
    /// 不透明度。
    public var alpha: Float

    /// アルファを乗算済みの成分から作る (作業空間の内側で使う形)。
    public init(premultipliedRed red: Float, green: Float, blue: Float, alpha: Float) {
        self.red = red
        self.green = green
        self.blue = blue
        self.alpha = alpha
    }

    /// アルファを乗算していない成分から作る (作業空間へ入る境界で使う形)。
    ///
    /// ここが [ADR-0011] 決定 4 の言う変換点。ここ以外で掛け戻しを書かない。
    ///
    /// [ADR-0011]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0011-color-model.md
    public init(straightRed red: Float, green: Float, blue: Float, alpha: Float = 1) {
        self.red = red * alpha
        self.green = green * alpha
        self.blue = blue * alpha
        self.alpha = alpha
    }

    /// 利用者が見た目で指定する成分から作る (作業空間へ入る**入口**の境界)。
    ///
    /// 成分は 0…1 の**ディスプレイのエンコードされた値** — 画面で見える明るさの
    /// 尺度で、線形の光の量ではない。0.5 と書けば「中くらいの灰色」であって、
    /// 光の量が半分という意味ではない。
    ///
    /// [ADR-0011] 決定 3 の「入力側は作業空間へ入る時点で線形へ変換する」を担う。
    /// 線形へ戻したうえでアルファを乗算する。
    ///
    /// [ADR-0011]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0011-color-model.md
    public static func display(
        red: Float, green: Float, blue: Float, alpha: Float = 1
    ) -> LinearRGBA {
        LinearRGBA(
            straightRed: TransferFunction.decode(red),
            green: TransferFunction.decode(green),
            blue: TransferFunction.decode(blue),
            alpha: alpha)
    }

    /// 不透明な色 (アルファ 1)。乗算済みと乗算前が一致するので変換は起きない。
    public static func opaque(red: Float, green: Float, blue: Float) -> LinearRGBA {
        LinearRGBA(premultipliedRed: red, green: green, blue: blue, alpha: 1)
    }

    /// 完全に透明な色。
    public static let transparent = LinearRGBA(
        premultipliedRed: 0, green: 0, blue: 0, alpha: 0)

    /// 4 成分を GPU へ渡す並びのまま (乗算済み・線形)。
    var components: SIMD4<Float> { SIMD4(red, green, blue, alpha) }
}
