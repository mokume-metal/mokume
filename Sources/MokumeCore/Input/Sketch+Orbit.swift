// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import simd

// 引きずって回し、スクロールで寄る。
extension SketchPart {

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
    ///   数でない値・無限の感度は、警告してその軸だけ効かせない (他の軸と慣性の流れは
    ///   いつもどおり進む)。有限でも、引きずった量との積が溢れた軸はそのフレームだけ進めない。
    ///
    /// - Note: 変えるのは**視点だけ**で、投影 (``perspective()`` / ``ortho()``) は
    ///   書き換えない。細かく決めたいときは ``orbit`` を直接書く。
    ///   慣性は既定で入っていない (``Orbit/inertia``)。
    ///
    /// - Note: **平面の図形はこの指定を通らない** — 面の座標へそのまま描かれる
    ///   (``camera(_:_:_:_:_:_:_:_:_:)``)。
    ///
    /// - Important: **``Sketch/mouseDragged(deltaX:deltaY:)`` の中から呼ばない。** ここが
    ///   食うのは ``SketchPart/dragX`` — フレームの合計 — なので、1 フレームに移動が複数件
    ///   届くと同じ量を何度も食うことになる (2 度目からは食わない作りにしてあるが、
    ///   そのぶん残りの呼び出しでは何も起きない)。`draw()` の中で 1 回呼ぶ形にする。
    ///
    /// - Note: 視点と同じく**フレームを越えない**。`setup()` や止まっている間の入力の
    ///   コールバックで呼ぶと、警告して無視される (道具の状態も進めない)。
    public func orbitControl(
        _ sensitivityX: some ScalarConvertible = 1, _ sensitivityY: some ScalarConvertible = 1,
        _ sensitivityZ: some ScalarConvertible = 1
    ) {
        guard let runtime = Self.liveRuntime() else { return }
        let canvas = runtime.canvas
        let (sensitivityX, sensitivityY, sensitivityZ) = (
            sensitivityX.asFloat, sensitivityY.asFloat, sensitivityZ.asFloat
        )
        // **道具の状態を進める前に断る** (#1670)。視点を書くのはシーンの記述で、フレームの
        // 外 (`setup()`・止まっている間のコールバック) では下の `camera` が断る。そこまで
        // 進めてから断ると、注意は出ても道具の状態 (慣性・引きずった量を食った印) だけが
        // 1 段進み、「無視する」にならない。形の組み立ての中も同じく先に断る (#1529)
        guard canvas.admits(.camera) else { return }
        var orbit = runtime.orbit ?? Orbit.fitting(width: canvas.width, height: canvas.height)

        // 感度が数でない・無限なら、受け口で知らせる (#2643・ADR-0020 決定 5)。効かせない
        // のは**その軸だけ** — 進めた先が有限にならない軸を進めないのは ``Orbit/advance`` の
        // 不変条件で、感度を使わない慣性の流れも止めない。検めるのは `Float` へ写した後で、
        // `Double` の大きすぎる値が無限になる場合も拾う
        let sensitivity = SIMD3(sensitivityX, sensitivityY, sensitivityZ)
        let sensible = sensitivity.x.isFinite && sensitivity.y.isFinite && sensitivity.z.isFinite
        if !sensible {
            canvas.warnOnce(
                .badOrbitSensitivity,
                "orbitControl(): got a sensitivity that is not a number, or an infinite one, so it had no effect on its axis")
        }
        // 同じフレームで 2 度呼ばれても、引きずった量を 2 度食わない
        if runtime.orbitAdvancedAt != runtime.frameCount {
            runtime.orbitAdvancedAt = runtime.frameCount
            let input = runtime.input
            let held = orbit.advance(
                dragX: input.dragX, dragY: input.dragY, scroll: input.scrollY,
                isDragging: input.isMouseDown, sensitivity: sensitivity)
            // 感度が有限なのに進めなかった軸 — 積が溢れた・届いた量が数でない・無限。
            // 別の軸の感度が使えなくても、こちらは別に知らせる
            let overflowed =
                (held.turn && sensitivity.x.isFinite) || (held.tilt && sensitivity.y.isFinite)
                || (held.zoom && sensitivity.z.isFinite)
            if overflowed {
                canvas.warnOnce(
                    .orbitStepHeld,
                    "orbitControl(): a turn or zoom came out as not a number or infinite (too large a sensitivity or movement), so that axis was left as it was for the frame")
            }
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
    /// 収めようのない値 (数でない値・無限の角や見ている先など) は既定へ倒し、初回だけ
    /// 警告する (見ている先は面の中央、角は 0、距離は寄れる限界)。
    /// **走っていなければ読んでも空が返り、書いても何も起きない** (口の名前ごとに 1 度だけ警告する)。
    /// 状態の読み書きでスケッチを止めない (ADR-0020 決定 5)。
    public var orbit: Orbit {
        get {
            guard let runtime = Self.liveRuntime(.read(returning: "an orbit at the origin with no distance")) else {
                return Orbit(center: .zero, distance: 0)
            }
            return runtime.orbit ?? Orbit.fitting(width: runtime.canvas.width, height: runtime.canvas.height)
        }
        // 部品 (struct) から書いても、書く先は走っているスケッチで、部品の値は変わらない
        nonmutating set {
            guard let runtime = Self.liveRuntime() else { return }
            var orbit = newValue
            // 見ている先の既定は、道具の始まりと同じ面の中央
            let start = Orbit.fitting(width: runtime.canvas.width, height: runtime.canvas.height)
            if orbit.clampToLimits(fallbackCenter: start.center) {
                runtime.canvas.warnOnce(
                    .badOrbit,
                    "orbit: got a value that is not a number, or an infinite one with no limit to stop at, so it fell back to its default (the middle of the canvas, angle 0, the nearest distance, minimum distance 1, no maximum distance, no inertia)")
            }
            runtime.orbit = orbit
        }
    }
}
