// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import MokumeDiagnostics

/// 0–255 の目盛りと作業空間の間の変換 ([ADR-0033] 決定 1)。
///
/// 素の数値で書かれた色は **sRGB のエンコード値を 255 倍したもの**として読む。
/// 作業空間へ移す変換そのもの (転送関数と原色) は ``LinearRGBA/display(red:green:blue:alpha:)``
/// が持ち、ここは目盛りを合わせるだけ — 変換点は [ADR-0011] 決定 3 の言う入口の 1 箇所の
/// ままである。読み出しは同じ変換を逆にたどる。
///
/// **アルファには伝達関数を掛けない。** アルファは光の量ではなく覆いの割合なので、
/// 目盛りを 255 で割るだけでよい。
///
/// **範囲の外の扱いは成分とアルファで逆になる。** 色の成分は締めない (0–255 は目盛りであって
/// 上限ではない — [ADR-0033] 決定 6) が、アルファは 0–255 に締める (同 決定 3 の改訂)。
/// 締めるのはここではなく、乗算する点 (``LinearRGBA/init(straightRed:green:blue:alpha:)``)
/// である — 0–1 の口 (``LinearRGBA/display(red:green:blue:alpha:)``) から書いた色も同じ値に
/// 揃える。
///
/// [ADR-0011]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0011-color-model.md
/// [ADR-0033]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0033-color-specification-surface.md
enum DisplayScale {
    /// 素の数値の目盛りの上端。
    static let maximum: Float = 255

    /// 線形 sRGB の値 → 0–255 のエンコード値。
    ///
    /// **丸めない。** 範囲の外の値もそのまま返す ([ADR-0033] 決定 6) — 「0–255」は
    /// 目盛りであって上限ではない。出口の ``OutputStage/encodeForDisplay(_:)`` が
    /// 標準レンジへ収めるのとは目的が違う (あちらは画面に出す値を作る)。
    ///
    /// [ADR-0033]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0033-color-specification-surface.md
    static func component(_ linear: Float) -> Float {
        guard linear.isFinite else { return 0 }
        return TransferFunction.encode(linear) * maximum
    }

    /// 乗算を戻し、sRGB の原色へ移してから 0–255 の目盛りへ ([ADR-0033] 決定 6 の 3 つの契約)。
    ///
    /// 掛け戻しは ``OutputStage/straighten(_:alpha:)`` を使う — [ADR-0011] 決定 4 は
    /// 戻す点を 1 つに固定しており、ここに 2 つ目の割り算を書かない。
    ///
    /// **3 成分をまとめて読む。** 原色の行列は成分を混ぜるので、赤だけを読むにも緑と青が
    /// 要る。数でない成分は 0 として混ぜる — 1 つの壊れた成分が、残りの読み出しまで
    /// 数でなくすることはない。
    ///
    /// [ADR-0011]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0011-color-model.md
    /// [ADR-0033]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0033-color-specification-surface.md
    static func readComponents(_ color: LinearRGBA) -> SIMD3<Float> {
        guard color.alpha.isFinite else { return .zero }
        func straight(_ premultiplied: Float) -> Float {
            premultiplied.isFinite ? OutputStage.straighten(premultiplied, alpha: color.alpha) : 0
        }
        let sRGB = ColorPrimaries.sRGB(
            fromWorking: SIMD3(straight(color.red), straight(color.green), straight(color.blue)))
        return SIMD3(component(sRGB.x), component(sRGB.y), component(sRGB.z))
    }

    /// 素の数値から作業空間の色を作る。**非有限の値が混じっていたら作らない。**
    ///
    /// **ここは黙って `nil` を返す。** 何と言うかは受け口が決める — 文面に入る口の名前を
    /// ここへ渡すと、鍵ではなく文字列で注意を数えることになる (``WarningLog`` の但し書き)。
    /// 弾くこと自体は [ADR-0020] 決定 5 の適用で、0–1 のつもりで書かれた値を推測で
    /// 咎める仕組みは持たない ([ADR-0033] 決定 9)。
    ///
    /// [ADR-0020]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0020-api-naming-and-surface.md
    /// [ADR-0033]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0033-color-specification-surface.md
    static func color(red: Float, green: Float, blue: Float, alpha: Float) -> LinearRGBA? {
        guard red.isFinite, green.isFinite, blue.isFinite, alpha.isFinite else { return nil }
        return .display(
            red: red / maximum, green: green / maximum, blue: blue / maximum,
            alpha: alpha / maximum)
    }

