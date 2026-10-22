// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation
import Testing

@testable import MokumeCore

extension CanvasTests {
    /// 輪郭 (端・折れ目)・位置の基準・描けない指定・変換・色・描けなかったフレーム。
    @Suite(
        "輪郭・位置・変換・色",
        .enabled(
            if: RenderDevice.isAvailable,
            "この世代のコマンド構造に対応した GPU が無い実行環境ではスキップする")
    )
    struct StrokeAndPlacement {
        private let black = Color.linear(red: 0, green: 0, blue: 0)
        private let white = Color.linear(red: 1, green: 1, blue: 1)

        private func makeCanvas(width: Int = 64, height: Int = 64) throws -> Canvas {
            try CanvasFixture.make(gpu: RenderDevice(), width: width, height: height)
        }

        private func pixels(of canvas: Canvas) throws -> DisplayImage {
            try canvas.target.encodeForDisplay()
        }

        // MARK: - 輪郭 (#234)

        private let blue = Color.display(red: 0, green: 0.4, blue: 1)
        private let red = Color.display(red: 1, green: 0, blue: 0)

        @Test("図形は塗りと輪郭の両方を出す")
        func shapesCarryBothFillAndStroke() throws {
            let canvas = try makeCanvas()
            try canvas.draw {
                canvas.background(black)
                canvas.fill(blue)
                canvas.stroke(red)
                canvas.strokeWeight(4)
                canvas.rect(16, 16, 32, 32)
            }
            let image = try pixels(of: canvas)
            #expect(image[32, 32].blue > 200)  // 内側は塗りの色
            #expect(image[16, 32].red > 200)  // 縁は線の色
            #expect(image[16, 32].blue < 60)
        }

        @Test("塗りを止めると輪郭だけが残る")
        func noFillLeavesOnlyTheOutline() throws {
            let canvas = try makeCanvas()
            try canvas.draw {
                canvas.background(black)
                canvas.fill(blue)
                canvas.noFill()
                canvas.stroke(red)
                canvas.strokeWeight(4)
                canvas.rect(16, 16, 32, 32)
            }
            let image = try pixels(of: canvas)
            #expect(image[32, 32] == (0, 0, 0, 255))  // 内側は背景のまま
            #expect(image[16, 32].red > 200)  // 縁は残る
        }

        @Test("線を止めると塗りだけが残る")
        func noStrokeLeavesOnlyTheFill() throws {
            let canvas = try makeCanvas()
            try canvas.draw {
                canvas.background(black)
                canvas.fill(blue)
                canvas.stroke(red)
                canvas.noStroke()
                canvas.strokeWeight(4)
                canvas.rect(16, 16, 32, 32)
            }
            let image = try pixels(of: canvas)
            #expect(image[32, 32].blue > 200)
            #expect(image[16, 32].red < 60)  // 縁に線の色は無い
        }

        @Test("塗りの色を指定し直すと、止めた塗りが戻る")
        func fillResumesWhenAColorIsGivenAgain() throws {
            let canvas = try makeCanvas()
            try canvas.draw {
                canvas.background(black)
                canvas.noFill()
                canvas.fill(blue)  // 呼んだ時点でまた塗るようになる
                canvas.noStroke()
                canvas.rect(16, 16, 32, 32)
            }
            #expect(try pixels(of: canvas)[32, 32].blue > 200)
        }

        // MARK: - 端の形

        /// 太さ 12 の線を (10, 32)-(50, 32) に引いたときの、端の外の画素。
        private func endOfThickLine(cap: StrokeCap, probe: (x: Int, y: Int)) throws -> UInt8 {
            let canvas = try makeCanvas()
            try canvas.draw {
                canvas.background(black)
                canvas.stroke(white)
                canvas.strokeWeight(12)
                canvas.strokeCap(cap)
                canvas.line(10, 32, 50, 32)
            }
            return try pixels(of: canvas)[probe.x, probe.y].red
        }

        @Test("端を切る形は、線の長さちょうどで止まる")
        func squareCapStopsAtTheGivenLength() throws {
            #expect(try endOfThickLine(cap: .square, probe: (52, 32)) == 0)
            #expect(try endOfThickLine(cap: .square, probe: (48, 32)) == 255)
        }

        @Test("出っ張らせる形は、太さの半分だけ伸びる")
        func projectCapExtendsByHalfTheWeight() throws {
            #expect(try endOfThickLine(cap: .project, probe: (52, 32)) == 255)  // 56 まで伸びる
            #expect(try endOfThickLine(cap: .project, probe: (58, 32)) == 0)
        }

