// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation
import Testing
import simd

@testable import MokumeCore

/// **形で切り抜く `clip { }`** ([#2431])。閉包の中で描いた 2D の塗りが切り抜きになり、型板の下位 7 ビットに入れ子の段数
/// として描かれる。GPU を要する。
///
/// 面は 400×400 の黒地で、`fill(255, 0, 0); rect(0, 0, 400, 400)` を描いた赤い画素で切り抜きを読む。円の切り抜きは多角形に
/// 刻むので (許容 0.25 画素)、縁の ±1.5 画素は判定の外に置く。
///
/// [#2431]: https://github.com/mokume-metal/mokume/issues/2431
@Suite(
    "形で切り抜く clip { }",
    .enabled(
        if: RenderDevice.isAvailable,
        "この世代のコマンド構造に対応した GPU が無い実行環境ではスキップする")
)
struct ClipShapeTests {
    private static let size = 400

    /// 黒地に `body` を走らせる。`fill(255, 0, 0); rect(0, 0, 400, 400)` は `body` の側で描く (``paintAll(_:)``)。
    private func render(
        width: Int = size, height: Int = size, _ body: (Canvas) -> Void
    ) throws -> (pixels: PixelBuffer, canvas: Canvas) {
        let canvas = try CanvasFixture.make(gpu: RenderDevice(), width: width, height: height)
        try canvas.draw {
            canvas.background(0)
            canvas.noStroke()
            body(canvas)
        }
        return (try canvas.target.readPixels(), canvas)
    }

    /// 面全体を赤で塗る。
    private static func paintAll(_ canvas: Canvas) {
        canvas.fill(255, 0, 0)
        canvas.noStroke()
        canvas.rectMode(.corner)
        canvas.rect(0, 0, Float(size), Float(size))
    }

    private static func isRed(_ pixels: PixelBuffer, _ x: Int, _ y: Int) -> Bool { pixels[x, y].red > 0.5 }

    /// 円の切り抜きの内と外を、縁の帯を除いて全画素で確かめる。`inside` は切り抜きに入るはずの画素の条件 (円の内に足す条件)。
    private func expectDisc(
        _ pixels: PixelBuffer, center: SIMD2<Float>, radius: Float,
        also inside: (Int, Int) -> Bool = { _, _ in true }, _ comment: Comment? = nil
    ) {
        var wrongInside = 0
        var wrongOutside = 0
        for y in 0..<pixels.height {
            for x in 0..<pixels.width {
                let distance = simd_length(SIMD2(Float(x) + 0.5, Float(y) + 0.5) - center)
                let red = Self.isRed(pixels, x, y)
                if distance < radius - 1.5, inside(x, y) {
                    if !red { wrongInside += 1 }
                } else if distance > radius + 1.5 || !inside(x, y) {
                    // 足す条件の境目の 1 列は、上の円の縁と同じく判定の外に置かない (矩形の縁は画素の中心の規則で決まる)
                    if red { wrongOutside += 1 }
                }
            }
        }
        #expect(wrongInside == 0, "切り抜きの内で赤くない画素 \(wrongInside) \(comment.map { "\($0)" } ?? "")")
        #expect(wrongOutside == 0, "切り抜きの外で赤い画素 \(wrongOutside) \(comment.map { "\($0)" } ?? "")")
    }

    private func redCount(_ pixels: PixelBuffer) -> Int {
        var count = 0
        for y in 0..<pixels.height { for x in 0..<pixels.width where Self.isRed(pixels, x, y) { count += 1 } }
        return count
    }

    private func clipWarnings(_ canvas: Canvas) -> Int {
        canvas.warnings.count { key in
            switch key {
            case .insideClip, .clipTooDeep, .clipInsideShape: true
            default: false
            }
        }
    }

    // MARK: - 条件 1・2: 円の切り抜きと変換

