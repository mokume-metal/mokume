// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation
import simd

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
/// 2. **明るさを画面へ写す** — 露出を掛け、範囲を超えた分を丸める
///    ([ADR-0011] 決定 5 の既定は標準レンジへの収まり)
/// 3. **ディスプレイのエンコードを掛ける** (sRGB の伝達関数)
/// 4. **チャンネルあたり 8 bit へ量子化する** ([ADR-0011] 決定 6 の量子化点)
///
/// ## 戻す道も同じ場所に置く
///
/// 4 手の逆 — **出した形の絵を作業空間へ戻す**道も、この型が持つ。外から届いた映像を
/// 毎フレーム絵にするのがそれである (``Image/write(_:)`` が呼ぶ)。離して置かないのは、
/// 片方だけ直すと出した絵を書き戻したときに色が動くからで、伝達関数が変換の対を
/// 離さないのと同じ理由による。
///
/// [ADR-0011]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0011-color-model.md
public enum OutputStage {
    /// 作業空間の画素を、表示できる形へ変換する。
    ///
    /// 明るさを写す段の設定は**画面が持つ**ので、画面を経由しないこの入口では
    /// 既定 — 何も変えない設定 — が使われる。
    public static func encode(_ pixels: PixelBuffer) -> DisplayImage {
        encode(pixels, brightness: .default)
    }

    /// 作業空間の画素を、指定した明るさで表示できる形へ変換する。
    static func encode(_ pixels: PixelBuffer, brightness: Brightness) -> DisplayImage {
        var bytes = [UInt8](repeating: 0, count: pixels.width * pixels.height * 4)
        for y in 0..<pixels.height {
            for x in 0..<pixels.width {
                let color = pixels[x, y]
                let alpha = clampToStandardRange(color.alpha)
                let mapped = brightness.map(
                    SIMD3(
                        straighten(color.red, alpha: alpha),
                        straighten(color.green, alpha: alpha),
                        straighten(color.blue, alpha: alpha)))
                let base = (y * pixels.width + x) * 4
                bytes[base] = quantize(encodeForDisplay(mapped.x))
                bytes[base + 1] = quantize(encodeForDisplay(mapped.y))
                bytes[base + 2] = quantize(encodeForDisplay(mapped.z))
                // 不透明度は光の量ではないので、伝達関数を掛けずにそのまま量子化する
                bytes[base + 3] = quantize(alpha)
            }
        }
        return DisplayImage(width: pixels.width, height: pixels.height, bytes: bytes)
    }

    // MARK: - 戻す

    /// 表示できる形の絵を、作業空間の画素へ戻す。
    ///
    /// ``encode(_:)`` の逆で、3 手 — 量子化を戻す・伝達関数で線形へ・アルファを
    /// 乗算する。明るさを写す手はここには無い (外から届いた絵に露出は掛かっていない)。
    ///
    /// **逆を出口と対で置く**のは、``TransferFunction`` が変換の対を離さないのと
    /// 同じ理由である — 片方だけ直すと、出した絵を書き戻したときに色が動く。
    ///
    /// 書き先を渡す形にしてあるのは、**毎フレーム呼ばれる道だから**である
    /// ([#487](https://github.com/mokume-metal/mokume/issues/487))。返り値にすると
    /// 1920×1080 で 8 MB の確保がフレームごとに起きる。
    ///
    /// - Precondition: `pixels` の要素数が絵の画素数と一致していること。
    static func decode(_ picture: DisplayImage, into pixels: inout [SIMD4<Float16>]) {
        precondition(pixels.count == picture.width * picture.height)
        picture.bytes.withUnsafeBufferPointer { source in
            pixels.withUnsafeMutableBufferPointer { destination in
                decodeLinear.withUnsafeBufferPointer { linear in
                    for index in destination.indices {
                        let base = index * 4
                        let alpha = Float(source[base + 3]) / 255
                        // **不透明なら乗算を飛ばす。** 映像はほとんどが不透明で、
                        // 掛け算 3 回とアルファの読みがそのぶん丸ごと消える
                        if alpha >= 1 {
                            destination[index] = SIMD4(
                                Float16(linear[Int(source[base])]),
                                Float16(linear[Int(source[base + 1])]),
                                Float16(linear[Int(source[base + 2])]), 1)
                        } else {
                            destination[index] = SIMD4(
                                Float16(linear[Int(source[base])] * alpha),
                                Float16(linear[Int(source[base + 1])] * alpha),
                                Float16(linear[Int(source[base + 2])] * alpha),
                                Float16(alpha))
                        }
                    }
                }
            }
        }
    }

    /// 量子化された値から線形へ戻す表 (256 段)。
    ///
    /// **画素ごとに `pow()` を呼ばないための表である。** 1920×1080 なら色成分は
    /// 622 万個あり、そこへ伝達関数を素直に掛けると変換だけで 1 フレームの予算を
    /// 使い切る。段は 256 しか無いので、全部を先に引いておける。
    private static let decodeLinear: [Float] = (0...255).map {
        TransferFunction.decode(Float($0) / 255)
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
