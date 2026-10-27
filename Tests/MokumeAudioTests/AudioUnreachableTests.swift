// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation
import MokumeTestSupport
import Testing

@testable import MokumeAudio
@testable import MokumeCore

/// 親のフォルダに入れず、在るかを確かめられない音声ファイルを、音の読み手の名前解決 (`audioURL`) がどう断るか
/// ([#2838](https://github.com/mokume-metal/mokume/issues/2838))。
///
/// 見つからない (資源の宣言を確かめよ) とは言わず、`unopenable` で入れない場所と OS の事情を名乗る。
/// 名前を場所へ解くところだけを見るので、走らせず・GPU も要らない。
@MainActor
@Suite("辿り着けない音声ファイル")
struct AudioUnreachableTests {
    final class Bare: Sketch {
        init() {}
        func draw() {}
    }

    @Test("入れない親の下の音声は、unopenable で入れない場所を名乗り、見つからないとは言わない")
    func unreachableParentIsNamedNotMissing() throws {
        let folder = TestScratch.path("mokume-audio-unreachable")
        let assets = folder.appendingPathComponent("assets")
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: assets.path)
            try? FileManager.default.removeItem(at: folder)
        }
        try FileManager.default.createDirectory(at: assets, withIntermediateDirectories: true)
        try Data("not audio".utf8).write(to: assets.appendingPathComponent("kick.wav"))
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: assets.path)
        // root で走ると権利を外しても入れる。入れてしまうと、検査が見たいものを見ていない
        try #require(
            access(assets.appendingPathComponent("probe").path, F_OK) != 0 && errno == EACCES,
            "入れない親を作れていない")

        let name = assets.appendingPathComponent("kick.wav").path
        do {
            _ = try Bare().audioURL(name)
            Issue.record("入れない場所の音声が解けてしまった")
        } catch {
            let reason = AssetOpening.unreachableReason(String(cString: strerror(EACCES)))
            #expect(error == .unopenable(path: name, location: name, reason: reason))
            for phrase in ["was found", "Cannot find", "resources"] {
                #expect(!error.description.contains(phrase), "\(error)")
            }
        }
    }
}
