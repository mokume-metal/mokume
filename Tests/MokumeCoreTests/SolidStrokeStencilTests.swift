// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation
import Metal
import Testing
import simd

@testable import MokumeCore

/// その場で組む立体の半透明の線は、1 つの図形の線全体を型板で 1 回だけ混ぜる ([#1561]・[#3574])。
/// GPU を要する。
///
/// 立体の線は帯・折れ目の形・端の形・曲線の刻みの円板を、世界の座標で別々の三角形として積む。
/// 重ねたまま混ぜると、折れ目・端・稜の集まる点と、奥行きの違う稜が画面で交わる所が 2〜3 回
/// 混ざって濃くなる。型板の印 (区間の 1 回目) は型板が 0 の画素だけを通して印を付け、消し描きが
/// 同じ区間の印を消す (``ShapePipeline``)。
///
/// ## 読み方
///
/// 面は 160×160 の黒地で、線は `stroke(255, 0, 0, 128)`。1 回混ぜると線形の赤が 0.413、
/// 2 回で 0.618 になる。「重ね塗りの画素」は赤が 0.5 を超える画素とする。期待値は混ぜ方の式と、
/// 同じ図形を別の経路 (平面・不透明の線) で描いた絵から導く ([ADR-0019] 決定 4)。
///
/// [#1561]: https://github.com/mokume-metal/mokume/issues/1561
/// [#3574]: https://github.com/mokume-metal/mokume/issues/3574
/// [ADR-0019]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0019-drawing-verification.md
@Suite(
    "立体の半透明の線の型板",
    .enabled(
        if: RenderDevice.isAvailable,
        "この世代のコマンド構造に対応した GPU が無い実行環境ではスキップする")
)
struct SolidStrokeStencilTests {
    private let black = LinearRGBA.linear(red: 0, green: 0, blue: 0)

    /// 1 回だけ混ぜたときの赤 (線形)。`stroke(255, 0, 0, 128)` を黒地に 1 回 `blend` した値。
    private static let once: Float = 0.413
    /// 2 回混ぜたときの赤。
    private static let twice: Float = 0.618

    /// 黒地に描いて、線形の画素を読む。塗りは止めておく (使う検査が自分で戻す)。
    private func render(_ body: (Canvas) -> Void) throws -> PixelBuffer {
        let canvas = try CanvasFixture.make(gpu: RenderDevice(), width: 160, height: 160)
        try canvas.draw {
            canvas.background(black)
            canvas.noFill()
            body(canvas)
        }
        return try canvas.target.readPixels()
    }

    /// 半透明の赤の線で描く。
    private func translucent(_ body: (Canvas) -> Void) throws -> PixelBuffer {
        try render { canvas in
            canvas.stroke(255, 0, 0, 128)
            body(canvas)
        }
    }

    /// 赤が 0.5 を超える画素 (2 回以上混ぜた画素) の位置。
    private func overpainted(_ pixels: PixelBuffer) -> [SIMD2<Int>] {
        var found: [SIMD2<Int>] = []
        for y in 0..<pixels.height {
            for x in 0..<pixels.width where pixels[x, y].red > 0.5 { found.append(SIMD2(x, y)) }
        }
        return found
    }

    /// 赤の線が塗った画素 (赤 > 0.05) の位置。
    private func painted(_ pixels: PixelBuffer) -> Set<SIMD2<Int>> {
        var found: Set<SIMD2<Int>> = []
        for y in 0..<pixels.height {
            for x in 0..<pixels.width where pixels[x, y].red > 0.05 { found.insert(SIMD2(x, y)) }
        }
        return found
    }

    /// 画面の点 `p` を含む画素の赤。
    private func red(_ pixels: PixelBuffer, at p: SIMD2<Float>) -> Float {
        pixels[Int(p.x.rounded(.down)), Int(p.y.rounded(.down))].red
    }

    // MARK: - 形

    /// 起票時の閉じた 4 点。`depth` が偽なら平面の `vertex(x, y)` で置く。
    private static func closedSquare(_ canvas: Canvas, depth: Bool = true) {
        canvas.beginShape()
        for (x, y) in [(40, 40), (120, 40), (120, 120), (40, 120)] as [(Float, Float)] {
            if depth { canvas.vertex(x, y, 0) } else { canvas.vertex(x, y) }
        }
        canvas.endShape(.close)
    }

    /// 奥行きを持つ 2 点の線。
    private static func segment(
        _ canvas: Canvas, _ a: SIMD2<Float>, _ b: SIMD2<Float>
    ) {
        canvas.beginShape()
        canvas.vertex(a.x, a.y, 0)
        canvas.vertex(b.x, b.y, 0)
        canvas.endShape()
    }

