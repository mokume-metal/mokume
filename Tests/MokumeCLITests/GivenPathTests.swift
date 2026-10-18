// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation
import Testing

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

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("mokume-given-path-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
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
            BuildDirectory.environmentKey: FileManager.default.temporaryDirectory
                .appendingPathComponent("mokume-doctor-store-\(UUID().uuidString)").path
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
}
