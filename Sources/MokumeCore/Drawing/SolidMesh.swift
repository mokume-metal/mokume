// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import simd

/// 組み立て終えた立体の形。
///
/// 中身は**三角形の並び**で、3 点で 1 枚を表す。位置は形自身の座標で、置く場所の
/// 変換は描くときに掛かる (``Shape`` と同じ約束)。色は形が持たない — 置くときの
/// 塗りで決まる。
struct SolidMesh {
    /// 形の 1 点。
    struct Point: Equatable {
        var position: SIMD3<Float>
        /// 面の向き。光を当てる段で使う。
        var normal: SIMD3<Float>
    }

    let points: [Point]

    /// 三角形の枚数。
    var triangleCount: Int { points.count / 3 }
}

// MARK: - 何をどう分けるか

/// 形と寸法の組。**使い回しの鍵**でもある。
///
/// 鍵を寸法から組み立てた文字列にしない。文字列にすると、値の異常がそのまま鍵の
/// 空間の異常になる — 数でない寸法から作った鍵は二度と当たらず、表に居座り続ける。
/// 型にしておけば、鍵を作れる時点で値は既に確かめられている (``SolidShape/make(_:)``)。
enum SolidShape: Hashable {
    case box(width: Float, height: Float, depth: Float)
    case sphere(radius: Float, detail: Int)
    case plane(width: Float, height: Float)
    case cylinder(radius: Float, height: Float, detail: Int)
    case cone(radius: Float, height: Float, detail: Int)
    case torus(ringRadius: Float, tubeRadius: Float, detail: Int)

    /// **一周をいくつに割るか**の下限と上限。
    ///
    /// 下限は 3 (三角形にならない分け方はできない)。上限は、手が滑って大きな値を
    /// 渡したときに確保が跳ね上がらないようにするためのもの。
    static let detailRange = 3...128

    /// 分けかたを範囲へ丸める。**形をまたいで同じ意味**を持つ ([ADR-0020] 決定 5:
    /// 描画は投げずに、範囲へ丸める)。
    ///
    /// [ADR-0020]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0020-api-naming-and-surface.md
    static func clampDetail(_ detail: Int) -> Int {
        min(max(detail, detailRange.lowerBound), detailRange.upperBound)
    }

    /// 寸法として置けない値か。
    ///
    /// 数でない値・無限・負の寸法は、絵として意味を持たない。ここで弾くので、
    /// 鍵の空間にはそういう値が入らない。
    static func isDrawable(_ values: Float...) -> Bool {
        values.allSatisfy { $0.isFinite && $0 >= 0 }
    }

    /// この形を組み立てる。
    func make() -> SolidMesh {
        switch self {
        case .box(let width, let height, let depth):
            SolidMesh(points: SolidMeshBuilder.box(width: width, height: height, depth: depth))
        case .sphere(let radius, let detail):
            SolidMesh(points: SolidMeshBuilder.sphere(radius: radius, detail: detail))
        case .plane(let width, let height):
            SolidMesh(points: SolidMeshBuilder.plane(width: width, height: height))
        case .cylinder(let radius, let height, let detail):
            SolidMesh(
                points: SolidMeshBuilder.cylinder(radius: radius, height: height, detail: detail))
        case .cone(let radius, let height, let detail):
            SolidMesh(points: SolidMeshBuilder.cone(radius: radius, height: height, detail: detail))
        case .torus(let ringRadius, let tubeRadius, let detail):
            SolidMesh(
                points: SolidMeshBuilder.torus(
                    ringRadius: ringRadius, tubeRadius: tubeRadius, detail: detail))
        }
    }
}

// MARK: - 組み立て