    /// 回した `box(70)` の置き方。`flipped` なら半周回した向き (奥の稜を先に積む交点が出る)。
    private static func placeRotatedBox(_ canvas: Canvas, flipped: Bool) {
        canvas.translate(80, 80, 0)
        canvas.rotateX(0.5)
        canvas.rotateY(0.6 + (flipped ? Float.pi : 0))
    }

    /// 稜線の網の、端を共有しない 2 本の稜が画面で交わる所。いまの変換で `box(size)` の稜を
    /// 画面へ写して求める。`near`・`far` は、その画素へ向かう視線の上にある 2 本の稜の点 (形自身の座標)。
    private struct Crossing {
        var screen: SIMD2<Float>
        var near: SIMD3<Float>
        var far: SIMD3<Float>
    }

    private static func boxCrossings(_ canvas: Canvas, size: Float) -> [Crossing] {
        let h = size / 2
        var corners: [SIMD3<Float>] = []
        for x in [-h, h] { for y in [-h, h] { for z in [-h, h] { corners.append(SIMD3(x, y, z)) } } }
        // 1 つの成分だけが違う角どうしが稜
        var edges: [(Int, Int)] = []
        for i in corners.indices {
            for j in corners.indices where j > i {
                let differing = (0..<3).filter { corners[i][$0] != corners[j][$0] }.count
                if differing == 1 { edges.append((i, j)) }
            }
        }
        func screen(_ p: SIMD3<Float>) -> SIMD2<Float> {
            SIMD2(canvas.screenX(p.x, p.y, p.z), canvas.screenY(p.x, p.y, p.z))
        }
        func depth(_ p: SIMD3<Float>) -> Float { canvas.screenZ(p.x, p.y, p.z) }
        /// 稜の上で、画面の点 `target` に写る点を二分で探す (透視では画面の割合と空間の割合が違う)。
        func point(on edge: (Int, Int), at target: SIMD2<Float>) -> SIMD3<Float> {
            let (a, b) = (corners[edge.0], corners[edge.1])
            let (sa, sb) = (screen(a), screen(b))
            let along = sb - sa
            var (low, high): (Float, Float) = (0, 1)
            for _ in 0..<60 {
                let middle = (low + high) / 2
                let s = screen(a + (b - a) * middle)
                if simd_dot(s - sa, along) < simd_dot(target - sa, along) {
                    low = middle
                } else {
                    high = middle
                }
            }
            return a + (b - a) * ((low + high) / 2)
        }
        var found: [Crossing] = []
        for (m, e) in edges.enumerated() {
            for f in edges[(m + 1)...] {
                let shared = Set([e.0, e.1]).intersection([f.0, f.1])
                guard shared.isEmpty else { continue }
                let (p, p2) = (screen(corners[e.0]), screen(corners[e.1]))
                let (q, q2) = (screen(corners[f.0]), screen(corners[f.1]))
                let r = p2 - p
                let s = q2 - q
                let denominator = r.x * s.y - r.y * s.x
                guard abs(denominator) > 1e-4 else { continue }
                let t = ((q - p).x * s.y - (q - p).y * s.x) / denominator
                let u = ((q - p).x * r.y - (q - p).y * r.x) / denominator
                // 稜の端の近く (角の形と重なる所) は数えない
                guard t > 0.1, t < 0.9, u > 0.1, u < 0.9 else { continue }
                let crossing = p + r * t
                let onE = point(on: e, at: crossing)
                let onF = point(on: f, at: crossing)
                let (near, far) = depth(onE) < depth(onF) ? (onE, onF) : (onF, onE)
                found.append(Crossing(screen: crossing, near: near, far: far))
            }
        }
        return found
    }

    // MARK: - 面

    /// 描き切りのパスの記述は、色の面と同じ標本の数の `stencil8` の型板を、パスごとに 0 から
    /// 始めて捨てる (memoryless)。
    @Test("描き切りのパスは、色の面と同じ標本の数の memoryless な stencil8 の型板を持つ")
    func passCarriesAMemorylessStencil() throws {
        let canvas = try CanvasFixture.make(gpu: RenderDevice(), width: 160, height: 160)
        for pass in [
            canvas.target.makeRenderPass(clearColor: black),
            canvas.target.makeRenderPass(clearColor: nil, continuingDepth: true, keepingDepth: true),
        ] {
            let stencil = try #require(pass.stencilAttachment)
            let texture = try #require(stencil.texture)
            #expect(texture.pixelFormat == .stencil8)
            #expect(texture.storageMode == .memoryless)
            #expect(texture.sampleCount == canvas.target.texture.sampleCount)
            #expect(texture.width == canvas.target.texture.width)
            #expect(texture.height == canvas.target.texture.height)
            #expect(stencil.loadAction == .clear)
            #expect(stencil.clearStencil == 0)
            #expect(stencil.storeAction == .dontCare)
        }
    }

