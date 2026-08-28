// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation
import Testing

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
        /// 作り直しを頼まれた場所。**パッケージの場所であることを見る** (#331)
        var builtIn: [URL] = []

        func hooks() -> WatchSession.Hooks {
            WatchSession.Hooks(
                build: { directory in
                    self.builds += 1
                    self.builtIn.append(directory)
                    // 作り直しには時間がかかる。刻む対象なので時計を進める
                    self.clock += 0.5
                    return (self.buildStatus, self.buildOutput)
                },
                resolveExecutable: { $0.appendingPathComponent("bin") },
                launch: { _, _, stamp in
                    self.launches += 1
                    self.stampsGivenToChildren.append(stamp)
                    self.clock += 0.03
                    return nil
                },
                now: { self.clock },
                stamp: { _ in self.stamp })
        }
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