        @Test("丸める形は、四角い端では届く角に届かない")
        func roundCapCutsTheCorners() throws {
            // (55, 37) は中心 (50, 32) から 7.1 画素 — 半径 6 の円の 1 画素外、四角の 1 画素内。
            // 縁の上 (6.4 画素の (55, 36)) は滑らかにする領域なので見ない (ADR-0019 決定 4)
            #expect(try endOfThickLine(cap: .round, probe: (55, 37)) == 0)
            #expect(try endOfThickLine(cap: .project, probe: (55, 37)) == 255)
            #expect(try endOfThickLine(cap: .round, probe: (54, 32)) == 255)  // 真横は円の内
        }

        // MARK: - 折れ目の形

        /// 直角に折れた線の、外側の角の画素。
        private func outerCornerOfBend(join: StrokeJoin) throws -> UInt8 {
            let canvas = try makeCanvas()
            try canvas.draw {
                canvas.background(black)
                canvas.noFill()
                canvas.stroke(white)
                canvas.strokeWeight(12)
                canvas.strokeJoin(join)
                // 直角の角を持つ閉じた形
                canvas.rect(20, 20, 24, 24)
            }
            // 左上の角の、いちばん外側 (角から 6 画素ぶん外へ)
            return try pixels(of: canvas)[15, 15].red
        }

        @Test("角を丸めると、四角い角には出る画素が出ない")
        func roundJoinCutsTheOuterCorner() throws {
            #expect(try outerCornerOfBend(join: .round) == 0)
            #expect(try outerCornerOfBend(join: .miter) == 255)
        }

        @Test("削ぐ形は矩形の角を落とし、尖らせる形は残す")
        func bevelCutsTheCornerAndMiterKeepsIt() throws {
            // 矩形の角は 3 つの折れ目の形が区別される。距離関数の経路は式で削ぎ (#752)、
            // 三角形の経路も矩形の角だけは同じ線で削ぐ (#1506・下の
            // `triangleRectCornersFollowTheJoin`)。任意多角形の折れ目も、2 本の帯の向きから決まる
            // 同じ形で埋める (#1644・`PolylineJoinTests`)
            #expect(try outerCornerOfBend(join: .bevel) == 0)
            #expect(try outerCornerOfBend(join: .miter) == 255)
        }

        /// 矩形を三角形の経路へ乗せる手立て。
        nonisolated enum RectRoute: CaseIterable, CustomTestStringConvertible, Sendable {
            /// 断片を付ける (`shader()`)。1 つだけなので畳まない
            case shaded
            /// 同じ矩形を断片付きで 2 つ重ねる。2 つ目で畳みの雛形が開く
            case shadedFolded
            /// 絵を貼って塗る (`texture()`)。輪郭と同居するので畳まない
            case textured

            var testDescription: String {
                switch self {
                case .shaded: "断片を付けた"
                case .shadedFolded: "断片を付けて畳んだ"
                case .textured: "絵を貼って塗る"
                }
            }
        }

        /// 三角形の経路の矩形の角も、距離関数の経路と同じ線で削ぐ (#1506)。形と探針は
        /// `FormShapeTests.rectangleCornersFollowTheJoin` と同じで、削ぎ線は角から太さの半分だけ
        /// 離れた所を通る 45° の線。かつては `bevel` でも `miter` と同じ正方形で角を埋め、
        /// `shader()` / `texture()` を 1 行足しただけで矩形の角が尖っていた。
        @Test("三角形の経路で描く矩形も、削ぐ形は角を 45° で落とし、尖らせる形は残す", arguments: RectRoute.allCases)
        func triangleRectCornersFollowTheJoin(_ route: RectRoute) throws {
            func corner(_ join: StrokeJoin) throws -> DisplayImage {
                let canvas = try makeCanvas(width: 96, height: 96)
                var failure: (any Error)?
                try canvas.draw {
                    canvas.background(black)
                    canvas.stroke(white)
                    canvas.strokeWeight(12)
                    canvas.strokeJoin(join)
                    do {
                        switch route {
                        case .shaded, .shadedFolded:
                            canvas.noFill()
                            canvas.shader(try canvas.makeShader("float4 paint(Fragment in, Values values) { return in.color; }"))
                        case .textured:
                            // 絵の中身は問わない。塗りに絵が付いていることだけが経路を決める
                            canvas.texture(try canvas.createImage(1, 1))
                            canvas.fill(black)
                        }
                    } catch { failure = error }
                    canvas.rect(20, 20, 40, 40)
                    if route == .shadedFolded { canvas.rect(20, 20, 40, 40) }
                }
                if let failure { throw failure }
                return try pixels(of: canvas)
            }
            // 外縁は 14…66。角 (15, 15) は尖らせたときだけ塗られる
            #expect(try corner(.miter)[15, 15].red == 255)
            #expect(try corner(.bevel)[15, 15].red == 0, "削いだ角が尖っている")
            // 削いだ角は 45° の直線。(19, 19) は削ぎ線の内側
            #expect(try corner(.bevel)[19, 19].red == 255)
            // 内縁はどちらの形でも直角 (帯が重なる)
            for join in [StrokeJoin.miter, .bevel] {
                let image = try corner(join)
                #expect(image[27, 27].red == 0, "\(join): 内縁の角の内側が塗られている")
                #expect(image[25, 25].red == 255, "\(join): 内縁の角が欠けている")
            }
        }

