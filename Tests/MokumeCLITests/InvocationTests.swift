// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation
import Testing
import mokume

@testable import MokumeCLI

/// 走らせる口が受け取るもの (#680)。
///
/// **`run` と `watch` は同じものを受ける。** 別々に解いていた頃は、構成を選ぶ口が
/// どちらにも無く、`-c release` は場所として解釈されていた。
@Suite("走らせる口の引数")
struct InvocationTests {
    @Test("場所だけを渡せる")
    func takesJustThePlace() throws {
        #expect(try Invocation.parse(["/tmp/sketch"]) == Invocation(place: "/tmp/sketch"))
        #expect(try Invocation.parse([]) == Invocation())
    }

    /// **順序を問わない。** 打つ人が覚えることを増やさない。
    @Test("構成は場所の前でも後でも受ける")
    func takesTheConfigurationOnEitherSide() throws {
        let expected = Invocation(place: "/tmp/sketch", configuration: "release")
        #expect(try Invocation.parse(["/tmp/sketch", "-c", "release"]) == expected)
        #expect(try Invocation.parse(["-c", "release", "/tmp/sketch"]) == expected)
        #expect(
            try Invocation.parse(["--configuration", "release", "/tmp/sketch"]) == expected)
    }

    /// **既定を変えたので、戻す口が要る。** 置き場は既定で版ごとの共有になるが、
    /// 隔離したい場面 (検査・計測) では従来どおりパッケージ直下を指せる。
    @Test("置き場は、構成と同じ形で順序を問わずに受ける")
    func takesTheScratchPathOnEitherSide() throws {
        let expected = Invocation(place: "/tmp/sketch", scratchPath: ".build")
        #expect(try Invocation.parse(["/tmp/sketch", "--scratch-path", ".build"]) == expected)
        #expect(try Invocation.parse(["--scratch-path", ".build", "/tmp/sketch"]) == expected)
        // 構成と併せて渡せる (どちらも道具立てへ通す指定である)
        #expect(
            try Invocation.parse(["-c", "release", "--scratch-path", "/store", "/tmp/sketch"])
                == Invocation(
                    place: "/tmp/sketch", configuration: "release", scratchPath: "/store"))
    }

    /// **知らない選択肢を黙って場所にしない** ([#680] が構成で踏んだ形と同じ)。
    ///
    /// [#680]: https://github.com/mokume-metal/mokume/issues/680
    @Test("置き場の綴りのあとに値が無ければ、使い方を言う")
    func aScratchPathWithoutAValueIsRefused() throws {
        #expect(throws: CommandFailure.self) { try Invocation.parse(["--scratch-path"]) }
    }

    /// **名乗りと実体は同じ値から出す。** 選ばれていなければ道具立ての既定に任せ、
    /// 名乗りだけ既定の名前を使う。
    @Test("選ばれていなければ、道具立てに任せて既定の名前を名乗る")
    func leavesTheDefaultToTheToolchain() throws {
        let invocation = try Invocation.parse([])
        #expect(invocation.configuration == nil)
        #expect(invocation.configurationName == RunCommand.defaultConfigurationName)
        #expect(RunCommand.configurationArguments(invocation.configuration).isEmpty)
    }

    @Test("選ばれていれば、その名前を名乗り、その構成で組む")
    func carriesTheChosenConfiguration() throws {
        let invocation = try Invocation.parse(["-c", "release"])
        #expect(invocation.configurationName == "release")
        #expect(RunCommand.configurationArguments(invocation.configuration) == ["-c", "release"])
    }

    // ------------------------------------------------------------ 構成の値 (#2316)

    /// **組み立ての前に断る。** 検めずに道具立てへ渡していた頃は、`swift build
    /// --show-bin-path -c Release` が usage を出して非 0 で終わり、その空の出力が
    /// 「Package.swift に実行ファイルが無い」と名乗られていた
    /// ([#2316](https://github.com/mokume-metal/mokume/issues/2316))。
    ///
    /// **大小を読み替えない。** 綴りは道具立てに合わせる (``Invocation/configurationFlags``)。
    @Test(
        "debug / release 以外の構成は、受け付ける値を名指しして止まる",
        arguments: ["Release", "DEBUG", "bogus", "", " release"])
    func refusesAnUnknownConfiguration(configuration: String) {
        for flag in Invocation.configurationFlags {
            let thrown = #expect(throws: CommandFailure.self) {
                try Invocation.parse([flag, configuration, "/tmp/sketch"])
            }
            guard case .usage(let message) = thrown else {
                Issue.record("使い方の誤りとして止まっていない: \(String(describing: thrown))")
                continue
            }
            #expect(message.contains("debug"), "受け付ける値 (debug) を名指していない: \(message)")
            #expect(message.contains("release"), "受け付ける値 (release) を名指していない: \(message)")
            #expect(message.contains(": \(configuration)"), "渡した値を名乗っていない: \(message)")
        }
    }

    /// 裏側。受け付ける値と、渡さない場合はいままでどおり通る。
    @Test("debug・release と、構成を渡さない場合は通る")
    func acceptsTheToolchainsConfigurations() throws {
        for configuration in ["debug", "release"] {
            for flag in Invocation.configurationFlags {
                #expect(
                    try Invocation.parse([flag, configuration])
                        == Invocation(configuration: configuration))
            }
        }
        #expect(try Invocation.parse(["/tmp/sketch"]).configuration == nil)
    }

    /// **口ごとに、`swift` を 1 本も起こす前に止まる。** 在らない場所を渡しても
    /// 「スケッチが見つからない」(`Package.swift` を確かめる段) より先に断るので、
    /// その後ろにある `dump-package`・`--show-bin-path`・`build` は走りようがない。
    @Test("run・watch・render は、場所を確かめる前に構成の誤りで止まる")
    func eachDoorRefusesBeforeLookingAtThePlace() {
        let nowhere = "/nonexistent-\(UUID().uuidString)"
        let doors: [(String, () throws(CommandFailure) -> Void)] = [
            ("run", { () throws(CommandFailure) in try RunCommand.run(["-c", "Release", nowhere]) }),
            (
                "watch",
                { () throws(CommandFailure) in
                    try WatchCommand.run(["-c", "DEBUG", nowhere]) { _, _ in }
                }
            ),
            (
                "render",
                { () throws(CommandFailure) in
                    try RenderCommand.run([
                        "-c", "bogus", "--fps", "10", "--seconds", "0.1", "--out", "c.mov", nowhere,
                    ])
                }
            ),
        ]
        for (name, door) in doors {
            do {
                try door()
                Issue.record("\(name) が止まらなかった")
            } catch {
                guard case .usage = error else {
                    Issue.record("\(name) が構成の誤りより先に別の段で止まった: \(error)")
                    continue
                }
            }
        }
    }

    /// **知らない選択肢を黙って場所にしない。** 「スケッチが見つからない: …/-c」では
    /// 何を直せばよいか分からない。
    @Test("知らない選択肢は、使い方を出して止まる")
    func refusesUnknownOptions() {
        #expect(throws: CommandFailure.self) { try Invocation.parse(["--fast"]) }
        #expect(throws: CommandFailure.self) { try Invocation.parse(["-c"]) }
        #expect(throws: CommandFailure.self) { try Invocation.parse(["a", "b"]) }
    }

    // ------------------------------------------------------------ 区画の基準

    /// **区画の基準は、走らせるスケッチが従うものに合わせる。** 環境変数から基準を解く
    /// 規則は `WorkDirectory` が持つので、ここが見るのは「解かれた結果に道具の既定値を
    /// 当てる」ところだけである。
    @Test("環境変数が基準を与えていれば、それが区画の基準になる")
    func theWorkDirectoryDecidesTheFacetBase() {
        let sketch = URL(fileURLWithPath: "/sketch", isDirectory: true)
        let elsewhere = "/elsewhere"
        let given = WorkDirectory.given(environment: [StartupReads.workDirectory.key: elsewhere])
        let invocation = Invocation(place: sketch.path)

        #expect(given?.path == elsewhere)
        #expect(invocation.facetBase(workDirectory: given).path == elsewhere)
        // 与えられていなければスケッチの場所 (いままでどおり)
        #expect(invocation.facetBase(workDirectory: nil).path == sketch.path)
        #expect(Invocation.facetBase(under: sketch, workDirectory: nil).path == sketch.path)
    }

    /// `run` が見る区画と `watch` が置く区画が別々に組まれていて、`MOKUME_WORK_DIR` の
    /// 下で割れていた ([#791](https://github.com/mokume-metal/mokume/issues/791))。
    /// **黙って窓が出ない**のに、そう言うための名乗りだけが基準を取り違えていた。いまも
    /// 古いライブラリのスケッチは区画が在ると窓を開かないので、名乗りは要る (#2028)。
    @MainActor
    @Test("基準を与えても、run は watch が置いた区画を見つけて名乗る")
    func runLooksWhereWatchPlacesTheViewport() throws {
        let sketch = try Self.directory()
        let work = try Self.directory()
        defer {
            try? FileManager.default.removeItem(at: sketch)
            try? FileManager.default.removeItem(at: work)
        }
        // MOKUME_WORK_DIR を与えた環境が解決する基準
        let given = WorkDirectory.given(environment: [StartupReads.workDirectory.key: work.path])
        let invocation = Invocation(place: sketch.path)

        // 見張りが置く先 (WatchCommand が窓を出せたときに作る区画)
        let session = WatchSession(
            directory: sketch, context: testContext(), facetBase: invocation.facetBase(workDirectory: given))
        let placed = WatchCommand.viewportFacet(for: session)
        #expect(placed.path.hasPrefix(work.path), "見張りはスケッチの場所ではなく基準の下へ置く")
        // 子は与えられた基準の下の区画を見る (`WorkDirectory.facet` と同じ規則)
        #expect(placed == WorkDirectory.facet(StartupReads.viewport.key, under: work))
        // 基準が与えられていなければ、スケッチの場所 (いままでどおり)
        #expect(
            WatchCommand.viewportFacet(under: invocation.facetBase(workDirectory: nil))
                == WorkDirectory.facet(StartupReads.viewport.key, under: sketch))

        // **run も同じ場所を見て名乗る** — 古いライブラリのスケッチは区画が在ると窓を開かず、
        // 自分では何も言わない (#2028)。名乗りが基準を取り違えると、黙って窓が出ない (#791)
        try FileManager.default.createDirectory(at: placed, withIntermediateDirectories: true)
        let notice = RunCommand.sharedSurfaceNotice(for: invocation, workDirectory: given)
        #expect(notice?.contains(placed.path) == true, "見張りが置いた区画を run が見つけられていない")
        #expect(notice?.contains("older mokume") == true, "版のずれを疑わせる手掛かりが無い")
        #expect(RunCommand.sharedSurfaceNotice(for: invocation, workDirectory: nil) == nil)
    }

    static func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("mokume-invocation-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
