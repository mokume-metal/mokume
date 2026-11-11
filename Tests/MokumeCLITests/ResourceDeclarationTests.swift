// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation
import MokumeTestSupport
import Synchronization
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
    ///   - before: 宣言の前に置く行 (コメントなど)。
    ///   - otherTargets: `targets:` に足す target。
    static func manifest(
        resources: String? = nil, before: String = "", otherTargets: String = ""
    ) -> String {
        let declared = resources.map { ", resources: [\($0)]" } ?? ""
        return """
            // swift-tools-version: 6.0
            import PackageDescription

            \(before)
            let package = Package(
                name: "demo",
                targets: [
                    .executableTarget(name: "demo"\(declared)),
                    \(otherTargets)
                ]
            )
            """
    }

    private func makeSketch(
        manifest: String, assets: [String] = [], hidden: [String] = [],
        target: String = "demo"
    ) throws -> URL {
        let root = TestScratch.path("mokume-resources", isDirectory: true)
        let place = root.appendingPathComponent("Sources/\(target)", isDirectory: true)
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

    @Test("宣言があれば通る")
    func aDeclaredDirectoryPasses() throws {
        let root = try makeSketch(
            manifest: Self.manifest(resources: #".copy("assets")"#), assets: ["grain.png"])
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(throws: Never.self) { try ResourceDeclaration.check(in: root) }
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
        #expect(throws: Never.self) { try ResourceDeclaration.check(in: root) }
    }

    /// `path:` で `Sources/demo` を置き場にした target `App`。
    private static func placedByPath(resources: String?) -> String {
        let declared = resources.map { ", resources: [\($0)]" } ?? ""
        return """
            // swift-tools-version: 6.0
            import PackageDescription

            let package = Package(
                name: "demo",
                targets: [
                    .executableTarget(name: "App", path: "Sources/demo"\(declared))
                ]
            )
            """
    }

    /// target の置き場を `path:` で動かしていても、その置き場の宣言を見る — 宣言していれば
    /// 通り、していなければ止まる (置き場を持つ target を名前からだけ探すと、どちらも素通りする)。
    @Test("path: で置き場を指した target の宣言も読む")
    func aTargetPlacedByPathIsMatched() throws {
        let declared = try makeSketch(
            manifest: Self.placedByPath(resources: #".copy("assets")"#), assets: ["grain.png"])
        defer { try? FileManager.default.removeItem(at: declared) }
        #expect(throws: Never.self) { try ResourceDeclaration.check(in: declared) }

        let undeclared = try makeSketch(
            manifest: Self.placedByPath(resources: nil), assets: ["grain.png"])
        defer { try? FileManager.default.removeItem(at: undeclared) }
        #expect(throws: CommandFailure.resourcesNotDeclared(directory: "Sources/demo/assets")) {
            try ResourceDeclaration.check(in: undeclared)
        }
    }

    @Test("中身があるのに宣言が無ければ止まる")
    func anUndeclaredDirectoryStops() throws {
        let root = try makeSketch(manifest: Self.manifest(), assets: ["grain.png"])
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(throws: CommandFailure.resourcesNotDeclared(directory: "Sources/demo/assets")) {
            try ResourceDeclaration.check(in: root)
        }
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
        #expect(throws: CommandFailure.resourcesNotDeclared(directory: "Sources/demo/assets")) {
            try ResourceDeclaration.check(in: root)
        }
    }

    /// コメントに書いた宣言は宣言ではない (#3984)。
    @Test("コメントの中の宣言では通さない")
    func aCommentedDeclarationDoesNotCount() throws {
        let root = try makeSketch(
            manifest: Self.manifest(before: #"// resources: [.copy("assets")],"#),
            assets: ["grain.png"])
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(throws: CommandFailure.resourcesNotDeclared(directory: "Sources/demo/assets")) {
            try ResourceDeclaration.check(in: root)
        }
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
        #expect(throws: Never.self) { try ResourceDeclaration.check(in: root) }
    }

    @Test("目印だけの置き場は止めない")
    func aDirectoryWithOnlyHiddenFilesIsFine() throws {
        let root = try makeSketch(manifest: Self.manifest(), hidden: [".gitkeep"])
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(throws: Never.self) { try ResourceDeclaration.check(in: root) }
    }

    @Test("宣言があっても、別の置き場を挙げているだけなら止める")
    func declaringSomethingElseDoesNotCount() throws {
        let root = try makeSketch(
            manifest: Self.manifest(resources: #".copy("shaders")"#), assets: ["grain.png"])
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(throws: CommandFailure.self) { try ResourceDeclaration.check(in: root) }
    }

    /// **宣言が読めない回は、ここでは止めない。** 道具立てが読めない `Package.swift` は、
    /// 後の段 (`bundle` は宣言を読む段・`run` などはビルド) が道具立ての理由を添えて止める。
    /// ここで「宣言が無い」と名乗ると、本当の理由 (宣言が壊れている) を隠す。
    @Test("道具立てが読めない宣言では、資材の検査は止めない")
    func anUnreadableManifestIsLeftToLaterSteps() throws {
        let root = try makeSketch(manifest: "// swift-tools-version: 6.0", assets: ["grain.png"])
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(throws: Never.self) { try ResourceDeclaration.check(in: root) }
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
        #expect(throws: Never.self) { try ResourceDeclaration.check(in: root) }
    }
}

/// 宣言の読みを、同じ実行の中で重ねない控え (#3984)。
///
/// 資材の検査は走らせる前に宣言を読み、その後の段 (置き場と product を決める・束ねる) も宣言を
/// 読む。同じ `Package.swift` に `dump-package` を 2 度起こさない。
@Suite("宣言の控え")
struct DeclarationMemoTests {
    private nonisolated final class Count: Sendable {
        let value = Mutex(0)
        func bump() { value.withLock { $0 += 1 } }
        var current: Int { value.withLock { $0 } }
    }

    private static let package = SwiftPM.package(inDumpOf: #"{"name": "demo"}"#)!

    private func makePackage(_ text: String) throws -> URL {
        let root = try TestScratch.directory("mokume-declaration-memo")
        try text.write(
            to: root.appendingPathComponent("Package.swift"), atomically: true, encoding: .utf8)
        return root
    }

    @Test("同じ宣言は 1 度だけ読み、書き換えれば読み直す")
    func readsOncePerManifest() throws {
        let root = try makePackage("// one")
        let memo = RunCommand.DeclarationMemo()
        let asked = Count()
        let ask = { () throws(CommandFailure) -> RunCommand.Declaration in
            asked.bump()
            return .declared(Self.package)
        }
        #expect(try memo.reading(root, keeping: true, ask: ask) == .declared(Self.package))
        #expect(try memo.reading(root, keeping: true, ask: ask) == .declared(Self.package))
        #expect(asked.current == 1, "同じ宣言を 2 度読んだ")

        try "// two".write(
            to: root.appendingPathComponent("Package.swift"), atomically: true, encoding: .utf8)
        _ = try memo.reading(root, keeping: true, ask: ask)
        #expect(asked.current == 2, "書き換えた宣言を読み直さない")
    }

    /// 止められうる読み (見張りの作り直しの糸) の答えは控えない。途中で止めた回の失敗を、
    /// 同じ宣言の次の読みへ持ち越さないため。控えを使うのはどの読みでもよい。
    @Test("控えないと言った読みの答えは残さない")
    func answersNotKeptAreAskedAgain() throws {
        let root = try makePackage("// one")
        let memo = RunCommand.DeclarationMemo()
        let asked = Count()
        let ask = { () throws(CommandFailure) -> RunCommand.Declaration in
            asked.bump()
            return .unanswered(status: 15)
        }
        _ = try memo.reading(root, keeping: false, ask: ask)
        _ = try memo.reading(root, keeping: false, ask: ask)
        #expect(asked.current == 2)
    }

    @Test("宣言が無ければ控えない")
    func aMissingManifestIsNotKept() throws {
        let root = try TestScratch.directory("mokume-declaration-memo")
        let memo = RunCommand.DeclarationMemo()
        let asked = Count()
        let ask = { () throws(CommandFailure) -> RunCommand.Declaration in
            asked.bump()
            return .unreadable
        }
        _ = try memo.reading(root, keeping: true, ask: ask)
        _ = try memo.reading(root, keeping: true, ask: ask)
        #expect(asked.current == 2)
    }
}
