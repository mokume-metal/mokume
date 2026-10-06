// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation
import Testing

@testable import MokumeCore

/// 立体の線は、1 つの形の中で重ねて混ぜない ([#1561])。GPU を要する。
///
/// 立体の線は、帯・折れ目の形・端の形・曲線の刻みの円板を視線に正対する形として世界の座標で
/// 別々の三角形に積む。重ねたまま積むと、半透明の線では折れ目・端・稜の集まる点だけが 2〜3 回
/// 混ざって濃くなる。平面の線 ([#1536]・`StrokeOverlapTests`) と同じ単位で塗る:
///
/// - 1 つの形の線のうち、線に沿って太さ以内で繋がる片どうし (帯・折れ目・端の形・曲線の刻みの
///   円板、稜線の網の同じ点に集まる帯と形) は 1 回だけ混ぜる
/// - 奥行きの違う稜が画面で交わる所は、別々の線と同じく 2 回混ぜる。手前の半透明の稜の向こうに
///   奥の稜が透けて見えるのが正しい
///
/// ## 読み方
///
/// 面は 160×160 の黒地で、線は `stroke(255, 0, 0, 128)`。1 回混ぜると線形の赤が 0.413、
/// 2 回で 0.618、3 回で 0.721 になる。「重ね塗りの画素」は赤が 0.5 を超える画素とする
/// (`StrokeOverlapTests` と同じ物差し)。
///
/// [#1536]: https://github.com/mokume-metal/mokume/issues/1536
/// [#1561]: https://github.com/mokume-metal/mokume/issues/1561
@Suite(
    "立体の線の重ね塗り",
    .enabled(
        if: RenderDevice.isAvailable,
        "この世代のコマンド構造に対応した GPU が無い実行環境ではスキップする")
)
struct SolidStrokeOverlapTests {
    private let black = LinearRGBA.linear(red: 0, green: 0, blue: 0)

    /// 1 回だけ混ぜたときの赤 (線形)。`stroke(255, 0, 0, 128)` を黒地に 1 回 `blend` した値。
    private static let once: Float = 0.413
    /// 2 回混ぜたときの赤。
    private static let twice: Float = 0.618

    /// 置き場所で掛ける半透明の白。不透明度は `stroke(255, 0, 0, 128)` と同じ 128/255。
    private static let veil: LinearRGBA = {
        let alpha = Float(128) / 255
        return LinearRGBA(premultipliedRed: alpha, green: alpha, blue: alpha, alpha: alpha)
    }()

    /// 黒地に `noFill()` と半透明の赤の線で描いて、線形の画素を読む。`body` が返す値も返す。
    private func translucent<Result>(
        _ body: (Canvas) -> Result
    ) throws -> (pixels: PixelBuffer, result: Result) {
        let canvas = try CanvasFixture.make(gpu: RenderDevice(), width: 160, height: 160)
        var result: Result?
        try canvas.draw {
            canvas.background(black)
            canvas.noFill()
            canvas.stroke(255, 0, 0, 128)
            result = body(canvas)
        }
        return (try canvas.target.readPixels(), result!)
    }

    /// 形を組み立て (`build`)、黒地へ置き場所を渡して置く。組み立ては置く絵と別のフレームで行う。
    private func placed(
        _ build: (Canvas) -> Shape, at placements: [Placement]
    ) throws -> PixelBuffer {
        let canvas = try CanvasFixture.make(gpu: RenderDevice(), width: 160, height: 160)
        var shape = Shape.empty
        try canvas.draw { shape = build(canvas) }
        try canvas.draw {
            canvas.background(black)
            canvas.shape(shape, at: placements)
        }
        return try canvas.target.readPixels()
    }

    /// 赤が 0.5 を超える画素 (2 回以上混ぜた画素) の位置。
    private func overpainted(_ pixels: PixelBuffer) -> [SIMD2<Int>] {
        var found: [SIMD2<Int>] = []
        for y in 0..<pixels.height {
            for x in 0..<pixels.width where pixels[x, y].red > 0.5 { found.append(SIMD2(x, y)) }
        }
        return found
    }

    /// 塗られた画素 (赤 > 0.05) の数。
    private func painted(_ pixels: PixelBuffer) -> Int {
        var count = 0
        for y in 0..<pixels.height {
            for x in 0..<pixels.width where pixels[x, y].red > 0.05 { count += 1 }
        }
        return count
    }

