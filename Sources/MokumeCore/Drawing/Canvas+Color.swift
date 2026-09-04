// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT
//
// 素の数値で色を指定する口 (ADR-0033 決定 1)。下の層にも同じ綴りを置くのは、
// 上で書けて下で書けない食い違いを作らないため (同 決定 8)。
//
// **説明文は置かない。** 正本は上の層 (ADR-0020 決定 4) で、api-surface.py の
// slash_doc は宣言の直前に積んだ `//` も説明文として拾う。この覚え書きが
// 拾われないよう、宣言との間は必ず 1 行空ける。

extension Canvas {
    public func background(_ gray: Float, _ alpha: Float = 255) {
        background(gray, gray, gray, alpha)
    }

    public func background(
        _ red: Float, _ green: Float, _ blue: Float, _ alpha: Float = 255
    ) {
        guard let color = DisplayScale.color(
            red: red, green: green, blue: blue, alpha: alpha,
            from: "background()", fallingBackTo: "色を変えませんでした")
        else { return }
        background(color)
    }

    public func fill(_ gray: Float, _ alpha: Float = 255) {
        fill(gray, gray, gray, alpha)
    }

    public func fill(_ red: Float, _ green: Float, _ blue: Float, _ alpha: Float = 255) {
        guard let color = DisplayScale.color(
            red: red, green: green, blue: blue, alpha: alpha,
            from: "fill()", fallingBackTo: "色を変えませんでした")
        else { return }
        fill(color)
    }

    public func stroke(_ gray: Float, _ alpha: Float = 255) {
        stroke(gray, gray, gray, alpha)
    }

    public func stroke(_ red: Float, _ green: Float, _ blue: Float, _ alpha: Float = 255) {
        guard let color = DisplayScale.color(
            red: red, green: green, blue: blue, alpha: alpha,
            from: "stroke()", fallingBackTo: "色を変えませんでした")
        else { return }
        stroke(color)
    }

    public func tint(_ gray: Float, _ alpha: Float = 255) {
        tint(gray, gray, gray, alpha)
    }

    public func tint(_ red: Float, _ green: Float, _ blue: Float, _ alpha: Float = 255) {
        guard let color = DisplayScale.color(
            red: red, green: green, blue: blue, alpha: alpha,
            from: "tint()", fallingBackTo: "色を変えませんでした")
        else { return }
        tint(color)
    }
}
