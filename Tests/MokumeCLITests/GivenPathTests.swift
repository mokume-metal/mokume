// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation
import MokumeTestSupport
import Testing
import mokume

@testable import MokumeCLI

/// 走らせた場所が読めない回 (作業ディレクトリが消えた) の場所の解き方
/// ([#2497](https://github.com/mokume-metal/mokume/issues/2497))。
///
/// 作業ディレクトリを消したプロセスでは `FileManager.currentDirectoryPath` が空文字列を返し
/// (実測)、そこから作った URL は基準を持たない `./` になる。そのまま基準にすると、相対パスは
/// 相対のまま解け、「絶対パスにする」という約束が黙って破れていた。
///
/// **作業ディレクトリは本当には消さない** — 並んで走る他の検査の足場が消える。読み取りを
/// 差し替えて (`GivenPath.currentDirectory(reading:)`)、基準が読めない回 (`nil`) を渡す。
@Suite("走らせた場所が読めない回")
struct GivenPathTests {
    private static let absolute = "/mokume-given-path/absolute"

    /// 投げられた失敗。投げなければ `nil`。
    private func failure<T>(_ body: () throws(CommandFailure) -> T) -> CommandFailure? {
        do {
            _ = try body()
            return nil
        } catch {
            return error
        }
    }

    // -------------------------------------------------------------- 読み取り

    @Test("作業ディレクトリが空文字列で読めたら、読めないことにする")
    func anEmptyWorkingDirectoryIsUnreadable() {
        #expect(GivenPath.currentDirectory(reading: { "" }) == nil)
        #expect(GivenPath.currentDirectory(reading: { "/work/plain" })?.path == "/work/plain")
    }

    // -------------------------------------------------------------- resolve

    /// 絶対パスは基準に触れない。**基準が読めなくても通り**、基準の URL も持たない。
    @Test("絶対パスは、基準が読めなくても通る")
    func anAbsolutePathPassesWithoutABase() throws {
        for given in [Self.absolute, "/a/b/../c", "\(Self.absolute)/"] {
            let url = try GivenPath.resolve(given, from: nil)
            #expect(url.baseURL == nil, "基準の URL を持っている: \(url)")
            #expect(!url.pathComponents.contains(".."))
            #expect(url.path.hasPrefix("/"))
        }
        #expect(try GivenPath.resolve("/a/b/../c", from: nil).path == "/a/c")
        // 引用して打たれた `~` は home へ展開されるので、絶対パスである
        let home = try GivenPath.resolve("~/x", from: nil)
        #expect(home.path == NSHomeDirectory() + "/x")
        #expect(home.baseURL == nil)
    }