/// 基本の形を三角形の並びへ落とす。
///
/// どの形も**原点が中心**で、縦軸は画面と同じく下向き。円柱と円錐の軸は縦、輪の
/// 穴は画面の側を向く (手本のある形はその向きに従う)。
enum SolidMeshBuilder {
    /// 箱。6 面それぞれが自分の向きを持つ (角で丸めない)。
    static func box(width: Float, height: Float, depth: Float) -> [SolidMesh.Point] {
        let x = width / 2
        let y = height / 2
        let z = depth / 2

        var points: [SolidMesh.Point] = []
        points.reserveCapacity(36)

        // 4 隅を面の周に沿って渡す。**外向きに巻き直すのはここ 1 箇所**で、面の向きも
        // 同じ巻き方から求めるので、向きと巻き方がずれようがない
        func face(_ a: SIMD3<Float>, _ b: SIMD3<Float>, _ c: SIMD3<Float>, _ d: SIMD3<Float>) {
            let normal = normalize(cross(c - a, b - a))
            for position in [a, c, b, a, d, c] {
                points.append(SolidMesh.Point(position: position, normal: normal))
            }
        }

        // 手前 (+z) と奥 (-z)
        face(SIMD3(-x, -y, z), SIMD3(-x, y, z), SIMD3(x, y, z), SIMD3(x, -y, z))
        face(SIMD3(x, -y, -z), SIMD3(x, y, -z), SIMD3(-x, y, -z), SIMD3(-x, -y, -z))
        // 右 (+x) と左 (-x)
        face(SIMD3(x, -y, z), SIMD3(x, y, z), SIMD3(x, y, -z), SIMD3(x, -y, -z))
        face(SIMD3(-x, -y, -z), SIMD3(-x, y, -z), SIMD3(-x, y, z), SIMD3(-x, -y, z))
        // 下 (+y) と上 (-y) — 縦軸は下向きなので +y が下
        face(SIMD3(-x, y, z), SIMD3(-x, y, -z), SIMD3(x, y, -z), SIMD3(x, y, z))
        face(SIMD3(-x, -y, -z), SIMD3(-x, -y, z), SIMD3(x, -y, z), SIMD3(x, -y, -z))

        return points
    }

    /// 平らな面。画面の側 (+z) を向く。
    static func plane(width: Float, height: Float) -> [SolidMesh.Point] {
        let x = width / 2
        let y = height / 2
        let normal = SIMD3<Float>(0, 0, 1)
        return [
            SIMD3(-x, -y, 0), SIMD3(x, -y, 0), SIMD3(x, y, 0),
            SIMD3(-x, -y, 0), SIMD3(x, y, 0), SIMD3(-x, y, 0),
        ].map { SolidMesh.Point(position: $0, normal: normal) }
    }

    /// 球。**一周を `detail` で割り**、上下は半周なのでその半分で割る。
    static func sphere(radius: Float, detail: Int) -> [SolidMesh.Point] {
        let around = detail
        let rings = max(2, detail / 2)

        func point(ring: Int, step: Int) -> SolidMesh.Point {
            let phi = Float(ring) / Float(rings) * .pi
            let theta = Float(step) / Float(around) * 2 * .pi
            let normal = SIMD3<Float>(
                sin(phi) * cos(theta),
                cos(phi),
                sin(phi) * sin(theta))
            return SolidMesh.Point(position: normal * radius, normal: normal)
        }

        var points: [SolidMesh.Point] = []
        points.reserveCapacity(around * rings * 6)
        for ring in 0..<rings {
            for step in 0..<around {
                let a = point(ring: ring, step: step)
                let b = point(ring: ring + 1, step: step)
                let c = point(ring: ring + 1, step: step + 1)
                let d = point(ring: ring, step: step + 1)
                // 巻き方は外向き。上下 (ring) と横 (step) の進む向きが左手の関係に
                // なっているので、他の形と揃えるためにここで入れ替える
                points.append(contentsOf: [a, c, b, a, d, c])
            }
        }
        return points
    }

