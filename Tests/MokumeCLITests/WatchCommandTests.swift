// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation
import Testing
import mokume

@testable import MokumeCLI
@testable import MokumeCore

/// 見張りの口。
///
/// 巡回そのもの (何をどの順で決めるか) は `WatchSessionTests` が見る。ここが見るのは
/// **見張りを始める前と、終えるとき**である — どちらも口の側にしか無い。
@Suite("見張りの口", .signalStateKept)
struct WatchCommandTests {
    /// 巡回を数えるだけの外側。
    @MainActor
    final class Stub {
        var builds = 0
        var stamp: String? = "aaa"

        func hooks() -> WatchSession.Hooks {
            WatchSession.Hooks(
                rebuild: { directory in
                    self.builds += 1
                    // **建っていない回を模す。** 通ったのに走らせるものが無い形が、
                    // かつて成功として記録されていた (#1066)
                    return RunCommand.Rebuilt(
                        status: 0, output: "", executable: nil, binPath: directory,
                        product: "sketch")
                },
                launch: { _, _, _, _ throws(CommandFailure) in
                    throw .cannotLaunch(tool: "sketch", place: "/stub", reason: "the stub starts nothing")
                },
                now: { 0 },
                stamp: { _ in self.stamp })
        }
    }

    private func makeDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("mokume-watch-command-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// 宣言の抜けを持つスケッチ。`Package.swift` は在るが `resources:` を書いていない。
    private func makeSketchWithUndeclaredAssets() throws -> URL {
        let root = try makeDirectory()
        let assets = root.appendingPathComponent("Sources/demo/assets", isDirectory: true)
        try FileManager.default.createDirectory(at: assets, withIntermediateDirectories: true)
        try Data("画像のつもり".utf8).write(to: assets.appendingPathComponent("picture.png"))
        try Data(#"// swift-tools-version: 6.2"#.utf8)
            .write(to: root.appendingPathComponent("Package.swift"))
        return root
    }

    // MARK: - 起動より前に置く区画

    /// 窓口が使う区画は、子を起こす前に在る。
    ///
    /// 区画が在るかどうかを見るのは起動の瞬間だけなので、置き損ねると窓口の道具は初めて
    /// 呼んだ回に必ず空振りし、道具ごとに 1 回ずつ起動し直させることになる ([#464])。
    /// **窓も GPU も要さない** — 区画を置くのはただのファイル操作である。
    ///
    /// [#464]: https://github.com/mokume-metal/mokume/issues/464
    @Test("窓口が使う区画は、子を起こす前に置かれる")
    func facetsForTheAgentSurfaceArePlacedUpFront() throws {
        let base = try makeDirectory()

        let created = WatchCommand.prepareFacets(under: base)

        for key in ["observe", "input", "params"] {
            let facet = WorkDirectory.facet(key, under: base)
            #expect(
                WorkDirectory.directoryExists(at: facet),
                "\(key) の区画が、子を起こす前に置かれていない")
            #expect(created.contains(facet), "\(key) を作ったのに、畳む一覧へ入っていない")
        }
    }

    /// **絵を渡す区画は先回りしない。** 在ると窓を開かず共有面へ差し出す区画なので、
    /// 窓が出せなかった回に置くと絵がどこにも出ない ([ADR-0032] 決定 1)。
    ///
    /// [ADR-0032]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0032-window-ownership.md
    @Test("絵を渡す区画は、先回りしては置かない")
    func theViewportFacetIsNotPlacedUpFront() throws {
        let base = try makeDirectory()

        _ = WatchCommand.prepareFacets(under: base)

        #expect(!WorkDirectory.directoryExists(at: WatchCommand.viewportFacet(under: base)))
    }

    /// 人が置いた区画は、こちらの持ち物ではない。
    ///
    /// 外から動かすために人が置いた区画かもしれないので、**畳むのは自分が作ったものだけ**
    /// にする ([#464])。
    ///
    /// [#464]: https://github.com/mokume-metal/mokume/issues/464
    @Test("元から在った区画は、畳む一覧に入らない")
    func facetsThatWereAlreadyThereAreNotOursToRemove() throws {
        let base = try makeDirectory()
        let observe = WorkDirectory.facet("observe", under: base)
        try FileManager.default.createDirectory(at: observe, withIntermediateDirectories: true)

        let created = WatchCommand.prepareFacets(under: base)

        #expect(!created.contains(observe), "人が置いた区画を畳もうとしている")
        #expect(WorkDirectory.directoryExists(at: observe), "人が置いた区画が消えている")
        // 残りは今までどおり置く
        #expect(created.contains(WorkDirectory.facet("input", under: base)))
    }

    // MARK: - 始める前

    /// **走らせる口と同じものを、同じ形で通す。** 宣言の抜けはビルドを通ってしまうので、
    /// いちばん打つ口だけが素通りしていると、この検査はほとんど効かない ([#682])。
    ///
    /// [#682]: https://github.com/mokume-metal/mokume/issues/682
    @Test("宣言されていない資材があると、見張りは始まらない")
    func refusesToWatchUndeclaredResources() throws {
        let kept = SignalState.current()
        defer { kept.restore() }
        let root = try makeSketchWithUndeclaredAssets()
        // 巡回は差し替える。**始める前に止まることを見る検査**なので、止まらなかった
        // ときに合図待ちで固まってはいけない (固まった検査は赤より読みにくい)
        #expect(throws: CommandFailure.resourcesNotDeclared(directory: "Sources/demo/assets")) {
            try WatchCommand.run([root.path], watching: { _, _ in })
        }
    }

