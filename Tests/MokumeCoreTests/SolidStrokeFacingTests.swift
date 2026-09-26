// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Testing
import simd

@testable import MokumeCore

/// 立体の線の帯を、**画面に写した線の垂線**へ向けているかの検査 (#1546)。GPU を要する。
///
/// 透視投影では、奥行きのある線は画面の中心から外れるほど斜めに写る。帯の横向きを
/// カメラ全体の軸との外積で決めると、画面での帯の向きが線の向きと
/// ずれて細り、ずれが揃うと線が消える。見るのは「どの向きの線も `strokeWeight` の
/// 画素の太さで出る」ことで、数え方は Issue の完了条件のとおりにする。
@Suite(
    "立体の線の帯の向き",
    .enabled(
        if: RenderDevice.isAvailable,
        "この世代のコマンド構造に対応した GPU が無い実行環境ではスキップする")
)
struct SolidStrokeFacingTests {
    private let size = 160

    /// 画面での線分 (端点は画素の角を整数に取る面の座標)。
    private struct ScreenSegment {
        var start: SIMD2<Float>
        var end: SIMD2<Float>
    }

    /// 線分を 1 本以上引いた絵と、その線分を画面へ落とした位置。
    ///
    /// 画面へ落とすのは描いたのと同じ視点の下で、変換を戻したあとに行う (点は世界の座標)。
    private func render(
        weight: Float, orthographic: Bool = false,
        segments: [(SIMD3<Float>, SIMD3<Float>)] = [],
        extra: ((Canvas) -> Void)? = nil,
        measured: [(SIMD3<Float>, SIMD3<Float>)]
    ) throws -> (PixelBuffer, [ScreenSegment]) {
        let canvas = try CanvasFixture.make(gpu: RenderDevice(), width: size, height: size)
        var screen: [ScreenSegment] = []
        try canvas.draw {
            canvas.background(.linear(red: 0, green: 0, blue: 0))
            if orthographic { canvas.ortho() }
            canvas.noFill()
            canvas.stroke(.linear(red: 1, green: 1, blue: 1))
            canvas.strokeWeight(weight)
            for (a, b) in segments {
                canvas.beginShape(.lines)
                canvas.vertex(a.x, a.y, a.z)
                canvas.vertex(b.x, b.y, b.z)
                canvas.endShape()
            }
            extra?(canvas)
            screen = measured.map { a, b in
                ScreenSegment(
                    start: SIMD2(canvas.screenX(a.x, a.y, a.z), canvas.screenY(a.x, a.y, a.z)),
                    end: SIMD2(canvas.screenX(b.x, b.y, b.z), canvas.screenY(b.x, b.y, b.z)))
            }
        }
        return (try canvas.target.readPixels(), screen)
    }

    /// 画面での太さ。線分の長さの 30〜70% の区間に中心がある画素のうち、線から垂直に
    /// `reach` 画素以内にあるものの線形の赤を足し、区間の長さで割る。端の丸は入らない。
    private func screenThickness(
        _ image: PixelBuffer, _ segment: ScreenSegment, reach: Float = 10
    ) -> Float {
        let delta = segment.end - segment.start
        let length = simd_length(delta)
        guard length > 0 else { return 0 }
        let along = delta / length
        let across = SIMD2(-along.y, along.x)
        var sum: Float = 0
        for y in 0..<image.height {
            for x in 0..<image.width {
                let offset = SIMD2(Float(x) + 0.5, Float(y) + 0.5) - segment.start
                let t = simd_dot(offset, along) / length
                guard t >= 0.3, t <= 0.7, abs(simd_dot(offset, across)) <= reach else { continue }
                sum += image[x, y].red
            }
        }
        return sum / (0.4 * length)
    }

    /// 1 本だけ引いた線の画面での太さ。
    private func thickness(
        _ a: SIMD3<Float>, _ b: SIMD3<Float>, weight: Float, orthographic: Bool = false
    ) throws -> Float {
        let (image, screen) = try render(
            weight: weight, orthographic: orthographic, segments: [(a, b)], measured: [(a, b)])
        return screenThickness(image, screen[0])
    }

