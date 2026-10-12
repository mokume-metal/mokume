// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Testing

@testable import MokumeCore

/// 描画の受け口が数をどう受け取るかを固定する検査 (#1018)。
///
/// ADR-0035 決定 7 は「6-b (整数リテラルだけの式が `Int` へ倒れる) を承知したうえで、
/// 受け口は戻さない」と決めた。**承知していることは、承知した中身を書き留めて初めて
/// 承知になる** — 受け口を将来 `Float` へ戻せば、ここが赤くなる。
///
/// 測る口は ``Transform/apply(x:y:)`` にした。`some ScalarConvertible` を受けて
/// 受け取った値をそのまま返す (単位変換の無い) 経路で、GPU を要さない。
@Suite("数の受け取り方")
struct ScalarConvertibleTests {
    private let identity = Transform.identity

    /// 整数リテラルだけで書いた式は `Int` のまま計算され、小数部が落ちる。
    ///
    /// **これは通ってしまう。** #1017 (`.pi` が解決しない) は赤くなるが、こちらは
    /// 絵だけが変わる — works の `additivewave-1.png` が 1 階調ぶん動いた経路である。
    @Test("整数リテラルだけの割り算は、整数除算になる")
    func integerLiteralsDivideAsIntegers() {
        #expect(identity.apply(x: 1 / 2, y: 0).x == 0)
        #expect(identity.apply(x: 255 * 50 / 100, y: 0).x == 127)
        #expect(identity.apply(x: 640 * 2 / 3, y: 0).x == 426)
    }

    /// **トップレベルの色と数の口も同じ受け方をする** ([#2255])。`Float` 固定だった頃は、引数の型
    /// から逆算して `1 / 2` を `Float` の 0.5 にしていた。総称の受け口では `Int` の 0 になる
    /// (ADR-0035 決定 6-b)。
    ///
    /// [#2255]: https://github.com/mokume-metal/mokume/issues/2255
    @Test("トップレベルの数の口でも、整数リテラルだけの割り算は整数除算になる")
    func integerLiteralsDivideAsIntegersAtTheTopLevel() {
        let half: Float = lerp(0, 10, 1 / 2)
        #expect(half == 0)
        let fraction: Float = lerp(0, 10, 1 / 2.0)
        #expect(fraction == 5)
        let gray: LinearRGBA = color(255 / 2)
        #expect(gray == color(Float(127)))
    }

    /// 片方に小数点を付ければ、面の案内どおり小数のまま渡る。
    @Test("片方を小数で書けば、小数のまま渡る")
    func oneFloatingLiteralKeepsThePrecision() {
        #expect(identity.apply(x: 1 / 2.0, y: 0).x == 0.5)
        #expect(identity.apply(x: 255 * 50 / 100.0, y: 0).x == 127.5)
        #expect(identity.apply(x: 640 * 2 / 3.0, y: 0).x == 640 * 2 / Float(3))
    }

    /// 面が返した数が式に入っていれば、全体が `Float` として計算される。
    @Test("面が返した数が混ざれば、整数除算にならない")
    func aFloatInTheExpressionDecidesTheType() {
        let width: Float = 1
        #expect(identity.apply(x: width * 1 / 2, y: 0).x == 0.5)
    }

    /// 決定 1 が生きていること。`Int` と `Double` の変数はそのまま渡せる。
    ///
    /// `.pi` が渡せないこと (#1017) はコンパイルエラーなので、ここでは書けない。
    /// 綴り方は ``ScalarConvertible`` の説明文と作者の読む面が持つ。
    @Test("Float・Double・Int の変数は、どれもそのまま渡せる")
    func everyStoredWidthPasses() {
        let asFloat: Float = 3.5
        let asDouble: Double = 3.5
        let asInt: Int = 3
        #expect(identity.apply(x: asFloat, y: 0).x == 3.5)
        #expect(identity.apply(x: asDouble, y: 0).x == 3.5)
        #expect(identity.apply(x: asInt, y: 0).x == 3)
    }

    /// **トップレベルの色と数の口も、変数をそのまま受ける** ([#2255])。Sketch の口と同じく
    /// `Float`・`Double`・`Int` のどれで持っていても通り、`Float` で渡したときと同じ値を返す
    /// (返り値は `Float` のまま — ADR-0035 決定 3)。
    ///
    /// 式は 1 つずつ型を書いた `let` に受けてから比べる。総称の口を `#expect` の中で
    /// 連ねると、型検査が重くなる。
    ///
    /// [#2255]: https://github.com/mokume-metal/mokume/issues/2255
    @Test("トップレベルの色と数の口も、Float・Double・Int の変数をそのまま受ける")
    func topLevelColourAndNumberPortsTakeEveryStoredWidth() {
        let i: Int = 3
        let d: Double = 0.5
        let f: Float = 3

        // 数の口
        let mapped: Float = map(i, 0, 10, 0, 1)
        #expect(mapped == 0.3)
        #expect(mapped == map(f, Float(0), Float(10), Float(0), Float(1)))
        let mixed: Float = lerp(0, i, d)
        #expect(mixed == 1.5)
        let held: Float = constrain(i, 0, 2)
        #expect(held == 2)
        let ratio: Float = norm(i, 0, 10)
        #expect(ratio == 0.3)
        let eased: Float = smoothstep(0, 10, i)
        #expect(eased == smoothstep(Float(0), Float(10), f))
        let turned: Float = radians(i)
        #expect(turned == radians(f))
        let read: Float = degrees(d)
        #expect(read == degrees(Float(0.5)))

        // 色の口
        let red: LinearRGBA = color(i, 0, 0)
        #expect(red == color(f, Float(0), Float(0)))
        let veil: LinearRGBA = color(i, d)
        #expect(veil == color(f, Float(0.5)))
        let gray: LinearRGBA = color(i)
        #expect(gray == color(f))
        let tinted: LinearRGBA = color(hue: i, saturation: 80, brightness: 90)
        #expect(tinted == color(hue: f, saturation: Float(80), brightness: Float(90)))
        let a: LinearRGBA = color(255, 170, 60)
        let b: LinearRGBA = color(40, 50, 120)
        let blended: LinearRGBA = lerpColor(a, b, d)
        #expect(blended == lerpColor(a, b, Float(0.5)))
    }
}
