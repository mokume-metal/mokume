// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation

// SVG の値の文法 — 色・塗り・長さ・変換・CSS。
//
// どれも**読めなければ `nil` を返し、何を読めなかったかは呼ぶ側が名乗る** (``SVGFile/Drawing/skipped``)。
// ここは文字を値にするだけで、どの要素の話かを知らない。
//
// 数は SVG / CSS の数の文法 — 10 進の綴りだけ — で読む。1 つの値を丸ごと数にする所は
// `DecimalText.spelled(_:)`、数を並べた値 (`viewBox`・パス・`transform` の引数) は
// `NumberScanner` を通す。Swift の `Float(String)` は 16 進 (`0x10`) も数にするので直に使わない (#2513)。

extension SVGFile {
    // MARK: - 色

    /// sRGB の成分 (0…1・乗算前) と不透明度。**作業空間へ移すのは置く側** (``Canvas``) で、
    /// `fill(r, g, b)` と同じ入口 (``LinearRGBA/display(red:green:blue:alpha:)``) を通る。
    nonisolated struct Color: Sendable, Equatable {
        var red: Float
        var green: Float
        var blue: Float
        var alpha: Float

        static let black = Color(red: 0, green: 0, blue: 0, alpha: 1)
    }

    /// 色の文字を読む。読むのは `#rgb`・`#rgba`・`#rrggbb`・`#rrggbbaa`・`rgb()` / `rgba()`
    /// (数と百分率)・名前の色 (CSS の 148 色と `transparent`)。大文字と小文字は区別しない。
    nonisolated static func parseColor(_ text: String) -> Color? {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if value.hasPrefix("#") { return hexColor(value.dropFirst()) }
        if value.hasPrefix("rgb") { return functionalColor(value) }
        if value == "transparent" { return Color(red: 0, green: 0, blue: 0, alpha: 0) }
        guard let packed = namedColors[value] else { return nil }
        return Color(
            red: Float((packed >> 16) & 0xFF) / 255, green: Float((packed >> 8) & 0xFF) / 255,
            blue: Float(packed & 0xFF) / 255, alpha: 1)
    }

    /// `#` の後ろの 16 進。3・4・6・8 桁を読む。
    nonisolated private static func hexColor(_ digits: Substring) -> Color? {
        let values = digits.compactMap { $0.hexDigitValue }
        guard values.count == digits.count else { return nil }
        func channel(_ high: Int, _ low: Int) -> Float { Float(high * 16 + low) / 255 }
        switch values.count {
        case 3, 4:
            let alpha = values.count == 4 ? channel(values[3], values[3]) : 1
            return Color(
                red: channel(values[0], values[0]), green: channel(values[1], values[1]),
                blue: channel(values[2], values[2]), alpha: alpha)
        case 6, 8:
            let alpha = values.count == 8 ? channel(values[6], values[7]) : 1
            return Color(
                red: channel(values[0], values[1]), green: channel(values[2], values[3]),
                blue: channel(values[4], values[5]), alpha: alpha)
        default:
            return nil
        }
    }

    /// `rgb(…)` / `rgba(…)`。成分は 0–255 の数か百分率、不透明度は 0–1 の数か百分率。
    /// 区切りはカンマでも空白でもよく、不透明度の前の `/` も受ける (CSS Color 4 の書き方)。
    nonisolated private static func functionalColor(_ value: String) -> Color? {
        guard let open = value.firstIndex(of: "("), value.hasSuffix(")") else { return nil }
        let name = value[..<open].trimmingCharacters(in: .whitespaces)
        guard name == "rgb" || name == "rgba" else { return nil }
        let inside = value[value.index(after: open)..<value.index(before: value.endIndex)]
        // 区切りの空白には改行も数える (`<style>` の値は改行を残して渡る) (#2513)
        let parts = inside.split(whereSeparator: { $0 == "," || $0 == "/" || $0.isWhitespace })
        guard parts.count == 3 || parts.count == 4 else { return nil }
        func component(_ part: Substring, scale: Float) -> Float? {
            if part.hasSuffix("%") {
                guard let percent = DecimalText.spelled(part.dropLast()), percent.isFinite else { return nil }
                return min(max(percent / 100, 0), 1)
            }
            guard let number = DecimalText.spelled(part), number.isFinite else { return nil }
            return min(max(number / scale, 0), 1)
        }
        guard let red = component(parts[0], scale: 255), let green = component(parts[1], scale: 255),
            let blue = component(parts[2], scale: 255)
        else { return nil }
        var alpha: Float = 1
        if parts.count == 4 {
            guard let read = component(parts[3], scale: 1) else { return nil }
            alpha = read
        }
        return Color(red: red, green: green, blue: blue, alpha: alpha)
    }

