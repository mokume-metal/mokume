// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Testing
import simd

@testable import MokumeCore

/// CPU で線を組む間に使う視点の量 (``StrokeCamera``) が、``Camera`` と 1 ビットも違わない
/// ことの検査 ([#1785])。GPU を要さない。
///
/// 線の頂点はこの値から組むので、1 ビットでもずれると線の縁の画素が動く。先に求めておく
/// 係数 (`2 * tan(fov / 2)`) が、``Camera/worldPerPixel(at:width:height:)`` の式と同じ順で
/// 計算されていることを、透視・平行・手前の面より手前の点で見る。
///
/// 投影の縦横比が面と違うとき、画面の横 1 画素と縦 1 画素は世界で長さが違う ([#2176])。
/// 横と縦を別々に測ること、面と同じ縦横比の投影では比がちょうど 1 になること (線の頂点が
/// 比を持たなかった頃と 1 ビットも変わらない条件) と、線を画面の画素で組む口 (`screenNormal`・
/// `world(_:)`・`onScreen(_:)`) が縦横比を違えた投影でも画面の垂線・画素の長さになることを見る。
///
/// [#1785]: https://github.com/mokume-metal/mokume/issues/1785
/// [#2176]: https://github.com/mokume-metal/mokume/issues/2176
@Suite("線を組む間の視点の量")
struct StrokeCameraTests {
    private static let points: [SIMD3<Float>] = [
        SIMD3(0, 0, 0), SIMD3(123.25, -47.5, 30), SIMD3(-900, 400, -2500), SIMD3(1e-3, 7, 866),
    ]

    private static func cameras() -> [Camera] {
        var perspective = Camera.fitting(width: 800, height: 600)
        perspective.eye = Vector3(120, -80, 700)
        perspective.center = Vector3(10, 20, -30)
        var orthographic = perspective
        orthographic.projection = Camera.Projection.orthographic(
            left: -400, right: 400, bottom: 300, top: -300, near: 1, far: 5000)
        var tilted = Camera.fitting(width: 1920, height: 1080)
        tilted.up = Vector3(0.3, 1, 0.1)
        return [perspective, orthographic, tilted]
    }

    /// 面の大きさ (幅, 高さ)。縦横比が `cameras()` の投影と合うものも合わないものも含める。
    private static let sizes: [(Float, Float)] = [(800, 600), (1920, 1080), (50, 37)]