    /// 相対パスは解く先が無い。**相対のまま返さずに、名乗って止まる。**
    @Test("相対パスは、基準が読めなければ名乗って止まる", arguments: ["sub", "../x", ".", "./a", ""])
    func aRelativePathIsRefusedWithoutABase(given: String) {
        #expect(
            failure { () throws(CommandFailure) in try GivenPath.resolve(given, from: nil) }
                == .currentDirectoryUnreadable(given: given))
    }

    @Test("基準が読めるなら、相対パスは基準から絶対パスに解く")
    func aRelativePathIsResolvedFromTheBase() throws {
        let base = URL(fileURLWithPath: "/work/plain", isDirectory: true)
        let url = try GivenPath.resolve("../x", from: base)
        #expect(url.path == "/work/x")
        #expect(url.baseURL == nil)
    }

    // -------------------------------------------------------------- 各口

    /// `run`・`watch`・`render` は `Invocation.parse` を通る。**ビルドの道具を起こす前に**
    /// 止まる (後で使う側が解くと、数分のビルドの後で知らせることになる)。
    @Test("run / watch / render は、相対の場所・置き場と場所の省略を、解く前に断る")
    func theRunningVerbsRefuseRelativePlaces() {
        func parse(_ arguments: [String]) -> CommandFailure? {
            failure { () throws(CommandFailure) in
                _ = try Invocation.parse(arguments, from: nil)
            }
        }
        #expect(parse(["sketches/grain"]) == .currentDirectoryUnreadable(given: "sketches/grain"))
        // 場所の省略は走らせた場所そのもの
        #expect(parse([]) == .currentDirectoryUnreadable(given: "."))
        #expect(parse(["-c", "release"]) == .currentDirectoryUnreadable(given: "."))
        // 置き場だけが相対でも、場所が絶対でも断る
        #expect(
            parse([Self.absolute, "--scratch-path", "sp"])
                == .currentDirectoryUnreadable(given: "sp"))
        // 絶対パスで渡した回は通る
        #expect(parse([Self.absolute]) == nil)
        #expect(parse([Self.absolute, "--scratch-path", "/store"]) == nil)
    }

    @Test("render は、相対の --out も解く前に断り、絶対パスなら通る")
    func renderRefusesARelativeOut() {
        func parse(out: String) -> CommandFailure? {
            failure { () throws(CommandFailure) in
                _ = try RenderCommand.parse(
                    [Self.absolute, "--fps", "30", "--seconds", "1", "--out", out],
                    currentDirectory: nil)
            }
        }
        #expect(parse(out: "motion.mov") == .currentDirectoryUnreadable(given: "motion.mov"))
        #expect(parse(out: "/tmp/mokume-given-path/motion.mov") == nil)
    }

    @Test("mcp は、相対の場所と場所の省略を断り、絶対パスなら通る")
    func mcpRefusesARelativePlace() throws {
        func directories(_ arguments: [String]) -> CommandFailure? {
            failure { () throws(CommandFailure) in
                _ = try MCPCommand.directories(
                    arguments: arguments, environment: [:], currentDirectory: nil)
            }
        }
        #expect(directories(["sub"]) == .currentDirectoryUnreadable(given: "sub"))
        #expect(directories([]) == .currentDirectoryUnreadable(given: "."))
        // 絶対パスは通り、在るかの判定へ進む (ここでは在らないので、その失敗で止まる)
        #expect(directories([Self.absolute]) == .directoryNotFound(path: Self.absolute))

        let root = try TestScratch.directory("mokume-given-path")
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(directories([root.path]) == nil)
    }

    @Test("bundle は、相対の場所・置き場と場所の省略を断り、絶対パスなら通る")
    func bundleRefusesRelativePlaces() throws {
        let options = try BundleCommand.parse([])
        #expect(
            failure { () throws(CommandFailure) in _ = try options.directory(from: nil) }
                == .currentDirectoryUnreadable(given: "."))
        let relative = try BundleCommand.parse(["sketch", "--out", "dist"])
        #expect(
            failure { () throws(CommandFailure) in _ = try relative.directory(from: nil) }
                == .currentDirectoryUnreadable(given: "sketch"))
        #expect(
            failure { () throws(CommandFailure) in _ = try relative.outDirectory(from: nil) }
                == .currentDirectoryUnreadable(given: "dist"))

        let absolute = try BundleCommand.parse([Self.absolute, "--out", "/dist"])
        #expect(try absolute.directory(from: nil).path == Self.absolute)
        #expect(try absolute.outDirectory(from: nil)?.path == "/dist")
    }

    @Test("new は、相対の --path を断り、絶対パスなら通る")
    func newRefusesARelativePath() throws {
        let relative = NewCommand.Options(name: "grain", path: "work")
        #expect(
            failure { () throws(CommandFailure) in _ = try relative.root(from: nil) }
                == .currentDirectoryUnreadable(given: "work"))
        // 既定の `--path` (`.`) も走らせた場所である
        let omitted = NewCommand.Options(name: "grain")
        #expect(
            failure { () throws(CommandFailure) in _ = try omitted.root(from: nil) }
                == .currentDirectoryUnreadable(given: "."))
        let absolute = NewCommand.Options(name: "grain", path: Self.absolute)
        #expect(try absolute.root(from: nil).path == Self.absolute + "/grain")
    }

    // -------------------------------------------------------------- 文面

    @Test("断る文面は、走らせた場所が読めないことと、直し方を言う")
    func theRefusalNamesTheCauseAndTheWayOut() {
        let relative = CommandFailure.currentDirectoryUnreadable(given: "sketches/grain").message
        #expect(relative.contains("Cannot read the directory this was run from"))
        #expect(relative.contains("sketches/grain"))
        #expect(relative.contains("absolute path"))
        // 省略した回に、打っていない綴りを名指さない
        let omitted = CommandFailure.currentDirectoryUnreadable(given: ".").message
        #expect(omitted.contains("defaults to"))
        #expect(CommandFailure.currentDirectoryUnreadable(given: ".").exitCode == 1)
    }

    // -------------------------------------------------------------- doctor

    /// **`doctor` は止まらない。** いちばん要るときに読めなくなる (知らない引数・空の場所と同じ)。
    @Test("doctor は、走らせた場所が読めなくても止まらず、先頭でそう名乗る")
    func doctorAnnouncesAnUnreadableWorkingDirectory() {
        let environment = [
            BuildDirectory.environmentKey: TestScratch.path("mokume-doctor-store").path
        ]
        // 実在しない相対の綴り (走らせている場所に同名があっても影響されない)
        let spelling = "mokume-no-such-\(UUID().uuidString)"
        let text = DoctorCommand.text(
            for: [spelling], workDirectory: nil, environment: environment, currentDirectory: nil)
        #expect(text.hasPrefix("Cannot read the directory this was run from"), "先頭で名乗っていない")
        #expect(text.contains(spelling))
        #expect(text.contains("What the environment provides"), "環境の節まで出ていない")

        // 場所の省略も止まらない
        let omitted = DoctorCommand.text(
            for: [], workDirectory: nil, environment: environment, currentDirectory: nil)
        #expect(omitted.hasPrefix("Cannot read the directory this was run from"))
        #expect(omitted.contains("What the environment provides"))
        // **解けていない綴りを stat しない** — macOS は消えた作業ディレクトリの `.` を読めてしまい、
        // そこへ `swift` を起こしに行って落ちた (実測)。場所は辿り着けない側で名乗る
        #expect(omitted.contains("— cannot be reached: the directory this was run from cannot be read"))
        #expect(!omitted.contains("Sketch: Package.swift is here"))

        // 絶対パスで場所を渡した回は、いつもどおり診る (名乗らない)
        let absolute = DoctorCommand.text(
            for: ["/nonexistent-\(UUID().uuidString)"], workDirectory: nil,
            environment: environment, currentDirectory: nil)
        #expect(!absolute.contains("Cannot read the directory this was run from"))
        #expect(absolute.contains("nothing is there"))
    }

    // -------------------------------------------------------------- 環境変数の基準 (#2497 の反証)

    private static let workKey = StartupReads.workDirectory.key
    private static let buildKey = BuildDirectory.environmentKey

    /// 環境変数が与える基準も、引数の場所と同じ約束を負う: 読めない作業ディレクトリでは、
    /// 相対の綴りを相対のまま返さずに断る。絶対パスは通る。
    @Test("MOKUME_WORK_DIR が相対で作業ディレクトリが読めなければ断り、絶対か未設定なら通る")
    func theWorkDirectoryVariableIsRefusedWhenRelative() throws {
        let relative = [Self.workKey: "facets"]
        #expect(
            failure { () throws(CommandFailure) in
                _ = try GivenPath.workDirectory(environment: relative, from: nil)
            } == .currentDirectoryUnreadable(given: "facets", variable: Self.workKey))
        #expect(try GivenPath.workDirectory(environment: [Self.workKey: "/abs/facets"], from: nil)?.path == "/abs/facets")
        #expect(try GivenPath.workDirectory(environment: [:], from: nil) == nil)
        // 読める作業ディレクトリなら、そこから絶対にする
        let base = URL(fileURLWithPath: "/work/plain", isDirectory: true)
        let resolved = try GivenPath.workDirectory(environment: relative, from: base)
        #expect(resolved?.path == "/work/plain/facets")
        #expect(resolved?.baseURL == nil)
    }

    @Test("MOKUME_BUILD_DIR が相対で作業ディレクトリが読めなければ断り、絶対なら通る")
    func theBuildDirectoryVariableIsRefusedWhenRelative() throws {
        let home = URL(fileURLWithPath: "/Users/example", isDirectory: true)
        #expect(
            failure { () throws(CommandFailure) in
                _ = try BuildDirectory.root(
                    environment: [Self.buildKey: "store"], home: home, currentDirectory: nil)
            } == .currentDirectoryUnreadable(given: "store", variable: Self.buildKey))
        #expect(
            try BuildDirectory.root(
                environment: [Self.buildKey: "/tmp/store"], home: home, currentDirectory: nil
            ).path == "/tmp/store")
        // 未設定は home の既定で、作業ディレクトリに依らない
        #expect(
            try BuildDirectory.root(environment: [:], home: home, currentDirectory: nil).path
                == "/Users/example/Library/Caches/mokume/build")
        #expect(
            try BuildDirectory.root(
                environment: [Self.buildKey: "store"], home: home,
                currentDirectory: URL(fileURLWithPath: "/work", isDirectory: true)
            ).path == "/work/store")
    }

    /// run / watch / render は `Invocation.parse` で、絶対パスの場所を渡していても、相対の
    /// `MOKUME_WORK_DIR` が読めない作業ディレクトリに当たるなら、ビルドの前に止まる。
    @Test("run / watch / render は、相対の MOKUME_WORK_DIR を読めない作業ディレクトリで断る")
    func theRunningVerbsRefuseARelativeWorkDirectoryVariable() {
        func parse(_ environment: [String: String]) -> CommandFailure? {
            failure { () throws(CommandFailure) in
                _ = try Invocation.parse([Self.absolute], from: nil, environment: environment)
            }
        }
        #expect(
            parse([Self.workKey: "facets"])
                == .currentDirectoryUnreadable(given: "facets", variable: Self.workKey))
        #expect(parse([Self.workKey: "/abs/facets"]) == nil)
        #expect(parse([:]) == nil)
    }

    @Test("mcp は、相対の MOKUME_WORK_DIR・MOKUME_BUILD_DIR を読めない作業ディレクトリで断る")
    func mcpRefusesRelativeVariables() throws {
        let root = try TestScratch.directory("mokume-given-path")
        defer { try? FileManager.default.removeItem(at: root) }
        func directories(_ environment: [String: String]) -> CommandFailure? {
            failure { () throws(CommandFailure) in
                _ = try MCPCommand.directories(
                    arguments: [root.path], environment: environment, currentDirectory: nil)
            }
        }
        #expect(
            directories([Self.workKey: "facets"])
                == .currentDirectoryUnreadable(given: "facets", variable: Self.workKey))
        #expect(
            directories([Self.buildKey: "store"])
                == .currentDirectoryUnreadable(given: "store", variable: Self.buildKey))
        #expect(directories([Self.workKey: "/abs/facets", Self.buildKey: "/abs/store"]) == nil)
    }

    @Test("断る文面は、環境変数の名前を言い、そこへ絶対パスを書けと言う")
    func theRefusalNamesTheVariable() {
        let message = CommandFailure.currentDirectoryUnreadable(
            given: "facets", variable: Self.workKey
        ).message
        #expect(message.contains(Self.workKey))
        #expect(message.contains("facets"))
        #expect(message.contains("absolute path in \(Self.workKey)"))
    }

    /// doctor は止まらず、相対の環境変数を「与えられていないもの」として診て、そう名乗る。
    @Test("doctor は、相対の環境変数が読めない作業ディレクトリに当たっても止まらず名乗る")
    func doctorAnnouncesUnreadableVariables() throws {
        let root = try TestScratch.directory("mokume-given-path")
        defer { try? FileManager.default.removeItem(at: root) }
        let text = DoctorCommand.text(
            for: [root.path], workDirectory: nil,
            environment: [Self.workKey: "facets", Self.buildKey: "store"], currentDirectory: nil)
        #expect(text.contains("\(Self.workKey) is the relative path facets"))
        #expect(text.contains("\(Self.buildKey) is the relative path store"))
        // 場所は絶対パスで渡されているので、診る (場所の名乗りは出ない)
        #expect(!text.contains("no place was looked at"))
        #expect(text.contains("Place: \(root.path)"))
        // 解けない根の共有の置き場は読まない
        #expect(text.contains("Shared store: \(DoctorCommand.unknown)"))
    }

    /// 空の場所 (`doctor ""`) × 読めない作業ディレクトリ: 「走らせた場所を診た」と「何も診ていない」が
    /// 並んで矛盾していた。診る場所が無いので、空だったことを言ったうえで、何も診ていないと言う。
    @Test("doctor の空の場所は、作業ディレクトリが読めなければ、診たとは言わず空だったことと読めないことを言う")
    func doctorEmptyPlaceWithAnUnreadableWorkingDirectory() {
        let environment = [
            BuildDirectory.environmentKey: TestScratch.path("mokume-doctor-store").path
        ]
        let text = DoctorCommand.text(
            for: [""], workDirectory: nil, environment: environment, currentDirectory: nil)
        #expect(text.hasPrefix("An empty directory was given, which names no place. Cannot read"))
        #expect(text.contains("no place was looked at"))
        #expect(!text.contains("This looked where you ran it instead"), "診たと言っている")
        // 読める作業ディレクトリなら、従来どおり走らせた場所を診たと名乗る
        let readable = DoctorCommand.text(
            for: [""], workDirectory: nil, environment: environment,
            currentDirectory: URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true))
        #expect(readable.contains("This looked where you ran it instead"))
        #expect(!readable.contains("no place was looked at"))
    }
}