    // MARK: - 塗り

    /// 塗り (`fill`) と線 (`stroke`) に書ける値。
    nonisolated enum Paint: Sendable, Equatable {
        /// 塗らない。
        case none
        /// その色で塗る。
        case color(Color)
        /// 要素の `color` の値で塗る。
        case currentColor
    }

    /// 塗りの値を読んだ結果。
    nonisolated enum PaintValue: Equatable {
        /// 読めた。
        case paint(Paint)
        /// 親の値を受け継ぐ (`inherit`)。
        case inherit
        /// グラデーションやパターン (`url(#…)`) を指している。**描けないので名乗る。** 後ろに
        /// 書いた代わりの色 (`url(#a) red`) があれば、その色で塗る
        case reference(fallback: Paint)
        /// 読めない。代わりの色が読めない参照 (`url(#a) abc`) も、CSS では宣言ごと無効なのでここ (#2649)
        case unreadable
    }

    nonisolated static func parsePaint(_ text: String) -> PaintValue {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        switch value.lowercased() {
        case "none": return .paint(.none)
        case "currentcolor": return .paint(.currentColor)
        case "inherit": return .inherit
        default: break
        }
        if value.lowercased().hasPrefix("url(") {
            guard let close = value.firstIndex(of: ")") else { return .unreadable }
            let rest = value[value.index(after: close)...].trimmingCharacters(in: .whitespaces)
            if rest.isEmpty { return .reference(fallback: .none) }
            switch parsePaint(rest) {
            case .paint(let fallback): return .reference(fallback: fallback)
            // `inherit`・もう 1 つの参照・読めない値は代わりの色にならず、値ごと読めない (#2649)
            case .inherit, .reference, .unreadable: return .unreadable
            }
        }
        guard let color = parseColor(value) else { return .unreadable }
        return .paint(.color(color))
    }

    // MARK: - display と描けない効果

    /// `display` の値を読み、描くか (`none` だけが偽) を返す。読むのは CSS Display 3 の値 — 1 語の値と、
    /// `<display-outside> || <display-inside>` と `list-item` の 2 語・3 語の組 — と、MathML Core の `math`
    /// (`block math`・`inline math` も)、全体キーワード (`initial`・
    /// `unset`・`revert`・`revert-layer`。どれも描く)。大文字と小文字は区別しない。**読めなければ `nil`**
    /// (`abc`・空・接頭辞つきの `-webkit-box`) — 呼ぶ側が名乗り、無かったものとする (#2650)。
    /// mokume が使うのは描くかどうかだけで、語ごとの意味は持たない。
    nonisolated static func parseDisplay(_ text: String) -> Bool? {
        let words = text.lowercased().split(whereSeparator: \.isWhitespace).map(String.init)
        guard let first = words.first else { return nil }
        if words.count == 1 {
            if first == "none" { return false }
            return displayKeywords.contains(first) || cssWideKeywords.contains(first) ? true : nil
        }
        // 組は語ごとに 1 度まで。`list-item` の中は `flow` か `flow-root` だけ。`list-item` が無ければ外と中の 2 語
        guard words.count <= 3, Set(words).count == words.count else { return nil }
        let outside = words.filter(displayOutside.contains)
        let inside = words.filter(displayInside.contains)
        let listItem = words.contains("list-item")
        guard outside.count <= 1, inside.count <= 1,
            outside.count + inside.count + (listItem ? 1 : 0) == words.count
        else { return nil }
        if listItem { return inside.allSatisfy { $0 == "flow" || $0 == "flow-root" } ? true : nil }
        return true
    }

    /// `display` の 1 語の値 (CSS Display 3 と MathML Core の `math`)。
    nonisolated private static let displayKeywords: Set<String> = [
        "block", "inline", "run-in", "flow", "flow-root", "table", "flex", "grid", "ruby", "list-item", "contents",
        "inline-block", "inline-table", "inline-flex", "inline-grid", "table-row-group", "table-header-group",
        "table-footer-group", "table-row", "table-cell", "table-column-group", "table-column", "table-caption",
        "ruby-base", "ruby-text", "ruby-base-container", "ruby-text-container", "math",
    ]
    nonisolated private static let displayOutside: Set<String> = ["block", "inline", "run-in"]
    nonisolated private static let displayInside: Set<String> = [
        "flow", "flow-root", "table", "flex", "grid", "ruby", "math",
    ]
    /// `inherit` を除く CSS の全体キーワード。
    nonisolated private static let cssWideKeywords: Set<String> = ["initial", "unset", "revert", "revert-layer"]

