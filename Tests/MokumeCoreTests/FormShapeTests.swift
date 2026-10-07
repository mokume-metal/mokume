// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation
import Testing

@testable import MokumeCore

/// 平面の基本図形を 1 インスタンス = 1 クアッド + 距離関数で描く経路の検査 ([#752])。GPU を要する。
///
/// 見るものは 3 つ — **畳まれていること** (寸法違い・種別違いでも 1 列で、頂点も周も
/// 組み立てない)、**決定論** (同じ絵を 2 回描いて 1 ビットも違わない)、**縁だけが
/// 滑らかで位置と大きさは変わらないこと** ([ADR-0019] 決定 4: 中心は指定色と完全一致・
/// 1 画素外は背景・縁の上は中間値)。
///
/// [#752]: https://github.com/mokume-metal/mokume/issues/752
/// [ADR-0019]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0019-drawing-verification.md
@Suite(
    "平面の基本図形 (距離関数)",
    .enabled(
        if: RenderDevice.isAvailable,
        "この世代のコマンド構造に対応した GPU が無い実行環境ではスキップする")
)
struct FormShapeTests {
    private let black = LinearRGBA.linear(red: 0, green: 0, blue: 0)
    private let white = LinearRGBA.linear(red: 1, green: 1, blue: 1)
    private let red = LinearRGBA.linear(red: 1, green: 0, blue: 0)
    private let green = LinearRGBA.linear(red: 0, green: 1, blue: 0)
    private let blue = LinearRGBA.linear(red: 0, green: 0, blue: 1)

    private func makeCanvas(width: Int = 96, height: Int = 96) throws -> Canvas {
        try CanvasFixture.make(gpu: RenderDevice(), width: width, height: height)
    }

    /// 黒地に描いて、出力段を通した画素を返す。
    private func picture(_ canvas: Canvas, _ body: (Canvas) -> Void) throws -> DisplayImage {
        try canvas.draw {
            canvas.background(black)
            body(canvas)
        }
        return try canvas.target.encodeForDisplay()
    }

    /// 決定論的な擬似乱数 (検査の中で寸法と位置を散らすため)。
    private struct Scatter {
        var state: UInt32 = 0x9E37_79B9
        mutating func next(_ range: ClosedRange<Float>) -> Float {
            state = state &* 1_664_525 &+ 1_013_904_223
            let unit = Float(state >> 8) / Float(1 << 24)
            return range.lowerBound + unit * (range.upperBound - range.lowerBound)
        }
    }

    // MARK: - 畳まれている

    /// 寸法違いの図形を 4000 個。**種別ごとに 1 列で、頂点も周も 1 つも組み立てない。**
    @Test(
        "寸法違いの図形 4000 個が 1 列に畳まれ、頂点も周も組み立てない",
        arguments: ["rect", "circle", "line"])
    func variedSizesFoldIntoOneDrawCall(_ kind: String) throws {
        let canvas = try makeCanvas()
        var scatter = Scatter()
        _ = try picture(canvas) { canvas in
            canvas.fill(white)
            canvas.stroke(blue)
            for _ in 0..<4000 {
                let x = scatter.next(0...96), y = scatter.next(0...96)
                let size = scatter.next(1...30)
                switch kind {
                case "rect": canvas.rect(x, y, size, scatter.next(1...30))
                case "circle": canvas.circle(x, y, size)
                default: canvas.line(x, y, x + size, y + scatter.next(-30...30))
                }
            }
        }
        #expect(canvas.drawCallsInLastFrame == 1, "寸法が違うだけで列が分かれている")
        #expect(canvas.flatVerticesInLastFrame == 0, "基本図形が頂点を積んでいる")
        #expect(canvas.flatOutlinesInLastFrame == 0, "基本図形が周を組み立てている")
    }

    /// **塗りを持つ図形どうしなら、種別を混ぜても 1 列。**
    ///
    /// 断片は塗り / 輪郭の有無で特化してあるので、そこだけが列を切る ([#771])。寸法・
    /// 種別・色・変換はどれも列を切らない — #752 が狙ったのはここで、失っていない。
    ///
    /// [#771]: https://github.com/mokume-metal/mokume/issues/771
    @Test("寸法・種別・色・変換を混ぜても、1 列に収まる")
    func mixedKindsShareOneDrawCall() throws {
        let canvas = try makeCanvas()
        _ = try picture(canvas) { canvas in
            for index in 0..<60 {
                let step = Float(index)
                canvas.push()
                canvas.translate(10 + step * 1.3, 10 + step)
                canvas.rotate(step * 0.1)
                canvas.scale(1 + step * 0.01, 1)
                canvas.fill(.linear(red: step / 60, green: 0.5, blue: 1 - step / 60))
                canvas.stroke(.linear(red: 1, green: step / 60, blue: 0))
                canvas.strokeWeight(1 + step * 0.05)
                switch index % 3 {
                case 0: canvas.rect(0, 0, 6 + step * 0.1, 4)
                case 1: canvas.circle(0, 0, 5 + step * 0.1)
                default: canvas.arc(0, 0, 8, 6, 0.2, 2 + step * 0.02)
                }
                canvas.pop()
            }
        }
        #expect(canvas.drawCallsInLastFrame == 1, "種別か色か変換で列が分かれている")
        #expect(canvas.flatOutlinesInLastFrame == 0)
    }

    /// **塗りの有無が変わると列が切れる。** これは [#771] で受け入れた代償である。
    ///
    /// 断片は塗り / 輪郭の有無で特化してあり (`kFormHasFill` / `kFormHasStroke`)、組ごとに
    /// パイプラインが違う。線と点は塗りを持たないので、塗りを持つ図形と混ぜると列が切れる。
    /// **黙って切れる状態にしない**ために、切れることをここで名指しで見る。
    ///
    /// 1 列あたりの費用は口を束ね直して描く 20 呼び出しほどで、交互に 1 万回置くような
    /// 極端な形でだけ効く。#752 が狙った「寸法違いで畳めない」は戻らない。
    ///
    /// [#771]: https://github.com/mokume-metal/mokume/issues/771
    @Test("塗りの有無が変わると列が切れる")
    func fillPresenceSplitsTheRun() throws {
        let canvas = try makeCanvas()
        _ = try picture(canvas) { canvas in
            canvas.fill(white)
            canvas.stroke(blue)
            canvas.strokeWeight(1)
            // 塗りを持つ図形が続く間は 1 列
            canvas.rect(10, 10, 12, 12)
            canvas.circle(40, 16, 12)
            // 線は塗りを持たない — ここで列が切れる
            canvas.line(10, 40, 60, 40)
            canvas.point(70, 40)
            // 塗りが戻るのでもう一度切れる
            canvas.rect(10, 60, 12, 12)
        }
        #expect(canvas.drawCallsInLastFrame == 3, "塗りの有無で列が切れていない")
        #expect(canvas.flatOutlinesInLastFrame == 0)
    }

    @Test("上限で列が分かれても、絵は 1 ビットも変わらない")
    func splittingByCapacityKeepsThePicture() throws {
        func scene(_ canvas: Canvas) throws -> DisplayImage {
            try picture(canvas) { canvas in
                canvas.fill(white)
                canvas.stroke(blue)
                for index in 0..<12 {
                    canvas.circle(10 + Float(index % 4) * 24, 12 + Float(index / 4) * 30, 8 + Float(index))
                }
            }
        }
        let whole = try makeCanvas()
        let together = try scene(whole)
        #expect(whole.drawCallsInLastFrame == 1)

        let limited = try makeCanvas()
        limited.instanceCapacity = 3
        let split = try scene(limited)
        #expect(limited.drawCallsInLastFrame == 4, "上限で列が分かれていない")
        #expect(together.bytes == split.bytes, "列の分け方で絵が変わっている")
    }

    // MARK: - 決定論

    @Test("同じ絵を 2 回描くと、1 ビットも違わない")
    func theSamePictureTwice() throws {
        func scene(_ canvas: Canvas) throws -> DisplayImage {
            var scatter = Scatter()
            return try picture(canvas) { canvas in
                for index in 0..<300 {
                    canvas.push()
                    canvas.translate(scatter.next(0...96), scatter.next(0...96))
                    canvas.rotate(scatter.next(0...6))
                    canvas.fill(
                        LinearRGBA(
                            straightRed: scatter.next(0...1), green: scatter.next(0...1),
                            blue: scatter.next(0...1), alpha: scatter.next(0.2...1)))
                    canvas.stroke(.linear(red: 1, green: 1, blue: scatter.next(0...1)))
                    canvas.strokeWeight(scatter.next(0...6))
                    canvas.strokeCap([.round, .square, .project][index % 3])
                    canvas.strokeJoin([.miter, .bevel, .round][index % 3])
                    switch index % 5 {
                    case 0: canvas.rect(0, 0, scatter.next(1...20), scatter.next(1...20))
                    case 1: canvas.ellipse(0, 0, scatter.next(1...24), scatter.next(1...24))
                    case 2: canvas.arc(0, 0, 20, 14, scatter.next(0...3), scatter.next(3...7))
                    case 3: canvas.line(0, 0, scatter.next(-20...20), scatter.next(-20...20))
                    default: canvas.point(0, 0)
                    }
                    canvas.pop()
                }
            }
        }
        #expect(try scene(try makeCanvas()).bytes == (try scene(try makeCanvas())).bytes)
    }

    // MARK: - 縁だけが滑らかで、位置と大きさは変わらない

    @Test("円の縁は中間値で、中心は指定色・1 画素外は背景")
    func circleEdgesAreSmooth() throws {
        let canvas = try makeCanvas()
        let image = try picture(canvas) { canvas in
            canvas.noStroke()
            canvas.fill(white)
            // 中心は画素の角 (48, 48)、半径 29.5。画素 i の中心は i + 0.5 なので、軸の上の縁
            // (77.5 と 18.5) がちょうど画素 77 と 18 の中心を通り、そこが半分だけ覆われる
            // (整数の半径だと縁が画素の境目に乗り、軸の上に中間値が出ない)
            canvas.circle(48, 48, 59)
        }
        #expect(image[48, 48].red == 255)
        #expect(image[75, 48].red == 255, "縁の 2 画素内は塗り切られている")
        let edge = image[77, 48].red
        #expect(edge > 0 && edge < 255, "縁が滑らかになっていない: \(edge)")
        #expect(image[79, 48].red == 0, "縁の 2 画素外に塗りが漏れている")
        // 対称
        #expect(image[18, 48].red == edge)
        #expect(image[48, 18].red == edge)
        #expect(image[48, 77].red == edge)
    }

    @Test("整数の座標に置いた矩形は、三角形のときと同じ画素をちょうど塗る")
    func integerRectanglesStayCrisp() throws {
        // 塗りの縁は整数の座標で画素の境目に乗るので (ADR-0039 決定 2)、rect(10, 20, 4, 8) は
        // 4x8 画素ちょうどになる。縁が画素の中心を通ると、縁の 1 画素が半分だけ覆われて滲む
        let canvas = try makeCanvas()
        let image = try picture(canvas) { canvas in
            canvas.noStroke()
            canvas.fill(white)
            canvas.rect(10, 20, 4, 8)
        }
        for y in 20..<28 {
            for x in 10..<14 {
                #expect(image[x, y].red == 255, "(\(x), \(y)) が塗られていない")
            }
        }
        #expect(image[9, 24].red == 0)
        #expect(image[14, 24].red == 0)
        #expect(image[12, 19].red == 0)
        #expect(image[12, 28].red == 0)
    }

    @Test("拡大しても、整数に落ちる矩形の縁は画素の境目に乗る")
    func scaledRectanglesStayCrispToo() throws {
        // 倍率 2 でも、整数に落ちる縁は画素の境目に乗る (輪郭の寄せは画面の半画素で測るが、
        // 塗りは寄せない)
        let canvas = try makeCanvas()
        let image = try picture(canvas) { canvas in
            canvas.noStroke()
            canvas.fill(white)
            canvas.scale(2, 2)
            canvas.rect(10, 10, 4, 4)
        }
        for y in 20..<28 {
            for x in 20..<28 {
                #expect(image[x, y].red == 255, "(\(x), \(y)) が塗られていない")
            }
        }
        #expect(image[19, 24].red == 0)
        #expect(image[28, 24].red == 0)
    }

    @Test("輪郭の帯は線幅ちょうどで、塗りとの継ぎ目に隙間が無い")
    func strokeBandHasTheGivenWidth() throws {
        let canvas = try makeCanvas()
        let image = try picture(canvas) { canvas in
            canvas.fill(red)
            canvas.stroke(blue)
            canvas.strokeWeight(6)
            canvas.circle(48, 48, 40)
        }
        // 半径 20・線幅 6 なので、帯は半径 17…23
        #expect(image[48 + 20, 48].blue == 255)
        #expect(image[48 + 18, 48].blue == 255)
        #expect(image[48 + 22, 48].blue == 255)
        #expect(image[48 + 15, 48].red == 255, "帯の内側は塗り")
        #expect(image[48 + 15, 48].blue == 0)
        #expect(image[48 + 25, 48].red == 0, "帯の外は背景")
        #expect(image[48 + 25, 48].blue == 0)
        // 継ぎ目 (半径 16…18) を含め、帯の外縁の手前までどの画素も塗りか輪郭で覆われている
        for x in (48 + 15)...(48 + 22) {
            let pixel = image[x, 48]
            #expect(Int(pixel.red) + Int(pixel.blue) >= 250, "(\(x), 48) に隙間がある: \(pixel)")
        }
    }

    @Test("置き換える混ぜ方でも、塗りと輪郭の継ぎ目に透けた筋が出ない")
    func replaceModeHasNoSeamBetweenFillAndStroke() throws {
        let canvas = try makeCanvas()
        let image = try picture(canvas) { canvas in
            canvas.blendMode(.replace)
            canvas.fill(red)
            canvas.stroke(blue)
            canvas.strokeWeight(5)
            canvas.rect(20, 20, 50, 50)
        }
        for x in 20...70 {
            #expect(image[x, 45].alpha == 255, "(\(x), 45) が透けている: \(image[x, 45])")
        }
    }

