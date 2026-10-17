// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Testing

@testable import MokumeCore

/// 2D の値型の `draw()` (#2600 の完了条件 2・3)。
///
/// 値は描画のモードに依らず書いたとおりの場所へ描き、見た目は値が持つものが優先し、描いた後の
/// 状態を変えない。同じ絵を関数で書いたものと画素で突き合わせ、状態は描いた直後の面から読む。
@Suite(
    "2D の値型を描く",
    .enabled(
        if: RenderDevice.isAvailable,
        "この世代のコマンド構造に対応した GPU が無い実行環境ではスキップする")
)
struct ShapeValueDrawingTests {
    /// `body` を `draw()` として 1 フレーム描くスケッチ。
    final class Scene: Sketch {
        var settings = SketchSettings(width: 160, height: 80)
        var body: (Scene) -> Void = { _ in }
        /// 描き終えた直後の面の設定 (塗り・線・モード)。
        var after: Canvas.Style?

        init() {}

        convenience init(_ body: @escaping (Scene) -> Void) {
            self.init()
            self.body = body
        }

        func draw() {
            background(20)
            noStroke()
            body(self)
            after = canvas.currentStyle
        }
    }

    /// 不透明の画素が、`color(r, g, b)` を面いっぱいに塗った画素と 2 階調以内か。
    ///
    /// 出す画素は表示の色空間へ移るので、sRGB の数をそのまま比べない。同じ色を下地として
    /// 塗った画素を手本にする (結果を読む側だけを揃え、描く側の経路は比べる相手に入れない)。
    private func near(
        _ pixel: (red: UInt8, green: UInt8, blue: UInt8, alpha: UInt8), _ expected: (Int, Int, Int)
    ) throws -> Bool {
        let (swatch, _) = try firstFrame(
            of: Scene { s in s.background(expected.0, expected.1, expected.2) })
        let reference = swatch[0, 0]
        return pixel.alpha == 255 && abs(Int(pixel.red) - Int(reference.red)) <= 2
            && abs(Int(pixel.green) - Int(reference.green)) <= 2
            && abs(Int(pixel.blue) - Int(reference.blue)) <= 2
    }

    private func firstFrame(of scene: Scene) throws -> (DisplayImage, Canvas) {
        let runtime = try SketchRuntime(sketch: scene, gpu: try RenderDevice())
        try runtime.advance()
        return (try runtime.canvas.target.encodeForDisplay(), runtime.canvas)
    }

    // MARK: - 完了条件 3: 塗りを持たない値は今の状態で塗る

    @Test("塗りを持たない Rect は、既定のモードで rect() と同じ画素になる")
    func rectMatchesTheFunction() throws {
        let (value, _) = try firstFrame(
            of: Scene { s in
                s.fill(240, 120, 60)
                Rect(left: 10, top: 10, width: 120, height: 40).draw()
            })
        let (function, _) = try firstFrame(
            of: Scene { s in
                s.fill(240, 120, 60)
                s.rect(10, 10, 120, 40)
            })
        #expect(value == function)
        #expect(try near(value[70, 30], (240, 120, 60)))
    }

    @Test("塗りを持たない Circle は、既定のモードで circle() と同じ画素になる")
    func circleMatchesTheFunction() throws {
        let (value, _) = try firstFrame(
            of: Scene { s in
                s.fill(240, 120, 60)
                Circle(x: 80, y: 40, radius: 30).draw()
            })
        let (function, _) = try firstFrame(
            of: Scene { s in
                s.fill(240, 120, 60)
                s.circle(80, 40, 60)
            })
        #expect(value == function)
        #expect(try near(value[80, 40], (240, 120, 60)))
    }

    // MARK: - 完了条件 2: モードに依らず、警告しない

