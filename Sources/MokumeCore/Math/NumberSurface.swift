// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

// MARK: - 値を写す口が言う注意

/// 数を写す口が 1 度だけ言う注意。
///
/// 描く口の注意は面が持つ (``Canvas/Warning``) が、``map(_:_:_:_:_:)`` のような値を
/// 写すだけの口には持ち主が無い。控えだけをここに置く形は ``ColorValues`` と同じで、
/// 鍵で数える仕組みそのものは ``WarningLog`` が持つ ([#833])。
///
/// [#833]: https://github.com/mokume-metal/mokume/issues/833
enum NumberValues {
    /// 1 度だけ言う注意の種類。**事情ごとに数える** — 1 つの鍵を共有すると、先に
    /// 鳴ったほうが後の事情を永久に黙らせる。
    enum Warning: Hashable {
        /// 写す元の幅が 0 だった。``map(_:_:_:_:_:)`` だけが持つ事情である。
        case emptyRange
        /// 数でない値・無限の値が渡された。**口ごとに数える** — 事情は同じでも、
        /// 出す文面が口ごとに違ううえ、綴りを 1 つにすると先に鳴った口が残りを
        /// 永久に黙らせる。連想値にしてあるのは、口が増えても鍵の共有が起こり
        /// ようがない形にするためで、綴りを並べる (`lerpNotANumber` …) と
        /// 足す人が使い回せてしまう。
        case notANumber(Entry)

        /// 注意を出した口。
        enum Entry: Hashable {
            case map
            case lerp
            case constrain
        }
    }

    /// 言った注意の控え。書き換えるのは ``warnOnce(_:_:)`` だけ。
    private(set) static var warnings = WarningLog<Warning>()

    static func warnOnce(_ warning: Warning, _ message: @autoclosure () -> String) {
        warnings.warnOnce(warning, message())
    }
}

// MARK: - 角度の単位を直す

/// 度をラジアンに直す。
///
/// ```swift
/// rotate(radians(45))
/// ```
///
/// **このパッケージが角度を受け取る口は、すべてラジアンで名乗っている**
/// (``Sketch/rotate(_:)`` の引数名が `radians`)。度で考えたい絵 — 円を 12 等分する、
/// 30 度ずつ回す — は、ここを通してから渡す。
///
/// **単位を切り替える状態は持たない。** `angleMode()` は無く、単位は呼んだ 1 行から
/// 読める ([ADR-0033] 決定 4 が `colorMode()` を持たないのと同じ理由)。
///
/// [ADR-0033]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0033-color-specification-surface.md
public func radians(_ degrees: Float) -> Float { degrees * .pi / 180 }

/// ラジアンを度に直す。``radians(_:)`` の逆。
///
/// ```swift
/// let tilt = degrees(atan2(mouseY - height / 2, mouseX - width / 2))
/// ```
///
/// 角度を**読みたい**ときのためにある — 画面に出す、度で書かれた表と突き合わせる、
/// といった用途である。描く口へ渡す値は直さなくてよい。
public func degrees(_ radians: Float) -> Float { radians * 180 / .pi }

// MARK: - 値を別の範囲へ写す

