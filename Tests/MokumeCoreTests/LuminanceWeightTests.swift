// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Testing

@testable import MokumeCore

/// 明るさの重み。**GPU を要さない。**
///
/// 重みは掛ける相手の原色で決まる。作業空間も書き出しも Display P3 なので、重みは P3 の
/// 相対輝度の行でなければならない ([#1212])。効果の側 (シェーダ) の写しは
/// `EffectTests` が画素で見る。
///
/// [#1212]: https://github.com/mokume-metal/mokume/issues/1212
@Suite("明るさの重み")
struct LuminanceWeightTests {
    /// 重みと入口の行列が、同じ原色から導かれている。sRGB の原色を作業空間へ移してから
    /// P3 の重みを掛けると、sRGB の原色の相対輝度 (Rec.709 の重み) に戻る。
    @Test(
        "sRGB の原色を作業空間へ移して P3 の重みを掛けると、Rec.709 の重みに戻る",
        arguments: [
            (SIMD3<Float>(1, 0, 0), 0.2126),
            (SIMD3<Float>(0, 1, 0), 0.7152),
            (SIMD3<Float>(0, 0, 1), 0.0722),
        ])
    func weightsAgreeWithThePrimaries(primary: SIMD3<Float>, luminance: Double) {
        let working = SIMD3<Double>(ColorPrimaries.working(fromSRGB: primary))
        let y = (working * ColorPrimaries.luminanceWeights).sum()
        // Rec.709 の重みは 4 桁に丸めた公称値なので、その丸めぶんを許す
        #expect(abs(y - luminance) < 1e-4, "\(y)")
    }

    /// 観測の明るさは、Display P3 の値に P3 の重みを掛ける。純色の絵なら重みそのものが出る。
    @Test(
        "純色の絵の明るさの平均は、その原色の P3 の重みになる",
        arguments: [
            ([UInt8(255), 0, 0], 0.228_975),
            ([UInt8(0), 255, 0], 0.691_739),
            ([UInt8(0), 0, 255], 0.079_287),
        ])
    func meanLuminanceUsesDisplayP3Weights(pixel: [UInt8], weight: Double) {
        let bytes = [UInt8]((0..<4).flatMap { _ in pixel + [255] })
        let stats = FrameStats.summarize(DisplayImage(width: 2, height: 2, bytes: bytes))
        #expect(abs(stats.meanLuminance - weight) < 1e-6, "\(stats.meanLuminance)")
    }
}