    /// 片方にだけ塗られた画素の位置 (引いた所の穴か、はみ出し)。
    private func differingRegion(_ a: PixelBuffer, _ b: PixelBuffer) -> [SIMD2<Int>] {
        var found: [SIMD2<Int>] = []
        for y in 0..<a.height {
            for x in 0..<a.width where (a[x, y].red > 0.05) != (b[x, y].red > 0.05) {
                found.append(SIMD2(x, y))
            }
        }
        return found
    }

    /// 描いた線が CPU の帯を通ったか (``Canvas/placeGPUStroke(of:mesh:)`` の列が 1 つも無く、
    /// 線の頂点が溜め場にある)。描く途中 (`draw` の中) で読む。
    private func strokedOnTheCPU(_ canvas: Canvas) -> Bool {
        canvas.closeBatch()
        return canvas.batches.allSatisfy { $0.strokeGeometry == nil }
            && canvas.solidVertices.contains { $0.stroke > 0 }
    }

    // MARK: - 形

    /// 起票時の閉じた 4 点。`depth` なら `vertex(x, y, 0)` で置き、立体の経路へ落とす。
    private static func closedSquare(_ canvas: Canvas, depth: Bool) {
        canvas.beginShape()
        for (x, y) in [(40, 40), (120, 40), (120, 120), (40, 120)] as [(Float, Float)] {
            if depth { canvas.vertex(x, y, 0) } else { canvas.vertex(x, y) }
        }
        canvas.endShape(.close)
    }

    // MARK: - 条件 1: 閉じた 4 点