    /// 色が元から持つ不透明度に、0–255 の不透明度を**掛ける** (`fill(color, alpha)` /
    /// `stroke(color, alpha)` の形 — [#1553])。**数でない値・無限なら作らない** (``color(red:green:blue:alpha:)`` と
    /// 同じく、何と言うかは受け口が決める)。
    ///
    /// **置き換えずに掛ける。** 手本 (Processing の `colorCalcARGB`) も同じで、乗算済みの 4 成分を
    /// 同じ率で縮めるだけで済む — 割り戻して掛け直す必要が無い ([ADR-0011] 決定 4)。置き換えに
    /// すると、不透明度 0 の色は元の成分を復元できないので黒になる。
    ///
    /// **締めるのは掛ける率で、積ではない。** 率を 0–1 に締めれば、元の色より不透明にも、
    /// 0 より透明にもならない。積だけを締めると、半透明の色に 255 を越える値を渡したとき
    /// 元の色より不透明になる — [ADR-0033] 決定 3 の改訂が退けた「塗りの色を越えて外挿する」
    /// と同じ形である。改訂は締める場所を straight の成分に掛ける点 1 箇所に置いたが、この形は
    /// 乗算済みの色に率を掛けるので、ここが 2 つ目になる。改訂がそう置いた理由 (0–1 の口と
    /// 0–255 の口で同じ色にする) には触れない — この形は 0–255 の口にしか無い。色の成分は
    /// 締めない (決定 6)。
    ///
    /// [#1553]: https://github.com/mokume-metal/mokume/issues/1553
    /// [ADR-0011]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0011-color-model.md
    /// [ADR-0033]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0033-color-specification-surface.md
    static func fading(_ color: LinearRGBA, by alpha: Float) -> LinearRGBA? {
        guard alpha.isFinite else { return nil }
        // 書き順は決定 3 の改訂と揃える (`max` は第 1 引数の NaN をそのまま返す)
        let rate = min(max(alpha / maximum, 0), 1)
        return LinearRGBA(
            premultipliedRed: color.red * rate, green: color.green * rate,
            blue: color.blue * rate, alpha: color.alpha * rate)
    }
}

// MARK: - 値を作る口が言う注意

/// 色の**値**を作る口が 1 度だけ言う注意。
///
/// 描く口の注意は面が持つ (``Canvas/Warning``) が、``color(_:_:_:_:)`` のような値を
/// 作る口には持ち主が無い。鍵で数える形は同じで、控えだけをここに置く ([#833])。
///
/// [#833]: https://github.com/mokume-metal/mokume/issues/833
enum ColorValues {
    /// 1 度だけ言う注意の種類。**口ごとに数える** — 1 つの旗を共有すると、
    /// 先に鳴った口が後の口を永久に黙らせる。
    enum Warning: Hashable {
        /// 素の数値の口に、数でない値・無限の値が渡された。
        case notANumber
        /// 色相・彩度・明度の口に、数でない値・無限の値が渡された。
        case notANumberHSB
    }

    /// 言った注意の控え。書き換えるのは ``warnOnce(_:_:)`` だけ。
    private(set) static var warnings = WarningLog<Warning>()

    static func warnOnce(_ warning: Warning, _ message: @autoclosure () -> String) {
        warnings.warnOnce(warning, message())
    }
}

// MARK: - 色を作る

/// 色を作る。**素の数値は 0–255** ([ADR-0033] 決定 1)。
///
/// 3 つなら赤・緑・青、4 つ目は不透明度。書いた値は画面で見える明るさの目盛りで、
/// 線形の光の量ではない。**原色は sRGB** — 手本の色見本と同じ数から同じ色が出る
/// (作業空間へ移す変換は ``LinearRGBA/display(red:green:blue:alpha:)`` と同じ)。
///
/// ```swift
/// let accent = color(255, 204, 0)
/// let veil = color(35, 75, 95, 128)
/// ```
///
/// 描く口へそのまま数値を渡す形 (``Sketch/fill(_:_:_:_:)``) と同じ目盛りなので、
/// 色を変数に持ちたいときだけこちらを使う。
///
/// **不透明度は 0–255 に締める。色の成分は締めない。** `color(255, 204, 0, 400)` は
/// 不透明度 255 と同じ色になり、`color(510, 0, 0)` の赤は 510 のまま残る
/// ([ADR-0033] 決定 3 の改訂・決定 6)。
///
/// - Note: 引数は `Float` なので、`Int` の変数はそのまま渡せない (`color(Float(i), 0, 0)`)。
///   `Int` と `Float` の口を並べると、リテラルの書き方で目盛りが変わる罠が入るため
///   ([ADR-0033] 決定 1)。
///
/// [ADR-0033]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0033-color-specification-surface.md
public func color(
    _ red: Float, _ green: Float, _ blue: Float, _ alpha: Float = 255
) -> LinearRGBA {
    guard let made = DisplayScale.color(red: red, green: green, blue: blue, alpha: alpha)
    else {
        ColorValues.warnOnce(
            .notANumber,
            "color(): got a value that is not a number, or an infinite one, so transparent was returned")
        return .transparent
    }
    return made
}

