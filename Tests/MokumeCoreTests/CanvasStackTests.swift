// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation
import Testing

@testable import MokumeCore

extension CanvasTests {
    /// 変換・スタイルの積み降ろしと、フレームの外・境目で変換や切り抜き・立体がどうなるか。
    @Suite(
        "積み降ろしとフレームの外",
        .enabled(
            if: RenderDevice.isAvailable,
            "この世代のコマンド構造に対応した GPU が無い実行環境ではスキップする")
    )
    struct StackAndFrame {
        private let black = LinearRGBA.linear(red: 0, green: 0, blue: 0)
        private let white = LinearRGBA.linear(red: 1, green: 1, blue: 1)
        private let blue = LinearRGBA.display(red: 0, green: 0.4, blue: 1)
        private let red = LinearRGBA.display(red: 1, green: 0, blue: 0)

        private func makeCanvas(width: Int = 64, height: Int = 64) throws -> Canvas {
            try CanvasFixture.make(gpu: RenderDevice(), width: width, height: height)
        }

        private func pixels(of canvas: Canvas) throws -> DisplayImage {
            try canvas.target.encodeForDisplay()
        }

        // MARK: - 積み降ろし (#235)

        @Test("変換とスタイルは独立に積める")
        func transformAndStyleStackIndependently() throws {
            let canvas = try makeCanvas()
            try canvas.draw {
                canvas.background(black)
                canvas.noStroke()
                canvas.fill(white)
                canvas.pushMatrix()  // 変換だけ積む
                canvas.translate(20, 20)
                canvas.fill(blue)  // 積んでいないので、戻しても残る
                canvas.popMatrix()
                canvas.rect(8, 8, 16, 16)  // 変換は戻り、塗りは青のまま
            }
            let image = try pixels(of: canvas)
            #expect(image[16, 16].red < 60)  // 青のまま (白なら red が 255)
            #expect(image[16, 16].blue > 200)
            #expect(image[36, 36] == (0, 0, 0, 255))  // 変換が戻っているので、ずれた場所には出ない
        }

        @Test("スタイルだけを積むと、変換は戻らない")
        func styleStackLeavesTheTransformAlone() throws {
            let canvas = try makeCanvas()
            try canvas.draw {
                canvas.background(black)
                canvas.noStroke()
                canvas.pushStyle()
                canvas.fill(blue)
                canvas.translate(20, 20)  // 積んでいないので、戻しても残る
                canvas.popStyle()
                canvas.fill(white)
                canvas.rect(8, 8, 16, 16)
            }
            // 変換が残っているので (28, 28) 起点に出る
            #expect(try pixels(of: canvas)[36, 36].red == 255)
        }

        @Test("両方を積むと、両方が戻る")
        func pushRestoresBothAtOnce() throws {
            let canvas = try makeCanvas()
            try canvas.draw {
                canvas.background(black)
                canvas.noStroke()
                canvas.fill(white)
                canvas.push()
                canvas.translate(20, 20)
                canvas.fill(blue)
                canvas.pop()
                canvas.rect(8, 8, 16, 16)
            }
            let image = try pixels(of: canvas)
            #expect(image[16, 16].red == 255)  // 塗りが白へ戻っている (青なら red が 0)
            #expect(image[36, 36] == (0, 0, 0, 255))  // 変換も戻っている
        }

        @Test("何も積んでいない状態で降ろしても落ちない")
        func poppingAnEmptyStackIsHarmless() throws {
            let canvas = try makeCanvas()
            try canvas.draw {
                canvas.background(black)
                canvas.pop()
                canvas.popMatrix()
                canvas.popStyle()
                canvas.noStroke()
                canvas.fill(white)
                canvas.rect(8, 8, 16, 16)
            }
            #expect(try pixels(of: canvas)[16, 16].red == 255)
        }