        @Test("閉じた図形の輪郭に隙間が無い")
        func closedOutlinesHaveNoGaps() throws {
            let canvas = try makeCanvas()
            try canvas.draw {
                canvas.background(black)
                canvas.noFill()
                canvas.stroke(white)
                canvas.strokeWeight(6)
                canvas.strokeJoin(.bevel)
                canvas.triangle(32, 12, 52, 48, 12, 48)
            }
            let image = try pixels(of: canvas)
            // 3 つの頂点そのものが塗られている (帯を線分ごとに置くだけだと角が欠ける)
            #expect(image[32, 12].red == 255)
            #expect(image[52, 48].red == 255)
            #expect(image[12, 48].red == 255)
        }

        // MARK: - 描けない線

        @Test("太さを持たない線は何も描かない", arguments: [0, -4] as [Float])
        func linesWithoutWeightDrawNothing(_ weight: Float) throws {
            let canvas = try makeCanvas()
            try canvas.draw {
                canvas.background(black)
                canvas.stroke(white)
                canvas.strokeWeight(weight)
                canvas.line(8, 32, 56, 32)
                canvas.point(32, 8)
            }
            let image = try pixels(of: canvas)
            #expect(image[32, 32] == (0, 0, 0, 255))
            #expect(image[32, 8] == (0, 0, 0, 255))
        }

        @Test("長さのない線でも落ちず、端の形だけが残る")
        func zeroLengthLineLeavesOnlyItsCaps() throws {
            let canvas = try makeCanvas()
            try canvas.draw {
                canvas.background(black)
                canvas.stroke(white)
                canvas.strokeWeight(10)
                canvas.strokeCap(.round)
                canvas.line(32, 32, 32, 32)  // 同じ点
            }
            // 帯は出ないが、端の形は両端ぶん置かれる
            #expect(try pixels(of: canvas)[32, 32].red == 255)
        }

        // MARK: - 位置の基準

        @Test("読み方が違えば、同じ矩形を別の引数で書ける")
        func everyRectModeCanExpressTheSameRectangle() throws {
            // どれも左上 (20, 20) から 20x20 を指す
            let cases: [(ShapeMode, (Float, Float, Float, Float))] = [
                (.corner, (20, 20, 20, 20)),
                (.corners, (20, 20, 40, 40)),
                (.center, (30, 30, 20, 20)),
                (.radius, (30, 30, 10, 10)),
            ]
            var images: [DisplayImage] = []
            for (mode, args) in cases {
                let canvas = try makeCanvas()
                try canvas.draw {
                    canvas.background(black)
                    canvas.fill(white)
                    canvas.rectMode(mode)
                    canvas.rect(args.0, args.1, args.2, args.3)
                }
                images.append(try pixels(of: canvas))
            }
            for image in images.dropFirst() {
                #expect(image.bytes == images[0].bytes)
            }
            #expect(images[0][25, 25] == (255, 255, 255, 255))
            #expect(images[0][45, 45] == (0, 0, 0, 255))
        }

