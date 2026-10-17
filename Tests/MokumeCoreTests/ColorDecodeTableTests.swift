// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Testing

@testable import MokumeCore

/// 入口の sRGB → 線形が、整数の入力を表で引いても**値を変えないこと** ([#2377])。
///
/// ``LinearRGBA/display(red:green:blue:alpha:)`` は、成分が `Float(k) / 255` (k は 0…255) と
/// ビット単位で等しいときだけ ``OutputStage/decodeLinear`` で引く。速くするための経路なので、
/// 返す値は引かなかったときとビットまで同じでなければならない。比べるのはすべて**ビット**
/// である — `==` は `-0` と `0` を同じとするが、`-0` は表を通さない約束で、その差は
/// 原色の行列を通っても残る。
///
/// 変更前の式 (``reference(_:_:_:_:)``) を検査の中に残して照合する。表を使う分岐が壊れても、
/// 参照のほうは常に `pow` を通るので、食い違いが出る。
///
/// GPU は要らない — 作業空間へ入る手前の純粋な計算である。
///
/// [#2377]: https://github.com/mokume-metal/mokume/issues/2377
@Suite("入口の変換の表引き")
struct ColorDecodeTableTests {
    /// 変更前の ``LinearRGBA/display(red:green:blue:alpha:)``。常に `decode` を通す。
    private func reference(_ red: Float, _ green: Float, _ blue: Float, _ alpha: Float = 1)
        -> LinearRGBA
    {
        let working = ColorPrimaries.working(
            fromSRGB: SIMD3(
                TransferFunction.decode(red), TransferFunction.decode(green),
                TransferFunction.decode(blue)))
        return LinearRGBA(
            straightRed: working.x, green: working.y, blue: working.z, alpha: alpha)
    }

    /// ビットまで同じか。数でない値どうしは同じとする (ペイロードは見ない)。
    private func sameBits(_ one: Float, _ other: Float) -> Bool {
        (one.isNaN && other.isNaN) || one.bitPattern == other.bitPattern
    }

    private func sameBits(_ one: LinearRGBA, _ other: LinearRGBA) -> Bool {
        sameBits(one.red, other.red) && sameBits(one.green, other.green)
            && sameBits(one.blue, other.blue) && sameBits(one.alpha, other.alpha)
    }

    /// 食い違った入力を書き出して返す。空なら全部が一致している。
    private func mismatches(_ inputs: [(Float, Float, Float, Float)]) -> [String] {
        inputs.compactMap { (red, green, blue, alpha) in
            let got = LinearRGBA.display(red: red, green: green, blue: blue, alpha: alpha)
            let want = reference(red, green, blue, alpha)
            return sameBits(got, want)
                ? nil : "display(\(red), \(green), \(blue), \(alpha)) = \(got) / 参照 \(want)"
        }
    }

    @Test("表は 256 段すべてで decode とビットまで一致する")
    func tableMatchesDecodeAtEveryStep() {
        #expect(OutputStage.decodeLinear.count == 256)
        let wrong = (0...255).filter { step in
            OutputStage.decodeLinear[step].bitPattern
                != TransferFunction.decode(Float(step) / 255).bitPattern
        }
        #expect(wrong.isEmpty, "表と decode が食い違う段: \(wrong)")
    }

    @Test("各成分の 256 段 × 他の成分の端 (0・255) で、変更前の式と同じ値を返す")
    func everyStepWithOtherChannelsAtTheEnds() {
        let ends: [Float] = [0, 255]
        var inputs: [(Float, Float, Float, Float)] = []
        for step in 0...255 {
            let value = Float(step) / 255
            for first in ends {
                for second in ends {
                    let one = first / 255
                    let other = second / 255
                    inputs.append((value, one, other, 1))
                    inputs.append((one, value, other, 1))
                    inputs.append((one, other, value, 1))
                }
            }
            // 不透明度が 1 でない経路 (乗算) にも同じ値が流れる
            inputs.append((value, value, value, 0.5))
        }
        #expect(inputs.count == 256 * 13)
        let wrong = mismatches(inputs)
        #expect(wrong.isEmpty, "\(wrong.count) 件が食い違う。先頭: \(wrong.prefix(3))")
    }

