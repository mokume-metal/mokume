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

    /// 箱の三角形 (外向き) を、`scale` 倍して `offset` へ動かしたもの。`inward` なら巻き方を裏返す。
    private func box(scale: Float = 1, offset: SIMD3<Float> = .zero, inward: Bool = false) -> [SIMD3<Float>] {
        var positions = SolidShape.box(width: 2, height: 2, depth: 2).make().points.map {
            $0.position * scale + offset
        }
        if inward {
            var first = 0
            while first + 2 < positions.count {
                positions.swapAt(first + 1, first + 2)
                first += 3
            }
        }
        return positions
    }

    @Test("原点から遠くに置いた小さな閉じた形も、向きが求まる")
    func farFromTheOriginIsStillOutward() {
        // 体積は平行移動で変わらない。閾値を原点からの距離で測ると、ここが求まらなくなる
        #expect(SolidWinding.of(box(scale: 0.5, offset: SIMD3(1000, 1000, 1000))) == .outward)
        #expect(SolidWinding.of(box(scale: 0.5, offset: SIMD3(1000, 1000, 1000), inward: true)) == .inward)
    }

    @Test("成分ごとに向きが揃っていれば、その向き")
    func agreeingComponentsKeepTheirWinding() {
        #expect(SolidWinding.of(box() + box(offset: SIMD3(10, 0, 0))) == .outward)
        #expect(SolidWinding.of(box(inward: true) + box(offset: SIMD3(10, 0, 0), inward: true)) == .inward)
    }

    @Test("成分どうしで向きが食い違う形は求まらない (1 つだけ裏返った成分・中空の形)")
    func disagreeingComponentsAreUnknown() {
        // 1 つの成分だけ巻き方が逆
        #expect(SolidWinding.of(box() + box(offset: SIMD3(10, 0, 0), inward: true)) == .unknown)
        // 外向きの外殻と内向きの内殻を持つ中空の箱。外殻の体積が勝つので、和の符号では外向きに見える
        #expect(SolidWinding.of(box(scale: 3) + box(inward: true)) == .unknown)
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
