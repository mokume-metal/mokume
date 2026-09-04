// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import MokumeDiagnostics

/// 0–255 の目盛りと作業空間の間の変換 ([ADR-0033] 決定 1)。
///
/// 素の数値で書かれた色は**ディスプレイのエンコード値を 255 倍したもの**として読む。
/// 線形へ戻す変換そのものは ``TransferFunction`` が持ち、ここは目盛りを合わせるだけ —
/// 変換点は [ADR-0011] 決定 3 の言う入口の 1 箇所のままである。
///
/// **アルファには伝達関数を掛けない。** アルファは光の量ではなく覆いの割合なので、
/// 目盛りを 255 で割るだけでよい。
///
/// [ADR-0011]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0011-color-model.md
/// [ADR-0033]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0033-color-specification-surface.md
enum DisplayScale {
    /// 素の数値の目盛りの上端。
    static let maximum: Float = 255

    /// 0–255 のエンコード値 → 作業空間の線形の値。
    static func linear(_ component: Float) -> Float {
        TransferFunction.decode(component / maximum)
    }

    /// 作業空間の線形の値 → 0–255 のエンコード値。
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

    /// 乗算を戻してから 0–255 の目盛りへ ([ADR-0033] 決定 6 の 3 つの契約)。
    ///
    /// 掛け戻しは ``OutputStage/straighten(_:alpha:)`` を使う — [ADR-0011] 決定 4 は
    /// 戻す点を 1 つに固定しており、ここに 2 つ目の割り算を書かない。
    ///
    /// [ADR-0011]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0011-color-model.md
    /// [ADR-0033]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0033-color-specification-surface.md
    static func readComponent(_ premultiplied: Float, alpha: Float) -> Float {
        guard premultiplied.isFinite, alpha.isFinite else { return 0 }
        return component(OutputStage.straighten(premultiplied, alpha: alpha))
    }

    /// 素の数値から作業空間の色を作る。**非有限の値が混じっていたら作らない。**
    ///
    /// 弾くのは [ADR-0020] 決定 5 (フレームごとに呼ばれるものは投げず、受け口で
    /// 検証して安全側へ倒す) の適用で、`nil` を受けた側が「何もしない」へ倒す。
    /// 0–1 のつもりで書かれた値を推測で咎める仕組みは持たない ([ADR-0033] 決定 9)。
    ///
    /// [ADR-0020]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0020-api-naming-and-surface.md
    /// [ADR-0033]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0033-color-specification-surface.md
    static func color(
        red: Float, green: Float, blue: Float, alpha: Float,
        from entry: String, fallingBackTo effect: String
    ) -> LinearRGBA? {
        guard red.isFinite, green.isFinite, blue.isFinite, alpha.isFinite else {
            warnNotANumberOnce(entry, effect)
            return nil
        }
        return LinearRGBA(
            straightRed: linear(red),
            green: linear(green),
            blue: linear(blue),
            alpha: alpha / maximum)
    }

    /// 何度も言わない — 毎フレーム起きうるので (``Diagnostics/warn(_:)`` の但し書き)。
    static var warnedNotANumber = false

    static func warnNotANumberOnce(_ entry: String, _ effect: String) {
        guard !warnedNotANumber else { return }
        warnedNotANumber = true
        Diagnostics.warn("\(entry): 数でない値・無限の値が渡されたので、\(effect)")
    }
}

// MARK: - 色を作る

/// 色を作る。**素の数値は 0–255** ([ADR-0033] 決定 1)。
///
/// 3 つなら赤・緑・青、4 つ目は不透明度。書いた値は画面で見える明るさの目盛りで、
/// 線形の光の量ではない。
///
/// ```swift
/// let accent = color(255, 204, 0)
/// let veil = color(35, 75, 95, 128)
/// ```
///
/// 描く口へそのまま数値を渡す形 (``Sketch/fill(_:_:_:_:)``) と同じ目盛りなので、
/// 色を変数に持ちたいときだけこちらを使う。
///
/// - Note: 引数は `Float` なので、`Int` の変数はそのまま渡せない (`color(Float(i), 0, 0)`)。
///   `Int` と `Float` の口を並べると、リテラルの書き方で目盛りが変わる罠が入るため
///   ([ADR-0033] 決定 1)。
///
/// [ADR-0033]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0033-color-specification-surface.md
public func color(
    _ red: Float, _ green: Float, _ blue: Float, _ alpha: Float = 255
) -> LinearRGBA {
    DisplayScale.color(
        red: red, green: green, blue: blue, alpha: alpha,
        from: "color()", fallingBackTo: "透明を返しました") ?? .transparent
}

/// 灰色を作る。**素の数値は 0–255**、2 つ目は不透明度。
///
/// ```swift
/// let ash = color(128)
/// let veil = color(0, 64)
/// ```
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
/// [ADR-0033]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0033-color-specification-surface.md
public func red(_ color: LinearRGBA) -> Float {
    DisplayScale.readComponent(color.red, alpha: color.alpha)
}

/// 緑の成分を 0–255 の目盛りで読む。契約は ``red(_:)`` と同じ。
public func green(_ color: LinearRGBA) -> Float {
    DisplayScale.readComponent(color.green, alpha: color.alpha)
}

/// 青の成分を 0–255 の目盛りで読む。契約は ``red(_:)`` と同じ。
public func blue(_ color: LinearRGBA) -> Float {
    DisplayScale.readComponent(color.blue, alpha: color.alpha)
}

/// 不透明度を 0–255 の目盛りで読む。
///
/// **伝達関数を通さない** — 不透明度は光の量ではなく覆いの割合なので、目盛りを
/// 255 倍するだけである。数でない値は 0 へ倒す。
public func alpha(_ color: LinearRGBA) -> Float {
    guard color.alpha.isFinite else { return 0 }
    return color.alpha * DisplayScale.maximum
}