    /// **窓を出してから、最初の作り直しに入る。**
    ///
    /// 直に呼ぶと、窓が画面に出るのは初回の作り直しが終わってからになる — いちばん長く
    /// 待つのが初回なのに、待っている間だけ状態がどこにも出ない。端末では #695 が直した
    /// ことが、窓では直らない ([#705](https://github.com/mokume-metal/mokume/issues/705))。
    @Test("最初の作り直しは、巡回へ渡してから始まる")
    func firstBuildStartsInsideTheLoop() throws {
        let kept = SignalState.current()
        defer { kept.restore() }
        let root = try makeDirectory()
        try Data(#"// swift-tools-version: 6.2"#.utf8)
            .write(to: root.appendingPathComponent("Package.swift"))
        var handedOver: WatchSession?
        try WatchCommand.run([root.path], watching: { session, _ in handedOver = session })
        // 渡した時点で 1 度も作り直していない = 作り直しは巡回の中で始まる
        #expect(handedOver != nil)
        #expect(handedOver?.lastReport == nil)
    }

    /// **最初の拍は、巡回に入った直後に来る** ([#1789])。
    ///
    /// 最初の発火を「作った時刻 + 間隔」にすると、初回の作り直しが 1 拍ぶん無駄に待つ。
    ///
    /// [#1789]: https://github.com/mokume-metal/mokume/issues/1789
    @Test("巡回の最初の拍は 1 拍待たずに来る")
    func firstTickDoesNotWaitAnInterval() {
        let madeAt = Date()
        let timer = WatchCommand.loopTimer { _ in }
        defer { timer.invalidate() }
        #expect(timer.fireDate.timeIntervalSince(madeAt) < WatchCommand.interval / 2)
        #expect(timer.timeInterval == WatchCommand.interval)
    }

    /// **見張っている間だけ、省電力の間引きを断る。**
    ///
    /// 窓が覆われて前面から降りた道具は App Nap に入り、そこでは CPU の優先度の断りも
    /// 外れる — 機械が混んでいると入れ替わりも終わりの合図も数秒途切れる
    /// ([#1199](https://github.com/mokume-metal/mokume/issues/1199))。App Nap そのものは
    /// 検査で再現できないので、ここが見るのは**断りを立てる場所と返す場所**である。
    @Test("見張っている間は間引きを断り、終えたら返す")
    func refusesThrottlingWhileWatching() throws {
        let kept = SignalState.current()
        defer { kept.restore() }
        let root = try makeDirectory()
        try Data(#"// swift-tools-version: 6.2"#.utf8)
            .write(to: root.appendingPathComponent("Package.swift"))
        var heldInsideTheLoop = false

        try WatchCommand.run([root.path], watching: { _, _ in
            heldInsideTheLoop = WatchCommand.refusesThrottling
        })

        #expect(heldInsideTheLoop, "巡回に入る前に断っていない")
        #expect(!WatchCommand.refusesThrottling, "終えたのに断ったままになっている")
    }

    /// **見張りの口を続けて通しても、後の回の後始末が走る** ([#1937])。
    ///
    /// 後始末を済ませた印 (`WatchCommand.teardownDone`) はプロセスに 1 つで、一度立つと下りない
    /// (本番の見張りは 1 プロセスに 1 回)。前の検査が立てたまま残すと、後に走る検査の後始末が
    /// 冒頭で抜ける。窓を閉じないので駆動源が実行ループに残り、間引きの断りも返さない。
    /// 検査の順序に依らないように、印は ``SignalState`` が控えて戻す。
    ///
    /// [#1937]: https://github.com/mokume-metal/mokume/issues/1937
    @Test("見張りの口を続けて通しても、後の回の後始末が走る")
    func eachWatchTearsDownEvenAfterAnother() throws {
        for round in 1...2 {
            let kept = SignalState.current()
            defer { kept.restore() }
            let root = try makeDirectory()
            try Data(#"// swift-tools-version: 6.2"#.utf8)
                .write(to: root.appendingPathComponent("Package.swift"))

            try WatchCommand.run([root.path], watching: { _, _ in })

            #expect(WatchCommand.teardownDone, "\(round) 回目の後始末が走っていない")
            #expect(!WatchCommand.refusesThrottling, "\(round) 回目の後始末が間引きの断りを返していない")
        }
    }

    /// **見張りの終わりに、読まれずに残った起動の失敗の理由を掃く** (#3169)。止めている最中に失敗した子の理由は、
    /// 巡回が読む前に見張りが終わると誰にも読まれない。
    @Test("見張りの後始末は、読まれずに残った起動の失敗の理由を掃く")
    func teardownSweepsUnreadStartFailureNotes() throws {
        let kept = SignalState.current()
        defer { kept.restore() }
        let directory = try makeDirectory()
        let session = WatchSession(directory: directory, context: testContext(), hooks: Stub().hooks())
        let facet = WorkDirectory.facet(WorkDirectory.buildFacetName, under: directory)
        try FileManager.default.createDirectory(at: facet, withIntermediateDirectories: true)
        let stray = WorkDirectory.startFailureURL(forProcess: 99999, under: facet)
        try Data("left behind".utf8).write(to: stray)
        let record = BuildReport.statusURL(under: directory)
        try Data("{}".utf8).write(to: record)
        WatchCommand.teardownDone = false

        WatchCommand.teardown(session, nil)

        #expect(!FileManager.default.fileExists(atPath: stray.path), "残った理由を掃いていない")
        #expect(FileManager.default.fileExists(atPath: record.path), "記録まで消した")
    }

    /// **二度返しても落ちない。** 終わりの経路は 2 つある (巡回が抜けた・道具立てが
    /// 終わらせた) ので、返す側は何度呼ばれてもよい形でなければならない。
    @Test("断りを二度返しても落ちない")
    func releasingTheRefusalTwiceIsHarmless() {
        WatchCommand.refuseThrottling()
        #expect(WatchCommand.refusesThrottling)
        WatchCommand.allowThrottling()
        WatchCommand.allowThrottling()
        #expect(!WatchCommand.refusesThrottling)
    }

    /// **相手が居なくても落ちない。** 見張りは子を頻繁に入れ替えるので、既に居ない相手へ
    /// 書くことは必ず起きる ([ADR-0032](https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0032-window-ownership.md) 決定 4)。
    @Test("走らせているものが居なければ、書いても何も起きない")
    func sendingWithoutAChildIsHarmless() throws {
        let session = WatchSession(directory: try makeDirectory(), context: testContext(), hooks: Stub().hooks())
        session.send("{\"type\":\"mouseMoved\",\"x\":1,\"y\":2}\n")
    }

    // MARK: - プレビューへ重ねる行

    /// **端末が正で、プレビューはそれを映す。**
    ///
    /// プレビューは端末の代わりではないので ([#705](https://github.com/mokume-metal/mokume/issues/705)
    /// 完了条件 5)、ここだけで名乗る事実を作らない。
    @Test("作り直しが通ったら、重ねる行は畳む")
    func clearsTheNoticeOnSuccess() {
        #expect(WatchCommand.notice(for: report(ok: true), holdingPrevious: true) == nil)
    }

    /// **消すと見分けが付かなくなる。** 保存して印が消え、絵が変わらなければ、作り直しに
    /// 失敗したのか、変えた結果が同じだったのかが読めない。
    @Test("作り直しが通らなかったら、重ねる行は出したままにする")
    func keepsTheNoticeOnFailure() throws {
        let line = try #require(WatchCommand.notice(for: report(ok: false), holdingPrevious: true))
        #expect(line.contains(WatchCommand.holdingLine))
    }

    /// **前の版が居ない失敗を「前の版のまま」と言わない** ([#2875](https://github.com/mokume-metal/mokume/issues/2875))。
    /// 最初の 1 回と、子が自分で消えた後の回がこれに当たる。
    @Test("前の版が走っていない失敗は、走っている版が無いことを重ねる")
    func namesThatNothingRunsWhenThereIsNoPrevious() throws {
        let line = try #require(WatchCommand.notice(for: report(ok: false), holdingPrevious: false))
        #expect(!line.contains(WatchCommand.holdingLine), "\(line)")
        #expect(line.contains(WatchCommand.nothingRunningLine), "\(line)")
    }

    // MARK: - 通らなかったビルドの最初の error: の行 (#3087)

    private func failed(_ output: String) -> BuildReport {
        .failed(
            status: 1, output: output, stamp: nil, configuration: "debug",
            timings: BuildReport.Timings(detectMs: nil, buildMs: 1, relaunchMs: nil))
    }

    /// 例: 桁つきの `<パス>:<行>:<桁>: error: <文>`。手前の警告や note は拾わず、最初の 1 本を言い換えずに出す。
    @Test("通らなかった回の行に、最初の error: の行 (ファイル・行・桁・文) を添える")
    func addsTheFirstErrorLineToTheFailedBuildNotice() throws {
        let first = "/work/Sources/App/main.swift:12:5: error: cannot find 'circel' in scope"
        let output = """
            Building for debugging...
            /work/Sources/App/main.swift:3:9: warning: variable 'x' was never used
            \(first)
                circel(0, 0, 50)
                ^~~~~~
            /work/Sources/App/main.swift:20:1: error: expected '}' at end of brace statement
            error: fatalError
            """
        let line = try #require(WatchCommand.notice(for: failed(output), holdingPrevious: true))
        #expect(line == "The build failed — " + WatchCommand.holdingLine + "\n" + first, "\(line)")
        let nothing = try #require(WatchCommand.notice(for: failed(output), holdingPrevious: false))
        #expect(nothing.hasSuffix("\n" + first), "\(nothing)")
    }

    @Test("桁の無い形も拾い、色の制御列は落とす")
    func readsTheErrorLineWithoutAColumnAndStripsColour() throws {
        #expect(failed("a.swift:7: error: boom").firstErrorLine == "a.swift:7: error: boom")
        let coloured = "\u{1B}[1m/w/a.swift:7:2: \u{1B}[0;1;31merror: \u{1B}[0;1mboom\u{1B}[0m"
        #expect(failed(coloured).firstErrorLine == "/w/a.swift:7:2: error: boom")
    }

    /// ファイルと行が付かない `error:` の行 (リンクの失敗など)・`error:` が無い失敗は、今の行のまま。
    @Test("ファイルと行の付かない error: や error: の無い失敗は、今の行のまま")
    func leavesTheLineAloneWithoutAFileAndLine() {
        for output in ["", "error: link command failed", "ld: symbol(s) not found\nerror: fatalError"] {
            let line = WatchCommand.notice(for: failed(output), holdingPrevious: true)
            #expect(line == "The build failed — " + WatchCommand.holdingLine, "\(output)")
        }
    }

    @Test("長い error: の行は末尾を省く")
    func cutsALongErrorLine() throws {
        let long = "/w/a.swift:1:1: error: " + String(repeating: "y", count: 400)
        let error = try #require(failed(long).firstErrorLine)
        #expect(error.count == BuildReport.errorLineLimit)
        #expect(error.hasSuffix("…"))
        #expect(error.hasPrefix("/w/a.swift:1:1: error: yyy"))
    }

    /// **1 枚目の待ちは、待ちを置いた後の 1 度だけ畳む** (#2875)。2 つの窓が独立に合図を出すので
    /// 2 度目では畳まない。作り直しが始まった後に遅れて来た合図でも畳まない — 畳むと、
    /// 作り直しの行が消える。
    @Test("1 枚目の待ちは、待っている間の最初の合図でだけ畳む")
    func theFirstFrameWaitClosesOnceAndOnlyWhileWaiting() {
        let wait = FirstFrameWait()
        #expect(!wait.shown(.window), "待つ前の合図で畳んだ")
        wait.wait()
        wait.promoted(.window)
        wait.promoted(.preview)
        #expect(wait.shown(.window))
        #expect(!wait.shown(.preview), "もう片方の窓の合図でもう一度畳んだ")

        wait.wait()
        wait.promoted(.window)
        wait.settle()
        #expect(!wait.shown(.window), "作り直しが始まった後の遅れた合図で畳んだ")
    }

    /// **前の子の 1 枚目で、新しい子の待ちを畳まない** (#2875 の反証)。最初の世代は絵が来る前に
    /// 採用されるので、`setup()` の最中に保存すると、前の子の 1 枚目の合図が新しい子を待つ間に来る。
    /// 畳むのは、待ちを置いた後にその窓が乗り換えた世代の 1 枚目だけである。
    @Test("待ちを置いた後に乗り換えていない窓の 1 枚目では畳まない")
    func aLateFirstFrameOfThePreviousChildDoesNotClose() {
        let wait = FirstFrameWait()
        wait.wait()
        #expect(!wait.shown(.window), "前の子の 1 枚目で畳んだ")
        #expect(!wait.shown(.preview), "前の子の 1 枚目で畳んだ")
        // 新しい子へ乗り換えたのは作品の窓だけ。プレビューはまだ前の子を出している
        wait.promoted(.window)
        #expect(!wait.shown(.preview), "乗り換えていない窓の合図で畳んだ")
        #expect(wait.shown(.window))
    }

    /// 作り直しは通ったが子を起こせなかった回 (`ok: true, launched: false`) を、成功と同じに
    /// 畳まない ([#2574](https://github.com/mokume-metal/mokume/issues/2574))。畳むと窓の側は
    /// 「保存した → 絵が止まっている → 何も出ない」になる。
    @Test("起こせなかった回は、重ねる行に起こせなかったことと理由の頭 1 行を出す")
    func namesTheReasonWhenTheBuildPassedButNothingStarted() throws {
        let line = try #require(
            WatchCommand.notice(
                for: notStarted(reason: "Cannot start sketch: permission denied\nsecond line"),
                holdingPrevious: false))
        #expect(line == "Rebuilt, but could not start it: Cannot start sketch: permission denied")
        // 起こせた回は畳む (従来どおり)
        #expect(WatchCommand.notice(for: report(ok: true, launched: true), holdingPrevious: true) == nil)
    }

    /// **「could not start」を重ねず、長くても要点 (末尾の原因) が切れない。** 印は 1 行の小さな字で、
    /// 折り返しも省略もしないので、窓幅で切れると肝心の `(Permission denied)` が落ちる。実際の
    /// `cannotLaunch` の文面 (スキーマの代表例) で見る。
    @Test("実際の起こせなかった理由は、前置きを重ねず、短くしても原因が残る")
    func aRealReasonIsNotRepeatedAndKeepsItsCause() throws {
        let reason = try Self.exampleReason()
        let line = try #require(WatchCommand.notice(for: notStarted(reason: reason), holdingPrevious: false))
        #expect(line.lowercased().components(separatedBy: "could not start").count == 2, "言葉が重なっている: \(line)")
        #expect(line.hasPrefix("Rebuilt, but could not start hello"))
        #expect(line.count <= BuildReport.noticeLimit)
        #expect(line.hasSuffix("(Permission denied)"), "原因が切れている: \(line)")
    }

    /// **最初の絵を出す前に終わった子は、場所が長くても終わり方 (終了コード・合図) がプレビューの行に残る**
    /// (#3172 の反証)。末尾を残す詰め方だけでは、理由の末尾の「it exited with code 7 before …」が削られる。
    @Test("絵を出す前に終わった子の理由は、長い場所でも終わり方を残して詰める", arguments: [
        ("it exited with code 7", "code 7"), ("it crashed (signal 11)", "signal 11"),
    ])
    func theWayAChildEndedSurvivesTheNoticeLimit(how: String, kept: String) throws {
        let place = "/Users/someone/Documents/sketches/a-project-with-a-rather-long-name/inner"
        let reason = "Could not start sketch in \(place): \(how)" + BuildReport.firstFrameSuffix
        let line = try #require(WatchCommand.notice(for: notStarted(reason: reason), holdingPrevious: false))
        #expect(line.count <= BuildReport.noticeLimit, "\(line)")
        #expect(line.contains(kept), "終わり方が落ちている: \(line)")
        #expect(line.hasSuffix("before drawing its first frame"), "\(line)")
        #expect(line.hasPrefix("Could not start sketch"), "\(line)")
    }

    /// スキーマの代表例に載っている、実際の理由。
    private static func exampleReason() throws -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Schemas/examples/build-status-not-launched.json")
        let object = try #require(
            try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        return try #require(object["notStartedReason"] as? String)
    }

    /// 理由を渡さなくても、型が理由を持たせる。**理由なしの記録は作れない。**
    @Test("理由を渡さなかった起こせなかった回も、理由つきで出る")
    func aReportWithoutAReasonCannotBeBuilt() throws {
        let line = try #require(WatchCommand.notice(for: notStarted(reason: ""), holdingPrevious: false))
        #expect(line.hasSuffix("no reason was given"))
    }

    /// 終われと言われて起こさなかった回を「起こせなかった」と言わない (#2521 の規律)。
    @Test("終われと言われて起こさなかった回は、起こせなかったと言わない")
    func doesNotCallAnEndingWatchAFailureToStart() throws {
        let line = try #require(
            WatchCommand.notice(
                for: notStarted(reason: WatchSession.stopRequestedNotice), holdingPrevious: false))
        #expect(line == WatchSession.stopRequestedNotice)
        #expect(!line.contains("could not"))
    }

