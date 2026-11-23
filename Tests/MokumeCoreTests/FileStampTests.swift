// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation
import MokumeTestSupport
import Testing

@testable import MokumeCore

/// 更新時刻の見張り (``FileStamp``) の検査 ([#1786])。GPU を要さない。
///
/// 読めなければ `nil`・書き換えれば変わる・**リンクは辿り、読む先の時刻を取る** (切れたリンクは
/// `nil`) を見る。
///
/// [#1786]: https://github.com/mokume-metal/mokume/issues/1786
@Suite("更新時刻の見張り")
struct FileStampTests {
    private func makeDirectory() throws -> URL {
        let directory = TestScratch.path("mokume-file-stamp")
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

    /// **読む先の時刻を読む** — 呼び手は皆リンクを辿って中身を読むので、控えの時刻も同じ先から取る
    /// (#3994)。リンク自身の時刻を読むと、先だけを差し替えたときに控えが古いまま残る。
    @Test("リンクは辿り、先の時刻を読む。先を動かすと変わる")
    func followsSymbolicLinks() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let target = directory.appendingPathComponent("target.png")
        let link = directory.appendingPathComponent("link.png")
        try Data("x".utf8).write(to: target)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 2_000_000)], ofItemAtPath: target.path)

        let first = try #require(FileStamp.of(link))
        #expect(first == FileStamp.of(target))
        #expect(first.seconds == 2_000_000)

        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 2_000_001)], ofItemAtPath: target.path)
        #expect(FileStamp.of(link) != first, "先だけを動かしたのに、リンクの時刻が変わらない")
    }

    /// 切れたリンクは、ファイルが無いときと同じ (読む先が無い)。
    @Test("切れたリンクは nil")
    func aDanglingLinkHasNoStamp() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let link = directory.appendingPathComponent("link.png")
        try FileManager.default.createSymbolicLink(
            at: link, withDestinationURL: directory.appendingPathComponent("gone.png"))
        #expect(FileStamp.of(link) == nil)
        #expect(FileStamp.lookUp(link) == .absent, "切れたリンクを、在るのに辿れないと数えている")
    }

    /// 循環するリンクは在るのに辿れない。時刻は `nil` で、見え方はリンク自身の時刻を持つ「辿れない」。
    /// 中身を読む呼び手 (画像・書体) も、落ちずに失敗を返す。
    @Test("循環するリンクは辿れないと見え、時刻・画像・書体の読みは失敗で返る")
    func aLinkLoopIsUnreachable() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = directory.appendingPathComponent("a.png")
        let second = directory.appendingPathComponent("b.png")
        try FileManager.default.createSymbolicLink(atPath: first.path, withDestinationPath: second.path)
        try FileManager.default.createSymbolicLink(atPath: second.path, withDestinationPath: first.path)

        #expect(FileStamp.of(first) == nil)
        guard case .unreachable = FileStamp.lookUp(first) else {
            Issue.record("循環するリンクを辿れないと見ていない: \(FileStamp.lookUp(first))")
            return
        }
        #expect(ImageFile.stamp(of: first) == nil)
        #expect(throws: ImageFailure.self) { try ImageFile.decode(first.path) }
        #expect(throws: FontFailure.self) { try Font.load(first.path) }
    }

    @Test("無いファイルは「無い」と見える")
    func aMissingFileIsAbsent() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        #expect(FileStamp.lookUp(directory.appendingPathComponent("absent.json")) == .absent)
    }

    // MARK: - 要求のファイル (``RequestFile``) がリンクのとき

    private struct Probe: ExchangeRequest, Equatable {
        let id: String
    }

    /// 要求の置き場がリンクでも、先を書き換えれば次の要求として拾う。先が消えている間は拾わず、
    /// 落ちない (#3994)。
    @Test("要求のファイルがリンクのとき、先を書き換えると新しい要求を拾う")
    @MainActor
    func aLinkedRequestFilePicksUpTheTarget() throws {
        let facet = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: facet) }
        let target = facet.appendingPathComponent("elsewhere.json")
        let requests = RequestFile<Probe>(facet: facet, handover: .rereadsReport)
        try FileManager.default.createSymbolicLink(at: requests.url, withDestinationURL: target)

        // 切れている間は、何も拾わない
        #expect(requests.pending() == nil)

        try Data(#"{"id":"a"}"#.utf8).write(to: target)
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 3_000_000)], ofItemAtPath: target.path)
        #expect(requests.pending() == .request(Probe(id: "a")))
        requests.markHandled("a")
        #expect(requests.pending() == nil)

        try Data(#"{"id":"b"}"#.utf8).write(to: target)
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 3_000_001)], ofItemAtPath: target.path)
        #expect(
            requests.pending() == .request(Probe(id: "b")),
            "リンクの先を書き換えたのに、新しい要求を拾わない")
        requests.markHandled("b")

        // 先が消えると拾わない (落ちない)。戻せば次の要求を拾う
        try FileManager.default.removeItem(at: target)
        #expect(requests.pending() == nil)
        try Data(#"{"id":"c"}"#.utf8).write(to: target)
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 3_000_002)], ofItemAtPath: target.path)
        #expect(requests.pending() == .request(Probe(id: "c")))
    }
}
