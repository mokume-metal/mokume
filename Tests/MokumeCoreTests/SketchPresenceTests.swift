// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import AppKit
import Testing

@testable import MokumeCore

/// 名乗りの**判断と文言**だけを見る検査。
///
/// メニューバーへ実際に物を出す部分はここでは触らない。出すと検査を走らせるたびに
/// メニューバーへ印が増えるうえ、出たかどうかは画面を見なければ分からない —
/// 名乗りが**実機の状態を正しく写しているか**は手元でしか確かめられないという意味で、
/// 描画が CI で回せないのと同じ性質である ([ADR-0019] 決定 7)。
///
/// だから境目の判断と文言の組み立ては純関数に切り出してあり、ここが見るのはそれである。
///
/// [ADR-0019]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0019-drawing-verification.md
@Suite("走っているスケッチの名乗り")
@MainActor
struct SketchPresenceTests {
    // MARK: - いつ名乗るか

    @Test("境目に届くまでは名乗らない")
    func staysQuietBeforeGrace() {
        #expect(!SketchPresence.shouldAnnounce(runningFor: 0))
        #expect(!SketchPresence.shouldAnnounce(runningFor: SketchPresence.grace - 0.001))
    }

    @Test("境目に届いたら名乗る")
    func announcesAtGrace() {
        #expect(SketchPresence.shouldAnnounce(runningFor: SketchPresence.grace))
        #expect(SketchPresence.shouldAnnounce(runningFor: SketchPresence.grace * 100))
    }

    // 「既に名乗っていたら二度と名乗らない」の検査はここに**無い**。
    //
    // かつては `shouldAnnounce` に `announced` を渡して確かめていたが、本番からそこへ渡る
    // のは常に `false` で (直前の `guard isAnnounced` が同じ判定を済ませている)、**検査は
    // 二度名乗らないことではなくその引数を確かめていた** (#960 の 7)。引数を落としたので
    // 検査も落とした。
    //
    // 守っているのは `SketchPresence.advanced(runningFor:)` の `guard isAnnounced` 1 つで、
    // 破れると印が毎フレーム増える。ここで覆えないのは、覆うには実際に名乗らせるしか
    // なく、**走らせるたびにメニューバーへ物が増える**ためである。

    /// 境目は「待っている実行」と「離れた実行」の間に**桁で**空いている必要がある
    /// (実測: 一括処理は 10 秒弱・#454 の孤児は 1.5 時間以上)。
    @Test("境目は一括処理より十分に長く、孤児より十分に短い")
    func graceSitsBetweenTheTwoScales() {
        #expect(SketchPresence.grace > 10)
        #expect(SketchPresence.grace < 600)
    }

    // MARK: - 経過の表記

    @Test("経過は分と秒で出る")
    func elapsedShowsMinutesAndSeconds() {
        #expect(SketchPresence.elapsedText(0) == "0:00")
        #expect(SketchPresence.elapsedText(9) == "0:09")
        #expect(SketchPresence.elapsedText(65) == "1:05")
        #expect(SketchPresence.elapsedText(599) == "9:59")
    }

    /// #454 で残っていたのは 1.5〜2.5 時間ぶんだった。**分だけで表すと 3 桁になって読めない。**
    @Test("1 時間を越えたら時間まで出る")
    func elapsedShowsHours() {
        #expect(SketchPresence.elapsedText(3600) == "1:00:00")
        #expect(SketchPresence.elapsedText(3661) == "1:01:01")
        #expect(SketchPresence.elapsedText(9000) == "2:30:00")
    }

    /// 時計が巻き戻る形の値を渡されても、負の経過という読めない行を出さない。
    @Test("負の経過は 0 として出る")
    func elapsedClampsBelowZero() {
        #expect(SketchPresence.elapsedText(-5) == "0:00")
    }

    // MARK: - 出所の畳み方

    @Test("ホームディレクトリは ~ に畳む")
    func shortenFoldsHome() {
        #expect(SketchPresence.shorten("/Users/x/work", home: "/Users/x") == "~/work")
        #expect(SketchPresence.shorten("/Users/x", home: "/Users/x") == "~")
    }

    /// **前方一致だけで畳むと、隣の名前まで巻き込む。**
    @Test("ホームと似た名前のディレクトリは畳まない")
    func shortenKeepsSiblingsOfHome() {
        #expect(SketchPresence.shorten("/Users/xy/work", home: "/Users/x") == "/Users/xy/work")
    }

    /// メニューの幅は一番長い行が決めるので、深い worktree を素で出すと
    /// プレビューが押しやられる。
    @Test("長すぎる出所は末尾を残して畳む")
    func shortenKeepsTail() {
        let path = "/Users/x/" + String(repeating: "deep/", count: 20) + "worktrees/issue-473"
        let shortened = SketchPresence.shorten(path, home: "/Users/x", limit: 30)
        #expect(shortened.count == 30)
        #expect(shortened.hasPrefix("…"))
        // **どの worktree かは末尾に出る。**頭から削るのはそれを残すためである
        #expect(shortened.hasSuffix("worktrees/issue-473"))
    }

