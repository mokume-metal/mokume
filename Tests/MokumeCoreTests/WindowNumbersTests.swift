// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation
import MokumeTestSupport
import Testing

@testable import MokumeCore

/// 速さを数える集計器。
///
/// **「測れていない」を 0 で表さない** ([ADR-0030](https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0030-parameter-surfaces.md) 決定 7)。
/// 0 は「測ったら 0 だった」と読めるが、起動直後も止めている間もまだ測れていない。
@Suite("フレームの速さを数える")
struct FrameTempoTests {
    private func tempo(_ moments: [Double]) -> FrameTempo {
        var tempo = FrameTempo()
        for moment in moments { tempo.record(now: moment) }
        return tempo
    }

    /// 起点を 0 に置いたまま 1 枚目を迎えると、「1 枚 ÷ 起動からの長い時間」が
    /// **0.0 という嘘の数字**になる。最初のフレームは間隔を開くだけにする。
    @Test("1 枚目では、まだ測れていない")
    func theFirstFrameOnlyOpensTheInterval() {
        #expect(tempo([]).frameRate(now: 0) == nil)
        #expect(tempo([100]).frameRate(now: 100) == nil)
        #expect(tempo([100]).frameTimeMs(now: 100) == nil)
    }

    @Test("2 枚目からは速さが出る")
    func rateAppearsFromTheSecondFrame() throws {
        let rate = try #require(tempo([0, 0.02]).frameRate(now: 0.02))
        #expect(abs(rate - 50) < 0.001)
    }

    @Test("速さは直近の間隔の平均から出る")
    func rateComesFromTheMeanInterval() throws {
        // 間隔は 0.01 と 0.03 なので平均 0.02 → 50fps
        let rate = try #require(tempo([0, 0.01, 0.04]).frameRate(now: 0.04))
        #expect(abs(rate - 50) < 0.001)
    }

    @Test("フレーム時間は平均と最大の両方を返す")
    func frameTimeCarriesTheWorstCase() throws {
        let time = try #require(tempo([0, 0.01, 0.04]).frameTimeMs(now: 0.04))
        #expect(abs(time.mean - 20) < 0.001)
        #expect(abs(time.max - 30) < 0.001)
    }

    /// 止めたスケッチは最後に測った値を残し続ける。**古い数字を名乗らない。**
    @Test("しばらく進んでいなければ、測れていないへ戻る")
    func stopsClaimingAStaleRate() {
        let stopped = tempo([0, 0.02])
        #expect(stopped.frameRate(now: 0.02 + FrameTempo.staleAfter - 0.001) != nil)
        #expect(stopped.frameRate(now: 0.02 + FrameTempo.staleAfter) == nil)
        #expect(stopped.frameTimeMs(now: 0.02 + FrameTempo.staleAfter) == nil)
    }

    /// 時計を寄せ直した直後は時間が巻き戻りうる。負の間隔を混ぜると平均が壊れる。
    @Test("時間が巻き戻った回は数えない")
    func ignoresTimeGoingBackwards() throws {
        let rate = try #require(tempo([0, 0.02, 0.01, 0.04]).frameRate(now: 0.04))
        // 数えたのは 0.02 と 0.03 の 2 回だけ (平均 0.025 → 40fps)
        #expect(abs(rate - 40) < 0.001)
    }

    @Test("遡るのは直近の窓のぶんだけ")
    func onlyTheRecentWindowCounts() throws {
        var moments = [0.0]
        // 最初は遅く、そのあとずっと速い
        moments.append(1.0)
        for step in 1...FrameTempo.window { moments.append(1.0 + Double(step) * 0.01) }
        let rate = try #require(tempo(moments).frameRate(now: moments.last!))
        // 最初の 1 秒の間隔が窓から押し出されているので 100fps に寄る
        #expect(abs(rate - 100) < 0.001)
    }
}

/// 窓に出る数字の表記。
///
/// **測れていない値の表明を、窓の中で揃える** (決定 7)。1 つの表示だけが `0` を出す
/// 状態にしない。
@Suite("窓に出る数字の表記")
struct WindowNumbersTextTests {
    private func cells(_ numbers: FrameNumbers) -> [String: String] {
        Dictionary(uniqueKeysWithValues: KnobText.numbers(numbers).map { ($0.label, $0.value) })
    }

    @Test("測れていない値は、どれも同じ 1 つの綴りで出る")
    func unmeasuredValuesShareOneSpelling() {
        let shown = cells(
            FrameNumbers(frameCount: 0, time: 0, frameRate: nil, frameTimeMs: nil))
        #expect(shown["fps"] == KnobText.notMeasured)
        #expect(shown["ms"] == KnobText.notMeasured)
    }

    /// **0 と書かない。** 測れた 0 と区別が付かなくなる。
    @Test("測れていない値が 0 に化けない")
    func unmeasuredValuesNeverBecomeZero() {
        let shown = cells(
            FrameNumbers(frameCount: 0, time: 0, frameRate: nil, frameTimeMs: nil))
        for (label, value) in shown where label == "fps" || label == "ms" {
            #expect(value != "0")
            #expect(value != "0.0")
            #expect(value != "0.00")
        }
    }