    /// 円柱。軸は縦。側面を `detail` で割り、上下に蓋を付ける。
    static func cylinder(radius: Float, height: Float, detail: Int) -> [SolidMesh.Point] {
        let half = height / 2
        var points: [SolidMesh.Point] = []
        points.reserveCapacity(detail * 12)

        for step in 0..<detail {
            let t0 = Float(step) / Float(detail) * 2 * .pi
            let t1 = Float(step + 1) / Float(detail) * 2 * .pi
            let n0 = SIMD3<Float>(cos(t0), 0, sin(t0))
            let n1 = SIMD3<Float>(cos(t1), 0, sin(t1))
            let a = n0 * radius + SIMD3(0, -half, 0)
            let b = n0 * radius + SIMD3(0, half, 0)
            let c = n1 * radius + SIMD3(0, half, 0)
            let d = n1 * radius + SIMD3(0, -half, 0)
            points.append(contentsOf: [
                SolidMesh.Point(position: a, normal: n0),
                SolidMesh.Point(position: b, normal: n0),
                SolidMesh.Point(position: c, normal: n1),
                SolidMesh.Point(position: a, normal: n0),
                SolidMesh.Point(position: c, normal: n1),
                SolidMesh.Point(position: d, normal: n1),
            ])
            // 蓋 — 上 (-y) と下 (+y)。縦軸が下向きなので -y が上になる
            points.append(contentsOf: fan(
                center: SIMD3(0, -half, 0), first: a, second: d, normal: SIMD3(0, -1, 0)))
            points.append(contentsOf: fan(
                center: SIMD3(0, half, 0), first: c, second: b, normal: SIMD3(0, 1, 0)))
        }
        return points
    }

    /// 円錐。軸は縦で、先は上 (-y)。底を `detail` で割る。
    static func cone(radius: Float, height: Float, detail: Int) -> [SolidMesh.Point] {
        let half = height / 2
        let apex = SIMD3<Float>(0, -half, 0)
        var points: [SolidMesh.Point] = []
        points.reserveCapacity(detail * 6)

        for step in 0..<detail {
            let t0 = Float(step) / Float(detail) * 2 * .pi
            let t1 = Float(step + 1) / Float(detail) * 2 * .pi
            let r0 = SIMD3<Float>(cos(t0), 0, sin(t0))
            let r1 = SIMD3<Float>(cos(t1), 0, sin(t1))
            let a = r0 * radius + SIMD3(0, half, 0)
            let b = r1 * radius + SIMD3(0, half, 0)
            // 斜面の向きは、その三角形そのものから求める (巻き方と同じ順で読む)
            let side = normalize(cross(a - apex, b - apex))
            points.append(contentsOf: [
                SolidMesh.Point(position: apex, normal: side),
                SolidMesh.Point(position: a, normal: side),
                SolidMesh.Point(position: b, normal: side),
            ])
            points.append(contentsOf: fan(
                center: SIMD3(0, half, 0), first: b, second: a, normal: SIMD3(0, 1, 0)))
        }
        return points
    }

    /// 輪。穴は画面の側を向く。輪の一周も管の一周も `detail` で割る。
    static func torus(ringRadius: Float, tubeRadius: Float, detail: Int) -> [SolidMesh.Point] {
        func point(ring: Int, tube: Int) -> SolidMesh.Point {
            let u = Float(ring) / Float(detail) * 2 * .pi
            let v = Float(tube) / Float(detail) * 2 * .pi
            let ringDirection = SIMD3<Float>(cos(u), sin(u), 0)
            let normal = ringDirection * cos(v) + SIMD3<Float>(0, 0, sin(v))
            let position = ringDirection * ringRadius + normal * tubeRadius
            return SolidMesh.Point(position: position, normal: normal)
        }

        var points: [SolidMesh.Point] = []
        points.reserveCapacity(detail * detail * 6)
        for ring in 0..<detail {
            for tube in 0..<detail {
                let a = point(ring: ring, tube: tube)
                let b = point(ring: ring + 1, tube: tube)
                let c = point(ring: ring + 1, tube: tube + 1)
                let d = point(ring: ring, tube: tube + 1)
                points.append(contentsOf: [a, b, c, a, c, d])
            }
        }
        return points
    }

    /// 中心と 2 点で 1 枚の蓋を作る。
    private static func fan(
        center: SIMD3<Float>, first: SIMD3<Float>, second: SIMD3<Float>, normal: SIMD3<Float>
    ) -> [SolidMesh.Point] {
        [center, first, second].map { SolidMesh.Point(position: $0, normal: normal) }
    }
}
