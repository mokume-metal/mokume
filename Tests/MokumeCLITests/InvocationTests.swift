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
    /// **黙って窓が出ない**のに、そう言うための名乗りだけが基準を取り違えていた。
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
            directory: sketch, facetBase: invocation.facetBase(workDirectory: given))
        let placed = WatchCommand.viewportFacet(for: session)
        #expect(placed.path.hasPrefix(work.path), "見張りはスケッチの場所ではなく基準の下へ置く")
        try FileManager.default.createDirectory(at: placed, withIntermediateDirectories: true)

        let notice = RunCommand.sharedSurfaceNotice(for: invocation, workDirectory: given)
        #expect(
            notice != nil,
            "見張りが置いた区画を run が見つけられていない (窓が出ないことを名乗れない)")
        // 在処をそのまま出す — `.mokume/…` とだけ言うとスケッチの場所を探すことになる
        #expect(notice?.contains(placed.path) == true)

        // 基準が与えられていなければ、スケッチの場所を見る (いままでどおり)
        #expect(RunCommand.sharedSurfaceNotice(for: invocation, workDirectory: nil) == nil)
        try FileManager.default.createDirectory(
            at: WatchCommand.viewportFacet(under: sketch), withIntermediateDirectories: true)
        #expect(RunCommand.sharedSurfaceNotice(for: invocation, workDirectory: nil) != nil)
    }

    static func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("mokume-invocation-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
