// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation
import Testing

@testable import MokumeCore

/// 作者の口 ``Sketch/random()`` が返す値の分布 ([#1385] 条件 9)。
///
/// ``RandomTests`` は範囲と再現 (同じ種から同じ列) だけを見ていて、**値が 0…1 に一様に
/// 散っているか**は誰も見ていない。偏った列でも範囲には収まるので、範囲の検査は緑のまま
/// になる。ここでは 10 区間の度数を χ² で判定する。
///
/// ## 判定の組み方
///
/// - 引く回数は 1e5、区間は 10 (幅 0.1)。各区間の期待度数は 1e4
/// - 自由度は 9 (区間の数 − 1)。有意水準は**両側で 0.2%** — 上側 0.1% の 27.877 を越えたら
///   偏り、下側 0.1% の 1.152 を下回ったら**揃いすぎ** (数え上げのような列) とみなす
/// - **種は選ばない。** 作者が ``Sketch/randomSeed(_:)`` を書かなかったときの既定の列
///   (種 0) をそのまま使う。χ² の値を見てから種を選ぶと、偶然小さい値の出る種を拾えて
///   しまい検定にならない。種が固定なので結果は決定的で、偶然で落ちることはない
///
/// 種 0 の χ² は 2026-09-23 の実測で 14.89 (自由度 9 の上側 9% ほど — 珍しくない値)。
/// 生成器を変えて列が動き、この値が 2 つの臨界値の間から出たら、それは列の偏りである。
///
/// [#1385]: https://github.com/mokume-metal/mokume/issues/1385
@Suite(
    "乱数の分布",
    .enabled(
        if: RenderDevice.isAvailable,
        "作者の口はランタイムを通るので GPU が要る。この世代のコマンド構造に対応した GPU が無い実行環境ではスキップする")
)
struct RandomDistributionTests {
    /// 何も描かないスケッチ。乱数を引くためだけにランタイムを立てる。
    final class Blank: Sketch {
        var settings = SketchSettings(width: 8, height: 8)
        init() {}
        func draw() {}
    }

    static let draws = 100_000
    static let bins = 10
    /// 自由度 9 の χ² 分布の上側 0.1% 点。
    static let upperCriticalValue = 27.877
    /// 自由度 9 の χ² 分布の下側 0.1% 点。
    static let lowerCriticalValue = 1.152

    /// 10 区間の度数の χ²。範囲の外の値は数えずに返す (範囲は別に見る)。
    static func chiSquare(of values: [Float]) -> Double {
        var counts = [Int](repeating: 0, count: bins)
        for value in values {
            let index = Int((value * Float(bins)).rounded(.down))
            guard counts.indices.contains(index) else { continue }
            counts[index] += 1
        }
        let expected = Double(values.count) / Double(bins)
        return counts.reduce(0) { total, count in
            total + (Double(count) - expected) * (Double(count) - expected) / expected
        }
    }

    /// 作者の口は走っているランタイムを通るので、検査からもそれを差してから呼ぶ。
    private func runSketch(_ runtime: SketchRuntime, _ body: () -> Void) {
        let previous = runningSketch
        runningSketch = runtime
        defer { runningSketch = previous }
        body()
    }

    @Test("種を決めずに 1e5 回引くと、10 区間の度数が一様と見分けられない")
    func defaultSequenceIsUniform() throws {
        let sketch = Blank()
        let runtime = try SketchRuntime(sketch: sketch, gpu: RenderDevice())
        var values: [Float] = []
        values.reserveCapacity(Self.draws)
        runSketch(runtime) {
            for _ in 0..<Self.draws { values.append(sketch.random()) }
        }

        #expect(values.allSatisfy { $0 >= 0 && $0 < 1 }, "0 以上 1 未満の外に出た値がある")
        let statistic = Self.chiSquare(of: values)
        #expect(statistic < Self.upperCriticalValue, "度数が偏っている (χ² = \(statistic))")
        #expect(statistic > Self.lowerCriticalValue, "度数が揃いすぎている (χ² = \(statistic))")
    }
}
