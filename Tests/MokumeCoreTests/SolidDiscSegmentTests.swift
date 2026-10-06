// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation
import Testing
import simd

@testable import MokumeCore

/// 立体の線の円板 (丸い端・丸い折れ目・曲線の刻み・点) は、画面の半径で周を刻む ([#2011])。GPU を要する。
///
/// **多角形と真円の隔たりは、画面の上で 0.25 画素以内に収まる** (`Canvas.segmentCount(forRadius:)`)。
/// 立体の線の円板は分割数が 16 に決め打ちで、保証は半径 13 画素 (太さ 26) までしか届かず、太い線の
/// 丸い端が画面で角ばっていた。
///
/// 期待値は、**同じ形を平面の頂点 (`vertex(x, y)`) で描いた絵**である ([ADR-0019] 決定 4)。既定の
/// 視点では奥行き 0 の面が画面にちょうど重なり、立体の線は画面の画素で太さを測るので、平面の線と
/// 同じ画面の半径の円板になる。平面の円板は #1645 で画面の半径で刻むようになっている。縁は 50% の
/// 被覆 (赤 ≥ 0.5) で白黒にして比べる (`PolylineJoinTests` の `Coverage` と同じ物差し)。
///
/// 対照は**同じ対を太さ 20 で描いた違い**である。太さ 20 (半径 10) では 16 分割も保証の内側に
/// あるので、平面 (15 分割) との違いは保証の内側どうしの違いだけになる。
///
/// [#2011]: https://github.com/mokume-metal/mokume/issues/2011
/// [ADR-0019]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0019-drawing-verification.md
@Suite(
    "立体の線の円板の分割数",
    .enabled(
        if: RenderDevice.isAvailable,
        "この世代のコマンド構造に対応した GPU が無い実行環境ではスキップする")
)
struct SolidDiscSegmentTests {
    private static let size = 160

    /// 塗られた画素。縁を 50% の被覆で白黒にする。
    private struct Coverage {
        var inked: [Bool]

        subscript(x: Int, y: Int) -> Bool { inked[y * SolidDiscSegmentTests.size + x] }

        /// 違う画素のうち `region` に入るものの数。
        func differing(from other: Coverage, where region: (Int, Int) -> Bool = { _, _ in true }) -> Int {
            var count = 0
            for y in 0..<SolidDiscSegmentTests.size {
                for x in 0..<SolidDiscSegmentTests.size
                where region(x, y) && self[x, y] != other[x, y] {
                    count += 1
                }
            }
            return count
        }

        var count: Int { inked.filter { $0 }.count }
    }

    /// 160×160 の黒地に、白い線 (`stroke(255)`・塗り無し) で描く。
    private func render(_ body: (Canvas) -> Void) throws -> Coverage {
        let size = Self.size
        let canvas = try CanvasFixture.make(gpu: RenderDevice(), width: size, height: size)
        try canvas.draw {
            canvas.background(0)
            canvas.noFill()
            canvas.stroke(255)
            body(canvas)
        }
        let pixels = try canvas.target.readPixels()
        var inked: [Bool] = []
        inked.reserveCapacity(size * size)
        for index in 0..<(size * size) { inked.append(Float(pixels.components[index * 4]) >= 0.5) }
        return Coverage(inked: inked)
    }

    /// 2 点 (40, 80) → (120, 80) の線の両端 (端の円板だけが載る列)。
    private static func ends(_ x: Int, _ y: Int) -> Bool { x < 40 || x >= 120 }

    /// 2 点 (40, 80) → (120, 80) を平面の頂点で描く。
    private func flatPair(_ canvas: Canvas, weight: Float) {
        canvas.strokeWeight(weight)
        canvas.beginShape()
        canvas.vertex(40, 80)
        canvas.vertex(120, 80)
        canvas.endShape()
    }

    /// 2 点を奥行きを持つ頂点で描く (既定は (40, 80, 0) → (120, 80, 0))。
    private func solidPair(
        _ canvas: Canvas, weight: Float,
        from: SIMD3<Float> = SIMD3(40, 80, 0), to: SIMD3<Float> = SIMD3(120, 80, 0)
    ) {
        canvas.strokeWeight(weight)
        canvas.beginShape()
        canvas.vertex(from.x, from.y, from.z)
        canvas.vertex(to.x, to.y, to.z)
        canvas.endShape()
    }