    @Test("測れている値は数字で出る")
    func measuredValuesAreShownAsNumbers() {
        let shown = cells(
            FrameNumbers(frameCount: 42, time: 1.25, frameRate: 59.94, frameTimeMs: 16.68))
        #expect(shown["fps"] == "59.9")
        #expect(shown["ms"] == "16.7")
        #expect(shown["frame"] == "42")
        #expect(shown["t"] == "1.25")
    }

    /// 数え上げは常に測れている。**欠測になりうるものだけが欠測を名乗る。**
    @Test("進めた枚数と時刻は、いつでも数字で出る")
    func countsAreAlwaysMeasured() {
        let shown = cells(
            FrameNumbers(frameCount: 0, time: 0, frameRate: nil, frameTimeMs: nil))
        #expect(shown["frame"] == "0")
        #expect(shown["t"] == "0.00")
    }

    /// 予算を越えた数は数え上げなので常に数字で、いちばん重いフレームは測るまで欠測 (#2601)。
    @Test("予算を越えた数と、いちばん重かったフレームの番号が出る")
    func overBudgetFramesAndTheHeaviestAreShown() {
        let fresh = cells(FrameNumbers(frameCount: 0, time: 0, frameRate: nil, frameTimeMs: nil))
        #expect(fresh["slow"] == "0")
        #expect(fresh["worst"] == KnobText.notMeasured)
        let slowed = cells(
            FrameNumbers(
                frameCount: 120, time: 1.98, frameRate: 58, frameTimeMs: 17.2,
                overBudgetFrames: 3, heaviestFrame: 97))
        #expect(slowed["slow"] == "3")
        #expect(slowed["worst"] == "#97")
    }

    /// 走っているのが別のプロセスのときは、数字そのものが届いていないことがある (#718)。
    /// **そのときは枚数も時刻も欠測である** — 進んでいない相手の枚数を 0 と書くと、
    /// 「1 枚目を描いたところ」と区別が付かなくなる。
    @Test("数字が届いていなければ、どれも同じ綴りで出る")
    func nothingArrivedShowsOneSpellingEverywhere() {
        let shown = KnobText.numbers(nil)
        #expect(shown.map(\.label) == ["fps", "ms", "frame", "t", "slow", "worst"])
        #expect(shown.allSatisfy { $0.value == KnobText.notMeasured })
    }
}

/// 別のプロセスが数えた速さを保つ側 (#718)。
///
/// **面に載った数字は、書いた側が消えても残り続ける。** 子が死んでも固まっても最後の
/// 数字はそこに在るので、受け取ってからの古さで打ち切る。
@Suite("面から届いた速さ")
struct RemoteTempoTests {
    private let numbers = FrameNumbers(
        frameCount: 12, time: 0.2, frameRate: 60, frameTimeMs: 16.7)

    @Test("まだ何も届いていなければ、測れていない")
    func nothingArrivedYet() {
        #expect(RemoteTempo().numbers(now: 0) == nil)
        #expect(RemoteTempo().numbers(now: 1000) == nil)
    }

    /// **数え直さない** (ADR-0030 決定 7)。受け取ったものをそのまま返す。
    @Test("届いた数字はそのまま返る")
    func whatArrivedComesBackUnchanged() throws {
        var tempo = RemoteTempo()
        tempo.record(numbers, at: 100)
        #expect(try #require(tempo.numbers(now: 100)) == numbers)
    }

    /// しきい値は集計器と**同じもの**を使う (`FrameTempo.staleAfter`) — 同じ問いに 2 つの
    /// しきい値を持つと、片方だけ直した日に窓と応答が違うことを言い始める。
    @Test("しばらく届かなければ、測れていないへ戻る")
    func stopsClaimingAStaleNumber() {
        var tempo = RemoteTempo()
        tempo.record(numbers, at: 100)
        #expect(tempo.numbers(now: 100 + FrameTempo.staleAfter - 0.001) != nil)
        #expect(tempo.numbers(now: 100 + FrameTempo.staleAfter) == nil)
    }

    @Test("また届けば、また名乗る")
    func aFreshNumberRevivesIt() {
        var tempo = RemoteTempo()
        tempo.record(numbers, at: 100)
        #expect(tempo.numbers(now: 100 + FrameTempo.staleAfter) == nil)
        tempo.record(numbers, at: 100 + FrameTempo.staleAfter)
        #expect(tempo.numbers(now: 100 + FrameTempo.staleAfter) != nil)
    }
}