    @Test("clip { circle(200, 200, 200) } の後の赤い面は、中心から半径 100 の内側だけが赤い")
    func circleWindow() throws {
        let result = try render { canvas in
            canvas.clip { canvas.circle(200, 200, 200) }
            Self.paintAll(canvas)
        }
        expectDisc(result.pixels, center: SIMD2(200, 200), radius: 100)
        #expect(abs(redCount(result.pixels) - Int((Float.pi * 100 * 100).rounded())) <= 320)
        #expect(clipWarnings(result.canvas) == 0, "既定の線が効いていても警告しない")
    }

    /// 切り抜きで切られる側の列の経路。`rect` は基本図形の列 (距離関数) を通るので、三角形の列・貼る絵の列・立体の列も
    /// 別に確かめる (どれも型板を試す奥行きの扱いへ替わる)。
    enum Route: String, CaseIterable, CustomTestStringConvertible {
        case form, triangles, image, solid
        var testDescription: String { rawValue }
    }

    @Test("どの経路の列も切り抜きで切る (基本図形・三角形・画像・立体)", arguments: Route.allCases)
    func everyRouteIsClipped(_ route: Route) throws {
        var failure: (any Error)?
        let result = try render { canvas in
            canvas.clip { canvas.circle(200, 200, 200) }
            canvas.fill(255, 0, 0)
            switch route {
            case .form:
                canvas.rect(0, 0, 400, 400)
            case .triangles:
                canvas.beginShape()
                canvas.vertex(0, 0)
                canvas.vertex(400, 0)
                canvas.vertex(400, 400)
                canvas.vertex(0, 400)
                canvas.endShape(.close)
            case .image:
                do {
                    let picture = try canvas.createImage(4, 4)
                    picture.fill(.linear(red: 1, green: 0, blue: 0))
                    canvas.image(picture, 0, 0, 400, 400)
                } catch { failure = error }
            case .solid:
                canvas.translate(200, 200)
                canvas.box(600, 600, 1)
            }
        }
        if let failure { throw failure }
        #expect(Self.isRed(result.pixels, 200, 200), "切り抜きの中")
        #expect(!Self.isRed(result.pixels, 20, 20) && !Self.isRed(result.pixels, 380, 380), "切り抜きの外")
    }

    @Test("線の設定は読まない — strokeWeight(40) の円も、塗りの範囲 (半径 100) で切る")
    func strokeIsIgnored() throws {
        let result = try render { canvas in
            canvas.stroke(255)
            canvas.strokeWeight(40)
            canvas.clip { canvas.circle(200, 200, 200) }
            Self.paintAll(canvas)
        }
        expectDisc(result.pixels, center: SIMD2(200, 200), radius: 100)
        #expect(clipWarnings(result.canvas) == 0)
    }

    @Test("translate(100, 0) の後で書くと、切り抜きも右へ 100 動く。閉包の後の変換は切り抜きを動かさない")
    func windowReadsTheTransformAtTheCall() throws {
        let result = try render { canvas in
            canvas.translate(100, 0)
            canvas.clip { canvas.circle(200, 200, 200) }
            canvas.translate(-100, 50)
            canvas.resetMatrix()
            Self.paintAll(canvas)
        }
        expectDisc(result.pixels, center: SIMD2(300, 200), radius: 100)
    }

    @Test("閉包の中の変換は閉包の中だけで効き、出ると呼ぶ前の変換に戻る")
    func transformInsideTheBlockStaysInside() throws {
        var after: simd_float4x4?
        let result = try render { canvas in
            canvas.translate(50, 0)
            canvas.clip {
                canvas.translate(0, 50)
                canvas.circle(150, 150, 200)
            }
            after = canvas.transform.matrix
            canvas.resetMatrix()
            Self.paintAll(canvas)
        }
        expectDisc(result.pixels, center: SIMD2(200, 200), radius: 100)
        #expect(after?.columns.3.x == 50 && after?.columns.3.y == 0)
    }

