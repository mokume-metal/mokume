// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import simd

// 引きずって回し、スクロールで寄る。
extension SketchPart {

    /// 引きずって回し、右ドラッグで覗き込み、スクロールで寄れるようにする。
    ///
    /// `draw()` の中で毎フレーム 1 回呼ぶ。
    ///
    /// | 操作 | 動き |
    /// | --- | --- |
    /// | 左ドラッグ (中ボタンなど、ほかのボタンも) | 注視点のまわりを回る。**指の向きへ被写体が回る** (掴んで回す向き) |
    /// | 右ドラッグ・⌥ を押したまま左ドラッグ | 注視点を画面の面に沿ってずらす (平行移動)。**被写体が指に付いて動く** |
    /// | スクロール | 寄る・引く |
    ///
    /// 平行移動の量は、注視点の奥行きで 1 画素が覆う長さで測る。注視点の奥行きにある点は、
    /// 指にぴったり付いて動く。感度の引数は回す・寄るの効きで、平行移動には掛からない。
    /// トラックパッドでは、⌥ を押したまま引きずると平行移動になる。
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
    /// - Note: **右ドラッグは平行移動である** (#2461 で回すから変わった)。手本の p5.js の
    ///   `orbitControl()` と同じ割り当てで、回すのは左ドラッグ。
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
            // 右ボタンか、⌥ を押したままの左ボタンなら平行移動 (#2461)。ほかの押下は今までどおり回す
            let pans =
                input.pressedButtons.contains(.right)
                || (input.pressedButtons.contains(.left) && Keyboard(state: input).isPressed(.option))
            // **平行移動の量は動かす前の視点で測る。** 投影はいまのもの (`orbitControl` は書き換えない)
            var view = canvas.currentCamera
            (view.eye, view.center, view.up) = (orbit.eye, orbit.center, orbit.up)
            // 平行移動の間は回さない。回す軸は 0 の引きずりとして進め、慣性の速さも捨てる
            let held = orbit.advance(
                dragX: pans ? 0 : input.dragX, dragY: pans ? 0 : input.dragY, scroll: input.scrollY,
                isDragging: input.isMouseDown, sensitivity: sensitivity)
            let panHeld =
                pans
                && !orbit.pan(
                    dragX: input.dragX, dragY: input.dragY, through: view, width: canvas.width,
                    height: canvas.height)
            // 感度が有限なのに進めなかった軸 — 積が溢れた・届いた量が数でない・無限。
            // 別の軸の感度が使えなくても、こちらは別に知らせる。平行移動は感度を使わない
            let overflowed =
                (held.turn && sensitivity.x.isFinite) || (held.tilt && sensitivity.y.isFinite)
                || (held.zoom && sensitivity.z.isFinite) || panHeld
            if overflowed {
                canvas.warnOnce(
                    .orbitStepHeld,
                    "orbitControl(): a turn, pan or zoom came out as not a number or infinite (too large a sensitivity or movement), so that axis was left as it was for the frame")
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
    ///     orbit.center = Vector3(width / 2, height / 2, -200)
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
                return Orbit(center: Vector3(0, 0, 0), distance: 0)
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
