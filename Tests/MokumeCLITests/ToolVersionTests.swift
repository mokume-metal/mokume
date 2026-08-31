// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation
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
        #expect(text.contains("手元ビルド"))
        #expect(!text.contains("Homebrew"))
    }

    @Test("手元ビルドには、いつ組まれたかを添える")
    func addsTheBuildTimeToALocalBuild() {
        let stamp = Date(timeIntervalSince1970: 1_756_000_000)
        let text = ToolVersion.describe(executable: url("/tmp/x/.build/debug/mokume-cli"), modified: stamp)
        // 年だけ見る。書式そのものを固定すると、読みやすさを直すたびに検査が落ちる
        #expect(text.contains("2025") || text.contains("2026"))
    }

    @Test("日時が読めなければ、そこだけ判定できずと言う")
    func doesNotGuessTheBuildTime() {
        let text = ToolVersion.describe(executable: url("/tmp/x/.build/debug/mokume-cli"), modified: nil)
        #expect(text.contains("手元ビルド"))
        #expect(text.contains(DoctorCommand.unknown))
    }

    @Test("Cellar の下でも、版の形をしていなければ読まない")
    func requiresAVersionShapedComponent() {
        // 名前の直後が版でない配置 (自分で並べた場所など) を Homebrew と誤って名乗らない
        let text = ToolVersion.describe(
            executable: url("/opt/homebrew/Cellar/mokume/HEAD/libexec/mokume"), modified: nil)
        #expect(!text.contains("Homebrew"))
    }
}