    // MARK: - 条件 3: 入れ子は交わる・1 つの閉包の中は和

    @Test("入れ子の切り抜きは交わる: 円の後に右半分の矩形を書くと、円の右半分だけが赤い")
    func nestedWindowsIntersect() throws {
        let result = try render { canvas in
            canvas.clip { canvas.circle(200, 200, 200) }
            canvas.clip { canvas.rect(200, 0, 200, 400) }
            Self.paintAll(canvas)
        }
        expectDisc(result.pixels, center: SIMD2(200, 200), radius: 100, also: { x, _ in x >= 200 })
        #expect(!Self.isRed(result.pixels, 150, 200), "円の左半分は落とす")
    }

    @Test("1 つの閉包の中の形は和になり、重なりも切り抜きに入る。穴 (beginContour) は切り抜きの外")
    func shapesInOneBlockUnite() throws {
        let result = try render { canvas in
            canvas.clip {
                canvas.circle(150, 200, 200)
                canvas.circle(250, 200, 200)
                canvas.beginShape()
                canvas.vertex(0, 0)
                canvas.vertex(100, 0)
                canvas.vertex(100, 100)
                canvas.vertex(0, 100)
                canvas.beginContour()
                canvas.vertex(25, 25)
                canvas.vertex(25, 75)
                canvas.vertex(75, 75)
                canvas.vertex(75, 25)
                canvas.endContour()
                canvas.endShape(.close)
            }
            Self.paintAll(canvas)
        }
        let pixels = result.pixels
        #expect(Self.isRed(pixels, 200, 200), "2 つの円の重なり")
        #expect(Self.isRed(pixels, 80, 200) && Self.isRed(pixels, 320, 200), "それぞれの円")
        #expect(!Self.isRed(pixels, 200, 330), "どちらの円の外")
        #expect(Self.isRed(pixels, 10, 10), "穴の外の枠")
        #expect(!Self.isRed(pixels, 50, 50), "穴の中")
    }

    // MARK: - 条件 5: 戻し方

    @Test("push / pop と pushStyle / popStyle は切り抜きを戻し、pushMatrix / popMatrix は戻さない")
    func stacksRestoreTheWindow() throws {
        for (name, push, pop, restores) in [
            ("push", { (c: Canvas) in c.push() }, { (c: Canvas) in c.pop() }, true),
            ("pushStyle", { (c: Canvas) in c.pushStyle() }, { (c: Canvas) in c.popStyle() }, true),
            ("pushMatrix", { (c: Canvas) in c.pushMatrix() }, { (c: Canvas) in c.popMatrix() }, false),
        ] {
            let result = try render { canvas in
                push(canvas)
                canvas.clip { canvas.circle(200, 200, 200) }
                pop(canvas)
                Self.paintAll(canvas)
            }
            #expect(Self.isRed(result.pixels, 10, 10) == restores, "\(name)")
            #expect(Self.isRed(result.pixels, 200, 200), "\(name)")
        }
    }

    @Test("切り抜きはフレームを越えない — 次のフレームは切り抜きなしで始まる")
    func windowEndsWithTheFrame() throws {
        let canvas = try CanvasFixture.make(gpu: RenderDevice(), width: Self.size, height: Self.size)
        try canvas.draw {
            canvas.background(0)
            canvas.clip { canvas.circle(200, 200, 200) }
        }
        try canvas.draw {
            canvas.background(0)
            Self.paintAll(canvas)
        }
        let pixels = try canvas.target.readPixels()
        #expect(Self.isRed(pixels, 10, 10))
    }

    // MARK: - 条件 8: 矩形と形の混ざり方