    /// 置き換える混ぜ方で、塗りと輪郭を両方持つ形を 1 回で描いた絵は、**部品の単位で置き
    /// 換えた絵**になる — 輪郭の帯では輪郭だけが残り、下の塗りは透けない ([#1819])。
    ///
    /// 比べる相手は 2 つ。三角形の経路 (`shader()` を付ける。塗りの三角形の上に輪郭の
    /// 三角形を置き、置き換えるので帯には輪郭だけが残る) と、塗りだけの形 → 輪郭だけの形
    /// の順に分けて描いた絵である。根の約束 ([#1867] 決定 1) は、1 画素を塗りだけ `f − o`・
    /// 重なり `o`・帯だけ `s − o`・どちらでもない所の 4 つの面積に分け、それぞれを混ぜた色を
    /// 面積で足す。置き換えで解くと重なりには輪郭だけが入るので、置く色は `S·s + F·(f − o)`
    /// になる。かつては重なりに「輪郭 over 塗り」を入れていた (`S·s + F·(f − α·o)`) ので、
    /// 半透明の輪郭の帯の内側半分に塗りが透け、透明な地では α が 1.0 まで埋まっていた。
    ///
    /// 比べるのは**帯に丸ごと入る画素だけ**で、縁は比べない (縁の中間値は経路の間で違って
    /// よい・ADR-0039 決定 1)。帯に丸ごと入るかは、同じ形の輪郭だけを不透明な白で描いた
    /// 被覆率がちょうど 1 かで決める。不透明な輪郭 (255) では 2 つの式が同じになり、
    /// 絵は動かない。輪郭の不透明度 0 では、帯は透明に抜ける。
    ///
    /// **楕円も 1 画素も外さない** ([#1820])。かつては、塗りと先に重ねる列が楕円の輪郭を塗りの
    /// 距離場から 1 次の近似でずらして作るので、帯の内縁の 8 画素 (84×26) が不透明な輪郭でも
    /// 三角形の経路と違い、数が増えないことだけを見ていた。内縁の曲率半径が小さい楕円は式を
    /// 輪郭の位置で解き直すようにした後は、その 8 画素も他の形と同じに揃う。
    ///
    /// [#1819]: https://github.com/mokume-metal/mokume/issues/1819
    /// [#1820]: https://github.com/mokume-metal/mokume/issues/1820
    /// [#1867]: https://github.com/mokume-metal/mokume/issues/1867
    @Test(
        "置き換える混ぜ方で、塗りと輪郭を 1 回で描いた絵の帯は、三角形の経路・分けて描いた絵と同じく輪郭だけが残る",
        arguments: [Float(255), 128, 0], [true, false])
    func replaceModeKeepsOnlyTheStrokeInTheBand(_ strokeAlpha: Float, _ transparentGround: Bool) throws {
        let shapes: [(name: String, weight: Float, draw: (Canvas) -> Void)] = [
            // #1819 の場面 (画素 (26, 48) が帯の内側半分に入る)
            ("rect (#1819)", 12, { $0.rect(24, 24, 48, 48) }),
            ("rect", 7, { $0.rect(20.3, 18.6, 52, 46) }),
            ("circle", 7, { $0.circle(48.4, 47.7, 58) }),
            ("ellipse", 7, { $0.ellipse(48.3, 47.6, 84, 26) }),
            ("arc", 7, { $0.arc(48.2, 48.6, 64, 64, 0.4, 4.1) }),
        ]
        let ground = transparentGround
            ? LinearRGBA(straightRed: 0, green: 0, blue: 0, alpha: 0) : black
        let fillColor = blue
        func strokeColor(_ alpha: Float) -> LinearRGBA {
            .display(red: 1, green: 0, blue: 0, alpha: alpha / 255)
        }
        enum Route { case once, triangles, split }
        for shape in shapes {
            func render(_ route: Route, strokeAlpha: Float) throws -> PixelBuffer {
                let canvas = try makeCanvas()
                var failure: (any Error)?
                try canvas.draw {
                    canvas.background(ground)
                    canvas.blendMode(.replace)
                    canvas.strokeWeight(shape.weight)
                    switch route {
                    case .once:
                        canvas.fill(fillColor)
                        canvas.stroke(strokeColor(strokeAlpha))
                        shape.draw(canvas)
                    case .triangles:
                        do {
                            canvas.shader(try canvas.makeShader(
                                "float4 paint(Fragment in, Values values) { return in.color; }"))
                        } catch { failure = error }
                        canvas.fill(fillColor)
                        canvas.stroke(strokeColor(strokeAlpha))
                        shape.draw(canvas)
                    case .split:
                        canvas.fill(fillColor)
                        canvas.noStroke()
                        shape.draw(canvas)
                        canvas.noFill()
                        canvas.stroke(strokeColor(strokeAlpha))
                        shape.draw(canvas)
                    }
                }
                if let failure { throw failure }
                return try canvas.target.readPixels()
            }
            func gap(_ p: LinearRGBA, _ q: LinearRGBA) -> Float {
                max(abs(p.red - q.red), abs(p.green - q.green), abs(p.blue - q.blue), abs(p.alpha - q.alpha))
            }
            // 帯に丸ごと入る画素: 輪郭だけを不透明な白で重ねた被覆率がちょうど 1
            let band: PixelBuffer = try {
                let canvas = try makeCanvas()
                try canvas.draw {
                    canvas.background(black)
                    canvas.noFill()
                    canvas.stroke(white)
                    canvas.strokeWeight(shape.weight)
                    shape.draw(canvas)
                }
                return try canvas.target.readPixels()
            }()
            let inBand = (0..<band.height).flatMap { y in
                (0..<band.width).compactMap { x in band[x, y].red >= 1 ? (x, y) : nil }
            }
            #expect(inBand.count > 100, "\(shape.name): 帯に丸ごと入る画素が少ない (\(inBand.count))")
            let once = try render(.once, strokeAlpha: strokeAlpha)
            for (other, label) in [
                (try render(.triangles, strokeAlpha: strokeAlpha), "三角形の経路"),
                (try render(.split, strokeAlpha: strokeAlpha), "分けて描いた絵"),
            ] {
                var differing = 0
                var worst = (gap: Float(0), x: 0, y: 0)
                for (x, y) in inBand {
                    let g = gap(once[x, y], other[x, y])
                    if g > 1.0 / 255 { differing += 1 }
                    if g > worst.gap { worst = (g, x, y) }
                }
                #expect(
                    differing == 0,
                    "\(shape.name)・輪郭の不透明度 \(Int(strokeAlpha))・\(transparentGround ? "透明" : "黒") の地: \(label)と \(differing) / \(inBand.count) 画素違う (最大 \(worst.gap) @ (\(worst.x), \(worst.y)))")
            }
            if shape.name == "rect (#1819)" {
                // 帯の内側半分 (26, 48) は輪郭の不透明度のまま。塗りの青は透けない
                let inner = once[26, 48]
                #expect(abs(inner.alpha - strokeAlpha / 255) <= 1.0 / 255, "(26, 48) の α: \(inner.alpha)")
                #expect(
                    inner.blue <= strokeColor(strokeAlpha).blue + 1.0 / 255,
                    "(26, 48) に塗りが透けている: \(inner)")
            }
        }
    }

    /// 縁の画素の重みを見る、輪郭つきの矩形。太さ 12 は #1819 の場面 (画素 (26, 48) が帯の
    /// 内側半分に入る)。太さ 1 の帯は、塗りの縁の外側に接して重ならない辺と、塗りの中に入る
    /// 辺を持つ。
    private static let edgeRects: [(name: String, x: Float, y: Float, width: Float, height: Float, weight: Float)] = [
        ("rect 太さ 12", 24, 24, 48, 48, 12),
        ("rect 小数", 20.3, 18.6, 52, 46, 7),
        ("rect 太さ 1", 20.3, 18.6, 52, 46, 1),
    ]

    /// 輪郭つきの矩形の 1 画素を、4 つの面積に分けるための被覆率 ([#1867] 決定 1)。
    ///
    /// どれも同じ機械が不透明な白で黒地に描いた形の赤から読む。塗り `f` は形そのもの、帯の
    /// 外縁・内縁は、輪郭を寄せる約束 (ADR-0039 決定 2・画面で +0.5) のとおり半画素ずらして
    /// 太さの半分だけ太らせた・痩せさせた `rect` の塗りである。帯 `s` は外縁 − 内縁 (輪郭
    /// だけの形とも比べる)、重なり `o` は縁が画素の幅では平行とみなした見積もり
    /// `min(f, 外縁) − min(f, 内縁)`。太さ 1 の帯は塗りの縁の外側に接して重ならない辺と、
    /// 塗りの中に入る辺を持つので、`min(f, s)` では見積もれない。
    ///
    /// [#1867]: https://github.com/mokume-metal/mokume/issues/1867
    private struct RectAreas {
        let fills: PixelBuffer
        let outers: PixelBuffer
        let inners: PixelBuffer
        /// 輪郭だけの形 (外縁 − 内縁と比べる)
        let strokes: PixelBuffer

        /// 画素 (x, y) の塗り `f`・帯 `s`・重なり `o`
        func at(_ x: Int, _ y: Int) -> (f: Float, s: Float, o: Float) {
            let (f, outer, inner) = (fills[x, y].red, outers[x, y].red, inners[x, y].red)
            return (f, max(0, outer - inner), max(0, min(f, outer) - min(f, inner)))
        }

        /// 縁の画素 (塗りか帯の被覆率が 0 と 1 の間) の数
        var edgeCount: Int {
            var count = 0
            for y in 0..<fills.height {
                for x in 0..<fills.width {
                    let (f, s, _) = at(x, y)
                    if (f > 0 && f < 1) || (s > 0 && s < 1) { count += 1 }
                }
            }
            return count
        }

        /// 外縁 − 内縁が、輪郭だけの形と 1/255 を越えて違う画素の数
        var bandMismatchCount: Int {
            var count = 0
            for y in 0..<fills.height {
                for x in 0..<fills.width where abs(at(x, y).s - strokes[x, y].red) > 1.0 / 255 {
                    count += 1
                }
            }
            return count
        }
    }

    private func rectAreas(
        _ rect: (name: String, x: Float, y: Float, width: Float, height: Float, weight: Float)
    ) throws -> RectAreas {
        func coverage(_ body: (Canvas) -> Void) throws -> PixelBuffer {
            let canvas = try makeCanvas()
            try canvas.draw {
                canvas.background(black)
                body(canvas)
            }
            return try canvas.target.readPixels()
        }
        func filled(grow: Float, shift: Float) throws -> PixelBuffer {
            try coverage { canvas in
                canvas.fill(white)
                canvas.noStroke()
                canvas.rect(
                    rect.x - grow + shift, rect.y - grow + shift,
                    rect.width + 2 * grow, rect.height + 2 * grow)
            }
        }
        let half = rect.weight / 2
        return RectAreas(
            fills: try filled(grow: 0, shift: 0),
            outers: try filled(grow: half, shift: 0.5),
            inners: try filled(grow: -half, shift: 0.5),
            strokes: try coverage { canvas in
                canvas.noFill()
                canvas.stroke(white)
                canvas.strokeWeight(rect.weight)
                canvas.rect(rect.x, rect.y, rect.width, rect.height)
            })
    }

    /// 置き換える混ぜ方の 1 画素は、**縁の画素も** 4 つの面積の和になる ([#1819]・[#1867] 決定 1)。
    ///
    /// 帯に丸ごと入る画素だけを見る検査 (上) では、縁の重みが決まらない — 「帯に丸ごと入る
    /// ときだけ重なりを輪郭だけにする」誤りでも緑になる。そこで面全体の画素を、置き換えで
    /// 解いた式 `S·s + F·(f − o)` と比べる。形の外 (どちらでもない面積) は置き換えで透明に
    /// なるので、透明な地に描いて 0 と比べる。被覆率は `RectAreas`。
    ///
    /// 塗りが半透明のとき、輪郭が不透明なとき、**不透明な輪郭で記録した形を半透明の色で置く**
    /// とき (置き場所の色は輪郭の不透明度にも掛かる・`FormInstance.placed(by:tint:)`) も回す。
    ///
    /// [#1819]: https://github.com/mokume-metal/mokume/issues/1819
    /// [#1867]: https://github.com/mokume-metal/mokume/issues/1867
    @Test(
        "置き換える混ぜ方で、塗りと輪郭を 1 回で描いた絵の縁の画素は、面積で置き換えた色になる",
        arguments: ["半透明の輪郭", "半透明の塗りと輪郭", "半透明の塗りと不透明な輪郭", "記録した形を半透明の色で置く"])
    func replaceModeWeighsEdgePixelsByArea(_ variant: String) throws {
        let fillAlpha: Float = variant.hasPrefix("半透明の塗り") ? 0.6 : 1
        let strokeAlpha: Float = variant == "半透明の塗りと不透明な輪郭" || variant.hasPrefix("記録") ? 1 : 0.5
        let fillColor = LinearRGBA.display(red: 0.2, green: 0.35, blue: 0.8, alpha: fillAlpha)
        let strokeColor = LinearRGBA.display(red: 0.75, green: 0.3, blue: 0.15, alpha: strokeAlpha)
        // 置き場所の色 (乗算済みの成分ごとに掛かる)。記録した形を置くときだけ
        let tint = variant.hasPrefix("記録")
            ? LinearRGBA(premultipliedRed: 0.5, green: 0.5, blue: 0.5, alpha: 0.5) : nil
        func placed(_ color: LinearRGBA) -> LinearRGBA {
            guard let tint else { return color }
            return LinearRGBA(
                premultipliedRed: color.red * tint.red, green: color.green * tint.green,
                blue: color.blue * tint.blue, alpha: color.alpha * tint.alpha)
        }
        let (fillPlaced, strokePlaced) = (placed(fillColor), placed(strokeColor))
        for rect in Self.edgeRects {
            let areas = try rectAreas(rect)
            let canvas = try makeCanvas()
            var recorded = Shape.empty
            func draw() {
                canvas.blendMode(.replace)
                canvas.strokeWeight(rect.weight)
                canvas.fill(fillColor)
                canvas.stroke(strokeColor)
                canvas.rect(rect.x, rect.y, rect.width, rect.height)
            }
            if tint != nil { try canvas.draw { recorded = canvas.createShape { draw() } } }
            try canvas.draw {
                canvas.background(LinearRGBA(straightRed: 0, green: 0, blue: 0, alpha: 0))
                if let tint {
                    canvas.blendMode(.replace)
                    canvas.shape(recorded, at: [Placement(fill: tint)])
                } else {
                    draw()
                }
            }
            let once = try canvas.target.readPixels()
            var differing = 0
            var worst = (gap: Float(0), x: 0, y: 0, f: Float(0), s: Float(0))
            for y in 0..<once.height {
                for x in 0..<once.width {
                    let (f, s, o) = areas.at(x, y)
                    let expected = [
                        strokePlaced.red * s + fillPlaced.red * (f - o),
                        strokePlaced.green * s + fillPlaced.green * (f - o),
                        strokePlaced.blue * s + fillPlaced.blue * (f - o),
                        strokePlaced.alpha * s + fillPlaced.alpha * (f - o),
                    ]
                    let actual = once[x, y]
                    let gap = max(
                        abs(actual.red - expected[0]), abs(actual.green - expected[1]),
                        abs(actual.blue - expected[2]), abs(actual.alpha - expected[3]))
                    if gap > 1.0 / 255 { differing += 1 }
                    if gap > worst.gap { worst = (gap, x, y, f, s) }
                }
            }
            #expect(areas.edgeCount > 100, "\(rect.name): 縁の画素が少ない (\(areas.edgeCount))")
            #expect(
                areas.bandMismatchCount == 0,
                "\(rect.name): 外縁 − 内縁が輪郭だけの形と \(areas.bandMismatchCount) 画素違う")
            #expect(
                differing == 0,
                "\(variant)・\(rect.name): \(differing) 画素が面積で置き換えた色と違う (最大 \(worst.gap) @ (\(worst.x), \(worst.y))・f \(worst.f)・s \(worst.s))")
        }
    }

    /// 重ねる混ぜ方と下地を読む混ぜ方の 1 画素も、**縁と継ぎ目の画素まで** 4 つの面積の和に
    /// なる ([#1818]・[#1867] 決定 1)。
    ///
    /// 画素を塗りだけ `f − o`・重なり `o`・帯だけ `s − o`・どちらでもない `1 − (f + s − o)` に
    /// 分け、それぞれに丸ごと入っていたら出す色 (塗りだけ・重なり・帯だけ・地) を面積で足した
    /// 色と、面全体の画素を 1/255 以内で比べる。3 つの色は、太い輪郭の矩形を塗り → 輪郭の
    /// 順に分けて描いた絵の、それぞれに丸ごと入る画素から読む (混ぜ方の式を写さない)。
    /// 被覆率は `RectAreas`。
    ///
    /// - 重ねる混ぜ方は、継ぎ目の割り戻し (塗りの被覆率を「輪郭 over 塗り」の重みで割り戻す)
    ///   が、この読みを over で解いた式と項ごとに一致する。式を変えずに通る
    /// - 線形でない 6 つは、塗りと輪郭を別々に下地と混ぜていた頃は、継ぎ目と、帯の下の塗りの
    ///   縁で外れた (`.lightest` の太さ 1 で継ぎ目の地が最悪 24% 透けた)
    /// - 加算と減算は、不透明な地では別々に混ぜても同じ色になる。透けた地では、別々に混ぜると
    ///   塗りと帯を画素の中で無関係に散らばったものとして重ねるので、継ぎ目の不透明度が外れた
    ///
    /// [#1818]: https://github.com/mokume-metal/mokume/issues/1818
    /// [#1867]: https://github.com/mokume-metal/mokume/issues/1867
    @Test(
        "重ねる・下地を読む混ぜ方で、塗りと輪郭を 1 回で描いた絵の縁の画素は、4 つの面積に分けて混ぜた色になる",
        arguments: [
            BlendMode.blend, .add, .subtract, .lightest, .darkest,
            .difference, .exclusion, .multiply, .screen,
        ],
        ["不透明な地", "透明な地", "半透明の輪郭", "半透明の塗り"])
    func compositeModesWeighEdgePixelsByArea(_ mode: BlendMode, _ variant: String) throws {
        let fillColor = LinearRGBA.display(
            red: 0.2, green: 0.35, blue: 0.8, alpha: variant == "半透明の塗り" ? 0.6 : 1)
        let strokeColor = LinearRGBA.display(
            red: 0.75, green: 0.3, blue: 0.15, alpha: variant == "半透明の輪郭" ? 0.5 : 1)
        let ground = variant == "透明な地"
            ? LinearRGBA(straightRed: 0, green: 0, blue: 0, alpha: 0)
            : LinearRGBA.display(red: 0.3, green: 0.4, blue: 0.5)
        // 塗りだけ・重なり・帯だけ・どちらでもない所に丸ごと入る画素の色。帯は x = 8.5〜24.5、
        // 塗りは x = 16〜80
        let whole: (fill: LinearRGBA, both: LinearRGBA, stroke: LinearRGBA, ground: LinearRGBA) = try {
            let canvas = try makeCanvas()
            try canvas.draw {
                canvas.background(ground)
                canvas.blendMode(mode)
                canvas.strokeWeight(16)
                canvas.fill(fillColor)
                canvas.noStroke()
                canvas.rect(16, 16, 64, 64)
                canvas.noFill()
                canvas.stroke(strokeColor)
                canvas.rect(16, 16, 64, 64)
            }
            let pixels = try canvas.target.readPixels()
            return (pixels[48, 48], pixels[20, 48], pixels[12, 48], pixels[2, 2])
        }()
        func components(_ color: LinearRGBA) -> SIMD4<Float> {
            SIMD4(color.red, color.green, color.blue, color.alpha)
        }
        for rect in Self.edgeRects {
            let areas = try rectAreas(rect)
            let canvas = try makeCanvas()
            try canvas.draw {
                canvas.background(ground)
                canvas.blendMode(mode)
                canvas.strokeWeight(rect.weight)
                canvas.fill(fillColor)
                canvas.stroke(strokeColor)
                canvas.rect(rect.x, rect.y, rect.width, rect.height)
            }
            let once = try canvas.target.readPixels()
            var differing = 0
            var worst = (gap: Float(0), x: 0, y: 0, f: Float(0), s: Float(0))
            for y in 0..<once.height {
                for x in 0..<once.width {
                    let (f, s, o) = areas.at(x, y)
                    var expected = components(whole.ground) * max(0, 1 - (f + s - o))
                    expected += components(whole.fill) * (f - o)
                    expected += components(whole.both) * o
                    expected += components(whole.stroke) * (s - o)
                    let difference = components(once[x, y]) - expected
                    let gap = max(abs(difference.x), abs(difference.y), abs(difference.z), abs(difference.w))
                    if gap > 1.0 / 255 { differing += 1 }
                    if gap > worst.gap { worst = (gap, x, y, f, s) }
                }
            }
            #expect(areas.edgeCount > 100, "\(rect.name): 縁の画素が少ない (\(areas.edgeCount))")
            #expect(
                areas.bandMismatchCount == 0,
                "\(rect.name): 外縁 − 内縁が輪郭だけの形と \(areas.bandMismatchCount) 画素違う")
            #expect(
                differing == 0,
                "\(mode)・\(variant)・\(rect.name): \(differing) 画素が 4 つの面積に分けて混ぜた色と違う (最大 \(worst.gap) @ (\(worst.x), \(worst.y))・f \(worst.f)・s \(worst.s))")
        }
    }

    /// 下地を読む混ぜ方で、塗りと輪郭を両方持つ形を 1 回で描いた絵は、**塗りだけ・重なり・
    /// 帯だけのどれかに丸ごと入る画素では**、塗りだけの形の上に輪郭だけの形を重ねた絵と
    /// 同じになる ([#1643])。加算と減算は被覆率について線形なので、縁と継ぎ目も含めて
    /// どの画素でも同じになる。
    ///
    /// 線形でない 6 つの縁と継ぎ目の画素は、4 つの面積に分けて混ぜた色になり、分けて重ねた
    /// 絵とは違ってよい (ADR-0039 決定 5・[#1818])。その重みは
    /// `compositeModesWeighEdgePixelsByArea` が見る。丸ごと入るかは、同じ形の塗りだけと
    /// 輪郭だけを不透明な白で描いた被覆率が、どちらも 0 か 1 かで決める。
    ///
    /// 継ぎ目の漏れを塞ぐ割り戻し (ADR-0039 決定 5 の重ねる列) は「輪郭を塗りの上に重ねる」
    /// 前提の式なので、ここへ持ち込むと不透明な輪郭の帯の内側半分で塗りが消えていた (加算で
    /// 帯の内側の青が 0.33 → 0.006)。輪郭の不透明度 254 と 255 の間で絵が不連続に変わって
    /// いたので、その両側も回す。楕円 (円を含む) の輪郭を塗りの距離場から 1 次の近似でずらすと
    /// 内縁に誤差が残るので、細長い楕円も回す (近似のままだと、半径 29 の円でも加算で 1/255 を
    /// 越えた)。下地を読む断片は近似を使わず、いつも輪郭の位置で解き直す。重ねる・置き換える
    /// 列の楕円が近似を使ってよいかは `ellipseStrokeDoesNotDependOnTheFill` が見る ([#1820])。
    /// 比べる相手も同じ機械で描くので、成分の差は表示の 1 段 (1/255) より小さい。
    ///
    /// [#1643]: https://github.com/mokume-metal/mokume/issues/1643
    /// [#1818]: https://github.com/mokume-metal/mokume/issues/1818
    /// [#1820]: https://github.com/mokume-metal/mokume/issues/1820
    @Test(
        "下地を読む混ぜ方でも、塗りと輪郭を 1 回で描いた絵は、丸ごと覆われた画素で分けて重ねた絵と同じ",
        arguments: [
            BlendMode.add, .subtract, .lightest, .darkest,
            .difference, .exclusion, .multiply, .screen,
        ],
        [Float(255), 254, 128])
    func compositeModesDrawFillAndStrokeLikeTwoShapes(_ mode: BlendMode, _ strokeAlpha: Float) throws {
        let shapes: [(name: String, draw: (Canvas) -> Void)] = [
            ("rect", { $0.rect(20.3, 18.6, 52, 46) }),
            ("circle", { $0.circle(48.4, 47.7, 58) }),
            ("ellipse", { $0.ellipse(48.3, 47.6, 84, 26) }),
            ("arc", { $0.arc(48.2, 48.6, 64, 64, 0.4, 4.1) }),
        ]
        let fillColor = LinearRGBA.display(red: 0.2, green: 0.35, blue: 0.8)
        let strokeColor = LinearRGBA.display(red: 0.75, green: 0.3, blue: 0.15, alpha: strokeAlpha / 255)
        // 縁と継ぎ目も比べるのは、被覆率について線形な 2 つだけ
        let comparesEdges = mode == .add || mode == .subtract
        for shape in shapes {
            func render(split: Bool) throws -> PixelBuffer {
                let canvas = try makeCanvas()
                try canvas.draw {
                    canvas.background(.display(red: 0.3, green: 0.4, blue: 0.5))
                    canvas.blendMode(mode)
                    canvas.strokeWeight(7)
                    if split {
                        canvas.fill(fillColor)
                        canvas.noStroke()
                        shape.draw(canvas)
                        canvas.noFill()
                        canvas.stroke(strokeColor)
                        shape.draw(canvas)
                    } else {
                        canvas.fill(fillColor)
                        canvas.stroke(strokeColor)
                        shape.draw(canvas)
                    }
                }
                return try canvas.target.readPixels()
            }
            /// 塗りだけ・輪郭だけを不透明な白で黒地に描いた被覆率 (赤)
            func coverage(fills: Bool) throws -> PixelBuffer {
                let canvas = try makeCanvas()
                try canvas.draw {
                    canvas.background(black)
                    canvas.strokeWeight(7)
                    if fills {
                        canvas.fill(white)
                        canvas.noStroke()
                    } else {
                        canvas.noFill()
                        canvas.stroke(white)
                    }
                    shape.draw(canvas)
                }
                return try canvas.target.readPixels()
            }
            let (fills, strokes) = (try coverage(fills: true), try coverage(fills: false))
            let once = try render(split: false)
            let split = try render(split: true)
            var differing = 0
            var inBand = 0
            var worst = (gap: Float(0), x: 0, y: 0)
            for y in 0..<once.height {
                for x in 0..<once.width {
                    let (f, s) = (fills[x, y].red, strokes[x, y].red)
                    let whole = (f == 0 || f == 1) && (s == 0 || s == 1)
                    guard comparesEdges || whole else { continue }
                    if s == 1 { inBand += 1 }
                    let (p, q) = (once[x, y], split[x, y])
                    let gap = max(
                        abs(p.red - q.red), abs(p.green - q.green),
                        abs(p.blue - q.blue), abs(p.alpha - q.alpha))
                    if gap > 1.0 / 255 { differing += 1 }
                    if gap > worst.gap { worst = (gap, x, y) }
                }
            }
            #expect(inBand > 100, "\(mode)・\(shape.name): 帯に丸ごと入る画素が少ない (\(inBand))")
            #expect(
                differing == 0,
                "\(mode)・\(shape.name)・輪郭の不透明度 \(Int(strokeAlpha)): \(differing) 画素違う (最大 \(worst.gap) @ (\(worst.x), \(worst.y)))")
        }
    }

    /// 楕円の輪郭の被覆率を比べる置き方 (向き・拡大・剪断・細かさ)。ずらしの向きと、描く画素
    /// 1 つが形自身の座標でいくらかが変わる。鏡映 (`scale` の符号が負) は行列式が負になる。
    private struct RingPlacement {
        var angle: Float = 0
        var scale: SIMD2<Float> = [1, 1]
        var shear: Float = 0
        var density: Float = 1

        /// 拡大・剪断が無い (大きな絵でも収まる)
        var isPlain: Bool { scale == [1, 1] && shear == 0 }

        var label: String {
            "\(angle) rad・拡大 \(scale)・剪断 \(shear)・細かさ \(density)"
        }
    }

    /// 塗りを足した絵と輪郭だけの絵の、輪郭の被覆率 (赤) の食い違い。
    private struct RingGap {
        /// 輪郭だけの絵で、縁 (0 < 被覆率 < 1) の画素の数
        var edges = 0
        /// 差が 1/255 を越える画素の数
        var differing = 0
        var worst = (gap: Float(0), x: 0, y: 0, strokeOnly: Float(0), both: Float(0))
    }

    /// 置き方が収まる一辺 (出す画素)。
    private func ringReach(width: Float, height: Float, weight: Float, _ placement: RingPlacement) -> Float {
        (max(width, height) + weight) * max(abs(placement.scale.x), abs(placement.scale.y))
            * (1 + abs(tan(placement.shear)))
    }

    /// 黒の塗りと白の輪郭を黒地に置くと、赤の成分がそのまま輪郭の被覆率になる (塗りは黒なので
    /// 赤に何も足さず、輪郭の白に被覆率を掛けた量だけが残る。重ねる列でも置き換える列でも
    /// 同じ)。塗りを足した絵と、塗りを外した同じ形の絵で、その赤を比べる。
    /// `asArc` は、楕円を一周の `arc` で描く。
    private func ringGap(
        _ mode: BlendMode, width: Float, height: Float, weight: Float,
        _ placement: RingPlacement, asArc: Bool = false
    ) throws -> RingGap {
        let side = (Int(ringReach(width: width, height: height, weight: weight, placement)) + 41) / 2 * 2
        func render(fills: Bool) throws -> PixelBuffer {
            let canvas: Canvas
            if placement.density == 1 {
                canvas = try makeCanvas(width: side, height: side)
            } else {
                let gpu = try RenderDevice()
                let output = try RenderTarget(gpu: gpu, width: side, height: side)
                canvas = try Canvas(
                    output: output, gpu: gpu, pixelDensity: placement.density, upscale: .spatial)
            }
            try canvas.draw {
                canvas.background(black)
                canvas.blendMode(mode)
                canvas.strokeWeight(weight)
                canvas.stroke(white)
                if fills { canvas.fill(black) } else { canvas.noFill() }
                canvas.translate(Float(side) / 2 + 0.3, Float(side) / 2 + 0.6)
                canvas.rotate(placement.angle)
                canvas.shearX(placement.shear)
                canvas.scale(placement.scale.x, placement.scale.y)
                if asArc {
                    canvas.arc(0, 0, width, height, 0, 2 * Float.pi)
                } else {
                    canvas.ellipse(0, 0, width, height)
                }
            }
            return try canvas.target.readPixels()
        }
        let strokeOnly = try render(fills: false)
        let both = try render(fills: true)
        var gap = RingGap()
        // 画素ごとに色を組み立てると、大きな絵で遅い。赤だけを成分から読む
        for index in stride(from: 0, to: strokeOnly.components.count, by: 4) {
            let (alone, together) = (Float(strokeOnly.components[index]), Float(both.components[index]))
            if alone > 0 && alone < 1 { gap.edges += 1 }
            let difference = abs(together - alone)
            if difference > 1.0 / 255 { gap.differing += 1 }
            if difference > gap.worst.gap {
                let pixel = index / 4
                gap.worst = (difference, pixel % strokeOnly.width, pixel / strokeOnly.width, alone, together)
            }
        }
        return gap
    }

    /// 塗りと輪郭を両方持つ楕円の輪郭は、塗りの有無・混ぜ方によらず、輪郭だけの楕円と同じ
    /// 形になる ([#1820]・[#1867] 決定 2)。
    ///
    /// 重ねる (`.blend`)・置き換える (`.replace`) 列は塗りと輪郭を先に重ねる断片で、楕円の
    /// 輪郭の距離場を塗りの距離場から 1 次の近似でずらして作れる (`mokume_shifted`)。誤差は
    /// **内縁の曲率半径** (短半径² / 長半径 − 太さの半分・画素) に反比例して、半径 29・太さ 7 の
    /// 円の内縁 (25.5 画素) でも被覆率が 0.01 動き、1/255 を越える。そこで内縁の曲率半径が
    /// 足りない楕円は、式を輪郭の位置で解き直す (`mokume_canShiftRing`)。下地を読む列 (`.add`) は
    /// いつも解き直す。
    ///
    /// 比べるのは**輪郭の被覆率**で、塗りを外した同じ楕円の絵と、差が 1/255 を越える画素が 0
    /// (比べ方は `ringGap`)。
    ///
    /// 楕円は、長径と短径の比 1〜8・大きさ・太さを回す。**直径 58・太さ 7 の円**と、
    /// **内縁の曲率半径が 1 画素を切る組 (84×26・太さ 7)** を必ず入れる。近似が残る大きな楕円
    /// (内縁の曲率半径が数十〜数百画素の円と、円でない楕円) と、境目の両側も入れる。**円でない
    /// 楕円の近似は、距離場そのものの勾配でずらさないと、内縁の曲率半径が大きくても
    /// 1/255 を越える** (1060×530・太さ 7 で 0.0073、700×466・太さ 30 で 0.019) ので、
    /// それを見張る大きな楕円も入れてある。位置は小数、置き方は軸の向き・斜め・縦横で違う
    /// 拡大・鏡映 (行列式が負)・剪断・細かさ 0.5 も回す (ずらしの向きと、描く画素 1 つの大きさが
    /// 変わる)。
    ///
    /// **一周の `arc` も同じ検査を通す。** 一周の `arc` は `.ellipse` の形へ流れる
    /// (`Canvas.arc` の `isFullTurn`) ので症状は同じで、その経路を直接見る (代表の楕円だけ)。
    /// `rect` と一周でない `arc` (扇形) は、輪郭を常に輪郭の位置 `q` で厳密に解く構造で近似を
    /// 使わないので、この検査の対象外である。
    ///
    /// **この検査は「解き直す側に倒れて緑」を見逃す** — 判定 (`mokume_canShiftRing`) が壊れて
    /// 常に解き直すようになっても、輪郭は輪郭だけの楕円と一致するので緑のままである。近似が
    /// 使われ続けることは `largeEllipsesStayOnTheShiftedRing` が見る。
    ///
    /// [#1820]: https://github.com/mokume-metal/mokume/issues/1820
    /// [#1867]: https://github.com/mokume-metal/mokume/issues/1867
    @Test(
        "塗りと輪郭を両方持つ楕円の輪郭は、塗りの有無によらず輪郭だけの楕円と 1/255 以内で同じ",
        arguments: [BlendMode.blend, .add, .replace])
    func ellipseStrokeDoesNotDependOnTheFill(_ mode: BlendMode) throws {
        // 直径 (幅・高さ)・太さ・一周の `arc` でも描くか。内縁の曲率半径は
        // 短半径² / 長半径 − 太さの半分 (半径で数える)
        let cases: [(name: String, width: Float, height: Float, weight: Float, asArcToo: Bool)] = [
            ("円 58・太さ 7 (#1820)", 58, 58, 7, true),
            ("84×26・太さ 7 (#1820・内縁が 1 画素を切る)", 84, 26, 7, true),
            ("円 14", 14, 14, 3, false),
            ("円 120", 120, 120, 7, false),
            ("円 120・太さ 1", 120, 120, 1, false),
            ("円 120・太さ 30", 120, 120, 30, false),
            ("比 1.5 (87×58)", 87, 58, 7, false),
            ("比 2 (116×58)", 116, 58, 7, true),
            ("比 4 (232×58)", 232, 58, 7, false),
            ("比 8 (464×58)", 464, 58, 7, false),
            ("比 2 (52×26)", 52, 26, 7, false),
            ("比 4 (104×26)", 104, 26, 7, false),
            ("比 8 (208×26)", 208, 26, 7, false),
            ("比 3 (360×120)", 360, 120, 7, false),
            ("比 3 (360×120)・太さ 1", 360, 120, 1, false),
            ("84×26・太さ 30 (内縁が無い)", 84, 26, 30, false),
            ("円 262 (境目の手前)", 262, 262, 7, false),
            ("円 300", 300, 300, 7, true),
            ("円 300・太さ 30", 300, 300, 30, false),
            ("楕円 400×340", 400, 340, 7, true),
            ("楕円 480×440", 480, 440, 7, false),
            ("円 700 (近似が残る)", 700, 700, 7, false),
            ("楕円 1060×530 (比 2・近似が残る)", 1060, 530, 7, true),
            ("楕円 700×466・太さ 30 (近似が残る)", 700, 466, 30, false),
            ("円 1000 (縦横で違う拡大でも近似が残る)", 1000, 1000, 7, false),
        ]
        let placements: [RingPlacement] = [
            RingPlacement(), RingPlacement(angle: .pi / 4), RingPlacement(angle: 0.35),
            RingPlacement(angle: 0.35, scale: [1.8, 0.8]), RingPlacement(scale: [0.9, 0.5]),
            RingPlacement(density: 0.5), RingPlacement(angle: 0.35, density: 0.5),
            // 鏡映 (行列式が負)・剪断
            RingPlacement(scale: [-1, 1]), RingPlacement(angle: 0.35, scale: [-1.3, 0.7]),
            RingPlacement(shear: 0.4), RingPlacement(angle: 0.35, scale: [1.4, 0.8], shear: 0.5),
        ]
        for item in cases {
            for placement in placements {
                let reach = ringReach(width: item.width, height: item.height, weight: item.weight, placement)
                // 拡大・剪断した絵は大きいので、収まる楕円だけ回す
                if !placement.isPlain && reach > 1000 { continue }
                for asArc in item.asArcToo ? [false, true] : [false] {
                    let gap = try ringGap(
                        mode, width: item.width, height: item.height, weight: item.weight, placement,
                        asArc: asArc)
                    let label = "\(mode)・\(asArc ? "一周の arc" : "ellipse")・\(item.name)・\(placement.label)"
                    #expect(gap.edges > 20, "\(label): 輪郭の縁の画素が少ない (\(gap.edges))")
                    #expect(
                        gap.differing == 0,
                        "\(label): 輪郭の被覆率が塗りを足すと \(gap.differing) 画素で 1/255 を越えて動く (最大 \(gap.worst.gap) @ (\(gap.worst.x), \(gap.worst.y))・輪郭だけ \(gap.worst.strokeOnly)・両方 \(gap.worst.both))")
                }
            }
        }
    }

    /// 内縁の曲率半径が十分に大きい楕円は、近似でずらされ続ける ([#1820])。
    ///
    /// 上の検査 (`ellipseStrokeDoesNotDependOnTheFill`) は、近似を使うかどうかを問わず緑になる
    /// — 判定 (`mokume_canShiftRing`) が壊れて常に解き直す側へ倒れても、輪郭は輪郭だけの楕円と
    /// 一致するからである。鏡映で行列式の絶対値を落とす・特異値の式を壊すと、その倒れ方をする。
    /// そこで、**近似を使うはずの楕円は、塗りを足すと被覆率がわずかに (0 を越えて 1/255 以内で)
    /// 違う**ことを固定する。解き直す楕円は輪郭だけの楕円と同じ式を同じ位置で解くので、
    /// 1 ビットも違わない — 食い違いが 0 を越えるのは、近似でずらしているときだけである。
    ///
    /// 置き方は、内縁の曲率半径に対する見積もりが許す範囲 (`kFormShiftTolerance`) の 0.3〜0.7
    /// 倍に収まるものだけを選んだ (境目ぎりぎりの置き方は、float の丸めで判定が揺れうるので
    /// 固定しない)。円 (法線でずらす) と円でない楕円 (距離場そのものの勾配でずらす) の
    /// どちらも入れる。
    ///
    /// [#1820]: https://github.com/mokume-metal/mokume/issues/1820
    @Test(
        "内縁の曲率半径が十分に大きい楕円は、塗りを足すと被覆率がわずかに違う (近似でずらされ続ける)",
        arguments: [BlendMode.blend, .replace])
    func largeEllipsesStayOnTheShiftedRing(_ mode: BlendMode) throws {
        let large: [(name: String, width: Float, height: Float, placements: [RingPlacement], asArc: Bool)] = [
            ("円 700", 700, 700, [
                RingPlacement(), RingPlacement(angle: 0.35), RingPlacement(scale: [-1, 1]),
                RingPlacement(shear: 0.4), RingPlacement(angle: 0.35, scale: [1.4, 0.8], shear: 0.5),
                RingPlacement(density: 0.5),
            ], false),
            ("円 700 (一周の arc)", 700, 700, [RingPlacement()], true),
            ("円 1000", 1000, 1000, [RingPlacement(), RingPlacement(angle: 0.35)], false),
            ("楕円 480×440", 480, 440, [
                RingPlacement(), RingPlacement(angle: 0.35), RingPlacement(scale: [-1, 1]),
                RingPlacement(density: 0.5),
            ], false),
        ]
        for item in large {
            for placement in item.placements {
                let gap = try ringGap(
                    mode, width: item.width, height: item.height, weight: 7, placement, asArc: item.asArc)
                let label = "\(mode)・\(item.name)・\(placement.label)"
                #expect(
                    gap.worst.gap > 0,
                    "\(label): 輪郭が輪郭だけの絵と 1 ビットも違わない — 近似でずらされず、解き直されている")
                #expect(
                    gap.differing == 0,
                    "\(label): 輪郭の被覆率が塗りを足すと \(gap.differing) 画素で 1/255 を越えて動く (最大 \(gap.worst.gap))")
            }
        }
    }

    @Test("塗りを止めれば輪郭だけ、線を止めれば塗りだけが出る")
    func fillAndStrokeCanBeSwitchedOff() throws {
        let ring = try picture(try makeCanvas()) { canvas in
            canvas.noFill()
            canvas.stroke(blue)
            canvas.strokeWeight(4)
            canvas.circle(48, 48, 40)
        }
        #expect(ring[48, 48].blue == 0, "止めたはずの塗りが出ている")
        #expect(ring[68, 48].blue == 255)

        let disc = try picture(try makeCanvas()) { canvas in
            canvas.fill(red)
            canvas.stroke(blue)
            canvas.noStroke()
            canvas.strokeWeight(4)
            canvas.circle(48, 48, 40)
        }
        #expect(disc[48, 48].red == 255)
        #expect(disc[68, 48].blue == 0, "止めたはずの輪郭が出ている")
    }

    // MARK: - 端と角

    @Test("長さ 0 の線は端の形だけが出る")
    func zeroLengthLinesFollowTheCap() throws {
        func endOnly(_ cap: StrokeCap) throws -> DisplayImage {
            try picture(try makeCanvas()) { canvas in
                canvas.stroke(white)
                canvas.strokeWeight(10)
                canvas.strokeCap(cap)
                canvas.line(48, 48, 48, 48)
            }
        }
        let square = try endOnly(.square)
        #expect(square[48, 48].red == 0, "長さちょうどで切る端は、長さ 0 では何も描かない")
        let round = try endOnly(.round)
        #expect(round[48, 48].red == 255)
        #expect(round[52, 52].red == 0, "丸い端は角に届かない (中心から 5.66)")
        let project = try endOnly(.project)
        #expect(project[48, 48].red == 255)
        #expect(project[52, 52].red == 255, "出っ張る端は正方形")
        #expect(project[56, 56].red == 0)
    }

    @Test("点は端の形の孤立した 1 つとして出る")
    func pointsFollowTheCap() throws {
        func dot(_ cap: StrokeCap) throws -> DisplayImage {
            try picture(try makeCanvas()) { canvas in
                canvas.stroke(white)
                canvas.strokeWeight(10)
                canvas.strokeCap(cap)
                canvas.point(48, 48)
            }
        }
        #expect(try dot(.round)[52, 52].red == 0, "丸い点は角に届かない")
        #expect(try dot(.round)[48, 52].red == 255)
        // 孤立した端では、長さちょうどで切る形も正方形として出る (線が無いと長さが決まらない)
        #expect(try dot(.square)[52, 52].red == 255)
        #expect(try dot(.project)[52, 52].red == 255)
        #expect(try dot(.project)[56, 56].red == 0)
    }

    @Test("矩形の角は折れ目の形に従う — 尖らせれば残り、削げば 45° で落ち、丸めれば円弧")
    func rectangleCornersFollowTheJoin() throws {
        func corner(_ join: StrokeJoin) throws -> DisplayImage {
            try picture(try makeCanvas()) { canvas in
                canvas.noFill()
                canvas.stroke(white)
                canvas.strokeWeight(12)
                canvas.strokeJoin(join)
                canvas.rect(20, 20, 40, 40)
            }
        }
        // 外縁は 14…66。角 (15, 15) は尖らせたときだけ塗られる
        #expect(try corner(.miter)[15, 15].red == 255)
        #expect(try corner(.bevel)[15, 15].red == 0)
        #expect(try corner(.round)[15, 15].red == 0)
        // 削いだ角は 45° の直線。(19, 19) は削ぎ線 (|x−40|+|y−40| = 48.5) の内側
        #expect(try corner(.bevel)[19, 19].red == 255)
        // 丸めた角は半径 6 の円弧。(16, 20) は角 (20, 20) から 4 — 円弧の内側
        #expect(try corner(.round)[16, 20].red == 255)
        // 内縁はどの形でも直角 (帯が重なる)
        for join in [StrokeJoin.miter, .bevel, .round] {
            let image = try corner(join)
            #expect(image[27, 27].red == 0, "\(join): 内縁の角の内側が塗られている")
            #expect(image[25, 25].red == 255, "\(join): 内縁の角が欠けている")
        }
    }

    // MARK: - 1 画素より細い線・輪郭・点

    /// 黒地に白の輪郭で描いて、**線形の**赤 (= 被覆) を読む。
    ///
    /// 細い線の濃さは 1 画素あたり数 % なので、出力段を通した 8 bit (`picture`) では刻みが
    /// 粗すぎて和が読めない。読むのは作業空間そのままの値である。
    ///
    /// `density` を下げると、読むのは**描く画素** (出す面より小さい) になる。fixture の
    /// `Canvas(target:gpu:)` は細かさ 1 に決め打つので、そのときだけ直に組む。
    private func coverage(
        width: Int = 160, height: Int = 160, density: Float = 1, _ body: (Canvas) -> Void
    ) throws -> PixelBuffer {
        let canvas: Canvas
        if density == 1 {
            canvas = try makeCanvas(width: width, height: height)
        } else {
            let gpu = try RenderDevice()
            let output = try RenderTarget(gpu: gpu, width: width, height: height)
            canvas = try Canvas(output: output, gpu: gpu, pixelDensity: density, upscale: .spatial)
        }
        try canvas.draw {
            canvas.background(black)
            canvas.noFill()
            canvas.stroke(white)
            body(canvas)
        }
        return try canvas.target.readPixels()
    }

    /// 行 `row` の列 `columns` の被覆の和。
    private func rowSum(_ pixels: PixelBuffer, row: Int, columns: Range<Int>) -> Double {
        columns.reduce(0) { $0 + Double(pixels.components[(row * pixels.width + $1) * 4]) }
    }

    /// 面全体の被覆の和。
    private func totalSum(_ pixels: PixelBuffer) -> Double {
        stride(from: 0, to: pixels.components.count, by: 4)
            .reduce(0) { $0 + Double(pixels.components[$1]) }
    }

    /// **1 画素より細い線は、置く位置によらず太さぶんの濃さで出る** ([#1451])。
    ///
    /// 被覆を縁 1 本の距離だけで出していた頃は、帯の両縁が同じ画素に入っても向こう側の縁の
    /// 欠けを引かなかった。線は画面で半画素寄せる約束 (ADR-0039 決定 2) なので、整数の座標
    /// では帯の中心が画素の中心に乗り、太さ 0.1 の線がその 1 画素を 0.55 で塗っていた —
    /// 帯が 2 画素の境目に乗る半端な座標 (0.093) の 5.9 倍である。
    ///
    /// 被覆は画面の画素で測るので、拡大の下で画面で同じ太さ・同じ位置になる線も同じ濃さで
    /// 出る。
    ///
    /// 太さ 0.05 も見るのは、細い線の被覆に 1/256 の遊び (`mokume_formCoverage`) を掛けて
    /// いないことを捕まえるため — 掛けると帯を画素の境目に置いた太さ 0.05 の線が 15% 足りなく
    /// なる (太さ 0.1 では 7% で、許容の内に収まってしまう)。
    ///
    /// [#1451]: https://github.com/mokume-metal/mokume/issues/1451
    @Test(
        "1 画素より細い縦線は、置く位置によらず太さぶんの濃さで出る",
        arguments: [Float(0.05), 0.1, 0.5], [Float(80), 80.25, 80.5])
    func subpixelLinesKeepTheirWeight(_ weight: Float, _ x: Float) throws {
        let direct = try coverage { canvas in
            canvas.strokeWeight(weight)
            canvas.line(x, 10, x, 150)
        }
        let directSum = rowSum(direct, row: 80, columns: 70..<90)
        #expect(
            abs(directSum - Double(weight)) <= 0.1 * Double(weight),
            "太さ \(weight)・x = \(x) の縦線の行の和: \(directSum)")

        let scaled = try coverage { canvas in
            canvas.scale(0.25, 0.25)
            canvas.strokeWeight(weight * 4)
            canvas.line(x * 4, 40, x * 4, 600)
        }
        let scaledSum = rowSum(scaled, row: 80, columns: 70..<90)
        #expect(
            abs(scaledSum - Double(weight)) <= 0.1 * Double(weight),
            "scale(0.25) の下で画面の太さ \(weight)・x = \(x) の縦線の行の和: \(scaledSum)")
    }

    /// 線の**端**でも濃さは太さに比例する。
    ///
    /// 長さの向きも画素の中で両側の端を見る — 片側の縁だけを見ると、端を画素の中心に
    /// 置いた線がそこで帯の外まで塗られ、太さ 0.1・長さ 20 の線の和が 11.5 (期待の 5.8 倍)
    /// になっていた。回した線でも同じ。
    @Test("1 画素より細い線は、端でも回しても太さに比例した濃さで出る")
    func subpixelLineEndsKeepTheirWeight() throws {
        // 太さ 0.1・長さ 20 の水平線 (既定の丸い端)。期待は 20 × 0.1 = 2 (端の丸は 0.008)
        let starts: [(Float, Float)] = [(10, 20), (10.5, 20), (10.25, 20.5), (10.5, 20.5)]
        for (x, y) in starts {
            let pixels = try coverage(width: 64, height: 64) { canvas in
                canvas.strokeWeight(0.1)
                canvas.line(x, y, x + 20, y)
            }
            let sum = totalSum(pixels)
            #expect(abs(sum - 2) <= 0.2, "(\(x), \(y)) から引いた長さ 20 の線の和: \(sum)")
        }
        // 0.5 rad 回した長さ 40 の線。期待は 40 × 0.1 = 4
        let angle: Float = 0.5
        let tilted: [(Float, Float)] = [(10.25, 10), (10.5, 10.5), (10.1, 10.7)]
        for (x, y) in tilted {
            let pixels = try coverage(width: 64, height: 64) { canvas in
                canvas.strokeWeight(0.1)
                canvas.line(x, y, x + 40 * cos(angle), y + 40 * sin(angle))
            }
            let sum = totalSum(pixels)
            #expect(abs(sum - 4) <= 0.4, "(\(x), \(y)) から 0.5 rad 回して引いた線の和: \(sum)")
        }
    }

    /// 輪郭の帯も、1 画素より細ければ縁の位置によらず太さぶんの濃さで出る。
    ///
    /// 帯は外縁と内縁の 2 本の距離場を持つが、2 つの被覆を**掛け合わせて**いた頃は
    /// (「外縁の内で、かつ内縁の外」を独立な事象とみなす式)、両縁が同じ画素に入ると内縁の
    /// 欠けを引き切れず、太さ 0.1 の縁の和が 0.303 / 0.239 / 0.093 と位置で揺れていた。
    @Test(
        "1 画素より細い輪郭は、縁を置く位置によらず太さぶんの濃さで出る",
        arguments: ["rect", "circle", "arc"], [Float(0.1), 0.5])
    func subpixelOutlinesKeepTheirWeight(_ kind: String, _ weight: Float) throws {
        for offset in [Float(0), 0.25, 0.5] {
            let pixels = try coverage(width: 128, height: 128) { canvas in
                canvas.strokeWeight(weight)
                // どれも左の縁が x = 10 + offset に来て、行 60 がその縁を横切る。弧は角 π を
                // 挟む向きに開くので、扇の 2 本の半径は行 60 では中心 (x = 60 付近) にしか来ない
                switch kind {
                case "rect": canvas.rect(10 + offset, 40, 40, 40)
                case "circle": canvas.circle(60 + offset, 60, 100)
                default: canvas.arc(60 + offset, 60, 100, 100, Float.pi - 0.5, Float.pi + 0.5)
                }
            }
            let sum = rowSum(pixels, row: 60, columns: 0..<20)
            #expect(
                abs(sum - Double(weight)) <= 0.1 * Double(weight),
                "\(kind) の太さ \(weight)・縁 x = \(10 + offset) の行の和: \(sum)")
        }
    }

    /// **1 画素より細い点は、置く位置によらず面積に比例した濃さで出る。**
    ///
    /// 点は長さ 0 の線なので、太さの向きと長さの向きのどちらでも両側の縁を見る。片側だけ
    /// を見ると、4 画素の角に置いた太さ 0.1 の丸い点はどの画素の中心にも届かずに消え
    /// (0)、画素の中心に置くと 0.55 で出ていた。
    @Test("1 画素より細い点は、置く位置によらず面積に比例した濃さで出る", arguments: [StrokeCap.round, .project])
    func subpixelPointsKeepTheirArea(_ cap: StrokeCap) throws {
        let positions: [(Float, Float)] = [(20, 20), (20.5, 20), (20.5, 20.5), (20.25, 20.1)]
        func sums(_ weight: Float) throws -> [Double] {
            try positions.map { (x, y) in
                totalSum(
                    try coverage(width: 40, height: 40) { canvas in
                        canvas.strokeWeight(weight)
                        canvas.strokeCap(cap)
                        canvas.point(x, y)
                    })
            }
        }
        let thin = try sums(0.1)
        let thick = try sums(0.5)
        for (weight, values) in [(0.1, thin), (0.5, thick)] {
            let smallest = values.min() ?? 0
            let largest = values.max() ?? 0
            #expect(smallest > 0, "\(cap) の太さ \(weight) の点が消える位置がある: \(values)")
            #expect(
                largest <= 1.25 * smallest,
                "\(cap) の太さ \(weight) の点の和が位置で揺れる: \(values)")
        }
        // 面積は太さの 2 乗に比例する — 太さ 0.1 は太さ 0.5 の 1/25
        for (index, (small, large)) in zip(thin, thick).enumerated() {
            let ratio = large > 0 ? small / large : .infinity
            #expect(
                abs(ratio - 1.0 / 25) <= 0.3 / 25,
                "\(cap) の点 \(positions[index]) で、太さ 0.1 と 0.5 の和の比が \(ratio) (期待 0.04)")
        }
    }

    /// **1 画素以上の線と輪郭は、縁の位置によらず太さぶんの濃さのまま。**
    ///
    /// 1 画素より細い帯の扱いを直したことが、1 画素以上へ漏れないための見張り
    /// ([#1451] 完了条件 5)。1 画素以上では、帯の片側の縁しか入らない画素と、帯に覆い
    /// 切られる画素しか無いので、縁 1 本の被覆で足りていた (1/256 の遊びのぶんだけ和が
    /// 僅かに縮む)。
    ///
    /// [#1451]: https://github.com/mokume-metal/mokume/issues/1451
    @Test(
        "1 画素以上の線と輪郭は、縁を置く位置によらず太さぶんの濃さのまま",
        arguments: [Float(1), 1.5, 2, 3])
    func weightsOfAPixelOrMoreStayExact(_ weight: Float) throws {
        for offset in [Float(0), 0.25, 0.5] {
            let line = try coverage { canvas in
                canvas.strokeWeight(weight)
                canvas.line(80 + offset, 10, 80 + offset, 150)
            }
            let lineSum = rowSum(line, row: 80, columns: 70..<90)
            #expect(
                abs(lineSum - Double(weight)) <= 0.01 * Double(weight),
                "太さ \(weight)・x = \(80 + offset) の縦線の行の和: \(lineSum)")

            let outline = try coverage { canvas in
                canvas.strokeWeight(weight)
                canvas.rect(10 + offset, 40, 40, 40)
            }
            let outlineSum = rowSum(outline, row: 60, columns: 0..<20)
            #expect(
                abs(outlineSum - Double(weight)) <= 0.01 * Double(weight),
                "太さ \(weight)・縁 x = \(10 + offset) の rect の輪郭の行の和: \(outlineSum)")
        }
    }

    // MARK: - 1 画素より細い塗り

    /// **1 画素より細い `rect` の塗りは、置く位置によらず面積ぶんの濃さで出る** ([#1477])。
    ///
    /// 塗りの被覆を縁 1 本の距離だけで出していた頃は、帯の両縁が同じ画素に入っても向こう側の
    /// 縁の欠けを引かなかった。幅 0.1・高さ 20 の `rect` (面積 2) の和が、帯の中心を画素の
    /// 中心に置くと 11.0、画素の境目に置くと 1.86 だった。塗りは寄せない (ADR-0039 決定 2)
    /// ので、線と違って整数の座標では縁が画素の境目に乗る。
    ///
    /// 幅 0.05 と、帯の中心が画素の境目に来る位置 (11 − w/2) を見るのは、細い塗りに 1/256 の
    /// 遊び (`mokume_formCoverage`) を掛けていないことを捕まえるため — 掛けると、境目を
    /// またぐ幅 0.05 の帯が 15% 足りなくなる (帯が画素 1 つに収まる位置では 7% で、許容の内に
    /// 収まってしまう)。位置を引数に割らないのは、直す前でも緑になる位置があるためである。
    ///
    /// [#1477]: https://github.com/mokume-metal/mokume/issues/1477
    @Test(
        "1 画素より細い rect は、置く位置によらず面積ぶんの濃さで出る",
        arguments: [Float(0.05), 0.1, 0.5])
    func subpixelRectanglesKeepTheirArea(_ width: Float) throws {
        // 左上の角。帯の中心が画素の中心に来る位置 (10.5 − w/2) と、画素の境目に来る位置
        // (11 − w/2) を含む
        let corners: [(Float, Float)] = [
            (10, 10), (10.25, 10), (10.5, 10), (10.5 - width / 2, 10), (11 - width / 2, 10),
            (10.3, 10.7),
        ]
        let expected = Double(width) * 20
        for (x, y) in corners {
            let upright = totalSum(
                try coverage(width: 64, height: 64) { canvas in
                    canvas.noStroke()
                    canvas.fill(white)
                    canvas.rect(x, y, width, 20)
                })
            #expect(
                abs(upright - expected) <= 0.1 * expected,
                "幅 \(width)・左上 (\(x), \(y)) の縦長の rect の和: \(upright) (期待 \(expected))")

            let lying = totalSum(
                try coverage(width: 64, height: 64) { canvas in
                    canvas.noStroke()
                    canvas.fill(white)
                    canvas.rect(y, x, 20, width)
                })
            #expect(
                abs(lying - expected) <= 0.1 * expected,
                "幅 \(width)・左上 (\(y), \(x)) の横長の rect の和: \(lying) (期待 \(expected))")

            // 画面で同じ位置・同じ大きさになる、拡大の下の rect
            let scaled = totalSum(
                try coverage(width: 64, height: 64) { canvas in
                    canvas.noStroke()
                    canvas.fill(white)
                    canvas.scale(0.25, 0.25)
                    canvas.rect(x * 4, y * 4, width * 4, 80)
                })
            #expect(
                abs(scaled - expected) <= 0.1 * expected,
                "scale(0.25) の下で画面の幅 \(width)・左上 (\(x), \(y)) の rect の和: \(scaled) (期待 \(expected))")
        }
    }

    /// 回した細い `rect` も、面積ぶんの濃さで出る。
    ///
    /// 細さは描く画素 1 つが形自身の座標でいくらか (逆行列の行ノルム) で測るので、回した
    /// 形でも同じ枝を通る。縁 1 本の式では、0.5 rad 回した幅 0.1・長さ 40 の `rect` (面積 4)
    /// の和が 12 前後だった。
    @Test("回した 1 画素より細い rect も、面積ぶんの濃さで出る")
    func tiltedSubpixelRectanglesKeepTheirArea() throws {
        let centers: [(Float, Float)] = [(32.25, 32), (32.5, 32.5), (32.1, 32.7)]
        for (x, y) in centers {
            let sum = totalSum(
                try coverage(width: 64, height: 64) { canvas in
                    canvas.noStroke()
                    canvas.fill(white)
                    canvas.translate(x, y)
                    canvas.rotate(0.5)
                    canvas.rect(-20, -0.05, 40, 0.1)
                })
            #expect(abs(sum - 4) <= 0.4, "中心 (\(x), \(y)) で 0.5 rad 回した rect の和: \(sum) (期待 4)")
        }
    }

    /// **1 画素より小さい円は、置く位置によらず外接する正方形の面積ぶんで出る。**
    ///
    /// 直径 d の円は d² に比例させる — 同じ位置に置いた太さ d の丸い点 (1 画素より細い点は
    /// 四角に数える) と同じ量で、直径 1 の境目の両側でも濃さが続く (#1477 の判断 1)。縁 1 本
    /// の式では、直径 0.2 の円が 4 画素の角に置くと消え (0)、画素の中心に置くと 0.60
    /// (外接する正方形の 15 倍) で出ていた。
    @Test(
        "1 画素より小さい円は、置く位置によらず外接する正方形の面積ぶんで出る",
        arguments: [Float(0.2), 0.5])
    func subpixelCirclesKeepTheirBoundingSquare(_ diameter: Float) throws {
        let centers: [(Float, Float)] = [(20, 20), (20.25, 20), (20.5, 20.5), (20.3, 20.7)]
        let expected = Double(diameter * diameter)
        for (x, y) in centers {
            let circle = totalSum(
                try coverage(width: 40, height: 40) { canvas in
                    canvas.noStroke()
                    canvas.fill(white)
                    canvas.circle(x, y, diameter)
                })
            #expect(
                abs(circle - expected) <= 0.1 * expected,
                "直径 \(diameter)・中心 (\(x), \(y)) の円の和: \(circle) (期待 \(expected))")

            let point = totalSum(
                try coverage(width: 40, height: 40) { canvas in
                    canvas.strokeWeight(diameter)
                    canvas.strokeCap(.round)
                    canvas.point(x, y)
                })
            #expect(
                abs(circle - point) <= 0.1 * point,
                "直径 \(diameter)・中心 (\(x), \(y)) の円の和 \(circle) が、太さ \(diameter) の丸い点の和 \(point) と食い違う")
        }
    }

    /// **片方の向きだけが細い楕円も、置く位置によらず面積ぶんの濃さで出る。**
    ///
    /// 長い向きは画素で解けているので、細い向きの両縁だけを数え、面積 (π/4 × 幅 × 高さ) に
    /// 比例させる。縁 1 本の式では、`ellipse(x, 30, 0.2, 20)` (面積 3.14) の和が、中心を
    /// 画素の境目に置くと 5.94、画素の中心に置くと 20.0 だった。
    @Test("細長い楕円は、置く位置によらず面積ぶんの濃さで出る")
    func thinEllipsesKeepTheirArea() throws {
        let centers: [(Float, Float)] = [(20, 30), (20.25, 30), (20.5, 30), (20.3, 30), (20.3, 30.7)]
        let expected = Double.pi / 4 * 0.2 * 20
        for (x, y) in centers {
            let tall = totalSum(
                try coverage(width: 64, height: 64) { canvas in
                    canvas.noStroke()
                    canvas.fill(white)
                    canvas.ellipse(x, y, 0.2, 20)
                })
            #expect(
                abs(tall - expected) <= 0.1 * expected,
                "中心 (\(x), \(y)) の縦長の楕円の和: \(tall) (期待 \(expected))")

            let wide = totalSum(
                try coverage(width: 64, height: 64) { canvas in
                    canvas.noStroke()
                    canvas.fill(white)
                    canvas.ellipse(y, x, 20, 0.2)
                })
            #expect(
                abs(wide - expected) <= 0.1 * expected,
                "中心 (\(y), \(x)) の横長の楕円の和: \(wide) (期待 \(expected))")
        }
    }

    /// **1 画素以上の塗りは、縁の位置によらず幅ぶんの濃さのまま。**
    ///
    /// 1 画素より細い塗りの扱いを直したことが、1 画素以上へ漏れないための見張り
    /// ([#1477] 完了条件 6)。1 画素以上の塗りは縁 1 本の式のままなので、縁が画素に 3/4
    /// 掛かる画素は 1/256 の遊びのぶん 0.75 からずれた値 (0.75 × (1 + 2/256) − 1/256) で
    /// 出る。細い塗りの枝は遊びを掛けないので、1 画素以上へ漏れればそこが 0.75 ちょうどになる。
    ///
    /// [#1477]: https://github.com/mokume-metal/mokume/issues/1477
    @Test(
        "1 画素以上の塗りは、縁を置く位置によらず幅ぶんの濃さのまま",
        arguments: [Float(1), 1.5, 2, 3])
    func fillsOfAPixelOrMoreStayExact(_ width: Float) throws {
        for x in [Float(10), 10.25, 10.5] {
            let pixels = try coverage(width: 32, height: 32) { canvas in
                canvas.noStroke()
                canvas.fill(white)
                canvas.rect(x, 4, width, 24)
            }
            let sum = rowSum(pixels, row: 16, columns: 0..<32)
            #expect(
                abs(sum - Double(width)) <= 0.01 * Double(width),
                "幅 \(width)・左の縁 x = \(x) の rect の行の和: \(sum)")
            if x == 10.25 {
                let edge = Double(pixels.components[(16 * pixels.width + 10) * 4])
                let snapped = 0.75 * (1 + 2.0 / 256) - 1.0 / 256
                #expect(
                    abs(edge - snapped) <= 1e-4,
                    "幅 \(width)・左の縁 x = 10.25 の rect の、縁に 3/4 掛かる画素: \(edge) (期待 \(snapped))")
            }
        }
    }

    // MARK: - 描く細かさを下げた面

    /// **描く細かさを下げた面でも、線の濃さは置く位置によらず、描く画素での太さぶんで出る**
    /// ([#1488])。
    ///
    /// 座標と太さは出す画素で書き、描く画素への縮みは投影が持つ。被覆を出す画素の単位で
    /// 測っていた頃は、`pixelDensity: 0.5` の太さ 1 の線が、描く画素では太さ 0.5 なのに
    /// 被覆の式からは太さ 1 に見えていた。描く画素の中心は出す座標で 2 ずつ離れるので、
    /// 線の縁から 1 単位の所に中心が来る位置 (x = 81.5) では被覆が 0 になって線が消え、
    /// 行の和が x = 80 / 80.5 / 81 / 81.5 で 0.5 / 1.0 / 0.5 / 0 と揺れていた。
    ///
    /// 太さ 3 (描く画素で 1.5) も見るのは、1 画素より太い帯の縁の渡しも描く画素で測る
    /// ことを捕まえるため — 出す画素で測ると、縁の渡しが描く画素の半分の幅に縮む。
    ///
    /// [#1488]: https://github.com/mokume-metal/mokume/issues/1488
    @Test(
        "描く細かさ 0.5 の面の縦線は、置く位置によらず描く画素での太さぶんの濃さで出る",
        arguments: [Float(0.2), 1, 3], [Float(80), 80.5, 81, 81.5])
    func halfDensityLinesKeepTheirWeight(_ weight: Float, _ x: Float) throws {
        let pixels = try coverage(density: 0.5) { canvas in
            canvas.strokeWeight(weight)
            canvas.line(x, 10, x, 150)
        }
        // 出す 160 画素の面は、描く画素では 80。行 40 は出す座標の y = 80〜82 にあたる
        let sum = rowSum(pixels, row: 40, columns: 30..<50)
        let expected = Double(weight) * 0.5
        #expect(
            abs(sum - expected) <= 0.1 * expected,
            "細かさ 0.5・太さ \(weight)・x = \(x) の縦線の、描く画素の行の和: \(sum) (期待 \(expected))")
    }

    /// 輪郭の帯も、描く細かさを下げた面で縁の位置によらず、描く画素での太さぶんで出る。
    ///
    /// 輪郭は外縁と内縁の被覆の差で数える (`mokume_formPaint`)。どちらの縁の被覆も
    /// 出す画素で測っていた頃は、帯が描く画素の中でどこに来るかで和が揺れていた。
    @Test(
        "描く細かさ 0.5 の面の輪郭は、縁を置く位置によらず描く画素での太さぶんの濃さで出る",
        arguments: ["rect", "circle", "arc"], [Float(0.2), 1, 3])
    func halfDensityOutlinesKeepTheirWeight(_ kind: String, _ weight: Float) throws {
        for offset in [Float(0), 0.5, 1, 1.5] {
            let pixels = try coverage(width: 128, height: 128, density: 0.5) { canvas in
                canvas.strokeWeight(weight)
                // どれも左の縁が x = 10 + offset に来る (`subpixelOutlinesKeepTheirWeight` と同じ形)
                switch kind {
                case "rect": canvas.rect(10 + offset, 40, 40, 40)
                case "circle": canvas.circle(60 + offset, 60, 100)
                default: canvas.arc(60 + offset, 60, 100, 100, Float.pi - 0.5, Float.pi + 0.5)
                }
            }
            // 描く画素の行 30 (出す座標の y = 60〜62) が左の縁を横切る
            let sum = rowSum(pixels, row: 30, columns: 0..<10)
            let expected = Double(weight) * 0.5
            #expect(
                abs(sum - expected) <= 0.1 * expected,
                "細かさ 0.5・\(kind) の太さ \(weight)・縁 x = \(10 + offset) の、描く画素の行の和: \(sum) (期待 \(expected))")
        }
    }

    /// 点も、描く細かさを下げた面で置く位置によらず、描く画素での面積ぶんで出る。
    ///
    /// 出す座標で 0.5 ずつずらすと、点の中心は描く画素の中を 0.25 ずつ動く。並べたのは
    /// 描く画素の中心・縁・角と、その間である。
    @Test(
        "描く細かさ 0.5 の面の点は、置く位置によらず描く画素での面積ぶんの濃さで出る",
        arguments: [StrokeCap.round, .project])
    func halfDensityPointsKeepTheirArea(_ cap: StrokeCap) throws {
        // 評価は出す画素で半画素寄せるので、中心は描く画素で ((x + 0.5) / 2, (y + 0.5) / 2)
        let positions: [(Float, Float)] = [(40, 40), (40.5, 40.5), (41.5, 40.5), (41.5, 41.5)]
        for weight in [Float(0.2), 1] {
            for (x, y) in positions {
                let sum = totalSum(
                    try coverage(width: 80, height: 80, density: 0.5) { canvas in
                        canvas.strokeWeight(weight)
                        canvas.strokeCap(cap)
                        canvas.point(x, y)
                    })
                let expected = pow(Double(weight) * 0.5, 2)
                #expect(
                    abs(sum - expected) <= 0.1 * expected,
                    "細かさ 0.5・\(cap) の太さ \(weight) の点 (\(x), \(y)) の、描く画素の和: \(sum) (期待 \(expected))")
            }
        }
    }

    /// **塗りの縁も、描く画素に掛かる面積ぶんの濃さで出る。**
    ///
    /// 塗りの縁の被覆も同じ式 (`mokume_formCoverage`) で出す。出す画素で測っていた頃は、
    /// 縁を滑らかにする幅が描く画素の半分しか無く、縁が描く画素の 1/4 に掛かっても 3/4 に
    /// 掛かっても、その画素は 0 か 1 に振り切れていた。
    @Test("描く細かさ 0.5 の面の塗りの縁は、描く画素に掛かる面積ぶんの濃さで出る")
    func halfDensityFillEdgesFollowTheArea() throws {
        for offset in [Float(0), 0.5, 1, 1.5] {
            let pixels = try coverage(width: 128, height: 128, density: 0.5) { canvas in
                canvas.noStroke()
                canvas.fill(white)
                canvas.rect(10 + offset, 40, 40, 40)
            }
            // 左の縁は描く画素で x = 5 + offset / 2。画素 5 (行 30) に掛かるのは 1 − offset / 2
            let edge = Double(pixels.components[(30 * pixels.width + 5) * 4])
            let expected = 1 - Double(offset) / 2
            #expect(
                abs(edge - expected) <= 0.01,
                "細かさ 0.5・縁 x = \(10 + offset) の塗りの、縁に掛かる描く画素の値: \(edge) (期待 \(expected))")
        }
    }

    /// **1 画素より細い塗りも、描く細かさを下げた面では描く画素での面積ぶんで出る** ([#1477])。
    ///
    /// 細さは描く画素で測る (`inverseRows` が描く画素を基準にしている・#1488)。細かさ 0.5 の
    /// `rect(x, 10, 0.2, 20)` は描く画素では幅 0.1・高さ 10 で、縁 1 本の式では描く画素の和が
    /// 置く位置で 0.97〜5.00 に揺れていた (期待 1.0)。直径 1 の円は描く画素で直径 0.5 なので、
    /// 外接する正方形の 0.25 になる。
    ///
    /// [#1477]: https://github.com/mokume-metal/mokume/issues/1477
    @Test("描く細かさ 0.5 の面でも、1 画素より細い塗りは描く画素での面積ぶんの濃さで出る")
    func halfDensitySubpixelFillsKeepTheirArea() throws {
        for x in [Float(10), 10.5, 11, 11.5] {
            let sum = totalSum(
                try coverage(width: 64, height: 64, density: 0.5) { canvas in
                    canvas.noStroke()
                    canvas.fill(white)
                    canvas.rect(x, 10, 0.2, 20)
                })
            #expect(
                abs(sum - 1) <= 0.1,
                "細かさ 0.5・左の縁 x = \(x) の幅 0.2 の rect の、描く画素の和: \(sum) (期待 1)")
        }
        let centers: [(Float, Float)] = [(40, 40), (40.5, 40), (41, 41), (40.6, 41.4)]
        for (x, y) in centers {
            let sum = totalSum(
                try coverage(width: 80, height: 80, density: 0.5) { canvas in
                    canvas.noStroke()
                    canvas.fill(white)
                    canvas.circle(x, y, 1)
                })
            #expect(
                abs(sum - 0.25) <= 0.025,
                "細かさ 0.5・中心 (\(x), \(y)) の直径 1 の円の、描く画素の和: \(sum) (期待 0.25)")
        }
    }

    /// **細い塗りを含む列と含まない列が 1 枚に混ざっても、どの塗りも正しく描ける** ([#1477])。
    ///
    /// 1 画素より細い塗りの枝は、細い塗りを含まない列では断片の原稿から外す
    /// (`kFormHasThinFill`)。含むかは置く側が図形ごとに判定して列の旗に足す
    /// (`FormInstance.mayHaveThinFill`) ので、判定が細い塗りを見落とすと、その列の細い塗りが
    /// 縁 1 本の式に戻って濃さが揺れる。太い塗りだけの列・細い塗りだけの列・両方が混ざった
    /// 列 (太い塗りが先) を並べ、太い塗りは縁 1 本の式のまま (縁に 3/4 掛かる画素が遊びを
    /// 込めた値)、細い塗りは面積ぶんで出ることを見る。
    ///
    /// [#1477]: https://github.com/mokume-metal/mokume/issues/1477
    @Test("細い塗りを含む列と含まない列が混ざっても、どちらの塗りも正しく描ける")
    func thinAndThickFillRunsMix() throws {
        let pixels = try coverage(width: 64, height: 64) { canvas in
            // 塗りを持たない点を挟んで列を切る (点は角 (60, 60) の画素にだけ出る)
            let splitRun = {
                canvas.stroke(white)
                canvas.point(60, 60)
                canvas.noStroke()
            }
            canvas.noStroke()
            canvas.fill(white)
            // 列 1: 1 画素以上の塗りだけ
            canvas.rect(10.25, 4, 2, 12)
            splitRun()
            // 列 2: 1 画素より細い塗りだけ (帯の中心が画素の中心)
            canvas.rect(30.45, 4, 0.1, 12)
            splitRun()
            // 列 3: 太い塗りの後に、細い rect と、4 画素の角に置いた小さい円
            canvas.rect(10.25, 24, 2, 12)
            canvas.rect(30.45, 24, 0.1, 12)
            canvas.circle(50, 30, 0.5)
        }
        func sum(rows: Range<Int>, columns: Range<Int>) -> Double {
            rows.reduce(0) { $0 + rowSum(pixels, row: $1, columns: columns) }
        }
        let snapped = 0.75 * (1 + 2.0 / 256) - 1.0 / 256
        for (name, row) in [("太い塗りだけの列", 10), ("混ざった列", 30)] {
            let thick = rowSum(pixels, row: row, columns: 0..<20)
            #expect(abs(thick - 2) <= 0.02, "\(name) の幅 2 の rect の行の和: \(thick) (期待 2)")
            let edge = Double(pixels.components[(row * pixels.width + 10) * 4])
            #expect(
                abs(edge - snapped) <= 1e-4,
                "\(name) の幅 2 の rect の、縁に 3/4 掛かる画素: \(edge) (期待 \(snapped))")
        }
        for (name, rows) in [("細い塗りだけの列", 0..<20), ("混ざった列", 20..<40)] {
            let thin = sum(rows: rows, columns: 20..<40)
            #expect(abs(thin - 1.2) <= 0.12, "\(name) の幅 0.1 の rect の和: \(thin) (期待 1.2)")
        }
        let circle = sum(rows: 20..<40, columns: 40..<60)
        #expect(abs(circle - 0.25) <= 0.025, "混ざった列の直径 0.5 の円の和: \(circle) (期待 0.25)")
    }

    /// **描く細かさをもっと下げても、縁に掛かる画素が覆う四角の外に落ちない。**
    ///
    /// 頂点関数が形の外に取る余白 (`kFormMargin`) も描く画素で測る。出す画素で 2 のまま
    /// だと、細かさ 0.25 では描く画素の半分にしかならない。線は画面で半画素寄せて評価する
    /// ので、寄せた側 (+x) で縁に掛かる描く画素の中心が四角の外に出て、その画素が塗られない。
    @Test("描く細かさ 0.25 の面でも、縦線の縁に掛かる画素が落ちない")
    func quarterDensityLinesKeepTheirEdges() throws {
        // 出す座標で 0.25 ずつ、描く画素 1 つぶん (出す座標で 4) を刻む
        for step in 0..<16 {
            let x = 80 + Float(step) * 0.25
            let pixels = try coverage(density: 0.25) { canvas in
                canvas.strokeWeight(2)
                canvas.line(x, 10, x, 150)
            }
            // 出す 160 画素の面は、描く画素では 40。行 20 は出す座標の y = 80〜84 にあたる
            let sum = rowSum(pixels, row: 20, columns: 15..<25)
            #expect(
                abs(sum - 0.5) <= 0.05,
                "細かさ 0.25・太さ 2・x = \(x) の縦線の、描く画素の行の和: \(sum) (期待 0.5)")
        }
    }

    // MARK: - 壊れない

    @Test("大きさの無い図形・負の寸法は何も描かない")
    func degenerateSizesDrawNothing() throws {
        let blank = try picture(try makeCanvas()) { _ in }
        let image = try picture(try makeCanvas()) { canvas in
            canvas.fill(white)
            canvas.stroke(white)
            canvas.rect(10, 10, 0, 20)
            canvas.rect(10, 10, 20, 0)
            canvas.rect(10, 10, -20, 20)
            canvas.circle(48, 48, 0)
            canvas.circle(48, 48, -10)
            canvas.ellipse(48, 48, 10, 0)
            canvas.arc(48, 48, 20, 20, 1, 0.5)
            canvas.strokeWeight(0)
            canvas.line(0, 0, 96, 96)
            canvas.point(48, 48)
        }
        #expect(image.bytes == blank.bytes)
    }

    /// 扇の**直線の縁**の輪郭は、帯の幅いっぱいが塗り切られている。
    ///
    /// 距離場は線分の上でちょうど 0 になり、そこでは「外へ向かう向き」が決まらないので
    /// 控えの向きが使われる。控えが長さ 1 でないと、被覆の渡し (`mokume_formCoverage`) が
    /// その長さのぶんだけ間延びし、**帯の真ん中の 1 画素だけが薄く抜ける** — 縁の上の
    /// 1 画素なので台帳の指紋は動くが、絵を拡大するまで気付けない ([#752])。
    ///
    /// [#752]: https://github.com/mokume-metal/mokume/issues/752
    @Test("扇の直線の縁は、輪郭の帯の真ん中が抜けない")
    func sectorStraightEdgeHasSolidStroke() throws {
        let image = try picture(try makeCanvas()) { canvas in
            canvas.noFill()
            canvas.stroke(white)
            canvas.strokeWeight(6)
            // 始まりの角度 0 = 中心から右へ伸びる水平な半径。帯はその上下 3 画素ぶん
            canvas.arc(48, 48, 60, 60, 0, .pi * 0.75)
        }
        // 半径の途中を横切る縦の並び。帯の内側は端から端まで塗り切られている
        for y in 46...50 {
            #expect(
                image[64, y].red == 255,
                "扇の直線の縁の帯 (y=\(y)) が抜けている: \(image[64, y].red)")
        }
    }

    /// 楕円の扇の再現 ([#1448])。横 260・縦 80 の楕円の 0…π/4 で、弧の端は媒介変数の角
    /// 45° の点 (cx + rx·cos t, cy + ry·sin t) — 中心から見ると 17° の向きにある。
    ///
    /// [#1448]: https://github.com/mokume-metal/mokume/issues/1448
    private func ellipticSector(_ canvas: Canvas) {
        canvas.arc(20, 60, 260, 80, 0, Float.pi / 4)
    }

    /// 楕円の扇の**塗り**の内外は、辺を引くのと同じ媒介変数の角で決まる。
    ///
    /// 内外を中心から見た角で決めていた頃は、切り口が中心から見た 45° の半直線まで
    /// 伸び、本当の辺 (中心から弧の端まで) の外に三角の塗りがはみ出していた ([#1448])。
    ///
    /// [#1448]: https://github.com/mokume-metal/mokume/issues/1448
    @Test("楕円の扇の塗りは、弧の端へ引いた辺の外へはみ出さない")
    func ellipticSectorFillStopsAtItsEdge() throws {
        let image = try picture(try makeCanvas(width: 170, height: 110)) { canvas in
            canvas.noStroke()
            canvas.fill(white)
            ellipticSector(canvas)
        }
        // (52, 77) は楕円の内で、中心から見れば 28° (はみ出しの中)、媒介変数の角では 60°
        #expect(image[52, 77].red == 0, "扇の外 (媒介変数の角 60°) が塗られている: \(image[52, 77].red)")
        // 媒介変数の角 13° の扇の内は塗り切られている
        #expect(image[100, 65].red == 255, "扇の内 (媒介変数の角 13°) が抜けている: \(image[100, 65].red)")
    }

    /// 楕円の扇の**輪郭**も、弧の端で止まる。直線の辺の帯は塗り切られたまま。
    ///
    /// 輪郭は塗りと同じ距離場を輪郭の位置で解くので、内外の取り違えは弧の伸びとして
    /// 出る — 弧が中心から見た 45° (媒介変数の角 73°) まで伸びていた ([#1448])。
    ///
    /// [#1448]: https://github.com/mokume-metal/mokume/issues/1448
    @Test("楕円の扇の輪郭は、弧の端より先の楕円の上に出ない")
    func ellipticSectorOutlineStopsAtTheArcEnd() throws {
        let image = try picture(try makeCanvas(width: 170, height: 110)) { canvas in
            canvas.noFill()
            canvas.stroke(white)
            canvas.strokeWeight(2)
            ellipticSector(canvas)
        }
        // 弧の端 (媒介変数の角 45°) より先、媒介変数の角 60°・70° の楕円の上
        for (x, y) in [(85, 94), (64, 97)] {
            #expect(image[x, y].red == 0, "弧の端より先 (\(x), \(y)) に輪郭が出ている: \(image[x, y].red)")
        }
        // 中心から弧の端へ引いた直線の辺の上
        #expect(image[65, 74].red == 255, "直線の辺の帯 (65, 74) が抜けている: \(image[65, 74].red)")
    }

    @Test("巨大な寸法でも数が壊れず、面を覆う")
    func hugeSizesStayFinite() throws {
        func scene(_ canvas: Canvas) throws -> DisplayImage {
            try picture(canvas) { canvas in
                canvas.noStroke()
                canvas.fill(red)
                canvas.circle(48, 48, 1e9)
                canvas.stroke(blue)
                canvas.strokeWeight(3)
                canvas.line(-1e9, 48, 1e9, 48)
            }
        }
        let image = try scene(try makeCanvas())
        #expect(image[10, 10].red == 255)
        #expect(image[90, 90].red == 255)
        #expect(image[48, 48].blue == 255)
        #expect(try scene(try makeCanvas()).bytes == image.bytes)
    }

    @Test("数でない座標と潰れた変換は置かない")
    func unusableInputsAreSkipped() throws {
        let blank = try picture(try makeCanvas()) { _ in }
        let image = try picture(try makeCanvas()) { canvas in
            canvas.fill(white)
            canvas.circle(Float.nan, 48, 20)
            canvas.rect(10, Float.infinity, 20, 20)
            canvas.line(0, 0, Float.nan, 96)
            canvas.push()
            canvas.scale(1, 0)
            canvas.rect(10, 10, 40, 40)
            canvas.circle(48, 48, 40)
            canvas.pop()
        }
        #expect(image.bytes == blank.bytes)
    }

    // MARK: - 他の経路との重なり順

    @Test("三角形の経路を挟んでも、呼び出し順どおりに重なる")
    func orderIsPreservedAcrossRoutes() throws {
        func layered(_ order: [Int]) throws -> (DisplayImage, Int) {
            let canvas = try makeCanvas()
            let image = try picture(canvas) { canvas in
                canvas.noStroke()
                for step in order {
                    switch step {
                    case 0:
                        canvas.fill(red)
                        canvas.circle(48, 48, 60)
                    case 1:
                        // 三角形は従来の経路 (頂点を積む)
                        canvas.fill(green)
                        canvas.triangle(48, 10, 90, 90, 6, 90)
                    default:
                        canvas.fill(blue)
                        canvas.rect(30, 30, 36, 36)
                    }
                }
            }
            return (image, canvas.drawCallsInLastFrame)
        }
        let (forward, forwardCalls) = try layered([0, 1, 2])
        #expect(forward[48, 48].blue == 255)
        #expect(forward[48, 48].red == 0)
        #expect(forwardCalls == 3, "経路が交互に来れば列は 3 つに分かれる")
        let (backward, _) = try layered([2, 1, 0])
        #expect(backward[48, 48].red == 255)
        #expect(backward[48, 48].blue == 0)
    }

    @Test("字を挟んでも、字は基本図形の間に描かれる")
    func textBetweenFormsKeepsItsPlace() throws {
        let canvas = try makeCanvas()
        let image = try picture(canvas) { canvas in
            canvas.noStroke()
            canvas.fill(red)
            canvas.rect(0, 0, 96, 96)
            canvas.fill(white)
            canvas.textSize(60)
            canvas.textAlign(.center, .center)
            canvas.text("█", 48, 48)
            canvas.fill(blue)
            canvas.circle(48, 48, 10)
        }
        #expect(image[48, 48].blue == 255, "最後の円が字の上に出ていない")
        // 字の形は書体に依るので場所は決めない — 白い画素がどこかに出ていればよい
        let hasWhite = (0..<96).contains { y in
            (0..<96).contains { x in image[x, y].green > 200 && image[x, y].blue > 200 }
        }
        #expect(hasWhite, "字が矩形の上に出ていない")
        #expect(canvas.drawCallsInLastFrame == 3, "字の前後で列が分かれていない")
    }

    // MARK: - 保持した形

    @Test("保持した形の円は、直に描いた円と同じ絵になる")
    func retainedFormsMatchDirectDrawing() throws {
        let direct = try picture(try makeCanvas()) { canvas in
            canvas.fill(red)
            canvas.stroke(blue)
            canvas.strokeWeight(3)
            canvas.push()
            canvas.translate(48, 48)
            canvas.rotate(0.4)
            canvas.circle(0, 0, 30)
            canvas.rect(-20, 10, 40, 8)
            canvas.line(-25, -25, 25, -20)
            canvas.pop()
        }
        let canvas = try makeCanvas()
        let retained = try picture(canvas) { canvas in
            let shape = canvas.createShape {
                canvas.fill(red)
                canvas.stroke(blue)
                canvas.strokeWeight(3)
                canvas.circle(0, 0, 30)
                canvas.rect(-20, 10, 40, 8)
                canvas.line(-25, -25, 25, -20)
            }
            // 線は塗りを持たないので、円・矩形とは別の列になる (`fillPresenceSplitsTheRun`)
            #expect(shape.drawCallCount == 2)
            #expect(shape.vertexCount == 0, "基本図形は頂点を持たない")
            canvas.push()
            canvas.translate(48, 48)
            canvas.rotate(0.4)
            canvas.shape(shape)
            canvas.pop()
        }
        #expect(direct.bytes == retained.bytes)
        #expect(canvas.drawCallsInLastFrame == 2)
    }

    /// **保持した形の塗りは、置いた後の大きさで 1 画素より細いかを判定する** ([#1477])。
    ///
    /// 記録したときは幅 4 の `rect` でも、縮めて置けば画面で幅 0.1 になる。細い塗りの枝を
    /// 残した組で描くかは置いた時点で決める (`FormInstance.mayHaveThinFill`) ので、記録した
    /// ときの大きさで決めると、縮めて置いた塗りが縁 1 本の式に戻って濃さが揺れる。
    ///
    /// [#1477]: https://github.com/mokume-metal/mokume/issues/1477
    @Test("保持した形の塗りは、置いた後の大きさで 1 画素より細いかを判定する")
    func retainedThinFillsFollowThePlacedSize() throws {
        let pixels = try coverage(width: 64, height: 64) { canvas in
            let shape = canvas.createShape {
                canvas.noStroke()
                canvas.fill(white)
                canvas.rect(0, 0, 4, 48)
            }
            canvas.push()
            // 画面で幅 0.1・高さ 12。帯の中心が画素の中心 (x = 30.5) に来る
            canvas.translate(30.45, 4)
            canvas.scale(0.025, 0.25)
            canvas.shape(shape)
            canvas.pop()
        }
        let sum = totalSum(pixels)
        #expect(abs(sum - 1.2) <= 0.12, "縮めて置いた幅 0.1 の rect の和: \(sum) (期待 1.2)")
    }

    @Test("組にした形をたくさん置いても、1 列に収まり色掛けが効く")
    func placingManyRetainedFormsStaysInOneCall() throws {
        let canvas = try makeCanvas()
        let image = try picture(canvas) { canvas in
            let dot = canvas.createShape {
                canvas.noStroke()
                canvas.fill(white)
                canvas.circle(0, 0, 8)
            }
            let placements = (0..<200).map { index in
                var placement = Placement(x: 8 + Float(index % 10) * 9, y: 8 + Float(index / 10) * 4)
                placement.fill = index % 2 == 0 ? .linear(red: 1, green: 0, blue: 0) : nil
                return placement
            }
            canvas.shape(dot, at: placements)
        }
        #expect(canvas.drawCallsInLastFrame == 1)
        #expect(canvas.flatVerticesInLastFrame == 0)
        #expect(image[8, 8].red == 255)
        #expect(image[8, 8].green == 0, "置き場所の色が掛かっていない")
        #expect(image[17, 8].green == 255, "色を渡していない置き場所まで染まっている")
    }

    // MARK: - 従来の経路に残るもの

    @Test("貼る絵のある塗りと利用者の断片は、三角形の経路に残る")
    func texturedAndShadedShapesStayOnTriangles() throws {
        let textured = try makeCanvas()
        let image = try textured.createImage(4, 4)
        image.set(0, 0, white)
        _ = try picture(textured) { canvas in
            canvas.texture(image)
            canvas.noStroke()
            for index in 0..<8 { canvas.rect(Float(index) * 10, 10, 8, 8) }
            // 貼る絵は塗りにしか効かないので、線は距離関数の経路でよい
            canvas.stroke(white)
            canvas.line(0, 60, 96, 60)
        }
        #expect(textured.flatVerticesInLastFrame > 0, "貼る絵のある矩形が三角形を積んでいない")
        // 同じ寸法の矩形は #424 の畳みが効き、周は雛形 1 つと 1 つ目のぶんしか組まない
        #expect(textured.flatOutlinesInLastFrame == 2, "貼る絵のある矩形が畳まれていない")
    }

    // MARK: - 並びの取り決め

    /// **色を持つかは旗が決める。** 旗が下りていれば、渡した色も線幅も置き場所に
    /// 残らない — `Optional` を畳んだときに落としやすい所なので名指しで見る ([#771])。
    @Test("旗が下りていれば、渡した色と線幅は置き場所に残らない")
    func flagsDropTheColours() {
        let colour = SIMD4<Float>(0.25, 0.5, 0.75, 1)
        let onlyFill = FormInstance(
            kind: .rect, linear: SIMD4(1, 0, 0, 1), offset: .zero, half: SIMD2(4, 4),
            halfWeight: 3, fill: colour, stroke: colour, fills: true, strokes: false,
            cap: .round, join: .miter)
        #expect(onlyFill.fill == colour)
        #expect(onlyFill.stroke == .zero, "輪郭を持たないのに輪郭の色が残っている")
        #expect(onlyFill.size.z == 0, "輪郭を持たないのに線幅が残っている")
        #expect(onlyFill.meta.w == FormInstance.fillsFlag)

        let onlyStroke = FormInstance(
            kind: .rect, linear: SIMD4(1, 0, 0, 1), offset: .zero, half: SIMD2(4, 4),
            halfWeight: 3, fill: colour, stroke: colour, fills: false, strokes: true,
            cap: .round, join: .miter)
        #expect(onlyStroke.fill == .zero, "塗りを持たないのに塗りの色が残っている")
        #expect(onlyStroke.stroke == colour)
        #expect(onlyStroke.size.z == 3)
        #expect(onlyStroke.meta.w == FormInstance.strokesFlag)
    }

    /// **1 画素より細い塗りの判定は、描く画素での細さで答え、境目の近くは「含む」側に倒す**
    /// ([#1477])。
    ///
    /// 「含む」と答えた図形の列だけが、断片に細い塗りの枝を残した組で描かれる
    /// (`kFormHasThinFill`)。1 画素以上の塗りまで「含む」と答えると速さを失い、細い塗りを
    /// 「含まない」と答えると絵が変わる。境目は断片と同じ 256/258 画素で、その少し外
    /// (1/1024 以内) も「含む」と答える — CPU と GPU の丸めの違いで、断片が枝に入るはずの
    /// 形を見落とさないため。
    ///
    /// [#1477]: https://github.com/mokume-metal/mokume/issues/1477
    @Test("1 画素より細い塗りの判定は、描く画素での細さで答え、境目の近くは含む側に倒す")
    func thinFillJudgementLeansToIncluding() {
        func form(
            _ width: Float, _ height: Float, kind: FormInstance.Kind = .rect,
            linear: SIMD4<Float> = SIMD4(1, 0, 0, 1), fills: Bool = true
        ) -> FormInstance {
            FormInstance(
                kind: kind, linear: linear, offset: SIMD2(10, 10),
                half: SIMD2(width / 2, height / 2), arc: kind == .arc ? SIMD2(0, 1) : .zero,
                halfWeight: 0.5, fill: SIMD4(1, 1, 1, 1), stroke: SIMD4(1, 1, 1, 1),
                fills: fills, strokes: !fills, cap: .round, join: .miter)
        }
        let one = SIMD2<Float>(1, 1)
        // 細かさ 1・変換なし: 幅 1 画素以上は含まない、境目の手前は含む
        #expect(!form(1, 20).mayHaveThinFill(unitsPerDrawnPixel: one), "幅 1 の rect")
        #expect(!form(20, 1).mayHaveThinFill(unitsPerDrawnPixel: one), "高さ 1 の rect")
        #expect(form(0.99, 20).mayHaveThinFill(unitsPerDrawnPixel: one), "幅 0.99 の rect")
        #expect(form(20, 0.1).mayHaveThinFill(unitsPerDrawnPixel: one), "高さ 0.1 の rect")
        // 断片の境目 (256/258) の少し外は、断片では枝に入らないが、判定は含む側に倒す
        let justOutside = Float(256) / 258 * 1.0005
        #expect(
            form(justOutside, 20).mayHaveThinFill(unitsPerDrawnPixel: one),
            "境目の 0.05% 外の rect")
        // 楕円も同じ。扇・塗りの無い形は枝を持たないので含まない
        #expect(!form(1, 20, kind: .ellipse).mayHaveThinFill(unitsPerDrawnPixel: one), "幅 1 の楕円")
        #expect(form(0.5, 0.5, kind: .ellipse).mayHaveThinFill(unitsPerDrawnPixel: one), "直径 0.5 の円")
        #expect(!form(0.5, 0.5, kind: .arc).mayHaveThinFill(unitsPerDrawnPixel: one), "直径 0.5 の扇")
        #expect(
            !form(0.1, 20, fills: false).mayHaveThinFill(unitsPerDrawnPixel: one),
            "塗りの無い幅 0.1 の rect")
        // 拡大の下では画面の大きさで答える: scale(0.25) の幅 4 は画面で 1
        let quarter = SIMD4<Float>(0.25, 0, 0, 0.25)
        #expect(!form(4, 80, linear: quarter).mayHaveThinFill(unitsPerDrawnPixel: one), "scale(0.25) の幅 4")
        #expect(form(3.9, 80, linear: quarter).mayHaveThinFill(unitsPerDrawnPixel: one), "scale(0.25) の幅 3.9")
        // 回しても画面の大きさで答える
        let rotated = SIMD4<Float>(cos(0.5), sin(0.5), -sin(0.5), cos(0.5))
        #expect(!form(1, 40, linear: rotated).mayHaveThinFill(unitsPerDrawnPixel: one), "回した幅 1")
        #expect(form(0.5, 40, linear: rotated).mayHaveThinFill(unitsPerDrawnPixel: one), "回した幅 0.5")
        // 描く細かさ 0.5 では描く画素で答える: 幅 2 は描く画素で 1
        let halfDensity = SIMD2<Float>(2, 2)
        #expect(!form(2, 40).mayHaveThinFill(unitsPerDrawnPixel: halfDensity), "細かさ 0.5 の幅 2")
        #expect(form(1.9, 40).mayHaveThinFill(unitsPerDrawnPixel: halfDensity), "細かさ 0.5 の幅 1.9")
    }
}
