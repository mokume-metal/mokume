// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation
import MokumeTestSupport
import Testing

@testable import MokumeCLI

/// 道具が自分の版を名乗るところ。
///
/// **在処から導く。** 版をソースに定数で持つとリリースがファイルを変えることになるので
/// (`scripts/release.py` の冒頭)、実行ファイルの置かれ方から読む (#634)。
@Suite("道具の版")
struct ToolVersionTests {
    private func url(_ path: String) -> URL { URL(fileURLWithPath: path) }

    @Test("Homebrew の在処からは版が読める")
    func readsTheVersionFromTheCellarPath() {
        let text = ToolVersion.describe(
            executable: url("/opt/homebrew/Cellar/mokume/0.5.0/libexec/mokume"),
            modified: nil)
        #expect(text.contains("0.5.0"))
        #expect(text.contains("Homebrew"))
    }

    @Test("版が読めない在処では、手元ビルドと名乗る")
    func namesALocalBuild() {
        let stamp = Date(timeIntervalSince1970: 1_756_000_000)
        let text = ToolVersion.describe(executable: url("/tmp/x/.build/debug/mokume-cli"), modified: stamp)
        #expect(text.contains("local build"))
        #expect(!text.contains("Homebrew"))
    }

    @Test("手元ビルドには、いつ組まれたかを添える")
    func addsTheBuildTimeToALocalBuild() {
        let stamp = Date(timeIntervalSince1970: 1_756_000_000)
        let text = ToolVersion.describe(executable: url("/tmp/x/.build/debug/mokume-cli"), modified: stamp)
        // 書式は ``Timestamp`` に任せる。固定すると、読みやすさを直すたびに検査が落ちる。
        // ただし**渡した時刻であること**は見る — 年だけ見ていた頃は、現在時刻を出しても
        // 通った (#2281)
        #expect(text.contains(Timestamp.text(stamp)), "\(text)")
    }

    @Test("日時が読めなければ、そこだけ判定できずと言う")
    func doesNotGuessTheBuildTime() {
        let text = ToolVersion.describe(executable: url("/tmp/x/.build/debug/mokume-cli"), modified: nil)
        #expect(text.contains("local build"))
        #expect(text.contains(DoctorCommand.unknown))
    }

    @Test("Cellar の下でも、版の形をしていなければ読まない")
    func requiresAVersionShapedComponent() {
        // 名前の直後が版でない配置 (自分で並べた場所など) を Homebrew と誤って名乗らない
        let text = ToolVersion.describe(
            executable: url("/opt/homebrew/Cellar/mokume/HEAD/libexec/mokume"), modified: nil)
        #expect(!text.contains("Homebrew"))
    }

    // MARK: - 配布物が同梱する版 (#2887)

    private let sha = "e48a07f684804fc687269f1b929ebf1bc10fbd4f"

