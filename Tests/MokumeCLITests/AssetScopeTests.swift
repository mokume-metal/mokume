// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation
import MokumeTestSupport
import Synchronization
import Testing
import mokume

@testable import MokumeCLI

/// 走らせる子に探させてよい資材の包み (#4038)。
///
/// `run`・`watch`・`render`・`replay` のビルドの置き場は共有なので、実行ファイルの隣にはいまの宣言に無い包みも
/// 並ぶ。子へは許す一覧 (閉包の target の包みの名前 + 依存の名前の頭) を渡し、依存の木の答えと名乗りは置き場に
/// 控える。**検査は実物の `swift package` を起こさない** (問いは差し替える)。
@Suite("子に探させてよい包み")
struct AssetScopeTests {
    /// いまの宣言: パッケージ `demo`、実行 product `demo` は target `demo` だけ。直接の依存は identity `mokume`。
    private static let dump = """
        {"name":"demo",
         "products":[{"name":"demo","type":{"executable":null},"targets":["demo"]}],
         "targets":[
           {"name":"demo","type":"executable","resources":[{"rule":{"copy":{}},"path":"assets"}],
            "dependencies":[{"product":["mokume","mokume",null,null]}]},
           {"name":"demoTests","type":"test","resources":[{"rule":{"copy":{}},"path":"fixtures"}],
            "dependencies":[{"byName":["demo",null]}]}],
         "dependencies":[{"sourceControl":[{"identity":"mokume","productFilter":null}]}]}
        """

    /// 置き場 (控えの置き場) と、パッケージの根と、実行ファイル。
    private struct Build {
        let root: URL
        let package: URL
        let store: URL
        let executable: URL

        var bin: URL { executable.deletingLastPathComponent() }

        func place(_ names: String...) throws {
            for name in names {
                try FileManager.default.createDirectory(
                    at: bin.appendingPathComponent(name, isDirectory: true), withIntermediateDirectories: true)
            }
        }
    }

    /// 実行ファイルと、その隣に並んだ包みを作る。パッケージの根には宣言のファイルを置く (控えの鍵になる)。
    private func makeBuild(beside names: [String]) throws -> Build {
        let root = try TestScratch.directory("mokume-asset-scope")
        let package = root.appendingPathComponent("demo", isDirectory: true)
        try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
        try "// demo".write(to: package.appendingPathComponent("Package.swift"), atomically: true, encoding: .utf8)
        let store = root.appendingPathComponent("store", isDirectory: true)
        let bin = store.appendingPathComponent("bin", isDirectory: true)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let executable = bin.appendingPathComponent("demo")
        try "#!/bin/sh\n".write(to: executable, atomically: true, encoding: .utf8)
        let build = Build(root: root, package: package, store: store, executable: executable)
        for name in names { try build.place(name) }
        return build
    }

    /// 依存の木の答え: 依存は `mokume` (在処は `mokume`)。
    private func tree(_ build: Build, dependency: String = "mokume") -> String {
        """
        {"identity":"demo","name":"demo","path":"\(build.package.path)","dependencies":[
          {"identity":"\(dependency)","name":"\(dependency)","path":"\(dependencyPath(build).path)","dependencies":[]}]}
        """
    }

    private func dependencyPath(_ build: Build) -> URL {
        build.root.appendingPathComponent("checkouts/mokume", isDirectory: true)
    }

    private func context(
        _ build: Build, declared: SwiftPM.Package?, product: String? = "demo", toolchain: String? = "swiftlang-6.4"
    ) -> BuildContext {
        BuildContext(
            configuration: nil, place: .outside(build.store, given: false), product: product, declared: declared,
            toolchain: toolchain)
    }

    /// 偽の問い。数えて、決まった答えを返す。
    nonisolated private final class Asker: @unchecked Sendable {
        private let lock = NSLock()
        private var answers: [(Int32, String)]
        private(set) var arguments: [[String]] = []

        init(_ answers: [(Int32, String)]) { self.answers = answers }

        var count: Int { lock.withLock { arguments.count } }

        var asking: AssetScope.Asking {
            { arguments, _ in
                self.lock.withLock {
                    self.arguments.append(arguments)
                    return self.answers.count > 1 ? self.answers.removeFirst() : self.answers[0]
                }
            }
        }
    }

