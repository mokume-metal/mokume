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

    @Test("包みが 1 つも無ければ、道具立ての口へ譲る")
    func nothingFoundFallsBackToTheToolchain() throws {
        let root = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: root) }

        var asked = false
        _ = ModuleResources.resolve(
            name: "Shapes", extension: "metal", neighbourhood: root, resources: root,
            lastResort: { _, _ in
                asked = true
                return nil
            })
        #expect(asked, "開発中と検査の経路が塞がっている")
    }

    /// 譲る先が指すのは**組み上げた機械の絶対パス**で、配った先には無い。譲ると、
    /// こちらの名乗りに変えられないまま作者のディレクトリを名指しして落ちる。
    @Test("束ねた形では、道具立ての口へ譲らない")
    func aPackagedAppNeverFallsBack() throws {
        let root = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let app = root.appendingPathComponent("Demo.app", isDirectory: true)
        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)

        var asked = false
        let found = ModuleResources.resolve(
            name: "Shapes", extension: "metal", neighbourhood: app, resources: nil,
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
}
