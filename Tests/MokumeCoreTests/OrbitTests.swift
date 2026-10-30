// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation
import Testing
import simd

@testable import MokumeCore

/// 視点を操る道具の検査。**入力も GPU も要らない**部分をここで固める。
///
/// 完了条件の 4 つ (押した瞬間に動かない・1 px の効きが慣性で変わらない・慣性を切ると
/// 惰性が残らない・仰角が真上を越えない) は、いずれも「連続的な入力を離散フレームで
/// 積む」境界にある。**実機で触るまで気付かない**種類なので、計算の側で固定する。
@Suite("視点を操る")
struct OrbitTests {
    private func fitting() -> Orbit { Orbit.fitting(width: 640, height: 480) }

    private func drag(
        _ orbit: inout Orbit, x: Float = 0, y: Float = 0, scroll: Float = 0,
        isDragging: Bool = true
    ) {
        orbit.advance(
            dragX: x, dragY: y, scroll: scroll, isDragging: isDragging,
            sensitivity: SIMD3(1, 1, 1))
    }

    // MARK: - 既定

    @Test("始まりは、面がちょうど収まる視点と同じ位置")
    func startsWhereTheDefaultCameraIs() {
        let orbit = fitting()
        let camera = Camera.fitting(width: 640, height: 480)
        #expect(orbit.eye == camera.eye)
        #expect(orbit.center == camera.center)
        #expect(orbit.up == camera.up)
    }

    @Test("寄り・引きの限界は、既定の投影の手前と奥の面に合う")
    func limitsMatchTheDefaultProjection() {
        let orbit = fitting()
        guard case let .perspective(_, _, near, far) = Camera.defaultPerspective(
            width: 640, height: 480)
        else {
            Issue.record("既定の投影が透視でない")
            return
        }
        #expect(orbit.minimumDistance == near)
        #expect(orbit.maximumDistance == far)
    }

    // MARK: - 引きずる

    @Test("横へ引きずると、指の向きへ被写体が回る")
    func draggingSidewaysTurnsTheSubjectWithTheFinger() {
        var orbit = fitting()
        drag(&orbit, x: 40)
        // 指を右へ = 被写体の左側が手前へ = 見る位置は左へ回る
        #expect(orbit.yaw < 0)
        #expect(orbit.eye.x < orbit.center.x)
    }

    @Test("縦へ引きずると、見る位置が上下する")
    func draggingVerticallyRaisesTheEye() {
        var orbit = fitting()
        drag(&orbit, y: 40)
        // 下へ引きずる = 見下ろす = 見る位置は上 (縦軸は下向きなので -y)
        #expect(orbit.pitch > 0)
        #expect(orbit.eye.y < orbit.center.y)
    }

    @Test("押しているだけで動かさなければ、何も動かない")
    func holdingWithoutMovingDoesNothing() {
        var orbit = fitting()
        let before = orbit
        drag(&orbit, x: 0, y: 0)
        #expect(orbit.yaw == before.yaw)
        #expect(orbit.pitch == before.pitch)
        #expect(orbit.distance == before.distance)
    }

    // MARK: - 慣性

    @Test("1 px が回す角は、慣性の強さを変えても同じ", arguments: [Float(0), 0.5, 0.9, 0.99])
    func onePixelTurnsTheSameAngleAtAnyInertia(_ inertia: Float) {
        var orbit = fitting()
        orbit.inertia = inertia
        // **1 フレームだけでは差が出ない。** 速さへ足し込む作りの倍率 1 / (1 - 減衰) は
        // 引きずり続けたときに現れるので、20 フレーム引きずって総量で見る
        for _ in 0..<20 { drag(&orbit, x: 1) }
        #expect(abs(orbit.yaw - -20 * Orbit.radiansPerPixel) < 1e-5)
    }

    @Test("慣性を入れると、離したあとも流れて、やがて止まる")
    func inertiaCoastsAndSettles() {
        var orbit = fitting()
        orbit.inertia = 0.9
        drag(&orbit, x: 30)
        let atRelease = orbit.yaw

        drag(&orbit, isDragging: false)
        let afterOne = orbit.yaw
        #expect(afterOne != atRelease)

        for _ in 0..<300 { drag(&orbit, isDragging: false) }
        let settled = orbit.yaw
        drag(&orbit, isDragging: false)
        #expect(abs(orbit.yaw - settled) < 1e-6)
    }