    private func notStarted(reason: String) -> BuildReport {
        .notStarted(
            reason: reason, buildOutput: "[1/2] Compiling…", stamp: nil, configuration: "debug",
            timings: BuildReport.Timings(detectMs: nil, buildMs: 1, relaunchMs: nil))
    }

    private func report(ok: Bool, launched: Bool = true) -> BuildReport {
        let timings = BuildReport.Timings(detectMs: nil, buildMs: 1, relaunchMs: nil)
        return ok
            ? .launched(output: "", stamp: nil, configuration: "debug", timings: timings)
            : .failed(status: 1, output: "", stamp: nil, configuration: "debug", timings: timings)
    }

    // MARK: - 書くとき

    /// **端末では、速さの行を消してから書く。** 走らせているスケッチは同じ 1 行を書き換え
    /// 続けているので、消さずに書くと作り直しの記録がその行の途中から続く形になる。
    @Test("端末へ書くときは、速さの行を消してから書く")
    func clearsTheRateLineOnATerminal() {
        let line = WatchCommand.line("作り直した", isTerminal: true)
        #expect(line.hasPrefix("\r"))
        #expect(line.contains("[2K"))
        #expect(line.hasSuffix("作り直した"))
    }

    /// **複数行は行ごとに消す** (#2521 の反証)。理由のように複数行を 1 度に書くと、先頭しか
    /// 消さない形では 2 行目以降に速さの行の残りが重なる。
    @Test("端末へ複数行を書くときは、行ごとに速さの行を消す")
    func clearsEveryLineOfAMultilineText() {
        let text = WatchCommand.line("1 行目\n2 行目", isTerminal: true)
        #expect(text == "\r\u{1B}[2K1 行目\n\r\u{1B}[2K2 行目")
    }