/// 灰色を作る。**素の数値は 0–255**、2 つ目は不透明度。
///
/// ```swift
/// let ash = color(128)
/// let veil = color(0, 64)
/// ```
///
/// **不透明度は 0–255 に締める。灰色の値は締めない** (``color(_:_:_:_:)`` と同じ)。
public func color(_ gray: Float, _ alpha: Float = 255) -> LinearRGBA {
    color(gray, gray, gray, alpha)
}

/// 16 進の綴りから色を作る。
///
/// ```swift
/// let amber = color(hex: 0xFF_CC00)
/// ```
///
/// 読むのは下位 24 bit で、上位は落とす。手本 (Processing) の習慣で不透明度を
/// 上位バイトに付けた `0xFFFF_CC00` を渡しても、色は同じ `0xFF_CC00` になる。
/// 不透明度を変えたいときは ``color(_:_:_:_:)`` を使う。
public func color(hex: Int) -> LinearRGBA {
    let bits = hex & 0xFF_FFFF
    return color(
        Float((bits >> 16) & 0xFF), Float((bits >> 8) & 0xFF), Float(bits & 0xFF))
}

// MARK: - 色を読む

/// 赤の成分を **0–255 の目盛り**で読む ([ADR-0033] 決定 6)。
///
/// ```swift
/// let picked = get(10, 10)
/// let warmth = red(picked) - blue(picked)
/// ```
///
/// 返す値には 3 つの契約がある。**不透明度が 0 の色は 0 を返す** (乗算済みの表現から
/// 元の色は復元できない)。**範囲の外は丸めない** — `red(color(510, 0, 0))` は 510 を
/// 返す。**数でない値は 0 へ倒す**。
///
/// 値は ``color(_:_:_:_:)`` と同じ **sRGB の原色**の目盛りで返す (作業空間から sRGB へ
/// 移してから読む — [ADR-0011] 決定 3)。だから `red(color(255, 204, 0))` は 255 に戻る。
/// sRGB の外にある作業空間の色は、負や 255 を超える値として読める。
///
/// [ADR-0011]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0011-color-model.md
/// [ADR-0033]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0033-color-specification-surface.md
public func red(_ color: LinearRGBA) -> Float {
    DisplayScale.readComponents(color).x
}

/// 緑の成分を 0–255 の目盛りで読む。契約は ``red(_:)`` と同じ。
public func green(_ color: LinearRGBA) -> Float {
    DisplayScale.readComponents(color).y
}

/// 青の成分を 0–255 の目盛りで読む。契約は ``red(_:)`` と同じ。
public func blue(_ color: LinearRGBA) -> Float {
    DisplayScale.readComponents(color).z
}

/// 不透明度を 0–255 の目盛りで読む。
///
/// **伝達関数を通さない** — 不透明度は光の量ではなく覆いの割合なので、目盛りを
/// 255 倍するだけである。数でない値は 0 へ倒す。
///
/// **書いた不透明度は 0–255 に締まっている** — `alpha(color(0, 0, 0, 400))` は 255、
/// `alpha(color(0, 0, 0, -100))` は 0 を返す。色の成分は締めないので、``red(_:)`` は
/// 範囲の外の値も返す ([ADR-0033] 決定 3 の改訂・決定 6)。乗算済みの口
/// (``LinearRGBA/init(premultipliedRed:green:blue:alpha:)``) で作った色は締めずに読む。
///
/// [ADR-0033]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0033-color-specification-surface.md
public func alpha(_ color: LinearRGBA) -> Float {
    guard color.alpha.isFinite else { return 0 }
    return color.alpha * DisplayScale.maximum
}
