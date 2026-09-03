// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Testing
import simd

@testable import MokumeCore

/// 立体の形の組み立てそのものの検査。GPU は要らない。
///
/// 絵にする前の段階で確かめられることは、ここで確かめる — 失敗が「どの形の、どの
/// 性質が壊れたか」という言葉で返るので、原因に辿り着くのが速い。
@Suite("立体の形")
struct SolidMeshTests {

    // MARK: - 分けかたの意味

    @Test("一周を割る数は、形をまたいで同じ意味を持つ")
    func detailMeansTheSameAcrossShapes() {
        let detail = 12

        // 側面を持つ形は、一周ぶんの区画をそれぞれ持つ。区画あたりの三角形の枚数は
        // 形によって違う (円柱は側面 2 + 蓋 2、円錐は側面 1 + 底 1) が、**一周を
        // いくつに割ったか**は同じ数で決まる
        #expect(
            SolidShape.cylinder(radius: 10, height: 20, detail: detail).make().triangleCount
                == detail * 4)
        #expect(
            SolidShape.cone(radius: 10, height: 20, detail: detail).make().triangleCount
                == detail * 2)
        // 球は上下が半周なので、その半分で割る
        #expect(
            SolidShape.sphere(radius: 10, detail: detail).make().triangleCount
                == detail * (detail / 2) * 2)
        // 輪は、輪の一周も管の一周も同じ数で割る
        #expect(
            SolidShape.torus(ringRadius: 10, tubeRadius: 3, detail: detail).make().triangleCount
                == detail * detail * 2)
    }

    @Test("分けかたは範囲へ丸める", arguments: [(-5, 3), (0, 3), (3, 3), (24, 24), (10_000, 128)])
    func detailIsClamped(_ given: Int, _ expected: Int) {
        #expect(SolidShape.clampDetail(given) == expected)
    }

    @Test("分けかたを増やすと三角形が増える")
    func moreDetailMeansMoreTriangles() {
        let coarse = SolidShape.sphere(radius: 10, detail: 8).make().triangleCount
        let fine = SolidShape.sphere(radius: 10, detail: 32).make().triangleCount
        #expect(fine > coarse)
    }

    // MARK: - 置けない寸法

    @Test("数でない値・無限・負の寸法は置けない", arguments: [Float.nan, .infinity, -0.001])
    func badSizesAreRejected(_ value: Float) {
        #expect(!SolidShape.isDrawable(value))
        #expect(!SolidShape.isDrawable(1, value))
    }

    @Test("0 と正の有限な寸法は置ける")
    func goodSizesAreAccepted() {
        #expect(SolidShape.isDrawable(0))
        #expect(SolidShape.isDrawable(1, 2, 3))
    }

    // MARK: - 形そのもの

    @Test("箱は 12 枚の三角形で、原点を中心に指定した大きさに収まる")
    func boxHasTwelveTrianglesAroundOrigin() {
        let mesh = SolidShape.box(width: 20, height: 10, depth: 4).make()
        #expect(mesh.triangleCount == 12)

        let positions = mesh.points.map(\.position)
        #expect(positions.map(\.x).max() == 10)
        #expect(positions.map(\.x).min() == -10)
        #expect(positions.map(\.y).max() == 5)
        #expect(positions.map(\.y).min() == -5)
        #expect(positions.map(\.z).max() == 2)
        #expect(positions.map(\.z).min() == -2)
    }

    @Test("平らな面は 2 枚の三角形で、画面の側を向く")
    func planeFacesTheViewer() {
        let mesh = SolidShape.plane(width: 8, height: 6).make()
        #expect(mesh.triangleCount == 2)
        #expect(mesh.points.allSatisfy { $0.normal == SIMD3<Float>(0, 0, 1) })
        #expect(mesh.points.allSatisfy { $0.position.z == 0 })
    }

    @Test("球の点は、すべて半径ぶんだけ原点から離れている")
    func spherePointsSitOnTheRadius() {
        let radius: Float = 7
        let mesh = SolidShape.sphere(radius: radius, detail: 16).make()
        for point in mesh.points {
            #expect(abs(length(point.position) - radius) < 1e-3)
        }
    }

    @Test("球の面の向きは、外を向いた単位ベクトル")
    func sphereNormalsPointOutward() {
        let mesh = SolidShape.sphere(radius: 5, detail: 16).make()
        for point in mesh.points {
            #expect(abs(length(point.normal) - 1) < 1e-3)
            // 中心から見て外向き = 位置と同じ向き
            #expect(dot(normalize(point.position), point.normal) > 0.99)
        }
    }

    @Test("円柱は指定した高さに収まり、側面は半径ぶん外へ出る")
    func cylinderFitsItsSize() {
        let mesh = SolidShape.cylinder(radius: 6, height: 20, detail: 16).make()
        let positions = mesh.points.map(\.position)
        #expect(abs((positions.map(\.y).max() ?? 0) - 10) < 1e-4)
        #expect(abs((positions.map(\.y).min() ?? 0) + 10) < 1e-4)
        let radial = positions.map { sqrt($0.x * $0.x + $0.z * $0.z) }.max() ?? 0
        #expect(abs(radial - 6) < 1e-3)
    }

    @Test("円錐の先は上を向く")
    func coneApexPointsUp() {
        // 縦軸は下向きなので、上は y が小さいほう
        let mesh = SolidShape.cone(radius: 6, height: 20, detail: 16).make()
        let apexes = mesh.points.filter { $0.position.y < 0 }
        #expect(!apexes.isEmpty)
        #expect(apexes.allSatisfy { abs($0.position.x) < 1e-5 && abs($0.position.z) < 1e-5 })
    }

    @Test("輪には穴が空いている")
    func torusHasAHole() {
        let mesh = SolidShape.torus(ringRadius: 10, tubeRadius: 3, detail: 16).make()
        // 中心からの距離は「輪の半径 ± 管の半径」の帯に収まる = 中心は空いている
        for point in mesh.points {
            let distance = sqrt(point.position.x * point.position.x
                + point.position.y * point.position.y + point.position.z * point.position.z)
            #expect(distance > 10 - 3 - 1e-3)
            #expect(distance < 10 + 3 + 1e-3)
        }
    }

    // MARK: - 頂点の並び

    @Test("シェーダ側の構造体と大きさが一致する")
    func vertexStrideMatchesShader() {
        #expect(MemoryLayout<SolidVertex>.stride == SolidVertex.expectedStride)
    }

    @Test("形は三角形の並びなので、点の数は 3 の倍数", arguments: [
        SolidShape.box(width: 1, height: 2, depth: 3),
        .sphere(radius: 1, detail: 7),
        .plane(width: 1, height: 1),
        .cylinder(radius: 1, height: 2, detail: 5),
        .cone(radius: 1, height: 2, detail: 5),
        .torus(ringRadius: 3, tubeRadius: 1, detail: 5),
    ])
    func meshesAreTriangleLists(_ shape: SolidShape) {
        #expect(shape.make().points.count % 3 == 0)
    }

    @Test("面の巻き方が、形をまたいで揃っている", arguments: [
        SolidShape.box(width: 10, height: 20, depth: 30),
        .sphere(radius: 10, detail: 8),
        .plane(width: 10, height: 10),
        .cylinder(radius: 10, height: 20, detail: 6),
        .cone(radius: 10, height: 20, detail: 6),
        .torus(ringRadius: 30, tubeRadius: 10, detail: 6),
    ])
    func windingAgreesWithTheOutwardNormal(_ shape: SolidShape) {
        // **巻き方は絵に出ない — 出るのは光を当てたときだけ。** 塗り 1 色なら形ごとに
        // 逆でも同じ絵が出るので、揃っていないことに絵では気付けない。裏を向いた面を
        // 見えている側で明るくする (両面) 扱いは表裏の判定に巻き方を使うので、
        // ここが揃っていない形だけが逆から照らされる
        let points = shape.make().points
        var checked = 0
        for index in stride(from: 0, to: points.count - 2, by: 3) {
            let a = points[index]
            let b = points[index + 1]
            let c = points[index + 2]
            let face = cross(b.position - a.position, c.position - a.position)
            // 退化した三角形は向きを持たないので数えない
            guard length_squared(face) > 1e-6 else { continue }
            #expect(dot(face, a.normal + b.normal + c.normal) > 0)
            checked += 1
        }
        #expect(checked > 0)
    }

    @Test("面の向きは外を向いている", arguments: [
        SolidShape.box(width: 10, height: 20, depth: 30),
        .sphere(radius: 10, detail: 8),
        .cylinder(radius: 10, height: 20, detail: 6),
        .cone(radius: 10, height: 20, detail: 6),
    ])
    func normalsPointOutward(_ shape: SolidShape) {
        // **内を向いていても絵は出る。** 出るのは「光が反対から当たっているように
        // 見える」絵で、それらしく見えてしまうので目では気付けない。中身の詰まった
        // 形なら、面の向きと中心からの向きが同じ側にあることで機械的に見分けられる
        // (輪は内側の面が軸を向くので中身が詰まっておらず、平らな面は volume を
        // 持たないので、この物差しは当たらない — 巻き方の検査だけが効く)
        for point in shape.make().points {
            #expect(dot(point.normal, point.position) > 0)
        }
    }

    // MARK: - 閉じているか (背面カリングの前提)

    @Test("閉じた形とそうでない形を、形自身が名乗る")
    func closednessIsDeclaredByTheShape() {
        // 閉じた形の列だけが裏面を捨てられる。平らな面は片面で、裏から見えなくなる
        #expect(SolidShape.box(width: 1, height: 1, depth: 1).isClosed)
        #expect(SolidShape.sphere(radius: 1, detail: 8).isClosed)
        #expect(SolidShape.cylinder(radius: 1, height: 1, detail: 8).isClosed)
        #expect(SolidShape.cone(radius: 1, height: 1, detail: 8).isClosed)
        #expect(SolidShape.torus(ringRadius: 2, tubeRadius: 1, detail: 8).isClosed)
        #expect(!SolidShape.plane(width: 1, height: 1).isClosed)
    }

    @Test("閉じた形は、巻き方そのものが外を向いている", arguments: [
        SolidShape.box(width: 10, height: 20, depth: 30),
        .sphere(radius: 10, detail: 8),
        .sphere(radius: 3, detail: 3),
        .cylinder(radius: 10, height: 20, detail: 6),
        .cylinder(radius: 1, height: 100, detail: 3),
        .cone(radius: 10, height: 20, detail: 6),
        .cone(radius: 1, height: 100, detail: 3),
        .torus(ringRadius: 30, tubeRadius: 10, detail: 6),
        .torus(ringRadius: 30, tubeRadius: 10, detail: 128),
    ])
    func closedShapesWindOutward(_ shape: SolidShape) {
        // **裏面を捨てる判定は書かれた向きを読まない** — 読むのは 3 点を巻いた向き
        // だけである。上の検査は書かれた向きとの一致を見ているが、書かれた向きが
        // 内向きに揃って間違っていれば両方が揃って通る。ここでは 3 点だけから向きを
        // 求め、それが形の中心 (輪は管の中心) から外へ向くことを見る。1 枚でも内向き
        // なら、その面はカリングで消え、絵に穴が空く
        precondition(shape.isClosed)
        let points = shape.make().points
        var checked = 0
        for index in stride(from: 0, to: points.count - 2, by: 3) {
            let a = points[index].position
            let b = points[index + 1].position
            let c = points[index + 2].position
            let face = cross(b - a, c - a)
            guard length_squared(face) > 1e-6 else { continue }
            let centroid = (a + b + c) / 3
            let outward = centroid - Self.center(of: shape, near: centroid)
            #expect(dot(face, outward) > 0, "\(index / 3) 枚目が内向きに巻かれている")
            checked += 1
        }
        #expect(checked > 0)
    }

    /// 「外」を測る基準の点。中身の詰まった形は原点、輪は管の中心。
    private static func center(of shape: SolidShape, near point: SIMD3<Float>) -> SIMD3<Float> {
        guard case .torus(let ringRadius, _, _) = shape else { return .zero }
        let inPlane = SIMD3<Float>(point.x, point.y, 0)
        return normalize(inPlane) * ringRadius
    }
}