    /// **記録へ落とすときは飾らない。** 制御の文字がそのまま残ると読めない。
    @Test("端末でなければ、飾りを付けない")
    func doesNotDecorateARecord() {
        #expect(WatchCommand.line("作り直した", isTerminal: false) == "作り直した")
    }

    // MARK: - 終えるとき

    /// **合図はハンドラの外で効く。** ハンドラは印を立てるだけで、終わらせるのは巡回。
    @Test("終わりの合図を受けると、印が立つ")
    func raisesTheStopFlagOnSignal() {
        let kept = SignalState.current()
        defer { kept.restore() }
        WatchCommand.installStopHandlers()

        #expect(watchStopRequested == 0)
        raise(SIGTERM)
        #expect(watchStopRequested != 0)
    }

    /// **合図の検査は、走者の受け口と印を前の形へ戻す** ([#1937])。
    ///
    /// 前を見ずに既定へ戻すと、走者が無視で継いだ合図 (背面の起動の SIGINT など) まで既定に
    /// なる。ここでは見張りの受け口を置く前に、目印として SIGHUP を無視・SIGPIPE を既定にしておき、
    /// 見張りの口が立てる印と一緒に、戻した後に前の形へ戻っていることを見る。
    ///
    /// [#1937]: https://github.com/mokume-metal/mokume/issues/1937
    @Test("合図の検査の後、受け口と印は置く前の形へ戻る")
    func theSnapshotRestoresWhatWasThere() {
        let outer = SignalState.current()
        defer { outer.restore() }
        signal(SIGHUP, SIG_IGN)
        signal(SIGPIPE, SIG_DFL)
        WatchCommand.teardownDone = false

        let kept = SignalState.current()
        WatchCommand.installStopHandlers()
        raise(SIGHUP)
        WatchCommand.teardownDone = true
        runStopSignal = SIGTERM
        kept.restore()

        #expect(kept.changes().isEmpty, "戻した後も変わったままのものがある: \(kept.changes())")
        #expect(StopSignals.isIgnored(StopSignals.current(SIGHUP)), "無視で継いだ SIGHUP を戻していない")
        #expect(StopSignals.isDefault(StopSignals.current(SIGPIPE)), "既定だった SIGPIPE を無視のまま残した")
        #expect(watchStopRequested == 0, "合図で立った印を残した")
        #expect(!WatchCommand.teardownDone, "後始末の印を立てたまま残した")
        #expect(runStopSignal == 0, "道具の合図の印を残した")
    }

