// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import CoreText
import Foundation

/// 書体の太さの物差しと、頼んだ太さへの寄せ方 ([#2445])。
///
/// ## 物差し
///
/// **太さは CSS の 100〜900 で数える。** CoreText が面に付ける太さ (`kCTFontWeightTrait`、
/// -1〜1) は、`UltraLight` -0.8・`Regular` 0・`Bold` 0.4・`Black` 0.62 のように、段の間隔が
/// 揃っていない。受け口 (``Canvas/textWeight(_:)``) は p5.js と同じ 100〜900 で、可変書体の
/// `wght` 軸もほとんどはこの数え方なので、面の太さを CSS の数へ写してから比べる
/// (``css(fromCoreText:)``)。
///
/// ## 寄せ方
///
/// - **`wght` 軸を持つ面は、軸を動かす。** 軸の範囲へ締める (``used``)。
/// - **持たない面は、同じ書体の面のうち最も近い太さの面を取る** (``nearest(among:weight:italic:)``)。
///   傾きが合う面を先に絞る。
///
/// [#2445]: https://github.com/mokume-metal/mokume/issues/2445
nonisolated enum TypefaceWeight {
    /// 可変書体の太さの軸の識別子 (`wght` の 4 文字を数にしたもの)。
    static let axisIdentifier = 0x7767_6874
    /// ``Canvas/textWeight(_:)`` が受ける範囲。
    static let range = 100...900
    /// 太さを頼まれたとき、頼んだ太さと使った太さがこの差を越えて離れたら、知らせる。
    /// 500 に Regular (400) を使う程度は、書体の面の粒度の範囲である。
    static let noticeableGap = 100
    /// ``TextStyle/bold`` が頼む太さ。
    static let bold = 700
    /// 何も頼まないときの太さ。
    static let regular = 400

    /// 面の太さと傾き。
    struct Trait: Equatable {
        /// CSS の数で数えた太さ (100〜900。範囲の外にも出うる)。
        var weight: Double
        var italic: Bool
    }

    /// CoreText の太さの印 (`UltraLight` から `Black` まで) と CSS の数の対応。折れ線で結ぶ。
    private static let anchors: [(coreText: Double, css: Double)] = [
        (-0.8, 100), (-0.6, 200), (-0.4, 300), (0, 400), (0.23, 500), (0.3, 600),
        (0.4, 700), (0.56, 800), (0.62, 900),
    ]

    /// CoreText の太さの印を、CSS の数へ写す。端の外は端に揃える。
    static func css(fromCoreText value: Double) -> Double {
        guard let first = anchors.first, let last = anchors.last else { return 400 }
        if value <= first.coreText { return first.css }
        if value >= last.coreText { return last.css }
        for (low, high) in zip(anchors, anchors.dropFirst()) where value <= high.coreText {
            let ratio = (value - low.coreText) / (high.coreText - low.coreText)
            return low.css + ratio * (high.css - low.css)
        }
        return last.css
    }

    /// 受け口へ渡された値を、整数の太さにして範囲へ締める。
    ///
    /// **丸めてから締める** — `500.4` と `500.2` は同じ太さで、焼き場の鍵も同じになる (#2445 の条件 4)。
    static func clamped(_ value: Float) -> (weight: Int, wasOutside: Bool) {
        // 整数へ直す前に締める — `Float` の大きな値を `Int` へ直すと落ちる
        let rounded = value.rounded()
        let weight = min(max(rounded, Float(range.lowerBound)), Float(range.upperBound))
        return (Int(weight), weight != rounded)
    }

    /// 面の候補のうち、頼んだ太さに最も近いものの番号。候補が無ければ `nil`。
    ///
    /// **傾きが合う面を先に絞る。** 絞って 1 つも残らなければ、傾きは諦めて全部から選ぶ (呼ぶ側が
    /// 傾きを得られなかったことを知らせる)。太さが同じだけ離れた 2 面は、頼んだ太さが 500 以下なら軽い方、
    /// より重いなら重い方を取る。それでも同じなら、先に並んでいる面。
    ///
    /// **面の引き方を CoreText から切り離してある** — どの機械でも同じ答えを返す合成の材料で検査できる
    /// (``Typeface/styledFace(of:traits:copy:)`` と同じ作り)。
    static func nearest(among faces: [Trait], weight: Int, italic: Bool) -> Int? {
        guard !faces.isEmpty else { return nil }
        var pool = faces.indices.filter { faces[$0].italic == italic }
        if pool.isEmpty { pool = Array(faces.indices) }
        let wanted = Double(weight)
        var best = pool[0]
        for index in pool.dropFirst() {
            let gap = abs(faces[index].weight - wanted)
            let bestGap = abs(faces[best].weight - wanted)
            if gap < bestGap - 1e-9 {
                best = index
            } else if abs(gap - bestGap) <= 1e-9, faces[index].weight != faces[best].weight {
                let lighter = faces[index].weight < faces[best].weight
                if lighter == (weight <= 500) { best = index }
            }
        }
        return best
    }

    /// 面の太さと傾きを、CoreText の記述子から読む。
    static func trait(of font: CTFont) -> Trait {
        let traits = CTFontCopyTraits(font) as NSDictionary
        let coreText = (traits[kCTFontWeightTrait as String] as? NSNumber)?.doubleValue ?? 0
        return Trait(
            weight: css(fromCoreText: coreText),
            italic: CTFontGetSymbolicTraits(font).contains(.traitItalic))
    }

    // MARK: - 可変書体

    /// 面の軸のうち、太さの軸とその範囲。軸の無い (可変でない) 面は `nil`。
    static func weightAxis(of font: CTFont) -> ClosedRange<Double>? {
        for axis in axes(of: font) where axis.identifier == axisIdentifier {
            return axis.minimum...axis.maximum
        }
        return nil
    }

    /// 面が持つ軸。可変でなければ空。
    static func axes(of font: CTFont) -> [Axis] {
        guard let found = CTFontCopyVariationAxes(font) as? [[String: Any]] else { return [] }
        return found.compactMap { entry in
            guard let identifier = (entry[kCTFontVariationAxisIdentifierKey as String] as? NSNumber)?.intValue,
                let minimum = (entry[kCTFontVariationAxisMinimumValueKey as String] as? NSNumber)?.doubleValue,
                let maximum = (entry[kCTFontVariationAxisMaximumValueKey as String] as? NSNumber)?.doubleValue,
                let initial = (entry[kCTFontVariationAxisDefaultValueKey as String] as? NSNumber)?.doubleValue
            else { return nil }
            return Axis(identifier: identifier, minimum: minimum, maximum: maximum, initial: initial)
        }
    }

    struct Axis: Equatable {
        var identifier: Int
        var minimum: Double
        var maximum: Double
        var initial: Double
    }

    /// 軸の値を指して、面の写しを作る。指さなかった軸は面のいまの値のまま。
    static func copy(of font: CTFont, size: CGFloat, axes values: [Int: Double]) -> CTFont {
        let variation = Dictionary(
            uniqueKeysWithValues: values.map { (NSNumber(value: $0.key), NSNumber(value: $0.value)) })
        let descriptor = CTFontDescriptorCreateWithAttributes(
            [kCTFontVariationAttribute as String: variation] as CFDictionary)
        return CTFontCreateCopyWithAttributes(font, size, nil, descriptor)
    }

    // MARK: - 面を頼んだ太さへ寄せる

    /// 寄せた結果。
    struct Weighted {
        var font: CTFont
        /// 使った太さ (CSS の数)。軸を動かしたなら締めた後の値、面を選んだなら面の太さ。
        var used: Int
    }

    /// 面を、頼んだ太さへ寄せる。
    ///
    /// - 太さの軸を持つ面は、軸を動かす。軸の外の値は範囲へ締める。
    /// - 持たない面は、同じ家族の面 (``familyFaces(of:size:)``) から、最も近い太さの面を取る。
    static func weighted(_ font: CTFont, weight: Int) -> Weighted {
        let size = CTFontGetSize(font)
        if let axis = weightAxis(of: font) {
            let value = min(max(Double(weight), axis.lowerBound), axis.upperBound)
            return Weighted(
                font: copy(of: font, size: size, axes: [axisIdentifier: value]),
                used: Int(value.rounded()))
        }
        let candidates = familyFaces(of: font, size: size)
        let traits = candidates.map(trait(of:))
        let italic = CTFontGetSymbolicTraits(font).contains(.traitItalic)
        guard let index = nearest(among: traits, weight: weight, italic: italic) else {
            return Weighted(font: font, used: Int(trait(of: font).weight.rounded()))
        }
        return Weighted(font: candidates[index], used: Int(traits[index].weight.rounded()))
    }

    /// 面と同じ家族の面。家族を引けなければ、面自身だけ。
    static func familyFaces(of font: CTFont, size: CGFloat) -> [CTFont] {
        let family = CTFontCopyFamilyName(font) as String
        let query = CTFontDescriptorCreateWithAttributes(
            [kCTFontFamilyNameAttribute as String: family] as CFDictionary)
        let found = CTFontDescriptorCreateMatchingFontDescriptors(query, nil) as? [CTFontDescriptor] ?? []
        let faces = found.map { CTFontCreateWithFontDescriptor($0, size, nil) }
        return faces.isEmpty ? [font] : faces
    }
}
