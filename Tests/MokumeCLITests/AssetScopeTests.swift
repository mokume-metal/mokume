// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation
import MokumeTestSupport
import Synchronization
import Testing
import mokume

@testable import MokumeCLI

/// 走らせる子に探させない資材の包み (#4038)。
///
/// `run`・`watch`・`render`・`replay` のビルドの置き場は共有なので、実行ファイルの隣にはいまの宣言に無い包みも
/// 並ぶ。どれを外すかは `bundle` が写さない包みと同じ規則で決め、子へ環境変数で渡し、起動で 1 行名乗る。
@Suite("子に探させない包み")
struct AssetScopeTests {
    /// いまの宣言: パッケージ `demo`、実行 product `demo` は target `demo` だけ。
    private static let dump = """
        {"name":"demo",
         "products":[{"name":"demo","type":{"executable":null},"targets":["demo"]}],
         "targets":[
           {"name":"demo","type":"executable","resources":[{"rule":{"copy":{}},"path":"assets"}],
            "dependencies":[{"product":["mokume","mokume",null,null]}]},
           {"name":"demoTests","type":"test","resources":[{"rule":{"copy":{}},"path":"fixtures"}],
            "dependencies":[{"byName":["demo",null]}]}]}
        """

    /// 依存の木の答え: 依存は `mokume` だけ。
    nonisolated private static let tree = """
        {"identity":"demo","name":"demo","dependencies":[
          {"identity":"mokume","name":"mokume","dependencies":[]}]}
        """

    /// 実行ファイルと、その隣に並んだ包みを作る。
    private func makeBuild(beside names: [String]) throws -> (root: URL, executable: URL) {
        let root = try TestScratch.directory("mokume-asset-scope")
        let bin = root.appendingPathComponent("bin", isDirectory: true)
        for name in names {
            try FileManager.default.createDirectory(
                at: bin.appendingPathComponent(name, isDirectory: true), withIntermediateDirectories: true)
        }
        let executable = bin.appendingPathComponent("demo")
        try "#!/bin/sh\n".write(to: executable, atomically: true, encoding: .utf8)
        return (root, executable)
    }

    private func context(declared: SwiftPM.Package?, product: String? = "demo") -> BuildContext {
        BuildContext(
            configuration: nil, place: .outside(URL(fileURLWithPath: "/store"), given: false), product: product,
            declared: declared)
    }