    /// 太さ 20 の対照: 同じ対の両端の違い。
    private func controlDifference() throws -> Int {
        let flat = try render { flatPair($0, weight: 20) }
        let solid = try render { solidPair($0, weight: 20) }
        #expect(flat.count > 0)
        return solid.differing(from: flat, where: Self.ends)
    }

    // MARK: - 条件 1: その場で描く線

    /// 起票時の再現。太さ 60 (半径 30) の丸い端は、平面では 25 分割 (隔たり 0.24 画素) で、
    /// 立体では 16 分割 (隔たり 0.58 画素) だった。
    @Test("太さ 60 の立体の線の丸い端は、平面の同じ線との違いが、太さ 20 の同じ対の違いを越えない")
    func thickRoundEndsFollowTheScreenRadius() throws {
        let control = try controlDifference()
        let flat = try render { flatPair($0, weight: 60) }
        let solid = try render { solidPair($0, weight: 60) }
        #expect(flat.count > 0)
        let measured = solid.differing(from: flat, where: Self.ends)
        #expect(measured <= control, "太さ 60 の両端の違い \(measured)・太さ 20 の対照 \(control)")
    }

    /// 円板は丸い端のほか、丸い折れ目 (`strokeJoin(.round)`) と点 1 つの周にも置く (どれも
    /// `appendSolidDisc` を通る)。折れ目は端を `.square` (何も置かない) にして、円板だけを比べる。
    @Test(
        "太さ 60 の立体の丸い折れ目と点 1 つも、平面の同じ形との違いが、太さ 20 の同じ形の違いを越えない",
        arguments: ["丸い折れ目", "点 1 つ"])
    func thickRoundJoinsAndPointsFollowTheScreenRadius(_ kind: String) throws {
        let points: [SIMD2<Float>] =
            kind == "丸い折れ目" ? [SIMD2(30, 125), SIMD2(80, 55), SIMD2(130, 125)] : [SIMD2(80, 80)]
        func draw(_ canvas: Canvas, weight: Float, depth: Bool) {
            canvas.strokeWeight(weight)
            canvas.strokeJoin(.round)
            canvas.strokeCap(kind == "丸い折れ目" ? .square : .round)
            canvas.beginShape()
            for point in points {
                if depth { canvas.vertex(point.x, point.y, 0) } else { canvas.vertex(point.x, point.y) }
            }
            canvas.endShape()
        }
        func difference(weight: Float) throws -> Int {
            let flat = try render { draw($0, weight: weight, depth: false) }
            let solid = try render { draw($0, weight: weight, depth: true) }
            #expect(flat.count > 0)
            return solid.differing(from: flat)
        }
        let control = try difference(weight: 20)
        let measured = try difference(weight: 60)
        #expect(measured <= control, "太さ 60 の違い \(measured)・太さ 20 の対照 \(control)")
    }

    // MARK: - 条件 3: 保持した形

    /// 保持した形の立体の線は、置くときに置いた後の点といまの視点で組み直す (`rebuiltSolidStroke`)。
    /// 原点の周りに記録して、(80, 80, 0) へ置く。
    @Test("保持した太さ 60 の立体の線の丸い端も、平面の同じ線との違いが、太さ 20 の同じ対の違いを越えない")
    func retainedThickRoundEndsFollowTheScreenRadius() throws {
        let control = try controlDifference()
        let flat = try render { flatPair($0, weight: 60) }
        let placed = try render { canvas in
            let shape = canvas.createShape {
                solidPair(canvas, weight: 60, from: SIMD3(-40, 0, 0), to: SIMD3(40, 0, 0))
            }
            canvas.translate(80, 80, 0)
            canvas.shape(shape)
        }
        #expect(flat.count > 0)
        let measured = placed.differing(from: flat, where: Self.ends)
        #expect(measured <= control, "太さ 60 の両端の違い \(measured)・太さ 20 の対照 \(control)")
    }

    // MARK: - 条件 4: GPU と CPU

