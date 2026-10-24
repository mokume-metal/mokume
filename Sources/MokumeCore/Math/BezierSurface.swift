// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

// MARK: - 3 次のベジェ曲線の上の点と向き

/// 3 次のベジェ曲線の上の点を、1 つの軸について返す。
///
/// ```swift
/// // 曲線 bezier(60, 420, 260, 60, 640, 600, 900, 160) に沿って動く点
/// let t = (time * 0.15).truncatingRemainder(dividingBy: 1)
/// let x = bezierPoint(60, 260, 640, 900, t)
/// let y = bezierPoint(420, 60, 600, 160, t)
/// circle(x, y, 20)
/// ```
///
/// 引数は手本と同じ並びで、**始点・制御点・制御点・終点**の 1 つの軸の値 (`a, b, c, d`) と、
/// 曲線の上の位置 `t` である。平面の曲線なら、`x` の 4 つと `y` の 4 つで 2 回呼ぶ。
/// ``SketchPart/bezier(_:_:_:_:_:_:_:_:)`` に渡す 8 つの数を、軸ごとに 4 つずつ取り出した形である。
///
/// `t` が 0 なら `a` (始点)、1 なら `d` (終点) が**ちょうど**返る。制御点 `b`・`c` は通らない。
/// `bezierPoint(0, 0, 100, 100, 0.5)` は 50 を返す。
///
/// **`t` は曲線の長さの割合ではない。** 制御点が偏っていると、`t` を等間隔に進めても点は
/// 等間隔には進まない。**0…1 の外は締めずに、曲線をそのまま延ばす** (``lerp(_:_:_:)`` と
/// 同じ)。締めたいときは ``constrain(_:_:_:)`` を通す。伸びた先が `Float` の範囲を越えたら
/// ±∞ を返す (数でない値は返さない)。
///
/// **数でない値・無限の値が混じったときは `a` を返す** (`a` も数でないときは 0)。毎フレーム
/// 呼ばれる口が数でない値を返すと、**絵が黙って消える** ([ADR-0020] 決定 5)。注意は 1 度だけ言う。
///
/// **進む向きは ``bezierTangent(_:_:_:_:_:)`` が返す。** 引くのは
/// ``SketchPart/bezier(_:_:_:_:_:_:_:_:)`` で、同じ曲線を ``SketchPart/bezierVertex(_:_:_:_:_:_:)``
/// で繋いだものも同じ式である。
///
/// [ADR-0020]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0020-api-naming-and-surface.md
public nonisolated func bezierPoint(
    _ a: some ScalarConvertible, _ b: some ScalarConvertible, _ c: some ScalarConvertible, _ d: some ScalarConvertible,
    _ t: some ScalarConvertible
) -> Float {
    let (a, b, c, d, t) = (a.asFloat, b.asFloat, c.asFloat, d.asFloat, t.asFloat)
    guard a.isFinite, b.isFinite, c.isFinite, d.isFinite, t.isFinite else {
        NumberValues.warnOnce(
            .notANumber(.bezierPoint),
            "bezierPoint(): got a value that is not a number, or an infinite one, so the start was returned"
        )
        return a.isFinite ? a : 0
    }
    // 4 つの項を `Float` で足すと、`t` が 1 に近いときに丸めが積もる。`Double` で計算して
    // 戻す — 有限の入力からは有限の `Double` が出る (±∞ になるのは `Float` へ戻すとき)
    let (da, db, dc, dd, dt) = (Double(a), Double(b), Double(c), Double(d), Double(t))
    let u = 1 - dt
    return Float(da * (u * u * u) + db * (3 * u * u * dt) + dc * (3 * u * dt * dt) + dd * (dt * dt * dt))
}

/// 3 次のベジェ曲線の、1 つの軸についての傾き (`t` で微分した値) を返す。
///
/// ```swift
/// // 曲線 bezier(60, 420, 260, 60, 640, 600, 900, 160) の上で、進む向きへ頭を向ける
/// let t = (time * 0.15).truncatingRemainder(dividingBy: 1)
/// let angle = atan2(bezierTangent(420, 60, 600, 160, t), bezierTangent(60, 260, 640, 900, t))
/// rotate(angle)
/// ```
///
/// 引数は ``bezierPoint(_:_:_:_:_:)`` と同じ。**`x` の傾きと `y` の傾きを別々に求め、
/// `atan2(y の傾き, x の傾き)` で向きにする**。`bezierTangent(0, 0, 100, 100, 0.5)` は 150 を返す。
///
/// **返るのは向きではなく、`t` を 1 進めたときの進み量である。** 長さは `t` の進み方
/// (速さ) を含むので、向きだけが要るときは `atan2` へ渡す (正の倍数は向きを変えない)。
/// 始点と制御点が同じ位置にある (`a == b`) と、`t` が 0 のとき傾きが 0 になる — 向きが
/// 定まらないので、その端だけ少し内側 (`0.001` など) で読む。
///
/// **0…1 の外は締めない** (``bezierPoint(_:_:_:_:_:)`` と同じ)。数でない値・無限の値が混じった
/// ときは 0 を返し、注意は 1 度だけ言う。
public nonisolated func bezierTangent(
    _ a: some ScalarConvertible, _ b: some ScalarConvertible, _ c: some ScalarConvertible, _ d: some ScalarConvertible,
    _ t: some ScalarConvertible
) -> Float {
    let (a, b, c, d, t) = (a.asFloat, b.asFloat, c.asFloat, d.asFloat, t.asFloat)
    guard a.isFinite, b.isFinite, c.isFinite, d.isFinite, t.isFinite else {
        NumberValues.warnOnce(
            .notANumber(.bezierTangent),
            "bezierTangent(): got a value that is not a number, or an infinite one, so 0 was returned"
        )
        return 0
    }
    // 手本の式 `3t²(−a+3b−3c+d) + 6t(a−2b+c) + 3(−a+b)` と同じ多項式を、差の形に畳んで
    // 計算する。端で `3(b−a)`・`3(d−c)` がそのまま出る
    let (da, db, dc, dd, dt) = (Double(a), Double(b), Double(c), Double(d), Double(t))
    let u = 1 - dt
    return Float(3 * (u * u * (db - da) + 2 * u * dt * (dc - db) + dt * dt * (dd - dc)))
}