    /// 実行ファイルと、その隣の同梱ファイル (`contents` が `nil` なら置かない) を、一時の場所へ作る。
    /// `under` はその下の経路 (Cellar の配置を作るのに使う)。
    private func place(
        release contents: String?, under path: [String] = []
    ) throws -> (executable: URL, cleanup: () -> Void) {
        let root = TestScratch.path("mokume-toolversion", isDirectory: true)
        let directory = path.reduce(root) { $0.appendingPathComponent($1, isDirectory: true) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let executable = directory.appendingPathComponent("mokume")
        try "#!/bin/sh\n".write(to: executable, atomically: true, encoding: .utf8)
        if let contents {
            try contents.write(
                to: directory.appendingPathComponent(ToolVersion.releaseFileName),
                atomically: true, encoding: .utf8)
        }
        return (executable, { try? FileManager.default.removeItem(at: root) })
    }

    @Test("同梱の 1 行ファイルがあれば、版と短い SHA を名乗る")
    func namesTheShippedRelease() throws {
        let (executable, cleanup) = try place(release: "v0.29.0 \(sha)\n")
        defer { cleanup() }
        let text = ToolVersion.describe(executable: executable, modified: nil)
        #expect(text == "0.29.0 (release e48a07f)")
        #expect(ToolVersion.releaseVersion(in: executable) == "0.29.0")
    }

    @Test("同梱の 1 行ファイルが無ければ、今までどおり手元ビルド")
    func withoutTheFileItIsStillALocalBuild() throws {
        let (executable, cleanup) = try place(release: nil)
        defer { cleanup() }
        let text = ToolVersion.describe(executable: executable, modified: nil)
        #expect(text.hasPrefix("local build"))
        #expect(ToolVersion.releaseVersion(in: executable) == nil)
    }

    @Test(
        "空・形が壊れた中身は版として名乗らず、手元ビルドに戻る",
        arguments: [
            "", "\n", "v0.29.0\n", "v0.29.0 xyz\n", "v0.29.0 e48a07\n",
            "latest e48a07f684804fc687269f1b929ebf1bc10fbd4f\n",
            "v0.29.0 e48a07f684804fc687269f1b929ebf1bc10fbd4f extra\n",
            "v0.29.0 e48a07f684804fc687269f1b929ebf1bc10fbd4f00\n",
            "vv0.29.0 e48a07f684804fc687269f1b929ebf1bc10fbd4f\n",
        ])
    func aBrokenFileIsNotAVersion(contents: String) throws {
        let (executable, cleanup) = try place(release: contents)
        defer { cleanup() }
        #expect(ToolVersion.describe(executable: executable, modified: nil).hasPrefix("local build"))
        #expect(ToolVersion.releaseVersion(in: executable) == nil)
    }

    @Test("同梱のファイルがあれば、Homebrew の置き場でも版は配布物のもので、置き場は経路として名乗る")
    func theShippedVersionWinsInTheCellar() throws {
        let (executable, cleanup) = try place(
            release: "v0.29.0 \(sha)\n", under: ["Cellar", "mokume", "0.29.0_1", "libexec"])
        defer { cleanup() }
        #expect(ToolVersion.describe(executable: executable, modified: nil) == "0.29.0 (Homebrew)")
        #expect(ToolVersion.releaseVersion(in: executable) == "0.29.0")
    }

    @Test("同梱のファイルが壊れていれば、Homebrew の置き場は今までどおり置き場の版を名乗る")
    func aBrokenFileFallsBackToTheCellar() throws {
        let (executable, cleanup) = try place(
            release: "garbage\n", under: ["Cellar", "mokume", "0.5.0", "libexec"])
        defer { cleanup() }
        #expect(ToolVersion.describe(executable: executable, modified: nil) == "0.5.0 (Homebrew)")
    }

    @Test("展開した場所を別のディレクトリへ移しても、同じ名乗りになる")
    func movingTheDirectoryKeepsTheName() throws {
        let (executable, cleanup) = try place(release: "v0.29.0 \(sha)\n", under: ["here"])
        defer { cleanup() }
        let before = ToolVersion.describe(executable: executable, modified: nil)
        let moved = executable.deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("elsewhere", isDirectory: true)
        try FileManager.default.moveItem(at: executable.deletingLastPathComponent(), to: moved)
        let after = ToolVersion.describe(
            executable: moved.appendingPathComponent("mokume"), modified: nil)
        #expect(before == "0.29.0 (release e48a07f)")
        #expect(after == before)
    }

    @Test("版の書き方: v は付けても付けなくてもよく、SHA は 7〜40 文字の 16 進")
    func parsesTheFileShape() {
        #expect(ToolVersion.parseRelease("0.29.0 \(sha)") == .init(version: "0.29.0", commit: "e48a07f"))
        #expect(ToolVersion.parseRelease("v1.0.0-rc.1 E48A07F") == .init(version: "1.0.0-rc.1", commit: "e48a07f"))
        #expect(ToolVersion.parseRelease("v0.29.0 e48a07") == nil)
    }
}
