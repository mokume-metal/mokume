// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation
import Testing

@testable import MokumeCLI

@Suite("スケッチ一式を作る")
struct NewCommandTests {
    @Test("名前と場所を読む")
    func readsTheNameAndWhereToPutIt() throws {
        #expect(try NewCommand.parse(["sketch"]) == .init(name: "sketch"))
        #expect(
            try NewCommand.parse(["sketch", "--path", "/tmp"])
                == .init(name: "sketch", path: "/tmp"))
        #expect(
            try NewCommand.parse(["sketch", "--local", "../mokume"])
                == .init(name: "sketch", path: ".", local: "../mokume"))
    }

    @Test("名前が無ければ、何をすればよいか言って止まる")
    func refusesWithoutAName() {
        #expect(throws: CommandFailure.nameMissing) { try NewCommand.parse([]) }
    }

    @Test("使えない名前を弾く")
    func rejectsNamesThatCannotBeUsed() {
        #expect(NewCommand.isValid(name: "my-sketch"))
        #expect(NewCommand.isValid(name: "sketch_2"))
        // 先頭が英字でないものはパッケージ名にも型の名前にもできない
        #expect(!NewCommand.isValid(name: "2sketch"))
        #expect(!NewCommand.isValid(name: "-sketch"))
        #expect(!NewCommand.isValid(name: "my sketch"))
        #expect(!NewCommand.isValid(name: ""))
    }

    @Test("名前から型の名前を作る")
    func buildsATypeNameFromTheName() {
        #expect(NewCommand.typeName(for: "my-sketch") == "MySketch")
        #expect(NewCommand.typeName(for: "sketch") == "Sketch")
        #expect(NewCommand.typeName(for: "a_b-c") == "ABC")
    }

    @Test("パスで指した依存は、末尾のディレクトリ名で参照する")
    func namesAPathDependencyByItsDirectory() {
        // リポジトリの名前ではなくパスの末尾が identity になる。作業用の複製を
        // 指したときに食い違うので、パスから導く
        let sketch = URL(fileURLWithPath: "/w/plain/foo", isDirectory: true)
        #expect(NewCommand.packageIdentity(local: nil, sketch: sketch) == "mokume")
        #expect(NewCommand.packageIdentity(local: "/a/b/mokume", sketch: sketch) == "mokume")
        #expect(NewCommand.packageIdentity(local: "/a/b/work-copy", sketch: sketch) == "work-copy")
    }

    /// **`.package(path:)` と同じ場所を、同じ基準で指す** (#2322)。`--local` は
    /// `.package(path:)` へそのまま入り SwiftPM が**作られるスケッチの場所から**解くのに、
    /// 名前だけを走らせた場所から解いていた。末尾が `..`・`.` だと 2 つが別の場所を指し、
    /// `swift package resolve` が `unknown package` で止まる。
    @Test(
        "パスで指した依存の名前は、作られるスケッチの場所から解く",
        arguments: [
            // (走らせた場所, --path, --local, identity)
            ("/w/Mokume", ".", "..", "mokume"),  // チェックアウトの中で `new foo --local ..`
            ("/w/Mokume", "sub", "../..", "mokume"),  // --path と組む
            ("/w/plain", ".", ".", "foo"),  // スケッチ自身 (末尾が `.`)
            ("/w/plain", ".", "../../lib/Mokume-Copy", "mokume-copy"),
            ("/w/plain", "/elsewhere", "../mokume", "mokume"),  // 絶対の --path
            ("/w/plain", ".", "/a/b/work-copy", "work-copy"),  // 絶対の --local
        ])
    func namesAPathDependencyFromTheSketch(
        typedFrom: String, path: String, local: String, identity: String
    ) throws {
        let options = NewCommand.Options(name: "foo", path: path, local: local)
        let base = URL(fileURLWithPath: typedFrom, isDirectory: true)
        let sketch = options.root(from: base)
        #expect(NewCommand.packageIdentity(local: local, sketch: sketch) == identity)
        // 作られる Package.swift でも、`.package(path:)` と名前が揃っている
        let manifest = try #require(
            try NewCommand.files(for: options, base: base).first { $0.0 == "Package.swift" }?.1)
        #expect(manifest.contains(".package(path: \"\(local)\")"))
        #expect(manifest.contains("package: \"\(identity)\""))
    }

    /// SwiftPM は `~/` で始まる path の依存だけを home から解く。名前も同じ規則で解く。
    @Test("~/ で始まる依存の名前は、home から解く")
    func namesAHomeRelativeDependencyFromHome() {
        let sketch = URL(fileURLWithPath: "/w/plain/foo", isDirectory: true)
        #expect(NewCommand.packageIdentity(local: "~/src/Mokume", sketch: sketch) == "mokume")
        // 末尾が `.` だと、どこから解いたかで名前が変わる (スケッチからなら `~`)
        let home = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
        #expect(
            NewCommand.packageIdentity(local: "~/.", sketch: sketch)
                == home.standardizedFileURL.lastPathComponent.lowercased())
    }

    /// **場所を Swift の文字列として逃がす** (#2322)。`"` を含む場所を生のまま貼ると
    /// `Package.swift` が読めず、`Created` と言って壊れたものを残していた。逃がすのは
    /// `--local` から来る 2 つの差し込み口 (`DEPENDENCY`・`PACKAGE`) — 名前は
    /// ``NewCommand/isValid(name:)`` が `"` を通さない。
    @Test("場所に \" や \\ があっても、Package.swift の文字列は閉じたまま")
    func aLocalWithQuotesStaysInsideTheString() throws {
        let local = #"/tmp/q"dir\x/we"ird"#
        let manifest = try #require(
            try NewCommand.files(for: .init(name: "quoted", local: local))
                .first { $0.0 == "Package.swift" }?.1)
        #expect(manifest.contains(#".package(path: "/tmp/q\"dir\\x/we\"ird")"#))
        #expect(manifest.contains(#"package: "we\"ird""#))
        #expect(!manifest.contains(local), "場所が逃がされずに貼られている")
    }

    /// 上の逃がし方で作った `Package.swift` を、SwiftPM 自身に読ませる (完了条件 3 の
    /// `swift package dump-package` が通ること)。依存の中身は読まないので、指す先は空でよい。
    @Test("場所に \" や \\ があっても、作った Package.swift を SwiftPM が読める")
    func aLocalWithQuotesMakesAReadableManifest() throws {
        let workspace = FileManager.default.temporaryDirectory
            .appendingPathComponent("mokume-new-quoted-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workspace) }
        let options = NewCommand.Options(
            name: "quoted", path: workspace.path,
            local: workspace.appendingPathComponent(#"q"dir\x"#).path)
        let root = options.root()
        for (path, contents) in try NewCommand.files(for: options) {
            let url = root.appendingPathComponent(path)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try contents.write(to: url, atomically: true, encoding: .utf8)
        }
        let declared = try RunCommand.dumpPackage(in: root)
        #expect(declared?.executableProductName == "quoted", "SwiftPM が Package.swift を読めない")
    }

    /// 基準が口ごとに違うのは `--local` だけなので、help がそれを言う (#2323 の完了条件 4)。
    @Test("help は、相対の --local が作られるスケッチから解かれることを言う")
    func theHelpSaysWhereLocalStartsFrom() throws {
        let entry = try #require(Command.Verb.new.usageEntry)
        let text = entry.description.replacingOccurrences(of: "\n", with: " ")
        #expect(text.contains("a relative one starts from the new sketch"))
    }

    // MARK: - 作った後の案内 (#2320)

    /// 案内に出る `cd` の行を、走らせた場所で `/bin/sh` に打たせ、入った先を返す。
    private func pasteCD(from guidance: String, at typedFrom: URL) throws -> String {
        let line = try #require(
            guidance.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
                .first { $0.hasPrefix("cd ") })
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "\(line) && pwd"]
        process.currentDirectoryURL = typedFrom
        let result = try RunCommand.capture(process, capturing: true, errors: .inherit)
        #expect(result.status == 0, "案内の cd が通らない: \(line)")
        return result.output.trimmingCharacters(in: .newlines)
    }

    /// **案内は、走らせた場所からそのまま貼って動く。** `--path` を無視して `cd <名前>` と
    /// 言っていたので、`--path` を付けると走らせた場所からは入れず、空白を含む場所なら
    /// 引用も要った。
    @Test(
        "作った後の案内は、走らせた場所からそのまま貼れば作った場所へ入る",
        arguments: [".", "dir with space", "it's here", #"a"b\c $HOME"#])
    func theGuidanceCanBePastedWhereItWasTyped(path: String) throws {
        let typedFrom = FileManager.default.temporaryDirectory
            .appendingPathComponent("mokume-new-guide-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: typedFrom) }
        let root = NewCommand.Options(name: "hint", path: path).root(from: typedFrom)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let guidance = NewCommand.guidance(for: root)
        #expect(guidance.contains("Created \(root.path)"))
        // 場所は引用され、--path を含む
        #expect(guidance.contains("  cd \(GivenPath.shellWord(root))\n"))
        #expect(try pasteCD(from: guidance, at: typedFrom) == root.path)
    }

    /// 文面の固定。`--path` と空白を含む場所で、引用した絶対パスを名指しする。
    @Test("作った後の案内は、作った場所を引用した絶対パスで名指しする")
    func theGuidanceNamesTheQuotedPlace() {
        let root = NewCommand.Options(name: "hint", path: "dir with space")
            .root(from: URL(fileURLWithPath: "/work", isDirectory: true))
        #expect(
            NewCommand.guidance(for: root) == """
                Created /work/dir with space/hint

                  cd '/work/dir with space/hint'
                  \(Command.name) run
                """)
    }

    @Test("作られるのは 7 つ — 定義・スケッチ・無視の指定・資材の置き場・案内 2 枚・窓口の登録")
    func writesThePackageTheSketchTheIgnoreFileTheAssetsDirectoryAndTheGuides() throws {
        let files = try NewCommand.files(for: .init(name: "my-sketch"))
        #expect(
            files.map(\.0) == [
                "Package.swift", "Sources/my-sketch/MySketch.swift", ".gitignore",
                "Sources/my-sketch/assets/README.md", "AGENTS.md", "CLAUDE.md", ".mcp.json",
            ])
    }

    /// **案内に書くだけでは届かない。** 窓口は呼ぶ側が起動する前に登録されているものしか
    /// 使えないので、作った後で打っても、そのとき動いているエージェントからは呼べない
    /// ([#683](https://github.com/mokume-metal/mokume/issues/683))。
    @Test("窓口の登録が置かれ、道具の名前と mcp の呼び方だけを持つ")
    func writesTheWindowRegistration() throws {
        let files = try NewCommand.files(for: .init(name: "my-sketch"))
        let text = try #require(files.first { $0.0 == ".mcp.json" }?.1)
        let object = try #require(
            JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
        let servers = try #require(object["mcpServers"] as? [String: Any])
        let entry = try #require(servers["mokume"] as? [String: Any])
        #expect(entry["command"] as? String == "mokume")
        #expect(entry["args"] as? [String] == ["mcp", "."])
    }

    /// **案内と実際の手順を食い違わせない。** 登録が置かれた後は、人が窓口を打つ必要は無い。
    @Test("案内は、人が打つものとして窓口を挙げない")
    func theGuideDoesNotAskThePersonToStartTheWindow() throws {
        let text = try guide("AGENTS.md")
        #expect(!text.contains("mokume mcp ."))
        #expect(text.contains(".mcp.json"))
    }

    /// 案内の中身。
    ///
    /// **見るのは「書かれているか」までである。** 読んだエージェントが実際にそう動くかは
    /// モデルの判断で、ここでは担保できない (#632)。
    private func guide(_ name: String) throws -> String {
        let files = try NewCommand.files(for: .init(name: "my-sketch"))
        return try #require(files.first { $0.0 == name }?.1)
    }

    @Test("案内は、対象の既定がそのスケッチであることを書いている")
    func theGuideNamesTheDefaultTarget() throws {
        let text = try guide("AGENTS.md")
        #expect(text.contains("Sources/my-sketch/"))
        #expect(text.contains("対象"))
    }

    @Test("案内は、観測してから絵の話をするよう書いている")
    func theGuideRequiresObservingFirst() throws {
        let text = try guide("AGENTS.md")
        for expected in ["observe", "count", "build_status", "doctor"] {
            #expect(text.contains(expected), "案内に \(expected) の使い方が無い")
        }
    }

    @Test("案内は本体を正典として指し、規約を写さない")
    func theGuidePointsAtTheCanon() throws {
        let text = try guide("AGENTS.md")
        #expect(text.contains("github.com/mokume-metal/mokume/blob/main/AGENTS.md"))
    }

    @Test("案内は道具の使い方に絞り、作品の側の運用を決めない")
    func theGuideDoesNotRuleOnTheWorkItself() throws {
        let text = try guide("AGENTS.md")
        // ADR-0022 決定 5 が「決めない」と名指ししたもの。ここに現れたら線を越えている
        for forbidden in ["Conventional Commits", "ブランチ", "squash", "ライセンス", "締切"] {
            #expect(!text.contains(forbidden), "作品の側の運用 (\(forbidden)) に踏み込んでいる")
        }
    }

    @Test("Claude Code 向けの 1 枚は、案内を指すだけで写しを持たない")
    func theClaudeEntryOnlyPointsAtTheGuide() throws {
        let text = try guide("CLAUDE.md")
        let lines = text.split(separator: "\n", omittingEmptySubsequences: true)
        #expect(lines.count == 1, "参照 1 行のはずが \(lines.count) 行ある")
        #expect(text.contains("@AGENTS.md"))
    }

    @Test("スケッチの入口は、資材を足しても壊れない形で書かれている")
    func theEntryPointSurvivesAddingResources() throws {
        let files = try NewCommand.files(for: .init(name: "my-sketch"))
        let sketch = try #require(files.first { $0.0.hasSuffix("MySketch.swift") }?.1)
        // **一番上に式を置かない。** 置く形は「対象の中身が 1 つだけ」のときしか
        // 通らないので、利用者が資材を 1 つ足した時点で組み上がらなくなる
        #expect(sketch.contains("@main"))
        #expect(!sketch.contains("MySketch.main()"))
    }

    @Test("作られた定義は、実行ファイルを宣言している")
    func theGeneratedPackageDeclaresAnExecutable() throws {
        let files = try NewCommand.files(for: .init(name: "my-sketch"))
        let package = try #require(files.first { $0.0 == "Package.swift" }?.1)
        // 宣言が無いと、道具が実行ファイルの場所を解決できず遠回りを払い続ける
        #expect(package.contains(#".executable(name: "my-sketch", targets: ["my-sketch"])"#))
    }

    @Test("差し込みの残りが出来上がりに混ざらない")
    func leavesNoPlaceholderBehind() throws {
        for (name, contents) in try NewCommand.files(for: .init(name: "my-sketch")) {
            #expect(!contents.contains("{{"), "\(name) に差し込みの残りがある")
        }
    }

    @Test("版は下限だけを指し、上限を切らない")
    func pinsTheLibraryVersionAsAFloorOnly() throws {
        let files = try NewCommand.files(for: .init(name: "my-sketch"))
        let package = try #require(files.first { $0.0 == "Package.swift" }?.1)
        #expect(package.contains("from: \"\(Templates.libraryMinimumVersion)\""))
        // **上限が戻ってきたら赤くする。** 上限を切ると、下限の値が古くなった時点で
        // 新しく作るスケッチが古い 0.x に固定され、壊れないまま腐る (#214)
        #expect(
            !package.contains("upToNextMinor"),
            "上限を切ると Templates.libraryMinimumVersion の鮮度が効いてしまう")
    }
}