    /// 描けない効果の性質 (`clip-path`・`mask`・`filter`・`marker` / `marker-start` / `marker-mid` / `marker-end`・
    /// `mix-blend-mode`) の値を読み、効果を持つか (`none`、`mix-blend-mode` は `normal` なら偽) を返す。**読めなければ
    /// `nil`** — 呼ぶ側が名乗り、無かったものとする (#2410)。大文字と小文字は区別しない。読む文法は:
    ///
    /// - `clip-path`: `url(…)`、または基本図形の関数 (`inset()`・`circle()` など) と箱の語 (`fill-box` など) の
    ///   どちらか、または 1 つずつ
    /// - `filter`: `url(…)` とフィルタ関数 (`blur()`・`drop-shadow()` など) の並び
    /// - `marker*`: `url(…)`
    /// - `mix-blend-mode`: CSS Compositing の語
    /// - `mask`: 短縮形の層 (`,` で区切る) の並び。層は画像 (`url(…)`・グラデーションなどの画像の関数・`none`)
    ///   を 1 つまでと、位置・大きさ・繰り返し・箱・合成・`alpha` / `luminance` の語と長さ。**どの層の画像も `none`
    ///   (書いていない) なら切り抜かないので効果なし** (`mask: luminance`)
    ///
    /// 関数の引数は確かめない。
    nonisolated static func parseEffect(_ property: String, _ text: String) -> Bool? {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if property == "mix-blend-mode" {
            if value == "normal" { return false }
            return blendModes.contains(value) ? true : nil
        }
        if value == "none" { return false }
        guard let parts = cssComponents(value), !parts.isEmpty else { return nil }
        if property == "mask" { return maskHasImage(parts) }
        let functions = parts.map(functionName)
        switch property {
        case "clip-path":
            if parts.count == 1, functions[0] == "url" { return true }
            guard parts.count <= 2 else { return nil }
            let shapes = functions.compactMap { $0 }.filter(basicShapes.contains)
            let boxes = zip(parts, functions).filter { $1 == nil && geometryBoxes.contains(String($0)) }
            return shapes.count <= 1 && boxes.count <= 1 && shapes.count + boxes.count == parts.count ? true : nil
        case "filter":
            return functions.allSatisfy { $0 == "url" || $0.map(filterFunctions.contains) == true } ? true : nil
        default:  // marker・marker-start・marker-mid・marker-end
            return parts.count == 1 && functions[0] == "url" ? true : nil
        }
    }

    /// `mask` の短縮形の部品から、画像を持つ層があるかを読む。読めない部品・2 つ目の画像・空の層があれば `nil`。
    nonisolated private static func maskHasImage(_ parts: [Substring]) -> Bool? {
        var hasImage = false
        for layer in parts.split(separator: ",", omittingEmptySubsequences: false) {
            guard !layer.isEmpty else { return nil }
            var images = 0
            for part in layer {
                if part == "none" || functionName(part).map(maskImages.contains) == true {
                    images += 1
                    if part != "none" { hasImage = true }
                } else if functionName(part) != nil {
                    return nil
                } else if !(part == "/" || maskKeywords.contains(String(part))
                    || parseLength(String(part), reference: 1) != nil)
                {
                    return nil
                }
            }
            guard images <= 1 else { return nil }
        }
        return hasImage
    }

    /// `mask` の層の画像になる関数 (`url()` と CSS Images の画像の関数)。
    nonisolated private static let maskImages: Set<String> = [
        "url", "linear-gradient", "radial-gradient", "conic-gradient", "repeating-linear-gradient",
        "repeating-radial-gradient", "repeating-conic-gradient", "image", "image-set", "cross-fade", "element",
        "paint",
    ]
    /// `mask` の層に書ける語 (位置・大きさ・繰り返し・箱・合成・モード)。
    nonisolated private static let maskKeywords: Set<String> = geometryBoxes.union([
        "left", "right", "top", "bottom", "center", "auto", "cover", "contain", "repeat", "repeat-x", "repeat-y",
        "no-repeat", "space", "round", "no-clip", "add", "subtract", "intersect", "exclude", "alpha", "luminance",
        "match-source",
    ])

