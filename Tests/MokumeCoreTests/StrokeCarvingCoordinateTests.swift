// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Testing
import simd

@testable import MokumeCore

/// 線の片の引き算は、原点から遠い座標でも片を消さず、裏返さない ([#2725])。CPU だけで確かめる。
///
/// 片の向きは面積の符号で決める。絶対座標のまま `Float` で足すと、原点から 1e5 離れた小さな片で
/// 刻み (1024) が面積を越え、符号が反転する・0 に潰れる。
///
/// [#2725]: https://github.com/mokume-metal/mokume/issues/2725
@Suite("線の片の引き算: 遠い座標")
nonisolated struct StrokeCarvingCoordinateTests {
    /// 出てきた片の、符号付きの面積 (`Double`・最初の点からの差で足す)。
    private nonisolated static func area(_ points: [SIMD2<Float>]) -> Double {
        let origin = SIMD2<Double>(points[0])
        var sum = 0.0
        for index in points.indices {
            let a = SIMD2<Double>(points[index]) - origin
            let b = SIMD2<Double>(points[(index + 1) % points.count]) - origin
            sum += a.x * b.y - a.y * b.x
        }
        return sum / 2
    }

    /// 縦 `height`・横 `width` の長方形の周。`clockwise` なら時計回りに並べる。
    private nonisolated static func rectangle(
        _ x: Float, _ y: Float, _ width: Float, _ height: Float, clockwise: Bool
    ) -> [SIMD2<Float>] {
        let ring = [SIMD2(x, y), SIMD2(x + width, y), SIMD2(x + width, y + height), SIMD2(x, y + height)]
        return clockwise ? ring.reversed() : ring
    }

    /// 片を積んで引いた残りの面積の和と、残りが全部反時計回りか。
    private nonisolated static func carvedArea(_ rings: [[SIMD2<Float>]]) -> (area: Double, pieces: Int, ccw: Bool) {
        var carving = StrokeCarving(
            points: rings.indices.map { SIMD2(Float($0), 0) }, isClosed: false, weight: 1,
            wholeOutline: true)
        for (index, ring) in rings.enumerated() {
            carving.addPoint(index) { $0.append(contentsOf: ring) }
        }
        var total = 0.0
        var pieces = 0
        var ccw = true
        carving.carved { points, rim, _, _ in
            let piece = Array(points[rim])
            let value = area(piece)
            total += value
            pieces += 1
            if value <= 0 { ccw = false }
        }
        return (total, pieces, ccw)
    }

    /// 小さな片 (面積 3〜24) は、どの向きで渡しても、消えずに反時計回りで出る。
    @Test(
        "小さな片は、原点から 1e5 離れても消えず、反時計回りで出る (#2725)",
        arguments: [0.0, 100_000], [false, true])
    func smallPiecesSurviveFarFromOrigin(_ offset: Double, clockwise: Bool) {
        let shift = Float(offset)
        let sizes: [(Float, Float)] = [(10, 2), (3, 1.5), (6, 4), (12, 2), (0.5, 6), (7, 3)]
        for (width, height) in sizes {
            let ring = Self.rectangle(shift + 123, shift + 77, width, height, clockwise: clockwise)
            let result = Self.carvedArea([ring])
            #expect(result.pieces == 1, "\(width)×\(height): 片が \(result.pieces) 個")
            #expect(result.ccw, "\(width)×\(height): 反時計回りで出ていない")
            #expect(abs(result.area - Double(width * height)) < 1e-3, "\(width)×\(height): \(result.area)")
        }
    }

    /// 重なる 2 つの片は、残りの面積の和が和集合 (10×2 と 10×2 が 2 だけ重なる = 36) と同じ。
    @Test(
        "重なる 2 つの片の残りの面積の和は、原点から 1e5 離れても和集合と同じ (#2725)",
        arguments: [0.0, 100_000], [false, true])
    func overlappingPiecesKeepTheirUnion(_ offset: Double, clockwise: Bool) {
        let shift = Float(offset)
        let first = Self.rectangle(shift + 50, shift + 20, 10, 2, clockwise: clockwise)
        let second = Self.rectangle(shift + 58, shift + 20, 10, 2, clockwise: clockwise)
        let result = Self.carvedArea([first, second])
        #expect(result.ccw)
        #expect(abs(result.area - 36) < 1e-3, "和集合 36 に対して \(result.area)")
    }
}