    @Test("向きと 1 画素の長さが、Camera とビット単位で一致する")
    func matchesTheCamera() {
        for camera in Self.cameras() {
            for (width, height) in Self.sizes {
                let stroke = StrokeCamera(camera, width: width, height: height)
                #expect(stroke.eye == camera.eye.simd)
                #expect(stroke.forward == camera.forward)
                #expect(stroke.screenRight == camera.right * stroke.pixelAspect)
                #expect(stroke.down == camera.down)
                #expect(
                    stroke.pixelAspect.bitPattern == camera.pixelAspect(width: width, height: height).bitPattern)
                for point in Self.points {
                    let expected = camera.worldPerPixel(at: point, width: width, height: height)
                    let actual = stroke.worldPerPixel(at: point, height: height)
                    #expect(
                        actual.bitPattern == expected.y.bitPattern,
                        "\(camera.projection) \(point) \(height): \(actual) != \(expected.y)")
                    #expect(
                        (actual * stroke.pixelAspect).bitPattern == expected.x.bitPattern,
                        "\(camera.projection) \(point) \(width): 横の長さが一致しない")
                }
            }
        }
    }

    // MARK: - 横と縦の 1 画素

    /// 面の縦横比で作った投影は、横の 1 画素と縦の 1 画素が世界で同じ長さになる (比がちょうど 1)。
    /// 線を組む式はこのとき比を持たなかった頃と 1 ビットも変わらない (台帳が動かない条件)。
    @Test("面の縦横比で作った投影では、横の 1 画素と縦の 1 画素が同じ長さになる", arguments: [
        (800, 600), (1920, 1080), (200, 200), (1280, 720), (333, 111), (1, 3), (1000, 7),
    ] as [(Float, Float)])
    func matchingProjectionsHaveUnitAspect(width: Float, height: Float) {
        let fitting = Camera.fitting(width: width, height: height)
        #expect(fitting.pixelAspect(width: width, height: height) == 1)
        // 利用者が `perspective(fov, width / height, …)` と書いた形
        var written = fitting
        written.projection = .perspective(fieldOfView: 1.1, aspect: width / height, near: 5, far: 900)
        #expect(written.pixelAspect(width: width, height: height) == 1)
        var orthographic = fitting
        orthographic.projection = Camera.defaultOrthographic(width: width, height: height)
        #expect(orthographic.pixelAspect(width: width, height: height) == 1)
        for point in Self.points {
            for camera in [fitting, written, orthographic] {
                let length = camera.worldPerPixel(at: point, width: width, height: height)
                #expect(length.x == length.y)
            }
        }
    }

    /// 範囲があふれる投影 (`abs(right - left)` が無限になる) は、投影の横が潰れて絵に写らない。
    /// 比が無限や 0 になって、線の頂点が数でなくなることはない。
    @Test("横の範囲があふれる投影でも、比は数のままで、線を組む量は有限になる")
    func overflowingProjectionsKeepAFiniteAspect() throws {
        var camera = Camera.fitting(width: 200, height: 200)
        camera.projection = .orthographic(
            left: -3e38, right: 3e38, bottom: 100, top: -100, near: 10, far: 2000)
        #expect(camera.pixelAspect(width: 200, height: 200) == 1)
        let stroke = StrokeCamera(camera, width: 200, height: 200)
        let normal = try #require(stroke.screenNormal(SIMD3(80, 80, 0), SIMD3(120, 120, 0)))
        #expect(normal.x.isFinite && normal.y.isFinite)
        #expect(stroke.world(normal).x.isFinite)
    }

    @Test("縦横比を面と違えた投影では、横の 1 画素と縦の 1 画素が別々に測られる")
    func mismatchedProjectionsMeasureSeparately() {
        var camera = Camera.fitting(width: 200, height: 200)
        let point = SIMD3<Float>(100, 100, 0)
        // 透視: aspect 0.5 → 横の 1 画素は縦の半分 (横が 2 倍に伸びて写る)
        camera.projection = .perspective(fieldOfView: .pi / 3, aspect: 0.5, near: 10, far: 2000)
        let perspective = camera.worldPerPixel(at: point, width: 200, height: 200)
        #expect(perspective.y == camera.worldPerPixel(at: point, width: 200, height: 200).y)
        #expect(abs(perspective.y - 1) < 1e-4)
        #expect(perspective.x == perspective.y * 0.5)
        // 平行: 範囲の横 100 を 200 画素・縦 200 を 200 画素に写す
        camera.projection = .orthographic(left: -50, right: 50, bottom: 100, top: -100, near: 10, far: 2000)
        let orthographic = camera.worldPerPixel(at: point, width: 200, height: 200)
        #expect(orthographic.y == 1)
        #expect(orthographic.x == 0.5)
        // 横が縦より長くなる側 (aspect 2) でも、位置によらない比で測る
        camera.projection = .perspective(fieldOfView: .pi / 3, aspect: 2, near: 10, far: 2000)
        for far in [SIMD3<Float>(100, 100, -500), SIMD3<Float>(30, 40, 120)] {
            let length = camera.worldPerPixel(at: far, width: 200, height: 200)
            #expect(length.x == length.y * 2)
        }
    }

    // MARK: - 画面の画素で組む口

    /// 点を画面の画素の位置へ写す (`viewProjection` を通す。縦は下向き)。
    private static func pixel(_ point: SIMD3<Float>, _ camera: Camera, width: Float, height: Float) -> SIMD2<Float> {
        let clip = camera.viewProjection(width: width, height: height) * SIMD4(point, 1)
        let ndc = SIMD2(clip.x, clip.y) / clip.w
        return SIMD2((ndc.x + 1) / 2 * width, (1 - ndc.y) / 2 * height)
    }

    /// 縦横比を違えた投影で、`screenNormal` は画面に写した線に直交し (画素の座標で)、`world(_:)` で
    /// 世界へ直して `half × 縦の 1 画素` を掛けた動きは、画面でちょうど `half` 画素動く。
    @Test("縦横比を違えた投影でも、帯の垂線は画面の画素で線に直交し、動きは画面の画素の長さになる")
    func normalIsPerpendicularOnScreen() throws {
        let width: Float = 200
        let height: Float = 160
        var skewed = Camera.fitting(width: width, height: height)
        skewed.eye = Vector3(130, 60, 260)
        skewed.center = Vector3(90, 90, 10)
        let projections: [Camera.Projection] = [
            .perspective(fieldOfView: 1.0, aspect: 0.5, near: 10, far: 2000),
            .perspective(fieldOfView: 1.0, aspect: 3, near: 10, far: 2000),
            .orthographic(left: -50, right: 50, bottom: 80, top: -80, near: 10, far: 2000),
            .orthographic(left: -200, right: 200, bottom: 40, top: -40, near: 10, far: 2000),
        ]
        let segments: [(SIMD3<Float>, SIMD3<Float>)] = [
          (SIMD3(80, 80, 0), SIMD3(120, 120, 0)), (SIMD3(60, 100, 20), SIMD3(140, 90, -30)),
          (SIMD3(100, 40, 0), SIMD3(100, 140, 0)), (SIMD3(40, 100, 10), SIMD3(160, 100, 10)),
        ]
        for projection in projections {
            var camera = skewed
            camera.projection = projection
            let stroke = StrokeCamera(camera, width: width, height: height)
            // 画面の下は縦の成分が増える向き (この検査の物差しの確認)
            let origin = Self.pixel(SIMD3(100, 100, 0), camera, width: width, height: height)
            let below = Self.pixel(SIMD3(100, 100, 0) + camera.down * 5, camera, width: width, height: height)
            #expect(below.y > origin.y)
            for (a, b) in segments {
                let normal = try #require(stroke.screenNormal(a, b), "\(projection) \(a) \(b)")
                #expect(abs(length(normal) - 1) < 1e-5)
                let (pa, pb) = (
                    Self.pixel(a, camera, width: width, height: height), Self.pixel(b, camera, width: width, height: height)
                )
                let along = normalize(pb - pa)
                #expect(abs(dot(along, normal)) < 1e-3, "\(projection) \(a) \(b): 垂線が線に直交しない \(dot(along, normal))")
                // 画面で 10 画素動く世界の動き (縦の 1 画素 × 10 を、横と縦の成分に直す) を中点に足す
                let middle = (a + b) / 2
                let step = stroke.world(normal) * (10 * stroke.worldPerPixel(at: middle, height: height))
                let moved = Self.pixel(middle + step, camera, width: width, height: height)
                let still = Self.pixel(middle, camera, width: width, height: height)
                // 奥行きが動いても画面の位置が変わらないよう、視線に直交する動きだけを足している
                #expect(abs(length(moved - still) - 10) < 0.05, "\(projection) \(a) \(b): 画面で \(length(moved - still)) 画素動く")
                // 世界の向きに直した成分を画面の成分へ戻すと、元の成分になる
                let back = stroke.onScreen(stroke.world(normal))
                #expect(length(back - normal) < 1e-5)
            }
        }
    }
}
