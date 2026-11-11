// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation
import MokumeTestSupport
import Testing

@testable import MokumeCLI

/// 資材の置き場が宣言されているかを見る検査。
///
/// **宣言の抜けはビルドを通ってしまう。** 通った後では「組み上がったのに絵が出ない」
/// 形になり、描画側を疑って当たりが外れ続ける。走らせる前にここで止める。
///
/// **宣言は道具立て (`dump-package`) が解いたものを読む** ([#3984](https://github.com/mokume-metal/mokume/issues/3984))。
/// 検査は本物の `Package.swift` を道具立てに読ませる — 文字列で照らすと、道具立てが受け付ける
/// `.copy("./assets")` を拒み、別の target やコメントの宣言で通してしまう。
@Suite("資材の宣言")
struct ResourceDeclarationTests {
    /// `demo` という実行 target を 1 つ持つ宣言。
    ///
    /// - Parameters:
    ///   - resources: `demo` の `resources:` の中身。`nil` なら書かない。
    ///   - path: `demo` の `path:`。`nil` なら書かない。
    ///   - before: 宣言の前に置く行 (コメントなど)。
    ///   - otherTargets: `targets:` に足す target。
    static func manifest(
        resources: String? = nil, path: String? = nil, before: String = "",
        otherTargets: String = ""
    ) -> String {
        let placed = path.map { ", path: \"\($0)\"" } ?? ""
        let declared = resources.map { ", resources: [\($0)]" } ?? ""
        return """
            // swift-tools-version: 6.0
            import PackageDescription

            \(before)
            let package = Package(
                name: "demo",
                targets: [
                    .executableTarget(name: "demo"\(placed)\(declared)),
                    \(otherTargets)
                ]
            )
            """
    }

