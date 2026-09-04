// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT


// 明るさを画面へ写す段。設定は**画面 (描画先) が持つ** — 効く範囲と寿命は
// ``Brightness`` が定める。
extension Canvas {

    // 画面全体の明るさの倍率。
    public func exposure(_ multiplier: Float) {
        guard multiplier.isFinite, multiplier >= 0 else { return warnBadExposure() }
        target.brightness.exposure = multiplier
    }

    // 表示できる範囲を超えた明るさの丸め方。
    public func toneMapping(_ mode: ToneMapping) {
        target.brightness.toneMapping = mode
    }

    /// 受け取れない露出を、初回だけ知らせる ([ADR-0020] 決定 5)。
    ///
    /// [ADR-0020]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0020-api-naming-and-surface.md
    private func warnBadExposure() {
        warnOnce(
            .badExposure,
            "exposure(): 数でない値・無限・負の値が渡されたので、明るさを変えませんでした")
    }
}