        @Test("同じ引数でも、読み方が変われば別の場所に出る")
        func theSameArgumentsLandElsewhereUnderAnotherMode() throws {
            let corner = try makeCanvas()
            try corner.draw {
                corner.background(black)
                corner.fill(white)
                corner.rect(20, 20, 20, 20)  // 既定 = corner
            }
            let center = try makeCanvas()
            try center.draw {
                center.background(black)
                center.fill(white)
                center.rectMode(.center)
                center.rect(20, 20, 20, 20)  // 中心 (20, 20) なので左上へ寄る
            }
            #expect(try pixels(of: corner)[36, 36] == (255, 255, 255, 255))
            #expect(try pixels(of: center)[36, 36] == (0, 0, 0, 255))
            #expect(try pixels(of: center)[14, 14] == (255, 255, 255, 255))
        }

        @Test("楕円の読み方は円にも効く")
        func circleFollowsTheEllipseMode() throws {
            let canvas = try makeCanvas()
            try canvas.draw {
                canvas.background(black)
                canvas.fill(white)
                canvas.ellipseMode(.radius)
                canvas.circle(32, 32, 10)  // 半径として読むので直径 20
            }
            let image = try pixels(of: canvas)
            #expect(image[32, 32] == (255, 255, 255, 255))
            #expect(image[40, 32] == (255, 255, 255, 255))  // 半径 10 の内側
            #expect(image[32, 46] == (0, 0, 0, 255))  // 外側
        }

        // MARK: - 描けない指定

        @Test("角度が逆向きの円弧は何も描かない")
        func reversedArcDrawsNothing() throws {
            let canvas = try makeCanvas()
            try canvas.draw {
                canvas.background(black)
                canvas.fill(white)
                canvas.arc(32, 32, 40, 40, Float.pi, 0)
            }
            let image = try pixels(of: canvas)
            for y in stride(from: 0, to: 64, by: 8) {
                for x in stride(from: 0, to: 64, by: 8) {
                    #expect(image[x, y] == (0, 0, 0, 255))
                }
            }
        }

        @Test("大きさを持たない図形は何も描かない", arguments: [0, -20] as [Float])
        func degenerateShapesDrawNothing(_ size: Float) throws {
            let canvas = try makeCanvas()
            try canvas.draw {
                canvas.background(black)
                canvas.fill(white)
                canvas.rect(20, 20, size, size)
                canvas.circle(32, 32, size)
                canvas.ellipse(32, 32, size, 20)
            }
            let image = try pixels(of: canvas)
            for y in stride(from: 0, to: 64, by: 8) {
                for x in stride(from: 0, to: 64, by: 8) {
                    #expect(image[x, y] == (0, 0, 0, 255))
                }
            }
        }

        // MARK: - 図形

        @Test("矩形は指定した場所に、指定した大きさで出る")
        func rectangleLandsWhereItWasAsked() throws {
            let canvas = try makeCanvas()
            try canvas.draw {
                canvas.background(black)
                canvas.fill(white)
                canvas.noStroke()  // ここで見るのは塗りの位置と大きさ
                canvas.rect(10, 20, 4, 8)
            }

            let image = try pixels(of: canvas)
            // 内側の 4x8 が塗られている
            for y in 20..<28 {
                for x in 10..<14 {
                    #expect(image[x, y].red == 255, "(\(x), \(y)) が塗られていない")
                }
            }
            // 1 画素外は塗られていない
            #expect(image[9, 24].red == 0)
            #expect(image[14, 24].red == 0)
            #expect(image[12, 19].red == 0)
            #expect(image[12, 28].red == 0)
        }

        @Test("円は中心が指定した場所で、直径ぶんの広がりを持つ")
        func circleIsCenteredWhereItWasAsked() throws {
            let canvas = try makeCanvas()
            try canvas.draw {
                canvas.background(black)
                canvas.fill(white)
                canvas.circle(32, 32, 20)
            }

            let image = try pixels(of: canvas)
            #expect(image[32, 32].red == 255)
            // 半径 10 の内側と外側
            #expect(image[32 + 8, 32].red == 255)
            #expect(image[32, 32 - 8].red == 255)
            #expect(image[32 + 12, 32].red == 0)
            #expect(image[32, 32 + 12].red == 0)
        }

        @Test("太さ 1 の線は、整数の座標では 1 画素に収まる")
        func hairlineCoversExactlyOneColumn() throws {
            // 座標の約束のうち、線を半画素寄せているかを見る検査 (ADR-0039 決定 2)。
            // 寄せが無いと、縁が画素の中心に乗って隣の列が塗られるか 2 列にまたがる。
            // 経路ごとの寄せは `PixelGridTests.strokesSitOnPixelCenters` が見る
            let canvas = try makeCanvas()
            try canvas.draw {
                canvas.background(black)
                canvas.stroke(white)
                canvas.strokeWeight(1)
                canvas.line(10, 0, 10, 64)
            }

            let image = try pixels(of: canvas)
            #expect(image[10, 32].red == 255, "指定した列が塗られていない")
            #expect(image[9, 32].red == 0, "左隣まで塗られている")
            #expect(image[11, 32].red == 0, "右隣まで塗られている")
        }