    @Test("慣性を切ると、溜まっていた惰性は残らない")
    func turningInertiaOffDropsTheStoredSpeed() {
        var orbit = fitting()
        orbit.inertia = 0.95
        drag(&orbit, x: 60)

        // 切って、しばらく置く
        orbit.inertia = 0
        for _ in 0..<10 { drag(&orbit, isDragging: false) }
        let resting = orbit.yaw

        // あとで上げても、待った時間に関わらず勝手に回り出さない
        orbit.inertia = 0.95
        for _ in 0..<10 { drag(&orbit, isDragging: false) }
        #expect(orbit.yaw == resting)
    }

    @Test("止めてから離せば流れない")
    func stoppingBeforeReleasingLeavesNoDrift() {
        var orbit = fitting()
        orbit.inertia = 0.95
        drag(&orbit, x: 60)
        // 押したまま動かさないフレームを 1 つ挟んでから離す
        drag(&orbit, x: 0)
        let atRelease = orbit.yaw

        for _ in 0..<10 { drag(&orbit, isDragging: false) }
        #expect(orbit.yaw == atRelease)
    }

    // MARK: - 限界

    @Test("仰角は真上・真下を越えない")
    func pitchStopsShortOfStraightUp() {
        for direction in [Float(1), -1] {
            var orbit = fitting()
            for _ in 0..<200 { drag(&orbit, y: direction * 50) }
            #expect(abs(orbit.pitch) <= Orbit.pitchLimit)
            // 越えなければ上方向と視線が重ならない = 視点として成り立つ
            let camera = Camera(
                eye: orbit.eye, center: orbit.center, up: orbit.up,
                projection: Camera.defaultPerspective(width: 640, height: 480))
            #expect(camera.isUsable)
        }
    }

    @Test("寄っても引いても、限界の外へ出ない")
    func distanceStaysWithinItsLimits() {
        var near = fitting()
        for _ in 0..<200 { drag(&near, scroll: 10, isDragging: false) }
        #expect(near.distance >= near.minimumDistance)

        var far = fitting()
        for _ in 0..<200 { drag(&far, scroll: -10, isDragging: false) }
        #expect(far.distance <= far.maximumDistance)
    }

    @Test("スクロールは掛け算で寄る (遠くでも近くでも同じ割合)")
    func zoomIsProportional() {
        var orbit = fitting()
        orbit.maximumDistance = .infinity
        orbit.minimumDistance = 0.001
        let start = orbit.distance
        drag(&orbit, scroll: 4, isDragging: false)
        let firstRatio = orbit.distance / start

        let second = orbit.distance
        drag(&orbit, scroll: 4, isDragging: false)
        #expect(abs(orbit.distance / second - firstRatio) < 1e-5)
        #expect(firstRatio < 1)
    }

    /// **3 つの感度は、それぞれの軸にだけ掛かる。** 上の検査はどれも感度 1 で呼ぶので、
    /// 縦に横の感度を掛けても、寄りの感度を捨てても緑のままだった (#2287)。倍率を
    /// 2・3・0.5 と軸ごとに変えて、取り違えれば比が食い違うようにする。
    @Test("横・縦・寄りの感度は、それぞれの軸にだけ掛かる")
    func eachSensitivityScalesItsOwnAxis() {
        func moved(by sensitivity: SIMD3<Float>) -> (yaw: Float, pitch: Float, zoom: Float) {
            var orbit = fitting()
            orbit.maximumDistance = .infinity
            orbit.minimumDistance = 0.001
            let start = orbit
            orbit.advance(
                dragX: 10, dragY: 10, scroll: 2, isDragging: true, sensitivity: sensitivity)
            return (
                orbit.yaw - start.yaw, orbit.pitch - start.pitch,
                log(orbit.distance / start.distance))
        }
        let plain = moved(by: SIMD3(1, 1, 1))
        // 1 のときに動いていなければ、比は何も見ていない
        #expect(plain.yaw != 0)
        #expect(plain.pitch != 0)
        #expect(plain.zoom != 0)

        let scaled = moved(by: SIMD3(2, 3, 0.5))
        #expect(abs(scaled.yaw / plain.yaw - 2) < 1e-4)
        #expect(abs(scaled.pitch / plain.pitch - 3) < 1e-4)
        #expect(abs(scaled.zoom / plain.zoom - 0.5) < 1e-4)
    }