    private func makeSketch(
        manifest: String, assets: [String] = [], hidden: [String] = []
    ) throws -> URL {
        let root = TestScratch.path("mokume-resources", isDirectory: true)
        let place = root.appendingPathComponent("Sources/demo", isDirectory: true)
        let directory = place.appendingPathComponent("assets", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try "print(1)".write(
            to: place.appendingPathComponent("main.swift"), atomically: true, encoding: .utf8)
        try manifest.write(
            to: root.appendingPathComponent("Package.swift"), atomically: true, encoding: .utf8)
        for name in assets + hidden {
            try "x".write(
                to: directory.appendingPathComponent(name), atomically: true, encoding: .utf8)
        }
        return root
    }

    /// コマンドと同じく、道具立てに読ませた宣言で見る。
    private func check(_ root: URL) throws {
        try ResourceDeclaration.check(in: root, declared: try RunCommand.dumpPackage(in: root))
    }

    private let stops = CommandFailure.resourcesNotDeclared(directory: "Sources/demo/assets")

    @Test("宣言があれば通る")
    func aDeclaredDirectoryPasses() throws {
        let root = try makeSketch(
            manifest: Self.manifest(resources: #".copy("assets")"#), assets: ["grain.png"])
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(throws: Never.self) { try check(root) }
    }

    /// **道具立てが受け付ける綴りは、どれも宣言である** (#3984)。`./assets` も `assets/` も、
    /// 道具立ては `assets` を束へ写す。
    @Test(
        "道具立てが同じ置き場と読む綴りなら、どれでも通る",
        arguments: [#".copy("./assets")"#, #".copy("assets/")"#, #".process("./assets")"#])
    func spellingsTheToolchainAcceptsPass(declaration: String) throws {
        let root = try makeSketch(
            manifest: Self.manifest(resources: declaration), assets: ["grain.txt"])
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(throws: Never.self) { try check(root) }
    }

    /// **宣言はファイルとして比べる** (#3984 の反証)。大文字と小文字を区別しないボリューム
    /// (既定の APFS) では、`Assets` と `assets` は同じディレクトリで、道具立ても同じものを写す。
    @Test("大文字と小文字だけが違う宣言は、区別しないボリュームでは同じ置き場")
    func aCaseOnlyDifferenceIsTheSamePlaceOnACaseInsensitiveVolume() throws {
        let root = try makeSketch(
            manifest: Self.manifest(resources: #".copy("Assets")"#), assets: ["grain.png"])
        defer { try? FileManager.default.removeItem(at: root) }
        let sensitive = try root.resourceValues(forKeys: [.volumeSupportsCaseSensitiveNamesKey])
            .volumeSupportsCaseSensitiveNames
        try #require(sensitive == false, "検査の置き場が大文字と小文字を区別するボリュームにある")
        #expect(throws: Never.self) { try check(root) }
    }

    /// 置き場の中の 1 ファイルだけの宣言では、他の資材は束に入らない (#3984 の反証)。
    @Test("置き場の中のファイルだけを挙げた宣言では止まる")
    func declaringOneFileInsideDoesNotCount() throws {
        let root = try makeSketch(
            manifest: Self.manifest(resources: #".copy("assets/grain.png")"#),
            assets: ["grain.png", "dot.png"])
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(throws: stops) { try check(root) }
    }

    /// target の置き場を `path:` で動かしていても、その置き場の宣言を見る — 宣言していれば
    /// 通り、していなければ止まる (置き場を持つ target を名前からだけ探すと、どちらも素通りする)。
    @Test("path: で置き場を指した target の宣言も読む")
    func aTargetPlacedByPathIsMatched() throws {
        let manifest = { (resources: String?) in
            Self.manifest(resources: resources, path: "Sources/demo")
                .replacingOccurrences(of: #"name: "demo", path"#, with: #"name: "App", path"#)
        }
        let declared = try makeSketch(manifest: manifest(#".copy("assets")"#), assets: ["grain.png"])
        defer { try? FileManager.default.removeItem(at: declared) }
        #expect(throws: Never.self) { try check(declared) }

        let undeclared = try makeSketch(manifest: manifest(nil), assets: ["grain.png"])
        defer { try? FileManager.default.removeItem(at: undeclared) }
        #expect(throws: stops) { try check(undeclared) }
    }

    /// **置き場を含む target を見る** (#3984 の反証)。`path: "Sources"` のように親を置き場にした
    /// target は `Sources/demo/assets` を含む。宣言のパスはその target の置き場から解く。
    @Test("親のディレクトリを置き場にした target も、置き場を含むものとして見る")
    func aTargetPlacedAtAParentContainsThePlace() throws {
        let undeclared = try makeSketch(
            manifest: Self.manifest(path: "Sources"), assets: ["grain.png"])
        defer { try? FileManager.default.removeItem(at: undeclared) }
        #expect(throws: stops) { try check(undeclared) }

        for covering in [#".copy("demo/assets")"#, #".copy("demo")"#] {
            let declared = try makeSketch(
                manifest: Self.manifest(resources: covering, path: "Sources"), assets: ["grain.png"])
            defer { try? FileManager.default.removeItem(at: declared) }
            #expect(throws: Never.self, "\(covering)") { try check(declared) }
        }
    }

    /// **置き場そのものがシンボリックリンクなら見ない** (前と同じ)。中身を数えるときにリンクを
    /// 辿らないので、宣言の有無によらず止めない。見張りも置き場の中のリンクを範囲の外としている
    /// (#2519)。リンクの置き場を道具立てがどう写すかを確かめるまで、見る範囲を広げない。
    @Test("リンクの置き場は、宣言の有無によらず止めない")
    func aLinkedPlaceIsNotJudged() throws {
        for resources in [#".copy("assets")"#, nil] {
            let root = try makeSketch(manifest: Self.manifest(resources: resources))
            defer { try? FileManager.default.removeItem(at: root) }
            let outside = try TestScratch.directory("mokume-resources-outside")
            defer { try? FileManager.default.removeItem(at: outside) }
            try "x".write(
                to: outside.appendingPathComponent("grain.png"), atomically: true, encoding: .utf8)
            let place = root.appendingPathComponent("Sources/demo/assets")
            try FileManager.default.removeItem(at: place)
            try FileManager.default.createSymbolicLink(at: place, withDestinationURL: outside)
            #expect(throws: Never.self, "\(String(describing: resources))") { try check(root) }
        }
    }

    /// **既定の置き場は target の種類で決める** (#3984 の反証)。テストの target は `Tests` が在れば
    /// その下に置かれ、`Sources/<名前>` ではない。種類を見ずに `Sources/<名前>` を当てると、
    /// テストの target の宣言で `Sources` の置き場を見ることになる。
    @Test("テストの target は、Tests が在れば Sources の置き場を含まない")
    func aTestTargetDoesNotOwnASourcesPlace() throws {
        let manifest = """
            // swift-tools-version: 6.0
            import PackageDescription

            let package = Package(
                name: "demo",
                targets: [
                    .executableTarget(name: "app"),
                    .testTarget(name: "demo"),
                ]
            )
            """
        let root = try makeSketch(manifest: manifest, assets: ["grain.png"])
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("Tests/demo"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("Sources/app"), withIntermediateDirectories: true)
        let declared = try #require(try RunCommand.dumpPackage(in: root))
        let owner = declared.target(
            containing: root.appendingPathComponent("Sources/demo/assets"), in: root)
        #expect(owner == nil, "テストの target が Sources の置き場を含むと読んだ: \(String(describing: owner?.target.name))")
        #expect(throws: Never.self) { try check(root) }
    }

    @Test("中身があるのに宣言が無ければ止まる")
    func anUndeclaredDirectoryStops() throws {
        let root = try makeSketch(manifest: Self.manifest(), assets: ["grain.png"])
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(throws: stops) { try check(root) }
    }

    /// **宣言は target ごとに読む** (#3984)。別の target が `assets` を宣言していても、置き場を
    /// 持つ target が宣言していなければ、その資材は束に入らない。
    @Test("別の target の宣言では通さない")
    func anotherTargetsDeclarationDoesNotCount() throws {
        let root = try makeSketch(
            manifest: Self.manifest(
                otherTargets: #".target(name: "Other", path: "Elsewhere/Other", resources: [.copy("assets")]),"#),
            assets: ["grain.png"])
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(throws: stops) { try check(root) }
    }

    /// コメントに書いた宣言は宣言ではない (#3984)。
    @Test("コメントの中の宣言では通さない")
    func aCommentedDeclarationDoesNotCount() throws {
        let root = try makeSketch(
            manifest: Self.manifest(before: #"// resources: [.copy("assets")],"#),
            assets: ["grain.png"])
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(throws: stops) { try check(root) }
    }

    @Test("止めるときの説明が、足す 1 行を示す")
    func theMessageShowsTheLineToAdd() {
        let text = CommandFailure.resourcesNotDeclared(directory: "Sources/demo/assets").message
        #expect(text.contains("Sources/demo/assets"))
        #expect(text.contains(#"resources: [.copy("assets")]"#))
    }

    @Test("空の置き場は止めない")
    func anEmptyDirectoryIsFine() throws {
        let root = try makeSketch(manifest: Self.manifest())
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(throws: Never.self) { try check(root) }
    }

    @Test("目印だけの置き場は止めない")
    func aDirectoryWithOnlyHiddenFilesIsFine() throws {
        let root = try makeSketch(manifest: Self.manifest(), hidden: [".gitkeep"])
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(throws: Never.self) { try check(root) }
    }

    @Test("宣言があっても、別の置き場を挙げているだけなら止める")
    func declaringSomethingElseDoesNotCount() throws {
        let root = try makeSketch(
            manifest: Self.manifest(resources: #".copy("shaders")"#), assets: ["grain.png"])
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(throws: stops) { try check(root) }
    }

    /// **宣言が読めない回は、ここでは止めない。** 道具立てが読めない `Package.swift` は後の段が
    /// 道具立ての理由を添えて止める (`bundle`・`run` の検査が後の段を見る)。
    @Test("宣言が読めない回は、資材の検査は止めない")
    func anUnreadableManifestIsLeftToLaterSteps() throws {
        let root = try makeSketch(manifest: "// swift-tools-version: 6.0", assets: ["grain.png"])
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(try RunCommand.dumpPackage(in: root) == nil)
        #expect(throws: Never.self) { try check(root) }
    }

    @Test("道具で作ったスケッチは、置き場と宣言の両方を持っている")
    func theGeneratedSketchDeclaresItsAssets() throws {
        let root = TestScratch.path("mokume-resources-new", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let files = try NewCommand.files(
            for: NewCommand.Options(name: "demo", path: ".", local: nil))
        #expect(files.contains { $0.0.hasPrefix("Sources/demo/assets/") })
        for (relative, contents) in files {
            let url = root.appendingPathComponent(relative)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try contents.write(to: url, atomically: true, encoding: .utf8)
        }
        let declared = try #require(try RunCommand.dumpPackage(in: root))
        #expect(ResourceDeclaration.undeclared(in: root, declared: declared).isEmpty)
    }

    // MARK: - コマンドが見る位置 (#3984 の反証)

    /// 導く段だけを本物で通す (解決の `swift` は起こさない)。
    private func context(
        in root: URL, afterReading: @escaping (SwiftPM.Package?) throws(CommandFailure) -> Void
    ) throws(CommandFailure) -> BuildContext {
        let store = TestScratch.path("mokume-resources-store", isDirectory: true)
        return try RunCommand.context(
            in: root, invocation: Invocation(place: root.path),
            environment: [BuildDirectory.environmentKey: store.path],
            resolver: { _, _ in }, afterReading: afterReading)
    }

    /// `run`・`render` は、宣言を読む段 (`context`) で読んだ宣言を見る。宣言が読めない回は止めず、
    /// 「宣言が読めない」置き場で後の段 (ビルド) へ進む — 止めるのはビルドで、理由は道具立てが出す。
    @Test("run と render は、宣言を読んだ段で見て、読めない回は後の段へ渡す")
    func runAndRenderCheckWhereTheyReadTheDeclaration() throws {
        let undeclared = try makeSketch(manifest: Self.manifest(), assets: ["grain.png"])
        defer { try? FileManager.default.removeItem(at: undeclared) }
        #expect(throws: stops) {
            try context(in: undeclared, afterReading: ResourceDeclaration.checking(in: undeclared))
        }

        let broken = try makeSketch(manifest: "// swift-tools-version: 6.0", assets: ["grain.png"])
        defer { try? FileManager.default.removeItem(at: broken) }
        let carried = try context(in: broken, afterReading: ResourceDeclaration.checking(in: broken))
        #expect(carried.place == .inPackage(.unreadableManifest))
    }

    /// **見張りは、宣言が読めた最初の回に 1 度だけ見る** (#682・#3984 の反証)。始めに宣言が
    /// 読めなかったら、作り直しで初めて読めた回に見る — 通るまで見て、通った後は見ない。
    @Test("壊れた宣言で始めた見張りは、宣言が初めて読めた導き直しで資材を見る")
    func aWatchStartedOnABrokenManifestChecksOnceTheDeclarationReads() throws {
        let root = try makeSketch(manifest: "// swift-tools-version: 6.0", assets: ["grain.png"])
        defer { try? FileManager.default.removeItem(at: root) }
        let once = ResourceDeclaration.Once(in: root)
        let resolver = BuildResolver(directory: root) { directory throws(CommandFailure) in
            BuildResolution(
                context: try context(in: directory, afterReading: once.check), binPath: directory)
        }
        func write(_ manifest: String) throws {
            try manifest.write(
                to: root.appendingPathComponent("Package.swift"), atomically: true, encoding: .utf8)
        }

        // 始め: 読めないので見ない (見張りは始まる)
        #expect(throws: Never.self) { try resolver.current() }
        // 宣言が読めるようになった作り直し: 抜けがあれば止まる。直すまで毎回止まる
        try write(Self.manifest())
        #expect(throws: stops) { try resolver.current() }
        #expect(throws: stops) { try resolver.current() }
        // 宣言を足せば通る
        try write(Self.manifest(resources: #".copy("assets")"#))
        #expect(throws: Never.self) { try resolver.current() }
        // 通った後は見ない (作り直しのたびには見ない・#682)
        try write(Self.manifest(before: "// 宣言を外した"))
        #expect(throws: Never.self) { try resolver.current() }
    }

    /// 始めに宣言が読めた見張りは、そこで 1 度だけ見る (#682)。
    @Test("始めに宣言が読めた見張りは、そこで見て、作り直しでは見ない")
    func aWatchStartedOnAReadableManifestChecksOnlyAtTheStart() throws {
        let root = try makeSketch(
            manifest: Self.manifest(resources: #".copy("assets")"#), assets: ["grain.png"])
        defer { try? FileManager.default.removeItem(at: root) }
        let once = ResourceDeclaration.Once(in: root)
        let resolver = BuildResolver(directory: root) { directory throws(CommandFailure) in
            BuildResolution(
                context: try context(in: directory, afterReading: once.check), binPath: directory)
        }
        #expect(throws: Never.self) { try resolver.current() }
        try Self.manifest().write(
            to: root.appendingPathComponent("Package.swift"), atomically: true, encoding: .utf8)
        #expect(throws: Never.self) { try resolver.current() }
    }
}
