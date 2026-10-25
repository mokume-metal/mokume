// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation
import Testing

@testable import MokumeCore

extension CanvasTests {
    /// 閉包で戻す `push { }` と、積み降ろしの不釣り合いの注意 (#2399)。
    @Suite(
        "閉包で戻す push { } と、対の無い積み降ろしの注意",
        .enabled(
            if: RenderDevice.isAvailable,
            "この世代のコマンド構造に対応した GPU が無い実行環境ではスキップする")
    )
    struct PushClosure {
        private let black = LinearRGBA.linear(red: 0, green: 0, blue: 0)
        private let white = LinearRGBA.linear(red: 1, green: 1, blue: 1)
        private let blue = LinearRGBA.display(red: 0, green: 0.4, blue: 1)

        private struct Thrown: Error {}

        private func makeCanvas() throws -> Canvas {
            try CanvasFixture.make(gpu: RenderDevice(), width: 64, height: 64)
        }

        private func translated(_ x: Float, _ y: Float) -> Transform {
            var transform = Transform.identity
            transform.translate(x: x, y: y)
            return transform
        }

        // MARK: - 戻す

        /// #2399 の本文の `flower(visible:)`。部品が閉包の中で早期 `return` しても、後に描く四角は
        /// `visible` の真偽によらず、部品の前の位置と塗りで描かれる。
        @Test("閉包の中で早期 return しても、後の図形へ移動と塗りが漏れない", arguments: [false, true])
        func earlyReturnStillRestores(visible: Bool) throws {
            let canvas = try makeCanvas()
            try canvas.draw {
                canvas.background(black)
                canvas.noStroke()
                canvas.fill(white)
                canvas.push {
                    canvas.translate(20, 20)
                    canvas.fill(blue)
                    guard visible else { return }
                    canvas.rect(36, 36, 4, 4)  // (56, 56) に置く。下で見る画素には掛からない
                }
                canvas.rect(8, 8, 16, 16)
            }
            let image = try canvas.target.encodeForDisplay()
            #expect(image[16, 16].red == 255, "塗りが戻っていない (青なら red が 0)")
            #expect(image[36, 36] == (0, 0, 0, 255), "移動が戻っていない")
        }

        @Test("閉包が投げたら、戻してから同じエラーが届き、投げて飛ばした対は積み忘れと言わない")
        func thrownErrorArrivesAfterRestoring() throws {
            let canvas = try makeCanvas()
            var caught: (any Error)?
            var transformWhenCaught: Transform?
            var fillWhenCaught: LinearRGBA?
            try canvas.draw {
                canvas.background(black)
                canvas.fill(white)
                do {
                    try canvas.push {
                        canvas.translate(20, 20)
                        canvas.fill(blue)
                        canvas.push()  // 投げて、対の pop() を飛ばす
                        throw Thrown()
                    }
                } catch {
                    caught = error
                    transformWhenCaught = canvas.transform
                    fillWhenCaught = canvas.style.fill
                }
            }
            #expect(caught is Thrown)
            #expect(transformWhenCaught == .identity, "受け取った時点で移動が戻っていない")
            #expect(fillWhenCaught == white, "受け取った時点で塗りが戻っていない")
            #expect(!canvas.warnings.hasWarned(.pushLeftOpen), "投げて飛ばした対を、積み忘れと言った")
        }

        @Test("入れ子の push { } から戻った状態は、同じ並びを push()・pop() で対にした状態と同じ")
        func nestedClosuresMatchPairedCalls() throws {
            typealias State = (transform: Transform, fill: LinearRGBA)
            func states(closures: Bool) throws -> [State] {
                let canvas = try makeCanvas()
                var seen: [State] = []
                func note() { seen.append((canvas.transform, canvas.style.fill)) }
                func scoped(_ body: () -> Void) {
                    if closures {
                        canvas.push(body)
                    } else {
                        canvas.push()
                        body()
                        canvas.pop()
                    }
                }
                try canvas.draw {
                    canvas.translate(5, 0)
                    canvas.fill(blue)
                    scoped {
                        canvas.translate(10, 3)
                        canvas.fill(white)
                        scoped {
                            canvas.scale(2, 2)
                            canvas.fill(black)
                            note()
                        }
                        note()
                    }
                    note()
                }
                return seen
            }
            let byClosure = try states(closures: true)
            let byPairs = try states(closures: false)
            #expect(byClosure.count == 3)
            for (closure, pairs) in zip(byClosure, byPairs) {
                #expect(closure.transform == pairs.transform)
                #expect(closure.fill == pairs.fill)
            }
            #expect(byClosure.last?.transform == translated(5, 0))
        }

