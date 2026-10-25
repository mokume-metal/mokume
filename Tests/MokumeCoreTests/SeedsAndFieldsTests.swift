// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Testing

@testable import MokumeCore
@testable import reference_sketches

/// 参照スケッチ `seeds-and-fields` (#2418)。**背景の塵が点いたり消えたりしても、200 本の花の位置と色が
/// 変わらない。** 花は 1 本ずつ自分の乱数源 (`RandomSource(seed: 7, index: i)`) で決まり、スケッチの列
/// (`random()`・`randomSource`) を何回引いても影響されない。
///
/// 描く経路を通すので GPU を使う (台帳の検査と同じ)。
@Suite(
    "参照スケッチ seeds-and-fields",
    .enabled(
        if: RenderDevice.isAvailable,
        "この世代のコマンド構造に対応した GPU が無い実行環境ではスキップする")
)
struct SeedsAndFieldsTests {
    @Test("塵が点いて・消えて・また点いても、200 本の花は 1 本も動かない。花は自分の列で決まる")
    func theFlowersStayWhileTheDustComesAndGoes() throws {
        let sketch = SeedsAndFields()
        let runtime = try SketchRuntime(
            sketch: sketch, gpu: try RenderDevice(), clock: nil, now: { 0 }, observer: nil)
        try runtime.advance()
        let first = sketch.flowers
        #expect(first.count == 200)

        // 塵は 60 フレームごとに点く・消える (点く間は、スケッチの列を 100 個引く)。
        // 2 周するまで走らせる
        let before = runtime.randomness
        for _ in 0..<250 { try runtime.advance() }
        #expect(sketch.flowers == first, "塵が点いている間にスケッチの列を引いたら、花が動いた")
        var now = runtime.randomness
        var then = before
        #expect(now.next() != then.next(), "塵がスケッチの列を引いていない (見たい状況ではない)")

        // 花の位置と色は、番号ごとの乱数源から直に引いた値と同じ
        let palette = [color(240, 90, 60), color(250, 200, 80), color(80, 140, 220)]
        for index in [0, 1, 99, 199] {
            var r = RandomSource(seed: 7, index: index)
            let x = Float.random(in: 20..<460, using: &r)
            let y = Float.random(in: 20..<520, using: &r)
            let tint = palette.randomElement(using: &r)!
            #expect(first[index] == SeedsAndFields.Flower(x: x, y: y, tint: tint))
        }
    }
}