/// **窓に出る数字と、面が返す数字が同じ源から来ること** (決定 7)。
///
/// 一致させる努力ではなく、**同じ源から来る構造で一致する**。源が 2 つに割れたら
/// この検査が落ちる — 2 つの集計器が同じ値を出し続ける偶然は無い。
@Suite(
    "窓の数字と面の数字は同じ源",
    .enabled(
        if: RenderDevice.isAvailable,
        "この世代のコマンド構造に対応した GPU が無い実行環境ではスキップする")
)
@MainActor
struct WindowNumbersSourceTests {
    final class Blank: Sketch {
        var settings = SketchSettings(width: 8, height: 8, frameRate: 60)
        init() {}
        func draw() { background(.linear(red: 0, green: 0, blue: 0)) }
    }

    private func makeFacet() throws -> URL {
        let directory = try TestScratch.directory("mokume-numbers")
        return directory
    }

    private func load(in facet: URL) throws -> [String: Any] {
        let data = try Data(contentsOf: facet.appendingPathComponent("report.json"))
        let report = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
        return report["load"] as? [String: Any] ?? [:]
    }

    @Test("窓が読む速さと、応答が返す速さが一致する")
    func theWindowAndTheReportAgree() throws {
        let facet = try makeFacet()
        var clock = 0.0
        let runtime = try SketchRuntime(
            sketch: Blank(), gpu: try RenderDevice(), clock: nil, now: { clock },
            observer: FrameObserver(directory: facet))
        for _ in 0..<8 {
            clock += 0.02
            try runtime.advance()
        }
        try AtomicFile.write(
            Data(#"{"id":"a1"}"#.utf8), to: facet.appendingPathComponent("request.json"))
        clock += 0.02
        try runtime.advance()

        // 時計を止めたまま両方を読む。**同じ源なら、丸めも遅れも入りようがない**
        let window = runtime.frameNumbers
        let reported = try load(in: facet)
        #expect(window.frameRate == reported["frameRate"] as? Double)
        let frameTime = reported["frameTimeMs"] as? [String: Any] ?? [:]
        #expect(window.frameTimeMs == frameTime["mean"] as? Double)
        #expect(window.frameRate != nil, "そもそも測れていない (一致だけでは何も示せない)")
    }

    /// 観測が無効でも窓は数字を出す。**ここを観測に紐づけると、窓が自分で測り直す**
    /// ことになり、源が 2 つに割れる。
    @Test("観測が無くても、窓の数字は測れている")
    func numbersAreMeasuredWithoutTheObserver() throws {
        var clock = 0.0
        let runtime = try SketchRuntime(
            sketch: Blank(), gpu: try RenderDevice(), clock: nil, now: { clock },
            observer: nil)
        for _ in 0..<4 {
            clock += 0.02
            try runtime.advance()
        }
        let numbers = runtime.frameNumbers
        #expect(numbers.frameRate != nil)
        #expect(numbers.frameCount == 4)
    }

    /// 応答の側の欠測の形。**鍵ごと省く** — 窓が「—」と描くのと同じ意味である。
    @Test("測れていない値は、応答から鍵ごと消える")
    func unmeasuredValuesAreOmittedFromTheReport() throws {
        let empty = RuntimeLoad.sample(tempo: FrameTempo(), budget: FrameBudget(frameRate: 60), now: 0)
        let encoded = try JSONEncoder().encode(empty)
        let object = try JSONSerialization.jsonObject(with: encoded) as? [String: Any] ?? [:]
        #expect(object["frameRate"] == nil)
        #expect(object["frameTimeMs"] == nil)
        #expect(object["heaviestFrame"] == nil)
        #expect(object["thermalState"] != nil)
    }

    // MARK: - 警告の欄 (#3087)

    @Test("警告を 1 つも言っていなければ、欄は出さない")
    func noWarningsNoReadout() {
        #expect(KnobText.warnings(nil) == nil)
    }

    /// 件数は数だけを差し込む (単複で語を選ばない・ADR-0038 決定 3)。最後の 1 行は端末に出た文面のまま。
    @Test("件数と最後の 1 行を、文面を言い換えずに出す")
    func warningsShowTheCountAndTheLastLine() throws {
        let line = "Transforms are written again every frame, so call this from draw()."
        let shown = try #require(KnobText.warnings(WarningSummary(count: 1, last: line)))
        #expect(shown.count == "1")
        #expect(shown.last == line)
        #expect(try #require(KnobText.warnings(WarningSummary(count: 12, last: line))).count == "12")
    }

    @Test("最後の 1 行の改行は畳み、長ければ末尾を省く")
    func warningLinesAreFlattenedAndCut() throws {
        let folded = try #require(KnobText.warnings(WarningSummary(count: 1, last: "first\nsecond")))
        #expect(folded.last == "first second")

        let long = String(repeating: "x", count: WarningSummary.lineLimit + 50)
        let cut = try #require(KnobText.warnings(WarningSummary(count: 1, last: long))).last
        #expect(cut.count == WarningSummary.lineLimit)
        #expect(cut.hasSuffix("…"))
        #expect(cut.hasPrefix("xxxx"), "頭を残していない")
    }
}
