// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Testing

@testable import MokumeCore

/// 2 色の間を取る口 ([#1552])。
///
/// 見るのは 4 つ。**線形の光の量で混ぜること** ([ADR-0011] 決定 1)、**乗算済みの 4 成分で
/// 混ぜること** (同 決定 4)、**端がちょうど戻ること**、そして **`amount` を 0…1 に締めること**
/// ([ADR-0033] 決定 3 の改訂)。前の 2 つが手本と中間の色が違う理由で、崩れると説明文の
/// 「手本とは違う」が嘘になる。数でない `amount` の注意は `ColorValueWarningTests` が見る
/// (控えを触るのはあの suite だけ)。
///
/// GPU は要らない — どれも面へ入る手前の純粋な計算である。
///
/// [#1552]: https://github.com/mokume-metal/mokume/issues/1552
/// [ADR-0011]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0011-color-model.md
/// [ADR-0033]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0033-color-specification-surface.md
@Suite("2 色の間を取る")
struct ColorInterpolationTests {
    /// 0–255 の読み出しは転送関数と原色の行列を往復するので、最下位で揺れる。
    private func isNear(_ one: Float, _ other: Float, within tolerance: Float = 0.05) -> Bool {
        abs(one - other) < tolerance
    }

    /// 彩度のある、不透明な 2 色 (Issue の例)。0–255 の数で書き、作業空間の値は
    /// どの成分も 2 進で閉じない。
    private let pale = color(236, 238, 240)
    private let vermilion = color(232, 96, 72)

    // MARK: - スケッチの外

    /// スケッチの外に置いた型。実害は作品の `enum` の `static func` の中で起きた ([#1552])。
    ///
    /// [#1552]: https://github.com/mokume-metal/mokume/issues/1552
    private enum OutsideASketch {
        /// 速さで線の色を朱へ寄せる — 0–255 の成分ごとに手で混ぜていた形。
        static func heat(_ amount: Float) -> LinearRGBA {
            lerpColor(color(236, 238, 240), color(232, 96, 72), amount)
        }
    }

    @Test("スケッチの外の型からも呼べる")
    func theEntryIsNotASketchMethod() {
        #expect(OutsideASketch.heat(0) == pale)
        #expect(OutsideASketch.heat(1) == vermilion)
    }

    // MARK: - 線形で混ぜる

    /// 手本は 0–255 のエンコード値のまま混ぜるので、黒と白の真ん中は 127.5 になる。
    @Test("線形の光の量で混ぜる — 黒と白の真ん中は 187.5 と読める")
    func theMixIsLinear() {
        let middle = lerpColor(color(0), color(255), 0.5)
        #expect(abs(middle.red - 0.5) < 1e-6, "\(middle)")
        #expect(abs(middle.green - 0.5) < 1e-6, "\(middle)")
        #expect(abs(middle.blue - 0.5) < 1e-6, "\(middle)")
        #expect(abs(middle.alpha - 1) < 1e-6, "\(middle)")
        #expect(isNear(red(middle), 187.5), "\(red(middle))")
    }

    /// 作業空間 (Display P3) と sRGB の間の原色の行列は線形なので、作業空間で混ぜても
    /// sRGB で混ぜたのと同じ中間になる。行列が混ぜ方に紛れ込むと、緑が 0 から浮く。
    @Test("原色が違う 2 色も、成分ごとに線形で混ざる")
    func primariesDoNotLeakIntoTheMix() {
        let middle = lerpColor(color(255, 0, 0), color(0, 0, 255), 0.5)
        #expect(isNear(red(middle), 187.5), "\(red(middle))")
        #expect(isNear(green(middle), 0), "\(green(middle))")
        #expect(isNear(blue(middle), 187.5), "\(blue(middle))")
    }

    // MARK: - 乗算済みで混ぜる

    /// 乗算していない成分で混ぜると、透明 (成分 0) へ寄せた分だけ赤が暗くなる — 手本は
    /// `red` が 127.5 前後に落ちる。乗算済みなら覆いの重みで混ざるので、色は赤のまま。
    @Test("透明へ寄せても暗くならない — 乗算済みの 4 成分で混ぜる")
    func theMixIsPremultiplied() {
        let half = lerpColor(.transparent, color(255, 0, 0), 0.5)
        #expect(alpha(half) == 127.5, "\(alpha(half))")
        #expect(isNear(red(half), 255), "\(red(half))")
        #expect(isNear(green(half), 0), "\(green(half))")
        #expect(isNear(blue(half), 0), "\(blue(half))")
    }

    // MARK: - 端

    /// 幅 (`stop - start`) を丸めてから掛けると、`amount` が 1 でも `stop` に戻らない
    /// ([#1453])。`lerp` と同じ計算を成分ごとに通すので、同じ性質を持つ。
    ///
    /// [#1453]: https://github.com/mokume-metal/mokume/issues/1453
    @Test("amount が 0 なら start が、1 なら stop がちょうど返る")
    func theEndsAreExact() {
        #expect(lerpColor(pale, vermilion, 0) == pale)
        #expect(lerpColor(pale, vermilion, 1) == vermilion)
        #expect(lerpColor(vermilion, pale, 1) == pale)
        #expect(lerpColor(pale, pale, 0.3) == pale)
    }

    // MARK: - 締める

    @Test("amount の 0…1 の外は締める — lerp と違い、手本と同じ")
    func amountsOutsideTheUnitRangeAreClamped() {
        #expect(lerpColor(pale, vermilion, 2) == vermilion)
        #expect(lerpColor(pale, vermilion, -1) == pale)
    }

    /// 締めずに外へ伸ばすと、不透明度の違う 2 色から 0–255 の外の不透明度ができる
    /// ([ADR-0033] 決定 3 の改訂 — 負の不透明度は下地から塗りを引く)。
    ///
    /// [ADR-0033]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0033-color-specification-surface.md
    @Test("不透明度の違う 2 色を外へ伸ばしても、不透明度は 0–255 に収まる")
    func opacityStaysInRange() {
        for amount: Float in [-1, 2] {
            let mixed = lerpColor(.transparent, color(255, 0, 0), amount)
            #expect(alpha(mixed) >= 0 && alpha(mixed) <= 255, "amount \(amount): \(alpha(mixed))")
        }
    }

    // MARK: - 数でない amount

    @Test("amount が数でない値・無限なら、start がそのまま返る")
    func nonFiniteAmountsGiveTheStart() {
        for amount: Float in [.nan, .infinity, -.infinity] {
            #expect(lerpColor(pale, vermilion, amount) == pale, "amount \(amount)")
        }
    }
}