        @Test("積んだスタイルは次のフレームへ漏れない")
        func styleDoesNotLeakIntoTheNextFrame() throws {
            // **積んだ履歴はフレームを越えない** (ADR-0021 決定 4 の追補)。スタイルそのもの
            // (塗り) は越えるが、「積んだ」という事実は次のフレームへ渡らない。
            //
            // **この検査は以前、逆のことを見ていた** ([#925]) — 2 フレーム目の `pop()` が
            // 1 フレーム目の値へ戻ることを期待し、「積んだものは残っているが、戻せば
            // 1 フレーム目の手前へ帰る」とコメントまで置いて、`styleStack` だけが越える
            // という割れを契約として固定していた
            //
            // [#925]: https://github.com/mokume-metal/mokume/issues/925
            let canvas = try makeCanvas()
            // 1 フレーム目: 積んだまま降ろさずに終える
            try canvas.draw {
                canvas.background(black)
                canvas.noStroke()
                canvas.push()
                canvas.fill(blue)
                canvas.translate(20, 20)
            }
            // 2 フレーム目: 積んだものはもう無いので、降ろしても何も戻らない
            try canvas.draw {
                canvas.background(black)
                canvas.pop()
                canvas.rect(8, 8, 16, 16)
            }
            let image = try pixels(of: canvas)
            // 塗りは青のまま — **スタイルそのものは越える**ので、1 フレーム目の最後の値が残る
            #expect(image[16, 16].blue > 200)
            #expect(image[16, 16].red < 60)
            #expect(image[36, 36] == (0, 0, 0, 255))  // 変換も (フレームの頭で) 戻っている
        }

        @Test("釣り合わない pushStyle は、毎フレーム積み上がらない")
        func unbalancedPushStyleDoesNotGrow() throws {
            // `Style` は 25 フィールドあり、60 fps で 1 時間積み続ければ 21 万個になる
            // ([#925])。**伸びていないことは絵からは分からない**ので、降ろせるかで見る
            let canvas = try makeCanvas()
            for _ in 0..<3 {
                try canvas.draw {
                    canvas.background(black)
                    canvas.noStroke()
                    canvas.fill(white)
                    canvas.pushStyle()  // 降ろさずに終える
                    canvas.fill(blue)
                }
            }
            // 3 フレームぶん積み上がっていれば、ここで降ろせてしまう
            try canvas.draw {
                canvas.background(black)
                canvas.popStyle()
                canvas.rect(8, 8, 16, 16)
            }
            let image = try pixels(of: canvas)
            #expect(image[16, 16].blue > 200, "前のフレームで積んだスタイルが降ろせてしまう")
            #expect(image[16, 16].red < 60)
        }

        @Test("閉じ忘れた beginShape() は、フレームをまたいで点を積み続けない (#1591)")
        func unclosedShapeDoesNotGrowAcrossFrames() throws {
            // 組み立て中の形はフレームに属する (ADR-0021 決定 4 の追補 (2026-09-27))。直す前は
            // 開いた印が境目で下りず、毎フレームの `vertex()` が同じ形へ積まれ続けた — 何も
            // 描かれないまま、点のぶんだけ記憶が増える ([#1591])。`setup()` で開いた形を模して、
            // フレームの外の持ち越しの区間で開く (頭の側で捨てることを見る)。区間の外では形を
            // 開くこと自体を断る ([#1672])
            //
            // [#1591]: https://github.com/mokume-metal/mokume/issues/1591
            // [#1672]: https://github.com/mokume-metal/mokume/issues/1672
            let canvas = try makeCanvas()
            canvas.carriesOver = true
            canvas.beginShape()
            canvas.carriesOver = false
            for frame in 1...30 {
                var placedInFrame = 0
                try canvas.draw {
                    for index in 0..<1000 {
                        canvas.vertex(Float(index % 64), Float(index / 16))
                    }
                    placedInFrame = canvas.shapePoints.count
                }
                // フレームの中でも積まれていない — 頭で捨てている。終わりだけで捨てると、
                // `setup()` で開いた形に 1 枚目の点が積まれる
                try #require(placedInFrame == 0, "\(frame) 枚目の中で \(placedInFrame) 点が積まれた")
                try #require(!canvas.isBuildingShape, "\(frame) 枚目の後も形が開いたまま")
                try #require(
                    canvas.shapePoints.isEmpty,
                    "\(frame) 枚目の後に \(canvas.shapePoints.count) 点が残っている")
                #expect(canvas.shapeIndices.isEmpty)
                #expect(canvas.shapeHoles.isEmpty)
                #expect(canvas.curveGuides.isEmpty)
                #expect(canvas.holePoints == nil)
            }
            #expect(canvas.warnings.hasWarned(.shapeNotEnded))
            // 捨てた後のフレームの `vertex()` は形の外なので、そちらの注意も言う
            #expect(canvas.warnings.hasWarned(.vertexOutsideShape))
        }