    @Test("手で書いた値も限界へ収める")
    func handWrittenValuesAreClamped() {
        var orbit = fitting()
        orbit.pitch = 10
        orbit.distance = 1e9
        // 収めただけで、既定へ倒してはいない (書く口が警告しない)
        let fellBack = orbit.clampToLimits()
        #expect(!fellBack)
        #expect(orbit.pitch == Orbit.pitchLimit)
        #expect(orbit.distance == orbit.maximumDistance)
    }

    /// 倒れ方は既定のまま、**倒したことを返す** — 書く口 (`orbit`) が警告する (#2643)。
    @Test("壊れた値を書いても、視点として成り立ち、既定へ倒したと分かる")
    func brokenValuesFallBackToSomethingUsable() {
        var orbit = fitting()
        orbit.pitch = .nan
        orbit.yaw = .infinity
        orbit.distance = .nan
        let fellBack = orbit.clampToLimits()
        #expect(fellBack)
        #expect(orbit.pitch == 0)
        #expect(orbit.yaw == 0)
        #expect(orbit.distance == orbit.minimumDistance)
        #expect(orbit.eye.x.isFinite && orbit.eye.y.isFinite && orbit.eye.z.isFinite)
    }

    // MARK: - 状態は常に有限 (#2643)

    /// 角・距離・速さに数でない値・無限が入ると、限界へ収める段が角を 0、距離を下限へ
    /// 倒すしかない。だから進めた先が有限にならない軸は、その軸だけ進めない。

    /// 回して、角が 0 でない状態を作る (0 へ倒れても「動かなかった」と見分けが付くように)。
    private func turned() -> Orbit {
        var orbit = fitting()
        drag(&orbit, x: 20, y: 10)
        return orbit
    }

    @Test("有限の感度でも積が溢れた軸だけ進めず、角を 0 へ倒さず、その軸の速さを捨てる")
    func overflowingTurnHoldsOnlyThatAxis() {
        var orbit = turned()
        let before = orbit
        #expect(before.yaw != 0 && before.pitch != 0)
        let held = orbit.advance(
            dragX: 40, dragY: 10, scroll: 0, isDragging: true, sensitivity: SIMD3(1e37, 1, 1))
        #expect(held == Orbit.HeldAxes(turn: true))
        #expect(orbit.yaw == before.yaw)
        #expect(orbit.yawSpeed == 0)
        // 溢れていない縦はいつもどおり進む
        #expect(abs(orbit.pitch - (before.pitch + 10 * Orbit.radiansPerPixel)) < 1e-6)
        #expect(orbit.pitchSpeed != 0)
    }

    @Test("届いた引きずりの量が数でない・無限でも、その軸は進まない", arguments: [Float.nan, .infinity, -.infinity])
    func unusableDragHoldsTheAxis(_ amount: Float) {
        var orbit = turned()
        let before = orbit
        let held = orbit.advance(
            dragX: amount, dragY: 0, scroll: 0, isDragging: true, sensitivity: SIMD3(1, 1, 1))
        #expect(held == Orbit.HeldAxes(turn: true))
        #expect(orbit.yaw == before.yaw)
        #expect(orbit.yawSpeed.isFinite && orbit.pitchSpeed.isFinite)
    }

    @Test("寄りの感度が数でない・無限なら、距離は動かない", arguments: [Float.nan, .infinity, -.infinity])
    func unusableZoomSensitivityHoldsTheDistance(_ sensitivity: Float) {
        var orbit = fitting()
        let before = orbit.distance
        let held = orbit.advance(
            dragX: 0, dragY: 0, scroll: 2, isDragging: false, sensitivity: SIMD3(1, 1, sensitivity))
        #expect(held == Orbit.HeldAxes(zoom: true))
        #expect(orbit.distance == before)
    }

    /// 指数が 100 になる量 (感度 10 で)。Float の `exp` は 88 あたりから無限になるので、溢れさせたい検査はこれを使う。
    /// **係数の `zoomPerScroll` が動いても、指数が同じになるように係数で割る** (#2442)。
    private var overflowingScroll: Float { -100 / (10 * Orbit.zoomPerScroll) }

    /// 引いたつもりが、最も寄った位置へ飛んでいた。
    @Test("溢れて無限になった距離は、下限ではなく上限へ収める")
    func overflowingZoomOutStopsAtTheFarLimit() {
        var orbit = fitting()
        // 指数 100 は Float の exp で無限になる
        let held = orbit.advance(
            dragX: 0, dragY: 0, scroll: overflowingScroll, isDragging: false, sensitivity: SIMD3(1, 1, 10))
        #expect(!held.any)
        #expect(orbit.distance == orbit.maximumDistance)

        var written = fitting()
        written.distance = .infinity
        let fellBack = written.clampToLimits()
        #expect(!fellBack)
        #expect(written.distance == written.maximumDistance)
    }