    @Test("clip { 円 } の後の矩形の clip は置き換え、矩形の後の clip { 円 } は交わる。noClip() は全部外す")
    func rectangleReplacesAndShapeIntersects() throws {
        let replaced = try render { canvas in
            canvas.clip { canvas.circle(200, 200, 200) }
            canvas.clip(0, 0, 200, 400)
            Self.paintAll(canvas)
        }
        #expect(Self.isRed(replaced.pixels, 10, 10) && Self.isRed(replaced.pixels, 199, 399))
        #expect(!Self.isRed(replaced.pixels, 200, 200), "矩形の外")
        #expect(redCount(replaced.pixels) == 200 * 400)

        let intersected = try render { canvas in
            canvas.clip(0, 0, 200, 400)
            canvas.clip { canvas.circle(200, 200, 200) }
            Self.paintAll(canvas)
        }
        expectDisc(intersected.pixels, center: SIMD2(200, 200), radius: 100, also: { x, _ in x < 200 })

        for order in [false, true] {
            let cleared = try render { canvas in
                if order {
                    canvas.clip(0, 0, 200, 400)
                    canvas.clip { canvas.circle(200, 200, 200) }
                } else {
                    canvas.clip { canvas.circle(200, 200, 200) }
                    canvas.clip(0, 0, 200, 400)
                }
                canvas.noClip()
                Self.paintAll(canvas)
            }
            #expect(redCount(cleared.pixels) == Self.size * Self.size)
        }
    }

    // MARK: - 条件 9: 型板に描くのは 2D の塗りだけ

    @Test("塗りの無い閉包 (線・点・noFill の形・空) は 1 度警告し、切り抜きは空になる")
    func blocksWithoutFillMakeAnEmptyWindow() throws {
        let blocks: [(String, (Canvas) -> Void, Bool)] = [
            ("line", { $0.stroke(255); $0.line(0, 0, 100, 100) }, true),
            ("point", { $0.stroke(255); $0.strokeWeight(20); $0.point(200, 200) }, true),
            ("noFill", { $0.stroke(255); $0.noFill(); $0.circle(200, 200, 200) }, true),
            ("empty", { _ in }, false),
        ]
        for (name, block, warns) in blocks {
            let result = try render { canvas in
                canvas.clip { block(canvas) }
                canvas.clip { block(canvas) }  // 2 度書いても知らせるのは 1 度
                canvas.noClip()
                canvas.clip { block(canvas) }
                Self.paintAll(canvas)
            }
            #expect(redCount(result.pixels) == 0, "\(name): 切り抜きが空でない")
            #expect(result.canvas.warnings.hasWarned(.insideClip(.noFill)) == warns, "\(name)")
            #expect(clipWarnings(result.canvas) == (warns ? 1 : 0), "\(name)")
        }
    }

    @Test("塗りのある弧と、部分道が 2 つ以上の道は、線の回を描かずに塗りで切る (塗りの無い形と取り違えない)")
    func arcsAndPathsAreNotTakenForFilllessShapes() throws {
        let arc = try render { canvas in
            canvas.stroke(255)
            canvas.clip { canvas.arc(200, 200, 200, 200, 0, Float.pi) }
            Self.paintAll(canvas)
        }
        #expect(Self.isRed(arc.pixels, 200, 250) && !Self.isRed(arc.pixels, 200, 150))
        #expect(clipWarnings(arc.canvas) == 0)

        let path = try render { canvas in
            canvas.stroke(255)
            let outline = canvas.createPath {
                canvas.beginShape()
                canvas.vertex(100, 100)
                canvas.vertex(300, 100)
                canvas.vertex(300, 300)
                canvas.vertex(100, 300)
                canvas.endShape(.close)
                canvas.beginShape()
                canvas.vertex(150, 150)
                canvas.vertex(150, 250)
                canvas.vertex(250, 250)
                canvas.vertex(250, 150)
                canvas.endShape(.close)
            }
            canvas.clip { canvas.shape(outline) }
            Self.paintAll(canvas)
        }
        #expect(Self.isRed(path.pixels, 120, 120))
        #expect(clipWarnings(path.canvas) == 0)
    }