        @Test("フレームをまたいで組んだ形は描かれない (#1591)")
        func shapeBuiltAcrossFramesIsNotDrawn() throws {
            // 1 枚目で開いて 2 点、2 枚目 (塗り直さない) で 1 点足して閉じる。直す前は 2 枚目に
            // 三角形が出ていた — 閉じ忘れた形を、次のフレームが続きとして描いていた
            let canvas = try makeCanvas()
            try canvas.draw {
                canvas.background(black)
                canvas.noStroke()
                canvas.fill(white)
                canvas.beginShape()
                canvas.vertex(4, 4)
                canvas.vertex(60, 4)
            }
            try canvas.draw {
                canvas.vertex(32, 60)
                canvas.endShape(.close)
            }
            let image = try pixels(of: canvas)
            #expect(image[32, 16] == (0, 0, 0, 255), "前のフレームで開いた形が描かれた")
            #expect(canvas.warnings.hasWarned(.shapeNotEnded))
            #expect(canvas.warnings.hasWarned(.shapeNotBegun))
        }

        @Test("push() の片肺が無い — 変換とスタイルは揃って戻らない")
        func pushRestoresNeitherHalfAcrossFrames() throws {
            // 以前は `push()` だけ書いて `pop()` を忘れると、次のフレームで**変換だけ**が
            // 戻り、スタイルは戻らなかった ([#925])。同じ 1 つの呼び出しの結果が、フレームを
            // またいだ瞬間に半分だけ効かなくなる形である
            let canvas = try makeCanvas()
            try canvas.draw {
                canvas.background(black)
                canvas.noStroke()
                canvas.fill(white)
                canvas.push()  // 降ろさずに終える
                canvas.fill(blue)
                canvas.translate(20, 20)
            }
            try canvas.draw {
                canvas.background(black)
                canvas.pop()  // どちらの半分も戻らない
                canvas.rect(8, 8, 16, 16)
            }
            let image = try pixels(of: canvas)
            #expect(image[16, 16].blue > 200, "スタイルだけが戻っている")
            #expect(image[36, 36] == (0, 0, 0, 255), "変換だけが戻っている")
        }

        // MARK: - フレームの外と境目での変換・切り抜き・立体

        @Test("積んだ変換を捨てても、戻す先は残る")
        func resetMatrixKeepsTheStack() throws {
            let canvas = try makeCanvas()
            try canvas.draw {
                canvas.background(black)
                canvas.noStroke()
                canvas.fill(white)
                canvas.translate(30, 30)
                canvas.pushMatrix()
                canvas.resetMatrix()  // いまの変換だけ捨てる
                canvas.rect(4, 4, 8, 8)  // 原点基準で出る
                canvas.popMatrix()
                canvas.rect(4, 4, 8, 8)  // 積んでおいた (30, 30) が戻る
            }
            let image = try pixels(of: canvas)
            #expect(image[8, 8].red == 255)
            #expect(image[38, 38].red == 255)
        }

        // フレームの外で書いた変換・積み降ろし・切り抜きが口ごとに注意して無視されるかは、
        // シーンの記述の口をまとめて回す `SceneOutsideFrameTests` が見る (#941・#925・#1505 の
        // 検査をそこへ畳んだ・#1670)。ここに残すのは絵のほう