    @Test("収まる出所はそのまま出る")
    func shortenLeavesShortPathsAlone() {
        #expect(SketchPresence.shorten("~/a/b", home: "", limit: 30) == "~/a/b")
    }

    // MARK: - 名乗りの中身

    @Test("題名・素性・出所が揃う")
    func describesTitleIdentityAndOrigin() {
        let description = SketchPresence.describe(
            title: "夜の海", executable: "evidence", pid: 4321,
            directory: "/Users/x/mokume", home: "/Users/x", elapsed: 5432)
        #expect(description.title == "夜の海")
        // 実行バイナリ名と PID を添えるのは、**題名だけでは見分けが付かない**ため。
        // 既定の題名は全スケッチ共通で、#454 で並んでいたのは同じ evidence が 4 本だった
        #expect(description.identity == "evidence · PID 4321 · up 1:30:32")
        #expect(description.origin == "~/mokume")
    }

    /// 題名を空にしたスケッチでも、名前の無い行を出さない。
    @Test("題名が空なら実行バイナリ名で名乗る")
    func fallsBackToExecutableName() {
        let description = SketchPresence.describe(
            title: "", executable: "evidence", pid: 1, directory: "/tmp", home: "/Users/x",
            elapsed: 0)
        #expect(description.title == "evidence")
    }
}

/// 名乗りの**時計の出どころ**を、`SketchRuntime` を通して見る検査 (#3119)。
///
/// 名乗りの経過は「作者の時計 (`now`) での経過」と「実時間での経過」の**小さいほう**で数える。
/// 検査が差し替えた `now` だけが進んでも、実時間だけが進んでも (`now` を止めた検査が混んだ機械で
/// 待たされる)、名乗ってはならない。名乗るとプロセス全体の状態が変わり、同じプロセスで窓を開閉する
/// 検査の run loop を止め、`exit(0)` で要約を残さず終わらせる (#1527)。
///
/// **名乗りそのものは起こさない。** 最初のフレームで起点を作ったあと、時計を進めて `advance()` を
/// **呼ばずに**、経過 (``SketchRuntime/presenceElapsed``) と判定 (``SketchPresence/shouldAnnounce(runningFor:)``)
/// だけを読む。退行しても、この検査が名乗って同じ実行の窓の検査を巻き込むことはない。
@Suite("名乗りの経過は実時間でも数える", .enabled(if: RenderDevice.isAvailable, "対応する GPU が必要"))
@MainActor
struct SketchPresenceClockTests {
    private final class Blank: Sketch {
        init() {}
        let settings = SketchSettings(width: 16, height: 16)
    }

    /// 検査が進める 2 つの時計。参照で共有する。
    private final class Clockwork {
        var author = 0.0
        var real = 0.0
    }

    /// 最初のフレームだけ進めて起点を立てたランタイム。
    private func started(_ clockwork: Clockwork) throws -> SketchRuntime {
        let runtime = try SketchRuntime(
            sketch: Blank(), gpu: RenderDevice(), clock: .wallClock, now: { clockwork.author },
            presenceClock: { clockwork.real })
        try runtime.advance()
        return runtime
    }

    @Test(
        "作者の時計と実時間の両方が猶予を越えたときだけ、名乗るべきになる",
        arguments: [
            // (作者の時計の進み, 実時間の進み, 名乗るべきか)。進みは猶予の何倍か
            (100.0, 0.0, false),
            (0.0, 100.0, false),
            (100.0, 100.0, true),
            (0.0, 0.0, false),
            // 境界: 猶予ちょうどで名乗り、手前では名乗らない。小さいほうが決める
            (1.0, 1.0, true),
            (100.0, 0.99, false),
        ])
    func announcesOnlyWhenBothClocksPassTheGrace(author: Double, real: Double, expected: Bool) throws {
        let clockwork = Clockwork()
        let runtime = try started(clockwork)
        clockwork.author += author * SketchPresence.grace
        clockwork.real += real * SketchPresence.grace
        #expect(SketchPresence.shouldAnnounce(runningFor: runtime.presenceElapsed) == expected)
        // `advance()` は呼んでいない。名乗りそのものは起こさない
        #expect(!runtime.isPresenceAnnounced)
    }

    @Test("最初のフレームの前は 0 で、どちらの時計が戻っても経過は負にならない")
    func elapsedStartsAtZeroAndNeverGoesNegative() throws {
        let clockwork = Clockwork()
        clockwork.author = 1000
        clockwork.real = 1000
        let runtime = try SketchRuntime(
            sketch: Blank(), gpu: RenderDevice(), clock: .wallClock, now: { clockwork.author },
            presenceClock: { clockwork.real })
        clockwork.author = 5000
        #expect(runtime.presenceElapsed == 0)
        try runtime.advance()
        clockwork.author = -1000
        clockwork.real = -1000
        #expect(runtime.presenceElapsed == 0)
    }
}