    nonisolated private static let basicShapes: Set<String> = [
        "inset", "circle", "ellipse", "polygon", "path", "rect", "xywh", "shape",
    ]
    nonisolated private static let geometryBoxes: Set<String> = [
        "fill-box", "stroke-box", "view-box", "margin-box", "border-box", "padding-box", "content-box",
    ]
    nonisolated private static let filterFunctions: Set<String> = [
        "blur", "brightness", "contrast", "drop-shadow", "grayscale", "hue-rotate", "invert", "opacity", "saturate",
        "sepia",
    ]
    nonisolated private static let blendModes: Set<String> = [
        "multiply", "screen", "overlay", "darken", "lighten", "color-dodge", "color-burn", "hard-light",
        "soft-light", "difference", "exclusion", "hue", "saturation", "color", "luminosity", "plus-darker",
        "plus-lighter",
    ]

    /// 値を、括弧の外の空白と、括弧を閉じた所で部品に分ける (`url(#a) fill-box` も `blur(2px)grayscale(1)` も
    /// 2 つ)。括弧の外の `,` と `/` は、それだけで 1 つの部品にする。括弧が釣り合わなければ `nil`。
    nonisolated private static func cssComponents(_ text: String) -> [Substring]? {
        var parts: [Substring] = []
        var depth = 0
        var start: String.Index?
        var index = text.startIndex
        while index < text.endIndex {
            let character = text[index]
            if depth == 0, character.isWhitespace || character == "," || character == "/" {
                if let from = start { parts.append(text[from..<index]) }
                start = nil
                if !character.isWhitespace { parts.append(text[index...index]) }
            } else {
                if start == nil { start = index }
                if character == "(" { depth += 1 }
                if character == ")" {
                    depth -= 1
                    guard depth >= 0 else { return nil }
                    if depth == 0, let from = start {
                        parts.append(text[from...index])
                        start = nil
                    }
                }
            }
            index = text.index(after: index)
        }
        guard depth == 0 else { return nil }
        if let from = start { parts.append(text[from...]) }
        return parts
    }

    /// 部品が関数 (`name(…)`) なら、その名前。
    nonisolated private static func functionName(_ part: Substring) -> String? {
        guard part.hasSuffix(")"), let open = part.firstIndex(of: "(") else { return nil }
        let name = part[..<open]
        guard !name.isEmpty, name.allSatisfy({ $0.isLetter || $0 == "-" }) else { return nil }
        return String(name)
    }

    // MARK: - 長さ

    /// 長さを読む。単位は `px` (と単位なし)・`pt`・`pc`・`mm`・`cm`・`in` と、`%`
    /// (`reference` に対する割合)。読めなければ `nil`。
    ///
    /// `em` / `ex` は字の大きさに依るので読まない (字を描かないので、基準になる大きさが無い)。
    nonisolated static func parseLength(_ text: String, reference: Float) -> Float? {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let units: [(suffix: String, scale: Float)] = [
            ("px", 1), ("pt", 4.0 / 3.0), ("pc", 16), ("mm", 96 / 25.4), ("cm", 96 / 2.54),
            ("in", 96), ("%", 0),
        ]
        for unit in units where value.hasSuffix(unit.suffix) {
            guard let number = DecimalText.spelled(value.dropLast(unit.suffix.count)), number.isFinite else {
                return nil
            }
            return unit.suffix == "%" ? number / 100 * reference : number * unit.scale
        }
        guard let number = DecimalText.spelled(value), number.isFinite else { return nil }
        return number
    }

    /// `stroke-dasharray` の値を読む。`none` は空の並び、ほかは 0 以上の長さ (``parseLength(_:reference:)`` が
    /// 読む単位と `%`) をカンマか空白で区切った並び。**読めない長さ・負の長さ・空の区切り (`5,,3`) を含めば `nil`**
    /// — SVG では宣言ごと無効で、呼ぶ側が名乗って無かったものとする (#2649)。
    nonisolated static func parseDashArray(_ text: String, reference: Float) -> [Float]? {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.lowercased() == "none" { return [] }
        var lengths: [Float] = []
        for part in value.split(separator: ",", omittingEmptySubsequences: false) {
            let words = part.split(whereSeparator: \.isWhitespace)
            guard !words.isEmpty else { return nil }
            for word in words {
                guard let length = parseLength(String(word), reference: reference), length >= 0 else { return nil }
                lengths.append(length)
            }
        }
        return lengths
    }

