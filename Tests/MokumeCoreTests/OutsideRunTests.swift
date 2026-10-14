// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

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
            let message = log.message(for: "width")
            #expect(message?.hasPrefix("width is only known inside setup()") == true)
            #expect(message?.contains("0 was returned instead") == true)
            #expect(message?.contains("Make anything that depends on it inside setup()") == true)
            #expect(log.message(for: "height") != nil)
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
            #expect(part.noise(0.5) == 0)
            #expect(part.textWidth("HP") == 0)
            #expect(part.screenX(3, 4) == 0)
            #expect(part.pixelWidth == 0)
            #expect(part.usesFrameHistory == false)
            #expect(log.message(for: "clock")?.contains(".wallClock was returned instead") == true)
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
        #expect(log.message(for: "width") != nil)
    }

    @Test("控えを差していない検査の警告は、差した控えへ混ざらない")
    func aBoundLogOnlySeesItsOwnCalls() {
        let log = OutsideRun()
        _ = Painter().frameCount  // 差す前 — プロセスの控えへ行く
        OutsideRun.$current.withValue(log) {
            #expect(log.messages.isEmpty)
        }
    }
}
