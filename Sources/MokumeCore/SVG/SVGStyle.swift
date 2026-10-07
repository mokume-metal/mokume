// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation

// SVG の値の文法 — 色・塗り・長さ・変換・CSS。
//
// どれも**読めなければ `nil` を返し、何を読めなかったかは呼ぶ側が名乗る** (``SVGFile/Drawing/skipped``)。
// ここは文字を値にするだけで、どの要素の話かを知らない。

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
        let parts = inside.split(whereSeparator: { $0 == "," || $0 == " " || $0 == "/" || $0 == "\t" })
        guard parts.count == 3 || parts.count == 4 else { return nil }
        func component(_ part: Substring, scale: Float) -> Float? {
            if part.hasSuffix("%") {
                guard let percent = Float(part.dropLast()), percent.isFinite else { return nil }
                return min(max(percent / 100, 0), 1)
            }
            guard let number = Float(part), number.isFinite else { return nil }
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
        /// 読めない。
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
            default: return .reference(fallback: .none)
            }
        }
        guard let color = parseColor(value) else { return .unreadable }
        return .paint(.color(color))
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
            guard let number = Float(value.dropLast(unit.suffix.count)), number.isFinite else { return nil }
            return unit.suffix == "%" ? number / 100 * reference : number * unit.scale
        }
        guard let number = Float(value), number.isFinite else { return nil }
        return number
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
            let cosine = Float(cos(radians))
            let sine = Float(sin(radians))
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
            let name = rest[..<open].trimmingCharacters(in: .whitespaces).lowercased()
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
                    a: 1, b: 0, c: Float(tan(Double(numbers[0]) * .pi / 180)), d: 1, e: 0, f: 0)
            case ("skewy", 1):
                step = Affine(
                    a: 1, b: Float(tan(Double(numbers[0]) * .pi / 180)), c: 0, d: 1, e: 0, f: 0)
            default:
                return nil
            }
            result = result * step
            rest = rest[rest.index(after: close)...]
        }
    }

    // MARK: - CSS

    /// `<style>` に書いた規則 1 つ。読むのは**クラス 1 つか要素名 1 つ**のセレクタだけ
    /// (Illustrator の書き出しの既定は `.cls-1 { fill: #e94e1b; }` の形)。
    nonisolated struct StyleRule: Sendable, Equatable {
        enum Selector: Sendable, Equatable {
            /// 要素の名前 (`rect`)。`*` はすべての要素。
            case element(String)
            /// クラス (`.cls-1`)。
            case className(String)
        }

        var selector: Selector
        /// 宣言を書いた順に。
        var declarations: [(name: String, value: String)]

        static func == (left: StyleRule, right: StyleRule) -> Bool {
            left.selector == right.selector
                && left.declarations.map(\.name) == right.declarations.map(\.name)
                && left.declarations.map(\.value) == right.declarations.map(\.value)
        }
    }

    /// CSS の文字を規則へ分ける。読めない規則 (複合のセレクタ・`@media` など) は描かない
    /// ものとして、その書き出しを返す。
    nonisolated static func parseStyleSheet(_ text: String) -> (rules: [StyleRule], unread: [String]) {
        var rules: [StyleRule] = []
        var unread: [String] = []
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
            let declarations = parseDeclarations(String(body))
            for part in prelude.split(separator: ",") {
                let selector = part.trimmingCharacters(in: .whitespacesAndNewlines)
                if let read = simpleSelector(selector) {
                    rules.append(StyleRule(selector: read, declarations: declarations))
                } else if !selector.isEmpty {
                    unread.append(selector)
                }
            }
        }
        return (rules, unread)
    }

    /// `name: value; …` を宣言の並びにする。`!important` は落とす (優先の順は書いた場所で決める)。
    nonisolated static func parseDeclarations(_ text: String) -> [(name: String, value: String)] {
        var declarations: [(name: String, value: String)] = []
        for part in withoutComments(text).split(separator: ";") {
            guard let colon = part.firstIndex(of: ":") else { continue }
            let name = part[..<colon].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            var value = part[part.index(after: colon)...].trimmingCharacters(in: .whitespacesAndNewlines)
            if let important = value.range(of: "!important", options: .caseInsensitive) {
                value = value[..<important.lowerBound].trimmingCharacters(in: .whitespaces)
            }
            guard !name.isEmpty else { continue }
            declarations.append((name, value))
        }
        return declarations
    }

    /// クラス 1 つか要素名 1 つのセレクタ。それ以外は `nil`。
    nonisolated private static func simpleSelector(_ text: String) -> StyleRule.Selector? {
        func isNameCharacter(_ character: Character) -> Bool {
            character.isLetter || character.isNumber || character == "-" || character == "_"
        }
        if text == "*" { return .element("*") }
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
