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
}
