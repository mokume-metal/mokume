// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation
import Testing

@testable import MokumeCore

/// `Shape.bounds` — 平面の部分の幾何の外接 ([#2426] の A・完了条件 1〜7)。
///
/// 焼いた頂点と置き場所から求めるので、描かずに読める (GPU は面を作るのにだけ要る)。**線の太さを含まない**
/// ことを、太さを変えても箱が動かないことで見る。
///
/// [#2426]: https://github.com/mokume-metal/mokume/issues/2426
@Suite(
    "保持した形の外接",
    .enabled(
        if: RenderDevice.isAvailable,
        "この世代のコマンド構造に対応した GPU が無い実行環境ではスキップする")
)
struct ShapeBoundsTests {
    private func makeCanvas() throws -> Canvas {
        try CanvasFixture.make(gpu: RenderDevice(), width: 64, height: 64)
    }

    /// 箱の 4 つの値が `expected` と `tolerance` の中で一致するか。
    private func expectBox(
        _ box: Rect?, _ left: Float, _ top: Float, _ width: Float, _ height: Float,
        tolerance: Float = 1e-4, _ note: Comment? = nil, sourceLocation: SourceLocation = #_sourceLocation
    ) {
        guard let box else {
            Issue.record("外接が nil: \(note.map(String.init(describing:)) ?? "")", sourceLocation: sourceLocation)
            return
        }
        let actual = [box.left, box.top, box.width, box.height]
        let wanted = [left, top, width, height]
        for (got, want) in zip(actual, wanted) {
            #expect(
                abs(got - want) <= tolerance,
                "外接が違う: \(actual) (期待 \(wanted)) \(note.map(String.init(describing:)) ?? "")",
                sourceLocation: sourceLocation)
        }
    }

    // MARK: - 完了条件 1・2: 基本図形と線の太さ

    @Test("rect の外接は書いた矩形で、線の太さを変えても動かない")
    func rectBoundsDoNotGrowWithStrokeWeight() throws {
        let canvas = try makeCanvas()
        for weight: Float in [0, 1, 8, 40] {
            let shape = canvas.createShape {
                canvas.strokeWeight(weight)
                canvas.stroke(.linear(red: 1, green: 1, blue: 1))
                canvas.rect(10, 20, 100, 50)
            }
            expectBox(shape.bounds, 10, 20, 100, 50, "strokeWeight \(weight)")
        }
    }

    @Test("rect の塗りだけ・輪郭だけでも同じ箱で、角を丸めても動かない")
    func rectBoundsSameForFillOnlyAndStrokeOnlyAndRounded() throws {
        let canvas = try makeCanvas()
        let fillOnly = canvas.createShape {
            canvas.noStroke()
            canvas.fill(.linear(red: 1, green: 0, blue: 0))
            canvas.rect(10, 20, 100, 50)
        }
        let strokeOnly = canvas.createShape {
            canvas.noFill()
            canvas.strokeWeight(12)
            canvas.stroke(.linear(red: 1, green: 1, blue: 1))
            canvas.rect(10, 20, 100, 50)
        }
        let rounded = canvas.createShape {
            canvas.rect(10, 20, 100, 50, 12)
        }
        for (name, shape) in [("fill", fillOnly), ("stroke", strokeOnly), ("rounded", rounded)] {
            expectBox(shape.bounds, 10, 20, 100, 50, Comment(rawValue: name))
        }
    }

    @Test("circle の外接は直径の正方形")
    func circleBounds() throws {
        let canvas = try makeCanvas()
        let shape = canvas.createShape {
            canvas.strokeWeight(6)
            canvas.circle(0, 0, 40)
        }
        expectBox(shape.bounds, -20, -20, 40, 40)
    }

    @Test("楕円の外接は、回した後の軸に沿った外接になる")
    func rotatedEllipseBounds() throws {
        let canvas = try makeCanvas()
        // 半径 (30, 10) の楕円を 90° 回すと、横が 10・縦が 30
        let shape = canvas.createShape {
            canvas.rotate(Float.pi / 2)
            canvas.ellipse(0, 0, 60, 20)
        }
        expectBox(shape.bounds, -10, -30, 20, 60, tolerance: 1e-3)
    }

    // MARK: - 完了条件 3: 平面の部分が無い形

    @Test("空の形・立体だけの形・何も描かない形の外接は nil")
    func noPlanarPartMeansNil() throws {
        let canvas = try makeCanvas()
        #expect(Shape.empty.bounds == nil)
        let solid = canvas.createShape { canvas.box(10) }
        #expect(solid.vertexCount > 0, "立体の頂点が焼かれていない (検査の前提)")
        #expect(solid.bounds == nil, "立体だけの形が外接を持っている")
        let invisible = canvas.createShape {
            canvas.noFill()
            canvas.noStroke()
            canvas.rect(0, 0, 10, 10)
        }
        #expect(invisible.bounds == nil, "塗りも線も無い図形が外接に入っている")
    }

    @Test("平面と立体が混ざった形の外接は、平面の部分だけ")
    func mixedShapeBoundsIgnoreSolids() throws {
        let canvas = try makeCanvas()
        let shape = canvas.createShape {
            canvas.noStroke()
            canvas.fill(.linear(red: 1, green: 0, blue: 0))
            canvas.rect(5, 6, 10, 20)
            canvas.translate(500, 500, 500)
            canvas.box(100)
        }
        expectBox(shape.bounds, 5, 6, 10, 20)
    }

    // MARK: - 完了条件 6: 変換

    @Test("組み立ての中の変換は、焼いた後の座標で外接する")
    func transformsAreBakedIntoTheBox() throws {
        let canvas = try makeCanvas()
        let moved = canvas.createShape {
            canvas.translate(50, 0)
            canvas.rect(0, 0, 10, 10)
        }
        expectBox(moved.bounds, 50, 0, 10, 10)
        let scaled = canvas.createShape {
            canvas.translate(10, 20)
            canvas.scale(2, 3)
            canvas.rect(0, 0, 10, 10)
        }
        expectBox(scaled.bounds, 10, 20, 20, 30)
        let turned = canvas.createShape {
            canvas.rotate(Float.pi / 4)
            canvas.rect(-5, -5, 10, 10)
        }
        let half = 5 * 2.0.squareRoot()
        expectBox(turned.bounds, Float(-half), Float(-half), Float(2 * half), Float(2 * half), tolerance: 1e-3)
    }

    @Test("形の中に置いた形は、置き場所の変換が掛かった後で外接する")
    func placedChildBoundsFollowThePlacement() throws {
        let canvas = try makeCanvas()
        let child = canvas.createShape {
            canvas.strokeWeight(9)
            canvas.rect(0, 0, 10, 4)
        }
        let parent = canvas.createShape {
            canvas.translate(100, 50)
            canvas.scale(2, 2)
            canvas.shape(child, 3, 1)
        }
        // 子の (3, 1)〜(13, 5) を 2 倍して (100, 50) だけずらす
        expectBox(parent.bounds, 106, 52, 20, 8)
    }

    // MARK: - 完了条件 7: 描く幾何で外接する

    @Test("arc の外接は、楕円全体ではなく中心と弧が作る扇の箱")
    func arcBoundsAreTheSector() throws {
        let canvas = try makeCanvas()
        // 弧の端の三角関数は Float の丸めぶんずれる
        let quarter = canvas.createShape { canvas.arc(0, 0, 100, 100, 0, Float.pi / 2) }
        expectBox(quarter.bounds, 0, 0, 50, 50, tolerance: 1e-3)
        // 半円。弧が真下 (y 軸の正) を通るので縦に 50 張り、中心と両端で横が -50〜50
        let half = canvas.createShape { canvas.arc(0, 0, 100, 100, 0, Float.pi) }
        expectBox(half.bounds, -50, 0, 100, 50, tolerance: 1e-3)
        // 3/4 周。極値の角 (π/2・π・3π/2 のうち弧の中にあるもの) を取りこぼさない
        let threeQuarters = canvas.createShape { canvas.arc(0, 0, 100, 100, 0, 3 * Float.pi / 2) }
        expectBox(threeQuarters.bounds, -50, -50, 100, 100, tolerance: 1e-3)
        // 線の太さは含まない
        let thick = canvas.createShape {
            canvas.strokeWeight(20)
            canvas.arc(0, 0, 100, 100, 0, Float.pi / 2)
        }
        expectBox(thick.bounds, 0, 0, 50, 50, tolerance: 1e-3)
    }

    @Test("回した楕円の扇は、回した後の軸の極値を取りこぼさない")
    func rotatedArcBounds() throws {
        let canvas = try makeCanvas()
        // 円 (半径 50) の 0〜π/2 を 45° 回すと、弧は角度 π/4〜3π/4 に載る。x の最大は端 (50 cos 45°)、
        // y の最大は真下 (50) の極値
        let shape = canvas.createShape {
            canvas.rotate(Float.pi / 4)
            canvas.arc(0, 0, 100, 100, 0, Float.pi / 2)
        }
        let edge = Float(50 * (0.5).squareRoot())
        expectBox(shape.bounds, -edge, 0, 2 * edge, 50, tolerance: 1e-3)
    }

    @Test("線と点の外接は端点で、線の太さを含まない")
    func lineAndPointBounds() throws {
        let canvas = try makeCanvas()
        let line = canvas.createShape {
            canvas.strokeWeight(20)
            canvas.line(10, 10, 110, 40)
        }
        expectBox(line.bounds, 10, 10, 100, 30)
        let dot = canvas.createShape {
            canvas.strokeWeight(20)
            canvas.point(7, 9)
        }
        expectBox(dot.bounds, 7, 9, 0, 0)
    }

    // MARK: - 三角形で組む図形 (輪郭の周から外接を出す)

    @Test("三角形・多角形の外接は頂点の外接で、線の太さを含まない")
    func polygonBoundsIgnoreStrokeWeight() throws {
        let canvas = try makeCanvas()
        for weight: Float in [1, 30] {
            let triangle = canvas.createShape {
                canvas.strokeWeight(weight)
                canvas.stroke(.linear(red: 1, green: 1, blue: 1))
                canvas.fill(.linear(red: 1, green: 0, blue: 0))
                canvas.triangle(10, 40, 50, 5, 90, 60)
            }
            expectBox(triangle.bounds, 10, 5, 80, 55, "triangle weight \(weight)")
            let open = canvas.createShape {
                canvas.noFill()
                canvas.strokeWeight(weight)
                canvas.stroke(.linear(red: 1, green: 1, blue: 1))
                canvas.beginShape()
                canvas.vertex(0, 0)
                canvas.vertex(100, 20)
                canvas.vertex(60, 80)
                canvas.endShape()
            }
            expectBox(open.bounds, 0, 0, 100, 80, "輪郭だけの折れ線 weight \(weight)")
        }
    }

    @Test("輪郭だけの多角形を形の中に置き直しても、外接は周のまま")
    func placedStrokeOnlyPolylineBounds() throws {
        let canvas = try makeCanvas()
        let line = canvas.createShape {
            canvas.noFill()
            canvas.strokeWeight(16)
            canvas.stroke(.linear(red: 1, green: 1, blue: 1))
            canvas.beginShape()
            canvas.vertex(0, 0)
            canvas.vertex(10, 0)
            canvas.vertex(10, 10)
            canvas.endShape()
        }
        let parent = canvas.createShape {
            canvas.translate(30, 40)
            canvas.scale(3, 3)
            canvas.shape(line)
        }
        expectBox(parent.bounds, 30, 40, 30, 30)
    }

    // MARK: - 繋いだ形

    @Test("group と + は、子の外接の和")
    func groupedBoundsAreTheUnion() throws {
        let canvas = try makeCanvas()
        let left = canvas.createShape { canvas.rect(0, 0, 10, 10) }
        let right = canvas.createShape { canvas.rect(100, 50, 20, 30) }
        expectBox((left + right).bounds, 0, 0, 120, 80)
        expectBox(Shape.group([left, .empty, right]).bounds, 0, 0, 120, 80)
        expectBox(Shape.group([.empty, left]).bounds, 0, 0, 10, 10)
        #expect(Shape.group([.empty, .empty]).bounds == nil)
        #expect(Shape.group([]).bounds == nil)
    }

    @Test("組を焼き直しても、外接は同じ")
    func bakedGroupKeepsTheBounds() throws {
        let canvas = try makeCanvas()
        let a = canvas.createShape { canvas.circle(10, 10, 20) }
        let b = canvas.createShape { canvas.triangle(30, 30, 50, 30, 40, 60) }
        let whole = a + b
        let baked = canvas.createShape { canvas.shape(whole) }
        expectBox(whole.bounds, 0, 0, 50, 60)
        expectBox(baked.bounds, 0, 0, 50, 60)
    }

    // MARK: - SVG (完了条件 4 の元)

    @Test("読み込んだ SVG の外接は、viewBox ではなく描いた図形の外接")
    func loadedSVGBounds() throws {
        let canvas = try makeCanvas()
        // 印の外周は 4〜60 (viewBox は 0〜64)。`Sketches/ShapesFromSVG.swift` の `mark` と同じ形
        let source = """
            <svg width="64" height="64" viewBox="0 0 64 64" fill="none" xmlns="http://www.w3.org/2000/svg">
            <path fill-rule="evenodd" d="M32 4C47.464 4 60 16.536 60 32C60 47.464 47.464 60 32 60C16.536 60 4 47.464 4 32C4 16.536 16.536 4 32 4Z" fill="white"/>
            <path d="M32 21L42 39H22L32 21Z" fill="white"/>
            </svg>
            """
        let drawing = try SVGFile.parse(source, path: "mark.svg")
        let shape = canvas.shape(of: drawing, readFrom: "mark.svg")
        // 3 次ベジェを刻んだ周の点の外接なので、真の外接 (4〜60) と 1e-3 のうちで合う (周の点に曲線の端 4・60 が入る)
        expectBox(shape.bounds, 4, 4, 56, 56, tolerance: 1e-3)
        let center = try #require(shape.bounds).center
        #expect(abs(center.x - 32) < 1e-3 && abs(center.y - 32) < 1e-3, "中心が viewBox の中心から離れている: \(center)")
    }
}
