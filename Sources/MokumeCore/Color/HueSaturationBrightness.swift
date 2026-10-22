// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

/// 色相・彩度・明度と、0–255 のエンコード値との間の変換 ([ADR-0033] 決定 5)。
///
/// 目盛りは**量ごとの慣習**に従う — 色相は 0–360 の度、彩度と明度は 0–100 の
/// 百分率。手本が割れている (Processing は 3 成分とも 0–255、p5 は 360/100/100)
/// ので、どちらかを写すのではなく、その量について世の中が使っている単位を採る。
///
/// 範囲の外の扱いは量ごとに違う。**色相は巻き戻し**、**彩度と明度の上側は通し**、
/// **下側 (負) だけ 0 へ丸める** — 負にすると最大の成分が入れ替わって色相が
/// 180 度反転し、値を保つのではなく引数の意味が変わってしまうためである。
///
/// [ADR-0033]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0033-color-specification-surface.md
enum HueSaturationBrightness {
    /// 色相の 1 周。
    static let turn: Float = 360
    /// 彩度・明度の目盛りの上端。
    static let percent: Float = 100

    /// 0 以上 360 未満 (半開区間) へ巻き戻す。**360 は返さない。**
    ///
    /// 巻き戻しは ``mod(_:_:)`` と同じ計算 (``foldedIntoPeriod(_:by:)``) を通す。負の入力へ
    /// 負を返す `truncatingRemainder` を直に使うと `hue: -40` が区画の添字を負にする。
    /// `color(hue: Float(frameCount), …)` を剰余なしで書けることがこの口の値打ちなので、負の側も
    /// 畳む。絶対値が 1.5e-5 ほどより小さい負の値に 360 を足すと Float では 360.0 ちょうどに
    /// 丸まるが、その値は 0 へ畳む — 赤の色相は作業空間との往復の残差でそういう値になり、畳まないと
    /// 1 周ぶんずれた 360 が読み出される (#1533)。
    ///
    /// **数でない値・無限の値は 0 を返す。** ``mod(_:_:)`` を直に呼ぶと、こちらの呼び出しの
    /// 名で注意が鳴るので、中の計算だけを通す。呼ぶ側 (``components(hue:saturation:brightness:)``) は
    /// 先に弾いているので、ここへは来ない。
    static func wrapped(_ hue: Float) -> Float {
        hue.isFinite ? foldedIntoPeriod(hue, by: turn) : 0
    }

    /// 色相・彩度・明度 → 0–255 のエンコード値。**非有限の値は受け取らない。**
    ///
    /// 区画の添字は `Int(hue / 60)` で取るので、無限・NaN のまま進むと変換で trap する。
    /// 投げないこと ([ADR-0020] 決定 5) より悪いので、呼ぶ前に弾く。
    ///
    /// [ADR-0020]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0020-api-naming-and-surface.md
    static func components(hue: Float, saturation: Float, brightness: Float)
        -> (red: Float, green: Float, blue: Float)
    {
        let angle = wrapped(hue)
        let s = max(saturation, 0) / percent
        let v = max(brightness, 0) / percent

        let chroma = v * s
        let position = angle / 60
        let sector = min(Int(position), 5)
        let second = chroma * (1 - abs(position.truncatingRemainder(dividingBy: 2) - 1))
        let base = v - chroma

        let (red, green, blue): (Float, Float, Float) =
            switch sector {
            case 0: (chroma, second, 0)
            case 1: (second, chroma, 0)
            case 2: (0, chroma, second)
            case 3: (0, second, chroma)
            case 4: (second, 0, chroma)
            default: (chroma, 0, second)
            }
        return (
            (red + base) * DisplayScale.maximum,
            (green + base) * DisplayScale.maximum,
            (blue + base) * DisplayScale.maximum)
    }

    /// 0–255 のエンコード値 → 色相・彩度・明度。
    static func values(red: Float, green: Float, blue: Float)
        -> (hue: Float, saturation: Float, brightness: Float)
    {
        let r = red / DisplayScale.maximum
        let g = green / DisplayScale.maximum
        let b = blue / DisplayScale.maximum
        let highest = max(r, g, b)
        let lowest = min(r, g, b)
        let chroma = highest - lowest

        var angle: Float = 0
        if chroma > 0 {
            if highest == r {
                angle = 60 * ((g - b) / chroma).truncatingRemainder(dividingBy: 6)
            } else if highest == g {
                angle = 60 * ((b - r) / chroma + 2)
            } else {
                angle = 60 * ((r - g) / chroma + 4)
            }
        }
        let saturation = highest > 0 ? chroma / highest : 0
        return (wrapped(angle), saturation * percent, highest * percent)
    }
}

// MARK: - 色相・彩度・明度で作る