    @Test("引ける限界が無いときに溢れた寄りは、進めない")
    func overflowingZoomWithoutAFarLimitHolds() {
        var orbit = Orbit(center: Vector3(0, 0, 0), distance: 100)
        let held = orbit.advance(
            dragX: 0, dragY: 0, scroll: overflowingScroll, isDragging: false, sensitivity: SIMD3(1, 1, 10))
        #expect(held == Orbit.HeldAxes(zoom: true))
        #expect(orbit.distance == 100)
    }

    @Test("どこから入っても、非有限の速さは捨てられ、慣性で角が 0 へ戻されない")
    func unusableSpeedIsDropped() {
        var clamped = turned()
        clamped.yawSpeed = .nan
        clamped.pitchSpeed = .infinity
        clamped.clampToLimits()
        #expect(clamped.yawSpeed == 0 && clamped.pitchSpeed == 0)

        var coasting = turned()
        let before = coasting
        coasting.inertia = 0.9
        coasting.yawSpeed = .nan
        coasting.pitchSpeed = -.infinity
        drag(&coasting, isDragging: false)
        #expect(coasting.yaw == before.yaw && coasting.pitch == before.pitch)
        #expect(coasting.yawSpeed == 0 && coasting.pitchSpeed == 0)
    }

    @Test("限界や慣性に数でない値を書いても、距離に数でない値が入らない")
    func brokenLimitsFallBackToDefaults() {
        var orbit = fitting()
        orbit.minimumDistance = .nan
        orbit.maximumDistance = .nan
        orbit.inertia = .nan
        orbit.distance = .nan
        let fellBack = orbit.clampToLimits()
        #expect(fellBack)
        #expect(orbit.minimumDistance == 1)
        #expect(orbit.maximumDistance == .infinity)
        #expect(orbit.inertia == 0)
        #expect(orbit.distance == 1)
        #expect(orbit.eye.x.isFinite && orbit.eye.y.isFinite && orbit.eye.z.isFinite)
    }

    /// 見ている先も「状態は常に有限」に入る。外れていると、毎フレーム見る位置が数でない
    /// 値になり、呼んでもいない `camera()` の文面で断られていた。
    @Test("見ている先が数でない・無限なら、渡した先へ倒し、既定へ倒したと分かる")
    func brokenCenterFallsBack() {
        var orbit = fitting()
        orbit.center = Vector3(Float.nan, 0, 0)
        let fellBack = orbit.clampToLimits(fallbackCenter: Vector3(1, 2, 3))
        #expect(fellBack)
        #expect(orbit.center == Vector3(1, 2, 3))
        #expect(orbit.eye.x.isFinite && orbit.eye.y.isFinite && orbit.eye.z.isFinite)
    }

    @Test("面の大きさが数でない・無限の fitting も、収めれば視点として成り立つ")
    func fittingWithBrokenSizeFallsBack() {
        var orbit = Orbit.fitting(width: Float.nan, height: Float.infinity)
        let fellBack = orbit.clampToLimits(fallbackCenter: Vector3(32, 24, 0))
        #expect(fellBack)
        #expect(orbit.center == Vector3(32, 24, 0))
        #expect(orbit.distance.isFinite)
        #expect(orbit.eye.x.isFinite && orbit.eye.y.isFinite && orbit.eye.z.isFinite)
    }

    /// 無限の限界は使える値で、逆さに書いた限界と同じく入れ替えの規則で読む。
    /// 既定へ倒すのは数でない限界だけ。
    @Test("無限の限界は入れ替えの規則で読み、既定へ倒さない")
    func infiniteLimitsKeepTheSwapRule() {
        var farOnly = fitting()
        farOnly.minimumDistance = .infinity
        farOnly.maximumDistance = 500
        farOnly.distance = 100
        let farFellBack = farOnly.clampToLimits()
        #expect(!farFellBack)
        #expect(farOnly.minimumDistance == .infinity)
        // 「500 より遠く」
        #expect(farOnly.distance == 500)

        var nearOnly = fitting()
        nearOnly.maximumDistance = -.infinity
        nearOnly.distance = 1e9
        let nearFellBack = nearOnly.clampToLimits()
        #expect(!nearFellBack)
        #expect(nearOnly.maximumDistance == -.infinity)
        #expect(nearOnly.distance == nearOnly.minimumDistance)
    }
}
