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
        /// 写す元の幅が 0 だった。
        case emptyRange
        /// 数でない値・無限の値が渡された。
        case notANumber
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
            .notANumber, "map(): 数でない値・無限の値が渡されたので、写した先の下端を返しました")
        return outLow.isFinite ? outLow : 0
    }
    guard inHigh != inLow else {
        NumberValues.warnOnce(
            .emptyRange, "map(): 写す元の幅が 0 なので、写した先の下端を返しました")
        return outLow
    }
    return outLow + (value - inLow) / (inHigh - inLow) * (outHigh - outLow)
}