    // MARK: - 変換

    /// 平面の変換 (SVG の `matrix(a b c d e f)` と同じ 6 つの数)。点 (x, y) は
    /// (a·x + c·y + e, b·x + d·y + f) へ移る。
    nonisolated struct Affine: Sendable, Equatable {
        var a: Float, b: Float, c: Float, d: Float, e: Float, f: Float

        static let identity = Affine(a: 1, b: 0, c: 0, d: 1, e: 0, f: 0)

        static func translate(_ x: Float, _ y: Float) -> Affine {
            Affine(a: 1, b: 0, c: 0, d: 1, e: x, f: y)
        }

        static func scale(_ x: Float, _ y: Float) -> Affine {
            Affine(a: x, b: 0, c: 0, d: y, e: 0, f: 0)
        }

        /// 度で渡す回転。
        static func rotate(degrees: Float) -> Affine {
            let radians = Double(degrees) * .pi / 180
            let cosine = Float(RuntimeMath.cos(radians))
            let sine = Float(RuntimeMath.sin(radians))
            return Affine(a: cosine, b: sine, c: -sine, d: cosine, e: 0, f: 0)
        }

        /// `left` を後から掛ける (`left` の座標系の中に `right` を置く)。SVG の
        /// `transform="A B"` は `A * B` で、点には B が先に掛かる。
        static func * (left: Affine, right: Affine) -> Affine {
            Affine(
                a: left.a * right.a + left.c * right.b,
                b: left.b * right.a + left.d * right.b,
                c: left.a * right.c + left.c * right.d,
                d: left.b * right.c + left.d * right.d,
                e: left.a * right.e + left.c * right.f + left.e,
                f: left.b * right.e + left.d * right.f + left.f)
        }

        /// 点を移す。
        func apply(_ point: SIMD2<Float>) -> SIMD2<Float> {
            SIMD2(a * point.x + c * point.y + e, b * point.x + d * point.y + f)
        }

        /// 逆の変換。つぶれている (行列式が 0 か有限でない) なら `nil`。
        var inverted: Affine? {
            let determinant = a * d - b * c
            guard determinant != 0, determinant.isFinite else { return nil }
            let scaleA = d / determinant
            let scaleB = -b / determinant
            let scaleC = -c / determinant
            let scaleD = a / determinant
            let result = Affine(
                a: scaleA, b: scaleB, c: scaleC, d: scaleD,
                e: -(scaleA * e + scaleC * f), f: -(scaleB * e + scaleD * f))
            return [result.a, result.b, result.c, result.d, result.e, result.f].allSatisfy(\.isFinite) ? result : nil
        }

        /// 長さがいちばん伸びる向きの倍率 (行列の最大の特異値)。曲線をどれだけ細かく刻むかを
        /// 決めるのに使う。
        var largestScale: Float {
            let p = a * a + b * b
            let q = c * c + d * d
            let r = a * c + b * d
            let half = (p + q) / 2
            let spread = (((p - q) / 2) * ((p - q) / 2) + r * r).squareRoot()
            return (half + spread).squareRoot()
        }
    }

    /// `transform` の文字を読む。並べた変換は左から順に掛ける。読めなければ `nil`。
    nonisolated static func parseTransform(_ text: String) -> Affine? {
        var result = Affine.identity
        var rest = Substring(text)
        while true {
            rest = rest.drop { $0.isWhitespace || $0 == "," }
            guard !rest.isEmpty else { return result }
            guard let open = rest.firstIndex(of: "("), let close = rest.firstIndex(of: ")"),
                open < close
            else { return nil }
            // 名前と括弧のあいだの改行 (`translate&#10;(10)`) も空白として落とす (#2513)
            let name = rest[..<open].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard let numbers = parseNumbers(String(rest[rest.index(after: open)..<close])) else {
                return nil
            }
            let step: Affine
            switch (name, numbers.count) {
            case ("matrix", 6):
                step = Affine(
                    a: numbers[0], b: numbers[1], c: numbers[2], d: numbers[3], e: numbers[4],
                    f: numbers[5])
            case ("translate", 1): step = .translate(numbers[0], 0)
            case ("translate", 2): step = .translate(numbers[0], numbers[1])
            case ("scale", 1): step = .scale(numbers[0], numbers[0])
            case ("scale", 2): step = .scale(numbers[0], numbers[1])
            case ("rotate", 1): step = .rotate(degrees: numbers[0])
            case ("rotate", 3):
                step =
                    .translate(numbers[1], numbers[2]) * .rotate(degrees: numbers[0])
                    * .translate(-numbers[1], -numbers[2])
            case ("skewx", 1):
                step = Affine(
                    a: 1, b: 0, c: Float(RuntimeMath.tan(Double(numbers[0]) * .pi / 180)), d: 1, e: 0, f: 0)
            case ("skewy", 1):
                step = Affine(
                    a: 1, b: Float(RuntimeMath.tan(Double(numbers[0]) * .pi / 180)), c: 0, d: 1, e: 0, f: 0)
            default:
                return nil
            }
            result = result * step
            rest = rest[rest.index(after: close)...]
        }
    }

