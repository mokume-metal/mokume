// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation
import Testing
import mokume

@testable import MokumeCLI

@Suite("保存したら作り直して差し替える")
struct WatchSessionTests {
    /// 差し替えた外側の記録。
    @MainActor
    final class Recorder {
        var stamp: String? = "aaa"
        var buildStatus: Int32 = 0
        var buildOutput = "Build complete!"
        var clock: Double = 0
        var builds = 0
        var launches = 0
        var stampsGivenToChildren: [String?] = []
        /// 子へ渡した速さの名乗り。**渡さないと決めたときは nil であること**を見る
        var ratesGivenToChildren: [String?] = []
        /// 作り直しを頼まれた場所。**パッケージの場所であることを見る** (#331)
        var builtIn: [URL] = []
        /// 作り直しに入ったところ。**名乗りとの順序**を見るために要る。
        var onBuild: () -> Void = {}
        /// 走らせるものが建ったか。**通ったのに建っていない回**を作れるようにしてある。
        var productBuilt = true
        /// 作り直しの最中に待たせる口。**既定は何もしない。**
        ///
        /// 作り直しが main actor を離れたかどうかは、**離れている間に別の仕事が進むか**
        /// でしか見えない (#834)。ここで待たせて、その隙に main actor の仕事を積む。
        var whileBuilding: () async -> Void = {}

        func hooks() -> WatchSession.Hooks {
            WatchSession.Hooks(
                rebuild: { directory in
                    self.onBuild()
                    self.builds += 1
                    self.builtIn.append(directory)
                    await self.whileBuilding()
                    // 作り直しには時間がかかる。刻む対象なので時計を進める
                    self.clock += 0.5
                    let bin = directory.appendingPathComponent("bin")
                    return RunCommand.Rebuilt(
                        status: self.buildStatus, output: self.buildOutput,
                        executable: self.productBuilt ? bin : nil, binPath: directory)
                },
                launch: { _, _, stamp, rate in
                    self.launches += 1
                    self.stampsGivenToChildren.append(stamp)
                    self.ratesGivenToChildren.append(rate)
                    self.clock += 0.03
                    return nil
                },
                now: { self.clock },
                stamp: { _ in self.stamp })
        }
    }

    /// **人が見ている前でだけ足す。** 見張りを打った人には速さが要るが、機械が読む経路の
    /// 出力は 1 バイトも変えない ([ADR-0029] 決定 5 の 2 番目)。
    @Test("名乗ると決めた見張りは、構成の名前を子へ渡す")
    func aReportingSessionHandsTheConfigurationToTheChild() async throws {
        let recorder = Recorder()
        let session = WatchSession(
            directory: try makeDirectory(), context: testContext(configuration: "release"), reportsRate: true,
            hooks: recorder.hooks())

        let report = await session.start()
        #expect(recorder.ratesGivenToChildren == ["release"])
        // **名乗りは 1 つの値から出る。** 子へ渡す名前と記録の名前が別々に決まると、
        // 読み手はどちらが実体か判定できない (#680)
        #expect(report.configuration == "release")
    }

    /// **選ばれていなければ道具立ての既定に任せ、名乗りだけ既定の名前を使う。**
    /// ここで `-c debug` と書き固めると、道具立てが既定を変えた日に黙ってずれる。
    @Test("構成が選ばれていなければ、道具立てへ渡す指定を持たない")
    func leavesTheDefaultConfigurationToTheToolchain() throws {
        let session = WatchSession(directory: try makeDirectory(), context: testContext(), hooks: Recorder().hooks())
        #expect(session.context.configuration == nil)
        #expect(session.context.configurationName == RunCommand.defaultConfigurationName)
        #expect(RunCommand.configurationArguments(session.context.configuration).isEmpty)
    }

    /// **始めることを、始める前に言う。** 作り直しはこの流れを塞ぐので、後から言うと
    /// 待っている間が無言になり、「見張れていない」と読まれる ([#695](https://github.com/mokume-metal/mokume/issues/695))。
    @Test("作り直しは、始める前に名乗る")
    func announcesBeforeItRebuilds() async throws {
        let recorder = Recorder()
        let session = WatchSession(directory: try makeDirectory(), context: testContext(), hooks: recorder.hooks())
        var events: [String] = []
        session.willRebuild = { events.append($0 ? "初回を始める" : "変更で始める") }
        recorder.onBuild = { events.append("作り直す") }

        await session.start()
        recorder.stamp = "bbb"
        await session.tick()

        #expect(events == ["初回を始める", "作り直す", "変更で始める", "作り直す"])
    }

