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

    /// 0–360 の内側へ巻き戻す。
    ///
    /// **切り捨ての剰余は使わない。** `truncatingRemainder` は負の入力に負を返すので、
    /// `hue: -40` が区画の添字を負にする。`color(hue: Float(frameCount), …)` を
    /// 剰余なしで書けることがこの口の値打ちなので、負の側も畳む。
    static func wrapped(_ hue: Float) -> Float {
        let remainder = hue.truncatingRemainder(dividingBy: turn)
        return remainder < 0 ? remainder + turn : remainder
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
/// 引数の意味が変わるため)。
///
/// [ADR-0011]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0011-color-model.md
/// [ADR-0033]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0033-color-specification-surface.md
public func color(
    hue: Float, saturation: Float, brightness: Float, alpha: Float = 255
) -> LinearRGBA {
    guard hue.isFinite, saturation.isFinite, brightness.isFinite else {
        ColorValues.warnOnce(
            .notANumberHSB,
            "color(hue:saturation:brightness:): 数でない値・無限の値が渡されたので、透明を返しました")
        return .transparent
    }
    let parts = HueSaturationBrightness.components(
        hue: hue, saturation: saturation, brightness: brightness)
    return color(parts.red, parts.green, parts.blue, alpha)
}

// MARK: - 色相・彩度・明度で読む

/// 色相を **0–360 の度**で読む ([ADR-0033] 決定 6)。
///
/// 灰色 (彩度 0) の色相は決まらないので 0 を返す。不透明度が 0 の色と、数でない値を
/// 持つ色も 0 になる — 契約は ``red(_:)`` と同じ。
///
/// [ADR-0033]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0033-color-specification-surface.md
public func hue(_ color: LinearRGBA) -> Float {
    values(of: color).hue
}

/// 彩度を **0–100 の百分率**で読む。契約は ``hue(_:)`` と同じ。
///
/// 色域の外の色では 100 を超えることがある (書いた値が保たれているため)。
public func saturation(_ color: LinearRGBA) -> Float {
    values(of: color).saturation
}

/// 明度を **0–100 の百分率**で読む。契約は ``hue(_:)`` と同じ。
///
/// 表示範囲を超えた明るさでは 100 を超えることがある。
public func brightness(_ color: LinearRGBA) -> Float {
    values(of: color).brightness
}

private func values(of color: LinearRGBA)
    -> (hue: Float, saturation: Float, brightness: Float)
{
    HueSaturationBrightness.values(
        red: red(color), green: green(color), blue: blue(color))
}