    // MARK: - 折れ目・端・稜の集まる点 (#1561 の条件 1〜3・9)

    @Test("奥行きを持つ閉じた 4 点は、角も 1 回だけ混ぜ、平面の同じ 4 点と同じになる")
    func closedSquareMixesOnce() throws {
        let solid = try translucent { canvas in
            canvas.strokeWeight(20)
            Self.closedSquare(canvas)
        }
        let flat = try translucent { canvas in
            canvas.strokeWeight(20)
            Self.closedSquare(canvas, depth: false)
        }
        #expect(overpainted(solid).count == 0, "重ね塗り \(overpainted(solid).count) 画素")
        #expect(abs(solid[45, 45].red - Self.once) < 0.01, "角 (45, 45) は \(solid[45, 45].red)")
        #expect(overpainted(solid).count == overpainted(flat).count)
        #expect(solid[45, 45].red == flat[45, 45].red)
    }

    @Test("奥行きを持つ開いた 2 点は、丸い端でも 1 回だけ混ぜる")
    func openSegmentMixesOnce() throws {
        let pixels = try translucent { canvas in
            canvas.strokeWeight(20)
            Self.segment(canvas, SIMD2(40, 80), SIMD2(120, 80))
        }
        #expect(overpainted(pixels).count == 0, "重ね塗り \(overpainted(pixels).count) 画素")
        #expect(abs(pixels[44, 80].red - Self.once) < 0.01, "(44, 80) は \(pixels[44, 80].red)")
    }

    @Test("box(80) の稜線は、稜の集まる角も 1 回だけ混ぜ、CPU の帯で組む")
    func boxEdgesMixOnce() throws {
        var gpuBones = 0
        let pixels = try translucent { canvas in
            canvas.strokeWeight(8)
            canvas.translate(80, 80, 0)
            canvas.box(80)
            // 半透明の稜線は GPU の骨を作らない (#1561 の条件 10)
            gpuBones = canvas.batches.filter { $0.strokeGeometry != nil }.count
                + (canvas.openSolid?.strokeGeometry != nil ? 1 : 0)
        }
        #expect(gpuBones == 0)
        #expect(overpainted(pixels).count == 0, "重ね塗り \(overpainted(pixels).count) 画素")
    }

    @Test("奥行きを持つ曲線は、刻みの円板どうしを 1 回だけ混ぜる")
    func curveMixesOnce() throws {
        let pixels = try translucent { canvas in
            canvas.strokeWeight(20)
            canvas.beginShape()
            canvas.vertex(20, 120, 0)
            canvas.bezierVertex(40, 20, 120, 20, 140, 120)
            canvas.endShape()
        }
        #expect(overpainted(pixels).count <= 5, "重ね塗り \(overpainted(pixels).count) 画素")
    }

    // MARK: - 稜が画面で交わる所 (#1561 の条件 4・#2183)

    @Test("回した box(70) の稜が画面で交わる所は、どちらの向きでも 1 回だけ混ぜる", arguments: [false, true])
    func crossingEdgesMixOnce(flipped: Bool) throws {
        var crossings: [Crossing] = []
        var gpuBones = 0
        let pixels = try translucent { canvas in
            canvas.strokeWeight(4)
            Self.placeRotatedBox(canvas, flipped: flipped)
            crossings = Self.boxCrossings(canvas, size: 70)
            canvas.box(70)
            gpuBones = canvas.batches.filter { $0.strokeGeometry != nil }.count
                + (canvas.openSolid?.strokeGeometry != nil ? 1 : 0)
        }
        #expect(gpuBones == 0)
        // 起票時の投影の交点 (65.6, 67.3)・(87.0, 98.8) が、求めた交点に入っている
        for expected in [SIMD2<Float>(65.6, 67.3), SIMD2<Float>(87.0, 98.8)] {
            #expect(crossings.contains { simd_distance($0.screen, expected) < 0.2 }, "\(crossings)")
        }
        for crossing in crossings {
            let value = red(pixels, at: crossing.screen)
            #expect(abs(value - Self.once) < 0.01, "交点 \(crossing.screen) は \(value)")
        }
        #expect(overpainted(pixels).count == 0, "重ね塗り \(overpainted(pixels).count) 画素")
    }

