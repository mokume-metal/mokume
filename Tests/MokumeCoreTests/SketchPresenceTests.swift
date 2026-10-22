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
/// 名乗りの経過は実時間で数える。検査が差し替えた `now` (作者の時計を動かすためのもの) を
/// 猶予より先へ進めても、プロセスの状態 (活性化の方針・状態バー) を変えてはならない。名乗ると
/// 同じプロセスで窓を開閉する検査の run loop を止め、`exit(0)` で要約を残さず終わらせる (#1527)。
///
/// **この検査が破れると、同じ実行の窓の検査を巻き込んで消える。** 赤を確かめるときは
/// `--filter` をこの検査だけに絞ること。
@Suite("名乗りの経過は実時間で数える", .enabled(if: RenderDevice.isAvailable, "対応する GPU が必要"))
@MainActor
struct SketchPresenceClockTests {
    private final class Blank: Sketch {
        init() {}
        let settings = SketchSettings(width: 16, height: 16)
    }

    /// 検査が進める `now`。参照で共有する。
    private final class Clockwork {
        var seconds = 0.0
    }

    @Test("差し替えた時計を猶予より先へ進めても、名乗らない")
    func replacedClockDoesNotAnnounce() throws {
        let clockwork = Clockwork()
        let runtime = try SketchRuntime(
            sketch: Blank(), gpu: RenderDevice(), clock: .wallClock, now: { clockwork.seconds })
        let policy = NSApplication.shared.activationPolicy()
        try runtime.advance()
        for step in [SketchPresence.grace - 1, SketchPresence.grace, SketchPresence.grace * 100] {
            clockwork.seconds = step
            try runtime.advance()
        }
        // 余計に回しても、メニューバーの出来事を取り出しに行かない
        try runtime.advance()
        #expect(!runtime.isPresenceAnnounced)
        #expect(NSApplication.shared.activationPolicy() == policy)
        // 名乗りの経過 (メニューの "up ...") も、差し替えた時計の進みを写さない
        #expect(runtime.presenceElapsed < SketchPresence.grace)
    }

    @Test("最初のフレームの前は 0 で、差し替えた時計が戻っても経過は負にならない")
    func elapsedStartsAtZeroAndIgnoresReplacedClock() throws {
        let clockwork = Clockwork()
        clockwork.seconds = 1000
        let runtime = try SketchRuntime(
            sketch: Blank(), gpu: RenderDevice(), clock: .wallClock, now: { clockwork.seconds })
        #expect(runtime.presenceElapsed == 0)
        try runtime.advance()
        clockwork.seconds = -1000
        try runtime.advance()
        #expect(runtime.presenceElapsed >= 0)
        #expect(runtime.presenceElapsed < SketchPresence.grace)
        #expect(!runtime.isPresenceAnnounced)
    }
}
