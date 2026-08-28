// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation
import Testing

@testable import MokumeCLI

/// 資材の置き場が宣言されているかを見る検査。
///
/// **宣言の抜けはビルドを通ってしまう。** 通った後では「組み上がったのに絵が出ない」
/// 形になり、描画側を疑って当たりが外れ続ける。走らせる前にここで止める。
@Suite("資材の宣言")
struct ResourceDeclarationTests {
    private func makeSketch(
        manifest: String, assets: [String] = [], hidden: [String] = []
    ) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("mokume-resources-\(UUID().uuidString)", isDirectory: true)
        let target = root.appendingPathComponent("Sources/demo", isDirectory: true)
        let directory = target.appendingPathComponent("assets", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
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
            manifest: #"resources: [.copy("assets")],"#, assets: ["grain.png"])
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(throws: Never.self) { try ResourceDeclaration.check(in: root) }
    }

    @Test("中身があるのに宣言が無ければ止まる")
    func anUndeclaredDirectoryStops() throws {
        let root = try makeSketch(manifest: "let package = Package(name: \"demo\")",
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
        let root = try makeSketch(manifest: "let package = Package(name: \"demo\")")
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(throws: Never.self) { try ResourceDeclaration.check(in: root) }
    }

    @Test("目印だけの置き場は止めない")
    func aDirectoryWithOnlyHiddenFilesIsFine() throws {
        let root = try makeSketch(
            manifest: "let package = Package(name: \"demo\")", hidden: [".gitkeep"])
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(throws: Never.self) { try ResourceDeclaration.check(in: root) }
    }

    @Test("宣言があっても、別の置き場を挙げているだけなら止める")
    func declaringSomethingElseDoesNotCount() throws {
        let root = try makeSketch(
            manifest: #"resources: [.copy("shaders")],"#, assets: ["grain.png"])
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(throws: CommandFailure.self) { try ResourceDeclaration.check(in: root) }
    }

    @Test("道具で作ったスケッチは、置き場と宣言の両方を持っている")
    func theGeneratedSketchDeclaresItsAssets() throws {
        let files = try NewCommand.files(
            for: NewCommand.Options(name: "demo", path: ".", local: nil))
        let manifest = try #require(files.first { $0.0 == "Package.swift" }?.1)
        #expect(ResourceDeclaration.declares("assets", in: manifest))
        #expect(files.contains { $0.0.hasPrefix("Sources/demo/assets/") })
    }
}
