// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation
import Testing

@testable import MokumeCore

/// SVG を読んだ形の絵 ([#2019] 条件 2・3)。GPU を要する。
///
/// **同じ形を本体の口で手描きした絵と比べる。** 期待値は SVG の文字から手で起こした
/// `beginShape` / `bezierVertex` / `rect` / `circle` / `arc` / `line` の呼び出しで、読み解く側の
/// コードを通らない ([ADR-0019] 決定 4)。相対の命令・省略記法・群の変換・`viewBox` の倍率・
/// 色の読み方・CSS のクラスのどれを読み違えても、図形が動くか色が変わって食い違いが出る。
///
/// 一致は画素の完全一致ではなく、形の画素のうち食い違う割合で見る (``PictureDifference``)。
/// 弧は読んだ側が 3 次曲線で、手描きの側が距離関数の扇形なので、縁の画素がわずかに割れる。
///
/// [#2019]: https://github.com/mokume-metal/mokume/issues/2019
/// [ADR-0019]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0019-drawing-verification.md
@Suite(
    "SVG を読んだ形の絵",
    .enabled(
        if: RenderDevice.isAvailable,
        "この世代のコマンド構造に対応した GPU が無い実行環境ではスキップする")
)
struct SVGShapeTests {
    /// Illustrator の書き出しの形を真似た SVG。クラスの CSS・群の変換・相対の命令・省略記法・
    /// 弧・角丸・`style` 属性・名前の色・`evenodd` の穴と離れた 2 本目の輪郭を混ぜてある。
    /// `viewBox` は 100 × 70 で、幅と高さはその 2 倍。
    static let markText = """
        <?xml version="1.0" encoding="UTF-8"?>
        <svg xmlns="http://www.w3.org/2000/svg" id="Layer_1" data-name="Layer 1" width="200" height="140" viewBox="0 0 100 70">
          <defs>
            <style>
              .cls-1 { fill: #3366cc; }
              .cls-2 { fill: none; stroke: #f29a47; stroke-width: 3px; stroke-linejoin: round; }
            </style>
          </defs>
          <title>mark</title>
          <rect class="cls-1" x="5" y="5" width="30" height="20"/>
          <g transform="translate(50 15) rotate(30)">
            <path d="m-10-5h20v10q-10 10-20 0z" fill="rgb(102, 204, 153)"/>
          </g>
          <circle cx="80" cy="15" r="10" fill="crimson"/>
          <path class="cls-2" d="M10 40C20 30 30 50 40 40s20-10 30 0"/>
          <path d="M75 50a8 8 0 0 1 16 0z" fill="gold"/>
          <polygon points="45,50 55,58 35,58" style="fill:#ccc;stroke:#000;stroke-width:1"/>
          <line x1="5" y1="55" x2="30" y2="55" stroke="#fff" stroke-width="2"/>
          <rect x="85" y="25" width="10" height="12" rx="3" fill="#a0a"/>
          <path fill="#4cc" fill-rule="evenodd" d="M40 61h14v8h-14z M43 63h8v4h-8z M58 61h6v8h-6z"/>
        </svg>
        """

    /// 書き出した場所。検査ごとに別の名前で書く。
    private static func written(_ text: String) throws -> String {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("mokume-svg-shape-\(UUID().uuidString).svg")
        try text.write(to: url, atomically: true, encoding: .utf8)
        return url.path
    }

    /// 読んだ形を (10, 10) に置くスケッチ。
    final class Loaded: Sketch {
        var settings = SketchSettings(width: 220, height: 160)
        var path = ""
        /// 待たない口で読むか。
        var requests = false
        var loading: Task<Void, Never>?
        var mark: Shape?

        init() {}

        func setup() {
            // **呼んだときの描き方に左右されない**ことも同時に見る。読む直前に、形に焼き付き
            // うる描き方を既定から外しておく
            blendMode(.add)
            fill(255, 0, 0)
            stroke(0, 255, 0)
            strokeWeight(12)
            strokeCap(.round)
            rectMode(.center)
            ellipseMode(.corner)
            if requests {
                loading = Task { mark = try? await requestShape(path) }
            } else {
                mark = try? loadShape(path)
            }
            blendMode(.blend)
        }

        func draw() {
            background(0)
            if let mark { shape(mark, 10, 10) }
        }
    }

    /// 同じ形を、SVG の文字から手で起こした本体の口で描くスケッチ。
    final class HandDrawn: Sketch {
        var settings = SketchSettings(width: 220, height: 160)
        init() {}

