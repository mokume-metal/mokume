// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation
import Testing

@testable import MokumeCore

// 図形の公開の口は、SVG の書き出しで **控えるか、名指しで落とすかのどちらか**になる ([#3139]・完了条件 9)。
//
// `save("x.svg")` は、図形を置く口の内側で控える。口を足した日に控えを足し忘れると、その図形だけが
// 黙って書かれない (ADR-0023 の改訂 (2026-10-23)・ADR-0020 決定 5)。ここは図形の口を **1 つずつ呼んで**、
// 控えた図形か、落として数えた種類のどちらかが残ることを見る。
//
// **口の列挙の元は `scripts/api-surface.py` の `PORT_KINDS` の「図形」の行である。** 口を足すと
// `make api` が種類を決めることを求め、「図形」と決めると、この検査に呼び出しが **多重定義の数だけ**
// あることを求める (`check_vector_ports`)。呼び出しの形 (`$0.` / `canvas.` / `sketch.` に続く
// `名前(`) だけを数えるので、ここでは下の `handled { $0.名前(…) }` の形で書く。
// 書き出さない口は `VECTOR_EXEMPT` へ理由つきで置く (`background()` — 完了条件 15)。
//
// [#3139]: https://github.com/mokume-metal/mokume/issues/3139

@Suite(
    "図形の口は、SVG に控えるか名指しで落とすかのどちらかになる",
    .enabled(
        if: RenderDevice.isAvailable,
        "この世代のコマンド構造に対応した GPU が無い実行環境ではスキップする")
)
struct VectorFigurePortsTests {
    /// 控えるのは `draw()` の窓の中なので、Canvas を 1 つ作って窓を開く。
    private func makeCanvas() throws -> Canvas {
        try CanvasFixture.make(gpu: RenderDevice(), width: 100, height: 100)
    }

    /// `body` が置いた図形のうち、**控えたものと落として数えたものの合計**。0 なら、黙って欠けた。
    private func handled(_ canvas: Canvas, _ body: (Canvas) throws -> Void) throws -> Int {
        var total = 0
        try canvas.draw {
            canvas.beginVectorWindow(pending: [])
            canvas.startVectorCapture(path: "x.svg")
            try? body(canvas)
            let captured = canvas.endVectorWindow()
            total = (captured?.figures.count ?? 0) + (captured?.drops.count ?? 0)
        }
        return total
    }

    @Test("基本図形の口は、図形を控える")
    func primitivesAreCaptured() throws {
        let canvas = try makeCanvas()
        func captured(_ body: (Canvas) -> Void) throws -> Int {
            var figures = 0
            try canvas.draw {
                canvas.beginVectorWindow(pending: [])
                canvas.startVectorCapture(path: "x.svg")
                body(canvas)
                figures = canvas.endVectorWindow()?.figures.count ?? 0
            }
            return figures
        }
        // 控える口は、落として数えるのでは足りない — 図形そのものが残る
        #expect(try captured { $0.rect(10, 10, 20, 20) } == 1)
        #expect(try captured { $0.rect(10, 10, 20, 20, 4) } == 1)
        #expect(try captured { $0.square(10, 10, 20) } == 1)
        #expect(try captured { $0.circle(50, 50, 20) } == 1)
        #expect(try captured { $0.circle(Vector2(50, 50), 20) } == 1)
        #expect(try captured { $0.ellipse(50, 50, 30, 20) } == 1)
        #expect(try captured { $0.arc(50, 50, 30, 30, 0, 2) } >= 1)
        #expect(try captured { $0.arc(50, 50, 30, 30, 0, 2, .chord) } >= 1)
        #expect(try captured { $0.line(0, 0, 10, 10) } == 1)
        #expect(try captured { $0.point(5, 5) } == 1)
        #expect(try captured { $0.line(Vector2(0, 0), Vector2(10, 10)) } == 1)
        #expect(try captured { $0.point(Vector2(5, 5)) } == 1)
        #expect(try captured { $0.triangle(0, 0, 10, 0, 0, 10) } == 1)
        #expect(try captured { $0.quad(0, 0, 10, 0, 12, 10, 0, 8) } == 1)
        #expect(try captured { $0.bezier(0, 0, 10, 0, 20, 10, 30, 10) } == 1)
    }

    @Test("頂点で作る形の口は、図形を控える")
    func vertexShapesAreCaptured() throws {
        let canvas = try makeCanvas()
        var figures = 0
        try canvas.draw {
            canvas.beginVectorWindow(pending: [])
            canvas.startVectorCapture(path: "x.svg")
            // 点を置く 4 つの口 (奥行きを持つ口は立体として落とす・下の検査)
            canvas.beginShape()
            canvas.vertex(0, 0)
            canvas.vertex(20, 0)
            canvas.vertex(20, 20, 0.5, 0.5)
            canvas.bezierVertex(15, 30, 5, 30, 0, 20)
            canvas.quadraticVertex(-5, 10, 0, 0)
            canvas.curveVertex(0, 0)
            canvas.curveVertex(0, 0)
            canvas.curveVertex(10, 10)
            canvas.curveVertex(20, 0)
            canvas.beginContour()
            canvas.vertex(5, 5)
            canvas.vertex(10, 5)
            canvas.vertex(10, 10)
            canvas.endContour()
            canvas.endShape(.close)
            // 添字で読む形と面の向き。平面の形では添字も向きも絵に出ないが、呼んで落ちない
            canvas.beginShape(.triangles)
            canvas.normal(0, 0, 1)
            canvas.vertex(30, 30)
            canvas.vertex(40, 30)
            canvas.vertex(30, 40)
            canvas.index(0)
            canvas.index(1)
            canvas.index(2)
            canvas.endShape()
            figures = canvas.endVectorWindow()?.figures.count ?? 0
        }
        #expect(figures >= 2)
    }