    /// **端末が消える形がいちばん多い。** 見張りを起こしたセッションが終わる経路で、
    /// [#454](https://github.com/mokume-metal/mokume/issues/454) の孤児はこの形をしている。
    @Test("受ける合図に、端末が消える形が入っている")
    func listensForTheHangUp() {
        #expect(WatchCommand.stopSignals.contains(SIGHUP))
        #expect(WatchCommand.stopSignals.contains(SIGINT))
        #expect(WatchCommand.stopSignals.contains(SIGTERM))
    }

    /// **時間切れで畳む形も受ける。** 期限を付けて起こした見張り (`alarm` + `exec`) が既定の
    /// 動作で消え、子が窓の無いまま 28 時間残った ([#1427](https://github.com/mokume-metal/mokume/issues/1427))。
    @Test("時間切れの合図 (SIGALRM) でも、印が立つ")
    func raisesTheStopFlagOnAlarm() {
        let kept = SignalState.current()
        defer { kept.restore() }
        WatchCommand.installStopHandlers()

        raise(SIGALRM)
        #expect(watchStopRequested != 0)
    }

    @Test("印が立つと、巡回を抜ける")
    func leavesTheLoopWhenStopped() async throws {
        let stub = Stub()
        let session = WatchSession(directory: try makeDirectory(), context: testContext(), hooks: stub.hooks())

        #expect(await WatchCommand.step(session, stopped: { false }))
        #expect(await !WatchCommand.step(session, stopped: { true }))
    }