        func draw() {
            background(0)
            push()
            translate(10, 10)
            scale(2, 2)
            // SVG の線の端の既定は butt (本体の square)・角は miter
            strokeCap(.square)
            strokeJoin(.miter)

            noStroke()
            fill(51, 102, 204)
            rect(5, 5, 30, 20)

            push()
            translate(50, 15)
            rotate(radians(30))
            fill(102, 204, 153)
            beginShape()
            vertex(-10, -5)
            vertex(10, -5)
            vertex(10, 5)
            quadraticVertex(0, 15, -10, 5)
            endShape(.close)
            pop()

            fill(220, 20, 60)
            circle(80, 15, 20)

            noFill()
            stroke(242, 154, 71)
            strokeWeight(3)
            strokeJoin(.round)
            beginShape()
            vertex(10, 40)
            bezierVertex(20, 30, 30, 50, 40, 40)
            bezierVertex(50, 30, 60, 30, 70, 40)
            endShape()
            strokeJoin(.miter)

            noStroke()
            fill(255, 215, 0)
            arc(83, 50, 16, 16, Float.pi, 2 * Float.pi)

            fill(204, 204, 204)
            stroke(0, 0, 0)
            strokeWeight(1)
            beginShape()
            vertex(45, 50)
            vertex(55, 58)
            vertex(35, 58)
            endShape(.close)

            stroke(255, 255, 255)
            strokeWeight(2)
            line(5, 55, 30, 55)

            noStroke()
            fill(170, 0, 170)
            let k: Float = 3 * 0.552_285
            beginShape()
            vertex(88, 25)
            vertex(92, 25)
            bezierVertex(92 + k, 25, 95, 28 - k, 95, 28)
            vertex(95, 34)
            bezierVertex(95, 34 + k, 92 + k, 37, 92, 37)
            vertex(88, 37)
            bezierVertex(88 - k, 37, 85, 34 + k, 85, 34)
            vertex(85, 28)
            bezierVertex(85, 28 - k, 88 - k, 25, 88, 25)
            endShape(.close)

            // evenodd の穴は、同じ向きに書いてあっても穴になる。外にある 3 本目は塗られる
            fill(68, 204, 204)
            beginShape()
            vertex(40, 61)
            vertex(54, 61)
            vertex(54, 69)
            vertex(40, 69)
            beginContour()
            vertex(43, 63)
            vertex(43, 67)
            vertex(51, 67)
            vertex(51, 63)
            endContour()
            endShape(.close)
            rect(58, 61, 6, 8)
            pop()
        }
    }

    private func picture(of sketch: any Sketch) throws -> (DisplayImage, SketchRuntime) {
        let runtime = try SketchRuntime(sketch: sketch, gpu: RenderDevice())
        try runtime.advance()
        return (try runtime.target.encodeForDisplay(), runtime)
    }

    @Test("読んだ SVG の絵が、同じ形を本体の口で描いた絵と重なる")
    func loadedShapeMatchesTheHandDrawnOne() throws {
        let path = try Self.written(Self.markText)
        defer { try? FileManager.default.removeItem(atPath: path) }
        let loaded = Loaded()
        loaded.path = path
        let (image, runtime) = try picture(of: loaded)
        let mark = try #require(loaded.mark, "SVG を読めていない")
        #expect(!mark.isEmpty)
        // 描けないものは無いので、知らせも出ない
        #expect(runtime.canvas.warnings.message(for: .svgSkipped(path: path)) == nil)

        let (reference, _) = try picture(of: HandDrawn())
        let difference = PictureDifference.between(image, reference)
        // 形の画素は約 7400 (どちらかが空なら、比べる前にここで分かる)
        #expect(difference.shapePixels > 5_000, "\(difference)")
        // 手元 (Apple M 系) では 48 / 7435 (0.65%)。弧と曲線の刻み方の違いで縁が割れる分である。
        // 一時的に壊して測った値: evenodd の穴を塗ると 2.3%、S の制御点を鏡に映さないと 7%、
        // CSS のクラスを読まないと 47%
        #expect(difference.fraction < 0.015, "読んだ形と手描きの形が食い違う: \(difference)")
    }

    @Test("待たない口で読んでも、待つ口と同じ絵になる")
    func requestedShapeMatchesTheLoadedOne() async throws {
        let path = try Self.written(Self.markText)
        defer { try? FileManager.default.removeItem(atPath: path) }

        let waited = Loaded()
        waited.path = path
        let (expected, _) = try picture(of: waited)

        let requested = Loaded()
        requested.path = path
        requested.requests = true
        let runtime = try SketchRuntime(sketch: requested, gpu: RenderDevice())
        try runtime.advance()
        await requested.loading?.value
        #expect(requested.mark != nil, "待たない口で読めていない")
        try runtime.advance()
        #expect(try runtime.target.encodeForDisplay() == expected)
    }

    /// 字と切り抜きを含む SVG を読むスケッチ。
    final class Partial: Sketch {
        var settings = SketchSettings(width: 40, height: 40)
        var path = ""
        var mark: Shape?
        init() {}
        func setup() { mark = try? loadShape(path) }
        func draw() {
            background(0)
            if let mark { shape(mark) }
        }
    }

    @Test("描けないものを含む SVG は、描ける部分を描いて、捨てたものをファイルにつき 1 度知らせる")
    func partlyDrawableFileWarnsOnce() throws {
        let path = try Self.written(
            """
            <svg xmlns="http://www.w3.org/2000/svg" width="40" height="40">
            <rect x="10" y="10" width="20" height="20" fill="#fff" clip-path="url(#c)"/>
            <text x="0" y="10">mark</text>
            </svg>
            """)
        defer { try? FileManager.default.removeItem(atPath: path) }
        let sketch = Partial()
        sketch.path = path
        let runtime = try SketchRuntime(sketch: sketch, gpu: RenderDevice())
        try runtime.advance()
        let message = try #require(
            runtime.canvas.warnings.message(for: .svgSkipped(path: path)), "捨てたものを知らせていない")
        #expect(message.contains("<text> (line 3)"))
        #expect(message.contains("clip-path (line 2)"))
        // 矩形は描かれている
        let image = try runtime.target.encodeForDisplay()
        #expect(image[20, 20] == (255, 255, 255, 255))
        #expect(image[5, 5] == (0, 0, 0, 255))
    }
}
