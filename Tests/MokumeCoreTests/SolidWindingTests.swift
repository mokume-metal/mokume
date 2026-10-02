// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Testing
import simd

@testable import MokumeCore

/// 形から巻き方の向きを求める検査 (``SolidWinding``)。GPU は要らない。
///
/// 裏 → 表の順で描くとき、どちらが裏かは巻き方で決まる
/// ([#1549](https://github.com/mokume-metal/mokume/issues/1549))。内向きの形を外向きと
/// 取り違えると奥の面がどの向きでも捨てられ、閉じていない形を取り違えると絵が崩れうるので、
/// 求まらないものは求まらないと言うことも見る。
@Suite("立体の巻き方の向き")
struct SolidWindingTests {
    /// 組み込みの形の点を、同じ位置を同じ値に揃えて並べ直す。
    ///
    /// 組み込みの球や筒は継ぎ目の点を三角関数で別々に求めるので、ビットまでは一致しない
    /// (組み込みの形は向きを求めずに外向きとして扱うので、それで困らない)。読み込んだモデルと
    /// 同じく「同じ角は同じ値」の並びにしてから向きを求める。
    private func welded(_ shape: SolidShape) -> [SIMD3<Float>] {
        let positions = shape.make().points.map(\.position)
        var canonical: [SIMD3<Float>] = []
        var result: [SIMD3<Float>] = []
        for position in positions {
            if let near = canonical.first(where: { simd_distance($0, position) < 1e-3 }) {
                result.append(near)
            } else {
                canonical.append(position)
                result.append(position)
            }
        }
        return result
    }

    @Test(
        "閉じた組み込みの形は、どれも外向きに巻いてある",
        arguments: [
            SolidShape.box(width: 20, height: 30, depth: 40),
            .sphere(radius: 10, detail: 12),
            .ellipsoid(radiusX: 10, radiusY: 6, radiusZ: 4, detail: 12),
            .cylinder(radius: 10, height: 20, detail: 12),
            .cone(radius: 10, height: 20, detail: 12),
            .torus(ringRadius: 10, tubeRadius: 3, detail: 12),
        ])
    func builtInClosedShapesAreOutward(_ shape: SolidShape) {
        #expect(SolidWinding.of(welded(shape)) == .outward)
    }

    @Test("巻き方を裏返した形は内向き")
    func reversedShapesAreInward() {
        var positions = welded(.sphere(radius: 10, detail: 12))
        var first = 0
        while first + 2 < positions.count {
            positions.swapAt(first + 1, first + 2)
            first += 3
        }
        #expect(SolidWinding.of(positions) == .inward)
    }

    @Test("閉じていない形は求まらない")
    func openShapesAreUnknown() {
        #expect(SolidWinding.of(SolidShape.plane(width: 10, height: 10).make().points.map(\.position)) == .unknown)
        // 箱から 1 枚抜いた形
        let box = SolidShape.box(width: 10, height: 10, depth: 10).make().points.map(\.position)
        #expect(SolidWinding.of(Array(box.dropLast(3))) == .unknown)
    }

    @Test("巻き方が揃っていない形は求まらない")
    func inconsistentWindingIsUnknown() {
        var positions = SolidShape.box(width: 10, height: 10, depth: 10).make().points.map(\.position)
        positions.swapAt(1, 2)
        #expect(SolidWinding.of(positions) == .unknown)
    }
}