        @Test("初期化のときに変換を書いても、絵は変わらない")
        func transformsOutsideAFrameLeaveThePictureAlone() throws {
            // 警告を足したことで**絵まで変わっていない**ことを見る。フレームの外で書いた
            // 変換はもともと `beginFrame()` に捨てられていたので、変わるのは注意の有無だけ
            let plain = try makeCanvas()
            try plain.draw {
                plain.background(black)
                plain.noStroke()
                plain.fill(white)
                plain.rect(8, 8, 16, 16)
            }
            let expected = try pixels(of: plain)

            let written = try makeCanvas()
            written.translate(20, 20)  // フレームの外なので効かない
            written.pushMatrix()
            try written.draw {
                written.background(black)
                written.noStroke()
                written.fill(white)
                written.rect(8, 8, 16, 16)
            }
            #expect(try pixels(of: written).bytes == expected.bytes)
        }

        @Test("斜めに歪めると、まっすぐな辺が傾く")
        func shearTiltsStraightEdges() throws {
            let canvas = try makeCanvas()
            try canvas.draw {
                canvas.background(black)
                canvas.noStroke()
                canvas.fill(white)
                canvas.shearX(Float.pi / 4)  // 45 度なら y のぶんだけ x がずれる
                canvas.rect(8, 8, 8, 24)
            }
            let image = try pixels(of: canvas)
            // y=12 では x が 12 ぶんずれて 20…28 になる。傾いた縁 (20) は滑らかにする領域なので、
            // 1 画素内側を見る
            #expect(image[21, 12].red == 255)
            #expect(image[12, 12].red == 0)  // ずれる前の位置には無い
        }

        @Test("点が変換でどこへ移るかを引ける")
        func screenCoordinatesFollowTheTransform() throws {
            let canvas = try makeCanvas()
            try canvas.draw {
                canvas.translate(20, 10)
                canvas.scale(2, 3)
                #expect(canvas.screenX(5, 5) == 30)  // 20 + 5*2
                #expect(canvas.screenY(5, 5) == 25)  // 10 + 5*3
            }
        }

        @Test("変換と切り抜きは、描き切った後のフレームの外へ残らない (#1472)")
        func transformAndClipDoNotOutliveTheFrame() throws {
            let canvas = try makeCanvas()
            // 描き場所 (`createGraphics`) の入口で描き切る。`draw { }` と同じ `endFrame()` を通る
            canvas.beginDraw()
            canvas.background(black)
            canvas.translate(20, 10)
            canvas.clip(0, 0, 8, 8)
            canvas.endDraw()

            #expect(canvas.screenX(5, 5) == 5)
            #expect(canvas.screenY(5, 5) == 5)
            #expect(canvas.style.clip == nil)
        }

        @Test("endDraw() を忘れた描き場所は、次の beginDraw() が前のフレームを描かずに捨てる (#1622)")
        func beginDrawAgainDropsTheUnfinishedFrame() throws {
            // 描き場所の `beginDraw()` / `endDraw()` も対で開いて閉じる操作で、フレームの中で
            // 釣り合う (ADR-0021 決定 4 の追補 (2026-09-27))。直す前の `beginDraw()` は注意だけで
            // 帰り、閉じ忘れたフレームの変換がそのまま次の描き直しに積み上がった ([#1622])
            //
            // [#1622]: https://github.com/mokume-metal/mokume/issues/1622
            let canvas = try makeCanvas()
            try canvas.draw { canvas.background(black) }

            // 閉じ忘れる 1 枚。置いた図形も、書いた変換も、次へ持ち込まない
            canvas.beginDraw()
            canvas.noStroke()
            canvas.fill(white)
            canvas.rect(40, 40, 8, 8)
            canvas.translate(20, 0)

            canvas.beginDraw()
            canvas.noStroke()
            canvas.fill(white)
            canvas.rect(8, 8, 8, 8)
            canvas.endDraw()

            let image = try pixels(of: canvas)
            #expect(image[12, 12] == (255, 255, 255, 255), "前のフレームの変換が効いている")
            #expect(image[32, 12] == (0, 0, 0, 255), "前のフレームの変換が効いている")
            #expect(image[44, 44] == (0, 0, 0, 255), "閉じ忘れたフレームの図形が描かれた")
            // 捨てたフレームも 1 枚に数える。番号は粒の繰り越しと焼き場の頁が境目の印として読む
            #expect(canvas.framesDrawn == 3, "捨てたフレームと次のフレームが同じ番号になっている")
            #expect(canvas.warnings.message(for: .unfinishedFrameDropped) == unfinishedFrameNotice)
            #expect(!canvas.warnings.hasWarned(.alreadyDrawing), "境目を越えたのに、重ね呼びと言った")
        }