        @Test("閉包の中の余分な pop() は、外で積んだ段を取らない")
        func extraPopInsideTheClosureLeavesOuterLevels() throws {
            let canvas = try makeCanvas()
            var afterClosure: Transform?
            var afterOuterPop: Transform?
            try canvas.draw {
                canvas.translate(3, 0)
                canvas.push()  // 外で積む (3, 0)
                canvas.translate(7, 0)
                canvas.push { canvas.pop() }  // 中に積んだ段は無い
                afterClosure = canvas.transform
                canvas.pop()
                afterOuterPop = canvas.transform
            }
            #expect(afterClosure == translated(10, 0), "閉包が戻す先が変わった")
            #expect(afterOuterPop == translated(3, 0), "閉包の中の pop() が外の段を取った")
            #expect(canvas.warnings.hasWarned(.popWithoutPush))
        }

        @Test("本体の中で描き場所のフレームを閉じて開き直したら、閉じたフレームの状態を書き戻さない")
        func closedFrameIsNotWrittenBack() throws {
            let canvas = try makeCanvas()
            canvas.beginDraw()
            canvas.translate(20, 20)
            canvas.push {
                canvas.translate(5, 5)
                canvas.endDraw()
                canvas.beginDraw()
                canvas.translate(1, 1)
            }
            let afterClosure = canvas.transform
            canvas.endDraw()
            #expect(afterClosure == translated(1, 1), "閉じたフレームの移動を、次のフレームへ書き戻した")
        }

        @Test("フレームの外では注意して、本体だけを走らせる")
        func outsideAFrameTheBodyStillRuns() throws {
            let canvas = try makeCanvas()
            var ran = 0
            canvas.push { ran += 1 }
            #expect(ran == 1)
            #expect(canvas.warnings.hasWarned(.transformOutsideFrame))
        }

        // MARK: - 対の無い積み降ろしの注意

        @Test("戻す段の無い降ろしは、呼んだ行を名指して 1 度だけ注意する")
        func popWithoutPushNamesTheLine() throws {
            let canvas = try makeCanvas()
            var poppedAt: UInt = 0
            try canvas.draw {
                canvas.popMatrix(); poppedAt = #line
                canvas.pop()
                canvas.popStyle()
            }
            let message = try #require(canvas.warnings.message(for: .popWithoutPush))
            #expect(message.contains("popMatrix() at MokumeCoreTests/PushClosureTests.swift:\(poppedAt)"), "\(message)")
        }

        @Test("変換だけ積んで pop() で戻すのは、対の無い降ろしではない")
        func popAfterPushMatrixIsNotUnmatched() throws {
            let canvas = try makeCanvas()
            try canvas.draw {
                canvas.pushMatrix()
                canvas.pop()
            }
            #expect(!canvas.warnings.hasWarned(.popWithoutPush))
        }

        @Test("降ろさずにフレームが終わると、対の無い最後の段の行を名指す")
        func pushLeftOpenNamesTheLastUnmatchedLine() throws {
            let canvas = try makeCanvas()
            var pushedAt: UInt = 0
            try canvas.draw {
                canvas.pushStyle()
                canvas.pushMatrix(); pushedAt = #line
            }
            let message = try #require(canvas.warnings.message(for: .pushLeftOpen))
            #expect(message.contains("pushMatrix() at MokumeCoreTests/PushClosureTests.swift:\(pushedAt)"), "\(message)")
            #expect(message.contains("the frame"), "\(message)")
        }

        @Test("閉包の本体で積んだまま抜けると、閉包の終わりとして名指す")
        func pushLeftOpenInsideTheClosure() throws {
            let canvas = try makeCanvas()
            var pushedAt: UInt = 0
            try canvas.draw {
                canvas.push {
                    canvas.push(); pushedAt = #line
                }
            }
            let message = try #require(canvas.warnings.message(for: .pushLeftOpen))
            #expect(message.contains("push() at MokumeCoreTests/PushClosureTests.swift:\(pushedAt)"), "\(message)")
            #expect(message.contains("push { … }"), "\(message)")
        }

        @Test("対にした積み降ろしと閉包だけなら、どちらの注意も出ない")
        func balancedDrawingSaysNothing() throws {
            let canvas = try makeCanvas()
            try canvas.draw {
                canvas.push()
                canvas.push { canvas.translate(1, 1) }
                canvas.pop()
            }
            #expect(!canvas.warnings.hasWarned(.popWithoutPush))
            #expect(!canvas.warnings.hasWarned(.pushLeftOpen))
        }

        // MARK: - スケッチの口

        private final class EmptyPop: Sketch {
            var settings = SketchSettings(width: 8, height: 8)
            var poppedAt: UInt = 0
            init() {}
            func draw() {
                pop(); poppedAt = #line
            }
        }

        @Test("スケッチの pop() は、スケッチの書いた行を名指す (転送の中の行ではない)")
        func sketchPopNamesTheSketchLine() throws {
            let sketch = EmptyPop()
            let runtime = try SketchRuntime(sketch: sketch, gpu: RenderDevice(), persistsParams: false)
            try runtime.advance()
            let message = try #require(runtime.canvas.warnings.message(for: .popWithoutPush))
            #expect(message.contains("pop() at MokumeCoreTests/PushClosureTests.swift:\(sketch.poppedAt)"), "\(message)")
        }
    }
}
