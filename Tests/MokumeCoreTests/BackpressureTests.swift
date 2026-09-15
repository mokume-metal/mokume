// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation
import Testing

@testable import MokumeCore

/// 抱える枚数の上限と、待ちの期限。
///
/// **GPU もファイルも要らない。** `Backpressure` は semaphore と数だけを持つ素の型なので、
/// 期限そのものを決定論的に固定できる — 期限を短くして構成し、誰も枠を返さない状態で
/// 待たせればよい。書き出しの経路ごと動かして期限を測ろうとすると、遅いディスクを
/// 用意する話になって再現しなくなる。
///
/// **期限の検査は 2 つの待ち方の両方で回す** ([#978])。測り方を 1 か所に置いた意味は、
/// 塞がずに見に来る側 (``Patience/peek``) にも同じ期限が効くことにある。
///
/// [#978]: https://github.com/mokume-metal/mokume/issues/978
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

    /// 選んだ待ち方で決着まで待ち、**諦めたときに残っていた数**を返す (全部終わったなら `nil`)。
    ///
    /// ``Patience/block`` は元からある `drain()` をそのまま通す — 同期の口の意味が変わって
    /// いないことも併せて見るため。
    private func drain(_ pressure: Backpressure, _ patience: Patience) throws -> Int? {
        switch patience {
        case .block:
            return pressure.drain()
        case .peek:
            try #require(
                pollUntilSettled(within: 10) { pressure.drain(.peek) },
                "塞がずに見に来る待ちが、10 秒経っても決着しない")
            return pressure.outstanding > 0 ? pressure.outstanding : nil
        }
    }

    @Test("全部返れば、諦めずに終わる", arguments: [Patience.block, .peek])
    func drainCompletesWhenAllReturn(_ patience: Patience) throws {
        let pressure = Backpressure(limit: 4, stallLimitSeconds: 0.05)
        pressure.take()
        pressure.take()
        let release = pressure.release
        release()
        release()

        #expect(try drain(pressure, patience) == nil)
        #expect(pressure.outstanding == 0)
    }

    @Test("1 つも進まなくなったら、諦めて残りの数を名乗る", arguments: [Patience.block, .peek])
    func drainGivesUpWhenNothingProgresses(_ patience: Patience) throws {
        let pressure = Backpressure(limit: 4, stallLimitSeconds: 0.05)
        pressure.take()
        pressure.take()

        // 誰も枠を返さない。**期限が無ければここで永久に返らない** — 待つのは main actor の
        // 上なので、絵も観測も入力も一緒に黙り、プロセスを殺すしかなくなる。塞がずに見に来る
        // 側では「終わりの返事が永久に来ない」として現れる
        #expect(try drain(pressure, patience) == 2)
    }

    @Test("諦めても、抱えている数は 0 に戻さない", arguments: [Patience.block, .peek])
    func givingUpKeepsTheCount(_ patience: Patience) throws {
        let pressure = Backpressure(limit: 4, stallLimitSeconds: 0.05)
        pressure.take()
        _ = try drain(pressure, patience)

        // **0 に戻すと壊れる。** 諦めた後に仕事が終わって合図を出すので、戻しておくと
        // 次の取り込みがその合図を数えて、抱えている数が実態より小さくなる。
        // 残しておけば、次に待つときが正しくまた待つ
        #expect(pressure.outstanding == 1)

        let release = pressure.release
        release()
        #expect(try drain(pressure, patience) == nil)
        #expect(pressure.outstanding == 0)
    }

    @Test("進んでいる間は、総時間が期限を越えても諦めない", arguments: [Patience.block, .peek])
    func drainMeasuresProgressNotTotalTime(_ patience: Patience) async throws {
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

        // 全部返るまでに 400ms かかる。総時間で測っていれば 300ms で諦める。塞がずに
        // 見に来る側では、**見に来るたびに測り直していれば**逆に諦めなくなる — そちらは
        // 上の「1 つも進まなくなったら」が見る
        #expect(try drain(pressure, patience) == nil)
        #expect(pressure.outstanding == 0)
    }

    /// **塞がずに見に来る待ちは、止まった相手の前でも待たない** ([#978])。
    ///
    /// 終わりの経路はこれを run loop から何度も呼ぶ。1 回でも塞げば、そのぶん main が
    /// `AVAssetWriter.finishWriting` の間に塞がれる — 直した形に戻る。
    ///
    /// [#978]: https://github.com/mokume-metal/mokume/issues/978
    @Test("塞がずに見に来る待ちは、止まった相手の前でも待たずに返り、数を保つ")
    func peekingNeverWaits() {
        // 期限を長く取る。塞いでいれば、ここで 2 秒止まってから `true` が返る
        let pressure = Backpressure(limit: 4, stallLimitSeconds: 2)
        pressure.take()
        pressure.take()

        let started = DispatchTime.now()
        #expect(!pressure.drain(.peek), "止まった相手を、見に来ただけで決着させている")
        let elapsed = Double(DispatchTime.now().uptimeNanoseconds - started.uptimeNanoseconds) / 1e9
        #expect(elapsed < 1, "見に来ただけで \(elapsed) 秒待った")
        #expect(pressure.outstanding == 2)
    }
}

/// 塞がずに見に来る待ちを、決着するまで繰り返し呼ぶ。
///
/// **上限を持つ。** 壊れて決着しなくなったときに検査ごと固まらせないためで、`.timeLimit` は
/// 使わない (上限は検査の走り出しから測られ、無関係な検査を赤くする・#564)。
///
/// - Parameters:
///   - seconds: これだけ経っても決着しなければ諦める。
///   - poll: 1 回見に来る。決着したら `true`。
/// - Returns: 決着したか。
func pollUntilSettled(within seconds: Double, _ poll: () -> Bool) -> Bool {
    let deadline = DispatchTime.now() + seconds
    while !poll() {
        guard DispatchTime.now() < deadline else { return false }
        Thread.sleep(forTimeInterval: 0.002)
    }
    return true
}