/// ある範囲の値を、別の範囲の値へ写す。
///
/// ```swift
/// let pointCount = map(mouseX, 0, width, 6, 60)
/// ```
///
/// 引数は写す値・元の範囲の下端と上端・写した先の下端と上端の順 (手本と同じ並び)。
///
/// **範囲の外は丸めない。** 元の範囲を外れた値は、そのまま外へ伸びる — `map(2, 0, 1, 0, 10)`
/// は 20 を返す。締めたいときは呼ぶ側で締める。
///
/// **元の幅が 0 のとき、数でない値・無限の値が混じったときは、写した先の下端を返す。**
/// 手本は ±∞ や NaN を返すが、``Sketch/draw()`` から毎フレーム呼ばれる口が数でない値を
/// 返すと、**絵が黙って消える** ([ADR-0020] 決定 5)。注意は 1 度だけ言う。
///
/// [ADR-0020]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0020-api-naming-and-surface.md
public func map(
    _ value: Float, _ inLow: Float, _ inHigh: Float, _ outLow: Float, _ outHigh: Float
) -> Float {
    guard value.isFinite, inLow.isFinite, inHigh.isFinite, outLow.isFinite, outHigh.isFinite
    else {
        NumberValues.warnOnce(
            .notANumber(.map), "map(): got a value that is not a number, or an infinite one, so the low end of the destination was returned")
        return outLow.isFinite ? outLow : 0
    }
    guard inHigh != inLow else {
        NumberValues.warnOnce(
            .emptyRange,
            "map(): the source range has zero width, so the low end of the destination was returned")
        return outLow
    }
    return outLow + (value - inLow) / (inHigh - inLow) * (outHigh - outLow)
}

// MARK: - 2 つの値の間を取る

/// 2 つの値の間を取る。
///
/// ```swift
/// let x = lerp(20, width - 20, 0.25)
/// ```
///
/// 引数は始まり・終わり・その間のどこか、の順 (手本と同じ並び)。`amount` が 0 なら
/// `start`、1 なら `stop` が返る。
///
/// **0…1 の外は締めない。** `lerp(0, 10, 2)` は 20 を、`lerp(0, 10, -1)` は -10 を返す
/// (手本と同じで、``map(_:_:_:_:_:)`` の外挿と揃う)。締めたいときは ``constrain(_:_:_:)``
/// を通す。
///
/// **数でない値・無限の値が混じったときは `start` を返す。** 毎フレーム呼ばれる口が
/// 数でない値を返すと、**絵が黙って消える** ([ADR-0020] 決定 5)。注意は 1 度だけ言う。
///
/// [ADR-0020]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0020-api-naming-and-surface.md
public func lerp(_ start: Float, _ stop: Float, _ amount: Float) -> Float {
    guard start.isFinite, stop.isFinite, amount.isFinite else {
        NumberValues.warnOnce(
            .notANumber(.lerp),
            "lerp(): got a value that is not a number, or an infinite one, so the start was returned"
        )
        return start.isFinite ? start : 0
    }
    return start + (stop - start) * amount
}

// MARK: - 値を範囲へ締める

/// 値を、決めた範囲の中へ締める。
///
/// ```swift
/// let radius = constrain(mouseX / 4, 4, 120)
/// ```
///
/// 引数は締める値・下端・上端の順 (手本と同じ並び)。範囲の中の値はそのまま返る。
///
/// **上下が逆に渡されたら入れ替えて締める。** `constrain(5, 10, 0)` は `constrain(5, 0, 10)`
/// と同じ 5 を返す — 逆向きの範囲を受け取る ``map(_:_:_:_:_:)`` と揃う。
///
/// **数でない値・無限の値が混じったときは、範囲の端へ倒す** — 両端とも有限なら下端を、
/// 片側だけ有限ならその端を、どちらも数でなければ 0 を返す。毎フレーム呼ばれる口が
/// 数でない値を返すと、**絵が黙って消える** ([ADR-0020] 決定 5)。注意は 1 度だけ言う。
///
/// [ADR-0020]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0020-api-naming-and-surface.md
public func constrain(_ value: Float, _ low: Float, _ high: Float) -> Float {
    guard value.isFinite, low.isFinite, high.isFinite else {
        NumberValues.warnOnce(
            .notANumber(.constrain),
            "constrain(): got a value that is not a number, or an infinite one, so the low end of the range was returned"
        )
        // 両端のうち有限なほうへ倒す。どちらも数でなければ返す先が無いので 0 にする
        if low.isFinite && high.isFinite { return min(low, high) }
        if low.isFinite { return low }
        if high.isFinite { return high }
        return 0
    }
    return min(max(value, min(low, high)), max(low, high))
}
