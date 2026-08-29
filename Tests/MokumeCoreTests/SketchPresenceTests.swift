// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

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
        #expect(!SketchPresence.shouldAnnounce(runningFor: 0, announced: false))
        #expect(
            !SketchPresence.shouldAnnounce(
                runningFor: SketchPresence.grace - 0.001, announced: false))
    }

    @Test("境目に届いたら名乗る")
    func announcesAtGrace() {
        #expect(SketchPresence.shouldAnnounce(runningFor: SketchPresence.grace, announced: false))
        #expect(SketchPresence.shouldAnnounce(runningFor: SketchPresence.grace * 100, announced: false))
    }

    /// 名乗りは毎フレーム判断されるので、**2 度目を弾けないと印が毎フレーム増える。**
    @Test("既に名乗っていたら二度と名乗らない")
    func announcesOnlyOnce() {
        #expect(!SketchPresence.shouldAnnounce(runningFor: SketchPresence.grace, announced: true))
        #expect(!SketchPresence.shouldAnnounce(runningFor: .infinity, announced: true))
    }

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
        #expect(description.identity == "evidence · PID 4321 · 経過 1:30:32")
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
