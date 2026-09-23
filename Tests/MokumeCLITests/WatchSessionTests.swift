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
        /// その回が探した product の名前。**土台が持つ名前とは別に置ける** — 宣言が
        /// 変わった回に、どちらの名前で名乗るかを見るため (#1067)。
        var product: String? = "sketch"
        /// 作り直しの最中に待たせる口。**既定は何もしない。**
        ///
        /// 作り直しが main actor を離れたかどうかは、**離れている間に別の仕事が進むか**
        /// でしか見えない (#834)。ここで待たせて、その隙に main actor の仕事を積む。
        var whileBuilding: () async -> Void = {}
        /// 作り直しを起こせなかったことにする誤り。**立っていれば、作り直しは投げる。**
        var failure: CommandFailure?
        /// 起こしたことにする子を返すか。**既定は返さない** (起こせなかった回になる)。
        ///
        /// 返すのは走らせていない `Process` である — 新しい絵が出るまでを測るのは子が居る回
        /// だけなので、居ることにだけ要る (#930)。
        var launchesChild = false

        func hooks() -> WatchSession.Hooks {
            WatchSession.Hooks(
                rebuild: { directory throws(CommandFailure) in
                    self.onBuild()
                    self.builds += 1
                    self.builtIn.append(directory)
                    await self.whileBuilding()
                    if let failure = self.failure { throw failure }
                    // 作り直しには時間がかかる。刻む対象なので時計を進める
                    self.clock += 0.5
                    let bin = directory.appendingPathComponent("bin")
                    return RunCommand.Rebuilt(
                        status: self.buildStatus, output: self.buildOutput,
                        executable: self.productBuilt ? bin : nil, binPath: directory,
                        product: self.product)
                },
                launch: { _, _, stamp, rate in
                    self.launches += 1
                    self.stampsGivenToChildren.append(stamp)
                    self.ratesGivenToChildren.append(rate)
                    self.clock += 0.03
                    return self.launchesChild ? Process() : nil
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
        recorder.product = "hello"
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

    /// **名乗る名前は、その回が探したものである。**
    ///
    /// 見張りは宣言が変わった回に土台を導き直すので (``BuildResolver``)、始めたときの
    /// 名前を持ち回ると、`Package.swift` で product を改名した回に**前の名前**で
    /// 「建っていない」と言うことになる — 手元では `probe` を `probe-renamed` に改名した
    /// 回に「The build succeeded, but probe was never built」と出て、実際には
    /// `probe-renamed` が建っていた ([#1067](https://github.com/mokume-metal/mokume/issues/1067))。
    @Test("宣言が変わった回は、その回の product の名前で名乗る")
    func anUnbuiltProductIsNamedAsThisRebuildSawIt() async throws {
        let recorder = Recorder()
        recorder.productBuilt = false
        // 始めたときの宣言は "sketch"、この回に導き直した宣言は "renamed"
        recorder.product = "renamed"
        let session = WatchSession(
            directory: try makeDirectory(), context: testContext(product: "sketch"),
            hooks: recorder.hooks())

        let report = await session.start()
        #expect(report.output.contains("renamed"), "改名した先の名前で名乗っていない")
        #expect(!report.output.contains("sketch"), "始めたときの名前を持ち回っている")
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

    /// **起こせなかった回も、作り直しの失敗と同じ顔にして理由を載せる。**
    ///
    /// かつては顔だけ揃えて理由を捨てていた — `try?` が投げられた誤りを丸ごと落とすので、
    /// 記録の `output` は空になり、読み手 (窓口) にも端末にも「失敗した」しか届かなかった
    /// ([#1100](https://github.com/mokume-metal/mokume/issues/1100))。`swift` が見つからない
    /// 手元で実際にそうなる。
    @Test("作り直しを起こせなかった回は、理由を記録に載せる")
    func aRebuildThatCouldNotStartKeepsTheReason() async throws {
        let recorder = Recorder()
        let directory = try makeDirectory()
        let session = WatchSession(
            directory: directory, context: testContext(), hooks: recorder.hooks())
        await session.start()

        recorder.stamp = "bbb"
        recorder.failure = .toolchainMissing("swift")
        let report = try #require(await session.tick())

        let reason = CommandFailure.toolchainMissing("swift").message
        #expect(report.output == reason, "投げられた誤りの説明が記録に載っていない")
        // **顔は作り直しの失敗と同じである。** 終了コードは 1 に倒し、差し替えない
        #expect(!report.ok)
        #expect(report.status == 1)
        #expect(!report.launched)
        #expect(recorder.launches == 1, "起こせなかったのに、走っている版を差し替えている")
        #expect(report.timings.relaunchMs == nil)

        // 区画のファイルにも同じ本文が載る — 窓口が読むのはこちらである
        let data = try Data(
            contentsOf: directory.appendingPathComponent(".mokume/build/status.json"))
        let decoded = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        #expect(decoded?["output"] as? String == reason)
        #expect(decoded?["status"] as? Int == 1)
        #expect(decoded?["ok"] as? Bool == false)
    }

    /// **本物の口も、起こせなかった理由を捨てない。**
    ///
    /// 上の検査は替え玉が投げる形なので、`live` の側で誤りを握り潰す形に戻っても緑のまま
    /// になる (#1100 の `try?` はそこに居た)。存在しない場所では `Process` が起動の時点で
    /// 投げるので、`swift` を 1 本も起こさずにその経路を通せる。
    @Test("本物の作り直しの口は、起こせなかった誤りを投げ返す")
    func theLiveRebuildThrowsWhatStoppedIt() async throws {
        let nowhere = FileManager.default.temporaryDirectory
            .appendingPathComponent("mokume-nowhere-\(UUID().uuidString)", isDirectory: true)
        let hooks = WatchSession.Hooks.live(in: nowhere, invocation: Invocation())

        await #expect(throws: CommandFailure.toolchainMissing("swift")) {
            try await hooks.rebuild(nowhere)
        }
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
                    binPath: directory, product: "sketch")
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

        var waits = 0
        session.willWaitForFinish = { _ in waits += 1 }
        #expect(session.end() == .terminated)
        #expect(!child.isRunning)
        // **いつもの終わり方は無言のまま。** 素直に終わる子を待つ間は名乗らない
        #expect(waits == 0)
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

    // MARK: - 後始末を待つのは終えるときだけ (#1219)

    /// 頼まれてから後始末に 0.6 秒かかる子。撮っていた動画を閉じているスケッチの代わり。
    ///
    /// **1 行来ても終わらない。** 待ち方を `read` 1 回にしないのは、TERM の保留を解く手
    /// (``nudge(_:)``) が 1 行渡すからである — 1 行で終わる子だと、**頼まれていない子まで**
    /// 自分から終わって `.terminated` に見える。管が閉じれば `read` が偽を返して終わるので、
    /// 置き去りにされても生き続けない。
    private func hooksClosingSlowly(ready: Ready) -> WatchSession.Hooks {
        hooks(
            running: "trap 'sleep 0.6; exit 0' TERM; echo ready; while read line; do :; done",
            ready: ready)
    }

    /// 子の標準入力へ 1 行渡して、**保留された TERM の trap を走らせる。**
    ///
    /// **子の `sh` (bash 3.2) は、届いた TERM をすぐには処理しないことがある。** `echo ready` の
    /// 後・`read` が割り込める状態になる前に届くと trap は保留になり、**`read` が戻るまで
    /// 走らない**。誰も書かなければ `read` は戻らないので、後始末を始めてもいない子を期限で
    /// 落とすことになる — merge queue で 1 度そうなった
    /// ([#1394](https://github.com/mokume-metal/mokume/issues/1394)。手元では `ready` から
    /// 0〜250 µs 揺らして撃つと 1500 回に 1 回)。負荷はこの隙を広げる形で効くので、
    /// **上限を延ばしても直らない** — 落ちるまでの時間が延びるだけである。
    ///
    /// **後始末の途中の子には効かない。** trap の中で `exit` するので、渡した行は読まれない。
    ///
    /// **管が閉じていることは無い。** 呼ぶのは子が走っている間だけで、後始末の `sleep` も
    /// 読み口を受け継いでいる — `SIGPIPE` を心配しなくてよい。
    private func nudge(_ child: Process) {
        guard let pipe = child.standardInput as? Pipe else { return }
        try? pipe.fileHandleForWriting.write(contentsOf: Data("\n".utf8))
    }

    /// **撮っていた動画を閉じ終えるまで待つ。** 3 秒で落としていた頃は、閉じている最中の
    /// スケッチを `SIGKILL` で落とし、開けない動画が残った (#1219)。
    ///
    /// **上限は後始末の時間 (0.6 秒) と桁を離して取る。** 通る回は子が終わった時点で戻るので、
    /// 延ばしても通る回の所要時間は変わらない (#1394)。
    @Test("見張りを終えるときは、後始末に時間のかかる子も待ってから、待っていると 1 度名乗る")
    func waitsForTheChildToFinishWhenWatchingEnds() async throws {
        let ready = Ready()
        let session = WatchSession(
            directory: try makeDirectory(), context: testContext(),
            hooks: hooksClosingSlowly(ready: ready), stopTimeout: 0.2, finishTimeout: 30)
        await session.start()
        let child = try #require(session.child)
        ready.waitForLast()

        var waits: [TimeInterval] = []
        // **名乗られた時点で、保留された TERM を解く。** 名乗りは「頼んでから `stopTimeout` を
        // 越えた」合図なので、子は後始末の途中か、TERM を保留したまま `read` に入っているかの
        // どちらかである (``nudge(_:)``)
        session.willWaitForFinish = {
            waits.append($0)
            nudge(child)
        }

        #expect(session.end() == .terminated, "後始末の途中で落とした")
        #expect(!child.isRunning)
        #expect(waits.count == 1, "長く待つ間を名乗っていない (または 2 度以上名乗った)")
        // 名乗るのは「この先さらに待つ上限」で、全体の上限から最初の待ちを引いたもの
        #expect(waits.first.map { abs($0 - 29.8) < 0.001 } == true)
    }

    /// **差し替えは保存のたびに払う待ちなので、延ばさない** (#732・#1219)。窓を持たない
    /// 見張りの差し替えは ``WatchSession/stop()`` を通るので、終えるときの口と分かれている
    /// ことをここで見る。
    @Test("差し替えは、後始末に時間のかかる子を待たずに落とす")
    func replacesWithoutWaitingForTheChildToFinish() async throws {
        let ready = Ready()
        let session = WatchSession(
            directory: try makeDirectory(), context: testContext(),
            hooks: hooksClosingSlowly(ready: ready), stopTimeout: 0.2, finishTimeout: 3)
        var waits = 0
        session.willWaitForFinish = { _ in waits += 1 }
        await session.start()
        let first = try #require(session.child)
        ready.waitForLast()
        defer { session.stop() }

        await session.tick()
        #expect(!first.isRunning, "前の子が残っている")
        #expect(session.lastStop == .killed, "差し替えで後始末を待った")
        #expect(waits == 0, "差し替えで、終えるときの名乗りが出た")
    }

    /// **閉じる側の期限を写さない。** 閉じる側が延びたのにこちらが据え置かれると、閉じている
    /// 最中に落とす形へ黙って戻る。
    @Test("見張りを終えるときの既定の猶予は、動画を閉じる側の期限を覆う")
    func finishTimeoutCoversTheRecordingDeadline() {
        #expect(WatchSession.defaultFinishTimeout > RecordingDeadline.longestFinishSeconds)
        #expect(WatchSession.defaultFinishTimeout > WatchSession.defaultStopTimeout)
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

    /// 期限を越えたら子を落とす係。
    ///
    /// **`Process` は `Sendable` ではない**が、期限を数えるのは別の走りでなければならない
    /// (数える相手が main を塞いでいる)。落とす 1 手と落としたかの印だけをここへ閉じて渡す。
    ///
    /// **型ごと `nonisolated` にする。** 理由は `BuildProcess` の同名の係が書いているものと
    /// 同じで、既定の隔離 (`Package.swift` の `.defaultIsolation(MainActor.self)`) のままだと
    /// 期限を数える閉包まで main actor と推論され、別の走りで鳴った瞬間に落ちる
    /// (実測: `dispatch_assert_queue` の SIGTRAP でバンドルごと死ぬ)。**写しのままにするのは、
    /// 割れれば黙らずに落ちるからである** ([ADR-0008] 決定 6)。
    ///
    /// [ADR-0008]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0008-mechanism-needs-demonstrated-harm.md
    nonisolated private final class Deadline: @unchecked Sendable {
        private let lock = NSLock()
        private let process: Process
        private var killed = false
        init(_ process: Process) { self.process = process }
        var didKill: Bool { lock.withLock { killed } }

        /// 期限を仕掛ける。**鳴る先は main の外である。**
        ///
        /// - Returns: 間に合ったときに取り下げる札。
        func arm(after seconds: Double) -> DispatchWorkItem {
            let alarm = DispatchWorkItem { self.kill() }
            DispatchQueue.global().asyncAfter(deadline: .now() + seconds, execute: alarm)
            return alarm
        }

        private func kill() {
            lock.withLock { killed = true }
            process.terminate()
        }
    }

    /// **応えない子へ書き続けても、送る側は戻る。**
    ///
    /// 読み口に立てた `O_NONBLOCK` は親の書き口に効かない (管の両端は別の open file
    /// description) ので、親が立てないと管の容量 (64KB) が埋まった次の `write` で
    /// **main が永久に塞がる** — 窓も保存の検出も合図の巡回も、まとめて止まる (#1296)。
    @Test("読まない子へ管の容量を越えて送っても、送る側は戻る")
    func sendingToAChildThatNeverReadsReturns() async throws {
        // **`send(_:)` の約束どおり `SIGPIPE` を無視する** (実行時は `WatchCommand` が置く)。
        // 無視しないと、期限で救出した後の書き込みで**検査の走り自体が落ちて**、塞がったのか
        // 別の理由で死んだのかを読めない
        let previousPipeHandler = signal(SIGPIPE, SIG_IGN)
        defer { signal(SIGPIPE, previousPipeHandler) }

        let ready = Ready()
        // **読まず・眠り続ける子。** `exec` で置き換えるので `sh` は残らず、止めるのは
        // この 1 人で済む (既定のヘルパが眠りを避けているのは、置き去りを作らないため)
        let session = WatchSession(
            directory: try makeDirectory(), context: testContext(),
            hooks: hooks(running: "echo ready; exec sleep 30", ready: ready), stopTimeout: 1)
        defer { session.stop() }

        await session.start()
        ready.waitForLast()
        let child = try #require(session.child)

        // **待つ側が期限を持つ。** 塞がったらここで子を落とす — 読み口が閉じれば `write`
        // は EPIPE で戻るので、**壊れていても run 全体は固まらず**、救出した印が赤で名乗る
        let deadline = Deadline(child)
        let alarm = deadline.arm(after: 5)
        defer { alarm.cancel() }

        // 1 件は約 50 バイト。管の容量 (64KB) を十分に越える数を書く
        let line = #"{"type":"mouseMoved","x":123.45,"y":678.90}"# + "\n"
        for _ in 0..<4_000 { session.send(line) }

        #expect(!deadline.didKill, "読まない子への書き込みで塞がり、期限で落として戻した")
        // **救出されていない回にだけ訊く。** 落とした後の「消えている」は当たり前で、
        // ここで見たいのは**子が自分で消えていて、塞がる機会が無かった**回である
        if !deadline.didKill {
            #expect(child.isRunning, "子が自分で消えている — 塞がるかどうかを見られていない")
        }
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

    // MARK: - 新しい絵が出るまで (#930)

    /// 窓を出せた見張りを、替え玉の外側で組む。**最初の世代は乗り換わった後まで進めてある。**
    ///
    /// 最初の合図は絵を指さないので測らない — その先の、測れる差し替えから始めたい検査のため。
    @MainActor
    private func promotedOnce(_ recorder: Recorder) async throws -> WatchSession {
        recorder.launchesChild = true
        let session = WatchSession(
            directory: try makeDirectory(), context: testContext(), hooks: recorder.hooks())
        session.overlapsGenerations = true
        await session.start()
        session.generationPromoted()
        return session
    }

    /// 区画に書かれた記録の所要時間。**書かれていなければ `nil`。**
    private func writtenTimings(of session: WatchSession) throws -> [String: Any]? {
        let url = BuildReport.statusURL(under: session.facetBase)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let object = try JSONSerialization.jsonObject(with: Data(contentsOf: url))
        return (object as? [String: Any])?["timings"] as? [String: Any]
    }

    /// **作者の実感は「保存してから新しい絵が出るまで」である。** `relaunchMs` は子を
    /// 起こし終えた時点で止まるので、窓が新しい絵を出すまでは誰も測っていなかった
    /// ([#930](https://github.com/mokume-metal/mokume/issues/930))。
    @Test("窓を出せた見張りは、乗り換えの合図で新しい絵が出るまでを記録へ足す")
    @MainActor
    func recordsTheTimeUntilTheNewPictureShows() async throws {
        let recorder = Recorder()
        let session = try await promotedOnce(recorder)

        recorder.stamp = "bbb"
        let started = recorder.clock + 0.5  // 作り直しが時計を 0.5 秒進めてから差し替えに入る
        let launched = try #require(await session.tick())
        // **起こし終えた時点の記録にはまだ無い** — 分かるのは合図が来てからである
        #expect(launched.timings.firstFrameMs == nil)
        #expect(try writtenTimings(of: session)?["firstFrameMs"] == nil)

        recorder.clock += 0.2
        session.generationPromoted()

        let report = try #require(session.lastReport)
        let firstFrame = try #require(report.timings.firstFrameMs, "合図が来ても足されていない")
        #expect(abs(firstFrame - (recorder.clock - started) * 1000) < 1e-6)
        // **同じ時刻から数えるので、起こすまでを丸ごと含む**
        #expect(firstFrame >= (try #require(report.timings.relaunchMs)))
        // **後から読んでも入っている。** 足しただけで書き直さなければ、窓口は古い記録を読む
        let written = try #require(try writtenTimings(of: session))
        #expect(written["firstFrameMs"] as? Double == firstFrame)
        #expect(written["relaunchMs"] as? Double == report.timings.relaunchMs)
    }

    /// **合図は窓ごとに来る** (作品の窓とプレビュー)。2 度目で数え直すと、遅いほうの窓の
    /// 時刻になる。
    @Test("2 つ目の窓からの合図では、数え直さない")
    @MainActor
    func theSecondWindowsSignalDoesNotRecountIt() async throws {
        let recorder = Recorder()
        let session = try await promotedOnce(recorder)
        recorder.stamp = "bbb"
        await session.tick()
        recorder.clock += 0.2
        session.generationPromoted()
        let first = try #require(session.lastReport?.timings.firstFrameMs)

        recorder.clock += 0.05
        session.generationPromoted()
        #expect(session.lastReport?.timings.firstFrameMs == first)
        #expect(try writtenTimings(of: session)?["firstFrameMs"] as? Double == first)
    }

    /// **合図が来ない実行で、項目を作らない。** 既存の 3 本は従来どおり書く。
    @Test("窓を出せない見張りでは省き、既存の 3 本はそのまま書く")
    @MainActor
    func aSessionWithoutAWindowLeavesItOut() async throws {
        let recorder = Recorder()
        recorder.launchesChild = true
        let session = WatchSession(
            directory: try makeDirectory(), context: testContext(), hooks: recorder.hooks())
        await session.start()
        session.generationPromoted()

        recorder.stamp = "bbb"
        await session.tick()
        recorder.clock += 0.2
        // 窓の無い実行に合図は来ないが、来ても測らない
        session.generationPromoted()

        let report = try #require(session.lastReport)
        #expect(report.timings.firstFrameMs == nil)
        #expect(report.timings.detectMs != nil)
        #expect(report.timings.buildMs > 0)
        #expect(report.timings.relaunchMs != nil)
        let written = try #require(try writtenTimings(of: session))
        #expect(Set(written.keys) == ["detectMs", "buildMs", "relaunchMs"])
    }

    /// **出している世代が無い台は、1 枚目を待たずに乗り換える。** 最初の合図は「目録が
    /// 読めた」でしかないので、そこで測ると絵が出る前の数字になる。
    @Test("まだ合図を受けていない間に起こした世代は測らない")
    @MainActor
    func theGenerationBeforeAnySignalIsNotMeasured() async throws {
        let recorder = Recorder()
        recorder.launchesChild = true
        let session = WatchSession(
            directory: try makeDirectory(), context: testContext(), hooks: recorder.hooks())
        session.overlapsGenerations = true

        await session.start()
        recorder.clock += 0.2
        session.generationPromoted()
        #expect(session.lastReport?.timings.firstFrameMs == nil)
        #expect(try writtenTimings(of: session)?["firstFrameMs"] == nil)
    }

    /// **起こした後に別の記録で上書きされたら、待っていた数字の行き先は無い。** 足すと、
    /// 作り直しの失敗の記録に、前の世代の絵の時刻が載る。
    @Test("起こした後に作り直しが失敗したら、その記録には足さない")
    @MainActor
    func aLaterFailedRebuildIsNotGivenTheTime() async throws {
        let recorder = Recorder()
        let session = try await promotedOnce(recorder)
        recorder.stamp = "bbb"
        await session.tick()

        recorder.stamp = "ccc"
        recorder.buildStatus = 1
        let failed = try #require(await session.tick())
        #expect(!failed.ok)
        session.generationPromoted()
        #expect(session.lastReport?.timings.firstFrameMs == nil)
        #expect(try writtenTimings(of: session)?["firstFrameMs"] == nil)
    }

    /// **前の世代が生きたまま乗り換わっていなければ、次の合図がどちらのものか分からない。**
    /// 目録は世代の印を持たないので、測ると前の世代の絵の時刻を新しい世代の数字として書く。
    @Test("前の世代が乗り換わらずに生きているうちに差し替えた回は測らない")
    @MainActor
    func aSwapBeforeThePreviousGenerationShowedIsNotMeasured() async throws {
        let ready = Ready()
        let session = try overlapping(ready: ready)
        defer { session.stop() }

        await session.start()
        ready.waitForLast()
        session.generationPromoted()
        // 2 世代目を起こし、**乗り換わらないうちに** 3 世代目へ差し替える
        await session.tick()
        ready.waitForLast()
        let unshown = try #require(session.child)
        await session.tick()
        ready.waitForLast()
        #expect(unshown.isRunning, "前の世代が生きている形を作れていない")

        session.generationPromoted()
        #expect(session.lastReport?.timings.firstFrameMs == nil, "どちらの世代の合図か分からないのに測った")
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
