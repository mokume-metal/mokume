// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import simd

// 引きずって回し、スクロールで寄る。
extension Sketch {

    /// 引きずって回し、スクロールで寄れるようにする。
    ///
    /// `draw()` の中で毎フレーム 1 回呼ぶ。押したまま動かすと注視点のまわりを回り、
    /// スクロールすると寄る・引く。**指の向きへ被写体が回る** (掴んで回す向き)。
    ///
    /// ```swift
    /// func draw() {
    ///     background(20, 23, 31)
    ///     orbitControl()
    ///     lights()
    ///     push()
    ///     translate(width / 2, height / 2, 0)
    ///     box(140)
    ///     pop()
    /// }
    /// ```
    ///
    /// 始まりは**既定の視点と同じ位置**なので、これを足しただけでは絵が動かない。
    /// 寄り・引きの限界も既定の投影の手前・奥の面に合わせてあるので、限界まで動かしても
    /// 被写体が切れない。
    ///
    /// - Parameters:
    ///   - sensitivityX: 横に引きずったときの効き。負にすると回る向きが逆になる。
    ///   - sensitivityY: 縦に引きずったときの効き。
    ///   - sensitivityZ: スクロールの効き。
    ///
    /// - Note: 変えるのは**視点だけ**で、投影 (``perspective()`` / ``ortho()``) は
    ///   書き換えない。細かく決めたいときは ``orbit`` を直接書く。
    ///   慣性は既定で入っていない (``Orbit/inertia``)。
    ///
    /// - Important: **``Sketch/mouseDragged()`` の中から呼ばない。** ここは 1 フレームに
    ///   1 回しか引きずった量を食わないので、1 フレームに移動が複数件届いたとき最初の
    ///   1 件までの部分累計だけを食い、残りが黙って捨てられる。回る量が減るだけなので
    ///   絵を見ても気付けない。`draw()` の中で 1 回呼ぶ形にする。
    public func orbitControl(
        _ sensitivityX: Float = 1, _ sensitivityY: Float = 1, _ sensitivityZ: Float = 1
    ) {
        guard let runtime = runningSketch else { return }
        var orbit = runtime.orbit ?? Orbit.fitting(width: canvas.width, height: canvas.height)

        // 同じフレームで 2 度呼ばれても、引きずった量を 2 度食わない
        if runtime.orbitAdvancedAt != runtime.frameCount {
            runtime.orbitAdvancedAt = runtime.frameCount
            let input = runtime.input
            orbit.advance(
                dragX: input.dragX, dragY: input.dragY, scroll: input.scrollY,
                isDragging: input.isMouseDown,
                sensitivity: SIMD3(sensitivityX, sensitivityY, sensitivityZ))
        } else {
            orbit.clampToLimits()
        }
        runtime.orbit = orbit

        canvas.camera(
            orbit.eye.x, orbit.eye.y, orbit.eye.z,
            orbit.center.x, orbit.center.y, orbit.center.z,
            orbit.up.x, orbit.up.y, orbit.up.z)
    }

    /// 視点を操る道具の状態。手で置きたいときはここへ書く。
    ///
    /// ```swift
    /// func setup() {
    ///     orbit.center = SIMD3(width / 2, height / 2, -200)
    ///     orbit.inertia = 0.92          // 離すと流れる
    /// }
    /// ```
    ///
    /// 書いた値は限界へ収められる (仰角は真上・真下を越えず、距離は上下限の中へ入る)。
    /// **走っていなければ読んでも空が返り、書いても何も起きない** — 入力を読むのと同じで、
    /// 状態の読み書きでスケッチを止めない。
    public var orbit: Orbit {
        get {
            guard let runtime = runningSketch else {
                return Orbit(center: .zero, distance: 0)
            }
            return runtime.orbit ?? Orbit.fitting(width: runtime.canvas.width, height: runtime.canvas.height)
        }
        set {
            guard let runtime = runningSketch else { return }
            var orbit = newValue
            orbit.clampToLimits()
            runtime.orbit = orbit
        }
    }
}
