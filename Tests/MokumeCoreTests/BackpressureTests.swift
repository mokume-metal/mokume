// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Testing

@testable import MokumeCore

/// 抱える枚数の上限と、待ちの期限。
///
/// **GPU もファイルも要らない。** `Backpressure` は semaphore と数だけを持つ素の型なので、
/// 期限そのものを決定論的に固定できる — 期限を短くして構成し、誰も枠を返さない状態で
/// 待たせればよい。書き出しの経路ごと動かして期限を測ろうとすると、遅いディスクを
/// 用意する話になって再現しなくなる。
@Suite("抱える枚数の上限")
struct BackpressureTests {
    @Test("上限まで取れる。返せばまた取れる")
    func takesUpToTheLimit() {
        let pressure = Backpressure(limit: 2, stallLimitSeconds: 0.05)
        pressure.take()
        pressure.take()
        #expect(pressure.outstanding == 2)

        let release = pressure.release
        release()
        // 取り込むまで数は減らない (待たずに取り込む口がある)
        pressure.harvest()
        #expect(pressure.outstanding == 1)

        pressure.take()
        #expect(pressure.outstanding == 2)
    }

    @Test("抱えた最大を覚える")
    func remembersThePeak() {
        let pressure = Backpressure(limit: 3, stallLimitSeconds: 0.05)
        let release = pressure.release
        pressure.take()
        pressure.take()
        release()
        release()
        pressure.harvest()
        #expect(pressure.outstanding == 0)
        #expect(pressure.peak == 2)
    }

    @Test("全部返れば、諦めずに終わる")
    func drainCompletesWhenAllReturn() {
        let pressure = Backpressure(limit: 4, stallLimitSeconds: 0.05)
        pressure.take()
        pressure.take()
        let release = pressure.release
        release()
        release()

        #expect(pressure.drain() == nil)
        #expect(pressure.outstanding == 0)
    }

    @Test("1 つも進まなくなったら、諦めて残りの数を名乗る")
    func drainGivesUpWhenNothingProgresses() {
        let pressure = Backpressure(limit: 4, stallLimitSeconds: 0.05)
        pressure.take()
        pressure.take()

        // 誰も枠を返さない。**期限が無ければここで永久に返らない** — 待つのは main actor の
        // 上なので、絵も観測も入力も一緒に黙り、プロセスを殺すしかなくなる
        #expect(pressure.drain() == 2)
    }

    @Test("諦めても、抱えている数は 0 に戻さない")
    func givingUpKeepsTheCount() {
        let pressure = Backpressure(limit: 4, stallLimitSeconds: 0.05)
        pressure.take()
        _ = pressure.drain()

        // **0 に戻すと壊れる。** 諦めた後に仕事が終わって合図を出すので、戻しておくと
        // 次の取り込みがその合図を数えて、抱えている数が実態より小さくなる。
        // 残しておけば、次に待つときが正しくまた待つ
        #expect(pressure.outstanding == 1)

        let release = pressure.release
        release()
        #expect(pressure.drain() == nil)
        #expect(pressure.outstanding == 0)
    }

    @Test("進んでいる間は、総時間が期限を越えても諦めない")
    func drainMeasuresProgressNotTotalTime() async {
        // 期限は「1 つも進まなくなってから」を測る。**総時間ではない** — 総時間で測ると、
        // 長く撮った動画の符号化を、進んでいるのに諦めることになる。
        //
        // 間隔 (20ms) は期限 (300ms) の 1/15 に取ってある。込み合った機械で 1 回の
        // 待ちが延びても、期限に届く前に次が返る
        let pressure = Backpressure(limit: 20, stallLimitSeconds: 0.3)
        for _ in 0..<20 { pressure.take() }
        let release = pressure.release

        Task.detached {
            for _ in 0..<20 {
                try? await Task.sleep(for: .milliseconds(20))
                release()
            }
        }

        // 全部返るまでに 400ms かかる。総時間で測っていれば 300ms で諦める
        #expect(pressure.drain() == nil)
        #expect(pressure.outstanding == 0)
    }
}
