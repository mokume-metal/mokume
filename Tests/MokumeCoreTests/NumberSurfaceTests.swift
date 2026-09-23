// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Testing
import simd

@testable import MokumeCore

/// 角度の単位を直す口と、値を別の範囲へ写す口 ([#883])、間を取る口と締める口 ([#1281])。
///
/// 見るのは 4 つ。**手本と同じ答えを出すこと**、**端が端へちょうど戻ること** ([#1453]・
/// [#1476])、**範囲の外を丸めないこと**、そして**数でない値を返さないこと**である。最後の
/// 1 つが崩れると、毎フレーム呼ばれる口が NaN を返して絵が黙って消える。
///
/// GPU は要らない — どれも面へ入る手前の純粋な計算である。
///
/// [#883]: https://github.com/mokume-metal/mokume/issues/883
/// [#1281]: https://github.com/mokume-metal/mokume/issues/1281
/// [#1453]: https://github.com/mokume-metal/mokume/issues/1453
/// [#1476]: https://github.com/mokume-metal/mokume/issues/1476
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
        #expect(map(2, 0, 1, 0, 10) == 20)
        #expect(map(-1, 0, 1, 0, 10) == -10)
    }

    /// 写した先の幅 (`outHigh - outLow`) を丸めてから掛けると、元の範囲の上端を写しても
    /// 写した先の上端に戻らない。幅が `Float` で溢れると、`0 × ∞` で NaN になる ([#1476])。
    ///
    /// [#1476]: https://github.com/mokume-metal/mokume/issues/1476
    @Test("元の範囲の端は、写した先の端へちょうど写る")
    func theEndsMapExactly() {
        #expect(map(1, 0, 1, 1e8, 1) == 1)
        #expect(map(0, 0, 1, 1e8, 1) == 1e8)
        #expect(map(0, 0, 1, -3e38, 3e38) == -3e38)
        #expect(map(1, 0, 1, -3e38, 3e38) == 3e38)
    }

    @Test("幅が溢れる範囲でも、真ん中は真ん中へ写る")
    func overflowingRangesMapTheirMiddle() {
        #expect(map(0.5, 0, 1, -3e38, 3e38) == 0)
        // 元の範囲の幅 (`inHigh - inLow`) が溢れると、比が 0 に潰れていた
        #expect(map(0, -3e38, 3e38, 0, 1) == 0.5)
    }

    @Test(
        "幅が溢れる範囲でも、元の範囲の中の値は有限で、写した先の両端の間に写る",
        arguments: RandomTests.overflowingSpans, unitAmounts)
    func anOverflowingRangeMapsBetweenItsEnds(_ span: (low: Float, high: Float), _ amount: Float) {
        // 元の範囲の中の値。幅を作らずに両端から直に混ぜれば、幅が溢れる範囲の中でも作れる
        let inside = (1 - amount) * span.low + amount * span.high
        let mapped: [(value: Float, outLow: Float, outHigh: Float)] = [
            (map(amount, 0, 1, span.low, span.high), span.low, span.high),  // 写した先が溢れる
            (map(inside, span.low, span.high, 0, 1), 0, 1),  // 元が溢れる
            (map(inside, span.low, span.high, span.high, span.low), span.high, span.low),  // 両方
        ]
        for (value, outLow, outHigh) in mapped {
            #expect(value.isFinite, "\(value) (写した先 \(outLow)…\(outHigh))")
            #expect(value >= min(outLow, outHigh) && value <= max(outLow, outHigh))
        }
    }

    /// 写す値が元の範囲から遠く外れると、比 (`(value - inLow) / (inHigh - inLow)`) が溢れて
    /// ±∞ になる。外挿は締めない ([#1453] の判断 (i)) ので ±∞ が返ってよいが、数でない値は
    /// 返さない ([#1476])。
    ///
    /// [#1453]: https://github.com/mokume-metal/mokume/issues/1453
    /// [#1476]: https://github.com/mokume-metal/mokume/issues/1476
    @Test("写す値が範囲から遠く外れても、数でない値は返らない")
    func farExtrapolationNeverGivesNotANumber() {
        // 写した先の幅が 0 なら、どこを写しても下端 — 比が ∞ でも `0 × ∞` を作らない
        #expect(map(3e38, -3e38, 0, 5, 5) == 5)
        // 元の幅が溢れる範囲の外の値 (真の値は 1.0169…)
        #expect(map(3e38, -3e38, 2.9e38, 0, 1).isFinite)
        // 締めないので、真の値が Float に無ければ ∞ のまま
        #expect(map(3e38, -3e38, 0, 0, 1) == .infinity)
        #expect(map(3e38, -3e38, 0, 1, 0) == -.infinity)
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
        #expect(lerp(0, 10, 2) == 20)
        #expect(lerp(0, 10, -1) == -10)
        #expect(lerp(0, 10, 1.5) == 15)
    }

    /// 端の差 (`stop - start`) を丸めてから掛けると、`amount` が 1 でも `stop` に戻らない
    /// ([#1453])。極端な値に限らない — 0…1000 の組の 6 つに 1 つで起きる。
    ///
    /// [#1453]: https://github.com/mokume-metal/mokume/issues/1453
    @Test("amount が 0 なら start が、1 なら stop がちょうど返る")
    func theEndsAreExact() {
        #expect(lerp(1e8, 1, 1) == 1)
        #expect(lerp(1e30, 1, 1) == 1)
        #expect(lerp(571.23236, 44.24578, 1) == 44.24578)
        #expect(lerp(1e8, 1, 0) == 1e8)
        #expect(lerp(571.23236, 44.24578, 0) == 571.23236)
        // 端の差が溢れる組でも。`amount` が 0 のとき、いまの式は `∞ × 0` で NaN を返していた
        #expect(lerp(-3e38, 3e38, 0) == -3e38)
        #expect(lerp(-3e38, 3e38, 1) == 3e38)
    }

    @Test("ふつうの値の組でも、端はちょうど返る")
    func theEndsAreExactForOrdinaryValues() {
        var randomness = Randomness(seed: 1453)
        let pairs = (0..<1000).map { _ in
            (start: randomness.value(from: 0, to: 1000), stop: randomness.value(from: 0, to: 1000))
        }
        let missed = pairs.filter { lerp($0.start, $0.stop, 0) != $0.start || lerp($0.start, $0.stop, 1) != $0.stop }
        #expect(missed.isEmpty, "端がずれた組 \(missed.count) / \(pairs.count): \(missed.prefix(3))")
    }

    /// 0…1 の端と真ん中と、端のすぐ隣。`random()` の引きの代表 (`RandomTests`) に 1 を足したもの。
    nonisolated static var unitAmounts: [Float] { RandomTests.representativeUnits + [1] }

    /// 端はどちらも有限なのに、差 (`stop - start`) が `Float` で溢れる組 ([#1453])。組は
    /// `random(low, high)` が同じ穴を塞いだとき ([#1312]) のものをそのまま使い、逆向きも見る。
    ///
    /// [#1312]: https://github.com/mokume-metal/mokume/issues/1312
    /// [#1453]: https://github.com/mokume-metal/mokume/issues/1453
    @Test(
        "端の差が溢れても、0…1 の間は有限で、端の間に収まる",
        arguments: RandomTests.overflowingSpans, unitAmounts)
    func anOverflowingSpanStaysBetweenItsEnds(_ span: (low: Float, high: Float), _ amount: Float) {
        for (start, stop) in [(span.low, span.high), (span.high, span.low)] {
            let value = lerp(start, stop, amount)
            #expect(value.isFinite, "lerp(\(start), \(stop), \(amount)) = \(value)")
            #expect(value >= min(start, stop) && value <= max(start, stop))
        }
    }

    @Test("端の差が溢れても、真ん中は 0")
    func anOverflowingSpanHasItsMiddleAtZero() {
        #expect(lerp(-3e38, 3e38, 0.5) == 0)
        #expect(lerp(-.greatestFiniteMagnitude, .greatestFiniteMagnitude, 0.5) == 0)
    }

    /// ここから 2 つは、いまの式 (`start + (stop - start) * amount`) が満たしていて、端を
    /// ちょうどにする別の式 (`(1 - amount) * start + amount * stop`) が壊す性質 ([#1453])。
    /// 端を直すときに失わないよう、いまの式のうちに押さえておく。
    ///
    /// [#1453]: https://github.com/mokume-metal/mokume/issues/1453
    @Test("始まりと終わりが同じなら、どの amount でも始まりが返る")
    func anEmptySpanAlwaysGivesItsStart() {
        for amount: Float in [0, 0.25, 0.86, 0.8627621, 1, 2, -1] {
            #expect(lerp(9.357954e11, 9.357954e11, amount) == 9.357954e11, "amount \(amount)")
        }
    }

    @Test("amount を隣の値へ進めても、値は逆行しない")
    func advancingTheAmountNeverTurnsBack() {
        #expect(lerp(201.32661, 672.665, 0.49999994) <= lerp(201.32661, 672.665, 0.49999997))
        // 1 の直前 → 1 → 1 の直後。1 で `stop` ちょうどを返しても、隣との並びは崩れない
        let pairs: [(start: Float, stop: Float)] = [
            (1e8, 1), (1e30, 1), (571.23236, 44.24578), (201.32661, 672.665), (-3e38, 3e38),
        ]
        for (start, stop) in pairs {
            let values = [Float(1).nextDown, 1, Float(1).nextUp].map { lerp(start, stop, $0) }
            let ordered = stop > start ? values == values.sorted() : values == values.sorted(by: >)
            #expect(ordered, "lerp(\(start), \(stop), 1 の直前 / 1 / 1 の直後) = \(values)")
        }
    }

    /// 外挿は締めない ([#1453] の判断 (i))。真の値が `Float` に無ければ ±∞ になってよいが、
    /// 有限の入力から数でない値は返さない。
    ///
    /// [#1453]: https://github.com/mokume-metal/mokume/issues/1453
    @Test("外挿が Float を越えたら ±∞ になり、数でない値は返らない")
    func extrapolationBeyondFloatGivesInfinityNotNotANumber() {
        #expect(lerp(1e38, 2e38, 10) == .infinity)
        #expect(lerp(2e38, 1e38, 10) == -.infinity)
        #expect(lerp(-3e38, 3e38, 2) == .infinity)
        #expect(lerp(-3e38, 3e38, -1) == -.infinity)
        // 端の差が溢れる組の、端のすぐ外 (真の値は 3.06e38 で Float に収まる)
        #expect(lerp(-3e38, 3e38, 1.01).isFinite)
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