    @Test("字・画像・立体・断片・保持した形は、それぞれ 1 度警告して切り抜きに入れない。同じ閉包の円は切り抜きになる")
    func refusedKindsAreNamedOnce() throws {
        let gpu = try RenderDevice()
        let probe = try CanvasFixture.make(gpu: gpu, width: 8, height: 8)
        let image = try probe.createImage(8, 8)
        let held = probe.createShape { probe.rect(0, 0, 10, 10) }
        let cases: [(Canvas.ClipRefusal, (Canvas) throws -> Void)] = [
            (.text, { $0.text("mokume", 10, 50) }),
            (.image, { $0.image(image, 0, 0, 100, 100) }),
            (.solid, { $0.box(50) }),
            (.solid, { c in
                c.beginShape()
                c.vertex(0, 0, 10)
                c.vertex(100, 0, 10)
                c.vertex(100, 100, 10)
                c.endShape(.close)
            }),
            (.shader, { c in c.shader(try c.makeShader("float4 paint(Fragment in, Values values) { return in.color; }")); c.rect(0, 0, 100, 100) }),
            (.retainedShape, { c in c.shape(held) }),
        ]
        for (refusal, block) in cases {
            var failure: (any Error)?
            let result = try render { canvas in
                canvas.clip {
                    do { try block(canvas) } catch { failure = error }
                    canvas.resetShader()
                    canvas.circle(300, 300, 100)
                }
                Self.paintAll(canvas)
            }
            if let failure { throw failure }
            #expect(result.canvas.warnings.hasWarned(.insideClip(refusal)), "\(refusal)")
            #expect(clipWarnings(result.canvas) == 1, "\(refusal)")
            #expect(Self.isRed(result.pixels, 300, 300), "\(refusal): 同じ閉包の円")
            #expect(!Self.isRed(result.pixels, 20, 20), "\(refusal): 断ったものは切り抜きに入らない")
        }
    }

    @Test("閉包の中の clip()・clip { }・noClip() は効かずに警告し、外の切り抜きはそのまま")
    func clipsInsideTheBlockAreRefused() throws {
        let result = try render { canvas in
            canvas.clip {
                canvas.clip(0, 0, 10, 10)
                canvas.clip { canvas.rect(0, 0, 10, 10) }
                canvas.noClip()
                canvas.circle(200, 200, 200)
            }
            Self.paintAll(canvas)
        }
        expectDisc(result.pixels, center: SIMD2(200, 200), radius: 100)
        #expect(result.canvas.warnings.hasWarned(.insideClip(.nested)))
        #expect(!result.canvas.warnings.hasWarned(.clipInsideShape))
    }

    // MARK: - 条件 10: 形の組み立ての中

    @Test("createShape { } の中の clip { } は断って警告し、外の切り抜きは変わらない")
    func clipInsideCreateShapeIsRefused() throws {
        var ran = false
        let result = try render { canvas in
            canvas.clip { canvas.circle(200, 200, 200) }
            _ = canvas.createShape {
                canvas.clip {
                    ran = true
                    canvas.rect(0, 0, 10, 10)
                }
                canvas.rect(0, 0, 10, 10)
            }
            Self.paintAll(canvas)
        }
        #expect(!ran, "閉包は走らせない")
        #expect(result.canvas.warnings.hasWarned(.clipInsideShape))
        expectDisc(result.pixels, center: SIMD2(200, 200), radius: 100)
    }

    @Test("フレームの外の clip { } は警告して無視する")
    func clipOutsideTheFrameIsRefused() throws {
        let canvas = try CanvasFixture.make(gpu: RenderDevice(), width: 8, height: 8)
        var ran = false
        canvas.clip { ran = true }
        #expect(!ran)
        #expect(canvas.currentStyle.clipShape == nil)
    }

    // MARK: - 境界: 段の上限