    @Test("素の数値の入口 color() も、整数の入力で変更前の式と同じ値を返す")
    func colorWithIntegersMatchesTheReference() {
        let steps = [0, 1, 2, 10, 11, 12, 13, 64, 127, 128, 129, 200, 254, 255]
        var wrong: [String] = []
        for red in steps {
            for green in steps {
                for blue in steps {
                    let got = color(Float(red), Float(green), Float(blue))
                    let want = reference(Float(red) / 255, Float(green) / 255, Float(blue) / 255)
                    if !sameBits(got, want) { wrong.append("color(\(red), \(green), \(blue))") }
                }
            }
        }
        #expect(wrong.isEmpty, "食い違う入力: \(wrong.prefix(5))")
    }

    @Test("負の 0 は表を通らず、変更前の式と同じ符号で返る")
    func negativeZeroIsNotLookedUp() {
        let zeros: [Float] = [-0.0, 0, 1]
        var inputs: [(Float, Float, Float, Float)] = []
        for red in zeros {
            for green in zeros {
                for blue in zeros { inputs.append((red, green, blue, 1)) }
            }
        }
        let wrong = mismatches(inputs)
        #expect(wrong.isEmpty, "\(wrong)")
        // 参照が -0 を残している (この検査が -0 と 0 を区別できている) ことの確認
        let negative = LinearRGBA.display(red: -0.0, green: -0.0, blue: -0.0)
        #expect(negative.red.bitPattern == (-0.0 as Float).bitPattern)
        let positive = LinearRGBA.display(red: 0, green: 0, blue: 0)
        #expect(positive.red.bitPattern == (0.0 as Float).bitPattern)
    }

    @Test("整数でない入力は表に丸められず、変更前の式と同じ値を返す")
    func nonIntegerInputsAreNotSnapped() {
        var values: [Float] = [
            0.5, 0.25, 0.8, 0.0001, 1e-30, 0.003_130_8, 0.040_45, 0.040_449_9, 0.040_450_1,
        ]
        // 表の段の隣 (1 ulp ずれ) は、段ではない。ずれの向きを両方見る
        for step in 0...255 {
            let value = Float(step) / 255
            values.append(value.nextUp)
            values.append(value.nextDown)
        }
        // 段と段の真ん中
        for step in 0..<255 { values.append((Float(step) + 0.5) / 255) }
        var inputs: [(Float, Float, Float, Float)] = []
        for value in values {
            inputs.append((value, 0, 1, 1))
            inputs.append((0, value, 1, 1))
            inputs.append((1, 0, value, 1))
            inputs.append((value, value, value, 1))
        }
        let wrong = mismatches(inputs)
        #expect(wrong.isEmpty, "\(wrong.count) 件が食い違う。先頭: \(wrong.prefix(3))")
    }

    @Test("範囲の外・無限・数でない入力は decode へ回り、変更前の式と同じ値を返す")
    func outOfRangeAndNonFiniteInputsFallBack() {
        let values: [Float] = [
            -1, -0.001, -255, -1e-30, 1.000_000_1, 1.5, 256.0 / 255, 2, 255, 1000, 3.05e18, 1e30,
            .greatestFiniteMagnitude, -.greatestFiniteMagnitude, .infinity, -.infinity, .nan,
            .leastNormalMagnitude, .leastNonzeroMagnitude,
        ]
        var inputs: [(Float, Float, Float, Float)] = []
        for value in values {
            inputs.append((value, 0, 1, 1))
            inputs.append((0, value, 1, 1))
            inputs.append((1, 0, value, 1))
            inputs.append((value, value, value, 1))
        }
        let wrong = mismatches(inputs)
        #expect(wrong.isEmpty, "\(wrong.count) 件が食い違う。先頭: \(wrong.prefix(3))")
    }
}
