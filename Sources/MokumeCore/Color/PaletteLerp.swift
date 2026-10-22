// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

/// ``paletteLerp(_:_:)`` が 1 度だけ言う注意。
///
/// 鍵は口ごとに分ける — ``ColorValues`` と共有すると、先に鳴った口が後の口を永久に黙らせる。
enum PaletteValues {
    enum Warning: Hashable {
        /// `amount` が数でない値・無限だった。
        case notANumber
        /// 区切りが 1 つも無かった (数でない位置を捨てた後を含む)。
        case noStops
        /// 区切りの位置に、数でない値・無限があった。
        case badPosition
    }

    /// 言った注意の控え。書き換えるのは ``warnOnce(_:_:)`` だけ。
    private(set) static var warnings = WarningLog<Warning>()

    static func warnOnce(_ warning: Warning, _ message: @autoclosure () -> String) {
        warnings.warnOnce(warning, message())
    }
}

/// 3 色以上の段から、位置に応じた色を引く。
///
/// 区切りは `(色, 位置)` の並びで、位置は小さいほど手前になる。`amount` が位置の間にあれば、両隣の
/// 区切りの色を ``lerpColor(_:_:_:)`` で混ぜる。
///
/// ```swift
/// background(15, 18, 23)
/// noStroke()
/// let sky: [(LinearRGBA, Float)] = [
///     (color(20, 30, 80), 0), (color(200, 60, 60), 0.6), (color(250, 220, 120), 1),
/// ]
/// for y in 0..<Int(height) {
///     fill(paletteLerp(sky, Float(y) / height))
///     rect(0, y, width, 1)
/// }
/// ```
///
/// 夕焼けの空の帯。3 色の段を高さで引き、上から下へ連続した階調で塗る。区間を探して ``lerpColor(_:_:_:)``
/// を書き分けなくてよい。
///
/// **区切りの規則は勾配 (``Gradient``) と同じ**:
///
/// - 位置の小さい順に並べ直して使う (並べ替えは安定で、同じ位置の 2 つは書いた順)。同じ位置の 2 つの間では
///   色が段になって切り替わり、位置ちょうどでは**後ろの**色になる
/// - 最初の位置より手前は最初の色、最後の位置より先は最後の色のまま伸びる
/// - 区切りが 1 つなら、`amount` によらずその色を返す
///
/// **`amount` は 0…1 に締める** (``lerpColor(_:_:_:)`` と同じ)。`paletteLerp(sky, -1)` は最初の色、
/// `paletteLerp(sky, 2)` は最後の色になる。位置が 0…1 の外にある区切りには、締めた `amount` が届く範囲でしか
/// 届かない — 位置は 0…1 で書く。`amount` が区切りの位置にちょうど着けば、その区切りの色が**ちょうど**返る
/// (同じ位置が並べば後ろの色)。
///
/// **混ぜる空間は線形で、手本 (p5.js) と中間の色が違う。** ``lerpColor(_:_:_:)`` と同じ空間 (線形の光の量・
/// 乗算済みの値) で混ぜるので、黒と白の真ん中は ``red(_:)`` で約 187.5 と読める。p5.js の `paletteLerp` は
/// 今の `colorMode()` の空間で混ぜ、sRGB の符号化した値では中間が 127.5 になる。名前と引数の並び (区切りの並びが先、
/// 割合が後) までが手本に倣った部分で、同じ中間の色が出ることは約束しない ([ADR-0020] 決定 1 の 2026-09-09 改訂)。
/// HSB や OKLCH で混ぜる形は持たない ([ADR-0033] 決定 4)。
///
/// **落ちない** ([ADR-0020] 決定 5)。p5.js は区切りが空だと例外になり、並んでいない位置では割合が負や無限になるが、
/// ここは次のように倒して 1 度だけ知らせる (口ごと)。
///
/// - **区切りが空**: 透明な色を返す
/// - **位置が数でない値・無限の区切り**: その区切りを捨てて読む (全部が捨てられれば、空と同じ)
/// - **`amount` が数でない値・無限**: 最初の区切りの色を返す (``lerpColor(_:_:_:)`` が `start` を返すのと同じ)
///
/// 色の成分は検めない — ``lerpColor(_:_:_:)`` と同じで、数でない成分を持つ色は、受ける口 (`fill(_:)` など) が断る。
///
/// [ADR-0020]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0020-api-naming-and-surface.md
/// [ADR-0033]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0033-color-specification-surface.md
public func paletteLerp(
    _ stops: [(LinearRGBA, Float)], _ amount: some ScalarConvertible
) -> LinearRGBA {
    var usable = stops
    if !stops.allSatisfy({ $0.1.isFinite }) {
        PaletteValues.warnOnce(
            .badPosition,
            "paletteLerp(): got a stop whose position is not a number, or is infinite, so that stop was left out")
        usable = stops.filter { $0.1.isFinite }
    }
    guard !usable.isEmpty else {
        PaletteValues.warnOnce(
            .noStops, "paletteLerp(): got no stops to read a color from, so transparent was returned")
        return .transparent
    }
    // 並んでいれば (ふつうはそう) 並べ直さない。毎フレーム・行ごとに呼ばれる口で、配列を作らない
    if !zip(usable, usable.dropFirst()).allSatisfy({ $0.1 <= $1.1 }) {
        usable = usable.enumerated().sorted {
            $0.element.1 != $1.element.1 ? $0.element.1 < $1.element.1 : $0.offset < $1.offset
        }.map(\.element)
    }

    let given = amount.asFloat
    // 締める前に弾く — Swift の `max` は第 1 引数の NaN をそのまま返すので、締めても NaN は残る
    guard given.isFinite else {
        PaletteValues.warnOnce(
            .notANumber,
            "paletteLerp(): got an amount that is not a number, or an infinite one, so the first stop's color was returned"
        )
        return usable[0].0
    }
    let amount = min(max(given, 0), 1)

    if amount < usable[0].1 { return usable[0].0 }
    for index in usable.indices.dropFirst() {
        let stop = usable[index]
        // 区間 [前の位置, この位置) の中。位置ちょうどは次の区間の始まり (同じ位置が並べば後ろの色)
        guard amount < stop.1 else { continue }
        let previous = usable[index - 1]
        return lerpColor(previous.0, stop.0, (amount - previous.1) / (stop.1 - previous.1))
    }
    return usable[usable.count - 1].0
}
