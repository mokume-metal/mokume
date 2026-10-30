// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation
import Testing

@testable import MokumeCore

/// 走っている速さの名乗り (#510)。GPU は要らない — 行を組むところは純関数にしてある。
@Suite("速さの名乗り")
struct FrameRateNoticeTests {
    /// **与えられなければ何も出さない。** 窓口から立てたスケッチの出力が 1 バイトも
    /// 変わらないことは、この既定で保たれる。
    @Test("名乗りが与えられなければ、名乗らない")
    func nothingIsSaidWithoutTheKey() {
        #expect(FrameRateNotice.configuration(environment: [:]) == nil)
        #expect(
            FrameRateNotice.configuration(
                environment: [StartupReads.frameRateNotice.key: "   "]) == nil)
        #expect(
            FrameRateNotice.configuration(
                environment: [StartupReads.frameRateNotice.key: " release "]) == "release")
    }

    /// **数字だけを見せない。** 速さは構成で数倍変わるので、同じ行に無いと重い / 軽いの
    /// 判断が構成の違いに引きずられる。
    @Test("速さの行には、構成が必ず入る")
    func theLineAlwaysCarriesTheConfiguration() {
        let line = FrameRateNotice.line(rate: 58.74, configuration: "debug")
        #expect(line.contains("58.7"))
        #expect(line.contains("debug"))
    }

    /// **人が見ていない先へは出さない。** 記録に毎秒 1 行残っても情報にならず、その間に
    /// 起きた作り直しの失敗を埋める ([#685](https://github.com/mokume-metal/mokume/issues/685))。
    /// 機械が読む口は観測の側にある。
    @Test("名乗るのは、鍵が与えられていて、かつ端末のときだけ")
    func announcesOnlyToATerminalWithTheKey() {
        #expect(FrameRateNotice.announces(configuration: "debug", isTerminal: true))
        #expect(!FrameRateNotice.announces(configuration: "debug", isTerminal: false))
        #expect(!FrameRateNotice.announces(configuration: nil, isTerminal: true))
        #expect(!FrameRateNotice.announces(configuration: nil, isTerminal: false))
    }

    /// **積み上げない。** 行頭へ戻して消してから書く。
    @Test("端末へ書く飾りは、行を消してから書く形をしている")
    func theTerminalDecorationClearsTheLine() {
        #expect(FrameRateNotice.rewrite.hasPrefix("\r"))
        #expect(FrameRateNotice.rewrite.contains("[2K"))
    }

    /// **欠測を 0 と書かない。** 0 は「測ったら 0 だった」と読めるが、実際は測れていない。
    @Test("進んでいないときは、0 と書かない")
    func aStoppedSketchIsNotWrittenAsZero() {
        let line = FrameRateNotice.line(rate: nil, configuration: "debug")
        #expect(!line.contains("0"))
        #expect(line.contains("cannot tell"))
        #expect(line.contains("debug"), "欠測でも構成は要る — 何の土俵の話かは変わらない")
    }

    // MARK: - 直近の推移 (#3424)

    /// 1 秒ごとの値 (`nil` は欠測) を、1 秒の間隔で時計を進めながら流し込む。
    private static func history(
        declared: Int = 60, _ rates: [Double?], start: Double = 1000
    ) -> FrameRateNotice.History {
        var history = FrameRateNotice.History(declaredFrameRate: declared)
        for (index, rate) in rates.enumerated() {
            history.record(rate: rate, at: start + Double(index))
        }
        return history
    }

    /// 本文の具体例そのもの: 宣言 60・`60, 60, 40, 40, 60, 欠測, 60` の 7 秒目の行と、
    /// いまの値が欠測の 6 秒目の行。
    @Test("宣言 60 で 60,60,40,40,60,欠測,60 と来ると、落ちて戻って穴のある推移が出る")
    func theWorkedExample() {
        let rates: [Double?] = [60, 60, 40, 40, 60, nil, 60]
        let seventh = Self.history(rates)
        #expect(
            FrameRateNotice.line(rate: 60, configuration: "release", history: seventh)
                == "Rate: 60.0 fps ██▆▆█·█ (release)")
        let sixth = Self.history(Array(rates.prefix(6)))
        #expect(
            FrameRateNotice.line(rate: nil, configuration: "release", history: sixth)
                == "Rate: cannot tell — frames are not advancing ██▆▆█· (release)")
    }

    /// **1 行のまま・始まる前は今と同じ。**
    @Test("推移が空なら、推移を持たない形と同じ文字列で、推移があっても 1 行である")
    func anEmptyTrendLeavesTheLineAsItWas() {
        let empty = FrameRateNotice.History(declaredFrameRate: 60)
        #expect(
            FrameRateNotice.line(rate: 58.3, configuration: "release", history: empty)
                == FrameRateNotice.line(rate: 58.3, configuration: "release"))
        #expect(
            FrameRateNotice.line(rate: nil, configuration: "debug", history: empty)
                == FrameRateNotice.line(rate: nil, configuration: "debug"))
        let full = Self.history([60, 30, nil])
        let line = FrameRateNotice.line(rate: nil, configuration: "debug", history: full)
        #expect(!line.contains("\n"))
        #expect(line.hasSuffix(" (debug)"))
    }

    /// **軸は宣言した値で固定する。** 120 を宣言した作品の 60 は半分の高さ。越えたら頭打ち。
    @Test("縦軸は宣言した frameRate で決まり、越えた値は最も高い棒になる")
    func theAxisIsTheDeclaredFrameRate() {
        #expect(Self.history(declared: 120, [60]).trend == "▄")
        #expect(Self.history(declared: 60, [60]).trend == "█")
        #expect(Self.history(declared: 60, [144]).trend == "█")
        #expect(Self.history(declared: 24, [30, 12, 1]).trend == "█▄▁")
        // 段の境目: 7.5/60 は 1 段、7.6/60 は 2 段 (ceil)
        #expect(Self.history(declared: 60, [7.5, 7.6]).trend == "▁▂")
    }

    /// **欠測は棒にしない。** 0 も最も低い棒も、測れなかったことを「測ったら低かった」と
    /// 読ませる。
    @Test("欠測は · になり、最も低い棒にも 0 にもならない")
    func aMissingSecondIsNotABar() {
        let trend = Self.history([nil, 0, 1, .nan]).trend
        #expect(trend == "·▁▁·", "0 fps の測定は最も低い棒・欠測と NaN は ·")
    }

    /// **1 文字は経過した 1 秒で、呼ばれた回数ではない。** 空いた秒に前の値を写さない。
    @Test("2 秒以上空いたら、空いた秒は · で埋まり、前の値を写さない")
    func aGapIsFilledWithMissingSeconds() {
        var history = FrameRateNotice.History(declaredFrameRate: 60)
        history.record(rate: 60, at: 100)
        history.record(rate: 30, at: 101.02)  // 少し遅れても 1 秒
        history.record(rate: 60, at: 104.0)  // 3 秒空いた: 2 秒が欠測
        #expect(history.trend == "█▄··█")
        // 空きの途中でも、次の標本は経過に応じて数える
        history.record(rate: 60, at: 105.0)
        #expect(history.trend == "█▄··██")
    }

    @Test("30 秒より長い空きは、30 文字ぶんの欠測で押し流す")
    func aVeryLongGapFlushesTheTrend() {
        var history = FrameRateNotice.History(declaredFrameRate: 60)
        history.record(rate: 60, at: 0)
        history.record(rate: 60, at: 10_000)
        #expect(history.trend == String(repeating: "·", count: 29) + "█")
    }

    /// **30 秒で打ち切る。** 31 個目で最も古い 1 文字が落ち、30 に満たない間は空白で埋めない。
    @Test("31 個目の標本で最も古い 1 文字が落ちる。たまるまでは詰めて出す")
    func theTrendKeepsThirtySeconds() {
        let first = Self.history([60, 30, 30])
        #expect(first.trend == "█▄▄", "30 に満たない間はたまった分だけ")
        let thirty = Self.history([60] + Array(repeating: 30, count: 29))
        #expect(thirty.trend.count == 30)
        #expect(thirty.trend.first == "█")
        let thirtyOne = Self.history([60] + Array(repeating: 30, count: 30))
        #expect(thirtyOne.trend.count == 30)
        #expect(thirtyOne.trend == String(repeating: "▄", count: 30), "最も古い █ が落ちた")
    }

    /// 時計が止まって見えても (経過 0)、呼ばれた 1 回は 1 文字として数える。
    @Test("時計が進んでいなくても、1 回の呼びは 1 文字になる")
    func aStalledClockStillCountsOneSecond() {
        var history = FrameRateNotice.History(declaredFrameRate: 60)
        history.record(rate: 60, at: 5)
        history.record(rate: 30, at: 5)
        history.record(rate: 30, at: 4)  // 戻っても
        #expect(history.trend == "█▄▄")
    }

    /// 推移の組み立ては環境にも標本の外にも触れない: 作り直しで子が替われば、新しい値は
    /// 空から始まる。
    @Test("新しい推移は空から始まる")
    func aNewChildStartsEmpty() {
        #expect(FrameRateNotice.History(declaredFrameRate: 60).trend.isEmpty)
    }
}
