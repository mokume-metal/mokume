// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Testing
import simd

@testable import MokumeCore

/// CPU で線を組む間に使う視点の量 (``StrokeCamera``) が、``Camera`` と 1 ビットも違わない
/// ことの検査 ([#1785])。GPU を要さない。
///
/// 線の頂点はこの値から組むので、1 ビットでもずれると線の縁の画素が動く。先に求めておく
/// 係数 (`2 * tan(fov / 2)`) が、``Camera/worldPerPixel(at:height:)`` の式と同じ順で
/// 計算されていることを、透視・平行・手前の面より手前の点で見る。
///
/// [#1785]: https://github.com/mokume-metal/mokume/issues/1785
@Suite("線を組む間の視点の量")
struct StrokeCameraTests {
    private static let points: [SIMD3<Float>] = [
        SIMD3(0, 0, 0), SIMD3(123.25, -47.5, 30), SIMD3(-900, 400, -2500), SIMD3(1e-3, 7, 866),
    ]

    private static func cameras() -> [Camera] {
        var perspective = Camera.fitting(width: 800, height: 600)
        perspective.eye = SIMD3(120, -80, 700)
        perspective.center = SIMD3(10, 20, -30)
        var orthographic = perspective
        orthographic.projection = Camera.Projection.orthographic(
            left: -400, right: 400, bottom: 300, top: -300, near: 1, far: 5000)
        var tilted = Camera.fitting(width: 1920, height: 1080)
        tilted.up = SIMD3(0.3, 1, 0.1)
        return [perspective, orthographic, tilted]
    }

    @Test("向きと 1 画素の長さが、Camera とビット単位で一致する")
    func matchesTheCamera() {
        for camera in Self.cameras() {
            let stroke = StrokeCamera(camera)
            #expect(stroke.eye == camera.eye)
            #expect(stroke.forward == camera.forward)
            #expect(stroke.right == camera.right)
            #expect(stroke.down == camera.down)
            for point in Self.points {
                for height in [Float(600), 1080, 37] {
                    let expected = camera.worldPerPixel(at: point, height: height)
                    let actual = stroke.worldPerPixel(at: point, height: height)
                    #expect(
                        actual.bitPattern == expected.bitPattern,
                        "\(camera.projection) \(point) \(height): \(actual) != \(expected)")
                }
            }
        }
    }
}