    /// **共有の置き場に並ぶ、いまの宣言に無い包みは外す** — 改名する前のパッケージ名 (`Aaa_demo`)・テストの
    /// target (`demo_demoTests`)・別のスケッチ (`other_other`)。いまの target と依存 (`mokume`) の包みは外さない。
    /// 依存の木は、走らせる置き場 (`--scratch-path`) について問う。
    @Test("いまの宣言に無い包みを外し、依存の木は走らせる置き場について問う")
    func undeclaredBundlesAreLeftOut() throws {
        let (root, executable) = try makeBuild(beside: [
            "Aaa_demo.bundle", "demo_demo.bundle", "demo_demoTests.bundle", "mokume_MokumeCore.bundle",
            "other_other.bundle",
        ])
        defer { try? FileManager.default.removeItem(at: root) }
        let declared = try #require(SwiftPM.package(inDumpOf: Self.dump))
        let asked = Mutex<[[String]]>([])
        let names = AssetScope.undeclaredBundles(
            context: context(declared: declared), executable: executable, package: root
        ) { arguments, _ in
            asked.withLock { $0.append(arguments) }
            return (0, Self.tree)
        }
        #expect(names == ["Aaa_demo.bundle", "demo_demoTests.bundle", "other_other.bundle"])
        #expect(
            asked.withLock { $0 }
                == [["package", "--scratch-path", "/store", "show-dependencies", "--format", "json"]])
    }

    /// **求められなければ何も外さない** (子は隣の包みを全部探す) — 宣言が読めない・product が無い・依存の木が
    /// 読めない。宣言が読めなければ道具立てに問わない。依存の木が読めない回は、宣言だけで決まるテストの target の
    /// 包み (`demo_demoTests`) も外さない (完了条件 3 の「いままでどおり全部探す」)。
    @Test("宣言・product・依存の木のどれかが読めなければ、何も外さない")
    func nothingIsLeftOutWhenUndecidable() throws {
        let (root, executable) = try makeBuild(beside: [
            "Aaa_demo.bundle", "demo_demo.bundle", "demo_demoTests.bundle",
        ])
        defer { try? FileManager.default.removeItem(at: root) }
        let declared = try #require(SwiftPM.package(inDumpOf: Self.dump))
        let asked = Mutex(0)
        let counting: AssetScope.Asking = { _, _ in
            asked.withLock { $0 += 1 }
            return (1, "")
        }
        #expect(
            AssetScope.undeclaredBundles(
                context: context(declared: nil), executable: executable, package: root, asking: counting
            ).isEmpty)
        #expect(
            AssetScope.undeclaredBundles(
                context: context(declared: declared, product: nil), executable: executable, package: root,
                asking: counting
            ).isEmpty)
        #expect(asked.withLock { $0 } == 0)
        // 依存の木が読めない
        #expect(
            AssetScope.undeclaredBundles(
                context: context(declared: declared), executable: executable, package: root, asking: counting
            ).isEmpty)
        #expect(asked.withLock { $0 } == 1)
        // 依存の木が要らない並び (いまの target とテストの target の包みだけ) なら、テストの target の包みは外す
        try FileManager.default.removeItem(
            at: executable.deletingLastPathComponent().appendingPathComponent("Aaa_demo.bundle"))
        #expect(
            AssetScope.decided(
                context: context(declared: declared), executable: executable, package: root, asking: counting)
                == ["demo_demoTests.bundle"])
        #expect(asked.withLock { $0 } == 1)
    }

    /// **見張りは、たまたま失敗した問いの答えを持ち回らない** — 並びが変わらなくても、次の建ちで問い直す。
    /// 問いが通った後は、同じ並びで問い直さない。
    @Test("見張りは失敗した問いの答えを持ち回らず、次の建ちで問い直す")
    func theWatcherDoesNotCarryAFailedAnswer() throws {
        let (root, executable) = try makeBuild(beside: ["Aaa_demo.bundle", "demo_demo.bundle"])
        defer { try? FileManager.default.removeItem(at: root) }
        let declared = try #require(SwiftPM.package(inDumpOf: Self.dump))
        let answers = Mutex<[(Int32, String)]>([(1, ""), (0, Self.tree)])
        let asked = Mutex(0)
        let carried = AssetScope.Carried { _, _ in
            asked.withLock { $0 += 1 }
            return answers.withLock { $0.isEmpty ? (0, Self.tree) : $0.removeFirst() }
        }
        let context = context(declared: declared)
        #expect(carried.refresh(context: context, executable: executable, package: root) == nil)
        #expect(carried.current.isEmpty, "問えなかった回に包みを外した")
        let second = carried.refresh(context: context, executable: executable, package: root)
        #expect(asked.withLock { $0 } == 2, "失敗した答えを持ち回って問い直さなかった")
        #expect(second == AssetScope.notice(["Aaa_demo.bundle"]))
        #expect(carried.current == ["Aaa_demo.bundle"])
        #expect(carried.refresh(context: context, executable: executable, package: root) == nil)
        #expect(asked.withLock { $0 } == 2)
    }

    /// **普通のスケッチでは依存の木を問わない** (#4038 の反証・指摘 3)。依存は mokume だけで、隣には実物と同じく
    /// `mokume_MokumeCore.bundle` が並ぶ。直接の依存の identity (`mokume`) で説明できるので、`show-dependencies` を
    /// 起こさずに「外すものは無い」と決まる。説明できない包み (共有の置き場の別のスケッチ) が並べば問う。
    @Test("依存が mokume だけのスケッチは、隣に mokume の包みが在っても依存の木を問わない")
    func anOrdinarySketchAsksNothing() throws {
        let dump = """
            {"name":"demo",
             "products":[{"name":"demo","type":{"executable":null},"targets":["demo"]}],
             "targets":[{"name":"demo","type":"executable","resources":[{"rule":{"copy":{}},"path":"assets"}],
               "dependencies":[{"product":["mokume","mokume",null,null]}]}],
             "dependencies":[{"sourceControl":[{"identity":"mokume","productFilter":null}]}]}
            """
        let (root, executable) = try makeBuild(beside: ["demo_demo.bundle", "mokume_MokumeCore.bundle"])
        defer { try? FileManager.default.removeItem(at: root) }
        let declared = try #require(SwiftPM.package(inDumpOf: dump))
        let asked = Mutex(0)
        let counting: AssetScope.Asking = { _, _ in
            asked.withLock { $0 += 1 }
            return (0, Self.tree)
        }
        #expect(
            AssetScope.decided(
                context: context(declared: declared), executable: executable, package: root, asking: counting)
                == [])
        #expect(asked.withLock { $0 } == 0)

        try FileManager.default.createDirectory(
            at: executable.deletingLastPathComponent().appendingPathComponent("other_other.bundle"),
            withIntermediateDirectories: true)
        #expect(
            AssetScope.decided(
                context: context(declared: declared), executable: executable, package: root, asking: counting)
                == ["other_other.bundle"])
        #expect(asked.withLock { $0 } == 1)
    }

    /// **問いは待つ側が期限を持つ** — 答えない子は殺して「求められない」(0 以外) にする。答えた子の出力は掴む。
    /// 止めると決めた後 (見張りが終わるとき) は起こさない。
    @Test("依存の木の問いは期限を越えたら子を殺し、止めた後は起こさない")
    func theQuestionHasADeadline() throws {
        let silent = Process()
        silent.executableURL = URL(fileURLWithPath: "/bin/sleep")
        silent.arguments = ["600"]
        let late = BundleCommand.ask(silent, timeout: 0.2)
        #expect(late.status != 0)
        #expect(!silent.isRunning, "期限を越えた子が残っている")

        let echo = Process()
        echo.executableURL = URL(fileURLWithPath: "/bin/echo")
        echo.arguments = ["{}"]
        let answered = BundleCommand.ask(echo, timeout: 60)
        #expect(answered.status == 0)
        #expect(answered.output == "{}\n")

        let running = RunningBuild()
        _ = running.stop()
        let stopped = Process()
        stopped.executableURL = URL(fileURLWithPath: "/bin/echo")
        #expect(BundleCommand.ask(stopped, timeout: 60, running: running).status != 0)
        #expect(stopped.processIdentifier == 0, "止めると決めた後に起こした")
    }

    /// 名乗りは 1 行。共有の置き場には別のスケッチの包みが多く並びうるので、並べる名前には上限がある。
    @Test("外した包みの名乗りは 1 行で、多ければ数で畳む")
    func theNoticeIsOneLine() {
        #expect(AssetScope.notice([]) == nil)
        let one = AssetScope.notice(["Aaa_demo.bundle"])
        #expect(
            one
                == "Not looking for assets in 1 bundle in the build folder that are not from this product"
                + " or its dependencies: Aaa_demo.bundle")
        let many = Set((1...7).map { "s\($0)_s.bundle" })
        let line = AssetScope.notice(many) ?? ""
        #expect(!line.contains("\n"))
        #expect(line.contains("7 bundles"))
        #expect(line.hasSuffix("s1_s.bundle, s2_s.bundle, s3_s.bundle, s4_s.bundle, s5_s.bundle and 2 more"))
        #expect(!line.contains("s6_s.bundle"))
        // 別のスケッチの現役の包みも入るので、古い・要らないとは言わない (#4038 の反証・指摘 6)
        #expect(!line.contains(" old") && !line.contains(" now") && !line.contains("stale") && !line.contains("builds"))
    }

    /// **`run` の経路が組む子の環境に、外す包みが載る** (#4038 の反証・指摘 8)。外す包みを決める口と、
    /// 子の環境へ渡す引数のどちらを外しても赤になる。名乗りも同じ口から 1 行出る。
    @Test("run が組む子の環境に、外す包みが載り、1 行名乗る")
    func theRunEnvironmentCarriesTheList() throws {
        let (root, executable) = try makeBuild(beside: ["Aaa_demo.bundle", "demo_demo.bundle"])
        defer { try? FileManager.default.removeItem(at: root) }
        let declared = try #require(SwiftPM.package(inDumpOf: Self.dump))
        var said: [String] = []
        let environment = RunCommand.runEnvironment(
            for: executable, context: context(declared: declared), in: root, recording: nil,
            say: { said.append($0) }, asking: { _, _ in (0, Self.tree) })
        #expect(environment[StartupReads.undeclaredBundles.key] == "Aaa_demo.bundle")
        #expect(said == [AssetScope.notice(["Aaa_demo.bundle"])].compactMap { $0 })
    }

    /// **見張りは、作り直しの後に子へ渡す値を更新する** (#4038 の反証・指摘 8)。本物の起こす口
    /// (``WatchSession/Hooks/live(resolver:running:stamps:keepTime:recording:progress:undeclared:)``) が、作り直しの後の
    /// 段取り (``AssetScope/Carried/afterRebuild(_:context:package:)``) で決めた包みを子の環境へ載せる。建たなかった
    /// 回は読み直さない。作り直しの口がこの段取りを呼ぶことは、`swift build` を走らせずには通せない (PR 本文に探した式)。
    @Test("見張りは作り直しの後に、外す包みを子の環境へ渡す")
    func theWatcherPassesTheListAfterARebuild() throws {
        let (root, executable) = try makeBuild(beside: ["Aaa_demo.bundle", "demo_demo.bundle"])
        defer { try? FileManager.default.removeItem(at: root) }
        let bin = executable.deletingLastPathComponent()
        let seen = root.appendingPathComponent("seen")
        try """
            #!/bin/sh
            printf '%s' "$\(StartupReads.undeclaredBundles.key)" > '\(seen.path)'
            """.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        let declared = try #require(SwiftPM.package(inDumpOf: Self.dump))
        let resolver = BuildResolver(directory: root) { _ in
            BuildResolution(context: self.context(declared: declared), binPath: bin)
        }
        let undeclared = AssetScope.Carried { _, _ in (0, Self.tree) }
        let hooks = WatchSession.Hooks.live(resolver: resolver, running: RunningBuild(), undeclared: undeclared)

        func launched() throws -> String {
            let child = try hooks.launch(executable, root, nil, nil)
            child.waitUntilExit()
            return try String(contentsOf: seen, encoding: .utf8)
        }
        func rebuilt(status: Int32) -> RunCommand.Rebuilt {
            RunCommand.Rebuilt(status: status, output: "", executable: executable, binPath: bin, product: "demo")
        }
        let context = context(declared: declared)
        #expect(try launched() == "", "建つ前に外す包みを渡した")
        #expect(undeclared.afterRebuild(rebuilt(status: 1), context: context, package: root) == nil)
        #expect(try launched() == "", "建たなかった回に読み直した")
        #expect(
            undeclared.afterRebuild(rebuilt(status: 0), context: context, package: root)
                == AssetScope.notice(["Aaa_demo.bundle"]))
        #expect(try launched() == "Aaa_demo.bundle", "作り直しの後に外す包みを子へ渡していない")
    }

    /// **見張りは、宣言・置き場・隣の並びが変わらなければ問い直さず、外す包みが変わった回だけ名乗る**
    /// (起動で 1 度)。並びが変われば問い直す。
    @Test("見張りは同じ並びで問い直さず、外す包みが変わった回だけ名乗る")
    func theWatcherAsksAndAnnouncesOnlyOnChange() throws {
        let (root, executable) = try makeBuild(beside: ["Aaa_demo.bundle", "demo_demo.bundle"])
        defer { try? FileManager.default.removeItem(at: root) }
        let declared = try #require(SwiftPM.package(inDumpOf: Self.dump))
        let asked = Mutex(0)
        let carried = AssetScope.Carried { _, _ in
            asked.withLock { $0 += 1 }
            return (0, Self.tree)
        }
        let context = context(declared: declared)
        let first = carried.refresh(context: context, executable: executable, package: root)
        #expect(first == AssetScope.notice(["Aaa_demo.bundle"]))
        #expect(carried.current == ["Aaa_demo.bundle"])
        #expect(carried.refresh(context: context, executable: executable, package: root) == nil)
        #expect(asked.withLock { $0 } == 1)

        // 別のスケッチの包みが隣に増えた
        try FileManager.default.createDirectory(
            at: executable.deletingLastPathComponent().appendingPathComponent("other_other.bundle"),
            withIntermediateDirectories: true)
        let second = carried.refresh(context: context, executable: executable, package: root)
        #expect(second == AssetScope.notice(["Aaa_demo.bundle", "other_other.bundle"]))
        #expect(carried.current == ["Aaa_demo.bundle", "other_other.bundle"])
        #expect(asked.withLock { $0 } == 2)
    }

    /// 探さない包みは起こす道具が自分の置き場から決める値なので、渡さなければ親の環境に在っても落とす。
    @Test("探さない包みは渡したときだけ子へ載り、親の環境に在っても落とす")
    func theListGoesOnlyWhenGiven() {
        let key = StartupReads.undeclaredBundles.key
        #expect(RunCommand.childEnvironment([key: "stale_stale.bundle"])[key] == nil, "親の値を継いだ")
        #expect(
            RunCommand.childEnvironment([:], undeclaredBundles: ["b_b.bundle", "a_a.bundle"])[key]
                == "a_a.bundle/b_b.bundle")
    }
}