    /// `plane` を辺に沿って平行投影で見ると、手前と奥の辺が画面で重なり、角は帯の端になる
    /// (`PolylineJoinTests.aPlaneSeenAlongAnEdgeEndsWithTheCap` と同じ視点)。不透明な線は GPU の骨で、
    /// 半透明 (`stroke(255, 250)`) の線は CPU の骨で組む。GPU の骨の円板は 16 枚で、16 で足りない
    /// 太さでは CPU の帯へ降りる。どちらの経路も、同じ太さの丸い端は同じ絵になる。
    @Test(
        "太い丸い端の plane は、GPU の経路でも CPU の経路と同じ絵になる",
        arguments: ["その場", "記録して置く"], [Float(20), 60])
    func gpuAndCPUAgreeOnThickRoundEnds(_ route: String, _ weight: Float) throws {
        func draw(_ canvas: Canvas, translucent: Bool) {
            canvas.camera(280, 80, 0, 80, 80, 0, 0, 1, 0)
            canvas.ortho()
            canvas.strokeCap(.round)
            canvas.strokeWeight(weight)
            if translucent { canvas.stroke(255, 250) }
            if route == "記録して置く" {
                let shape = canvas.createShape { canvas.plane(80, 80) }
                canvas.translate(80, 80, 0)
                canvas.shape(shape)
            } else {
                canvas.translate(80, 80, 0)
                canvas.plane(80, 80)
            }
        }
        let opaque = try render { draw($0, translucent: false) }
        let translucent = try render { draw($0, translucent: true) }
        #expect(translucent.count > 0)
        #expect(
            opaque.differing(from: translucent) == 0,
            "GPU と CPU で違う画素 \(opaque.differing(from: translucent))")
        // 端の円の内側 (中心 (80, 40) から半径 − 1) は塗られ、外側 (半径 + 1) は塗られない
        let half = weight / 2
        var missing = 0
        var spilled = 0
        for y in 0..<40 {
            for x in 0..<Self.size {
                let distance = simd_distance(SIMD2<Float>(Float(x), Float(y)), SIMD2(80, 40))
                if distance <= half - 1, !opaque[x, y] { missing += 1 }
                if distance >= half + 1, opaque[x, y] { spilled += 1 }
            }
        }
        #expect(missing == 0 && spilled == 0, "端の円の塗り漏れ \(missing)・はみ出し \(spilled)")
    }
}

/// 立体の線の円板の分割数の決め方 ([#2011])。GPU を要さない。
///
/// [#2011]: https://github.com/mokume-metal/mokume/issues/2011
@Suite("立体の線の円板の分割数の式")
struct SolidDiscSegmentFormulaTests {
    /// 下限 16 は、半径 13.01 画素 (太さ 26.02) まで 0.25 画素の保証の内側にある。
    @Test("太さ 26 以下は 16 分割のまま、それより太い線は画面の半径の分割数になる")
    func segmentsFollowTheScreenRadius() {
        for half: Float in [0, 0.5, 1, 6, 10, 13] {
            #expect(Canvas.solidDiscSegments(half: half) == 16, "半径 \(half)")
        }
        #expect(Canvas.segmentCount(forRadius: 13.5) > 16)
        for half: Float in [13.5, 30, 100, 2000] {
            #expect(
                Canvas.solidDiscSegments(half: half) == Canvas.segmentCount(forRadius: half),
                "半径 \(half)")
        }
        #expect(Canvas.solidDiscSegments(half: 30) == 25)
    }

    @Test("数でない・桁違いの半径は、下限か上限に倒れる")
    func degenerateRadii() {
        #expect(Canvas.solidDiscSegments(half: .nan) == 16)
        #expect(Canvas.solidDiscSegments(half: .infinity) == 16)
        #expect(Canvas.solidDiscSegments(half: -5) == 16)
        #expect(Canvas.solidDiscSegments(half: 1e9) == 1024)
    }

    /// 周の点は一周の分割数 + 1 個で、0 番は画面の横そのもの、最後は一周した点である。下限の
    /// 分割数で足りる半径は、GPU の骨の円板 (`kSolidStrokeDisc`) が書き写す 16 分割の表を使う
    /// (書き写しとのビットの一致は `SolidGPUStrokeTests.discUnitsMatchTheCPU` が見る)。
    @Test("周の点の表は分割数から導き、太さ 26 以下は 16 分割の表を使う")
    func unitsFollowTheSegments() {
        for segments in [16, 17, 25, 1024] {
            let units = Canvas.solidDiscUnits(segments: segments)
            #expect(units.count == segments + 1)
            #expect(units[0] == SIMD2(1, 0))
            for unit in units { #expect(abs(simd_length(unit) - 1) < 1e-6) }
            let quarter = units[segments / 4]
            if segments % 4 == 0 { #expect(abs(quarter.x) < 1e-6 && abs(quarter.y - 1) < 1e-6) }
        }
        #expect(Canvas.solidDiscFloorUnits.count == 17)
        #expect(Canvas.solidDiscUnits(half: 13) == Canvas.solidDiscFloorUnits)
        #expect(Canvas.solidDiscUnits(half: 30).count == 26)
    }
}
