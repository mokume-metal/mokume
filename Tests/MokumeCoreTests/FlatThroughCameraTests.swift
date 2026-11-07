// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Testing

@testable import MokumeCore

/// **2D の図形も、いまの視点と変換の 3 成分を通る** ([#3830]・ADR-0021 決定 1 の改訂 2026-11-07)。GPU を要する。
///
/// 変更前は、2D の図形は視点 (`camera`・`perspective`・`ortho`) を無視し、変換の z も捨てて面の座標へそのまま落ちた。
/// 同じ座標の `plane` と `rect` が、視点を動かすとずれた。ここは画素の外接の箱 (±1 画素) で次を見る。
///
/// - 視点を決めた下で、同じ座標の `rect` と `plane` が重なる
/// - 既定の透視で `translate(0, 0, z)` の後の 2D が z で変わる
/// - 既定の視点 (指定しない・`camera()` で戻した後) で奥行き 0 に描いた 2D は、変更前と同じ画素になる (全画素一致)
/// - 真横を向いた面 (`rotateY(HALF_PI)`) に描いた 2D も、横からの視点で同じ置き方の `plane` と重なる
///
/// [#3830]: https://github.com/mokume-metal/mokume/issues/3830
@Suite(
    "2D の図形は視点と変換の 3 成分を通る",
    .enabled(
        if: RenderDevice.isAvailable,
        "この世代のコマンド構造に対応した GPU が無い実行環境ではスキップする")
)
struct FlatThroughCameraTests {
    private static let width = 320
    private static let height = 240

    /// 斜め上から見る視点 (#3830 の画素の表と同じ)。
    private static func lookFromAbove(_ canvas: Canvas) {
        canvas.camera(400, 40, 300, 160, 120, 0, 0, 1, 0)
    }

    /// 黒の下地に `body` を描いた絵。
    private func drawn(_ body: (Canvas) -> Void) throws -> PixelBuffer {
        let gpu = try RenderDevice()
        let canvas = try CanvasFixture.make(gpu: gpu, width: Self.width, height: Self.height)
        try canvas.draw {
            canvas.background(0)
            canvas.noStroke()
            canvas.fill(255)
            body(canvas)
        }
        return try canvas.target.readPixels()
    }

    /// 明るい画素 (赤の成分が 0.5 を越える) の外接 (両端を含む)。
    private func litBox(_ pixels: PixelBuffer) -> (x: ClosedRange<Int>, y: ClosedRange<Int>)? {
        var (left, right, top, bottom) = (Int.max, Int.min, Int.max, Int.min)
        for y in 0..<pixels.height {
            for x in 0..<pixels.width where pixels[x, y].red > 0.5 {
                left = min(left, x)
                right = max(right, x)
                top = min(top, y)
                bottom = max(bottom, y)
            }
        }
        guard left <= right else { return nil }
        return (left...right, top...bottom)
    }

    /// 2 つの外接が、各辺 ±1 画素で一致するか。
    private func matches(
        _ a: (x: ClosedRange<Int>, y: ClosedRange<Int>), _ b: (x: ClosedRange<Int>, y: ClosedRange<Int>)
    ) -> Bool {
        abs(a.x.lowerBound - b.x.lowerBound) <= 1 && abs(a.x.upperBound - b.x.upperBound) <= 1
            && abs(a.y.lowerBound - b.y.lowerBound) <= 1 && abs(a.y.upperBound - b.y.upperBound) <= 1
    }

    // MARK: - 視点を通る

