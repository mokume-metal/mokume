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

        func hooks() -> WatchSession.Hooks {
            WatchSession.Hooks(
                build: { directory in
                    self.onBuild()
                    self.builds += 1
                    self.builtIn.append(directory)
                    // 作り直しには時間がかかる。刻む対象なので時計を進める
                    self.clock += 0.5
                    return (self.buildStatus, self.buildOutput)
                },
                resolveExecutable: { $0.appendingPathComponent("bin") },
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
    func aReportingSessionHandsTheConfigurationToTheChild() throws {
        let recorder = Recorder()
        let session = WatchSession(
            directory: try makeDirectory(), configuration: "release", reportsRate: true,
            hooks: recorder.hooks())

        let report = session.start()
        #expect(recorder.ratesGivenToChildren == ["release"])
        // **名乗りは 1 つの値から出る。** 子へ渡す名前と記録の名前が別々に決まると、
        // 読み手はどちらが実体か判定できない (#680)
        #expect(report.configuration == "release")
    }

    /// **選ばれていなければ道具立ての既定に任せ、名乗りだけ既定の名前を使う。**
    /// ここで `-c debug` と書き固めると、道具立てが既定を変えた日に黙ってずれる。
    @Test("構成が選ばれていなければ、道具立てへ渡す指定を持たない")
    func leavesTheDefaultConfigurationToTheToolchain() throws {
        let session = WatchSession(directory: try makeDirectory(), hooks: Recorder().hooks())
        #expect(session.configuration == nil)
        #expect(session.configurationName == RunCommand.defaultConfigurationName)
        #expect(RunCommand.configurationArguments(session.configuration).isEmpty)
    }

    /// **始めることを、始める前に言う。** 作り直しはこの流れを塞ぐので、後から言うと
    /// 待っている間が無言になり、「見張れていない」と読まれる ([#695](https://github.com/mokume-metal/mokume/issues/695))。
    @Test("作り直しは、始める前に名乗る")
    func announcesBeforeItRebuilds() throws {
        let recorder = Recorder()
        let session = WatchSession(directory: try makeDirectory(), hooks: recorder.hooks())
        var events: [String] = []
        session.willRebuild = { events.append($0 ? "初回を始める" : "変更で始める") }
        recorder.onBuild = { events.append("作り直す") }

        session.start()
        recorder.stamp = "bbb"
        session.tick()

        #expect(events == ["初回を始める", "作り直す", "変更で始める", "作り直す"])
    }

    /// **名乗らないのが既定。** 窓口はスケッチを起こさないが、口の側が何も渡さなければ
    /// 何も起きないことを、ここで固定しておく。
    @Test("名乗りを渡さなければ、何も起きない")
    func staysSilentWithoutAListener() throws {
        let recorder = Recorder()
        let session = WatchSession(directory: try makeDirectory(), hooks: recorder.hooks())
        session.start()
        #expect(recorder.builds == 1)
    }

    private func makeDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("mokume-watch-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test("最初の 1 回は、変化を待たずに作って走らせる")
    func buildsOnceAtTheStart() throws {
        let recorder = Recorder()
        let session = WatchSession(
            directory: try makeDirectory(), hooks: recorder.hooks())

        let report = session.start()
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
    func staysIdleWhenNothingChanged() throws {
        let recorder = Recorder()
        let session = WatchSession(directory: try makeDirectory(), hooks: recorder.hooks())
        session.start()

        #expect(session.tick() == nil)
        #expect(session.tick() == nil)
        #expect(recorder.builds == 1)
        #expect(recorder.launches == 1)
    }

    @Test("変わったら作り直して差し替え、所要時間を 3 つに分けて出す")
    func rebuildsAndReplacesOnChange() throws {
        let recorder = Recorder()
        let session = WatchSession(directory: try makeDirectory(), hooks: recorder.hooks())
        session.start()

        recorder.stamp = "bbb"
        let report = try #require(session.tick())

        #expect(recorder.builds == 2)
        #expect(recorder.launches == 2)
        #expect(report.ok)
        #expect(report.timings.detectMs != nil)
        #expect(report.timings.buildMs > 0)
        #expect(report.timings.relaunchMs != nil)
        #expect(report.configuration == "debug")
    }

    @Test("新しい世代の刻印が、走らせる子へ渡る")
    func handsTheStampToTheChild() throws {
        let recorder = Recorder()
        let session = WatchSession(directory: try makeDirectory(), hooks: recorder.hooks())
        session.start()
        recorder.stamp = "bbb"
        session.tick()

        // 読み手はこの刻印の変化で「保存した内容が反映されたか」を判定する
        #expect(recorder.stampsGivenToChildren == ["aaa", "bbb"])
    }

    @Test("作り直しに失敗したら、差し替えない")
    func keepsTheRunningVersionWhenTheBuildFails() throws {
        let recorder = Recorder()
        let session = WatchSession(directory: try makeDirectory(), hooks: recorder.hooks())
        session.start()

        recorder.stamp = "bbb"
        recorder.buildStatus = 1
        recorder.buildOutput = "error: cannot find 'circl' in scope"
        let report = try #require(session.tick())

        #expect(!report.ok)
        #expect(report.status == 1)
        #expect(report.output.contains("circl"))
        // 差し替えていない = 直前の版が走り続けている
        #expect(recorder.launches == 1)
        #expect(report.timings.relaunchMs == nil)
    }

    @Test("壊れたままのソースで、作り直しを繰り返さない")
    func doesNotRetryTheSameBrokenSource() throws {
        let recorder = Recorder()
        let session = WatchSession(directory: try makeDirectory(), hooks: recorder.hooks())
        session.start()
        recorder.stamp = "bbb"
        recorder.buildStatus = 1
        session.tick()

        #expect(session.tick() == nil)
        #expect(recorder.builds == 2)

        // 直せば、そのとき次の作り直しが走る
        recorder.stamp = "ccc"
        recorder.buildStatus = 0
        #expect(session.tick() != nil)
        #expect(recorder.builds == 3)
    }

    @Test("結果が区画のファイルに残る")
    func leavesTheOutcomeInTheFacet() throws {
        let recorder = Recorder()
        let directory = try makeDirectory()
        let session = WatchSession(directory: directory, hooks: recorder.hooks())
        session.start()

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
    func writesTheOutcomeToTheFacetBase() throws {
        let recorder = Recorder()
        let package = try makeDirectory()
        let work = try makeDirectory()
        // 走らせたスケッチは MOKUME_WORK_DIR に従って観測を書く。記録だけパッケージの
        // 場所に残ると、読み手から見て観測と記録が割れる (#331)
        let session = WatchSession(directory: package, facetBase: work, hooks: recorder.hooks())
        session.start()

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
        WatchSession.Hooks(
            build: { _ in (0, "") },
            resolveExecutable: { _ in URL(fileURLWithPath: "/bin/sh") },
            launch: { executable, _, _, _ in
                let process = Process()
                process.executableURL = executable
                // **眠らせずに、来ない入力を待たせる。** 眠らせると、強制終了した後に
                // 眠りだけが残る (親を失った `sleep` は生き続ける)
                process.arguments = [
                    "-c", (ignores ? "trap '' TERM; " : "") + "echo ready; read line",
                ]
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
    func stopsAChildThatListens() throws {
        let ready = Ready()
        let session = WatchSession(
            directory: try makeDirectory(), hooks: hooks(ignoringTermination: false, ready: ready),
            stopTimeout: 1)
        session.start()
        let child = try #require(session.child)
        ready.waitForLast()
        #expect(child.isRunning)

        #expect(session.stop() == .terminated)
        #expect(!child.isRunning)
    }

    /// **待つ側が期限を持つ。** 期限が無ければ、ここは永久に戻らない (#732)。
    @Test("止めてくれと頼んでも応えない子は、期限で強制終了する")
    func killsAChildThatIgnoresTermination() throws {
        let ready = Ready()
        let session = WatchSession(
            directory: try makeDirectory(), hooks: hooks(ignoringTermination: true, ready: ready),
            stopTimeout: 0.2)
        session.start()
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
    func replacesEvenWhenTheChildIgnoresTermination() throws {
        let ready = Ready()
        let session = WatchSession(
            directory: try makeDirectory(), hooks: hooks(ignoringTermination: true, ready: ready),
            stopTimeout: 0.2)
        session.start()
        let first = try #require(session.child)
        ready.waitForLast()
        defer { session.stop() }

        session.tick()
        #expect(!first.isRunning, "前の子が残っている")
        #expect(session.lastStop == .killed, "期限に掛かったことが残っていない")
        #expect(session.child !== first, "差し替わっていない")
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