        private let unfinishedFrameNotice =
            "endDraw() was not called for a beginDraw() in an earlier frame, so that frame was "
            + "dropped without being drawn, and drawing starts over from here"

        @Test("endDraw() を忘れた描き場所は、次のフレームが draw { } から来ても捨てる (#1622)")
        func drawAfterForgottenEndDrawDropsTheUnfinishedFrame() throws {
            // 捨てるのは入口 (`beginDraw()`) ではなく、フレームの始まりである。入口にだけ置くと、
            // 閉じ忘れたフレームの図形が `draw { }` の新しいフレームへ黙って合流する
            let canvas = try makeCanvas()
            try canvas.draw { canvas.background(black) }

            canvas.beginDraw()
            canvas.noStroke()
            canvas.fill(white)
            canvas.rect(40, 40, 8, 8)
            canvas.translate(20, 0)

            try canvas.draw {
                canvas.noStroke()
                canvas.fill(white)
                canvas.rect(8, 8, 8, 8)
            }

            let image = try pixels(of: canvas)
            #expect(image[12, 12] == (255, 255, 255, 255), "前のフレームの変換が効いている")
            #expect(image[44, 44] == (0, 0, 0, 255), "閉じ忘れたフレームの図形が描かれた")
            #expect(canvas.warnings.message(for: .unfinishedFrameDropped) == unfinishedFrameNotice)
        }

        /// `draw { }` が開いたフレームの中で呼んだ、フレームを開く・閉じる口。
        enum FrameCallInsideDraw: CaseIterable, CustomTestStringConvertible {
            case beginDraw, endDraw, draw

            var testDescription: String { "\(self)" }

            var notice: String {
                switch self {
                case .beginDraw:
                    "beginDraw(): this canvas is already inside a frame opened by draw { }, which "
                        + "closes it on its own. This call does nothing"
                case .endDraw:
                    "endDraw(): this canvas is inside a frame opened by draw { }, which closes it on "
                        + "its own when the block returns. This call does nothing"
                case .draw:
                    "draw(): this canvas is already inside a frame, so the block runs as part of that "
                        + "frame instead of opening a new one"
                }
            }
        }

        @Test(
            "draw { } の中で呼んだ beginDraw() / endDraw() / draw { } は、そのフレームを開き直さず閉じもしない",
            arguments: FrameCallInsideDraw.allCases)
        func frameCallsInsideDrawKeepTheFrame(_ call: FrameCallInsideDraw) throws {
            // `draw { }` が開いたフレームは、閉包を抜けるときに同じ呼び出しが閉じる。中で開き直すと
            // それまでに描いたものや変換が消え、中で閉じると閉包が戻った後にもう一度描き切って
            // 番号が 2 つ進む。本体の面は `Sketch.canvas` として公開されているので、`draw()` の中から
            // 呼べる (#1622 の反証役の指摘)
            let canvas = try makeCanvas()
            var passesAfterCall: Int?
            try canvas.draw {
                canvas.background(black)
                canvas.noStroke()
                canvas.fill(white)
                canvas.rect(8, 8, 8, 8)
                canvas.translate(20, 0)
                switch call {
                case .beginDraw: canvas.beginDraw()
                case .endDraw: canvas.endDraw()
                case .draw: try? canvas.draw { canvas.rect(8, 30, 8, 8) }
                }
                passesAfterCall = canvas.framesDrawn
                canvas.rect(8, 8, 8, 8)
            }
            let image = try pixels(of: canvas)
            #expect(image[12, 12] == (255, 255, 255, 255), "\(call) がそれまでのフレームを捨てた")
            #expect(image[32, 12] == (255, 255, 255, 255), "\(call) がフレームの変換を戻した")
            if call == .draw {
                #expect(image[32, 34] == (255, 255, 255, 255), "入れ子の draw の中身が同じフレームに描かれない")
            }
            #expect(passesAfterCall == 0, "\(call) がフレームを閉じた")
            #expect(canvas.framesDrawn == 1, "フレームが 2 度閉じた")
            #expect(!canvas.isDrawing)
            #expect(canvas.warnings.message(for: .frameCallInsideDraw) == call.notice)
            #expect(!canvas.warnings.hasWarned(.unfinishedFrameDropped), "閉じ忘れではないのに、捨てたと言った")
        }