    @Test("127 段までは積め、128 段目は警告して積まない")
    func depthLimit() throws {
        var depths: [Int] = []
        let result = try render { canvas in
            for _ in 0..<Canvas.clipDepthLimit { canvas.clip { canvas.rect(0, 0, 400, 400) } }
            depths.append(canvas.currentStyle.clipShape?.depth ?? 0)
            canvas.clip { canvas.rect(0, 0, 10, 10) }
            depths.append(canvas.currentStyle.clipShape?.depth ?? 0)
            Self.paintAll(canvas)
        }
        #expect(depths == [127, 127])
        #expect(result.canvas.warnings.hasWarned(.clipTooDeep))
        #expect(redCount(result.pixels) == Self.size * Self.size, "128 段目 (10×10) は効かない")
    }

    // MARK: - 型板の描き直し

    @Test("違う切り抜きを交互に描く列は、型板を外して描き直す (外す段が残らない)")
    func alternatingWindowsRemoveLayers() throws {
        let result = try render { canvas in
            canvas.fill(255, 0, 0)
            canvas.push()
            canvas.clip { canvas.circle(100, 100, 100) }
            canvas.rect(0, 0, 400, 400)
            canvas.pop()
            canvas.push()
            canvas.clip { canvas.circle(300, 300, 100) }
            canvas.fill(0, 255, 0)
            canvas.rect(0, 0, 400, 400)
            canvas.pop()
            canvas.push()
            canvas.clip { canvas.rect(0, 200, 200, 200) }
            canvas.clip { canvas.rect(100, 200, 100, 200) }
            canvas.fill(0, 0, 255)
            canvas.rect(0, 0, 400, 400)
            canvas.pop()
            // 切り抜きなしの列は面全体に描ける
            canvas.fill(255, 255, 255)
            canvas.rect(0, 0, 400, 10)
        }
        let pixels = result.pixels
        #expect(pixels[100, 100].red > 0.5 && pixels[100, 100].green < 0.5, "1 つ目の切り抜きは赤")
        #expect(pixels[300, 300].green > 0.5 && pixels[300, 300].red < 0.5, "2 つ目の切り抜きは緑")
        #expect(pixels[150, 300].blue > 0.5, "3 つ目の交わり")
        #expect(pixels[50, 300].blue < 0.5, "3 つ目の外の段だけの所")
        #expect(pixels[300, 100].red < 0.5 && pixels[300, 100].green < 0.5, "どの切り抜きの外")
        #expect(pixels[300, 5].red > 0.5 && pixels[300, 5].green > 0.5 && pixels[300, 5].blue > 0.5, "切り抜きなし")
    }

    @Test("切り抜きの中の background() は切り抜きの中だけを置き換える")
    func backgroundInsideTheWindow() throws {
        let result = try render { canvas in
            canvas.background(0, 0, 255)
            canvas.clip { canvas.circle(200, 200, 200) }
            canvas.background(255, 0, 0)
        }
        expectDisc(result.pixels, center: SIMD2(200, 200), radius: 100)
        #expect(result.pixels[10, 10].blue > 0.5)
    }

    @Test("途中の描き切り (loadPixels) の後も、次のパスの頭で型板を描き直して切り抜きが効く")
    func windowSurvivesAMidFrameDrawOut() throws {
        let result = try render { canvas in
            canvas.clip { canvas.circle(200, 200, 200) }
            canvas.loadPixels()
            Self.paintAll(canvas)
        }
        expectDisc(result.pixels, center: SIMD2(200, 200), radius: 100)
    }