    // MARK: - CSS

    /// 宣言 1 つ (`fill: red !important`)。
    nonisolated struct Declaration: Sendable, Equatable {
        var name: String
        var value: String
        /// `!important` が付いていたか。値からは外してある。
        var isImportant: Bool
    }

    /// `<style>` に書いた規則 1 つ。読むのは**クラス 1 つか要素名 1 つか `*`** のセレクタだけ
    /// (Illustrator の書き出しの既定は `.cls-1 { fill: #e94e1b; }` の形)。
    nonisolated struct StyleRule: Sendable, Equatable {
        nonisolated enum Selector: Sendable, Equatable {
            /// すべての要素 (`*`)。
            case universal
            /// 要素の名前 (`rect`)。
            case element(String)
            /// クラス (`.cls-1`)。
            case className(String)

            /// 詳細度。CSS の (クラス, 要素名) の数を 10 と 1 の位に置いたもの。読むセレクタは
            /// 1 つの部品だけなので桁はあふれない。`*` は数えない。
            var specificity: Int {
                switch self {
                case .universal: 0
                case .element: 1
                case .className: 10
                }
            }

            /// 名前とクラスを持つ要素に当たるか。
            func matches(name: String, classes: Set<String>) -> Bool {
                switch self {
                case .universal: true
                case .element(let element): element == name
                case .className(let className): classes.contains(className)
                }
            }
        }

        var selector: Selector
        /// 宣言を書いた順に。
        var declarations: [Declaration]
    }

    /// 同じ性質に宣言が重なったときの勝ち負け。**CSS Cascade の比べ方 1 つ**で、大きいほうが勝つ。
    /// 比べるのは順に、`!important` か・出どころ・詳細度・書いた順 (後ろが上)。
    ///
    /// 出どころの並びは 属性 < 規則 < `style` 属性で、`!important` の宣言どうしでも変わらない
    /// (属性には `!important` を書けない。`<style>` の `!important` は `style` 属性の `!important` に負ける)。
    nonisolated struct Rank: Sendable, Comparable {
        nonisolated enum Origin: Int, Sendable {
            /// 表現属性 (`fill="red"`)。
            case attribute
            /// `<style>` の規則。
            case rule
            /// `style` 属性。
            case styleAttribute
        }

        var isImportant: Bool
        var origin: Origin
        /// 規則の詳細度 (`StyleRule.Selector.specificity`)。規則でなければ 0。
        var specificity: Int
        /// 宣言を集めた順。
        var order: Int

        static func < (left: Rank, right: Rank) -> Bool {
            (left.isImportant ? 1 : 0, left.origin.rawValue, left.specificity, left.order)
                < (right.isImportant ? 1 : 0, right.origin.rawValue, right.specificity, right.order)
        }
    }

