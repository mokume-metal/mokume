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
        // 楕円体の割り方の意味は球と同じ
        #expect(
            SolidShape.ellipsoid(radiusX: 10, radiusY: 20, radiusZ: 5, detail: detail)
                .make().triangleCount == detail * (detail / 2) * 2)
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

    @Test("形は三角形の並びなので、点の数は 3 の倍数", arguments: [
        SolidShape.box(width: 1, height: 2, depth: 3),
        .sphere(radius: 1, detail: 7),
        .ellipsoid(radiusX: 1, radiusY: 2, radiusZ: 3, detail: 7),
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
        .ellipsoid(radiusX: 10, radiusY: 25, radiusZ: 6, detail: 8),
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
        .ellipsoid(radiusX: 10, radiusY: 25, radiusZ: 6, detail: 8),
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

    // MARK: - 稜線 (#850)

    /// 形と、その稜線の本数。一周はどれも 12 で割る。
    nonisolated static let edgeCounts: [(SolidShape, Int)] = {
        let around = 12
        let sphereRings = around / 2
        return [
            // 箱: 面の対角線 6 本が消えて 12 本
            (.box(width: 20, height: 10, depth: 4), 12),
            // 平らな面: 対角線が消えて縁の 4 本
            (.plane(width: 8, height: 6), 4),
            // 球: 緯線 (上下 6 区間の間の 5 周) と経線 (12 本 x 6 区間)。四辺形の対角線は無い
            (.sphere(radius: 7, detail: around), (sphereRings - 1) * around + around * sphereRings),
            // 楕円体: 球と同じ数。`diag(a, b, c)` は線形写像なので、球の四辺形が
            // 同一平面に載る性質 (だから対角線が出ない) をそのまま保つ
            (
                .ellipsoid(radiusX: 7, radiusY: 18, radiusZ: 4, detail: around),
                (sphereRings - 1) * around + around * sphereRings
            ),
            // 円柱: 側面の縦線 + 上下の縁。蓋の放射線と側面の対角線は無い
            (.cylinder(radius: 6, height: 20, detail: around), around * 3),
            // 円錐: 先から降りる線 + 底の縁。底の放射線は無い
            (.cone(radius: 6, height: 20, detail: around), around * 2),
            // 輪: 輪の向きと管の向きに、それぞれ一周 x 一周
            (.torus(ringRadius: 10, tubeRadius: 3, detail: around), around * around * 2),
        ]
    }()

    @Test("稜線は形の折れ目と縁だけで、三角形に割った継ぎ目を含まない", arguments: edgeCounts)
    func edgesAreCreasesAndBorders(_ shape: SolidShape, _ expected: Int) {
        #expect(SolidEdges(shape.make()).edges.count == expected)
    }

    @Test("一周の継ぎ目でも点は 1 つにまとまり、辺は 2 本に割れない", arguments: [3, 24, 128])
    func seamsAreWelded(_ detail: Int) {
        // 継ぎ目は角度 2π で作られ、丸めで 0 からわずかにずれる。ビットで比べると
        // 継ぎ目の点が 2 つに割れて、点の数が一周ぶん増える
        let sphere = SolidEdges(SolidShape.sphere(radius: 50, detail: detail).make())
        let rings = max(2, detail / 2)
        #expect(sphere.points.count == 2 + (rings - 1) * detail)
        let torus = SolidEdges(
            SolidShape.torus(ringRadius: 40, tubeRadius: 9, detail: detail).make())
        #expect(torus.points.count == detail * detail)
        #expect(torus.edges.count == detail * detail * 2)
    }

    @Test("同じ辺は 1 度しか現れない")
    func edgesAreUnique() {
        for shape in [
            SolidShape.box(width: 3, height: 3, depth: 3), .sphere(radius: 2, detail: 24),
            .torus(ringRadius: 5, tubeRadius: 1, detail: 24),
        ] {
            let edges = SolidEdges(shape.make()).edges
            let keys = Set(edges.map { SIMD2<Int32>(Int32(min($0.0, $0.1)), Int32(max($0.0, $0.1))) })
            #expect(keys.count == edges.count, "\(shape) に同じ辺が 2 度ある")
            #expect(edges.allSatisfy { $0.0 != $0.1 })
        }
    }

    @Test("読み込んだモデルにも同じ規則が効く")
    func modelEdgesFollowTheSameRule() throws {
        // 四角錐: 底の縁 4 + 斜めの稜 4。底の四角を割った対角線は無い
        let model = Model.make(
            name: "pyramid", parsed: try ModelFile.load(ModelFixture.pyramid),
            fitting: nil, identity: 1)
        #expect(SolidEdges(model.mesh).edges.count == 8)
    }

    @Test("空の並びからは稜線が出ない")
    func emptyMeshHasNoEdges() {
        let edges = SolidEdges(SolidMesh(points: []))
        #expect(edges.edges.isEmpty)
        #expect(edges.points.isEmpty)
    }

    // MARK: - 閉じているか (背面カリングの前提)

    @Test("閉じた形とそうでない形を、形自身が名乗る")
    func closednessIsDeclaredByTheShape() {
        // 閉じた形の列だけが裏面を捨てられる。平らな面は片面で、裏から見えなくなる
        #expect(SolidShape.box(width: 1, height: 1, depth: 1).isClosed)
        #expect(SolidShape.sphere(radius: 1, detail: 8).isClosed)
        #expect(SolidShape.ellipsoid(radiusX: 1, radiusY: 2, radiusZ: 3, detail: 8).isClosed)
        #expect(SolidShape.cylinder(radius: 1, height: 1, detail: 8).isClosed)
        #expect(SolidShape.cone(radius: 1, height: 1, detail: 8).isClosed)
        #expect(SolidShape.torus(ringRadius: 2, tubeRadius: 1, detail: 8).isClosed)
        #expect(!SolidShape.plane(width: 1, height: 1).isClosed)
    }

    @Test("閉じた形は、巻き方そのものが外を向いている", arguments: [
        SolidShape.box(width: 10, height: 20, depth: 30),
        .sphere(radius: 10, detail: 8),
        .sphere(radius: 3, detail: 3),
        .ellipsoid(radiusX: 10, radiusY: 25, radiusZ: 6, detail: 8),
        .ellipsoid(radiusX: 3, radiusY: 1, radiusZ: 7, detail: 3),
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

    // MARK: - 楕円体 (#849)

    @Test("3 つの半径が等しい楕円体は、球と同じ形になる")
    func anEllipsoidWithEqualRadiiIsASphere() {
        // **球と楕円体は別々に組み立てている** (ADR-0008 決定 6 の第 3 の道)。畳んで
        // いないので、片方の規律だけが動いても気付けない箇所が要る — それが uv の
        // 巻き方で、この検査 1 本がそこを塞ぐ。並び順・rings の割り方・巻き方も
        // まとめて留まる
        let radius: Float = 13
        let sphere = SolidShape.sphere(radius: radius, detail: 16).make().points
        let ellipsoid = SolidShape
            .ellipsoid(radiusX: radius, radiusY: radius, radiusZ: radius, detail: 16)
            .make().points

        #expect(ellipsoid.count == sphere.count)
        for (mine, theirs) in zip(ellipsoid, sphere) {
            // 位置と uv は**ビットで**一致する。どちらも同じ積を同じ順で取るので、
            // 丸めまで同じになる
            #expect(mine.position == theirs.position)
            #expect(mine.uv == theirs.uv)
            // 向きだけは経路が違う (球は方向そのまま、楕円体は余因子を正規化する)
            #expect(distance(mine.normal, theirs.normal) < 1e-5)
        }
    }

    @Test("楕円体の点は、すべて楕円面に載っている")
    func ellipsoidPointsSitOnTheSurface() {
        let (a, b, c): (Float, Float, Float) = (20, 40, 7)
        let mesh = SolidShape.ellipsoid(radiusX: a, radiusY: b, radiusZ: c, detail: 20).make()
        for point in mesh.points {
            let p = point.position
            let onSurface = (p.x / a) * (p.x / a) + (p.y / b) * (p.y / b) + (p.z / c) * (p.z / c)
            #expect(abs(onSurface - 1) < 1e-4)
        }
    }

    @Test("半径は x・y・z の順に効く")
    func ellipsoidRadiiApplyInAxisOrder() {
        // **軸を取り違えても「楕円体らしい絵」は出る。** 順序は形からしか読めない
        let mesh = SolidShape.ellipsoid(radiusX: 20, radiusY: 40, radiusZ: 60, detail: 24).make()
        let positions = mesh.points.map(\.position)
        for (extent, axis) in [
            (Float(20), \SIMD3<Float>.x), (40, \SIMD3<Float>.y), (60, \SIMD3<Float>.z),
        ] {
            #expect(abs((positions.map { $0[keyPath: axis] }.max() ?? 0) - extent) < 1e-3)
            #expect(abs((positions.map { $0[keyPath: axis] }.min() ?? 0) + extent) < 1e-3)
        }
    }

    @Test("楕円体の面の向きは、楕円面の勾配である")
    func ellipsoidNormalsFollowTheGradient() {
        // **球を引き伸ばしただけの向き (位置と同じ向き) では通らない。** 伸びた軸ほど
        // 面は寝るので、勾配と方向は別物になる
        let (a, b, c): (Float, Float, Float) = (10, 30, 6)
        let mesh = SolidShape.ellipsoid(radiusX: a, radiusY: b, radiusZ: c, detail: 20).make()
        var differed = 0
        for point in mesh.points {
            #expect(abs(length(point.normal) - 1) < 1e-4)
            let p = point.position
            let gradient = normalize(
                SIMD3<Float>(p.x / (a * a), p.y / (b * b), p.z / (c * c)))
            #expect(dot(point.normal, gradient) > 0.9999)
            // 位置の向きとは**違う**ことも見る。見ないと、球のままの実装でも
            // 勾配との一致だけは (丸めの範囲で) 通ってしまう極が残る
            if dot(point.normal, normalize(p)) < 0.99 { differed += 1 }
        }
        #expect(differed > 0, "どの点でも向きが位置と同じ = 球を引き伸ばしただけ")
    }

    @Test(
        "半径に 0 が混ざっても、位置も向きも数である",
        arguments: [
            SIMD3<Float>(0, 40, 40), SIMD3(40, 0, 40), SIMD3(40, 40, 0),
            SIMD3(0, 0, 40), SIMD3(0, 0, 0),
        ])
    func zeroRadiiStayFinite(_ radii: SIMD3<Float>) {
        // `SolidShape.isDrawable` は 0 を通す (`goodSizesAreAccepted`) ので、ここへ
        // 0 が届く。法線を素直な割り算で書くと無限が出て、そのまま GPU へ渡る
        let mesh = SolidShape
            .ellipsoid(radiusX: radii.x, radiusY: radii.y, radiusZ: radii.z, detail: 12).make()
        #expect(!mesh.points.isEmpty)
        for point in mesh.points {
            #expect(point.position.x.isFinite && point.position.y.isFinite
                && point.position.z.isFinite)
            #expect(point.normal.x.isFinite && point.normal.y.isFinite
                && point.normal.z.isFinite)
            #expect(abs(length(point.normal) - 1) < 1e-4)
        }
    }
}