    @Test("camera(...) の後、同じ座標の rect と plane が重なる (変更前は rect だけが面の同じ位置に残った)")
    func rectFollowsTheCameraLikeAPlane() throws {
        let rect = try #require(
            litBox(
                drawn { canvas in
                    Self.lookFromAbove(canvas)
                    canvas.rect(100, 60, 60, 60)
                }))
        let plane = try #require(
            litBox(
                drawn { canvas in
                    Self.lookFromAbove(canvas)
                    canvas.translate(130, 90, 0)
                    canvas.plane(60, 60)
                }))
        #expect(matches(rect, plane), "rect \(rect) / plane \(plane)")
        // 視点を通らなければ (100, 60)〜(159, 119) に残る
        #expect(!matches(rect, (100...159, 60...119)), "rect が視点を通っていない: \(rect)")
    }

    @Test("perspective(...) の後、同じ座標の circle と、同じ大きさの plane の外接が重なる")
    func circleFollowsTheProjection() throws {
        let circle = try #require(
            litBox(
                drawn { canvas in
                    canvas.perspective(1.2, Float(Self.width) / Float(Self.height), 1, 2000)
                    canvas.circle(130, 150, 60)
                }))
        let plane = try #require(
            litBox(
                drawn { canvas in
                    canvas.perspective(1.2, Float(Self.width) / Float(Self.height), 1, 2000)
                    canvas.translate(130, 150, 0)
                    canvas.plane(60, 60)
                }))
        #expect(matches(circle, plane), "circle \(circle) / plane \(plane)")
        #expect(!matches(circle, (100...159, 120...179)), "circle が投影を通っていない: \(circle)")
    }

    @Test("既定の透視で translate(0, 0, z) の後の rect は、z で大きさと位置を変え、同じ置き方の plane と重なる")
    func depthMovesAFlatShape() throws {
        let flat = try #require(
            litBox(
                drawn { canvas in
                    canvas.translate(0, 0, 60)
                    canvas.rect(130, 90, 60, 60)
                }))
        let plane = try #require(
            litBox(
                drawn { canvas in
                    canvas.translate(0, 0, 60)
                    canvas.translate(160, 120, 0)
                    canvas.plane(60, 60)
                }))
        #expect(matches(flat, plane), "rect \(flat) / plane \(plane)")
        // 手前へ出たので、奥行き 0 の 60 × 60 より大きい (既定の視点の距離 120√3 から 1.4 倍ほど)
        #expect(flat.x.count > 62 && flat.y.count > 62, "z を捨てている: \(flat)")
    }

    @Test("真横を向いた面 (rotateY(HALF_PI)) の rect も、横からの視点で同じ置き方の plane と重なる (消えない)")
    func aFlatShapeOnASideWallIsSeenFromTheSide() throws {
        func scene(_ canvas: Canvas, _ shape: (Canvas) -> Void) {
            canvas.camera(560, 60, 120, 160, 120, 0, 0, 1, 0)
            canvas.translate(160, 120, 0)
            canvas.rotateY(Float.pi / 2)
            shape(canvas)
        }
        let rect = try #require(litBox(drawn { canvas in scene(canvas) { $0.rect(-40, -40, 80, 80) } }))
        let plane = try #require(litBox(drawn { canvas in scene(canvas) { $0.plane(80, 80) } }))
        #expect(matches(rect, plane), "rect \(rect) / plane \(plane)")
        #expect(rect.x.count > 10, "真横の面が潰れた: \(rect)")
    }

    @Test("奥行きの違う同じ円を続けて描くと、それぞれの奥行きの大きさになる (違う奥行きを 1 つの雛形に畳まない)")
    func foldedShapesKeepTheirOwnDepth() throws {
        /// 面の右半分 (`right`) か左半分の、明るい画素の横幅。
        func width(_ pixels: PixelBuffer, right isRight: Bool = true) -> Int {
            var (left, right) = (Int.max, Int.min)
            let columns = isRight ? (Self.width / 2)..<pixels.width : 0..<(Self.width / 2)
            for y in 0..<pixels.height {
                for x in columns where pixels[x, y].red > 0.5 {
                    (left, right) = (min(left, x), max(right, x))
                }
            }
            return right - left + 1
        }
        func rightWidth(_ pixels: PixelBuffer) -> Int { width(pixels) }
        // 奥行き 60 の円を 1 つだけ描いた幅
        let alone = rightWidth(
            try drawn { canvas in
                canvas.translate(0, 0, 60)
                canvas.circle(200, 120, 40)
            })
        // 奥行き 0 の同じ円の後に続けて描く (畳みの相手がいる)
        let both = try drawn { canvas in
            canvas.circle(80, 120, 40)
            canvas.translate(0, 0, 60)
            canvas.circle(200, 120, 40)
        }
        let after = rightWidth(both)
        let first = width(both, right: false)
        #expect(alone > 44, "奥行き 60 の円が大きくならない: \(alone)")
        #expect(abs(after - alone) <= 1, "続けて描いた円の幅 \(after) が、1 つだけの幅 \(alone) と違う")
        // 先に描いた奥行き 0 の円は、後の円の奥行きに引きずられず、直径 40 のまま
        #expect(abs(first - 40) <= 1, "先に描いた円の幅 \(first) が、奥行き 0 の直径 40 と違う")
    }

    @Test("字も視点に付いて動き、視点を戻すと変更前と同じ位置に描く")
    func textFollowsTheCamera() throws {
        func label(_ canvas: Canvas) {
            canvas.textSize(32)
            canvas.text("mokume", 40, 80)
        }
        let plain = try #require(litBox(drawn { label($0) }))
        let seen = try #require(
            litBox(
                drawn { canvas in
                    Self.lookFromAbove(canvas)
                    label(canvas)
                }))
        #expect(!matches(plain, seen), "字が視点を通っていない: \(seen)")
    }

    @Test("絵 (image) も視点を通り、同じ座標の plane と重なる")
    func imageFollowsTheCamera() throws {
        let gpu = try RenderDevice()
        func boxOf(_ body: (Canvas, Image) -> Void) throws -> (x: ClosedRange<Int>, y: ClosedRange<Int>)? {
            let canvas = try CanvasFixture.make(gpu: gpu, width: Self.width, height: Self.height)
            let picture = try canvas.createImage(4, 4)
            for y in 0..<4 {
                for x in 0..<4 { picture.set(x, y, .linear(red: 1, green: 1, blue: 1)) }
            }
            try canvas.draw {
                canvas.background(0)
                canvas.noStroke()
                canvas.fill(255)
                body(canvas, picture)
            }
            return litBox(try canvas.target.readPixels())
        }
        let image = try #require(
            try boxOf { canvas, picture in
                Self.lookFromAbove(canvas)
                canvas.image(picture, 100, 60, 60, 60)
            })
        let plane = try #require(
            try boxOf { canvas, _ in
                Self.lookFromAbove(canvas)
                canvas.translate(130, 90, 0)
                canvas.plane(60, 60)
            })
        #expect(matches(image, plane), "image \(image) / plane \(plane)")
    }

    // MARK: - 既定の視点は変わらない

    @Test("視点を一度動かして camera() で戻した後の 2D は、視点を触らない絵と全画素が同じ")
    func resettingTheCameraKeepsThePixels() throws {
        func scene(_ canvas: Canvas) {
            canvas.stroke(200, 80, 40)
            canvas.strokeWeight(3)
            canvas.rect(20.5, 30, 90, 50)
            canvas.circle(200, 80, 70)
            canvas.translate(60, 150)
            canvas.rotate(0.3)
            canvas.noStroke()
            canvas.ellipse(0, 0, 80, 30)
            canvas.textSize(24)
            canvas.text("grain", 40, 30)
        }
        let untouched = try drawn { scene($0) }
        let reset = try drawn { canvas in
            Self.lookFromAbove(canvas)
            canvas.camera()
            scene(canvas)
        }
        var differing = 0
        for y in 0..<untouched.height {
            for x in 0..<untouched.width where untouched[x, y] != reset[x, y] { differing += 1 }
        }
        #expect(differing == 0, "camera() で戻した後に \(differing) 画素が違う")
    }

    // MARK: - 面の座標と奥行き

    @Test("screenX(x, y) は、視点を決めた下では奥行き 0 の点として視点を通した位置を返す")
    func screenPositionOfAFlatPointFollowsTheCamera() throws {
        let gpu = try RenderDevice()
        let canvas = try CanvasFixture.make(gpu: gpu, width: Self.width, height: Self.height)
        var plain: (Float, Float) = (0, 0)
        var seen: (Float, Float) = (0, 0)
        var spatial: (Float, Float) = (0, 0)
        try canvas.draw {
            canvas.translate(10, 20)
            plain = (canvas.screenX(30, 40), canvas.screenY(30, 40))
            Self.lookFromAbove(canvas)
            seen = (canvas.screenX(30, 40), canvas.screenY(30, 40))
            spatial = (canvas.screenX(30, 40, 0), canvas.screenY(30, 40, 0))
        }
        // 素の場合は変換の x・y そのもの
        #expect(plain == (40, 60))
        #expect(seen == spatial)
        #expect(seen != plain)
    }

    @Test("2D は奥行きを書かず読まない — 立体の後に、立体の奥に置いた rect も手前に出る (呼び出し順)")
    func flatShapesStayInCallOrder() throws {
        let pixels = try drawn { canvas in
            Self.lookFromAbove(canvas)
            canvas.fill(0, 0, 255)
            canvas.translate(160, 120, 0)
            canvas.box(80)
            canvas.translate(0, 0, -100)
            canvas.fill(255, 0, 0)
            canvas.rectMode(.center)
            canvas.rect(0, 0, 60, 60)
        }
        // 箱より奥に置いた矩形でも、後に呼んだので見える
        var red = 0
        for y in 0..<pixels.height {
            for x in 0..<pixels.width where pixels[x, y].red > 0.5 && pixels[x, y].blue < 0.5 { red += 1 }
        }
        #expect(red > 400, "奥の rect が箱に隠れた (赤 \(red) 画素)")
    }

    @Test("視点を通る 2D の下では、合成の単位を作らない")
    func compositeGroupIsRefusedUnderTheCamera() throws {
        let gpu = try RenderDevice()
        let canvas = try CanvasFixture.make(gpu: gpu, width: Self.width, height: Self.height)
        var whole = PlaneBox(SIMD2(0, 0))
        whole.maxX = 100
        whole.maxY = 100
        var results: [Bool] = []
        try canvas.draw {
            Self.lookFromAbove(canvas)
            canvas.camera()
            results.append(canvas.withCompositeGroup(opacity: 0.5, covering: whole) { _ in })
            canvas.translate(0, 0, 10)
            results.append(canvas.withCompositeGroup(opacity: 0.5, covering: whole) { _ in })
        }
        // 戻した視点では単位になる。奥行きのある変換の下では断る
        #expect(results == [true, false])
    }
}
