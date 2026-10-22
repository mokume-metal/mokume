// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Testing

@testable import MokumeCore

/// 3 色以上の段から色を引く ``paletteLerp(_:_:)`` (#2424)。走っているスケッチも GPU も要らない。
@Suite("パレットの補間")
struct PaletteLerpTests {
    private let sky: [(Color, Float)] = [
        (color(20, 30, 80), 0), (color(200, 60, 60), 0.6), (color(250, 220, 120), 1),
    ]

    // MARK: - 完了条件 2: 区間を探して混ぜる

    @Test("端はちょうどその色、区間の中は lerpColor と同じ")
    func endsAreExactAndIntervalsMatchLerpColor() {
        #expect(paletteLerp(sky, 0) == sky[0].0)
        #expect(paletteLerp(sky, 1) == sky[2].0)
        #expect(paletteLerp(sky, 0.6) == sky[1].0, "区切りの位置ちょうどは、その区切りの色")
        #expect(paletteLerp(sky, 0.3) == lerpColor(sky[0].0, sky[1].0, 0.5))
        #expect(paletteLerp(sky, 0.8) == lerpColor(sky[1].0, sky[2].0, 0.5))
        // 区間の割合は、区間の幅で割る (0.75 は [0.6, 1] の 0.375)
        #expect(paletteLerp(sky, 0.75) == lerpColor(sky[1].0, sky[2].0, (Float(0.75) - Float(0.6)) / (Float(1) - Float(0.6))))
        #expect(paletteLerp(sky, 0.3) != paletteLerp(sky, 0.8))
    }

    @Test("Double や Int の amount も受け取る")
    func acceptsAnyScalar() {
        #expect(paletteLerp(sky, Double(0.3)) == paletteLerp(sky, Float(0.3)))
        #expect(paletteLerp(sky, 1) == sky[2].0)
        let two: [(Color, Float)] = [(color(0), 0), (color(255), 1)]
        #expect(paletteLerp(two, 0) == two[0].0)
        #expect(paletteLerp(two, 1) == two[1].0)
    }

    // MARK: - 完了条件 3: 端と境界

    @Test("amount は 0…1 に締める")
    func amountIsClamped() {
        #expect(paletteLerp(sky, -1) == sky[0].0)
        #expect(paletteLerp(sky, 2) == sky[2].0)
        #expect(paletteLerp(sky, -Float.greatestFiniteMagnitude) == sky[0].0)
        // 位置が 0…1 の外の区切りには、締めた amount が届く範囲でしか届かない
        let wide: [(Color, Float)] = [(color(0), 0), (color(255), 10)]
        #expect(paletteLerp(wide, 5) == lerpColor(wide[0].0, wide[1].0, 0.1))
    }

    @Test("最初の位置より手前は最初の色、最後の位置より先は最後の色 (勾配と同じ)")
    func extendsBeyondTheEnds() {
        let inner: [(Color, Float)] = [(color(10, 20, 30), 0.25), (color(200, 100, 50), 0.75)]
        #expect(paletteLerp(inner, 0) == inner[0].0)
        #expect(paletteLerp(inner, 0.25) == inner[0].0)
        #expect(paletteLerp(inner, 0.75) == inner[1].0)
        #expect(paletteLerp(inner, 1) == inner[1].0)
        #expect(paletteLerp(inner, 0.5) == lerpColor(inner[0].0, inner[1].0, 0.5))
    }

    @Test("区切りが 1 つなら、amount によらずその色")
    func oneStop() {
        let only: [(Color, Float)] = [(color(10, 200, 30), 0.4)]
        for amount: Float in [-1, 0, 0.4, 1, 3] {
            #expect(paletteLerp(only, amount) == only[0].0)
        }
    }

    @Test("同じ位置の区切りは段になり、位置ちょうどでは後ろの色")
    func equalPositionsStep() {
        let step: [(Color, Float)] = [
            (color(255, 0, 0), 0), (color(0, 255, 0), 0.5), (color(0, 0, 255), 0.5), (color(255, 255, 255), 1),
        ]
        #expect(paletteLerp(step, 0.5) == step[2].0)
        #expect(paletteLerp(step, 0.25) == lerpColor(step[0].0, step[1].0, 0.5), "手前は緑へ向かう")
        #expect(paletteLerp(step, 0.75) == lerpColor(step[2].0, step[3].0, 0.5), "先は青から")
        // 位置がすべて同じなら、手前は最初の色、ちょうどと先は最後の色
        let same: [(Color, Float)] = [(color(255, 0, 0), 0.5), (color(0, 0, 255), 0.5)]
        #expect(paletteLerp(same, 0.2) == same[0].0)
        #expect(paletteLerp(same, 0.5) == same[1].0)
        #expect(paletteLerp(same, 0.9) == same[1].0)
    }

