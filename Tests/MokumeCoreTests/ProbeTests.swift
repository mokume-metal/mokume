// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation
import Testing

@testable import MokumeProbe

/// 入力を生成して縮める道具 (``Probe``) の自己の検査 (#3216)。GPU を使わない。
///
/// 道具が誤ると、生成した検査は「探した」と名乗りながら同じ点しか見ないか、赤を縮め損ねて読めない
/// 入力を名乗る。ここでは、決まった列・縮めた先・seed での再現・文面の形・帰属の表を見る。
@Suite("入力を生成して縮める道具は、決まった列を出し、赤を単純な入力へ縮めて seed と共に名乗る")
struct ProbeTests {
    static let axes = [ProbeAxis("x", 0..<10, simplest: 0), ProbeAxis("y", -1..<1, simplest: 0)]

    /// 環境変数の影響を受けない既定 (PR・queue の実行)。
    static let quiet: [String: String] = [:]

    private func inputs(key: String, environment: [String: String] = quiet) -> [[Double]] {
        var seen: [[Double]] = []
        _ = Probe.run("probe", suite: "ProbeTests", key: key, axes: Self.axes, cases: 20, environment: environment) {
            seen.append($0.values)
            return .pass
        }
        return seen
    }

    @Test("同じ key の既定の実行は毎回同じ入力を、違う key は違う入力を出す")
    func fixedSeedRepeats() {
        let first = inputs(key: "a")
        #expect(first.count == 20)
        #expect(first == inputs(key: "a"))
        #expect(first != inputs(key: "b"))
        // 範囲の内に散る (同じ点を繰り返さない)
        #expect(Set(first.map { $0[0] }).count == 20)
        #expect(first.allSatisfy { (0..<10).contains($0[0]) && (-1..<1).contains($0[1]) })
    }

    @Test("MOKUME_PROBE_FRESH は実行ごとに入力を変え、MOKUME_PROBE_SCALE は件数を倍にする")
    func freshAndScale() {
        #expect(inputs(key: "a", environment: ["MOKUME_PROBE_FRESH": "1"]) != inputs(key: "a"))
        #expect(inputs(key: "a", environment: ["MOKUME_PROBE_SCALE": "3"]).count == 60)
    }

    @Test("赤は境目の近くまで縮められ、文面は [名 seed=…] で始まって縮めた入力と縮める前を名乗る")
    func shrinksToTheBoundary() throws {
        // x ≥ 3 で破れる単調な述語。最も単純な値 0 へ向けて縮めると、3 の近くで止まる
        let report = Probe.run("probe", suite: "ProbeTests", key: "a", axes: Self.axes, cases: 50, environment: Self.quiet) {
            $0["x"] >= 3 ? .fail("x が大きい") : .pass
        }
        let failure = try #require(report.failure)
        #expect(failure.hasPrefix("[probe seed=0x"))
        // y は赤に関わらないので 0 まで縮む
        #expect(failure.contains(" y=0.0"))
        let x = try #require(failure.split(separator: " ").first { $0.hasPrefix("x=") }.flatMap { Double($0.dropFirst(2)) })
        #expect((3..<3.2).contains(x), "縮めた x = \(x)")
        #expect(failure.contains("縮める前: "))
    }

    @Test("赤の文面の seed を MOKUME_PROBE_SEED で渡すと、同じ入力の 1 件だけが走り同じ赤になる")
    func seedReplaysTheFailure() throws {
        var firstFailing: [Double]?
        let report = Probe.run("probe", suite: "ProbeTests", key: "a", axes: Self.axes, cases: 50, shrinkSteps: 0, environment: Self.quiet) {
            if $0["x"] >= 3 {
                if firstFailing == nil { firstFailing = $0.values }
                return .fail("x が大きい")
            }
            return .pass
        }
        let failure = try #require(report.failure)
        let seed = try #require(failure.split(separator: " ").first { $0.hasPrefix("seed=") }.map { String($0.dropFirst(5).dropLast()) })
        var replayed: [[Double]] = []
        let replay = Probe.run("probe", suite: "ProbeTests", key: "a", axes: Self.axes, cases: 50, shrinkSteps: 0, environment: ["MOKUME_PROBE_SEED": seed]) {
            replayed.append($0.values)
            return $0["x"] >= 3 ? .fail("x が大きい") : .pass
        }
        #expect(replayed == [try #require(firstFailing)])
        #expect(replay.failure == failure)
    }

    @Test("約束の外 (skip) へは縮めず、skip は数えるだけで赤にしない")
    func skipIsNotAFailure() throws {
        let report = Probe.run("probe", suite: "ProbeTests", key: "a", axes: Self.axes, cases: 50, environment: Self.quiet) {
            if $0["x"] < 1 { return .skip }
            // 赤を稀にして、赤の前に skip が来るようにする (最初の赤で打ち切るため)
            return $0["x"] >= 9 ? .fail("x が大きい") : .pass
        }
        #expect(report.skipped > 0)
        let failure = try #require(report.failure)
        #expect(!failure.contains(" x=0.0 "), "約束の外の x = 0 へ縮めた: \(failure)")
    }

    @Test("刻みを持つ座標は刻みの上の値だけを出し、上端を含まない")
    func steppedAxisStaysOnTheGrid() {
        let axis = ProbeAxis("d", 0.25..<1.0001, simplest: 1, step: 1.0 / 128)
        var random = ProbeRandom(seed: 1)
        for _ in 0..<200 {
            let value = axis.value(at: random.nextUnit())
            #expect(((value - 0.25) * 128).rounded() == (value - 0.25) * 128)
            #expect(axis.range.contains(value))
        }
        #expect(axis.simplest == 1)
    }

    @Test("帰属の表に無い suite から呼ぶと、述語を回す前に赤の文を返す")
    func unlistedSuiteIsRefused() throws {
        var called = false
        let report = Probe.run("probe", suite: "NotInTheCatalog", key: "a", axes: Self.axes, cases: 5, environment: Self.quiet) { _ in
            called = true
            return .pass
        }
        #expect(!called)
        #expect(try #require(report.failure).contains("NotInTheCatalog が probe-catalog.tsv に無い"))
        // 表に在っても、名が違えば断る
        let misnamed = Probe.run("density", suite: "ProbeTests", key: "a", axes: Self.axes, cases: 5, environment: Self.quiet) { _ in .pass }
        #expect(try #require(misnamed.failure).contains("表では提案 probe"))
    }

    /// 表と木の整合 (行の suite の有無・呼び出し元の載せ忘れ) は scripts/tests/probe_catalog_test.py が
    /// 見る。ここで見るのは、実行時に表を読む Swift の読み手が崩れた行を黙って飛ばさないこと。
    @Test("帰属の表の読み手は、この木の表を読め、崩れた行は読めないと投げる")
    func catalogReaderRefusesBrokenRows() throws {
        #expect(try ProbeCatalog.entries().contains { $0.suite == "ProbeTests" && $0.name == "probe" })
        #expect(throws: ProbeCatalog.CatalogError.self) { _ = try ProbeCatalog.entries(text: "A\tdensity\n") }
    }
}