    /// **名乗らないのが既定。** 窓口はスケッチを起こさないが、口の側が何も渡さなければ
    /// 何も起きないことを、ここで固定しておく。
    @Test("名乗りを渡さなければ、何も起きない")
    func staysSilentWithoutAListener() async throws {
        let recorder = Recorder()
        let session = WatchSession(directory: try makeDirectory(), context: testContext(), hooks: recorder.hooks())
        await session.start()
        #expect(recorder.builds == 1)
    }

    private func makeDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("mokume-watch-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// **通ったことと、走らせるものが在ることは別である。**
    ///
    /// かつてここは分かれていなかった — 実行ファイルを解決できなかった回も `ok: true` で
    /// 記録され、症状は「保存した → 作り直したと出た → 絵が止まっている」で、**記録の
    /// どこにも理由が出なかった** ([#1066](https://github.com/mokume-metal/mokume/issues/1066))。
    /// 置き場を共有すると、他のプロセスが実行ファイルを消した瞬間にこれを踏める。
    @Test("作り直しは通ったのに建っていない回は、成功として記録しない")
    func aRebuildThatBuiltNothingIsNotRecordedAsSuccess() async throws {
        let recorder = Recorder()
        recorder.productBuilt = false
        let session = WatchSession(
            directory: try makeDirectory(), context: testContext(product: "hello"),
            hooks: recorder.hooks())

        let report = await session.start()
        #expect(!report.ok, "建っていない回を成功として記録している")
        #expect(!report.launched)
        #expect(recorder.launches == 0, "走らせるものが無いのに起こそうとしている")
        // **記録に理由が出る。** 終了コードは 0 なので、それだけでは読み手に何も届かない
        #expect(report.output.contains("hello"))
        #expect(report.output.contains("was never built"))
        #expect(report.summary.contains("Build failed"))
        // 走っているものは落とさない (作り直しの失敗と同じ扱い)
        #expect(report.timings.relaunchMs == nil)
    }

    /// 起こせなかったことも記録に出る。**作り直しの失敗とは別の状態**である。
    @Test("建ったのに起こせなかった回は、そう名乗る")
    func aRebuildThatCouldNotLaunchSaysSo() async throws {
        let recorder = Recorder()
        let session = WatchSession(
            directory: try makeDirectory(), context: testContext(), hooks: recorder.hooks())

        // Recorder の launch は常に nil を返す (子を作らない)
        let report = await session.start()
        #expect(report.ok, "作り直し自体は通っている")
        #expect(!report.launched)
        #expect(report.summary.contains("could not start it"))
    }

    @Test("最初の 1 回は、変化を待たずに作って走らせる")
    func buildsOnceAtTheStart() async throws {
        let recorder = Recorder()
        let session = WatchSession(
            directory: try makeDirectory(), context: testContext(), hooks: recorder.hooks())

        let report = await session.start()
        #expect(recorder.builds == 1)
        #expect(recorder.launches == 1)
        // 名乗ると決めていない見張りは、子へ速さの名乗りを渡さない (窓口の側の既定)
        #expect(recorder.ratesGivenToChildren == [nil])
        #expect(report.ok)
        // 最初の 1 回は「保存から気付くまで」が無い
        #expect(report.timings.detectMs == nil)
        #expect(report.timings.buildMs > 0)
        #expect(report.timings.relaunchMs != nil)
    }

    @Test("変わっていなければ何もしない")
    func staysIdleWhenNothingChanged() async throws {
        let recorder = Recorder()
        let session = WatchSession(directory: try makeDirectory(), context: testContext(), hooks: recorder.hooks())
        await session.start()

        #expect(await session.tick() == nil)
        #expect(await session.tick() == nil)
        #expect(recorder.builds == 1)
        #expect(recorder.launches == 1)
    }

    @Test("変わったら作り直して差し替え、所要時間を 3 つに分けて出す")
    func rebuildsAndReplacesOnChange() async throws {
        let recorder = Recorder()
        let session = WatchSession(directory: try makeDirectory(), context: testContext(), hooks: recorder.hooks())
        await session.start()

        recorder.stamp = "bbb"
        let report = try #require(await session.tick())

        #expect(recorder.builds == 2)
        #expect(recorder.launches == 2)
        #expect(report.ok)
        #expect(report.timings.detectMs != nil)
        #expect(report.timings.buildMs > 0)
        #expect(report.timings.relaunchMs != nil)
        #expect(report.configuration == "debug")
    }

    @Test("新しい世代の刻印が、走らせる子へ渡る")
    func handsTheStampToTheChild() async throws {
        let recorder = Recorder()
        let session = WatchSession(directory: try makeDirectory(), context: testContext(), hooks: recorder.hooks())
        await session.start()
        recorder.stamp = "bbb"
        await session.tick()

        // 読み手はこの刻印の変化で「保存した内容が反映されたか」を判定する
        #expect(recorder.stampsGivenToChildren == ["aaa", "bbb"])
    }

    @Test("作り直しに失敗したら、差し替えない")
    func keepsTheRunningVersionWhenTheBuildFails() async throws {
        let recorder = Recorder()
        let session = WatchSession(directory: try makeDirectory(), context: testContext(), hooks: recorder.hooks())
        await session.start()

        recorder.stamp = "bbb"
        recorder.buildStatus = 1
        recorder.buildOutput = "error: cannot find 'circl' in scope"
        let report = try #require(await session.tick())

        #expect(!report.ok)
        #expect(report.status == 1)
        #expect(report.output.contains("circl"))
        // 差し替えていない = 直前の版が走り続けている
        #expect(recorder.launches == 1)
        #expect(report.timings.relaunchMs == nil)
    }

    @Test("壊れたままのソースで、作り直しを繰り返さない")
    func doesNotRetryTheSameBrokenSource() async throws {
        let recorder = Recorder()
        let session = WatchSession(directory: try makeDirectory(), context: testContext(), hooks: recorder.hooks())
        await session.start()
        recorder.stamp = "bbb"
        recorder.buildStatus = 1
        await session.tick()

        #expect(await session.tick() == nil)
        #expect(recorder.builds == 2)

        // 直せば、そのとき次の作り直しが走る
        recorder.stamp = "ccc"
        recorder.buildStatus = 0
        #expect(await session.tick() != nil)
        #expect(recorder.builds == 3)
    }

    @Test("結果が区画のファイルに残る")
    func leavesTheOutcomeInTheFacet() async throws {
        let recorder = Recorder()
        let directory = try makeDirectory()
        let session = WatchSession(directory: directory, context: testContext(), hooks: recorder.hooks())
        await session.start()

        let url = directory
            .appendingPathComponent(".mokume/build/status.json")
        let data = try Data(contentsOf: url)
        let decoded = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        #expect(decoded?["ok"] as? Bool == true)
        #expect(decoded?["schemaVersion"] as? Int == 1)
        #expect(decoded?["stamp"] as? String == "aaa")
        // 書きかけを掴ませない (原子的に置く)
        let names = try FileManager.default.contentsOfDirectory(
            atPath: directory.appendingPathComponent(".mokume/build").path)
        #expect(!names.contains { $0.hasSuffix(".tmp") })
    }

    @Test("区画の基準が別なら、記録はそちらへ置き、作り直しはパッケージの場所で行う")
    func writesTheOutcomeToTheFacetBase() async throws {
        let recorder = Recorder()
        let package = try makeDirectory()
        let work = try makeDirectory()
        // 走らせたスケッチは MOKUME_WORK_DIR に従って観測を書く。記録だけパッケージの
        // 場所に残ると、読み手から見て観測と記録が割れる (#331)
        let session = WatchSession(directory: package, context: testContext(), facetBase: work, hooks: recorder.hooks())
        await session.start()

        #expect(
            FileManager.default.fileExists(
                atPath: work.appendingPathComponent(".mokume/build/status.json").path))
        #expect(
            !FileManager.default.fileExists(
                atPath: package.appendingPathComponent(".mokume").path))
        // ビルドと世代の判定は動かない
        #expect(recorder.builtIn == [package])
    }
    // MARK: - 止め方

    /// 起こした子が「仕掛け終わった」と名乗る先。
    @MainActor
    final class Ready {
        /// 起こした順に溜まる管。
        ///
        /// **子ごとに新しい管を渡す。** 1 本を使い回すと、2 人目を起こすときには親側の端が
        /// 既に閉じられていて、道具立てが例外を投げる (実測: `NSFileHandleOperationException`)。
        var pipes: [Pipe] = []

        /// 最後に起こした子が仕掛け終わるのを待つ。
        ///
        /// **起こした直後は、まだ仕掛かっていない。** 数ミリ秒のうちに `SIGTERM` を送ると
        /// 既定の振る舞い (死ぬ) に落ちるので、応えない子を渡したつもりで**素直に止まる子**を
        /// 検めることになる (実測でそうなった)。
        ///
        /// 待ちは名乗りの 1 行で切れる。子が死んでいれば端が閉じるので、戻らなくならない。
        func waitForLast() {
            _ = pipes.last?.fileHandleForReading.availableData
        }
    }

    /// 実際に子を起こす外側。
    ///
    /// **`SIGTERM` を捕まえて何もしない子は、人が書けてしまう。** 待つ側が期限を持たないと、
    /// 終わるときだけでなく**保存のたびに**見張りが固まる
    /// ([#732](https://github.com/mokume-metal/mokume/issues/732))。
    ///
    /// - Parameters:
    ///   - ignores: 止めてくれと頼まれても応えないか。
    ///   - ready: 仕掛け終わったことを子が名乗る先。
    @MainActor
    private func hooks(ignoringTermination ignores: Bool, ready: Ready) -> WatchSession.Hooks {
        // **眠らせずに、来ない入力を待たせる。** 眠らせると、強制終了した後に
        // 眠りだけが残る (親を失った `sleep` は生き続ける)
        hooks(running: (ignores ? "trap '' TERM; " : "") + "echo ready; read line", ready: ready)
    }

    /// 実際に子を起こす外側。**走らせる中身を渡す。**
    ///
    /// 名乗り (`echo ready`) より後を差し替えれば、止め方だけでなく**終わり方**も作れる —
    /// 応えない子・自分から終わる子・落ちる子は、どれもここから 1 行で組める。
    @MainActor
    private func hooks(running script: String, ready: Ready) -> WatchSession.Hooks {
        WatchSession.Hooks(
            rebuild: { directory in
                RunCommand.Rebuilt(
                    status: 0, output: "", executable: URL(fileURLWithPath: "/bin/sh"),
                    binPath: directory)
            },
            launch: { executable, _, _, _ in
                let process = Process()
                process.executableURL = executable
                process.arguments = ["-c", script]
                let pipe = Pipe()
                process.standardInput = Pipe()
                process.standardOutput = pipe
                process.standardError = FileHandle.nullDevice
                guard (try? process.run()) != nil else { return nil }
                ready.pipes.append(pipe)
                return process
            },
            now: { 0 },
            stamp: { _ in UUID().uuidString })
    }

    @Test("頼んで止まる子は、止めたと名乗る")
    func stopsAChildThatListens() async throws {
        let ready = Ready()
        let session = WatchSession(
            directory: try makeDirectory(), context: testContext(), hooks: hooks(ignoringTermination: false, ready: ready),
            stopTimeout: 1)
        await session.start()
        let child = try #require(session.child)
        ready.waitForLast()
        #expect(child.isRunning)

        #expect(session.stop() == .terminated)
        #expect(!child.isRunning)
    }

    /// **待つ側が期限を持つ。** 期限が無ければ、ここは永久に戻らない (#732)。
    @Test("止めてくれと頼んでも応えない子は、期限で強制終了する")
    func killsAChildThatIgnoresTermination() async throws {
        let ready = Ready()
        let session = WatchSession(
            directory: try makeDirectory(), context: testContext(), hooks: hooks(ignoringTermination: true, ready: ready),
            stopTimeout: 0.2)
        await session.start()
        let child = try #require(session.child)
        ready.waitForLast()
        #expect(child.isRunning)

        let started = Date()
        #expect(session.stop() == .killed)
        #expect(!child.isRunning)
        // 数字は「戻ってきた」ことの確認でしかない — 期限が効いていなければ戻らないので
        #expect(Date().timeIntervalSince(started) < 2)
    }

    /// **差し替えも同じ経路を通る。** 期限が無いと、終われないだけでなく**保存のたびに**
    /// 固まる (#732)。
    @Test("応えない子でも、差し替えは進む")
    func replacesEvenWhenTheChildIgnoresTermination() async throws {
        let ready = Ready()
        let session = WatchSession(
            directory: try makeDirectory(), context: testContext(), hooks: hooks(ignoringTermination: true, ready: ready),
            stopTimeout: 0.2)
        await session.start()
        let first = try #require(session.child)
        ready.waitForLast()
        defer { session.stop() }

        await session.tick()
        #expect(!first.isRunning, "前の子が残っている")
        #expect(session.lastStop == .killed, "期限に掛かったことが残っていない")
        #expect(session.child !== first, "差し替わっていない")
    }

    // MARK: - 誰も頼んでいない消え方 (#1103)

    /// 子が消えるのを待つ。
    ///
    /// **待つ側が期限を持つ。** 検査そのものに上限を書く形 (`.timeLimit`) は採らない —
    /// あれは検査の走り出しからの時計で測るので、無関係な検査が増えた日にここが赤くなる
    /// ([#564](https://github.com/mokume-metal/mokume/issues/564))。
    private func waitUntilGone(_ process: Process, timeout: TimeInterval = 2) {
        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning, Date() < deadline { Thread.sleep(forTimeInterval: 0.005) }
    }

    @Test("自分から終わった子は、1 度だけ名乗られる")
    func namesTheChildThatEndedOnItsOwn() async throws {
        let ready = Ready()
        let session = WatchSession(
            directory: try makeDirectory(), context: testContext(),
            hooks: hooks(running: "echo ready; exit 7", ready: ready))
        await session.start()
        let child = try #require(session.child)
        ready.waitForLast()
        waitUntilGone(child)

        #expect(session.departed() == WatchSession.Departure(status: 7, wasSignalled: false))
        // **同じ消え方を二度言わない。** 巡回は 0.25 秒ごとに回るので、印が無ければ
        // 毎秒 4 回出し続ける
        #expect(session.departed() == nil)
    }

    /// **黙るのはその 1 人についてだけである。** 印を下ろさないと、最初の消失を名乗った
    /// 後は何度作り直しても二度と名乗らない — 見張りは付けっぱなしで使うものなので、
    /// 実質「最初の 1 回しか効かない」ことになる。
    @Test("作り直して起きた子が消えたら、もう一度名乗られる")
    func namesEachDepartureOnce() async throws {
        let ready = Ready()
        let session = WatchSession(
            directory: try makeDirectory(), context: testContext(),
            hooks: hooks(running: "echo ready; exit 7", ready: ready))
        await session.start()
        let first = try #require(session.child)
        ready.waitForLast()
        waitUntilGone(first)
        #expect(session.departed() != nil)

        // 世代が変わるので、作り直して起こし直す
        await session.tick()
        let second = try #require(session.child)
        #expect(second !== first)
        ready.waitForLast()
        waitUntilGone(second)
        #expect(session.departed() != nil, "2 人目の消失が名乗られない")
    }

    /// **落ちたことは、自分から終わったことと別に読めなければならない。** 落ちたのなら
    /// 端末を遡る先があり、自分から終わったのならスケッチの側にそう書いてある。
    @Test("落ちた子は、落ちたと名乗られる")
    func namesTheChildThatCrashed() async throws {
        let ready = Ready()
        let session = WatchSession(
            directory: try makeDirectory(), context: testContext(),
            hooks: hooks(running: "echo ready; kill -SEGV $$", ready: ready))
        await session.start()
        let child = try #require(session.child)
        ready.waitForLast()
        waitUntilGone(child)

        let departure = try #require(session.departed())
        #expect(departure.wasSignalled)
        #expect(departure.status == SIGSEGV)
    }

    /// **道具が止めた回は名乗らない。** 終わるときも保存による差し替えも同じ経路を通るので、
    /// ここを分けないと「見張りを終える」たびに「勝手に消えた」と言うことになる。
    @Test("道具が止めた子は、消えたことにしない")
    func staysSilentWhenTheToolStoppedTheChild() async throws {
        let ready = Ready()
        let session = WatchSession(
            directory: try makeDirectory(), context: testContext(),
            hooks: hooks(ignoringTermination: false, ready: ready), stopTimeout: 1)
        await session.start()
        ready.waitForLast()

        #expect(session.stop() == .terminated)
        #expect(session.departed() == nil)
    }

    /// **差し替えでも名乗らない。** 保存のたびに古い子は止まるが、それは道具が起こした
    /// 結果であって、誰も頼んでいない消え方ではない。
    @Test("差し替えで入れ替わった子も、消えたことにしない")
    func staysSilentWhenTheChildWasReplaced() async throws {
        let ready = Ready()
        let session = WatchSession(
            directory: try makeDirectory(), context: testContext(),
            hooks: hooks(ignoringTermination: false, ready: ready), stopTimeout: 1)
        await session.start()
        ready.waitForLast()
        defer { session.stop() }

        await session.tick()
        ready.waitForLast()
        #expect(session.departed() == nil)
    }

    // MARK: - 世代の重なり

    /// **止めてから起こすと、新しい子が最初の絵を焼くまで絵が途切れる** (手元では 417 ms・
    /// [#1142](https://github.com/mokume-metal/mokume/issues/1142))。順序を入れ替えて、画面が
    /// 入れ替わってから前の子を止める。
    @Test("重ねる見張りは、差し替えても前の子をすぐには止めない")
    func overlappingKeepsTheOutgoingChildAlive() async throws {
        let ready = Ready()
        let session = try overlapping(ready: ready)
        defer { session.stop() }

        await session.start()
        ready.waitForLast()
        let leaving = try #require(session.child)

        await session.tick()
        ready.waitForLast()
        #expect(session.outgoing === leaving, "前の子を控えていない")
        #expect(leaving.isRunning, "画面が入れ替わる前に止めている")
        #expect(session.child !== leaving)

        session.retireOutgoing()
        waitUntilGone(leaving)
        #expect(!leaving.isRunning, "入れ替わりの合図で止まっていない")
        #expect(session.outgoing == nil)
    }

    /// **合図が来ない回がある** (新しい世代が絵を出さずに消えた・窓がそもそも無い)。
    /// 重ねるのは 1 世代だけなので、次の差し替えが来たらそこで必ず止める。
    @Test("合図が来ないまま次の保存が来たら、そこで前の子を止める")
    func theOutgoingChildIsStoppedAtTheNextSwap() async throws {
        let ready = Ready()
        let session = try overlapping(ready: ready)
        defer { session.stop() }

        await session.start()
        ready.waitForLast()
        let first = try #require(session.child)
        await session.tick()
        ready.waitForLast()
        let second = try #require(session.child)
        #expect(session.outgoing === first)

        // 合図を送らないまま、もう 1 度保存された
        await session.tick()
        ready.waitForLast()
        waitUntilGone(first)
        #expect(!first.isRunning, "1 世代前が置き去りになっている")
        #expect(session.outgoing === second, "控えるのは直前の 1 世代だけである")
    }

    /// **窓が出せなかった実行では合図が来ない。** そこは今までどおり、止めてから起こす。
    @Test("重ねない見張りは、いままでどおり止めてから起こす")
    func withoutOverlapTheChildIsStoppedFirst() async throws {
        let ready = Ready()
        let session = WatchSession(
            directory: try makeDirectory(), context: testContext(),
            hooks: hooks(running: "echo ready; read line", ready: ready), stopTimeout: 0.5)
        defer { session.stop() }

        await session.start()
        ready.waitForLast()
        let leaving = try #require(session.child)
        await session.tick()
        #expect(!leaving.isRunning, "止めずに起こしている")
        #expect(session.outgoing == nil)
    }

    /// **入力の宛先は「画面に出ている世代」である。** 重なっている間はまだ前の世代が映って
    /// いるので、そこへ届かないと、触った先と動く絵が食い違う。
    @Test("入力は、画面に出ている世代へ行く")
    func inputGoesToTheGenerationOnScreen() async throws {
        let ready = Ready()
        let session = try overlapping(ready: ready)
        defer { session.stop() }

        await session.start()
        ready.waitForLast()
        let leaving = try #require(session.child)
        await session.tick()
        ready.waitForLast()
        let arriving = try #require(session.child)

        // 子は 1 行読んだら終わる。**どちらが終わったか**で宛先が分かる
        session.send("touch\n")
        waitUntilGone(leaving)
        #expect(!leaving.isRunning, "画面に出ている世代へ届いていない")
        #expect(arriving.isRunning, "まだ映っていない世代へ送っている")
    }

    /// **置いていかない。** 入れ替わりの合図が来る前に終わることがある。
    @Test("終わるときは、控えている子も置いていかない")
    func stoppingAlsoBringsDownTheOutgoingChild() async throws {
        let ready = Ready()
        let session = try overlapping(ready: ready)

        await session.start()
        ready.waitForLast()
        let leaving = try #require(session.child)
        await session.tick()
        ready.waitForLast()
        let arriving = try #require(session.child)
        #expect(session.outgoing === leaving)

        session.stop()
        waitUntilGone(leaving)
        waitUntilGone(arriving)
        #expect(!leaving.isRunning, "控えていた子を置いていった")
        #expect(!arriving.isRunning)
        #expect(session.outgoing == nil)
    }

    /// 世代を重ねる見張りを組む。**実際に子を起こす** — 重なりは生きた子でしか見られない。
    @MainActor
    private func overlapping(ready: Ready) throws -> WatchSession {
        let session = WatchSession(
            directory: try makeDirectory(), context: testContext(),
            hooks: hooks(running: "echo ready; read line", ready: ready), stopTimeout: 0.5)
        session.overlapsGenerations = true
        return session
    }

}

