// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Testing

@testable import MokumeCore

/// 太さの物差しと、面の選び方 (#2445)。**合成の材料で見る** — どの機械でも同じ答えを返し、
/// CoreText にも GPU にも触れない (`styledFace` の検査と同じ作り)。
@Suite("書体の太さの物差し")
struct TypefaceWeightTests {
    @Test("CoreText の太さの印は、CSS の 100〜900 へ折れ線で写る", arguments: [
        (-0.8, 100.0), (-0.6, 200), (-0.4, 300), (0, 400), (0.23, 500), (0.3, 600), (0.4, 700),
        (0.56, 800), (0.62, 900),
    ])
    func coreTextAnchorsMapToCSS(_ item: (coreText: Double, css: Double)) {
        #expect(abs(TypefaceWeight.css(fromCoreText: item.coreText) - item.css) < 1e-9)
    }

    @Test("印の間は線で結び、端の外は端に揃える")
    func betweenAnchorsIsLinearAndEndsClamp() {
        #expect(abs(TypefaceWeight.css(fromCoreText: -0.2) - 350) < 1e-9, "300 と 400 の真ん中")
        #expect(abs(TypefaceWeight.css(fromCoreText: 0.115) - 450) < 1e-9)
        #expect(TypefaceWeight.css(fromCoreText: -1) == 100)
        #expect(TypefaceWeight.css(fromCoreText: 1) == 900)
    }

    @Test("太さは整数に丸めてから範囲へ締め、範囲の外だったかを返す", arguments: [
        (Float(500.2), 500, false), (500.4, 500, false), (500.6, 501, false),
        (100, 100, false), (900, 900, false),
        (99.6, 100, false),  // 丸めると範囲の中
        (50, 100, true), (-5, 100, true), (900.4, 900, false), (950, 900, true),
        (Float.greatestFiniteMagnitude, 900, true), (-Float.greatestFiniteMagnitude, 100, true),
    ])
    func clampedRoundsFirst(_ item: (value: Float, weight: Int, outside: Bool)) {
        let result = TypefaceWeight.clamped(item.value)
        #expect(result.weight == item.weight, "\(item.value)")
        #expect(result.wasOutside == item.outside, "\(item.value)")
    }

    private typealias Trait = TypefaceWeight.Trait

    /// Light・Regular・Bold と、それぞれの斜体 (Helvetica と同じ並び)。
    private let helvetica = [
        Trait(weight: 400, italic: false), Trait(weight: 700, italic: false),
        Trait(weight: 400, italic: true), Trait(weight: 700, italic: true),
        Trait(weight: 300, italic: false), Trait(weight: 300, italic: true),
    ]

    @Test("最も近い太さの面を選ぶ。傾きが合う面から選ぶ", arguments: [
        (100, false, 4), (300, false, 4), (349, false, 4), (351, false, 0), (400, false, 0),
        (500, false, 0), (549, false, 0), (551, false, 1), (900, false, 1),
        (100, true, 5), (500, true, 2), (900, true, 3),
    ])
    func theNearestFaceWithTheRightSlant(_ item: (weight: Int, italic: Bool, expected: Int)) {
        #expect(
            TypefaceWeight.nearest(among: helvetica, weight: item.weight, italic: item.italic)
                == item.expected,
            "太さ \(item.weight) 斜体 \(item.italic)")
    }

    @Test("頼んだ傾きの面が 1 つも無ければ、傾きは諦めて太さで選ぶ")
    func slantIsGivenUpWhenNoFaceHasIt() {
        let upright = [Trait(weight: 300, italic: false), Trait(weight: 700, italic: false)]
        #expect(TypefaceWeight.nearest(among: upright, weight: 650, italic: true) == 1)
    }

    @Test("太さが同じだけ離れた 2 面は、500 以下なら軽い方、より重ければ重い方。それでも同じなら先の面")
    func aTieGoesTowardsTheCommonSide() {
        let faces = [Trait(weight: 600, italic: false), Trait(weight: 400, italic: false)]
        #expect(TypefaceWeight.nearest(among: faces, weight: 500, italic: false) == 1, "500 は軽い方")
        let heavy = [Trait(weight: 400, italic: false), Trait(weight: 800, italic: false)]
        #expect(TypefaceWeight.nearest(among: heavy, weight: 600, italic: false) == 1, "600 は重い方")
        let same = [Trait(weight: 400, italic: false), Trait(weight: 400, italic: false)]
        #expect(TypefaceWeight.nearest(among: same, weight: 700, italic: false) == 0)
    }

    @Test("面が無ければ nil")
    func noFacesIsNil() {
        #expect(TypefaceWeight.nearest(among: [], weight: 400, italic: false) == nil)
    }
}