/// 色相・彩度・明度から色を作る ([ADR-0033] 決定 5)。
///
/// **目盛りは量ごとの慣習に従う** — `hue` は 0–360 の度、`saturation` と
/// `brightness` は 0–100 の百分率、`alpha` だけは他の形と揃えて 0–255。
///
/// ```swift
/// background(color(hue: 220, saturation: 40, brightness: 12))
/// fill(color(hue: 45, saturation: 100, brightness: 100))
/// ```
///
/// **色相は巻き戻る。** `hue: 380` は `20`、`hue: -40` は `320` と同じ色になるので、
/// フレーム番号や角度をそのまま渡せる (剰余を書かなくてよい)。
///
/// ```swift
/// fill(color(hue: Float(frameCount), saturation: 70, brightness: 95))
/// ```
///
/// **彩度と明度は上へ突き抜けられる。** `brightness: 150` は表示範囲を超えた明るさ、
/// `saturation: 120` は色域の外の色を指す — 作業空間はどちらも保つ ([ADR-0011] 決定 1)。
/// 負の値だけは 0 として扱う (負にすると色相が 180 度回ってしまい、値を保つのではなく
/// 引数の意味が変わるため)。**丸めたときは、1 度だけ知らせる** (`saturation: -20` なら、彩度が 0 以上を
/// 取ることと、渡した値と、0 を使ったことを言う。彩度・明度・不透明度は別々に数える)。
///
/// **不透明度は 0–255 に締める** (``color(_:_:_:_:)`` と同じ)。`alpha: 400` は 255 と同じ色になり、
/// 締めたときは 1 度だけ知らせる ([ADR-0033] 決定 3 の改訂)。
///
/// [ADR-0011]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0011-color-model.md
/// [ADR-0033]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0033-color-specification-surface.md
public func color(
    hue: some ScalarConvertible, saturation: some ScalarConvertible, brightness: some ScalarConvertible,
    alpha: some ScalarConvertible = 255
) -> Color {
    let (hue, saturation, brightness) = (hue.asFloat, saturation.asFloat, brightness.asFloat)
    let alpha = alpha.asFloat
    guard hue.isFinite, saturation.isFinite, brightness.isFinite else {
        ColorValues.warnOnce(
            .notANumberHSB,
            "color(hue:saturation:brightness:): got a value that is not a number, or an infinite "
                + "one, so transparent was returned")
        return .transparent
    }
    // 丸めたことを言う ([#1842])。上へ突き抜ける値は丸めないので言わない
    let name = "color(hue:saturation:brightness:)"
    if saturation < 0 {
        ColorValues.warnRounded(
            .roundedSaturation, name, "saturation", takes: "0 or more", passed: saturation, used: 0)
    }
    if brightness < 0 {
        ColorValues.warnRounded(
            .roundedBrightness, name, "brightness", takes: "0 or more", passed: brightness, used: 0)
    }
    ColorValues.warnIfOpacityRounded(.roundedHSBOpacity, name, passed: alpha)
    let parts = HueSaturationBrightness.components(
        hue: hue, saturation: saturation, brightness: brightness)
    return makeColor(red: parts.red, green: parts.green, blue: parts.blue, alpha: alpha)
}

// MARK: - 色相・彩度・明度で読む

/// 色相を **0–360 の度**で読む ([ADR-0033] 決定 6)。
///
/// 返る値は **0 以上 360 未満**で、360 は返らない。赤は 0 になるので、
/// `Int(hue(c) / 360 * n)` で区画を引いても添字は `0..<n` に収まる。
///
/// 灰色 (彩度 0) の色相は決まらないので 0 を返す。不透明度が 0 の色と、数でない値を
/// 持つ色も 0 になる — 契約は ``red(_:)`` と同じ。
///
/// [ADR-0033]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0033-color-specification-surface.md
public func hue(_ color: Color) -> Float {
    values(of: color).hue
}

/// 彩度を **0–100 の百分率**で読む。契約は ``hue(_:)`` と同じ。
///
/// 色域の外の色では 100 を超えることがある (書いた値が保たれているため)。
public func saturation(_ color: Color) -> Float {
    values(of: color).saturation
}

/// 明度を **0–100 の百分率**で読む。契約は ``hue(_:)`` と同じ。
///
/// 表示範囲を超えた明るさでは 100 を超えることがある。
public func brightness(_ color: Color) -> Float {
    values(of: color).brightness
}

/// **色を読むのは 1 度だけ** ([#1787])。``red(_:)`` / ``green(_:)`` / ``blue(_:)`` はどれも
/// 3 成分をまとめて読んで 1 つを取り出すので、3 つを別々に呼ぶと同じ読み取り (割り戻し・
/// 原色の行列・伝達関数 3 回) を 3 度払う。まとめて読んだ 3 成分は、別々に読んだ値と同じ。
///
/// [#1787]: https://github.com/mokume-metal/mokume/issues/1787
private func values(of color: Color)
    -> (hue: Float, saturation: Float, brightness: Float)
{
    let components = DisplayScale.readComponents(color)
    return HueSaturationBrightness.values(
        red: components.x, green: components.y, blue: components.z)
}