        @Test("線の太さは指定した画素数になる")
        func strokeWeightWidensTheLine() throws {
            let canvas = try makeCanvas()
            try canvas.draw {
                canvas.background(black)
                canvas.stroke(white)
                canvas.strokeWeight(4)
                canvas.line(20, 0, 20, 64)
            }

            let image = try pixels(of: canvas)
            // 太さ 4 の帯は 18.5…22.5 を覆う。偶数の太さは整数の座標では両端の画素に半分ずつ
            // 掛かる (線の中心は画素の中心に乗るので)。覆いの合計が 4 画素ぶんであることを見る
            let covered = (0..<64).map { Double(image[$0, 32].red) }
            let outside = (0..<64).filter { $0 < 18 || $0 > 22 }.map { Double(image[$0, 32].red) }
            #expect(outside.allSatisfy { $0 == 0 }, "帯の外が塗られている")
            #expect(image[20, 32].red == 255)
            #expect(image[19, 32].red == 255)
            #expect(image[21, 32].red == 255)
            #expect(image[18, 32].red == image[22, 32].red, "両端の覆いが対称でない")
            #expect(image[18, 32].red > 0 && image[18, 32].red < 255, "両端は半分だけ覆われる")
            // 線形の覆いの合計 (出力段の変換を戻す)
            let total = covered.map { TransferFunction.decode(Float($0 / 255)) }.reduce(0, +)
            #expect(abs(total - 4) < 0.05, "覆いの合計が太さと合わない: \(total)")
        }

        // MARK: - 変換

        @Test("平行移動は図形をずらす")
        func translateMovesShapes() throws {
            let canvas = try makeCanvas()
            try canvas.draw {
                canvas.background(black)
                canvas.fill(white)
                canvas.translate(10, 5)
                canvas.rect(0, 0, 4, 4)
            }

            let image = try pixels(of: canvas)
            #expect(image[10, 5].red == 255)
            #expect(image[13, 8].red == 255)
            #expect(image[0, 0].red == 0)
        }

        @Test("拡大は図形を伸ばす")
        func scaleStretchesShapes() throws {
            let canvas = try makeCanvas()
            try canvas.draw {
                canvas.background(black)
                canvas.fill(white)
                canvas.noStroke()  // ここで見るのは塗りの伸び方
                canvas.scale(4, 1)
                canvas.rect(2, 10, 2, 4)
            }

            let image = try pixels(of: canvas)
            // x は 4 倍されて 8…15、y は変わらず 10…13
            #expect(image[8, 11].red == 255)
            #expect(image[15, 11].red == 255)
            #expect(image[16, 11].red == 0)
            #expect(image[8, 14].red == 0)
        }

        @Test("積んだ変換へ戻せる")
        func pushAndPopRestoreTheTransform() throws {
            let canvas = try makeCanvas()
            try canvas.draw {
                canvas.background(black)
                canvas.fill(white)
                canvas.push()
                canvas.translate(30, 30)
                canvas.rect(0, 0, 4, 4)
                canvas.pop()
                // 戻したので、次の矩形は原点に出る
                canvas.rect(0, 0, 4, 4)
            }

            let image = try pixels(of: canvas)
            #expect(image[31, 31].red == 255)
            #expect(image[1, 1].red == 255)
        }

        @Test("積んでいないのに戻しても壊れない")
        func popWithoutPushIsHarmless() throws {
            let canvas = try makeCanvas(width: 8, height: 8)
            try canvas.draw {
                canvas.background(black)
                canvas.pop()
                canvas.fill(white)
                canvas.rect(0, 0, 8, 8)
            }
            #expect(try pixels(of: canvas)[4, 4].red == 255)
        }

        // MARK: - 色

