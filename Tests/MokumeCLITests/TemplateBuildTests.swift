// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation
import Testing

@testable import MokumeCLI
@testable import MokumeCore

/// ひな形から作ったものが、実際に組み上がるか。
///
/// **形を見るだけでは足りない。** ひな形の Swift が壊れていても、鍵の差し込みや
/// ファイルの並びを見る検査は緑のまま通る — 壊れたひな形が配られるのはそこである。
/// 実際に組み上げるので時間がかかるが、ここを省くと「作った人だけが気付く」形になる。
@Suite("ひな形から作ったものが組み上がる")
struct TemplateBuildTests {
    /// このリポジトリの場所。作ったスケッチはここをパスで指す (まだ版が出ていない
    /// 段階でも組み上げられるように)。
    static var repository: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // MokumeCLITests
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // リポジトリ直下
    }

    @Test("作ったスケッチが、そのまま組み上がる", .timeLimit(.minutes(5)))
    func theGeneratedSketchBuilds() throws {
        let workspace = FileManager.default.temporaryDirectory
            .appendingPathComponent("mokume-template-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workspace) }

        let options = NewCommand.Options(
            name: "try-sketch", path: workspace.path, local: Self.repository.path)
        let root = workspace.appendingPathComponent("try-sketch", isDirectory: true)
        for (path, contents) in try NewCommand.files(for: options) {
            let url = root.appendingPathComponent(path)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try contents.write(to: url, atomically: true, encoding: .utf8)
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["swift", "build"]
        process.currentDirectoryURL = root
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let output = String(
            data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        process.waitUntilExit()

        #expect(process.terminationStatus == 0, "ひな形から作ったものが組み上がらない:\n\(output)")
    }

    @Test("置いた資材が、絵を探す場所へ運ばれる", .timeLimit(.minutes(5)))
    func assetsLandWhereImagesAreLookedFor() throws {
        let workspace = FileManager.default.temporaryDirectory
            .appendingPathComponent("mokume-assets-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workspace) }

        let options = NewCommand.Options(
            name: "asset-sketch", path: workspace.path, local: Self.repository.path)
        let root = workspace.appendingPathComponent("asset-sketch", isDirectory: true)
        for (path, contents) in try NewCommand.files(for: options) {
            let url = root.appendingPathComponent(path)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try contents.write(to: url, atomically: true, encoding: .utf8)
        }

        // 作った直後のスケッチへ、資材を 1 つ置く
        let asset = root.appendingPathComponent(
            "Sources/asset-sketch/assets/grain.txt")
        try "木目".write(to: asset, atomically: true, encoding: .utf8)

        // 宣言があるので、走らせる前の検査は通る
        #expect(throws: Never.self) { try ResourceDeclaration.check(in: root) }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["swift", "build"]
        process.currentDirectoryURL = root
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let output = String(
            data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        process.waitUntilExit()
        #expect(process.terminationStatus == 0, "資材を置いたスケッチが組み上がらない:\n\(output)")

        // 実行ファイルの隣を起点に、絵を探す並びの中に運ばれた資材が入っている。
        // **ここが繋がっていないと、宣言は書かれているのに実行時に読めない**
        let executable = try RunCommand.executablePath(in: root)
        let neighbourhood = executable.deletingLastPathComponent()
        let searched = ImageFile.candidates(
            for: "assets/grain.txt", workingDirectory: root.path,
            neighbourhood: neighbourhood, resources: nil)
        let found = searched.first { FileManager.default.fileExists(atPath: $0.path) }
        #expect(
            found != nil,
            """
            置いた資材が、絵を探す場所のどこにも運ばれていない。
            探した場所:
            \(searched.map { "  - \($0.path)" }.joined(separator: "\n"))
            """)
    }
}
