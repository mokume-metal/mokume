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

    @Test("手で書いた値も限界へ収める")
    func handWrittenValuesAreClamped() {
        var orbit = fitting()
        orbit.pitch = 10
        orbit.distance = 1e9
        orbit.clampToLimits()
        #expect(orbit.pitch == Orbit.pitchLimit)
        #expect(orbit.distance == orbit.maximumDistance)
    }

    @Test("壊れた値を書いても、視点として成り立つ")
    func brokenValuesFallBackToSomethingUsable() {
        var orbit = fitting()
        orbit.pitch = .nan
        orbit.yaw = .infinity
        orbit.distance = .nan
        orbit.clampToLimits()
        #expect(orbit.pitch == 0)
        #expect(orbit.yaw == 0)
        #expect(orbit.distance == orbit.minimumDistance)
        #expect(orbit.eye.x.isFinite && orbit.eye.y.isFinite && orbit.eye.z.isFinite)
    }
}
