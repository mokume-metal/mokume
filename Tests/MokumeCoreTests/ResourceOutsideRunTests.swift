// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation
import MokumeDiagnostics
import MokumeTestSupport
import Testing

@testable import MokumeCore

/// 走っている実行の外 (初期化子の中・後片付けの後・`Task` の中) から資源を作る口を呼ぶと、
/// プロセスを落とさず、その口の型の `notRunning(call:)` を投げる ([#2683])。
///
/// 資源の生成は型のついたエラーを投げる (ADR-0020 決定 5)。以前は面を取る所が `fatalError` で、
/// 投げる口なのに `try?` でも受けられず、窓が開く前にプロセスごと落ちた。投げない
/// ``SketchPart/createShape(_:)`` は描く口と同じく、空の形を返して 1 度だけ警告する (#2265 の決定)。
///
/// **面を作らずに投げることを見るので、GPU は要らない。** 走っている面を差したまま呼ぶ経路
/// (`setup()` で起こした `Task` から待つ読み込みが読める・#1367) は、面の要る
/// `RequestFromTaskTests` が持つ。
///
/// [#2683]: https://github.com/mokume-metal/mokume/issues/2683
@MainActor
@Suite("走っている実行の外から呼んだ資源の口")
struct ResourceOutsideRunTests {
    /// 資源を作る口を持つ部品。走っている実行の外から呼ぶ。
    struct Maker: SketchPart {}

    /// 本文の例。部品の `init()` で絵を読み、`try?` で受ける。
    struct Ship: SketchPart {
        var sprite: Image?
        init() { sprite = try? loadImage("ship.png") }
    }

    /// 部品をプロパティで作るスケッチ。作った時点で `Ship.init()` が走る。
    final class Game: Sketch {
        var ship = Ship()
        init() {}
        func draw() {}
    }

    /// 読める SVG を置いた場所。`loadShape` はファイルを読んでから面を取るので、読めないファイル
    /// だと先にそちらの失敗が投げられ、見たいものを見ない。
    static func svgFile() throws -> String {
        let url = TestScratch.path("mokume-outside-run", pathExtension: "svg")
        let text = #"<svg xmlns="http://www.w3.org/2000/svg" width="10" height="10"><circle cx="5" cy="5" r="4"/></svg>"#
        try Data(text.utf8).write(to: url)
        return url.path
    }

