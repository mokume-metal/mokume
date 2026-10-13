// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation
import Testing

@testable import MokumeCLI

/// 空の場所の引数 ([#2485](https://github.com/mokume-metal/mokume/issues/2485))。
///
/// **空の値は場所を名指していない。** `URL(fileURLWithPath: "")` は走らせた場所に解けるので、
/// `run "$DIR"` で `DIR` が空だった回は、黙って走らせた場所のスケッチを動かしていた。
/// 打った値を別のものとして読まない (#680・#2321) ので、場所を取る口は使い方の誤りとして断る。
///
/// 検査は各口の `parse` (と `doctor` の文面) だけで確かめる。**子は起こさない。**
@Suite("空の場所の引数")
struct EmptyPlaceTests {
    /// 投げられた使い方の失敗の文面。使い方の誤り以外 (別の失敗・投げない) なら `nil`。
    private func usageMessage(_ body: () throws -> Void) -> String? {
        do {
            try body()
            return nil
        } catch let failure as CommandFailure {
            guard case .usage(let text) = failure else { return nil }
            return text
        } catch {
            return nil
        }
    }

    /// 断る文面に、空だったことと、どの引数だったかが書かれているか。
    private func expectRefused(
        _ message: String?, naming needle: String, sourceLocation: SourceLocation = #_sourceLocation
    ) {
        guard let message else {
            Issue.record("使い方の誤りとして止まっていない", sourceLocation: sourceLocation)
            return
        }
        #expect(
            message.contains("empty"), "空だったことを言っていない: \(message)",
            sourceLocation: sourceLocation)
        #expect(
            message.contains(needle), "どの引数かを名指していない: \(message)",
            sourceLocation: sourceLocation)
    }

    // ------------------------------------------------------------ 位置引数 (完了条件 1)

    /// `run`・`watch`・`render` (と `doctor` の解き方) は `Invocation.parse` を通る。
    @Test("run / watch / render の場所が空なら、作業ディレクトリに解かずに止まる")
    func anEmptyPlaceOfTheRunningVerbsIsRefused() {
        expectRefused(usageMessage { _ = try Invocation.parse([""]) }, naming: "directory")
        // 選択肢の前後どちらに置いても同じ
        expectRefused(
            usageMessage { _ = try Invocation.parse(["-c", "release", ""]) }, naming: "directory")
        expectRefused(
            usageMessage { _ = try Invocation.parse(["", "-c", "release"]) }, naming: "directory")
        expectRefused(
            usageMessage {
                _ = try RenderCommand.parse(
                    ["", "--fps", "30", "--seconds", "1", "--out", "/a.mov"])
            }, naming: "directory")
    }

    @Test("bundle の場所が空なら、作業ディレクトリに解かずに止まる")
    func anEmptyPlaceOfBundleIsRefused() {
        expectRefused(usageMessage { _ = try BundleCommand.parse([""]) }, naming: "directory")
    }

    @Test("mcp の場所が空なら、作業ディレクトリに解かずに止まる")
    func anEmptyPlaceOfMCPIsRefused() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("mokume-empty-place-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        // 作業ディレクトリは在る。在るので、解いてしまえば通る — それを断る
        expectRefused(
            usageMessage {
                _ = try MCPCommand.directories(
                    arguments: [""], environment: [:], currentDirectory: root)
            }, naming: "directory")
    }

    // ------------------------------------------------------------ 選択肢の値 (完了条件 2)

    @Test("--scratch-path の値が空なら、止まる")
    func anEmptyScratchPathIsRefused() {
        expectRefused(
            usageMessage { _ = try Invocation.parse(["--scratch-path", ""]) },
            naming: "--scratch-path")
        expectRefused(
            usageMessage { _ = try Invocation.parse(["/tmp/sketch", "--scratch-path", ""]) },
            naming: "--scratch-path")
    }

    @Test("render --out の値が空なら、止まる")
    func anEmptyRenderOutIsRefused() {
        expectRefused(
            usageMessage {
                _ = try RenderCommand.parse(["--fps", "30", "--seconds", "1", "--out", ""])
            }, naming: "--out")
    }

    @Test("bundle --out の値が空なら、止まる")
    func anEmptyBundleOutIsRefused() {
        expectRefused(
            usageMessage { _ = try BundleCommand.parse(["/tmp/sketch", "--out", ""]) },
            naming: "--out")
    }

    @Test("new --path の値が空なら、止まる")
    func anEmptyNewPathIsRefused() {
        expectRefused(
            usageMessage { _ = try NewCommand.parse(["sketch", "--path", ""]) }, naming: "--path")
    }

    /// **`--local` も場所である** (反証の指摘)。値は `.package(path:)` へ書かれ、依存の名前
    /// (`packageIdentity`) も `""` を作るスケッチ自身の名前にするので、空のまま通すと自分に依存する
    /// 壊れた `Package.swift` が黙って作られる。解き方は変えず、空かどうかだけを見る。
    @Test("new --local の値が空なら、止まる")
    func anEmptyNewLocalIsRefused() {
        expectRefused(
            usageMessage { _ = try NewCommand.parse(["sketch-x", "--local", ""]) },
            naming: "--local")
    }

    // ------------------------------------------------------------ 変わらないこと

    /// 空でなければ、いままでどおり受ける。**場所でない値は対象外**: `new` の名前は名前の規則で
    /// 断られる (`invalidName`・空の名前は空だったと名乗る)。`--local` は空でなければ打ったとおり
    /// `.package(path:)` へ書く (解き方は変えない)。
    @Test("空でない値と、場所でない値は、いままでどおり")
    func nonEmptyValuesAndNonPlacesAreUnchanged() throws {
        #expect(try Invocation.parse(["."]) == Invocation(place: "."))
        #expect(try Invocation.parse([]) == Invocation())
        #expect(try Invocation.parse(["--scratch-path", ".build"]).scratchPath == ".build")
        #expect(try BundleCommand.parse(["--out", "dist"]).out == "dist")
        #expect(try NewCommand.parse(["s", "--path", "."]).path == ".")
        #expect(throws: CommandFailure.invalidName("")) { try NewCommand.parse([""]) }
        #expect(CommandFailure.invalidName("").message.hasPrefix("The name is empty\n"))
        #expect(CommandFailure.invalidName("a b").message.contains("characters a sketch cannot use: a b"))
        // `--local` の空でない値は、打ったとおり `.package(path:)` へ書かれる
        let options = try NewCommand.parse(["s", "--local", "../lib dir/x"])
        #expect(options.local == "../lib dir/x")
        let manifest = try #require(
            try NewCommand.files(for: options).first { $0.0 == "Package.swift" }?.1)
        #expect(manifest.contains(#".package(path: "../lib dir/x")"#))
    }

    // ------------------------------------------------------------ doctor (完了条件 3)

    /// 止まらない口は、断らずに名乗る。**走らせた場所を、渡された場所のように見せない** —
    /// 名乗りの行が先に立ち、診た場所がどこかも書く。
    @Test("doctor は空の場所で止まらず、空だったことと、代わりに診た場所を名乗る")
    func doctorNamesAnEmptyPlace() throws {
        let typedFrom = FileManager.default.temporaryDirectory
            .appendingPathComponent("mokume-empty-doctor-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: typedFrom, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: typedFrom) }
        let store = typedFrom.appendingPathComponent("store").path
        let environment = [BuildDirectory.environmentKey: store]

        let text = DoctorCommand.text(
            for: [""], workDirectory: nil, environment: environment, currentDirectory: typedFrom)
        #expect(text.contains("An empty directory was given"), "空だったことを名乗っていない: \(text)")
        #expect(
            text.contains(typedFrom.standardizedFileURL.path), "代わりに診た場所を名乗っていない")
        // 名乗りは、診た結果より前に置く
        let notice = text.range(of: "An empty directory was given")
        let report = text.range(of: "What the environment provides")
        #expect(notice != nil && report != nil && notice!.lowerBound < report!.lowerBound)

        // 場所を渡さなければ、名乗りは出ない
        let plain = DoctorCommand.text(
            for: [], workDirectory: nil, environment: environment, currentDirectory: typedFrom)
        #expect(!plain.contains("An empty directory was given"))
    }
}