        @Test("見た目で指定した色は、sRGB から作業空間へ移した色として出る")
        func displayColorSurvivesTheRoundTrip() throws {
            // 入口は転送関数を外して原色を Display P3 へ移し、出口は転送関数だけを掛ける
            // (ADR-0011 決定 3)。だから書き出しのバイト列は、sRGB の色を Display P3 で書き直した
            // ものになる。期待値は CoreGraphics に同じ変換をさせて導く (ADR-0019 決定 4 の改訂)。
            //
            // **ぴたりとは戻らない。** 途中の作業空間は半精度浮動小数なので、線形へ
            // 落として戻す間に最下位の桁が動く。8 bit にした後の許容を 1 段に取るのは
            // そのため — ここを 0 段にすると、精度の話でしか落ちない検査になる。
            for (red, green, blue) in [(0.25, 0.5, 0.75), (204.0 / 255, 153.0 / 255, 0)] {
                let canvas = try makeCanvas(width: 4, height: 4)
                try canvas.draw {
                    canvas.background(.display(red: Float(red), green: Float(green), blue: Float(blue)))
                }

                let pixel = try pixels(of: canvas)[0, 0]
                let expected = SRGBReference.writtenBytes(red: red, green: green, blue: blue)
                #expect(abs(Int(pixel.red) - Int(expected.0)) <= 1)
                #expect(abs(Int(pixel.green) - Int(expected.1)) <= 1)
                #expect(abs(Int(pixel.blue) - Int(expected.2)) <= 1)
                #expect(pixel.alpha == 255)
            }
        }

        @Test("半透明の図形は下の色と混ざる")
        func translucentShapesBlendWithWhatIsBelow() throws {
            let canvas = try makeCanvas(width: 8, height: 8)
            try canvas.draw {
                canvas.background(black)
                canvas.fill(Color(straightRed: 1, green: 1, blue: 1, alpha: 0.5))
                canvas.rect(0, 0, 8, 8)
            }

            // 線形で 0.5 の灰色 → 出力段を経て 188
            #expect(try pixels(of: canvas)[4, 4] == (188, 188, 188, 255))
        }

        // MARK: - 描けなかったフレーム (#342)

        @Test("描けなかったフレームに置いたものは、次のフレームへ残らない")
        func nothingPlacedInAFailedFrameSurvivesIntoTheNext() throws {
            let canvas = try makeCanvas(width: 8, height: 8)
            // 描ける状態から始める。以降の絵はこの黒が下地になる
            try canvas.draw { canvas.background(black) }

            // 描けないフレームで、塗り直しの予定と図形を置く。`.timedOut` は製品でも
            // 通る経路 (GPU が混んだとき `commitAndWait` が諦める) で、そこを検査から作る
            canvas.failureForTesting = .timedOut(seconds: 5)
            #expect(throws: RenderFailure.self) {
                try canvas.draw {
                    canvas.background(self.white)
                    canvas.fill(self.white)
                    canvas.rect(2, 2, 4, 4)
                }
            }

            // **次のフレームには何も置かない。** 持ち越しが無ければ描くものが 1 つも
            // 無く、下地の黒がそのまま残る
            canvas.failureForTesting = nil
            try canvas.draw {}

            let image = try pixels(of: canvas)
            for y in 0..<8 {
                for x in 0..<8 {
                    #expect(image[x, y] == (0, 0, 0, 255))
                }
            }
        }

        @Test("描けないフレームが続いても、溜めたものは積み上がらない")
        func repeatedFailuresDoNotPileUp() throws {
            let canvas = try makeCanvas(width: 8, height: 8)
            canvas.failureForTesting = .encoderUnavailable
            for _ in 0..<20 {
                #expect(throws: RenderFailure.self) {
                    try canvas.draw {
                        canvas.fill(self.white)
                        canvas.rect(0, 0, 8, 8)
                        // 番号で読む立体も置く。**番号の並びは頂点とは別の溜め場**なので、
                        // 片方だけ捨てても絵には出ない — フレーム数に比例して伸びるだけ
                        canvas.beginShape(.triangles)
                        canvas.normal(0, 0, 1)
                        canvas.vertex(0, 0, 1)
                        canvas.vertex(8, 0, 1)
                        canvas.vertex(8, 8, 1)
                        canvas.vertex(0, 8, 1)
                        for number in [0, 1, 2, 0, 2, 3] { canvas.index(number) }
                        canvas.endShape()
                    }
                }
            }

            // **ここだけは絵ではなく溜め場を見る。** 「積み上がらない」は描かれなかった
            // ものの話なので、どのフレームの絵にも現れない
            #expect(canvas.vertices.isEmpty)
            #expect(canvas.solidVertices.isEmpty)
            #expect(canvas.solidIndices.isEmpty)
            #expect(canvas.batches.isEmpty)
        }
    }
}
