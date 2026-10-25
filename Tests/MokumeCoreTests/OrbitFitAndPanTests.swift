// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Testing
import simd

@testable import MokumeCore

/// 読み込んだモデルに合わせて収める視点 (``Orbit/fitting(_:)``) と、平行移動の計算
/// (``Orbit/pan(dragX:dragY:through:width:height:)``) の検査 ([#2461])。**入力も GPU も要らない。**
///
/// 収める視点は、既定の整え方 (いちばん長い辺を面の短いほうの辺の半分へ) で作ったモデルの囲みの箱の
/// 8 隅を、既定の投影で写して面の内側に来るかで見る。**横長と正方形の面で見る** — 縦長の面では左右が
/// 切れうることは口の説明が名乗る代償で、ここでは確かめない。
///
/// [#2461]: https://github.com/mokume-metal/mokume/issues/2461
@Suite("視点を収める・ずらす")
struct OrbitFitAndPanTests {

    /// 囲みの箱が `size` になる直方体のモデルを、面 `width × height` の既定の整え方で作る。
    private static func box(_ size: SIMD3<Float>, width: Float, height: Float) -> Model {
        let (x, y, z) = (size.x / 2, size.y / 2, size.z / 2)
        var text = ""
        for corner in Self.corners(SIMD3(x, y, z), around: SIMD3(3, -1, 7)) {
            text += "v \(corner.x) \(corner.y) \(corner.z)\n"
        }
        // 面は向きを問わない。囲みの箱を決めるのは点だけである
        text += "f 1 2 3\nf 5 6 7\n"
        return Model.make(
            name: "box", parsed: ModelFile.parse(text), fitting: min(width, height) / 2)
    }

    /// 中心 `center`・半分の大きさ `half` の箱の 8 隅。
    private static func corners(_ half: SIMD3<Float>, around center: SIMD3<Float>) -> [SIMD3<Float>] {
        var found: [SIMD3<Float>] = []
        for sx: Float in [-1, 1] {
            for sy: Float in [-1, 1] {
                for sz: Float in [-1, 1] {
                    found.append(center + half * SIMD3(sx, sy, sz))
                }
            }
        }
        return found
    }

    /// 横長・正方形の面と、形の違う 3 つの箱 (立方体・平たい板・細長い棒)。
    static let cases: [(width: Float, height: Float, size: SIMD3<Float>)] = {
        var all: [(Float, Float, SIMD3<Float>)] = []
        for (width, height) in [(Float(1200), Float(600)), (640, 480), (400, 400)] {
            for size in [SIMD3<Float>(2, 2, 2), SIMD3(10, 0.5, 6), SIMD3(0.4, 8, 0.4)] {
                all.append((width, height, size))
            }
        }
        return all
    }()

    @Test("収めた視点では、既定の整え方のモデルの 8 隅が既定の投影で面の内側に写る", arguments: 0..<9)
    func fittedModelCornersAreInside(_ index: Int) {
        let (width, height, size) = Self.cases[index]
        let model = Self.box(size, width: width, height: height)
        let orbit = Orbit.fitting(model)
        let camera = Camera(
            eye: orbit.eye, center: orbit.center, up: orbit.up,
            projection: Camera.defaultPerspective(width: width, height: height))
        let matrix = camera.viewProjection(width: width, height: height)
        for corner in Self.corners(model.size.simd / 2, around: model.center.simd) {
            let clip = matrix * SIMD4(corner, 1)
            #expect(clip.w > 0, "\(size) の隅 \(corner) が目の後ろにある")
            let ndc = SIMD3(clip.x, clip.y, clip.z) / clip.w
            #expect(abs(ndc.x) < 1 && abs(ndc.y) < 1, "\(width)×\(height) で \(size) の隅 \(corner) が面の外: \(ndc)")
            #expect(ndc.z >= 0 && ndc.z <= 1, "\(width)×\(height) で \(size) の隅 \(corner) が手前か奥の面の外: \(ndc.z)")
        }
    }

    /// 囲みの球がちょうど収まる距離であって、遠すぎもしない (遠ざけるだけなら 8 隅は必ず収まる)。
    @Test("距離は、囲みの球が縦の画角にちょうど収まる長さで、見ている先は囲みの箱の中心")
    func distanceJustFitsTheSphere() {
        let model = Self.box(SIMD3(2, 2, 2), width: 640, height: 480)
        let orbit = Orbit.fitting(model)
        let radius = length(model.size.simd) / 2
        #expect(orbit.center == model.center)
        #expect(abs(orbit.distance - radius / RuntimeMath.sin(Float.pi / 6)) < 1e-3)
        #expect(orbit.yaw == 0 && orbit.pitch == 0)
        #expect(orbit.minimumDistance == orbit.distance / 10)
        #expect(orbit.maximumDistance == orbit.distance * 10)
    }