    /// **終われと言われた後に、もう一度作り直さない。** 待っている間に来た合図を
    /// 見ないと、抜ける直前に子を 1 つ起こしてから終わることになる。
    @Test("待っている間に来た合図は、作り直しより先に効く")
    func doesNotRebuildAfterTheStopSignal() async throws {
        let stub = Stub()
        let session = WatchSession(directory: try makeDirectory(), context: testContext(), hooks: stub.hooks())
        await session.start()
        #expect(stub.builds == 1)

        stub.stamp = "bbb"  // 変化はある。合図が無ければ作り直す状況
        await WatchCommand.step(session, stopped: { true })

        #expect(stub.builds == 1)
        // **終われと言われた後の巡回も、作り直さない** (#2518)。世代を待つ間は合図を口が
        // 見られないので、見張りの側が覚えた合図で止める
        await session.tick()
        #expect(stub.builds == 1, "終われと言われた後の巡回で作り直した")

        // 合図が無ければ作り直す状況であることを、同じ場面 (別の見張り) で確かめる
        let control = Stub()
        let unstopped = WatchSession(
            directory: try makeDirectory(), context: testContext(), hooks: control.hooks())
        await unstopped.start()
        control.stamp = "bbb"
        await WatchCommand.step(unstopped, stopped: { false })
        #expect(control.builds == 2)
    }

