// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Testing
import simd

@testable import MokumeCore

/// 角度の単位を直す口と、値を別の範囲へ写す口 ([#883])、間を取る口と締める口 ([#1281])。
///
/// 見るのは 3 つ。**手本と同じ答えを出すこと**、**範囲の外を丸めないこと**、そして
/// **数でない値を返さないこと**である。最後の 1 つが崩れると、毎フレーム呼ばれる口が
/// NaN を返して絵が黙って消える。
///
/// GPU は要らない — どれも面へ入る手前の純粋な計算である。
///
/// [#883]: https://github.com/mokume-metal/mokume/issues/883
/// [#1281]: https://github.com/mokume-metal/mokume/issues/1281
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

        /// [#1281] の 2 作品が手で書いていた形 — カメラの引きを補間し、締めて返す。
        ///
        /// [#1281]: https://github.com/mokume-metal/mokume/issues/1281
        static func pullBack(from near: Float, to far: Float, at progress: Float) -> Float {
            constrain(lerp(near, far, progress), near, far)
        }
    }

    @Test("スケッチの外の型からも呼べる")
    func theEntriesAreNotSketchMethods() {
        #expect(OutsideASketch.pointCount(at: 0, width: 400) == 6)
        #expect(OutsideASketch.pointCount(at: 400, width: 400) == 60)
        #expect(isNear(OutsideASketch.spokeAngle(index: 3, of: 12), .pi / 2))
        #expect(isNear(OutsideASketch.pullBack(from: 100, to: 400, at: 0.5), 250))
        // 締めが効くので、補間が範囲の外へ伸びても返る値は範囲の中に留まる
        #expect(isNear(OutsideASketch.pullBack(from: 100, to: 400, at: 2), 400))
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

    // MARK: - 間を取る

    @Test("端は端へ、中ほどは中ほどへ")
    func theInterpolationHitsItsEnds() {
        #expect(isNear(lerp(0, 10, 0), 0))
        #expect(isNear(lerp(0, 10, 1), 10))
        #expect(isNear(lerp(0, 10, 0.5), 5))
        #expect(isNear(lerp(100, 400, 0.25), 175))
    }

    @Test("始まりと終わりが逆向きでも間を取る")
    func theInterpolationMayDescend() {
        #expect(isNear(lerp(10, 0, 0.25), 7.5))
        #expect(isNear(lerp(-5, 5, 0.5), 0))
    }

    @Test("0…1 の外は締めず、そのまま伸びる")
    func amountsOutsideTheUnitRangeExtrapolate() {
        // ADR-0020 決定 7 の表が「締めない」と決めた行。締めたいときは constrain を通す
        #expect(isNear(lerp(0, 10, 2), 20))
        #expect(isNear(lerp(0, 10, -1), -10))
        #expect(isNear(lerp(0, 10, 1.5), 15))
    }

    @Test("間を取る口へ数でない値・無限が混じっても、数でない値は返らない")
    func nonFiniteInterpolationInputsNeverEscape() {
        #expect(lerp(.nan, 10, 0.5) == 0)  // 始まりが数でないので返す先が無い — 0 へ倒す
        #expect(lerp(3, .nan, 0.5) == 3)
        #expect(lerp(3, 10, .nan) == 3)
        #expect(lerp(3, .infinity, 0.5) == 3)
        #expect(lerp(3, 10, .infinity) == 3)
    }

    // MARK: - 締める

    @Test("範囲の中は素通りし、外は端で止まる")
    func valuesAreHeldInsideTheRange() {
        #expect(isNear(constrain(5, 0, 10), 5))
        #expect(isNear(constrain(-3, 0, 10), 0))
        #expect(isNear(constrain(42, 0, 10), 10))
        #expect(isNear(constrain(0, 0, 10), 0))
        #expect(isNear(constrain(10, 0, 10), 10))
    }

    @Test("上下が逆に渡されたら、入れ替えて締める")
    func reversedBoundsAreSwapped() {
        // map が逆向きの範囲を受け取るのと揃える (ADR-0020 決定 7 の表)
        #expect(isNear(constrain(5, 10, 0), 5))
        #expect(isNear(constrain(-3, 10, 0), 0))
        #expect(isNear(constrain(42, 10, 0), 10))
    }

    @Test("幅の無い範囲へは、その 1 点が返る")
    func anEmptyRangeYieldsItsOnlyPoint() {
        #expect(constrain(5, 3, 3) == 3)
        #expect(constrain(-5, 3, 3) == 3)
    }

    @Test("締める口へ数でない値・無限が混じっても、数でない値は返らない")
    func nonFiniteConstraintInputsNeverEscape() {
        #expect(constrain(.nan, 0, 10) == 0)
        #expect(constrain(5, .nan, 10) == 10)  // 有限なほうの端へ倒す
        #expect(constrain(5, 0, .nan) == 0)
        #expect(constrain(5, 0, .infinity) == 0)
        #expect(constrain(5, .nan, .nan) == 0)  // 返す先が無い
        // 上下が逆でも、倒す先は下端のまま
        #expect(constrain(.nan, 10, 0) == 0)
    }
}

/// 数を写す口・間を取る口・締める口が言う注意。
///
/// 控えはモジュールに 1 つなので、事情ごとに数えていることだけを見る (この控えを触るのは
/// この suite だけである)。
@Suite("数を扱う口が言う注意")
struct NumberValueWarningTests {
    @Test("幅が 0 の注意と、数でない値の注意は互いに黙らせない")
    func theTwoReasonsCountSeparately() {
        #expect(map(5, 3, 3, 100, 200) == 100)
        #expect(map(.nan, 0, 1, 100, 200) == 100)
        #expect(NumberValues.warnings.hasWarned(.emptyRange))
        #expect(NumberValues.warnings.hasWarned(.notANumber(.map)))
        #expect(NumberValues.warnings.message(for: .emptyRange)?.hasPrefix("map()") == true)
        #expect(NumberValues.warnings.message(for: .notANumber(.map))?.hasPrefix("map()") == true)
    }

    /// 鍵を 1 つにすると、先に鳴った口が残りを永久に黙らせる — 事情が同じでも口ごとに
    /// 数える ([#1281])。**ここが崩れても絵は変わらない**ので、崩れたことに気づく術は
    /// この検査しか無い。
    ///
    /// [#1281]: https://github.com/mokume-metal/mokume/issues/1281
    @Test("数でない値の注意は、口ごとに数えられる")
    func eachEntryCountsItsOwnNonFiniteWarning() {
        #expect(map(.nan, 0, 1, 100, 200) == 100)
        #expect(lerp(3, 10, .nan) == 3)
        #expect(constrain(.nan, 0, 10) == 0)
        #expect(NumberValues.warnings.hasWarned(.notANumber(.map)))
        #expect(NumberValues.warnings.hasWarned(.notANumber(.lerp)))
        #expect(NumberValues.warnings.hasWarned(.notANumber(.constrain)))
        // 文面も口ごとに違う — 鍵を共有していれば、どれかが他の口の名前で鳴る
        #expect(NumberValues.warnings.message(for: .notANumber(.map))?.hasPrefix("map()") == true)
        #expect(NumberValues.warnings.message(for: .notANumber(.lerp))?.hasPrefix("lerp()") == true)
        #expect(
            NumberValues.warnings.message(for: .notANumber(.constrain))?.hasPrefix("constrain()")
                == true)
    }
}