        @Test("描き場所で同じ本体のフレームの中に beginDraw() を重ねても、中身を捨てない (#1622)")
        func beginDrawTwiceInOneFrameKeepsTheLayer() throws {
            // 約束が捨てるのは、閉じ忘れたまま境目を越えたフレームである。補助の関数の入れ子などで
            // 同じ本体のフレームの中に重ねただけなら、境目は越えていない。描き場所は本体と時刻の
            // 置き場を共有する (#1467) ので、本体のフレームの番号で見分ける
            let main = try makeCanvas()
            let layer = try main.createGraphics(64, 64)
            try main.draw {
                layer.beginDraw()
                layer.background(black)
                layer.noStroke()
                layer.fill(white)
                layer.rect(8, 8, 8, 8)
                layer.beginDraw()  // 同じ本体のフレームで重ねる
                layer.rect(40, 40, 8, 8)
                layer.endDraw()
            }
            let image = try layer.target.encodeForDisplay()
            #expect(image[12, 12] == (255, 255, 255, 255), "重ねる前に描いたものが消えた")
            #expect(image[44, 44] == (255, 255, 255, 255))
            #expect(layer.framesDrawn == 1)
            #expect(
                layer.warnings.message(for: .alreadyDrawing)
                    == "beginDraw(): endDraw() has not been called yet for the beginDraw() earlier in "
                    + "this frame. This call does nothing, and drawing continues in the frame already open")
            #expect(!layer.warnings.hasWarned(.unfinishedFrameDropped))
        }

        /// 捨てるのは本体の次のフレームの頭である (#1834)。以前は次の `beginDraw()` が捨てていて、
        /// その間に読む口・描き切らせる口が捨てるはずの中身を描いた (口ごとの検査は
        /// `ForgottenLayerFrameTests`)。
        @Test("描き場所で閉じ忘れたまま本体のフレームが進めば、本体のフレームの頭で捨てる (#1622・#1834)")
        func theMainFrameDropsTheLayerLeftOpen() throws {
            let main = try makeCanvas()
            let layer = try main.createGraphics(64, 64)
            try main.draw {
                layer.beginDraw()
                layer.background(black)
                layer.endDraw()
            }
            try main.draw {
                layer.beginDraw()  // 閉じ忘れる
                layer.noStroke()
                layer.fill(white)
                layer.rect(40, 40, 8, 8)
                layer.translate(20, 0)
            }
            try main.draw {
                layer.beginDraw()
                layer.noStroke()
                layer.fill(white)
                layer.rect(8, 8, 8, 8)
                layer.endDraw()
            }
            let image = try layer.target.encodeForDisplay()
            #expect(image[12, 12] == (255, 255, 255, 255), "前のフレームの変換が効いている")
            #expect(image[44, 44] == (0, 0, 0, 255), "閉じ忘れたフレームの図形が描かれた")
            #expect(
                layer.warnings.message(for: .unfinishedFrameDropped)
                    == ForgottenLayerFrameTests.droppedAtMainFrameNotice)
            #expect(!layer.warnings.hasWarned(.alreadyDrawing))
            #expect(layer.framesDrawn == 3, "捨てたフレームを 1 枚に数えていない、または捨て直した")
        }

        @Test("捨てたフレームで積んだ力だけを落とし、前のフレームで積んだ力は残す (#1622)")
        func droppedFrameDropsOnlyItsForces() throws {
            // 力は「次に進めるときにまとめて効く」ので、前のフレームで積んで進めていない力は
            // 捨てたフレームに属さない。捨てたフレームで積んだ力だけを落とす
            let canvas = try makeCanvas()
            let dust = try canvas.makeParticles(count: 8)
            try canvas.draw { canvas.force(dust, [.gravity(0, 1)]) }  // 進めずに終える
            #expect(dust.pendingForceCount == 1)

            canvas.beginDraw()
            canvas.force(dust, [.gravity(0, 2), .drag(0.5)])
            canvas.particles(dust)  // 取り出した後に積んだぶんも落ちる
            canvas.force(dust, [.gravity(0, 3)])
            canvas.beginDraw()  // 閉じ忘れたフレームを捨てる
            #expect(dust.pendingForceCount == 0, "捨てたフレームで積んだ力が残っている")
            canvas.endDraw()

            canvas.beginDraw()
            canvas.force(dust, [.gravity(0, 4)])
            #expect(dust.pendingForceCount == 1)
            canvas.beginDraw()
            #expect(dust.pendingForceCount == 0)
            canvas.force(dust, [.gravity(0, 5)])
            canvas.endDraw()
            try canvas.draw { canvas.force(dust, [.gravity(0, 6)]) }
            canvas.beginDraw()
            canvas.force(dust, [.gravity(0, 7)])
            canvas.beginDraw()
            #expect(dust.pendingForceCount == 2, "前のフレームで積んだ力まで落とした")
            canvas.endDraw()
        }

        @Test("光と周囲は、描き切った後のフレームの外へ残らない (#1504)")
        func lightsAndSurroundingsDoNotOutliveTheFrame() throws {
            let canvas = try makeCanvas()
            canvas.beginDraw()
            canvas.background(black)
            canvas.ambientLight(.linear(red: 0.2, green: 0.2, blue: 0.2))
            canvas.surroundings(.sky)
            canvas.box(10)
            canvas.endDraw()

            #expect(canvas.activeLights.isEmpty)
            #expect(canvas.activeSurroundings == nil)

            // フレームの外で置いて閉じた立体の列は、前のフレームの光も周囲も焼かない。
            // 線は既定で引くので、塗りの列は `box()` の中で稜線の列に閉じられる。
            //
            // **置くのは持ち越しの区間の中** (#1672)。フレームの外で置けるのは、ランタイムが次の
            // フレームを約束する区間 (本体の止まっている間のコールバック) だけで、#1504 の舞台も
            // そこである。区間の外では置かれない (下の検査)
            canvas.carriesOver = true
            canvas.box(10)
            canvas.blendMode(.add)
            canvas.carriesOver = false
            let solids = canvas.batches.filter { $0.source == .solid }
            try #require(!solids.isEmpty)
            for batch in solids {
                #expect(batch.lightRange.isEmpty)
                #expect(batch.surroundings.topAndPresence.w == 0)
            }
        }

        @Test("持ち越しの区間の外では、描き切った後に置いた立体は溜まらず、1 度注意する (#1672)")
        func solidsPlacedOutsideTheRegionsAreRefused() throws {
            let canvas = try makeCanvas()
            canvas.beginDraw()
            canvas.box(10)
            canvas.endDraw()

            canvas.box(10)
            canvas.blendMode(.add)
            #expect(canvas.batches.isEmpty)
            #expect(canvas.solidVertices.isEmpty)
            #expect(canvas.solidInstances.isEmpty)
            #expect(canvas.warnings.hasWarned(.placingOutsideFrame))
        }
    }
}