    @Test("描き場所 (createGraphics) と細かさ 0.5 の面でも切り抜きが効く")
    func windowOnOtherSurfaces() throws {
        let gpu = try RenderDevice()
        let output = try RenderTarget(gpu: gpu, width: Self.size, height: Self.size)
        let half = try Canvas(output: output, gpu: gpu, pixelDensity: 0.5, upscale: .spatial)
        try half.draw {
            half.background(0)
            half.clip { half.circle(200, 200, 200) }
            Self.paintAll(half)
        }
        let pixels = try half.target.readPixels()
        #expect(pixels.width == Self.size / 2)
        #expect(Self.isRed(pixels, 100, 100) && !Self.isRed(pixels, 10, 10))

        let host = try CanvasFixture.make(gpu: gpu, width: 100, height: 100)
        let layer = try host.createGraphics(100, 100)
        try host.draw {
            layer.beginDraw()
            layer.background(0)
            layer.clip { layer.circle(50, 50, 50) }
            layer.fill(255, 0, 0)
            layer.noStroke()
            layer.rect(0, 0, 100, 100)
            layer.endDraw()
        }
        let layerPixels = try layer.target.readPixels()
        #expect(Self.isRed(layerPixels, 50, 50) && !Self.isRed(layerPixels, 5, 5))
    }

    // MARK: - 半透明の線の型板と組む ([ADR-0046])

    @Test("切り抜きの中の自分と交わる半透明の線は、交点も 1 回だけ混ぜ、切り抜きの外には出ない")
    func translucentStrokeInsideTheWindowMixesOnce() throws {
        let result = try render(width: 160, height: 160) { canvas in
            canvas.clip { canvas.rect(0, 0, 100, 160) }
            canvas.noFill()
            canvas.stroke(255, 0, 0, 128)
            canvas.strokeWeight(10)
            canvas.strokeCap(.round)
            canvas.beginShape()
            canvas.vertex(20, 20)
            canvas.vertex(140, 140)
            canvas.vertex(140, 20)
            canvas.vertex(20, 140)
            canvas.endShape()
        }
        let pixels = result.pixels
        #expect(abs(pixels[80, 80].red - 0.413) <= 0.01, "交点: \(pixels[80, 80].red)")
        var outside = 0
        for y in 0..<160 { for x in 101..<160 where pixels[x, y].red > 0.01 { outside += 1 } }
        #expect(outside == 0, "切り抜きの外に塗られた画素 \(outside)")
    }

    @Test("切り抜きの外では立体の線の消し描きが奥行きを残さず、後に置く立体を隠さない")
    func clippedSolidStrokeLeavesNoDepthOutside() throws {
        func scene(clipped: Bool) throws -> PixelBuffer {
            try render(width: 160, height: 160) { canvas in
                canvas.translate(80, 80)
                if clipped {
                    canvas.clip { canvas.rect(-80, -80, 70, 160) }
                    canvas.noFill()
                    canvas.stroke(255, 0, 0, 128)
                    canvas.strokeWeight(6)
                    canvas.rotateY(0.5)
                    canvas.rotateX(0.4)
                    canvas.box(80)
                    canvas.resetMatrix()
                    canvas.translate(80, 80)
                    canvas.noClip()
                }
                canvas.noStroke()
                canvas.fill(0, 255, 0)
                canvas.translate(0, 0, -120)
                canvas.box(160)
            }.pixels
        }
        let clipped = try scene(clipped: true)
        let plain = try scene(clipped: false)
        var differing = 0
        for y in 0..<160 { for x in 82..<160 where clipped[x, y] != plain[x, y] { differing += 1 } }
        #expect(differing == 0, "切り抜きの外で後の立体が隠れた画素 \(differing)")
    }

    // MARK: - ベクター

    @Test("切り抜きのある間の図形は、ベクターへ書かずに切り抜きとして名乗る")
    func vectorExportNamesTheClip() throws {
        let canvas = try CanvasFixture.make(gpu: RenderDevice(), width: 100, height: 100)
        try canvas.draw {
            canvas.clip { canvas.circle(50, 50, 50) }
            #expect(canvas.vectorBlocker(fills: true) == .clip)
        }
    }
}