    /// **止めたかどうかは別の出来事。** 走らせていたものが既に死んでいた場合と、
    /// こちらが止めた場合を同じ言い方にすると、孤児を追うときの手掛かりが消える。
    @Test("走らせているものが居なければ、止めたとは名乗らない")
    func doesNotClaimToHaveStoppedNothing() async throws {
        let stub = Stub()
        let session = WatchSession(directory: try makeDirectory(), context: testContext(), hooks: stub.hooks())
        await session.start()  // launch が nil を返すので子は居ない

        #expect(await session.stop() == .notRunning)
    }

    /// **窓から頼まれても、印は 1 つのまま。** 合図の置き場が増えると「終われと言われたか」
    /// の判定が経路ごとに分かれ、片方だけ直る形になる
    /// ([#826](https://github.com/mokume-metal/mokume/issues/826))。
    @Test("窓から終わりを頼まれると、シグナルと同じ印が立ち、巡回が抜ける")
    func raisesTheStopFlagFromTheWindow() async throws {
        let kept = SignalState.current()
        defer { kept.restore() }
        watchStopRequested = 0
        let stub = Stub()
        let session = WatchSession(directory: try makeDirectory(), context: testContext(), hooks: stub.hooks())

        #expect(await WatchCommand.step(session), "印が立つ前に抜けている")
        WatchCommand.requestStop()
        #expect(watchStopRequested != 0)
        #expect(await !WatchCommand.step(session), "窓から頼まれた印で抜けていない")
    }