    private func isNear(_ value: Float, _ expected: Float, within ratio: Float = 0.1) -> Bool {
        abs(value - expected) <= expected * ratio
    }

    // MARK: - 視線の軸と平行な線

    @Test("視線の軸と平行な線も、ずらした線も、太さ 6 の画素で出る")
    func lineAlongTheViewAxisKeepsItsWeight() throws {
        let straight = try thickness(SIMD3(50, 90, 30), SIMD3(50, 90, -30), weight: 6)
        #expect(isNear(straight, 6), "平行な線が \(straight) 画素 (起票時 1.91)")
        let nudged = try thickness(SIMD3(50, 90, 30), SIMD3(50, 90.01, -30), weight: 6)
        #expect(isNear(nudged, 6), "y にずらした線が \(nudged) 画素 (起票時 1.91)")
    }

    @Test(
        "太さ 4 の奥行きの線は、ずらす向きによらず 4 画素で出る",
        arguments: [SIMD3<Float>(0, 0, 0), SIMD3(0.01, 0, 0), SIMD3(0, 0.01, 0)])
    func lineAlongTheViewAxisOffCenter(_ nudge: SIMD3<Float>) throws {
        let value = try thickness(SIMD3(120, 30, 40), SIMD3(120, 30, -40) + nudge, weight: 4)
        #expect(isNear(value, 4), "ずらし \(nudge) の線が \(value) 画素 (起票時 3.16 / 2.48 / 3.10)")
    }

    @Test("画面の中心の真下でほぼ平行な線は消えない")
    func nearlyParallelLineDoesNotVanish() throws {
        let value = try thickness(SIMD3(80, 130, 40), SIMD3(80.01, 130, -40), weight: 4)
        #expect(isNear(value, 4), "ほぼ平行な線が \(value) 画素 (起票時 0.00)")
    }

    // MARK: - 平行でない奥行きのある線

    @Test("平行でない奥行きのある線も、太さ 4 の画素で出る")
    func slantedDepthLineKeepsItsWeight() throws {
        let value = try thickness(SIMD3(100, 40, 40), SIMD3(130, 60, -40), weight: 4)
        #expect(isNear(value, 4), "奥行きのある線が \(value) 画素 (起票時 2.97)")
    }

    @Test("回していない箱の奥行きの辺は、どれも太さ 6 の画素で出る")
    func unrotatedBoxDepthEdgesKeepTheirWeight() throws {
        // 角 (10, 10) の辺は奥の面の辺と重なるので数えない
        let corners: [SIMD2<Float>] = [SIMD2(-10, -10), SIMD2(10, -10), SIMD2(-10, 10)]
        let edges = corners.map { corner in
            (SIMD3(30 + corner.x, 30 + corner.y, 30), SIMD3(30 + corner.x, 30 + corner.y, -30))
        }
        let (image, screen) = try render(
            weight: 6,
            extra: { canvas in
                canvas.push()
                canvas.translate(30, 30, 0)
                canvas.box(20, 20, 60)
                canvas.pop()
            },
            measured: edges)
        for (corner, segment) in zip(corners, screen) {
            let value = screenThickness(image, segment, reach: 5)
            #expect(isNear(value, 6), "角 \(corner) の辺が \(value) 画素 (起票時 4.28 / 5.19 / 3.51)")
        }
    }

    // MARK: - いま正しいもの

    @Test("画面と平行な線と平行投影の線は、太さ 4 の画素のまま")
    func alreadyCorrectLinesStay() throws {
        let flat = try thickness(SIMD3(100, 40, 0), SIMD3(130, 60, 0), weight: 4)
        #expect(abs(flat - 4.16) <= 0.05, "画面と平行な線が \(flat) 画素")
        let ortho = try thickness(
            SIMD3(100, 40, 40), SIMD3(130, 60, -40), weight: 4, orthographic: true)
        #expect(abs(ortho - 4.16) <= 0.05, "平行投影の線が \(ortho) 画素")
    }
}