    @Test("奥行きを持つ頂点と立体の口は、立体として名指しで落とす")
    func solidsAreDropped() throws {
        let canvas = try makeCanvas()
        let model = try canvas.loadModel(ModelFixture.pyramid)
        #expect(try handled(canvas) { $0.line(0, 0, 0, 10, 10, 10) } == 1)
        #expect(try handled(canvas) { $0.point(0, 0, 5) } == 1)
        #expect(try handled(canvas) { $0.line(Vector3(0, 0, 0), Vector3(10, 10, 10)) } == 1)
        #expect(try handled(canvas) { $0.point(Vector3(0, 0, 5)) } == 1)
        // 奥行きを持つ頂点 (2 つの書き方) は、形ごと立体として 1 つ数える
        #expect(
            try handled(canvas) {
                $0.beginShape(.triangles)
                $0.vertex(1, 2, 3)
                $0.vertex(4, 5, 6, 0, 0)
                $0.vertex(7, 8, 9)
                $0.endShape()
            } == 1)
        #expect(try handled(canvas) { $0.box(10) } == 1)
        #expect(try handled(canvas) { $0.box(10, 20, 30) } == 1)
        #expect(try handled(canvas) { $0.sphere(10) } == 1)
        #expect(try handled(canvas) { $0.ellipsoid(10, 12, 14) } == 1)
        #expect(try handled(canvas) { $0.plane(10, 20) } == 1)
        #expect(try handled(canvas) { $0.cylinder(10, 20) } == 1)
        #expect(try handled(canvas) { $0.cone(10, 20) } == 1)
        #expect(try handled(canvas) { $0.torus(20, 5) } == 1)
        #expect(try handled(canvas) { $0.model(model) } == 1)
    }

    @Test("字・絵・保持した形・画素・画素への効果・粒の口は、書けないものとして名指しで落とす")
    func pixelsAndTextAreDropped() throws {
        let canvas = try makeCanvas()
        let image = try canvas.createImage(4, 4)
        let layer = try canvas.createGraphics(8, 8)
        let shape = canvas.createShape { canvas.rect(0, 0, 5, 5) }
        let dust = try canvas.makeParticles(count: 8)
        #expect(try handled(canvas) { $0.text("a", 10, 10) } == 1)
        #expect(try handled(canvas) { $0.text("a b", 5, 5, 40, 40) } == 1)
        #expect(try handled(canvas) { $0.shapedText("ab", 10, 10) } == 1)
        #expect(try handled(canvas) { $0.image(image, 0, 0) } == 1)
        #expect(try handled(canvas) { $0.image(image, 0, 0, 10, 10) } == 1)
        #expect(try handled(canvas) { $0.image(image, 0, 0, 10, 10, 0, 0, 2, 2) } == 1)
        #expect(try handled(canvas) { $0.image(layer, 0, 0) } == 1)
        #expect(try handled(canvas) { $0.image(layer, 0, 0, 10, 10) } == 1)
        #expect(try handled(canvas) { $0.image(layer, 0, 0, 10, 10, 0, 0, 2, 2) } == 1)
        #expect(try handled(canvas) { $0.shape(shape) } == 1)
        #expect(try handled(canvas) { $0.shape(shape, at: [Placement(x: 1, y: 1)]) } == 1)
        #expect(try handled(canvas) { $0.set(1, 1, .linear(red: 1, green: 0, blue: 0)) } == 1)
        // 画素の窓 (`pixels`) からの書き込みも、`set` と同じく数える。種類は「読み取り」だが、
        // `VECTOR_ALSO` が「図形」の口と同じに見る (#3139)
        #expect(try handled(canvas) { $0.pixels[1, 1] = .linear(red: 1, green: 0, blue: 0) } == 1)
        #expect(try handled(canvas) { $0.pixels.fill(.linear(red: 0, green: 1, blue: 0)) } == 1)
        #expect(try handled(canvas) { $0.pixels.update { _, _, color in color } } == 1)
        #expect(try handled(canvas) { $0.filter([.threshold(level: 0.5)]) } == 1)
        #expect(try handled(canvas) { $0.particles(dust) } == 1)
    }

    @Test("道 (Path) を描く口は、同じ beginShape を描いたときと同じく、図形を控える (落とさない)")
    func pathsAreCaptured() throws {
        let canvas = try makeCanvas()
        let path = canvas.createPath {
            canvas.beginShape()
            canvas.vertex(10, 10)
            canvas.vertex(60, 10)
            canvas.vertex(60, 60)
            canvas.endShape(.close)
        }
        var figures = 0
        var drops = 0
        try canvas.draw {
            canvas.beginVectorWindow(pending: [])
            canvas.startVectorCapture(path: "x.svg")
            canvas.fill(.linear(red: 1, green: 0, blue: 0))
            canvas.shape(path)
            let captured = canvas.endVectorWindow()
            figures = captured?.figures.count ?? 0
            drops = captured?.drops.count ?? 0
        }
        #expect(figures == 1 && drops == 0, "figures=\(figures) drops=\(drops)")
        #expect(try handled(canvas) { $0.shape(path) } == 1)
    }
}