    /// **押しどころの言葉を、窓の側で決めない** (#695 が端末の行で定めた規律)。
    ///
    /// 見ているのは綴りではなく、**続ける側と終える側が別の言葉であること**である。
    @Test("窓に出す問いは、口の側が持つ")
    func theQuestionComesFromTheCommand() {
        #expect(!WatchCommand.closeMessage.isEmpty)
        #expect(!WatchCommand.closeDetail.isEmpty)
        #expect(WatchCommand.closeConfirm != WatchCommand.closeCancel)
    }

    /// **置いていったものは、番号で名乗る。** ここまで来ると道具にできることは無いので、
    /// 落とすのは人である (#732)。
    @Test("消えなかったスケッチは、番号を添えて名乗る")
    func namesTheProcessItHadToAbandon() {
        #expect(WatchCommand.abandonedLine(pid: 4321).contains("4321"))
    }

    /// **落ちたのか、自分から終わったのかで読む人の次の一手が変わる** (#1103)。落ちたのなら
    /// 端末を遡る先があり、自分から終わったのならスケッチの側にそう書いてある。
    @Test("勝手に消えたスケッチは、終わり方と数字を添えて名乗る")
    func namesHowTheSketchDeparted() {
        let ended = WatchCommand.departedLine(.init(status: 11, wasSignalled: false))
        let crashed = WatchCommand.departedLine(.init(status: 11, wasSignalled: true))
        #expect(ended != crashed, "落ちたことと自分から終わったことが同じ言葉になっている")
        #expect(ended.contains("11"))
        #expect(crashed.contains("11"))
    }

    // MARK: - 作り直しを途中で止めたとき (#1147)

    /// **失敗と読み違えない。** 端末の要約は `Build failed:` で始まるので、止めた回が同じ
    /// 言葉で始まると「壊れていた」と読まれる。期限に掛かった回も「スケッチ」と言わない
    /// (#732 の規律を作り直しにも効かせる)。
    @Test("作り直しを止めた行は、作り直していなければ出ず、失敗やスケッチの言葉と混ざらない")
    func theStoppedRebuildLine() throws {
        #expect(WatchCommand.stoppedRebuildLine(nil) == nil, "作り直していないのに名乗っている")

        let outcomes: [WatchSession.StopOutcome] = [
            .notRunning, .terminated, .killed, .abandoned(pid: 4242),
        ]
        for outcome in outcomes {
            let line = try #require(WatchCommand.stoppedRebuildLine(outcome))
            #expect(
                line.hasPrefix(WatchSession.stoppedRebuildNotice), "\(outcome) の行が止めたことから始まらない")
            #expect(!line.contains("Build failed"), "\(outcome) の行が失敗の言葉を使っている")
            #expect(!line.contains("sketch"), "\(outcome) の行がスケッチを止めたと読める")
        }
        let abandoned = try #require(WatchCommand.stoppedRebuildLine(.abandoned(pid: 4242)))
        #expect(abandoned.contains("4242"), "残ったものを人が落とせる番号が無い")
    }
}
