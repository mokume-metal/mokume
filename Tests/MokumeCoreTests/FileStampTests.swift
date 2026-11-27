// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation
import MokumeTestSupport
import Testing

@testable import MokumeCore

/// 改訂の印 (``FileStamp``) の検査 ([#1786])。GPU を要さない。
///
/// 読めなければ `nil`・書き換えれば変わる・**リンクは辿り、読む先の印を取る** (切れたリンクは
/// `nil`) を見る。
///
/// [#1786]: https://github.com/mokume-metal/mokume/issues/1786
@Suite("改訂の印")
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

    // MARK: - 時刻の同じ別のファイルへ読む先が替わる (#4148)

    /// 中身を置き、更新時刻を `moment` に据える。**時刻を揃えた別のファイル**を作るために要る。
    static func place(_ bytes: String, at url: URL, _ moment: Date) throws {
        try Data(bytes.utf8).write(to: url)
        try FileManager.default.setAttributes([.modificationDate: moment], ofItemAtPath: url.path)
    }

    /// `link` を `target` へ付け替える (`ln -sfn`)。
    static func repoint(_ link: URL, to target: URL) throws {
        try FileManager.default.removeItem(at: link)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
    }

    /// 大きさも時刻も同じで中身だけが違うファイルへの付け替えは、別の印 (inode が違う)。
    @Test("リンクを、時刻と大きさの同じ別のファイルへ付け替えると変わる")
    func repointingALinkToAnotherFileWithTheSameTimeChanges() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let moment = Date(timeIntervalSince1970: 4_000_000)
        let first = directory.appendingPathComponent("a.json")
        let second = directory.appendingPathComponent("b.json")
        try Self.place("aaaa", at: first, moment)
        try Self.place("bbbb", at: second, moment)
        let link = directory.appendingPathComponent("link.json")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: first)

        let before = try #require(FileStamp.of(link))
        try Self.repoint(link, to: second)
        #expect(FileStamp.of(link) != before, "時刻の同じ別のファイルへ付け替えたのに、同じ印のまま")
    }

    /// 時刻を保った写しを `rename` で置き換える (`cp -p b tmp && mv tmp a`) と、名前は同じでも別のファイル。
    @Test("時刻を保った写しを rename で置き換えると変わる")
    func renamingACopyWithTheSameTimeOverTheFileChanges() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let moment = Date(timeIntervalSince1970: 4_000_000)
        let file = directory.appendingPathComponent("a.json")
        let copy = directory.appendingPathComponent("tmp.json")
        try Self.place("aaaa", at: file, moment)
        let before = try #require(FileStamp.of(file))

        try Self.place("bbbb", at: copy, moment)
        #expect(rename(copy.path, file.path) == 0)
        #expect(FileStamp.of(file) != before, "時刻の同じ写しで置き換えたのに、同じ印のまま")
    }

    /// 同じファイルを書き換えて時刻だけを戻しても、大きさが違えば別の印。
    @Test("同じファイルを書き換えて時刻を戻しても、大きさが変われば変わる")
    func rewritingInPlaceWithAnotherSizeChanges() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let moment = Date(timeIntervalSince1970: 4_000_000)
        let file = directory.appendingPathComponent("a.json")
        try Self.place("aaaa", at: file, moment)
        let before = try #require(FileStamp.of(file))

        try Self.place("aaaaaa", at: file, moment)
        #expect(FileStamp.of(file) != before, "大きさが変わったのに、同じ印のまま")
    }

    /// 同じファイル (同じ inode) を同じ大きさで書き換え、更新時刻を手で戻しても、状態変更時刻 (ctime) は
    /// 戻せないので別の印。
    @Test("同じファイルを同じ大きさで書き換え、時刻を戻しても変わる")
    func rewritingInPlaceWithTheSameSizeAndTimeChanges() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let moment = Date(timeIntervalSince1970: 4_000_000)
        let file = directory.appendingPathComponent("a.json")
        try Self.place("aaaa", at: file, moment)
        let before = try #require(FileStamp.of(file))

        try Self.place("bbbb", at: file, moment)
        let after = try #require(FileStamp.of(file))
        #expect(
            after.seconds == before.seconds && after.nanoseconds == before.nanoseconds && after.size == before.size
                && after.inode == before.inode,
            "前提: 更新時刻・大きさ・inode は揃っている")
        #expect(after != before, "同じ大きさで書き換えて時刻を戻したのに、同じ印のまま")
    }

    /// 中身に触れない属性の変更 (権限) も状態変更時刻を進めるので、別の印になる。**読み直すだけで、
    /// 古い中身を返す側には倒れない** (説明文に書いた代償)。
    @Test("権限だけを変えても変わる (読み直すだけの代償)")
    func changingOnlyThePermissionsChanges() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("a.json")
        try Self.place("aaaa", at: file, Date(timeIntervalSince1970: 4_000_000))
        let before = try #require(FileStamp.of(file))

        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        #expect(FileStamp.of(file) != before)
    }

    /// 在るのに辿れないリンクの改訂も、同じ欄 (リンク自身の inode など) で見分ける。
    @Test("辿れないリンクを、時刻の同じ別のリンクに置き換えると、別の改訂に見える")
    func replacingAnUnreachableLinkWithTheSameTimeChanges() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = directory.appendingPathComponent("a.json")
        let second = directory.appendingPathComponent("b.json")
        try FileManager.default.createSymbolicLink(atPath: first.path, withDestinationPath: second.path)
        try FileManager.default.createSymbolicLink(atPath: second.path, withDestinationPath: first.path)
        let times = [timeval(tv_sec: 5_000_000, tv_usec: 0), timeval(tv_sec: 5_000_000, tv_usec: 0)]
        #expect(lutimes(first.path, times) == 0)
        guard case .unreachable(let before) = FileStamp.lookUp(first) else {
            Issue.record("循環するリンクを辿れないと見ていない: \(FileStamp.lookUp(first))")
            return
        }

        try FileManager.default.removeItem(at: first)
        try FileManager.default.createSymbolicLink(atPath: first.path, withDestinationPath: second.path)
        #expect(lutimes(first.path, times) == 0)
        guard case .unreachable(let after) = FileStamp.lookUp(first) else {
            Issue.record("置き換えた循環するリンクを辿れないと見ていない: \(FileStamp.lookUp(first))")
            return
        }
        #expect(before.seconds == after.seconds && before.nanoseconds == after.nanoseconds)
        #expect(after != before, "時刻の同じ別のリンクに置き換えたのに、同じ改訂のまま")
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

    /// 要求の置き場のリンクを、時刻の同じ別の要求へ付け替えても、次の要求として拾う (#4148)。
    @Test("要求のファイルのリンクを、時刻の同じ別の要求へ付け替えると拾う")
    @MainActor
    func aRequestLinkRepointedToAnotherFileWithTheSameTimeIsPickedUp() throws {
        let facet = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: facet) }
        let moment = Date(timeIntervalSince1970: 6_000_000)
        let first = facet.appendingPathComponent("first.json")
        let second = facet.appendingPathComponent("second.json")
        try Self.place(#"{"id":"a"}"#, at: first, moment)
        try Self.place(#"{"id":"b"}"#, at: second, moment)
        let requests = RequestFile<Probe>(facet: facet, handover: .rereadsReport)
        try FileManager.default.createSymbolicLink(at: requests.url, withDestinationURL: first)

        #expect(requests.pending() == .request(Probe(id: "a")))
        requests.markHandled("a")
        #expect(requests.pending() == nil)

        try Self.repoint(requests.url, to: second)
        #expect(
            requests.pending() == .request(Probe(id: "b")),
            "時刻の同じ別の要求へ付け替えたのに、新しい要求を拾わない")
    }
}
