// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Testing
import simd

@testable import MokumeCore

/// 角度の単位を直す口と、値を別の範囲へ写す口 ([#883])。
///
/// 見るのは 3 つ。**手本と同じ答えを出すこと**、**範囲の外を丸めないこと**、そして
/// **数でない値を返さないこと**である。最後の 1 つが崩れると、毎フレーム呼ばれる口が
/// NaN を返して絵が黙って消える。
///
/// GPU は要らない — どれも面へ入る手前の純粋な計算である。
///
/// [#883]: https://github.com/mokume-metal/mokume/issues/883
@Suite("角度の単位と値の写像")
struct NumberSurfaceTests {
    /// 単精度の掛け算と割り算は最下位ビットで揺れるので、等値では見ない。
    private func isNear(_ one: Float, _ other: Float, within tolerance: Float = 1e-5) -> Bool {
        abs(one - other) < tolerance
    }

    // MARK: - 角度の単位

    @Test("度をラジアンに直すと、手本と同じ値になる")
    func degreesBecomeRadians() {
        #expect(radians(0) == 0)
        #expect(isNear(radians(90), .pi / 2))
        #expect(isNear(radians(180), .pi))
        #expect(isNear(radians(360), 2 * .pi))
        #expect(isNear(radians(-90), -.pi / 2))
    }

    @Test("ラジアンを度に直すと、手本と同じ値になる")
    func radiansBecomeDegrees() {
        #expect(degrees(0) == 0)
        #expect(isNear(degrees(.pi / 2), 90))
        #expect(isNear(degrees(.pi), 180))
        #expect(isNear(degrees(-.pi), -180))
    }

    @Test("直して戻すと元の値に返る")
    func theConversionsAreInverses() {
        for angle: Float in [0, 1, 45, 90, 123.5, 360, -30] {
            #expect(isNear(degrees(radians(angle)), angle, within: 1e-3))
            #expect(isNear(radians(degrees(angle)), angle, within: 1e-3))
        }
    }

    @Test("回す口へそのまま渡せる — 単位が揃っている")
    func radiansMatchTheRotationEntry() {
        // rotate(_ radians:) が受ける値と同じ目盛りであることを、回転行列で確かめる。
        // radians(90) で回すと、x 軸の向きが y 軸の向きへ移る。
        var transform = Transform.identity
        transform.rotate(by: radians(90))
        let turned = transform.matrix * SIMD4<Float>(1, 0, 0, 0)
        #expect(isNear(turned.x, 0, within: 1e-6))
        #expect(isNear(turned.y, 1, within: 1e-6))
    }

    // MARK: - スケッチの外

    /// スケッチの外に置いた型。実害はここで起きた — [#883] の `Ring` は、
    /// スケッチではない型の `private static func` に度→ラジアンを書いていた。
    ///
    /// [#883]: https://github.com/mokume-metal/mokume/issues/883
    private enum OutsideASketch {
        static func pointCount(at x: Float, width: Float) -> Int {
            Int(map(x, 0, width, 6, 60).rounded())
        }

        static func spokeAngle(index: Int, of count: Int) -> Float {
            radians(360 / Float(count) * Float(index))
        }
    }

    @Test("スケッチの外の型からも呼べる")
    func theEntriesAreNotSketchMethods() {
        #expect(OutsideASketch.pointCount(at: 0, width: 400) == 6)
        #expect(OutsideASketch.pointCount(at: 400, width: 400) == 60)
        #expect(isNear(OutsideASketch.spokeAngle(index: 3, of: 12), .pi / 2))
    }

    // MARK: - 値を写す

    @Test("端は端へ、間は間へ写る")
    func theRangeMapsAcrossItsEnds() {
        // Issue が挙げた形 — 面の横幅 400 の上での位置を、点の個数 6…60 へ写す
        #expect(isNear(map(0, 0, 400, 6, 60), 6))
        #expect(isNear(map(400, 0, 400, 6, 60), 60))
        #expect(isNear(map(200, 0, 400, 6, 60), 33))
    }

    @Test("写した先が逆向きでも写る")
    func theOutputRangeMayDescend() {
        #expect(isNear(map(0, 0, 1, 10, 0), 10))
        #expect(isNear(map(1, 0, 1, 10, 0), 0))
        #expect(isNear(map(0.25, 0, 1, 10, 0), 7.5))
    }

    @Test("範囲の外は丸めず、そのまま伸びる")
    func valuesOutsideTheRangeExtrapolate() {
        #expect(isNear(map(2, 0, 1, 0, 10), 20))
        #expect(isNear(map(-1, 0, 1, 0, 10), -10))
    }

    @Test("写す元の幅が 0 なら、写した先の下端を返す")
    func anEmptyInputRangeFallsToTheLowEnd() {
        // 手本は ±∞ を返す。ここは絵へ NaN を通さないほうを採っている
        #expect(map(5, 3, 3, 100, 200) == 100)
        #expect(map(3, 3, 3, 100, 200) == 100)
    }

    @Test("数でない値・無限が混じっても、数でない値は返らない")
    func nonFiniteInputsNeverEscape() {
        #expect(map(.nan, 0, 1, 100, 200) == 100)
        #expect(map(0.5, .nan, 1, 100, 200) == 100)
        // 上端が無限なら幅も無限。下端が無限だと割り算が NaN になる — 両側を見る
        #expect(map(0.5, 0, .infinity, 100, 200) == 100)
        #expect(map(0.5, -.infinity, 1, 100, 200) == 100)
        #expect(map(0.5, 0, 1, 100, .nan) == 100)
        // 下端そのものが数でないときは 0 へ倒す — 返す先が無いため
        #expect(map(0.5, 0, 1, .nan, 200) == 0)
    }
}

/// 値を写す口が言う注意。
///
/// 控えはモジュールに 1 つなので、事情ごとに数えていることだけを見る (この控えを触るのは
/// この suite だけである)。
@Suite("値を写す口が言う注意")
struct NumberValueWarningTests {
    @Test("幅が 0 の注意と、数でない値の注意は互いに黙らせない")
    func theTwoReasonsCountSeparately() {
        #expect(map(5, 3, 3, 100, 200) == 100)
        #expect(map(.nan, 0, 1, 100, 200) == 100)
        #expect(NumberValues.warnings.hasWarned(.emptyRange))
        #expect(NumberValues.warnings.hasWarned(.notANumber))
        #expect(NumberValues.warnings.message(for: .emptyRange)?.hasPrefix("map()") == true)
        #expect(NumberValues.warnings.message(for: .notANumber)?.hasPrefix("map()") == true)
    }
}
