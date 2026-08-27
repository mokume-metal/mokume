// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation

/// 作業空間の絵を、外へ出せる形へ変換する段。
///
/// [ADR-0011] 決定 3 の言う「境界」の出口側そのもの。**線形からディスプレイの
/// エンコードへの変換はここでしか起きない** — 途中の段でエンコードとデコードを
/// 往復させないための一点である。
///
/// 変換は 4 手で、順序に意味がある:
///
/// 1. **アルファを戻す** — 作業空間では乗算済みで運んでいる ([ADR-0011] 決定 4)。
///    外へ出す形は乗算していない表現なので、ここで割り戻す。色そのものを得てから
///    でないと、次のトーンマップが「暗い半透明」と「暗い色」を区別できない
/// 2. **標準レンジへ収める** ([ADR-0011] 決定 5 の既定)
/// 3. **ディスプレイのエンコードを掛ける** (sRGB の伝達関数)
/// 4. **チャンネルあたり 8 bit へ量子化する** ([ADR-0011] 決定 6 の量子化点)
///
/// [ADR-0011]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0011-color-model.md
public enum OutputStage {
    /// 作業空間の画素を、表示できる形へ変換する。
    public static func encode(_ pixels: PixelBuffer) -> DisplayImage {
        var bytes = [UInt8](repeating: 0, count: pixels.width * pixels.height * 4)
        for y in 0..<pixels.height {
            for x in 0..<pixels.width {
                let color = pixels[x, y]
                let alpha = clampToStandardRange(color.alpha)
                let base = (y * pixels.width + x) * 4
                bytes[base] = quantize(encodeForDisplay(straighten(color.red, alpha: alpha)))
                bytes[base + 1] = quantize(encodeForDisplay(straighten(color.green, alpha: alpha)))
                bytes[base + 2] = quantize(encodeForDisplay(straighten(color.blue, alpha: alpha)))
                // 不透明度は光の量ではないので、伝達関数を掛けずにそのまま量子化する
                bytes[base + 3] = quantize(alpha)
            }
        }
        return DisplayImage(width: pixels.width, height: pixels.height, bytes: bytes)
    }

    // MARK: - 4 手

    /// アルファの乗算を戻す (手 1)。
    ///
    /// 完全に透明な画素には戻すべき色が無いので 0 を返す。
    static func straighten(_ premultiplied: Float, alpha: Float) -> Float {
        alpha > 0 ? premultiplied / alpha : 0
    }

    /// 標準レンジへ収める (手 2)。
    ///
    /// **0…1 の内側の値は変えない。** 曲線で圧縮すると、`0.5` を指定して描いた絵が
    /// 指定と違う明るさで出ることになり、指定した色がそのまま出るという前提が崩れる。
    /// 範囲の外側だけを端に寄せる。
    ///
    /// 表示能力に応じて範囲の外側まで出すのは、[ADR-0011] 決定 5 のとおり
    /// スケッチ側が明示的に選んだときだけ — その経路はまだ無い。
    ///
    /// [ADR-0011]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0011-color-model.md
    static func clampToStandardRange(_ value: Float) -> Float {
        // NaN は比較がすべて false になるので min/max では落ちない。明示的に 0 へ倒す
        guard !value.isNaN else { return 0 }
        return min(max(value, 0), 1)
    }

    /// ディスプレイのエンコードを掛ける (手 3)。
    ///
    /// 色域は [ADR-0011] 決定 1 のとおり Display P3 のままで、変えるのは伝達関数だけ
    /// (P3 は sRGB と同じ伝達関数を使う)。変換そのものは ``TransferFunction`` が持つ —
    /// 入口の境界と対で置き、片方だけ直して食い違うことを防ぐため。
    ///
    /// [ADR-0011]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0011-color-model.md
    static func encodeForDisplay(_ linear: Float) -> Float {
        TransferFunction.encode(clampToStandardRange(linear))
    }

    /// チャンネルあたり 8 bit へ量子化する (手 4)。
    static func quantize(_ encoded: Float) -> UInt8 {
        UInt8((clampToStandardRange(encoded) * 255).rounded())
    }
}
