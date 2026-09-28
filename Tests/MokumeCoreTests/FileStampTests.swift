// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation
import Testing

@testable import MokumeCore

/// 更新時刻の見張り (``FileStamp``) の検査 ([#1786])。GPU を要さない。
///
/// `FileManager.attributesOfItem(atPath:)` から `lstat` へ替えたので、今までと同じ 3 つの
/// 振る舞い — 読めなければ `nil`・書き換えれば変わる・**リンクを辿らない** — を見る。
///
/// [#1786]: https://github.com/mokume-metal/mokume/issues/1786
@Suite("更新時刻の見張り")
struct FileStampTests {
    private func makeDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("mokume-file-stamp-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    @Test("無いファイルは nil")
    func missingFileHasNoStamp() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        #expect(FileStamp.of(directory.appendingPathComponent("absent.json")) == nil)
    }

    @Test("更新時刻を動かすと変わり、動かさなければ変わらない")
    func stampFollowsTheModificationTime() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("request.json")
        try Data("{}".utf8).write(to: file)
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 1_000_000)], ofItemAtPath: file.path)
        let first = try #require(FileStamp.of(file))
        #expect(FileStamp.of(file) == first)

        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 1_000_001)], ofItemAtPath: file.path)
        #expect(FileStamp.of(file) != first)
    }

    /// **リンクそのものの時刻を読む** — `attributesOfItem` がそうだったので、控えや見張りが
    /// 何を「変わった」と見るかを動かさない。
    @Test("リンクは辿らず、リンクそのものの時刻を読む")
    func doesNotFollowSymbolicLinks() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let target = directory.appendingPathComponent("target.png")
        let link = directory.appendingPathComponent("link.png")
        try Data("x".utf8).write(to: target)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 2_000_000)], ofItemAtPath: target.path)

        let expected = try #require(
            try FileManager.default.attributesOfItem(atPath: link.path)[.modificationDate] as? Date)
        let stamp = try #require(FileStamp.of(link))
        #expect(stamp.seconds == Int(expected.timeIntervalSince1970.rounded(.down)))
        #expect(stamp != FileStamp.of(target))
    }
}
