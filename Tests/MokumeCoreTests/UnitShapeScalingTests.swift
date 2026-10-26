// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Testing
import simd

@testable import MokumeCore

/// 単位の形 × 軸ごとの倍率が、寸法ごとに組んだ形と 1 ビットも違わないこと (#1862・#2386)。
/// GPU は要らない — 塗りの頂点関数と線の骨が広げる前の値を、CPU の組み立てと突き合わせる。
@Suite("単位の形と倍率 (#2386)")
nonisolated struct UnitShapeScalingTests {
    /// 再現できる乱数 (SplitMix64)。寸法を 0.001〜3000 の対数で散らす。
    private struct Dimensions {
        var state: UInt64

        mutating func next() -> Float {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            z ^= z >> 31
            let unit = Double(z >> 11) / Double(1 << 53)
            return Float(pow(10, unit * 6.477 - 3))
        }
    }

    /// 寸法を散らした形。整数の寸法 (箱の向きが 1 ulp ずれていた `box(50, 80, 20)` を含む) と、
    /// 乱数の寸法と、極端な比を混ぜる。
    static let shapes: [SolidShape] = {
        var shapes: [SolidShape] = [
            .box(width: 50, height: 80, depth: 20), .box(width: 200, height: 10, depth: 3),
            .box(width: 1, height: 1, depth: 1), .box(width: 1e-20, height: 3e-19, depth: 7),
            .box(width: 3e18, height: 2e18, depth: 1e18), .box(width: 1000, height: 0.01, depth: 1),
            .plane(width: 8, height: 6), .plane(width: 1e-3, height: 4000),
            .cylinder(radius: 10, height: 20, detail: 24), .cylinder(radius: 3000, height: 0.002, detail: 7),
            .cylinder(radius: 0.01, height: 900, detail: 128), .cylinder(radius: 1, height: 1, detail: 3),
            .sphere(radius: 3.013, detail: 24), .sphere(radius: 917.3, detail: 12),
        ]
        var dimensions = Dimensions(state: 2386)
        for detail in [3, 7, 24, 48, 128] {
            for _ in 0..<6 {
                shapes.append(.box(width: dimensions.next(), height: dimensions.next(), depth: dimensions.next()))
                shapes.append(.plane(width: dimensions.next(), height: dimensions.next()))
                shapes.append(.cylinder(radius: dimensions.next(), height: dimensions.next(), detail: detail))
                shapes.append(.sphere(radius: dimensions.next(), detail: detail))
            }
        }
        return shapes
    }()

    private static func bits(_ value: SIMD3<Float>) -> [UInt32] {
        [value.x.bitPattern, value.y.bitPattern, value.z.bitPattern]
    }

    @Test("単位の形の点 × 倍率は、寸法ごとに組んだ形の位置・向き・貼る絵の座標と 1 ビットも違わない")
    func unitPointsTimesScaleMatchTheBuilder() throws {
        for shape in Self.shapes {
            let (unit, scale) = try #require(shape.unitScaling, "\(shape) が単位の形を持たない")
            let built = shape.make().points
            let units = unit.make().points
            try #require(built.count == units.count, "\(shape): 点の数が違う")
            // 条件は 1 つずつ Bool に受けてから束ねる。`||` で 1 つの式に連ねると型検査に
            // 2 秒強かかる (#2596)
            let differing = zip(built, units).filter { built, unit in
                let position: Bool = Self.bits(built.position) != Self.bits(unit.position * scale)
                let normal: Bool = Self.bits(built.normal) != Self.bits(unit.normal)
                let uv: Bool = built.uv.x.bitPattern != unit.uv.x.bitPattern
                    || built.uv.y.bitPattern != unit.uv.y.bitPattern
                let derived: Bool = built.isDerivedNormal != unit.isDerivedNormal
                return position || normal || uv || derived
            }.count
            #expect(differing == 0, "\(shape): \(differing) 点が違う")
        }
    }

    @Test("稜線を共有できる寸法では、単位の形の稜線 × 倍率が、寸法ごとに取り出した稜線と点も辺も同じ")
    func unitEdgesTimesScaleMatchTheBuilder() throws {
        var shared = 0
        for shape in Self.shapes {
            guard let (unit, scale) = shape.unitEdgeScaling else { continue }
            shared += 1
            let built = SolidEdges(shape.make())
            let scaled = SolidEdges(unit.make()).scaled(by: scale)
            #expect(built.points.map(Self.bits) == scaled.points.map(Self.bits), "\(shape): 稜線の点が違う")
            #expect(
                built.edges.map { [$0.0, $0.1] } == scaled.edges.map { [$0.0, $0.1] }, "\(shape): 稜線の辺が違う")
        }
        // 前提: ほとんどの寸法は稜線を共有する (断るのは極端に細い形だけ)
        #expect(shared > Self.shapes.count * 3 / 4, "共有したのは \(shared) / \(Self.shapes.count)")
    }

    /// 溶接の許容差は最も長い軸で決まるので、最も短い軸が許容差を割る形では別の点が溶け合う。
    /// そういう寸法は共有を断り、寸法ごとに取り出す (断らなければ稜線が食い違う)。
    @Test(
        "最も短い軸が溶接の許容差を割るほど細い形は、稜線を共有しない",
        arguments: [
            SolidShape.box(width: 1, height: 1, depth: 1e-6),
            .plane(width: 4000, height: 0.01),
            .cylinder(radius: 1, height: 1e-6, detail: 24),
            .cylinder(radius: 1e-3, height: 1000, detail: 128),
        ])
    func thinShapesKeepTheirOwnEdges(_ shape: SolidShape) throws {
        #expect(shape.unitEdgeScaling == nil, "\(shape) の稜線を共有してしまう")
        // 塗りは溶接しないので、細くても単位の形を共有する
        let (unit, scale) = try #require(shape.unitScaling)
        let built = SolidEdges(shape.make())
        let scaled = SolidEdges(unit.make()).scaled(by: scale)
        #expect(built.points.count != scaled.points.count, "\(shape): 断る理由の前提 (点が溶け合う) が崩れた")
    }

    @Test("境目のすぐ内側の細い形は、稜線を共有しても食い違わない")
    func thinShapesJustInsideTheBoundaryStillMatch() throws {
        // 箱の許容差は最も長い軸の半分 × 1e-5。最も短い軸がその 2 倍をわずかに超える (円柱は半径 × 1e-5)
        for shape in [
            SolidShape.box(width: 1, height: 1, depth: 1.01e-5), .box(width: 3000, height: 0.0301, depth: 7),
            .cylinder(radius: 1, height: 2.1e-5, detail: 24),
        ] {
            let (unit, scale) = try #require(shape.unitEdgeScaling, "\(shape) が境目の内側に入っていない")
            let built = SolidEdges(shape.make())
            let scaled = SolidEdges(unit.make()).scaled(by: scale)
            #expect(built.points.map(Self.bits) == scaled.points.map(Self.bits), "\(shape): 稜線の点が違う")
            #expect(built.edges.map { [$0.0, $0.1] } == scaled.edges.map { [$0.0, $0.1] }, "\(shape): 稜線の辺が違う")
        }
    }

    @Test(
        "向きが寸法の比で変わる形・潰れた寸法・向きの積が溢れる箱は、単位の形を持たない",
        arguments: [
            SolidShape.cone(radius: 10, height: 20, detail: 24),
            .ellipsoid(radiusX: 10, radiusY: 20, radiusZ: 30, detail: 24),
            .torus(ringRadius: 20, tubeRadius: 5, detail: 24),
            .box(width: 0, height: 10, depth: 10), .plane(width: 10, height: 0),
            .cylinder(radius: 0, height: 10, detail: 24), .sphere(radius: 0, detail: 24),
            .box(width: 3e20, height: 3e20, depth: 1), .box(width: 1e-30, height: 1e-30, depth: 1),
        ])
    func shapesWithoutUnitScaling(_ shape: SolidShape) {
        #expect(shape.unitScaling == nil)
        #expect(shape.unitEdgeScaling == nil)
    }
}
