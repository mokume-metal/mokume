// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import MokumeDiagnostics
import Testing

@testable import MokumeCore

/// 走っている実行の外 (初期化子の中・後片付けの後・`Task` の中) から呼んだ語彙は、プロセスを
/// 落とさず、口ごとに 1 度だけ警告して安全な既定へ倒す (ADR-0020 決定 5・#2265)。
///
/// **控えは検査ごとに差し替える** (``OutsideRun/current``)。プロセスの控えは並んで走る
/// 検査と共有なので、そのままでは「1 度だけ」を他の検査と数え合う。装置にも窓にも触らない
/// ので、この suite にゲートは付かない。
@MainActor
@Suite("走っている実行の外から呼んだ語彙")
struct OutsideRunTests {
    /// 学生が書きそうな部品。`init()` の中で面の大きさを読む。
    ///
    /// 格納プロパティに既定値が無いと、`width` を読む前に Swift が組めなくする (自分を使う前に
    /// 全部を埋める規則)。実行時に走る前の読み取りになるのは、既定値を置いてから読む形である。
    struct Player: SketchPart {
        var x: Float = 0
        var y: Float = 0
        init() {
            x = width / 2
            y = height - 30
        }
    }

    /// 描く口・状態を書く口を一通り呼ぶ部品。
    struct Painter: SketchPart {
        func paint() {
            fill(255)
            translate(10, 10)
            circle(0, 0, 10)
            circle(0, 0, 10)
        }
    }

    @Test("走る前に面の大きさを読むと、落ちずに 0 が返り、口ごとに 1 度だけ警告する")
    func readingTheSizeBeforeTheRunReturnsZero() {
        let log = OutsideRun()
        OutsideRun.$current.withValue(log) {
            let first = Player()
            let second = Player()
            #expect(first.x == 0)
            #expect(first.y == -30)
            #expect(second.x == 0)
            // 2 つ作っても、width と height の 1 行ずつで止まる
            #expect(log.messages.count == 2)
            let message = log.messageForRead(of: "width")
            #expect(message?.hasPrefix("width is only known inside setup()") == true)
            #expect(message?.contains("0 was returned instead") == true)
            #expect(message?.contains("Make anything that depends on it inside setup()") == true)
            #expect(log.messageForRead(of: "height") != nil)
        }
    }

    @Test("走る前の読み取りは、どれも空の値を返す")
    func readsReturnEmptyValues() {
        let log = OutsideRun()
        OutsideRun.$current.withValue(log) {
            let part = Painter()
            #expect(part.frameCount == 0)
            #expect(part.time == 0)
            #expect(part.deltaTime == 0)
            #expect(part.clock == .wallClock)
            #expect(part.random() == 0)
            #expect(part.random(5) == 0)
            #expect(part.random(1, 2) == 0)
            #expect(part.randomGaussian() == 0)
            #expect(part.randomGaussian(10, 2) == 0)
            #expect(part.random(["a", "b"]) == nil)
            #expect(part.shuffle([3, 1, 2]) == [3, 1, 2])
            #expect(log.messageForRead(of: "shuffle(_:)")?.contains("the array unchanged was returned instead") == true)
            #expect(part.noise(0.5) == 0)
            #expect(part.textWidth("HP") == 0)
            #expect(part.screenX(3, 4) == 0)
            #expect(part.pixelWidth == 0)
            #expect(part.usesFrameHistory == false)
            #expect(log.messageForRead(of: "clock")?.contains(".wallClock was returned instead") == true)
        }
    }

    @Test("走る前に描く口を呼ぶと、落ちずに何もせず、口ごとに 1 度だけ警告する")
    func drawingBeforeTheRunDoesNothing() {
        let log = OutsideRun()
        OutsideRun.$current.withValue(log) {
            Painter().paint()
            Painter().paint()
            // fill・translate・circle の 3 口。circle は 4 回呼んだが 1 行
            #expect(log.messages.count == 3)
            let message = log.message(for: "circle(_:_:_:)")
            #expect(message?.hasPrefix("circle(_:_:_:) only works inside setup(), draw() or an input callback") == true)
            #expect(message?.contains("so it did nothing") == true)
            #expect(log.message(for: "translate(_:_:)") != nil)
        }
    }

    /// 後片付けの後と、`draw()` で起こした `Task` の中は、どちらも差さっている実行が無い。
    /// 以前は `Task` から描いた口でもプロセスごと落ちていた。
    @Test("Task の中から呼んでも、同じく落ちずに警告する")
    func callsFromATaskWarnToo() async {
        let log = OutsideRun()
        await OutsideRun.$current.withValue(log) {
            await Task { @MainActor in
                let part = Painter()
                part.circle(0, 0, 10)
                #expect(part.width == 0)
            }.value
        }
        #expect(log.message(for: "circle(_:_:_:)") != nil)
        #expect(log.messageForRead(of: "width") != nil)
    }

    /// `orbit` は読みと書きが同じ名前 (`#function` が `"orbit"`) を持つ。名前だけを鍵にすると、
    /// 先に踏んだ側がもう一方を永久に黙らせ、残る文面も違う種類のものになる。
    @Test("同じ名前の口でも、読んだときと書いたときは別に 1 度ずつ言う")
    func readingAndWritingTheSameNameWarnSeparately() {
        let log = OutsideRun()
        OutsideRun.$current.withValue(log) {
            let part = Painter()
            _ = part.orbit
            part.orbit = Orbit(center: .zero, distance: 100)
            #expect(log.messageForRead(of: "orbit")?.contains("was returned instead") == true)
            #expect(log.message(for: "orbit")?.contains("so it did nothing") == true)
        }
    }

    /// 毎回載せると、`init` で 1 度踏んだ古い警告が、後の無関係な観測の失敗の理由に混ざり続ける。
    @Test("観測の応答へは、言った後の最初の 1 回だけ渡す")
    func handsEachWarningToTheObservationOnce() {
        let log = OutsideRun()
        Diagnostics.$digest.withValue(WarningDigest()) {
            OutsideRun.$current.withValue(log) {
                Painter().circle(0, 0, 10)
                #expect(Diagnostics.takeUnreported().count == 1)
                #expect(Diagnostics.takeUnreported().isEmpty)
                _ = Painter().width
                #expect(Diagnostics.takeUnreported().map { $0.hasPrefix("width") } == [true])
            }
        }
    }

    /// 進行・時刻・書き出し・繋ぎの口 (``OutsideCall``) も同じ事情なので、同じ控えで 1 度だけ言う。
    /// 以前は呼ぶたびに標準エラーへ書き、観測の応答には載らなかった。
    @Test("呼び出しの外から頼んだ noLoop も、1 度だけ言って観測へ渡す")
    func outsideCallsShareTheLog() {
        let log = OutsideRun()
        OutsideRun.$current.withValue(log) {
            Painter().noLoop()
            Painter().noLoop()
            #expect(log.messages == [OutsideCall.noLoop.notice])
        }
    }

    @Test("走る前に画素を読むと、落ちずに大きさ 0 の窓が返る")
    func pixelsBeforeTheRunAreAnEmptyWindow() {
        let log = OutsideRun()
        OutsideRun.$current.withValue(log) {
            let pixels = Painter().pixels
            #expect(pixels.width == 0)
            #expect(pixels.height == 0)
            #expect(Painter().get(0, 0) == .transparent)
            #expect(log.messageForRead(of: "pixels") != nil)
        }
    }
}
