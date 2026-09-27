// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Testing

@testable import MokumeCore

/// 「mokume 自身の検査の中か」の判定 (``SelfTest``・[#1682])。
///
/// **束の名前を変えると判定が黙って外れる** — 検査の中でも「外」になり、置き漏れの検めが止まらなく
/// なる。1 本目がそれを赤にする。
///
/// [#1682]: https://github.com/mokume-metal/mokume/issues/1682
@Suite("mokume の検査の中か")
struct SelfTestTests {
    @Test("この検査の中では、mokume の検査の中と判定する")
    func thisRunIsASelfTest() {
        #expect(SelfTest.isRunning, "引数: \(CommandLine.arguments)")
    }

    @Test("mokume の検査の束の実行ファイルがあれば、検査の中")
    func recognisesTheBundles() {
        for name in SelfTest.bundleNames {
            let arguments = [
                "/usr/bin/swiftpm-testing-helper", "--test-bundle-path",
                "/work/.build/debug/mokumePackageTests.xctest/../\(name).xctest/Contents/MacOS/\(name)",
                "--testing-library", "swift-testing",
            ]
            #expect(SelfTest.isRunning(arguments: arguments), "\(name)")
        }
    }

    /// 利用者が自分のパッケージの検査を回すと、プロセス名と `--testing-library` は同じく立つ。
    /// 束の名前だけが違う。
    @Test("利用者のパッケージの検査や作品の実行は、検査の中と判定しない")
    func userRunsAreNotSelfTests() {
        let userTests = [
            "/usr/bin/swiftpm-testing-helper", "--test-bundle-path",
            "/work/.build/debug/MySketchTests.xctest/Contents/MacOS/MySketchTests",
            "--testing-library", "swift-testing",
        ]
        #expect(!SelfTest.isRunning(arguments: userTests))
        #expect(!SelfTest.isRunning(arguments: ["/work/.build/debug/MySketch"]))
        #expect(!SelfTest.isRunning(arguments: ["/usr/local/bin/mokume", "run", "Sketch.swift"]))
    }
}