    /// 交点で、手前と奥の稜の間の奥行きに不透明の小さな形を置いても、交点は手前の稜に隠れる
    /// (#2183 の条件 4)。消し描きが奥行きを書かないと、奥の稜を先に積む向きで交点に奥の稜の奥行きが
    /// 残り、後に置いた形がそこだけ手前の稜を突き抜ける。
    @Test("稜の交点は手前の稜の奥行きを持ち、間に置いた形を隠す", arguments: [false, true])
    func crossingKeepsTheNearerDepth(flipped: Bool) throws {
        var crossings: [Crossing] = []
        let boxOnly = try translucent { canvas in
            canvas.strokeWeight(4)
            Self.placeRotatedBox(canvas, flipped: flipped)
            crossings = Self.boxCrossings(canvas, size: 70)
            canvas.box(70)
        }
        #expect(!crossings.isEmpty)
        for crossing in crossings {
            let withShape = try translucent { canvas in
                canvas.strokeWeight(4)
                Self.placeRotatedBox(canvas, flipped: flipped)
                canvas.box(70)
                let middle = (crossing.near + crossing.far) / 2
                canvas.noStroke()
                canvas.fill(0, 255, 0)
                canvas.translate(middle.x, middle.y, middle.z)
                canvas.box(1.5)
            }
            let x = Int(crossing.screen.x.rounded(.down))
            let y = Int(crossing.screen.y.rounded(.down))
            #expect(withShape[x, y] == boxOnly[x, y], "交点 \(crossing.screen)")
        }
    }

    @Test("ortho で縮んで写る辺の両側も 1 回だけ混ぜる")
    func foreshortenedSidesMixOnce() throws {
        let pixels = try translucent { canvas in
            canvas.ortho()
            canvas.strokeWeight(20)
            canvas.translate(80, 80, 0)
            canvas.rotateX(1.35)
            canvas.beginShape()
            for (x, y) in [(-40, -40), (40, -40), (40, 40), (-40, 40)] as [(Float, Float)] {
                canvas.vertex(x, y, 0)
            }
            canvas.endShape(.close)
        }
        #expect(overpainted(pixels).count == 0, "重ね塗り \(overpainted(pixels).count) 画素")
    }

    // MARK: - 図形どうし・塗り

    /// 別々の図形の線どうしは、これまでどおり 2 回混ぜる。探針の 1 点ではなく交わりの全画素を見て、
    /// 消し描きの消し残し (後の図形の印が通らない画素) を拾う。
    @Test("別々の図形の線が交わる所は、全画素で 2 回混ぜる")
    func separateShapesMixTwice() throws {
        let pixels = try translucent { canvas in
            canvas.strokeWeight(10)
            canvas.strokeCap(.square)
            Self.segment(canvas, SIMD2(40, 80), SIMD2(120, 80))
            Self.segment(canvas, SIMD2(80, 40), SIMD2(80, 120))
        }
        #expect(abs(pixels[80, 80].red - Self.twice) < 0.01)
        var wrong: [SIMD2<Int>] = []
        for y in 76..<84 {
            for x in 76..<84 where abs(pixels[x, y].red - Self.twice) >= 0.01 { wrong.append(SIMD2(x, y)) }
        }
        #expect(wrong.isEmpty, "2 回でない交わりの画素: \(wrong)")
        // 交わりの外は 1 回
        #expect(abs(pixels[50, 80].red - Self.once) < 0.01)
        #expect(abs(pixels[80, 50].red - Self.once) < 0.01)
    }

    @Test("不透明の塗りの箱でも、線は 1 回だけ混ぜて、手前の線が欠けない", arguments: [false, true])
    func filledBoxKeepsItsStroke(flipped: Bool) throws {
        func picture(alpha: Float) throws -> PixelBuffer {
            try render { canvas in
                canvas.fill(0, 0, 255)
                canvas.stroke(255, 0, 0, alpha)
                canvas.strokeWeight(12)
                Self.placeRotatedBox(canvas, flipped: flipped)
                canvas.box(70)
            }
        }
        let translucent = try picture(alpha: 128)
        let opaque = try picture(alpha: 255)
        #expect(overpainted(translucent).count == 0, "重ね塗り \(overpainted(translucent).count) 画素")
        // 半透明の線が塗る画素は、不透明の線が塗る画素と同じ (欠けもはみ出しも無い)
        let missing = painted(opaque).subtracting(painted(translucent))
        let extra = painted(translucent).subtracting(painted(opaque))
        #expect(missing.isEmpty, "欠けた画素 \(missing.count)")
        #expect(extra.isEmpty, "はみ出た画素 \(extra.count)")
    }
}
