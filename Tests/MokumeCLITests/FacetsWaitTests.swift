// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation
import Testing
import mokume

@testable import MokumeCLI

/// 窓口がスケッチの応答を待つ上限 ([#1940](https://github.com/mokume-metal/mokume/issues/1940))。
///
/// **時計は偽物を差し込む。** 本物の時計で巨大な待ちを試すと、応答が来ないかぎり検査が
/// 戻らない。偽の時計は `sleep` のたびに進み、決めた回数に達したら応答を置く — 上限で諦める
/// 実装なら応答が置かれる前に `nil` で戻り、諦めない実装は置かれた応答を拾って戻る。
@Suite("窓口の待ちの上限")
struct FacetsWaitTests {
    /// `sleep` が呼ばれるたびに 1 刻み進む時計。`answerAt` 回目に応答を置く。
    private final class FakeClock {
        /// 時計の 1 刻み (ナノ秒)。
        let tick: UInt64
        let answerAt: Int
        let reportURL: URL
        private(set) var ticks = 0

        init(tickSeconds: Double, answerAt: Int, reportURL: URL) {
            self.tick = UInt64(tickSeconds * 1_000_000_000)
            self.answerAt = answerAt
            self.reportURL = reportURL
        }

        var now: DispatchTime {
            DispatchTime(uptimeNanoseconds: 1_000_000_000 + UInt64(ticks) * tick)
        }

        func sleep() {
            ticks += 1
            if ticks == answerAt {
                try? Data(#"{"id":"x"}"#.utf8).write(to: reportURL)
            }
        }
    }

    private func makeFacets(waitLimit: TimeInterval = Facets.defaultWaitLimit) -> (Facets, URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("mokume-facets-wait-\(UUID().uuidString)", isDirectory: true)
        return (Facets(directory: directory, waitLimit: waitLimit), directory)
    }

    /// **巨大な待ちが渡されても、窓口は有限の上限で諦める。** `count` / `every` は MCP から来る
    /// 値で、`Tools` はスキーマの上限で切らずに待ちへ足す。上限が無いと、足す秒数は
    /// `DispatchTime` が表せる範囲を越え、「ほぼ永久に待つ」か、実装次第では落ちる。
    @Test("待ちが巨大・無限でも、上限で諦めて何も応えなかったと返す")
    func givesUpAtTheCapWhenTheWaitIsHuge() throws {
        for huge in [1e12, Double.infinity] {
            let (facets, directory) = makeFacets()
            defer { try? FileManager.default.removeItem(at: directory) }
            let facet = facets.observeFacet
            // 1 刻み = 1 時間。上限 (1 日 = 24 刻み) を越えた 72 刻み目に応答が来る
            let clock = FakeClock(
                tickSeconds: 3600, answerAt: 72,
                reportURL: WorkDirectory.reportURL(under: facet))

            let report = try facets.exchange(
                facet: facet, request: ["id": "x"], id: "x", extraWait: huge,
                sleep: { _ in clock.sleep() }, now: { clock.now })

            #expect(report == nil, "上限を越えて待った (待ち \(huge) 秒)")
            #expect(clock.ticks == 24, "1 日 (24 刻み) で諦めていない: \(clock.ticks) 刻み")
        }
    }

    /// 期限へ足す前の丸め。範囲の中の値は**そのまま**通す — 通常の待ち (既定の 5 秒・撮る列の
    /// 約 4 分) が短くなってはならない。
    @Test("待ちの長さは、範囲の中ならそのまま、外なら端へ丸める")
    func boundsTheWaitIntoTheRangeDispatchTimeCanAdd() {
        let longest = Facets.longestWaitSeconds
        let cases: [(input: Double, expected: Double)] = [
            (0, 0), (0.2, 0.2), (Facets.defaultWaitLimit, 5), (240, 240), (longest, longest),
            // 上限を越える・無限は上限へ
            (longest + 1, longest), (1e12, longest), (1e300, longest), (.infinity, longest),
            // 負・NaN は 0 へ (待たずに戻る)
            (-1, 0), (-1e300, 0), (-.infinity, 0), (.nan, 0),
        ]
        for (input, expected) in cases {
            #expect(Facets.boundedWait(input) == expected, "\(input) 秒の丸め")
        }
    }

    /// 上限は**足す前の秒数**を切るだけで、通常の待ちの挙動は変えない。
    @Test("上限の手前で応えが来れば、その応えを返す")
    func returnsTheAnswerThatArrivesBeforeTheLimit() throws {
        let (facets, directory) = makeFacets(waitLimit: 5)
        defer { try? FileManager.default.removeItem(at: directory) }
        let facet = facets.observeFacet
        // 1 刻み = 1 秒。上限 (5 刻み) の手前の 3 刻み目に応答が来る
        let clock = FakeClock(
            tickSeconds: 1, answerAt: 3, reportURL: WorkDirectory.reportURL(under: facet))

        let report = try facets.exchange(
            facet: facet, request: ["id": "x"], id: "x",
            sleep: { _ in clock.sleep() }, now: { clock.now })

        #expect(report?["id"] as? String == "x")
        #expect(clock.ticks == 3)
    }

    @Test("応えが来なければ、上限の長さだけ待って諦める")
    func givesUpAfterTheLimitWhenNothingAnswers() throws {
        let (facets, directory) = makeFacets(waitLimit: 5)
        defer { try? FileManager.default.removeItem(at: directory) }
        let facet = facets.observeFacet
        let clock = FakeClock(
            tickSeconds: 1, answerAt: Int.max, reportURL: WorkDirectory.reportURL(under: facet))

        let report = try facets.exchange(
            facet: facet, request: ["id": "x"], id: "x",
            sleep: { _ in clock.sleep() }, now: { clock.now })

        #expect(report == nil)
        #expect(clock.ticks == 5, "上限の 5 秒 (5 刻み) だけ待っていない: \(clock.ticks) 刻み")
    }
}