@Suite("ソースの世代")
struct SourceStampTests {
    private func makeSketch() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("mokume-stamp-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: url.appendingPathComponent("Sources/app"), withIntermediateDirectories: true)
        try "// package".write(
            to: url.appendingPathComponent("Package.swift"), atomically: true, encoding: .utf8)
        try "let a = 1".write(
            to: url.appendingPathComponent("Sources/app/main.swift"), atomically: true,
            encoding: .utf8)
        return url
    }

    @Test("中身が変われば変わり、変わらなければ変わらない")
    func followsTheContents() throws {
        let sketch = try makeSketch()
        let first = SourceStamp.current(for: sketch)
        #expect(first != nil)
        #expect(SourceStamp.current(for: sketch) == first)

        try "let a = 2".write(
            to: sketch.appendingPathComponent("Sources/app/main.swift"), atomically: true,
            encoding: .utf8)
        let second = SourceStamp.current(for: sketch)
        #expect(second != first)

        // **元に戻したら元の世代に戻る。** 時刻や連番で振ると、戻したのに別の世代を
        // 名乗り、読み手は反映されていない変更を反映済みと読む
        try "let a = 1".write(
            to: sketch.appendingPathComponent("Sources/app/main.swift"), atomically: true,
            encoding: .utf8)
        #expect(SourceStamp.current(for: sketch) == first)
    }

