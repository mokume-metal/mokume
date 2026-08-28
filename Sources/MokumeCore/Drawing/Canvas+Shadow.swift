// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import MokumeDiagnostics
import simd

// 影を落とす。焼き付けの仕組みは ``ShadowMap``、寿命は [ADR-0021] 決定 4 が定める。
//
// [ADR-0021]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0021-solid-space-and-frame-assembly.md
extension Canvas {

    // 影を落とすかどうか。
    public func shadows(_ enabled: Bool) {
        guard isDrawing else { return warnShadowOutsideFrame() }
        closeBatch()
        shadowsEnabled = enabled
    }

    // 影を焼き付ける範囲の一辺 (世界の長さ)。
    public func shadowRange(_ size: Float) {
        guard isDrawing else { return warnShadowOutsideFrame() }
        guard size.isFinite, size > 0 else { return warnBadShadow("shadowRange") }
        closeBatch()
        shadowRangeValue = size
    }

    // 影の細かさ (焼き付け先の一辺の画素数)。
    public func shadowDetail(_ size: Int) {
        guard isDrawing else { return warnShadowOutsideFrame() }
        guard ShadowMap.detailRange.contains(size) else { return warnBadShadow("shadowDetail") }
        closeBatch()
        shadowDetailValue = size
    }

    // 影の縁の破綻を抑える量。
    public func shadowBias(_ amount: Float) {
        guard isDrawing else { return warnShadowOutsideFrame() }
        guard amount.isFinite, amount >= 0 else { return warnBadShadow("shadowBias") }
        closeBatch()
        shadowBiasValue = amount
    }

    // これから置く形が、影を落とす側か。
    public func castShadow(_ enabled: Bool) {
        guard isDrawing else { return warnShadowOutsideFrame() }
        closeBatch()
        castsShadow = enabled
    }

    // これから置く形が、影を受ける側か。
    public func receiveShadow(_ enabled: Bool) {
        guard isDrawing else { return warnShadowOutsideFrame() }
        closeBatch()
        receivesShadow = enabled
    }

    // MARK: - 焼き付け

    /// 影を落とす光。**置いてあるうちの最初の向きを持つ光**。
    ///
    /// 種類を増やすのは要ると分かってからにする ([ADR-0008])。どれが落としているかは
    /// ここを読めば分かる形にしてある。
    ///
    /// [ADR-0008]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0008-mechanism-needs-demonstrated-harm.md
    var shadowCaster: Light? {
        activeLights.first { $0.kind == .directional }
    }

    /// 焼き付ける範囲の一辺。指定が無ければ**いまの視点が写す範囲から導く**。
    ///
    /// 固定の数を既定にすると、その値に合った縮尺でしか使えない。面に合わせた既定の
    /// 視点と噛み合う値を導いておけば、`shadows(true)` の 1 行で床の上の影が出る。
    var effectiveShadowRange: Float {
        if let shadowRangeValue { return shadowRangeValue }
        // 面の対角。視点をどちらへ回しても、写っている範囲を覆える
        return (width * width + height * height).squareRoot()
    }

    /// 影を焼き付ける行列。落とす光が無ければ `nil`。
    var shadowMatrix: simd_float4x4? {
        guard shadowsEnabled, let caster = shadowCaster else { return nil }
        return ShadowMap.matrix(
            direction: SIMD3(
                caster.directionAndCone.x, caster.directionAndCone.y, caster.directionAndCone.z),
            center: currentCamera.center,
            range: effectiveShadowRange)
    }

    /// フレームの外で影の設定を書いたことを、初回だけ知らせる。
    private func warnShadowOutsideFrame() {
        guard !warnedShadowOutsideFrame else { return }
        warnedShadowOutsideFrame = true
        Diagnostics.warn(
            "影はフレームごとに書き直すものなので、描くところ (draw) で呼んでください。"
                + "初期化のときに書いた影はどのフレームにも属さないため、無視しました")
    }

    /// 受け取れない値を、初回だけ知らせる。
    private func warnBadShadow(_ name: String) {
        guard !warnedBadShadow else { return }
        warnedBadShadow = true
        Diagnostics.warn(
            "\(name)(): 数でない値・範囲の外の値が渡されたので、影の設定を変えませんでした")
    }
}
