// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Metal

/// 色を半精度 (`rgba16Float`) の面へ移す関所。**GPU の断片の出力を通らずに面へ色を置く所は、
/// すべてここを通る** — 塗り直しの clear 色 (`RenderTarget.makeRenderPass`) と、CPU で半精度へ
/// 変える書き込み (``Pixels`` の添字と `fill`・``Image`` の `set` と `fill`)・ファイルから読んだ絵
/// (`ImageFile.decode`)。
///
/// ## 上限と、非有限の扱い
///
/// **有限の成分は ±65504 (半精度の最大) で止め、NaN と ±inf はそのまま通す。** 図形・線・字・
/// 絵など面の大半を書く経路は、GPU が断片の出力を面の形式へ変える所で既にこう扱っており
/// (変えられない)、ここはその少ない側を揃える。clear 色と `Float16(_:)` の変換は最寄りの目盛りへ
/// 丸めるので、そのままだと 65520 以上 (負は -65520 以下) が ±inf になる。下地が ±inf だと、その上に
/// 乗算済みの `.blend` で描いた不透明な図形が inf × 0 で NaN になり、黒く抜けた。測った値の表は
/// [#1691] の本文にある (Apple M3 Max)。
///
/// **読み込みの口だけは、ここへ着く前に半精度になる。** CoreGraphics が絵を半精度の文脈へ描く
/// 時点で、65520 以上の成分が ±inf に化ける ([#1873] の実測。32 ビット浮動小数の TIFF・OpenEXR)。
/// 受け取った直後に通しても元の値が残っていないので、`ImageFile.decode` は非有限が出たときだけ
/// 32 ビット浮動小数の文脈で描き直し、**非有限だった成分をここへ通して**半精度へ移す。元から
/// ±inf・NaN の成分は、描き直しても非有限のままここを通り抜ける (他の経路と同じ)。
///
/// **止めるのは面へ移す所だけで、色の値そのものは締めない。** `LinearRGBA` の成分・塗りの状態・
/// `color()` の値は範囲の外の明るさのまま残る ([ADR-0011] 決定 1・[ADR-0033] 決定 6)。
///
/// **数でない値を数に化けさせない。** 分けるのは `isFinite` で、`min` / `max` の書き順に頼らない —
/// Swift の `min` / `max` は第 1 引数の NaN を返すので、書き順によっては NaN が 65504 に化ける。
///
/// [#1691]: https://github.com/mokume-metal/mokume/issues/1691
/// [#1873]: https://github.com/mokume-metal/mokume/issues/1873
/// [ADR-0011]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0011-color-model.md
/// [ADR-0033]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0033-color-specification-surface.md
enum HalfSurface {
    /// 面が表せる有限の最大 (65504)。
    nonisolated static let largestFinite = Float(Float16.greatestFiniteMagnitude)

    /// 面へ移す成分。有限なら ±``largestFinite`` で止め、非有限はそのまま返す。
    nonisolated static func component(_ value: Float) -> Float {
        guard value.isFinite else { return value }
        return min(max(value, -largestFinite), largestFinite)
    }

    /// CPU で面へ書く 1 画素。
    static func texel(_ color: LinearRGBA) -> SIMD4<Float16> {
        SIMD4(
            Float16(component(color.red)), Float16(component(color.green)),
            Float16(component(color.blue)), Float16(component(color.alpha)))
    }

    /// 塗り直す色 (パスの clear 色)。
    static func clearColor(_ color: LinearRGBA) -> MTLClearColor {
        MTLClearColor(
            red: Double(component(color.red)), green: Double(component(color.green)),
            blue: Double(component(color.blue)), alpha: Double(component(color.alpha)))
    }
}
