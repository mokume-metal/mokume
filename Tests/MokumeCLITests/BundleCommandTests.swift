// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation
import Testing

@testable import MokumeCLI

/// 束ねるときの組み立てと、配る前の検査。
///
/// 組み上げ自体は道具立てを呼ぶので重い。ここで見るのは**組み上がった後の並びと判定**で、
/// 実際に走るところまでの通しは ``TemplateBuildTests`` が受け持つ。
@Suite("束ねる")
struct BundleCommandTests {
    private func makeWorkspace() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("mokume-bundle-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    /// 組み上がったつもりの並び (実行ファイルと、隣に並んだ包み) を作る。
    private func makeBuildOutput(in root: URL) throws -> URL {
        let bin = root.appendingPathComponent("bin", isDirectory: true)
        let bundle = bin.appendingPathComponent("demo_demo.bundle/assets", isDirectory: true)
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        try "木目".write(
            to: bundle.appendingPathComponent("mark.txt"), atomically: true, encoding: .utf8)
        let executable = bin.appendingPathComponent("demo")
        try "#!/bin/sh\n".write(to: executable, atomically: true, encoding: .utf8)
        return executable
    }

    private let identity = AppIdentity(
        name: "Demo", identifier: "org.example.demo", version: "1.2.3")

    @Test("組み上がりが、包みの並びになる")
    func theLayoutIsAnApplicationBundle() throws {
        let root = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let executable = try makeBuildOutput(in: root)

        let app = try BundleCommand.assemble(
            executable: executable, identity: identity, minimumSystemVersion: "26.0",
            into: root.appendingPathComponent("out", isDirectory: true))

        #expect(app.lastPathComponent == "Demo.app")
        for path in ["Contents/Info.plist", "Contents/MacOS/demo", "Contents/Resources/demo_demo.bundle"] {
            #expect(
                FileManager.default.fileExists(atPath: app.appendingPathComponent(path).path),
                "包みに \(path) が無い")
        }
    }

    @Test("名乗りが、包みの一覧として書き出される")
    func theIdentityIsWrittenIntoTheBundle() throws {
        let root = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let executable = try makeBuildOutput(in: root)

        let app = try BundleCommand.assemble(
            executable: executable, identity: identity, minimumSystemVersion: "26.0",
            into: root.appendingPathComponent("out", isDirectory: true))

        let data = try Data(contentsOf: app.appendingPathComponent("Contents/Info.plist"))
        let plist =
            try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        #expect(plist?["CFBundleIdentifier"] as? String == "org.example.demo")
        #expect(plist?["CFBundleName"] as? String == "Demo")
        #expect(plist?["CFBundleExecutable"] as? String == "demo")
    }

    /// 前の版の資材が残ると、消したはずのものが配られる — しかも手元では動く。
    @Test("組み直しは、前の中身を残さない")
    func rebuildingDoesNotKeepTheOldContents() throws {
        let root = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let executable = try makeBuildOutput(in: root)
        let out = root.appendingPathComponent("out", isDirectory: true)

        let app = try BundleCommand.assemble(
            executable: executable, identity: identity, minimumSystemVersion: "26.0", into: out)
        let stale = app.appendingPathComponent("Contents/Resources/old.bundle", isDirectory: true)
        try FileManager.default.createDirectory(at: stale, withIntermediateDirectories: true)

        _ = try BundleCommand.assemble(
            executable: executable, identity: identity, minimumSystemVersion: "26.0", into: out)
        #expect(!FileManager.default.fileExists(atPath: stale.path))
    }

    @Test("宣言された包みが入っていなければ止まる")
    func aMissingDeclaredBundleStops() throws {
        let root = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let executable = try makeBuildOutput(in: root)
        let app = try BundleCommand.assemble(
            executable: executable, identity: identity, minimumSystemVersion: "26.0",
            into: root.appendingPathComponent("out", isDirectory: true))

        #expect(throws: Never.self) { try BundleCommand.check(app, contains: ["demo_demo.bundle"]) }
        #expect(throws: (any Error).self) {
            try BundleCommand.check(app, contains: ["demo_other.bundle"])
        }
    }

    @Test("宣言から、入っているべき包みの名前を導く")
    func declaredBundlesComeFromTheManifest() {
        let dump = """
            {"name":"demo","targets":[
              {"name":"demo","resources":[{"path":"assets","rule":{"copy":{}}}]},
              {"name":"other","resources":[]},
              {"name":"third"}
            ]}
            """
        #expect(BundleCommand.declaredResourceBundles(inDumpOf: dump) == ["demo_demo.bundle"])
    }

    @Test("下限の版は、パッケージの宣言から取る")
    func theMinimumVersionComesFromTheManifest() {
        let dump = """
            {"platforms":[{"platformName":"ios","version":"18.0"},
                          {"platformName":"macos","version":"26.0"}]}
            """
        #expect(BundleCommand.minimumSystemVersion(inDumpOf: dump) == "26.0")
        #expect(BundleCommand.minimumSystemVersion(inDumpOf: "{}") == nil)
    }

    /// 確かめ方まで言わないと、束ねた側の手元では成功したようにしか見えない。
    @Test("束ねた後の報せが、退避して起動する手順を含む")
    func theReportTellsHowToCheck() {
        let report = BundleCommand.report(for: URL(fileURLWithPath: "/tmp/Demo.app"))
        #expect(report.contains("/tmp/Demo.app"))
        #expect(report.contains(".build"))
    }

    @Test("置き場を渡せる")
    func theOutputDirectoryCanBeGiven() throws {
        #expect(try BundleCommand.parse(["sketch", "--out", "dist"]).out == "dist")
        #expect(try BundleCommand.parse([]).out == nil)
        #expect(throws: (any Error).self) { try BundleCommand.parse(["--out"]) }
        #expect(throws: (any Error).self) { try BundleCommand.parse(["a", "b"]) }
    }
}