    @Test("並んでいない位置は、安定に並べ直して読む (勾配と同じ)")
    func unorderedStopsAreSortedStably() {
        let shuffled = [sky[2], sky[0], sky[1]]
        for amount: Float in [0, 0.1, 0.3, 0.6, 0.8, 1] {
            #expect(paletteLerp(shuffled, amount) == paletteLerp(sky, amount), "amount \(amount)")
        }
        // 同じ位置は書いた順
        let a = color(255, 0, 0)
        let b = color(0, 0, 255)
        #expect(paletteLerp([(a, 0.5), (b, 0.5)], 0.5) == b)
        #expect(paletteLerp([(b, 0.5), (a, 0.5)], 0.5) == a)
    }

    @Test("区切りの並べ方は勾配 (Gradient) と同じ: 同じ区切りの並びを、同じ順に読む")
    func sortsLikeAGradient() throws {
        let a = color(255, 0, 0)
        let b = color(0, 255, 0)
        let c = color(0, 0, 255)
        let d = color(255, 255, 0)
        let given: [(Color, Float)] = [(c, 0.9), (a, 0.5), (d, 0.1), (b, 0.5)]
        let gradient = Gradient.linearGradient(given, from: [0, 0], to: [1, 0])
        let resolved = try #require(ResolvedGradient.resolve(gradient, under: .identity).gradient)
        // 勾配が並べた区切りを、そのまま読んだ値と一致する (同じ位置は書いた順)
        let ordered = resolved.stops.map { ($0.color, $0.position) }
        for amount: Float in [0, 0.05, 0.1, 0.3, 0.5, 0.7, 0.9, 1] {
            #expect(paletteLerp(given, amount) == paletteLerp(ordered, amount), "amount \(amount)")
        }
        #expect(ordered.map { $0.1 } == [0.1, 0.5, 0.5, 0.9])
        #expect(ordered[1].0 == a && ordered[2].0 == b, "同じ位置は書いた順")
    }

    @Test("区切りが空なら透明な色を返し、1 度だけ知らせる")
    func emptyStops() {
        #expect(paletteLerp([], 0.5) == .transparent)
        #expect(PaletteValues.warnings.message(for: .noStops)?.contains("no stops") == true)
    }

    @Test("位置が数でない・無限の区切りは捨てて読む。全部捨てれば空と同じ")
    func badPositionsAreDropped() {
        let bad: [(Color, Float)] = [
            (color(255, 0, 0), .nan), sky[0], (color(0, 0, 255), .infinity), sky[1], sky[2],
        ]
        #expect(paletteLerp(bad, 0.3) == paletteLerp(sky, 0.3))
        #expect(PaletteValues.warnings.message(for: .badPosition)?.contains("left out") == true)
        #expect(paletteLerp([(color(255, 0, 0), .nan)], 0.5) == .transparent)
    }

    @Test("amount が数でない・無限なら最初の区切りの色を返し、1 度だけ知らせる")
    func badAmount() {
        for amount in [Float.nan, .infinity, -.infinity] {
            #expect(paletteLerp(sky, amount) == sky[0].0)
        }
        #expect(PaletteValues.warnings.message(for: .notANumber)?.contains("first stop") == true)
        // 並んでいなければ、並べ直した最初
        #expect(paletteLerp([sky[2], sky[0]], Float.nan) == sky[0].0)
    }

    // MARK: - 完了条件 4: 混ぜる空間は lerpColor と同じ (線形)

    @Test("黒と白の真ん中は lerpColor と同じ約 187.5 (手本の符号化した値の混ぜ方の 127.5 ではない)")
    func mixesInTheWorkingSpace() {
        let ramp: [(Color, Float)] = [(color(0), 0), (color(255), 1)]
        let middle = paletteLerp(ramp, 0.5)
        #expect(middle == lerpColor(color(0), color(255), 0.5))
        #expect(abs(red(middle) - 187.5) < 1)
    }

    @Test("透明へ寄せても暗くならない (乗算済みの値で混ぜる)")
    func premultipliedMixing() {
        let fade: [(Color, Float)] = [(.transparent, 0), (color(255, 0, 0), 1)]
        #expect(paletteLerp(fade, 0.5) == lerpColor(.transparent, color(255, 0, 0), 0.5))
    }
}