    /// CSS の文字を規則へ分ける。読めない規則 (複合のセレクタ・`@media` など) は描かない
    /// ものとして、その書き出しを返す。読めた規則の中の宣言の形をしていない部分は `unreadDeclarations` に
    /// 返す (読めない規則の中身は、規則ごと名乗るので返さない) (#2649)。
    nonisolated static func parseStyleSheet(_ text: String) -> (
        rules: [StyleRule], unread: [String], unreadDeclarations: [String]
    ) {
        var rules: [StyleRule] = []
        var unread: [String] = []
        var unreadDeclarations: [String] = []
        let source = withoutComments(text)
        var cursor = source.startIndex
        while cursor < source.endIndex {
            guard let open = source[cursor...].firstIndex(of: "{") else { break }
            let prelude = source[cursor..<open].trimmingCharacters(in: .whitespacesAndNewlines)
            // 中括弧の釣り合いを見て、この規則の終わりを探す (`@media` は入れ子を持つ)
            var depth = 0
            var close = open
            var index = open
            while index < source.endIndex {
                if source[index] == "{" { depth += 1 }
                if source[index] == "}" {
                    depth -= 1
                    if depth == 0 {
                        close = index
                        break
                    }
                }
                index = source.index(after: index)
            }
            guard depth == 0 else {
                unread.append(String(prelude.prefix(40)))
                break
            }
            cursor = source.index(after: close)
            if prelude.hasPrefix("@") {
                // 字の形の宣言は字を描かないので黙って飛ばす。ほかの @ 規則は名乗る
                if !prelude.lowercased().hasPrefix("@font-face") { unread.append(String(prelude.prefix(40))) }
                continue
            }
            let body = source[source.index(after: open)..<close]
            let parsed = parseDeclarations(String(body))
            var readsAny = false
            for part in prelude.split(separator: ",") {
                let selector = part.trimmingCharacters(in: .whitespacesAndNewlines)
                if let read = simpleSelector(selector) {
                    rules.append(StyleRule(selector: read, declarations: parsed.declarations))
                    readsAny = true
                } else if !selector.isEmpty {
                    unread.append(selector)
                }
            }
            if readsAny { unreadDeclarations += parsed.unreadable }
        }
        return (rules, unread, unreadDeclarations)
    }

    /// `name: value; …` を宣言の並びにする。値の末尾の `!important` (`!` と `important` の間の空白と
    /// 大文字小文字は問わない) は、値から外して `isImportant` に持たせる。どちらが勝つかは書いた
    /// 場所ではなく、重ねる側の順位 (`Rank`) が決める。
    ///
    /// **宣言の形をしていない部分 (`:` が無い `fill red`・名前が空の `: red`) は `unreadable` に、落とした文字で
    /// 返す** — 呼ぶ側が名乗る (#2649)。空の部分 (`fill: red;;` の間・末尾の `;` の後ろ) は CSS の文法どおりで、返さない。
    nonisolated static func parseDeclarations(_ text: String) -> (declarations: [Declaration], unreadable: [String]) {
        var declarations: [Declaration] = []
        var unreadable: [String] = []
        for part in withoutComments(text).split(separator: ";") {
            let written = part.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !written.isEmpty else { continue }
            guard let colon = part.firstIndex(of: ":"),
                !part[..<colon].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else {
                unreadable.append(written)
                continue
            }
            let name = part[..<colon].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            var value = part[part.index(after: colon)...].trimmingCharacters(in: .whitespacesAndNewlines)
            var isImportant = false
            if let mark = value.lastIndex(of: "!"),
                value[value.index(after: mark)...].trimmingCharacters(in: .whitespacesAndNewlines)
                    .lowercased() == "important"
            {
                isImportant = true
                value = value[..<mark].trimmingCharacters(in: .whitespacesAndNewlines)
            }
            declarations.append(Declaration(name: name, value: value, isImportant: isImportant))
        }
        return (declarations, unreadable)
    }

    /// クラス 1 つか要素名 1 つか `*` のセレクタ。それ以外は `nil`。
    nonisolated private static func simpleSelector(_ text: String) -> StyleRule.Selector? {
        func isNameCharacter(_ character: Character) -> Bool {
            character.isLetter || character.isNumber || character == "-" || character == "_"
        }
        if text == "*" { return .universal }
        if text.hasPrefix(".") {
            let name = text.dropFirst()
            guard !name.isEmpty, name.allSatisfy(isNameCharacter) else { return nil }
            return .className(String(name))
        }
        guard let first = text.first, first.isLetter, text.allSatisfy(isNameCharacter) else { return nil }
        return .element(text)
    }

    /// `/* … */` を落とす。
    nonisolated private static func withoutComments(_ text: String) -> String {
        var result = ""
        var rest = Substring(text)
        while let open = rest.range(of: "/*") {
            result += rest[..<open.lowerBound]
            guard let close = rest[open.upperBound...].range(of: "*/") else { return result }
            rest = rest[close.upperBound...]
        }
        return result + rest
    }
}