    @Test("rectMode(.center) の中でも、Rect は左上 (10, 10) から描き、警告しない")
    func rectIgnoresRectMode() throws {
        let log = OutsideRun()
        let (image, canvas) = try OutsideRun.$current.withValue(log) {
            try firstFrame(
                of: Scene { s in
                    s.rectMode(.center)
                    s.fill(240, 120, 60)
                    Rect(left: 10, top: 10, width: 120, height: 40).draw()
                })
        }
        // 左上の角の内側と、右下の角の内側が塗られる。中心指定なら (-50, -10) から描かれ、右下は空く
        #expect(try near(image[12, 12], (240, 120, 60)))
        #expect(try near(image[127, 47], (240, 120, 60)))
        #expect(try near(image[132, 30], (20, 20, 20)))
        #expect(canvas.warnings.count(where: { _ in true }) == 0)
        #expect(log.messages.isEmpty)
    }

    @Test("ellipseMode(.corner) の中でも、Circle は中心 (80, 40) に描く")
    func circleIgnoresEllipseMode() throws {
        let (image, canvas) = try firstFrame(
            of: Scene { s in
                s.ellipseMode(.corner)
                s.fill(240, 120, 60)
                Circle(x: 80, y: 40, radius: 30).draw()
            })
        #expect(try near(image[80, 40], (240, 120, 60)))
        #expect(try near(image[55, 40], (240, 120, 60)))
        #expect(try near(image[105, 40], (240, 120, 60)))
        #expect(try near(image[80, 75], (20, 20, 20)))
        #expect(canvas.warnings.count(where: { _ in true }) == 0)
    }

    // MARK: - 完了条件 3: 値が持つ塗りが優先し、状態を変えない

    @Test("塗りを持つ値は noFill() の中でもその色で塗る")
    func ownFillWinsOverNoFill() throws {
        let (image, _) = try firstFrame(
            of: Scene { s in
                s.noFill()
                Rect(left: 10, top: 10, width: 60, height: 40, fill: color(240, 120, 60)).draw()
                Circle(x: 120, y: 40, radius: 20, fill: color(60, 120, 240)).draw()
            })
        #expect(try near(image[40, 30], (240, 120, 60)))
        #expect(try near(image[120, 40], (60, 120, 240)))
    }

    @Test("塗りを持つ値は今の fill() より優先する")
    func ownFillWinsOverCurrentFill() throws {
        let (image, _) = try firstFrame(
            of: Scene { s in
                s.fill(255)
                Rect(left: 10, top: 10, width: 60, height: 40, fill: color(240, 120, 60)).draw()
                Circle(x: 120, y: 40, radius: 20, fill: color(60, 120, 240)).draw()
            })
        #expect(try near(image[40, 30], (240, 120, 60)))
        #expect(try near(image[120, 40], (60, 120, 240)))
    }

    @Test("描いた後の塗り・線・モードは、呼ぶ前と同じ")
    func drawingLeavesTheStateAsItWas() throws {
        var before: Canvas.Style?
        let scene = Scene { s in
            s.noFill()
            s.stroke(10, 200, 30)
            s.strokeWeight(3)
            s.rectMode(.center)
            s.ellipseMode(.radius)
            before = s.canvas.currentStyle
            Rect(left: 10, top: 10, width: 60, height: 40, fill: color(240, 120, 60)).draw()
            Circle(x: 120, y: 40, radius: 20, fill: color(60, 120, 240)).draw()
            Rect(left: 10, top: 60, width: 10, height: 10).draw()
        }
        _ = try firstFrame(of: scene)
        let after = try #require(scene.after)
        let expected = try #require(before)
        #expect(after.hasFill == expected.hasFill)
        #expect(after.fill == expected.fill)
        #expect(after.hasStroke == expected.hasStroke)
        #expect(after.stroke == expected.stroke)
        #expect(after.strokeWeight == expected.strokeWeight)
        #expect(after.rectMode == .center)
        #expect(after.ellipseMode == .radius)
    }

    @Test("輪郭は今の stroke() に従う")
    func outlineFollowsTheCurrentStroke() throws {
        let (outlined, _) = try firstFrame(
            of: Scene { s in
                s.stroke(10, 200, 30)
                s.strokeWeight(4)
                Rect(left: 20, top: 20, width: 100, height: 40, fill: color(240, 120, 60)).draw()
            })
        // 左の辺の上は線の色、内側は値の塗り
        #expect(try near(outlined[20, 40], (10, 200, 30)))
        #expect(try near(outlined[70, 40], (240, 120, 60)))
    }
}
