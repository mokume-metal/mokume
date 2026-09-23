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
    private func coverage(
        width: Int = 160, height: Int = 160, _ body: (Canvas) -> Void
    ) throws -> PixelBuffer {
        let canvas = try makeCanvas(width: width, height: height)
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
}