    @Test("大きさの無いモデルは、距離 1 の視点を返す")
    func emptyModelFallsBack() {
        let empty = Model.make(name: "empty", parsed: ModelFile.parse(""), fitting: 300)
        let orbit = Orbit.fitting(empty)
        #expect(orbit.distance == 1)
        #expect(orbit.center == Vector3(0, 0, 0))
        #expect(orbit.eye.x.isFinite && orbit.eye.y.isFinite && orbit.eye.z.isFinite)
    }

    @Test("面の大きさから収める視点は変わらない")
    func fittingTheSurfaceIsUnchanged() {
        let orbit = Orbit.fitting(width: 640, height: 480)
        let distance = Camera.fittingDistance(height: 480)
        #expect(orbit == Orbit(
            center: Vector3(320, 240, 0), distance: distance,
            minimumDistance: distance / 10, maximumDistance: distance * 10))
    }

    // MARK: - 平行移動

    /// 既定の視点では、奥行き 0 の 1 画素が世界の 1 の長さになる (`Camera.fittingDistance`)。
    private static func view(of orbit: Orbit, width: Float, height: Float) -> Camera {
        Camera(
            eye: orbit.eye, center: orbit.center, up: orbit.up,
            projection: Camera.defaultPerspective(width: width, height: height))
    }

    @Test("右へ 100 画素ずらすと、見ている先は画面の左の向きへ 100 画素ぶん動き、角も距離も変わらない")
    func panningRightMovesTheCenterLeft() {
        var orbit = Orbit.fitting(width: 640, height: 480)
        let before = orbit
        let moved = orbit.pan(
            dragX: 100, dragY: 0, through: Self.view(of: orbit, width: 640, height: 480),
            width: 640, height: 480)
        #expect(moved)
        #expect(abs(orbit.center.x - (before.center.x - 100)) < 1e-3)
        #expect(abs(orbit.center.y - before.center.y) < 1e-3)
        #expect(abs(orbit.center.z - before.center.z) < 1e-3)
        #expect(orbit.yaw == before.yaw && orbit.pitch == before.pitch && orbit.distance == before.distance)
    }

    @Test("下へずらすと、見ている先は画面の上の向き (縦軸の負) へ動く")
    func panningDownMovesTheCenterUp() {
        var orbit = Orbit.fitting(width: 640, height: 480)
        let before = orbit
        orbit.pan(
            dragX: 0, dragY: 50, through: Self.view(of: orbit, width: 640, height: 480),
            width: 640, height: 480)
        #expect(abs(orbit.center.y - (before.center.y - 50)) < 1e-3)
    }

    /// 回した視点でも、動く向きは画面の横 (視点の右) で、量は見ている先の奥行きの画素の長さ。
    @Test("回した視点でも、画面の横の向きへ、見ている先の奥行きの画素の長さだけ動く")
    func panningFollowsTheTurnedView() {
        var orbit = Orbit.fitting(width: 640, height: 480)
        orbit.yaw = 0.7
        orbit.pitch = 0.3
        orbit.distance *= 2
        let view = Self.view(of: orbit, width: 640, height: 480)
        let step = view.worldPerPixel(at: orbit.center.simd, width: 640, height: 480)
        let before = orbit.center.simd
        orbit.pan(dragX: 30, dragY: 0, through: view, width: 640, height: 480)
        let expected = before - view.right * (30 * step.x)
        #expect(length(orbit.center.simd - expected) < 1e-3)
        // 遠ざけたので、1 画素は世界の 1 より長い
        #expect(length(orbit.center.simd - before) > 30)
    }

    @Test("動かした先が有限にならなければ、見ている先を動かさない", arguments: [Float.infinity, .nan, 3e38])
    func overflowingPanHolds(_ amount: Float) {
        var orbit = Orbit.fitting(width: 640, height: 480)
        // 遠ざけて 1 画素を世界の 1 より長くする (3e38 画素ぶんが Float に収まらない)
        orbit.distance *= 4
        let before = orbit.center
        let moved = orbit.pan(
            dragX: amount, dragY: 0,
            through: Self.view(of: orbit, width: 640, height: 480), width: 640, height: 480)
        #expect(!moved)
        #expect(orbit.center == before)
    }
}
