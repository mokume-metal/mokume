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
    ///
    /// 乗算していない成分から作った色 (``init(straightRed:green:blue:alpha:)`` と、それを通る
    /// ``display(red:green:blue:alpha:)``・``color(_:_:_:_:)`` など) では **0…1 に締まっている**。
    /// このプロパティと ``init(premultipliedRed:green:blue:alpha:)`` は作業空間の
    /// 「計算のための値」なので締めない — 書き換えた値はそのまま残る。
    public var alpha: Float

    /// アルファを乗算済みの成分から作る (作業空間の内側で使う形)。
    ///
    /// **どの値も締めない。** 渡した不透明度が 0…1 の外でもそのまま持つ。
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
    /// **不透明度は 0…1 に締める。色の成分は締めない。** 成分は範囲の外の明るさとして
    /// 意味を持つ ([ADR-0011] 決定 1) が、不透明度は「どれだけ効かせるか」なので、0 より
    /// 透明にも 1 より不透明にもならない。締めずに掛けると、`alpha: -0.5` は下地を負の値へ
    /// 落とし、`alpha: 1.5` は塗りの色を越える ([ADR-0033] 決定 3 の改訂)。数でない不透明度は
    /// 締めずにそのまま残す (不透明に化けない)。
    ///
    /// [ADR-0011]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0011-color-model.md
    /// [ADR-0033]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0033-color-specification-surface.md
    public init(straightRed red: Float, green: Float, blue: Float, alpha: Float = 1) {
        // **この書き順を保つ。** Swift の `min` / `max` は第 1 引数の NaN を返すので、
        // `max(0, min(1, alpha))` と書くと NaN が 1 (不透明) に化ける
        let alpha = min(max(alpha, 0), 1)
        self.red = red * alpha
        self.green = green * alpha
        self.blue = blue * alpha
        self.alpha = alpha
    }

    /// 利用者が見た目で指定する成分から作る (作業空間へ入る**入口**の境界)。
    ///
    /// 成分は 0…1 の **sRGB のエンコードされた値** — 画面で見える明るさの
    /// 尺度で、線形の光の量ではない。0.5 と書けば「中くらいの灰色」であって、
    /// 光の量が半分という意味ではない。
    ///
    /// **原色は sRGB である** (手本のリファレンスの色見本と同じ)。同じ 3 つの数を持つ
    /// sRGB の画像を読み込んだ色と、同じ作業空間の値になる。書き出した絵は作業空間の
    /// Display P3 を刻むので、彩度のある色のバイト列は書いた数と一致しない
    /// (`(0.8, 0.6, 0)` は `196, 155, 51` として書かれる)。灰色は一致する。
    ///
    /// [ADR-0011] 決定 3 の「入力側は作業空間へ入る時点で作業空間へ移す」を担う。
    /// 線形へ戻し、原色を作業空間へ移したうえでアルファを乗算する。
    ///
    /// **不透明度は 0…1 に締める。色の成分は締めない** — `alpha: 1.5` は 1 と同じ色になり、
    /// `red: 2` は白を越える明るさのまま残る (``init(straightRed:green:blue:alpha:)`` と同じ)。
    ///
    /// [ADR-0011]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0011-color-model.md
    public static func display(
        red: Float, green: Float, blue: Float, alpha: Float = 1
    ) -> LinearRGBA {
        let working = ColorPrimaries.working(
            fromSRGB: SIMD3(
                TransferFunction.decode(red), TransferFunction.decode(green),
                TransferFunction.decode(blue)))
        return LinearRGBA(
            straightRed: working.x, green: working.y, blue: working.z, alpha: alpha)
    }

    /// **線形の値**から作る不透明な色 (アルファ 1)。
    ///
    /// 成分は光の量そのもので、伝達関数を通さない — `0.5` は「光の量が半分」であって、
    /// 画面で見える中くらいの灰色ではない (それは ``display(red:green:blue:alpha:)``)。
    /// **1 を超えられる**ので、光の強さを表すのに使える (`linear(red: 2, green: 2, blue: 2)`
    /// は白の 2 倍の明るさ)。
    ///
    /// 名前が名乗るのは**目盛り**である ([ADR-0033] 決定 2)。同じ `red` という語で
    /// 3 つの目盛りが並ぶので、どれなのかは口の名前だけが区別できる:
    ///
    /// | 口 | `red` の意味 | 原色 |
    /// | --- | --- | --- |
    /// | ``linear(red:green:blue:)`` | 線形の 0–1 (1 を超えてよい) | 作業空間 (Display P3) |
    /// | ``display(red:green:blue:alpha:)`` | エンコード値の 0–1 | sRGB |
    /// | ``color(_:_:_:_:)`` | エンコード値の 0–255 | sRGB |
    ///
    /// この口だけは**作業空間の値そのもの**を受けるので、原色を移さない
    /// ([ADR-0011] 決定 3 の改訂)。sRGB の外にある色はここで書ける。
    ///
    /// アルファが 1 なので、乗算済みと乗算前が一致し変換は起きない。
    ///
    /// [ADR-0011]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0011-color-model.md
    /// [ADR-0033]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0033-color-specification-surface.md
    public static func linear(red: Float, green: Float, blue: Float) -> LinearRGBA {
        LinearRGBA(premultipliedRed: red, green: green, blue: blue, alpha: 1)
    }

    /// 完全に透明な色。
    public static let transparent = LinearRGBA(
        premultipliedRed: 0, green: 0, blue: 0, alpha: 0)

    /// 4 成分を GPU へ渡す並びのまま (乗算済み・線形)。
    var components: SIMD4<Float> { SIMD4(red, green, blue, alpha) }
}