    @Test("名前が変わっても変わる")
    func followsTheNamesToo() throws {
        let sketch = try makeSketch()
        let first = SourceStamp.current(for: sketch)
        try FileManager.default.moveItem(
            at: sketch.appendingPathComponent("Sources/app/main.swift"),
            to: sketch.appendingPathComponent("Sources/app/other.swift"))
        #expect(SourceStamp.current(for: sketch) != first)
    }

    @Test("見張るのはソースだけ")
    func watchesOnlySources() throws {
        let sketch = try makeSketch()
        let first = SourceStamp.current(for: sketch)
        try "書き置き".write(
            to: sketch.appendingPathComponent("Sources/app/notes.txt"), atomically: true,
            encoding: .utf8)
        #expect(SourceStamp.current(for: sketch) == first)
    }

    /// **断片を保存しても作り直さない。**
    ///
    /// 断片は走らせたまま差し替わるので、作り直して起動し直すと差し替わる様子そのものが
    /// 見られなくなる — 保存のたびに窓が開き直り、絵は最初から始まる。
    @Test("断片を保存しても、作り直しは起きない")
    func savingAFragmentDoesNotTriggerARebuild() throws {
        let sketch = try makeSketch()
        let first = SourceStamp.current(for: sketch)
        try "float4 paint(Fragment in, Values values) { return in.color; }".write(
            to: sketch.appendingPathComponent("Sources/app/paint.metal"), atomically: true,
            encoding: .utf8)
        #expect(SourceStamp.current(for: sketch) == first)
    }
}

/// 速さの名乗りを子へ渡す道 (#510)。
@Suite("速さの名乗りを渡す")
struct FrameRateHandoffTests {
    /// **渡したときだけ載る。** 置かないことで、受け取る側は「無ければ黙る」だけで済む。
    @Test("子へ渡す環境に載るのは、渡したものだけ")
    func onlyWhatWasGivenLandsInTheChildEnvironment() {
        let bare = RunCommand.childEnvironment([:])
        #expect(bare[StartupReads.frameRateNotice.key] == nil)
        #expect(bare[StartupReads.sourceStamp.key] == nil)

        let carried = RunCommand.childEnvironment([:], stamp: "abc", reportingRate: "debug")
        #expect(carried[StartupReads.frameRateNotice.key] == "debug")
        #expect(carried[StartupReads.sourceStamp.key] == "abc")
        #expect(RunCommand.childEnvironment(["A": "1"])["A"] == "1", "親の環境は運ぶ")
    }

}
