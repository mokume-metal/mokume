// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation
import MokumeTestSupport
import Testing

@testable import MokumeCore

/// 最終更新時刻で気付いて読む口。
///
/// **確定の時機がこの型の全部である。** 読む前に控えると、書きかけを 1 回掴んだだけで
/// その改訂が永久に読み飛ばされる ([#987](https://github.com/mokume-metal/mokume/issues/987)・
/// [#1048](https://github.com/mokume-metal/mokume/issues/1048))。
@Suite("更新時刻で気付いて読む")
@MainActor
struct WatchedFileTests {
    private struct Payload: Codable, Equatable {
        let revision: Int
    }

    /// ファイルを 1 つ作って渡す。
    private func withFile<T>(_ body: (URL) throws -> T) rethrows -> T {
        let directory = TestScratch.path("mokume-watched", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        return try body(directory.appendingPathComponent("payload.json"))
    }

    /// 更新時刻を据える。**置き直しても更新時刻が動かない**状況を作るために要る。
    private func place(_ bytes: String, at url: URL, _ moment: Date) throws {
        try Data(bytes.utf8).write(to: url)
        try FileManager.default.setAttributes([.modificationDate: moment], ofItemAtPath: url.path)
    }

    @Test("まだ無いファイルからは、何も返らない")
    func staysQuietWithoutTheFile() throws {
        try withFile { url in
            let file = WatchedFile<Payload>(url: url) { _ in }
            #expect(file.changed() == nil)
        }
    }

    @Test("置かれていれば読める")
    func readsWhatIsThere() throws {
        try withFile { url in
            try place(#"{"revision":1}"#, at: url, Date(timeIntervalSince1970: 1000))
            let file = WatchedFile<Payload>(url: url) { _ in }
            #expect(file.changed() == Payload(revision: 1))
        }
    }

    /// **要求が無いときのコストは、最終更新時刻を 1 回見るだけ。**
    @Test("更新時刻が動かなければ、二度は読まない")
    func readsOnlyWhenTheStampMoves() throws {
        try withFile { url in
            let moment = Date(timeIntervalSince1970: 1000)
            try place(#"{"revision":1}"#, at: url, moment)
            let file = WatchedFile<Payload>(url: url) { _ in }
            #expect(file.changed() != nil)
            #expect(file.changed() == nil)

            try place(#"{"revision":2}"#, at: url, moment.addingTimeInterval(1))
            #expect(file.changed() == Payload(revision: 2))
        }
    }

    /// **読む前に「読んだ」と記録しない。** ここが逆だと、書き手が置いている途中を 1 回
    /// 掴んだだけで、その改訂は次の書き込みまで読み飛ばされる。
    @Test("解けなかった改訂は、更新時刻が動かなくても掴み直せる")
    func doesNotSettleWhatItCouldNotDecode() throws {
        try withFile { url in
            let moment = Date(timeIntervalSince1970: 1000)
            try place(#"{"revi"#, at: url, moment)
            let file = WatchedFile<Payload>(url: url) { _ in }
            #expect(file.changed() == nil)

            // 書き手が置き終わった。**更新時刻は動かさない**
            try place(#"{"revision":7}"#, at: url, moment)
            #expect(file.changed() == Payload(revision: 7))
        }
    }

    /// 解けたら確定する。**確定しないままだと、同じ中身を毎回取り込むことになる** —
    /// 呼び手はそれを「変わった」として扱うので、顔ぶれを組み直し続ける。
    @Test("取り込めた改訂は、確定して二度は返らない")
    func settlesWhatItCouldDecode() throws {
        try withFile { url in
            let moment = Date(timeIntervalSince1970: 1000)
            try place(#"{"revi"#, at: url, moment)
            let file = WatchedFile<Payload>(url: url) { _ in }
            #expect(file.changed() == nil)

            try place(#"{"revision":7}"#, at: url, moment)
            #expect(file.changed() != nil)
            #expect(file.changed() == nil)
        }
    }

    /// **確定させないことと、黙ることは別である** ([#2889](https://github.com/mokume-metal/mokume/issues/2889))。
    /// 同じ改訂は読み直すたびには名乗らず、改訂 (更新時刻) が動いたら新しいものとして 1 度名乗る。
    @Test("解けなかった改訂は、読み直しても 1 度だけ知らせ、次の改訂ではまた知らせる")
    func reportsAnUnreadableRevisionOncePerRevision() throws {
        try withFile { url in
            let moment = Date(timeIntervalSince1970: 1000)
            try place(#"{"revi"#, at: url, moment)
            var reasons: [String] = []
            let file = WatchedFile<Payload>(url: url) { reasons.append($0.reason) }
            for _ in 0..<3 { #expect(file.changed() == nil) }
            #expect(reasons.count == 1, "\(reasons)")
            #expect(!(reasons.first ?? "").isEmpty, "理由が空")

            try place(#"{"revisi"#, at: url, moment.addingTimeInterval(1))
            for _ in 0..<3 { #expect(file.changed() == nil) }
            #expect(reasons.count == 2, "\(reasons)")
        }
    }

    /// 知らせた後も確定させない。読めた改訂では知らせない。
    @Test("知らせた後に同じ改訂が読めるようになれば取り込み、それ以降は知らせない")
    func staysQuietOnceItReads() throws {
        try withFile { url in
            let moment = Date(timeIntervalSince1970: 1000)
            try place(#"{"revi"#, at: url, moment)
            var reasons: [String] = []
            let file = WatchedFile<Payload>(url: url) { reasons.append($0.reason) }
            #expect(file.changed() == nil)
            #expect(reasons.count == 1)

            try place(#"{"revision":7}"#, at: url, moment)
            #expect(file.changed() == Payload(revision: 7))
            #expect(file.changed() == nil)
            #expect(reasons.count == 1)
        }
    }

    /// **読めなかった理由で案内が分かれる。** ファイルとして読めない (置き場がディレクトリ) のは理由だけを言い、
    /// 版の案内を付けない。解けないときだけ版のずれを候補に挙げる。
    @Test("ファイルとして読めない改訂は読めない失敗として、解けない改訂は解けない失敗として知らせる")
    func tellsApartAnUnreadableFileFromAnUndecodableOne() throws {
        try withFile { url in
            var failures: [UnreadableRevision.Failure] = []
            let file = WatchedFile<Payload>(url: url) { failures.append($0) }

            // 置き場がディレクトリ: 在るがファイルとして読めない
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            #expect(file.changed() == nil)
            #expect(file.changed() == nil)
            guard case .cannotRead? = failures.first, failures.count == 1 else {
                Issue.record("読めない失敗が 1 度だけ届いていない: \(failures)")
                return
            }
            let said = UnreadableRevision.notice(of: "The thing", at: url, failure: failures[0])
            #expect(!said.contains("mokume doctor"), "権限や置き場の事情に版の案内を付けている: \(said)")
            #expect(said.contains(url.path))

            try FileManager.default.removeItem(at: url)
            try place(#"{"revi"#, at: url, Date(timeIntervalSince1970: 2000))
            #expect(file.changed() == nil)
            guard case .cannotDecode? = failures.last, failures.count == 2 else {
                Issue.record("解けない失敗が届いていない: \(failures)")
                return
            }
            let hinted = UnreadableRevision.notice(of: "The thing", at: url, failure: failures[1])
            #expect(hinted.contains("mokume doctor") && hinted.contains("may depend"), "\(hinted)")
            #expect(hinted.contains("said once for this revision)"))
            let shared = UnreadableRevision.notice(
                of: "The thing", at: url, failure: failures[1], saidBy: "each window")
            #expect(shared.contains("by each window"), "\(shared)")
        }
    }

    /// 切れたリンクは、まだ無いファイルと同じ — 時刻が読めない (#3994) ので、知らせず確定もさせない。
    /// 置き直せば次の改訂として読む。
    @Test("切れたリンクは、知らせずに確定もさせない")
    func staysQuietOnADanglingLink() throws {
        try withFile { url in
            var told = 0
            let file = WatchedFile<Payload>(url: url) { _ in told += 1 }
            try FileManager.default.createSymbolicLink(
                atPath: url.path, withDestinationPath: url.path + ".gone")
            #expect(file.changed() == nil)
            #expect(told == 0, "消えていたファイルを名乗っている")

            try FileManager.default.removeItem(at: url)
            try place(#"{"revision":3}"#, at: url, Date(timeIntervalSince1970: 3000))
            #expect(file.changed() == Payload(revision: 3))
        }
    }

    /// 時刻を見た後、読む前に消えていた改訂は黙る。消えたことは次の改訂 (置き直し) が知らせる。確定もさせない。
    /// 時刻を見てから読むまでの隙間は検査から作れないので、改訂を与えて読む段を直に呼ぶ。
    @Test("時刻を見た後に消えていたファイルは、知らせずに確定もさせない")
    func staysQuietWhenTheFileVanishedAfterTheStamp() throws {
        try withFile { url in
            var told = 0
            let file = WatchedFile<Payload>(url: url) { _ in told += 1 }
            let seen = FileStamp(seconds: 3000, nanoseconds: 0)
            #expect(file.read(revision: seen) == nil)
            #expect(told == 0, "消えていたファイルを名乗っている")

            try place(#"{"revision":3}"#, at: url, Date(timeIntervalSince1970: 3000))
            #expect(file.changed() == Payload(revision: 3), "読めなかった改訂を確定させている")
        }
    }

    /// 循環するリンクは、在るのに辿れない。切れたリンク (無い) とは違い、**理由を 1 度名乗る** (#3994)。
    @Test("循環するリンクは読めない失敗として 1 度だけ知らせ、確定させない")
    func reportsALinkLoopOnce() throws {
        try withFile { url in
            let other = url.deletingLastPathComponent().appendingPathComponent("other.json")
            try FileManager.default.createSymbolicLink(atPath: url.path, withDestinationPath: other.path)
            try FileManager.default.createSymbolicLink(atPath: other.path, withDestinationPath: url.path)
            var failures: [UnreadableRevision.Failure] = []
            let file = WatchedFile<Payload>(url: url) { failures.append($0) }
            #expect(file.changed() == nil)
            #expect(file.changed() == nil)
            guard case .cannotRead? = failures.first, failures.count == 1 else {
                Issue.record("循環するリンクを 1 度だけ読めない失敗として名乗っていない: \(failures)")
                return
            }

            // 循環を解いて中身を置けば読む
            try FileManager.default.removeItem(at: other)
            try place(#"{"revision":4}"#, at: other, Date(timeIntervalSince1970: 4000))
            #expect(file.changed() == Payload(revision: 4))
            #expect(failures.count == 1)
        }
    }

    /// 検索の権利の無いディレクトリの中を指すリンクも、在るのに辿れない。理由を 1 度名乗る (#3994)。
    @Test("検索の権利の無い場所を指すリンクは、読めない失敗として 1 度だけ知らせる")
    func reportsALinkIntoAClosedDirectoryOnce() throws {
        try withFile { url in
            let closed = url.deletingLastPathComponent().appendingPathComponent("closed", isDirectory: true)
            try FileManager.default.createDirectory(at: closed, withIntermediateDirectories: true)
            let inside = closed.appendingPathComponent("payload.json")
            try place(#"{"revision":5}"#, at: inside, Date(timeIntervalSince1970: 5000))
            try FileManager.default.createSymbolicLink(at: url, withDestinationURL: inside)
            try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: closed.path)
            defer {
                try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: closed.path)
            }
            var failures: [UnreadableRevision.Failure] = []
            let file = WatchedFile<Payload>(url: url) { failures.append($0) }
            #expect(file.changed() == nil)
            #expect(file.changed() == nil)
            guard case .cannotRead? = failures.first, failures.count == 1 else {
                Issue.record("辿れないリンクを 1 度だけ読めない失敗として名乗っていない: \(failures)")
                return
            }

            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: closed.path)
            #expect(file.changed() == Payload(revision: 5))
        }
    }

    /// ディレクトリを指すリンクは、置き場がディレクトリのときと同じく読めない失敗として 1 度名乗る。
    @Test("ディレクトリを指すリンクは、読めない失敗として 1 度だけ知らせる")
    func reportsALinkToADirectoryOnce() throws {
        try withFile { url in
            let folder = url.deletingLastPathComponent().appendingPathComponent("folder", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try FileManager.default.createSymbolicLink(at: url, withDestinationURL: folder)
            var failures: [UnreadableRevision.Failure] = []
            let file = WatchedFile<Payload>(url: url) { failures.append($0) }
            #expect(file.changed() == nil)
            #expect(file.changed() == nil)
            guard case .cannotRead? = failures.first, failures.count == 1 else {
                Issue.record("ディレクトリを指すリンクを 1 度だけ読めない失敗として名乗っていない: \(failures)")
                return
            }
        }
    }

    /// 区画のファイルがリンクのとき、**先だけを書き換えても**次の改訂として読む (#3994)。
    /// 中身はリンクを辿って読むので、時刻も同じ先から取る。
    @Test("リンクの先を書き換えると、新しい中身を返す")
    func readsTheNewRevisionBehindALink() throws {
        try withFile { url in
            let target = url.deletingLastPathComponent().appendingPathComponent("target.json")
            try place(#"{"revision":1}"#, at: target, Date(timeIntervalSince1970: 1000))
            try FileManager.default.createSymbolicLink(at: url, withDestinationURL: target)
            var told = 0
            let file = WatchedFile<Payload>(url: url) { _ in told += 1 }
            #expect(file.changed() == Payload(revision: 1))
            #expect(file.changed() == nil)

            try place(#"{"revision":2}"#, at: target, Date(timeIntervalSince1970: 1001))
            #expect(
                file.changed() == Payload(revision: 2), "リンクの先を書き換えたのに、古い改訂のまま")

            // 先が消えている間は黙り、戻せば読む
            try FileManager.default.removeItem(at: target)
            #expect(file.changed() == nil)
            try place(#"{"revision":3}"#, at: target, Date(timeIntervalSince1970: 1002))
            #expect(file.changed() == Payload(revision: 3))
            #expect(told == 0)
        }
    }
}