    @Test("走らせずに同期の資源の口を呼ぶと、落ちずにその口の型の notRunning を投げる")
    func synchronousResourcesThrowNotRunning() throws {
        let part = Maker()
        let fragment = "return float4(1);"

        #expect(throws: RenderFailure.notRunning(call: "createGraphics(_:_:)")) {
            try part.createGraphics(8, 8)
        }
        #expect(throws: RenderFailure.notRunning(call: "makeNumbers(count:)")) {
            try part.makeNumbers(count: 4)
        }
        #expect(throws: RenderFailure.notRunning(call: "makeParticles(count:)")) {
            try part.makeParticles(count: 4)
        }

        #expect(throws: ImageFailure.notRunning(call: "loadImage(_:)")) {
            try part.loadImage("ship.png")
        }
        #expect(throws: ImageFailure.notRunning(call: "createImage(_:_:)")) {
            try part.createImage(4, 4)
        }

        #expect(throws: ShaderFailure.notRunning(call: "loadShader(_:values:surfaces:)")) {
            try part.loadShader("paint.metal")
        }
        #expect(throws: ShaderFailure.notRunning(call: "createShader(_:name:values:surfaces:)")) {
            try part.createShader(fragment)
        }
        #expect(throws: ShaderFailure.notRunning(call: "makeEffect(_:name:values:)")) {
            try part.makeEffect(fragment)
        }
        #expect(throws: ShaderFailure.notRunning(call: "loadEffect(_:values:)")) {
            try part.loadEffect("effect.metal")
        }
        #expect(throws: ShaderFailure.notRunning(call: "makeComputation(_:name:values:)")) {
            try part.makeComputation(fragment)
        }
        #expect(throws: ShaderFailure.notRunning(call: "loadComputation(_:values:)")) {
            try part.loadComputation("step.metal")
        }

        #expect(throws: ModelFailure.notRunning(call: "loadModel(_:normalize:)")) {
            try part.loadModel("head.obj")
        }

        let svg = try Self.svgFile()
        defer { try? FileManager.default.removeItem(atPath: svg) }
        #expect(throws: DataFailure.notRunning(call: "loadShape(_:)")) {
            try part.loadShape(svg)
        }
    }

    /// `Task.detached` はタスクローカル値を受け継がないので、走っている実行の面が届かない
    /// (``LaunchingSketch``)。`init` から呼んだときと同じく、読み込む面が決まらない。
    @Test("Task.detached から待つ読み込みを呼ぶと、落ちずに notRunning を投げる")
    func waitingLoadsFromADetachedTaskThrowNotRunning() async throws {
        let svg = try Self.svgFile()
        defer { try? FileManager.default.removeItem(atPath: svg) }

        let image = await Task.detached { await Self.requestImageFailure() }.value
        #expect(image == .notRunning(call: "requestImage(_:)"))

        let model = await Task.detached { await Self.requestModelFailure() }.value
        #expect(model == .notRunning(call: "requestModel(_:normalize:)"))

        let shape = await Task.detached { await Self.requestShapeFailure(svg) }.value
        #expect(shape == .notRunning(call: "requestShape(_:)"))

        // `Task.detached` には検査の控え (タスクローカル値) も届かないので、プロセスの控えへ言う
        for call in ["requestImage(_:)", "requestModel(_:normalize:)", "requestShape(_:)"] {
            #expect(
                OutsideRun.shared.message(for: call)?.contains("It threw an error") == true,
                "\(call) が投げる前に言っていない")
        }
    }

    /// 投げるだけでは、`try?` で受けた側に何も残らない — 値が黙って `nil` になり、標準エラーにも
    /// 観測の `warnings` にも出ない。`createShape` は警告するので、それとも食い違う。
    @Test("投げる前に口ごとに 1 度だけ警告し、観測の応答にも載る (try? で受けても残る)")
    func throwingLeavesAWarningOnce() {
        let log = OutsideRun()
        Diagnostics.$digest.withValue(WarningDigest()) {
            OutsideRun.$current.withValue(log) {
                let game = Game()
                _ = Game()
                #expect(game.ship.sprite == nil)
                // 2 つ作っても 1 行
                #expect(log.messages.count == 1)
                let message = log.message(for: "loadImage(_:)")
                #expect(message?.hasPrefix("loadImage(_:) only works inside setup()") == true)
                #expect(message?.contains("It threw an error instead of returning anything.") == true)
                #expect(message?.hasSuffix("Call it from setup()") == true)
                // 標準エラーへは 1 行しか流せない
                #expect(message?.contains("\n") == false)
                #expect(Diagnostics.takeUnreported() == message.map { [$0] })
            }
        }
    }

    // 待つ読み込みを呼んで、投げた失敗を返す。投げなければ `nil`。`Task.detached` の中身から呼ぶ
    // (閉包の中に typed throws の do を書くと、いまのコンパイラの隔離の検査が通らない)。

    static func requestImageFailure() async -> ImageFailure? {
        do {
            _ = try await Maker().requestImage("ship.png")
            return nil
        } catch let failure as ImageFailure {
            return failure
        } catch {
            return nil
        }
    }

    static func requestModelFailure() async -> ModelFailure? {
        do {
            _ = try await Maker().requestModel("head.obj")
            return nil
        } catch let failure as ModelFailure {
            return failure
        } catch {
            return nil
        }
    }

    static func requestShapeFailure(_ path: String) async -> DataFailure? {
        do {
            _ = try await Maker().requestShape(path)
            return nil
        } catch let failure as DataFailure {
            return failure
        } catch {
            return nil
        }
    }

    @Test("部品の init で try? loadImage を書いたスケッチは、作っても落ちず、絵が nil になる")
    func theIssueExampleBuildsTheSketch() {
        let game = Game()
        #expect(game.ship.sprite == nil)
    }

    @Test("走らせずに createShape を呼ぶと、落ちずに空の形を返し、1 度だけ警告する")
    func createShapeOutsideTheRunIsEmpty() {
        let log = OutsideRun()
        OutsideRun.$current.withValue(log) {
            let part = Maker()
            var ran = 0
            let first = part.createShape {
                ran += 1
                part.circle(0, 0, 10)
            }
            let second = part.createShape { part.circle(0, 0, 10) }
            #expect(first.isEmpty)
            #expect(second.isEmpty)
            #expect(ran == 1, "組み立ての中身が呼ばれていない")
            // createShape と、中の circle の 2 口。2 回呼んでも 1 行ずつ
            #expect(log.messages.count == 2)
            let message = log.message(for: "createShape(_:)")
            #expect(message?.hasPrefix("createShape(_:) only works inside setup()") == true)
            #expect(message?.contains("an empty shape was returned instead") == true)
            #expect(log.message(for: "circle(_:_:_:)") != nil)

            // 空の形を置いても落ちない (走っていないので、置く口も何もせずに言う)
            part.shape(first, 10, 10)
            #expect(log.message(for: "shape(_:_:_:)") != nil)
        }
    }

    /// 文面は呼べる場所を名乗る (ADR-0038 決定 3 の完全な文)。待つ読み込みだけが、走っている
    /// 実行の中で起こした `Task` から呼べる。同期の口に同じことを言うと、投げた場所そのものを
    /// 勧めてしまう。
    @Test("文面は口の名前と呼べる場所を名乗り、Task から呼べるのは待つ読み込みだけと言い分ける")
    func theNoticeNamesTheCallAndWhereItWorks() {
        let synchronous = ImageFailure.notRunning(call: "loadImage(_:)").description
        #expect(synchronous.hasPrefix("loadImage(_:) only works inside setup(), draw() or an input callback,"))
        #expect(!synchronous.contains("Task started there"))
        #expect(synchronous.hasSuffix("Call it from setup()"))

        let waiting = ImageFailure.notRunning(call: "requestImage(_:)").description
        #expect(waiting.hasPrefix("requestImage(_:) only works inside setup(), draw() or an input callback, or in a Task started there"))
        #expect(waiting.contains("Task.detached"))

        // **「走っていない」「面が無い」とは言わない** (#1322)。`draw()` が回っている最中に、そこで
        // 起こした `Task` から同期の口を呼んでもこの文面になり、そのとき面はある
        for text in [synchronous, waiting] {
            #expect(!text.contains("no surface"), "面が無いと言い切っている: \(text)")
            #expect(!text.lowercased().contains("not running"), "走っていないと言い切っている: \(text)")
            #expect(text.contains("could not be reached"))
        }

        // 5 つの型が同じ文面を出す (どの口から来たかで変わるのは名前だけ)
        let call = "makeSomething(_:)"
        let expected = OutsideRun.notRunningNotice(call)
        #expect(RenderFailure.notRunning(call: call).description == expected)
        #expect(ImageFailure.notRunning(call: call).description == expected)
        #expect(ShaderFailure.notRunning(call: call).description == expected)
        #expect(ModelFailure.notRunning(call: call).description == expected)
        #expect(DataFailure.notRunning(call: call).description == expected)
        // 走っている最中の警告の 1 行は、起きたことを名乗る行になる
        #expect(RenderFailure.notRunning(call: call).headline.hasPrefix("makeSomething(_:) only works"))
    }

    /// `canvas` は読むプロパティなので、資源の口の文面 (「作って返す」「setup() から呼ぶ」) を言わない。
    /// 止めるので、落ちずに済む語彙へ案内する。止める文面はプロセスを落とすので、ここでは文面だけを見る。
    @Test("canvas の止める文面は、読んだプロパティとして名乗り、落ちない語彙へ案内する")
    func theCanvasStopNoticeFitsAProperty() {
        let text = OutsideRun.canvasStopNotice
        #expect(text.hasPrefix("canvas can only be read inside setup(), draw() or an input callback."))
        #expect(!text.contains("makes what it returns"))
        #expect(text != OutsideRun.notRunningNotice("canvas"))
        #expect(!text.lowercased().contains("not running"))
        #expect(text.contains("circle()"))
    }

    /// 待つ読み込みの名前は、文面の言い分けに使う一覧と口の `#function` が一致していないと、
    /// 同期の口の文面に落ちる。一覧の名前で投げた失敗が、待つ読み込みの文面を出すことを見る。
    @Test("待つ読み込みの一覧は 3 口で、どれも Task から呼べると名乗る")
    func theWaitingLoadsAreListed() {
        #expect(
            OutsideRun.waitingLoads
                == ["requestImage(_:)", "requestModel(_:normalize:)", "requestShape(_:)"])
        for call in OutsideRun.waitingLoads {
            #expect(OutsideRun.notRunningNotice(call).contains("or in a Task started there"))
        }
    }
}