    private func settle(
        _ build: Build, declared: SwiftPM.Package?, product: String? = "demo", asker: Asker,
        tool: String = "tool-1", toolchain: String? = "swiftlang-6.4", said: inout [String]
    ) -> AssetBundles.Allowance? {
        var lines: [String] = []
        let allowance = AssetScope.settle(
            context: context(build, declared: declared, product: product, toolchain: toolchain),
            executable: build.executable, package: build.package, say: { lines.append($0) }, asking: asker.asking,
            tool: tool)
        said += lines
        return allowance
    }

    /// **許す一覧は宣言から決まり、並びから決まらない** — 閉包の target の包み (`demo_demo`) と依存の名前の頭
    /// (`mokume_`) だけを許す。改名する前のパッケージ名 (`Aaa_demo`)・テストの target (`demo_demoTests`)・別の
    /// スケッチ (`other_other`) は許さず、外したことを 1 行名乗る。依存の木は、走らせる置き場について問う。
    @Test("許す一覧は閉包の target の包みと依存の名前の頭だけで、外した包みを 1 行名乗る")
    func theAllowanceComesFromTheDeclaration() throws {
        let build = try makeBuild(beside: [
            "Aaa_demo.bundle", "demo_demo.bundle", "demo_demoTests.bundle", "mokume_MokumeCore.bundle",
            "other_other.bundle",
        ])
        defer { try? FileManager.default.removeItem(at: build.root) }
        let declared = try #require(SwiftPM.package(inDumpOf: Self.dump))
        let asker = Asker([(0, tree(build))])
        var said: [String] = []
        let allowance = try #require(settle(build, declared: declared, asker: asker, said: &said))
        #expect(allowance == AssetBundles.Allowance(bundles: ["demo_demo.bundle"], packages: ["mokume"]))
        #expect(
            asker.arguments
                == [["package", "--scratch-path", build.store.path, "show-dependencies", "--format", "json"]])
        #expect(
            said == [
                AssetScope.askingLine,
                AssetScope.notice(["Aaa_demo.bundle", "demo_demoTests.bundle", "other_other.bundle"]),
            ].compactMap { $0 })
    }

    /// **控えが在れば問わず、名乗りも変わったときだけ** (決定 1)。共有の置き場で `run` を続けて起こした形:
    /// 1 回目だけ問い、1 行出す。2 回目は黙る。外す包みが増えたら 1 行だけ出し、問いは増えない。
    @Test("控えの鍵が合えば問い直さず、外す包みが変わったときだけ名乗る")
    func theRecordSavesTheQuestionAndTheNotice() throws {
        let build = try makeBuild(beside: ["Aaa_demo.bundle", "demo_demo.bundle", "mokume_MokumeCore.bundle"])
        defer { try? FileManager.default.removeItem(at: build.root) }
        try FileManager.default.createDirectory(at: dependencyPath(build), withIntermediateDirectories: true)
        let declared = try #require(SwiftPM.package(inDumpOf: Self.dump))
        let asker = Asker([(0, tree(build))])
        var said: [String] = []
        _ = settle(build, declared: declared, asker: asker, said: &said)
        #expect(asker.count == 1)
        #expect(said.count == 2)

        said = []
        _ = settle(build, declared: declared, asker: asker, said: &said)
        #expect(asker.count == 1, "鍵の合う控えがあるのに問い直した")
        #expect(said.isEmpty, "同じ外す包みを 2 度名乗った")

        try build.place("other_other.bundle")
        _ = settle(build, declared: declared, asker: asker, said: &said)
        #expect(asker.count == 1)
        #expect(said == [AssetScope.notice(["Aaa_demo.bundle", "other_other.bundle"])].compactMap { $0 })
        // 控えは置き場の下の、パッケージの根ごとのファイル
        let url = AssetScope.recordURL(context: context(build, declared: declared), package: build.package)
        #expect(url.path.hasPrefix(build.store.appendingPathComponent(AssetScope.recordSegment).path))
        #expect(FileManager.default.fileExists(atPath: url.path))
    }

    /// **鍵が合わなければ必ず問い直す** — 根の `Package.swift`・`Package.resolved` の現れ・依存の在処の宣言の
    /// ファイル (パスの依存の改名・`--local` の行き先)・道具・道具立てのどれが変わっても。壊れた控えも問い直す。
    @Test("宣言のファイル・道具・道具立てが変わるか、控えが壊れていれば問い直す")
    func aStaleRecordIsAskedAgain() throws {
        let build = try makeBuild(beside: ["Aaa_demo.bundle", "demo_demo.bundle"])
        defer { try? FileManager.default.removeItem(at: build.root) }
        let dependency = dependencyPath(build)
        try FileManager.default.createDirectory(at: dependency, withIntermediateDirectories: true)
        try "// mokume".write(to: dependency.appendingPathComponent("Package.swift"), atomically: true, encoding: .utf8)
        let declared = try #require(SwiftPM.package(inDumpOf: Self.dump))
        let asker = Asker([(0, tree(build))])
        var said: [String] = []
        func settled(tool: String = "tool-1", toolchain: String? = "swiftlang-6.4") {
            _ = settle(build, declared: declared, asker: asker, tool: tool, toolchain: toolchain, said: &said)
        }
        settled()
        #expect(asker.count == 1)

        let changes: [(String, () throws -> Void)] = [
            ("根の Package.swift", {
                try "// demo 2".write(
                    to: build.package.appendingPathComponent("Package.swift"), atomically: true, encoding: .utf8)
            }),
            ("根の Package.resolved", {
                try "{}".write(
                    to: build.package.appendingPathComponent("Package.resolved"), atomically: true, encoding: .utf8)
            }),
            ("根の Package@swift-6.0.swift", {
                try "// 6".write(
                    to: build.package.appendingPathComponent("Package@swift-6.0.swift"), atomically: true,
                    encoding: .utf8)
            }),
            ("依存の Package.swift", {
                try "// renamed".write(
                    to: dependency.appendingPathComponent("Package.swift"), atomically: true, encoding: .utf8)
            }),
            ("控えの中身", {
                let url = AssetScope.recordURL(context: context(build, declared: declared), package: build.package)
                try "not json".write(to: url, atomically: true, encoding: .utf8)
            }),
        ]
        var expected = 1
        for (name, change) in changes {
            try change()
            settled()
            expected += 1
            #expect(asker.count == expected, "\(name) が変わったのに問い直さなかった")
            settled()
            #expect(asker.count == expected, "\(name) の後、鍵の合う控えで問い直した")
        }
        settled(tool: "tool-2")
        #expect(asker.count == expected + 1, "道具が変わったのに問い直さなかった")
        settled(tool: "tool-2", toolchain: "swiftlang-6.3")
        #expect(asker.count == expected + 2, "道具立てが変わったのに問い直さなかった")
    }

    /// **控えはパッケージの根ごと** — 共有の置き場で別のスケッチが書いた控えを使わない。
    @Test("控えはパッケージの根ごとに分かれ、別のスケッチの控えを使わない")
    func recordsAreKeptPerPackage() throws {
        let build = try makeBuild(beside: ["Aaa_demo.bundle", "demo_demo.bundle"])
        defer { try? FileManager.default.removeItem(at: build.root) }
        let declared = try #require(SwiftPM.package(inDumpOf: Self.dump))
        let other = build.root.appendingPathComponent("other", isDirectory: true)
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        let one = AssetScope.recordURL(context: context(build, declared: declared), package: build.package)
        let two = AssetScope.recordURL(context: context(build, declared: declared), package: other)
        #expect(one != two)
        #expect(one.deletingLastPathComponent() == two.deletingLastPathComponent())

        // 根の違う控えをこのファイルに写しても読まない
        var record = AssetScope.Record(package: BuildDirectory.ownerPath(of: other))
        record.dependencyNames = ["Aaa"]
        try FileManager.default.createDirectory(at: one.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(record).write(to: one)
        #expect(AssetScope.Record.read(at: one, package: BuildDirectory.ownerPath(of: build.package)) == nil)
    }

    /// **求められなければ渡さない** (子は隣の包みを全部探す)。宣言・product が読めなければ問わず黙る。依存の木を
    /// 問えなかった回は、外せなかったことを 1 行名乗る (決定 3)。依存の木が要らない並び (いまの target とテストの
    /// target の包みだけ) なら、問わずにテストの target の包みを外す。
    @Test("宣言・product が読めなければ黙って渡さず、依存の木を問えなかった回は 1 行名乗って渡さない")
    func nothingIsPassedWhenUndecidable() throws {
        let build = try makeBuild(beside: ["Aaa_demo.bundle", "demo_demo.bundle", "demo_demoTests.bundle"])
        defer { try? FileManager.default.removeItem(at: build.root) }
        let declared = try #require(SwiftPM.package(inDumpOf: Self.dump))
        let asker = Asker([(1, "")])
        var said: [String] = []
        #expect(settle(build, declared: nil, asker: asker, said: &said) == nil)
        #expect(settle(build, declared: declared, product: nil, asker: asker, said: &said) == nil)
        #expect(asker.count == 0)
        #expect(said.isEmpty)

        #expect(settle(build, declared: declared, asker: asker, said: &said) == nil)
        #expect(asker.count == 1)
        #expect(said == [AssetScope.askingLine, AssetScope.unscopedNotice])
        // 問えなかった答えは控えない: 次の回も問う
        said = []
        #expect(settle(build, declared: declared, asker: asker, said: &said) == nil)
        #expect(asker.count == 2, "問えなかった答えを控えた")
        #expect(said == [AssetScope.askingLine, AssetScope.unscopedNotice])

        try FileManager.default.removeItem(at: build.bin.appendingPathComponent("Aaa_demo.bundle"))
        said = []
        let allowance = settle(build, declared: declared, asker: asker, said: &said)
        #expect(allowance == AssetBundles.Allowance(bundles: ["demo_demo.bundle"], packages: ["mokume"]))
        #expect(asker.count == 2)
        #expect(said == [AssetScope.notice(["demo_demoTests.bundle"])].compactMap { $0 })
    }

    /// **普通のスケッチでは依存の木を問わない** (#4038 の反証・指摘 3)。依存は mokume だけで、隣には実物と同じく
    /// `mokume_MokumeCore.bundle` が並ぶ。直接の依存の identity で説明できるので、問わずに決まり、何も名乗らない。
    @Test("依存が mokume だけのスケッチは、隣に mokume の包みが在っても依存の木を問わない")
    func anOrdinarySketchAsksNothing() throws {
        let build = try makeBuild(beside: ["demo_demo.bundle", "mokume_MokumeCore.bundle"])
        defer { try? FileManager.default.removeItem(at: build.root) }
        let declared = try #require(SwiftPM.package(inDumpOf: Self.dump))
        let asker = Asker([(0, tree(build))])
        var said: [String] = []
        #expect(settle(build, declared: declared, asker: asker, said: &said) != nil)
        #expect(asker.count == 0)
        #expect(said.isEmpty)
    }

    /// **許す一覧と `bundle` の除外は同じ規則** — 同じ宣言・同じ依存の名前・同じ並びで、`bundle` が写さない包みと、
    /// 子が探さない包みが一致する。
    @Test("許す一覧が外す包みは、bundle が写さない包みと同じ")
    func theAllowanceMatchesWhatBundleLeavesOut() throws {
        let build = try makeBuild(beside: [
            "Aaa_demo.bundle", "demo_demo.bundle", "demo_demoTests.bundle", "mokume_MokumeCore.bundle",
            "Extra_ExtraLib.bundle", "other_other.bundle",
        ])
        defer { try? FileManager.default.removeItem(at: build.root) }
        let declared = try #require(SwiftPM.package(inDumpOf: Self.dump))
        let answer = """
            {"identity":"demo","name":"demo","dependencies":[
              {"identity":"mokume","name":"mokume","dependencies":[]},
              {"identity":"extra-pkg","name":"Extra","dependencies":[]}]}
            """
        let scope = BundleCommand.resourceScope(
            of: declared, product: "demo", executable: build.executable, package: build.package,
            place: .outside(build.store, given: false), asking: { _, _ in (0, answer) })
        var said: [String] = []
        let allowance = try #require(
            settle(build, declared: declared, asker: Asker([(0, answer)]), said: &said))
        let built = try FileManager.default.contentsOfDirectory(atPath: build.bin.path).filter {
            $0.hasSuffix(".bundle")
        }
        #expect(Set(built.filter { !allowance.allows($0) }) == scope.excluded)
        #expect(scope.excluded == ["Aaa_demo.bundle", "demo_demoTests.bundle", "other_other.bundle"])
    }

    /// **問いは待つ側が期限を持つ** — 全体で 1 つの期限で、答えない子は殺して「求められない」(0 以外) にする。
    /// 子が終わっても管の書き口を継いだ孫が残れば、同じ期限で読むのをやめる。答えた子の出力は掴む。止めると決めた
    /// 後 (見張りが終わるとき) は起こさない。
    @Test("依存の木の問いは全体の期限を越えたら子を殺し、止めた後は起こさない")
    func theQuestionHasADeadline() throws {
        let silent = Process()
        silent.executableURL = URL(fileURLWithPath: "/bin/sleep")
        silent.arguments = ["600"]
        let late = BundleCommand.ask(silent, timeout: 0.2)
        #expect(late.status != 0)
        #expect(!silent.isRunning, "期限を越えた子が残っている")

        // 子はすぐ終わるが、管を継いだ孫が残る
        let orphaning = Process()
        orphaning.executableURL = URL(fileURLWithPath: "/bin/sh")
        orphaning.arguments = ["-c", "/bin/sleep 600 & echo started"]
        let held = BundleCommand.ask(orphaning, timeout: 0.5)
        #expect(held.status != 0, "孫が管を握ったままなのに答えたことにした")

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

    /// **`run`・`render`・`replay` が実行ファイルを受け取る口は、探してよい包みも決める** (2 回目の反証・指摘 2)。
    /// 建てる手だけを差し替えた本物の口 (``RunCommand/prepare(in:context:say:asking:building:)``) が、許す一覧を返し、
    /// 名乗る。
    @Test("実行ファイルを受け取る口は、探してよい包みを決めて名乗る")
    func preparingDecidesTheAllowance() throws {
        let build = try makeBuild(beside: ["Aaa_demo.bundle", "demo_demo.bundle"])
        defer { try? FileManager.default.removeItem(at: build.root) }
        let declared = try #require(SwiftPM.package(inDumpOf: Self.dump))
        var said: [String] = []
        let prepared = try RunCommand.prepare(
            in: build.package, context: context(build, declared: declared), say: { said.append($0) },
            asking: Asker([(0, tree(build))]).asking,
            building: { _, _ throws(CommandFailure) in build.executable })
        #expect(prepared.executable == build.executable)
        #expect(prepared.assetBundles == AssetBundles.Allowance(bundles: ["demo_demo.bundle"], packages: ["mokume"]))
        #expect(said.contains(AssetScope.notice(["Aaa_demo.bundle"]) ?? ""))
    }

    /// **`render` の子の環境に許す一覧が載る** (2 回目の反証・指摘 2)。子を起こす口に、環境を書き出す実行ファイルを渡す。
    @Test("render の子の環境に、探してよい包みが載る")
    func theRenderChildGetsTheAllowance() throws {
        let build = try makeBuild(beside: [])
        defer { try? FileManager.default.removeItem(at: build.root) }
        let seen = build.root.appendingPathComponent("seen")
        try """
            #!/bin/sh
            printf '%s' "$\(StartupReads.assetBundles.key)" > '\(seen.path)'
            exit 3
            """.write(to: build.executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: build.executable.path)
        let allowance = try #require(AssetBundles.Allowance(bundles: ["demo_demo.bundle"], packages: ["mokume"]))
        let request = try #require(
            RenderRequest(frameRate: 30, frameCount: 1, destination: build.root.appendingPathComponent("out.mov").path))
        #expect(throws: CommandFailure.self) {
            try RenderCommand.launch(
                build.executable, in: build.package, request: request, assetBundles: allowance)
        }
        #expect(try String(contentsOf: seen, encoding: .utf8) == allowance.value)
    }

    /// **見張りは、作り直しの後に子へ渡す値を更新する** (2 回目の反証・指摘 2)。作り直す手だけを差し替えた本物の
    /// 口 (``WatchSession/Hooks/live(resolver:running:stamps:keepTime:recording:progress:assetBundles:rebuilding:)``)
    /// で、作り直し → 起こす口と通す。建たなかった回は決め直さない。
    @Test("見張りは作り直しの後に、探してよい包みを子の環境へ渡す")
    func theWatcherPassesTheAllowanceAfterARebuild() async throws {
        let build = try makeBuild(beside: ["Aaa_demo.bundle", "demo_demo.bundle"])
        defer { try? FileManager.default.removeItem(at: build.root) }
        let seen = build.root.appendingPathComponent("seen")
        try """
            #!/bin/sh
            printf '%s' "$\(StartupReads.assetBundles.key)" > '\(seen.path)'
            """.write(to: build.executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: build.executable.path)
        let declared = try #require(SwiftPM.package(inDumpOf: Self.dump))
        let context = context(build, declared: declared)
        let bin = build.bin
        let resolver = BuildResolver(directory: build.package) { _ in
            BuildResolution(context: context, binPath: bin)
        }
        let status = Mutex<Int32>(1)
        let executable = build.executable
        let hooks = WatchSession.Hooks.live(
            resolver: resolver, running: RunningBuild(),
            assetBundles: AssetScope.Carried(asking: Asker([(0, tree(build))]).asking),
            rebuilding: { _, _ in
                .success(
                    RunCommand.Rebuilt(
                        status: status.withLock { $0 }, output: "", executable: executable, binPath: bin,
                        product: "demo"))
            })

        func launched() throws -> String {
            let child = try hooks.launch(build.executable, build.package, nil, nil)
            child.waitUntilExit()
            return try String(contentsOf: seen, encoding: .utf8)
        }
        #expect(try launched() == "", "建つ前に許す一覧を渡した")
        _ = try await hooks.rebuild(build.package)
        #expect(try launched() == "", "建たなかった回に決め直した")
        status.withLock { $0 = 0 }
        _ = try await hooks.rebuild(build.package)
        #expect(
            try launched() == AssetBundles.Allowance(bundles: ["demo_demo.bundle"], packages: ["mokume"])?.value,
            "作り直しの後に許す一覧を子へ渡していない")
    }

    /// 許す一覧は起こす道具が自分の宣言から決める値なので、渡さなければ親の環境に在っても落とす。
    @Test("探してよい包みは渡したときだけ子へ載り、親の環境に在っても落とす")
    func theAllowanceGoesOnlyWhenGiven() throws {
        let key = StartupReads.assetBundles.key
        #expect(RunCommand.childEnvironment([key: "stale_stale.bundle"])[key] == nil, "親の値を継いだ")
        let allowance = try #require(AssetBundles.Allowance(bundles: ["b_b.bundle"], packages: ["a"]))
        #expect(RunCommand.childEnvironment([:], assetBundles: allowance)[key] == "b_b.bundle/a_")
    }
}