    /// 平面の同じ 4 点 (#1536 の直しの後) と、重ね塗りの画素の数と角の値が揃う。
    @Test(
        "奥行きを持つ閉じた 4 点の半透明の線は、角も辺と同じく 1 回だけ混ぜ、平面の同じ 4 点と揃う",
        arguments: [StrokeJoin.miter, .bevel, .round])
    func closedSquareBlendsOnce(_ join: StrokeJoin) throws {
        func draw(depth: Bool) throws -> PixelBuffer {
            try translucent { canvas in
                canvas.strokeWeight(20)
                canvas.strokeJoin(join)
                Self.closedSquare(canvas, depth: depth)
            }.pixels
        }
        let solid = try draw(depth: true)
        let flat = try draw(depth: false)
        #expect(overpainted(solid).count == 0, "\(join): 重ね塗り \(overpainted(solid).count)")
        #expect(abs(solid[45, 45].red - Self.once) <= 0.01, "\(join): 角 (45, 45) \(solid[45, 45].red)")
        #expect(abs(solid[80, 45].red - Self.once) <= 0.01, "\(join): 辺の中ほど \(solid[80, 45].red)")
        #expect(
            overpainted(solid).count == overpainted(flat).count,
            "\(join): 立体 \(overpainted(solid).count) / 平面 \(overpainted(flat).count)")
        #expect(solid[45, 45].red == flat[45, 45].red, "\(join): 立体 \(solid[45, 45].red) / 平面 \(flat[45, 45].red)")
    }

    // MARK: - 条件 2: 開いた 2 点

    @Test(
        "奥行きを持つ開いた 2 点の半透明の線は、端の形と帯を重ねて混ぜない",
        arguments: [StrokeCap.round, .project])
    func twoPointCapsBlendOnce(_ cap: StrokeCap) throws {
        let pixels = try translucent { canvas in
            canvas.strokeWeight(20)
            canvas.strokeCap(cap)
            canvas.beginShape()
            canvas.vertex(40, 80, 0)
            canvas.vertex(120, 80, 0)
            canvas.endShape()
        }.pixels
        #expect(overpainted(pixels).count == 0, "\(cap): 重ね塗り \(overpainted(pixels).count)")
        #expect(abs(pixels[44, 80].red - Self.once) <= 0.01, "\(cap): 端から 4 内側 \(pixels[44, 80].red)")
        #expect(abs(pixels[80, 80].red - Self.once) <= 0.01, "\(cap): 中ほど \(pixels[80, 80].red)")
    }

    // MARK: - 条件 3: 箱の稜線

    /// 稜が 3 本集まる角で、3 本の帯と角の形を 1 回だけ混ぜる。半透明の稜線は GPU で広げず、
    /// CPU の帯を通る (条件 10)。
    @Test("noFill() の箱の半透明の稜線は、稜の集まる角で重ねて混ぜない (CPU の帯を通る)")
    func boxCornersBlendOnce() throws {
        let (pixels, onCPU) = try translucent { canvas in
            canvas.strokeWeight(8)
            canvas.translate(80, 80, 0)
            canvas.box(80)
            return strokedOnTheCPU(canvas)
        }
        #expect(onCPU, "半透明の稜線が GPU の骨で広げられた")
        #expect(painted(pixels) > 0)
        #expect(overpainted(pixels).count == 0, "重ね塗り \(overpainted(pixels).count)")
    }

    // MARK: - 条件 4: 奥行きの違う稜の交わりは引かない

    /// 箱の稜線の網 (積む順の辺) を、いまの変換といまの視点で画面へ写したもの
    /// (``Canvas/screenX(_:_:_:)``)。辺は網の骨が帯を置く順 (`strokeNet`) に並ぶ。
    private struct ProjectedNet {
        var edges: [(Int, Int)]
        var screen: [SIMD2<Float>]
        var points: [SIMD3<Float>]
    }

    private static func projectedBoxNet(_ canvas: Canvas, size: Float) -> ProjectedNet {
        let net = SolidEdges(SolidShape.box(width: size, height: size, depth: size).make())
        let screen = net.points.map { SIMD2(canvas.screenX($0.x, $0.y, $0.z), canvas.screenY($0.x, $0.y, $0.z)) }
        return ProjectedNet(edges: net.edges, screen: screen, points: net.points)
    }

    /// 線分 `a`–`b` から点 `p` までの距離。
    private static func distance(_ p: SIMD2<Float>, _ a: SIMD2<Float>, _ b: SIMD2<Float>) -> Float {
        let along = b - a
        let t = max(0, min(1, ((p - a) * along).sum() / (along * along).sum()))
        let offset = a + along * t - p
        return (offset * offset).sum().squareRoot()
    }

    /// 2 本の線分が画面で交わる点と、それぞれの線分の上の位置 (端を除く)。交わらなければ `nil`。
    private static func crossing(
        _ a: SIMD2<Float>, _ b: SIMD2<Float>, _ c: SIMD2<Float>, _ d: SIMD2<Float>
    ) -> (point: SIMD2<Float>, t: Float, u: Float)? {
        let r = b - a
        let s = d - c
        let denominator = r.x * s.y - r.y * s.x
        guard abs(denominator) > 1e-6 else { return nil }
        let t = ((c.x - a.x) * s.y - (c.y - a.y) * s.x) / denominator
        let u = ((c.x - a.x) * r.y - (c.y - a.y) * r.x) / denominator
        guard t > 0, t < 1, u > 0, u < 1 else { return nil }
        return (a + r * t, t, u)
    }

    /// 回した箱では、手前の稜と奥の稜が画面で交わる。交わる所は投影から求める: 端を共有しない
    /// 2 本の稜の線分の交点。網を辿ると太さより離れているので、**交わりは引かない**。
    ///
    /// - 重ね塗りの画素は、そうした 2 本の両方から太さの半分 + 1 画素の内にある画素に限る
    ///   (稜の集まる角には残らない)
    /// - 交点の値は、引かずに重ねて積んだときの値: 奥の稜を先に積んだ交点は 2 回 (0.618)。
    ///   手前の稜を先に積んだ交点は、奥の稜が奥行きで捨てられて 1 回 (0.413) — 立体は奥行きを
    ///   書くので、半透明でも後から積んだ奥の稜は手前の稜に隠れる ([#2183])。積む順は網の辺の順
    ///
    /// 起票時の向き (`rotateX(0.5)`・`rotateY(0.6)`) は 2 つの交点とも手前の稜を先に積むので、
    /// 奥の稜を先に積む交点を持つ向き (`rotateY` を半周回したもの) も並べ、2 回の交点を必ず通す。
    ///
    /// [#2183]: https://github.com/mokume-metal/mokume/issues/2183
    @Test("回した箱の半透明の稜線は、奥行きの違う稜の交わりを引かずに重ねて積む (CPU の帯を通る)")
    func crossingEdgesAreNotCarved() throws {
        let weight: Float = 4
        var twiceSeen = 0
        for (pitch, yaw) in [(Float(0.5), Float(0.6)), (0.5, 0.6 + Float.pi)] {
            let (pixels, (net, depths, onCPU)) = try translucent { canvas in
                canvas.strokeWeight(weight)
                canvas.translate(80, 80, 0)
                canvas.rotateX(pitch)
                canvas.rotateY(yaw)
                let net = Self.projectedBoxNet(canvas, size: 70)
                let depths = net.points.map { canvas.screenZ($0.x, $0.y, $0.z) }
                canvas.box(70)
                return (net, depths, strokedOnTheCPU(canvas))
            }
            let label = "rotateX(\(pitch))・rotateY(\(yaw))"
            #expect(onCPU, "\(label): 半透明の稜線が GPU の骨で広げられた")
            var crossings: [(point: SIMD2<Float>, pair: (Int, Int), backFirst: Bool)] = []
            for i in net.edges.indices {
                for j in net.edges.indices where j > i {
                    let (a, b) = net.edges[i]
                    let (c, d) = net.edges[j]
                    guard Set([a, b]).isDisjoint(with: [c, d]),
                        let found = Self.crossing(net.screen[a], net.screen[b], net.screen[c], net.screen[d])
                    else { continue }
                    // 交点での奥行き (画面の上の位置で両端の奥行きを按分する。2 本は箱の厚みほど離れている)
                    let depthI = depths[a] + (depths[b] - depths[a]) * found.t
                    let depthJ = depths[c] + (depths[d] - depths[c]) * found.u
                    // 先に積むのは辺の番号の小さい i。i が奥なら 2 回
                    crossings.append((found.point, (i, j), depthI > depthJ))
                }
            }
            #expect(!crossings.isEmpty, "\(label): 交わる稜が無い (投影の求め方を確かめる)")
            // 線は画面で半画素寄せて描く (ADR-0039 決定 2)。画素 (x, y) の中心は、投影の座標で (x, y)
            let reach = weight / 2 + 1
            let stray = overpainted(pixels).filter { pixel in
                let center = SIMD2(Float(pixel.x), Float(pixel.y))
                return !crossings.contains { crossing in
                    let (i, j) = crossing.pair
                    return Self.distance(center, net.screen[net.edges[i].0], net.screen[net.edges[i].1]) <= reach
                        && Self.distance(center, net.screen[net.edges[j].0], net.screen[net.edges[j].1]) <= reach
                }
            }
            #expect(stray.isEmpty, "\(label): 交わりの外の重ね塗り \(stray.count) 画素: \(stray.prefix(12))")
            for crossing in crossings {
                let value = pixels[Int(crossing.point.x.rounded()), Int(crossing.point.y.rounded())].red
                let expected = crossing.backFirst ? Self.twice : Self.once
                #expect(
                    abs(value - expected) <= 0.01,
                    "\(label): 交点 \(crossing.point) (奥の稜が先: \(crossing.backFirst)) の赤 \(value)")
                if crossing.backFirst { twiceSeen += 1 }
            }
        }
        #expect(twiceSeen > 0, "奥の稜を先に積む交点が無い (2 回の交わりを確かめていない)")
    }

    // MARK: - 条件 9: 起票時の曲線を立体の経路で

    /// `vertex` に `z` を 1 度でも渡すと、`z = 0` でも立体の経路へ落ちる (`shapeHasDepth`)。
    /// 刻みの継ぎ目に置く円板は、刻みが太さの半分より短い所で 2 つ先の帯まで届く。
    @Test("起票時の曲線を立体の経路で描いた半透明の線は、刻みの継ぎ目で重ねて混ぜない")
    func filedCurveWithDepthBlendsOnce() throws {
        let pixels = try translucent { canvas in
            canvas.strokeWeight(20)
            canvas.beginShape()
            canvas.vertex(20, 120, 0)
            canvas.bezierVertex(40, 20, 120, 20, 140, 120)
            canvas.endShape()
        }.pixels
        #expect(painted(pixels) > 0)
        #expect(overpainted(pixels).count <= 5, "重ね塗り \(overpainted(pixels).count)・塗った \(painted(pixels))")
    }

    // MARK: - 塗る領域は変わらない

    /// 引き算は片の和を変えない。半透明の線 (引いて積む) と不透明の線 (重ねて積む・組み込みの
    /// 立体は GPU の骨) は、同じ画素を塗る — 片どうしの継ぎ目に穴もはみ出しも無いことの見張り。
    /// 継ぎ目の点は片ごとの平面で戻すと単精度の丸めで画面の位置がずれ、画素の中心が継ぎ目に
    /// 乗る所 (軸に沿った偶数の太さの縁) で穴か重なりになる (``SolidStrokeCarving``)。
    @Test("半透明の立体の線は、不透明の同じ線と同じ画素を塗る", arguments: 0..<9)
    func translucentStrokeKeepsItsRegion(_ shape: Int) throws {
        func draw(_ canvas: Canvas) {
            switch shape {
            case 0:
                canvas.strokeWeight(20)
                Self.closedSquare(canvas, depth: true)
            case 1:
                canvas.strokeWeight(20)
                canvas.strokeJoin(.round)
                Self.closedSquare(canvas, depth: true)
            case 2:
                canvas.strokeWeight(20)
                canvas.beginShape()
                canvas.vertex(40, 80, 0)
                canvas.vertex(120, 80, 0)
                canvas.endShape()
            case 3:
                canvas.strokeWeight(8)
                canvas.translate(80, 80, 0)
                canvas.box(80)
            case 4:
                canvas.strokeWeight(4)
                canvas.translate(80, 80, 0)
                canvas.rotateX(0.5)
                canvas.rotateY(0.6)
                canvas.box(70)
            case 5:
                canvas.strokeWeight(20)
                canvas.beginShape()
                canvas.vertex(20, 120, 0)
                canvas.bezierVertex(40, 20, 120, 20, 140, 120)
                canvas.endShape()
            case 6:
                canvas.strokeWeight(6)
                canvas.translate(80, 80, 0)
                canvas.rotateX(0.45)
                canvas.rotateY(0.7)
                canvas.sphere(55)
            case 7:
                canvas.strokeWeight(5)
                canvas.translate(80, 80, 0)
                canvas.rotateX(0.9)
                canvas.rotateY(0.3)
                canvas.torus(50, 16)
            default:
                canvas.strokeWeight(10)
                canvas.strokeJoin(.round)
                canvas.translate(80, 80, 0)
                canvas.rotateX(0.6)
                canvas.rotateZ(0.3)
                canvas.beginShape()
                canvas.vertex(-50, -50, 0)
                canvas.vertex(50, -50, 0)
                canvas.vertex(50, 50, 0)
                canvas.vertex(-50, 50, 0)
                canvas.endShape(.close)
            }
        }
        let carved = try translucent { draw($0) }.pixels
        let stacked = try translucent { canvas in
            canvas.stroke(255, 0, 0)
            draw(canvas)
        }.pixels
        #expect(painted(stacked) > 0)
        let differing = differingRegion(carved, stacked)
        #expect(differing.isEmpty, "形 \(shape): 塗る画素が \(differing.count) 違う: \(differing.prefix(12))")
    }

    // MARK: - 保持した形

    /// 保持した形の立体の線は、置くときにいまの視点で組み直す (`rebuiltSolidStroke`)。組み直しも
    /// 同じく重なりを引いて積む。
    @Test("半透明の線で記録した奥行きを持つ閉じた 4 点は、置いても角で重ねて混ぜない")
    func translucentRecordedSolidRingBlendsOnce() throws {
        let pixels = try placed(
            { canvas in
                canvas.createShape {
                    canvas.noFill()
                    canvas.stroke(255, 0, 0, 128)
                    canvas.strokeWeight(20)
                    Self.closedSquare(canvas, depth: true)
                }
            }, at: [Placement()])
        #expect(overpainted(pixels).count == 0, "重ね塗り \(overpainted(pixels).count)")
        #expect(abs(pixels[45, 45].red - Self.once) <= 0.01, "角 (45, 45): \(pixels[45, 45].red)")
    }

    /// 不透明の線で記録した形に、置き場所で半透明の色を掛ける (平面の #1829 と同じ口)。GPU で
    /// 組む線も、透けたら CPU の帯で組み直す (`placeSplittingGPUStrokes`)。
    @Test("不透明の線で記録した箱に半透明の色を掛けて置いても、稜の集まる角で重ねて混ぜない")
    func tintedRecordedBoxBlendsOnce() throws {
        let pixels = try placed(
            { canvas in
                canvas.createShape {
                    canvas.noFill()
                    canvas.stroke(255, 0, 0)
                    canvas.strokeWeight(8)
                    canvas.translate(80, 80, 0)
                    canvas.box(80)
                }
            }, at: [Placement(fill: Self.veil)])
        #expect(painted(pixels) > 0)
        #expect(overpainted(pixels).count == 0, "重ね塗り \(overpainted(pixels).count)")
    }
}
