// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation
import Testing

@testable import MokumeCore

/// 同梱資源の探し方。
///
/// 配ったときにしか表に出ない経路なので、**組み上げた並びを手で作って**確かめる。
@Suite("同梱資源の探し方")
struct ModuleResourcesTests {
    /// 包みを 1 つ持つ置き場を作る。
    private func makeBundle(named name: String, containing file: String, in root: URL) throws {
        let bundle = root.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        try "// 断片".write(
            to: bundle.appendingPathComponent(file), atomically: true, encoding: .utf8)
    }

    private func makeWorkspace() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("mokume-module-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    @Test("素の実行ファイルでは、隣の包みを見る")
    func aPlainExecutableLooksBeside() throws {
        let root = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: root) }
        try makeBundle(
            named: "\(ModuleResources.bundleName).bundle", containing: "Shapes.metal", in: root)

        let found = ModuleResources.resolve(
            name: "Shapes", extension: "metal", neighbourhood: root, resources: root,
            lastResort: { _, _ in nil })
        #expect(found?.lastPathComponent == "Shapes.metal")
    }

    @Test("束ねた形では、資源の置き場の包みを見る")
    func aPackagedAppLooksInResources() throws {
        let root = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let app = root.appendingPathComponent("Demo.app", isDirectory: true)
        let resources = app.appendingPathComponent("Contents/Resources", isDirectory: true)
        try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
        try makeBundle(
            named: "\(ModuleResources.bundleName).bundle", containing: "Shapes.metal",
            in: resources)

        // 束ねた形では、実行ファイルの隣 (Contents/MacOS) ではなく包みそのものが起点になる
        let found = ModuleResources.resolve(
            name: "Shapes", extension: "metal", neighbourhood: app, resources: resources,
            lastResort: { _, _ in nil })
        #expect(found?.lastPathComponent == "Shapes.metal")
    }

    @Test("包みが 1 つも無ければ、組み上げた機械の上でだけ道具立ての口へ譲る")
    func nothingFoundFallsBackToTheToolchain() throws {
        let root = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: root) }

        var asked = false
        _ = ModuleResources.resolve(
            name: "Shapes", extension: "metal", neighbourhood: root, resources: root,
            onBuildMachine: true,
            lastResort: { _, _ in
                asked = true
                return nil
            })
        #expect(asked, "開発中と検査の経路が塞がっている")
    }

    /// 検査はこの機械の上で走るので、既定のままでも譲りは効く。**既定が塞がると開発中と
    /// 検査の経路ごと止まる**ので、明示した側とは別に見る。
    @Test("この機械の上に居ることは、既定で判定される")
    func theBuildMachineIsDetectedByDefault() {
        #expect(ModuleResources.isOnBuildMachine, "検査はソースツリーの上で走っている")
    }

    /// 譲る先が指すのは**組み上げた機械の絶対パス**で、配った先には無い。譲ると、
    /// こちらの名乗りに変えられないまま作者のディレクトリを名指しして落ちる
    /// (`Bundle.module` は見つからなければ `fatalError` を起こす)。
    ///
    /// **素の実行ファイルとして配った形**がここに当たる — Homebrew で入れた道具が
    /// これで落ちていた ([#1058](https://github.com/mokume-metal/mokume/issues/1058))。
    @Test("配った先では、道具立ての口へ譲らない")
    func aDistributedExecutableNeverFallsBack() throws {
        let root = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: root) }

        var asked = false
        let found = ModuleResources.resolve(
            name: "Shapes", extension: "metal", neighbourhood: root, resources: root,
            onBuildMachine: false,
            lastResort: { _, _ in
                asked = true
                return nil
            })
        #expect(!asked, "配った先で、組み上げた機械の絶対パスへ落ちている")
        #expect(found == nil)
    }

    @Test("在処は、資源を探すのと同じ並びから出る")
    func theLocationComesFromTheSameSearch() throws {
        let root = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: root) }
        try makeBundle(
            named: "\(ModuleResources.bundleName).bundle",
            containing: "\(ModuleResources.probe.name).\(ModuleResources.probe.ext)", in: root)

        let location = ModuleResources.location(
            neighbourhood: root, resources: root, onBuildMachine: false,
            lastResort: { _, _ in nil })
        #expect(location?.lastPathComponent == "\(ModuleResources.bundleName).bundle")
    }

    @Test("読める包みが無ければ、在処は無い")
    func theLocationIsAbsentWhenNothingIsReadable() throws {
        let root = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: root) }

        let location = ModuleResources.location(
            neighbourhood: root, resources: root, onBuildMachine: false,
            lastResort: { _, _ in nil })
        #expect(location == nil)
    }

    /// 譲る先が指すのは**組み上げた機械の絶対パス**で、配った先には無い。譲ると、
    /// こちらの名乗りに変えられないまま作者のディレクトリを名指しして落ちる。
    @Test("束ねた形では、道具立ての口へ譲らない")
    func aPackagedAppNeverFallsBack() throws {
        let root = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let app = root.appendingPathComponent("Demo.app", isDirectory: true)
        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)

        // 組み上げた機械の上に居ても譲らない — 止めているのは束ねた形であること
        var asked = false
        let found = ModuleResources.resolve(
            name: "Shapes", extension: "metal", neighbourhood: app, resources: nil,
            onBuildMachine: true,
            lastResort: { _, _ in
                asked = true
                return nil
            })
        #expect(!asked)
        #expect(found == nil)
    }

    @Test("同じ場所を 2 度は並べない")
    func theSameRootIsListedOnce() {
        let root = URL(fileURLWithPath: "/tmp/demo", isDirectory: true)
        #expect(ModuleResources.candidates(neighbourhood: root, resources: root).count == 1)
        #expect(ModuleResources.candidates(neighbourhood: root, resources: nil).count == 1)
        #expect(
            ModuleResources.candidates(
                neighbourhood: root,
                resources: URL(fileURLWithPath: "/tmp/other", isDirectory: true)
            ).count == 2)
    }

    /// ソースに在る断片が、束ねた中からすべて読めること。
    ///
    /// **`Package.swift` の書き忘れを見る検査である。** 断片はディレクトリごと拾われる
    /// のをやめ、1 つずつ `.copy` で並べる形になった
    /// ([#1268](https://github.com/mokume-metal/mokume/issues/1268))。
    ///
    /// **足し忘れの出方は道具立ての版で違う。** Xcode 27 (Swift 6.4) は並びに無い
    /// `.metal` を**ソースと読んでコンパイルしようとする**ので build で落ちる (実測)。
    /// Xcode 26.6 では「扱いの決まっていない資源」の警告になるだけで、束ねられずに
    /// **実行時にだけ見つからない** — 絵が出ないところまで行って初めて分かる。
    /// ここが名指しで落とすのは後者である。
    ///
    /// **組み上げた機械の上でだけ見る。** ソースの在処を読むので、配った先には無い道で
    /// ある (`ModuleResources.isOnBuildMachine` と同じ判定)。
    @MainActor
    @Test("ソースに在るシェーダの断片は、束ねた中からすべて読める")
    func everyShaderFragmentIsBundled() throws {
        try #require(ModuleResources.isOnBuildMachine, "組み上げた機械の上でだけ見る")
        let sources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()      // Tests/MokumeCoreTests
            .deletingLastPathComponent()      // Tests
            .deletingLastPathComponent()      // パッケージの根
            .appendingPathComponent("Sources/MokumeCore", isDirectory: true)
        let found = try #require(
            FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil))
        let fragments = found.compactMap { $0 as? URL }.filter { $0.pathExtension == "metal" }
        // 並べる側が空だと、この検査は何も見ずに緑になる
        #expect(fragments.count >= 8)
        for fragment in fragments {
            let name = fragment.deletingPathExtension().lastPathComponent
            #expect(
                ModuleResources.url(forResource: name, withExtension: "metal") != nil,
                "\(fragment.lastPathComponent) が束ねた中に無い — Package.swift の resources へ足す")
        }
    }
}
