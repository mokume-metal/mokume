// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation
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
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("mokume-watched-\(UUID().uuidString)", isDirectory: true)
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
            let file = WatchedFile<Payload>(url: url)
            #expect(file.changed() == nil)
        }
    }

    @Test("置かれていれば読める")
    func readsWhatIsThere() throws {
        try withFile { url in
            try place(#"{"revision":1}"#, at: url, Date(timeIntervalSince1970: 1000))
            let file = WatchedFile<Payload>(url: url)
            #expect(file.changed() == Payload(revision: 1))
        }
    }

    /// **要求が無いときのコストは、最終更新時刻を 1 回見るだけ。**
    @Test("更新時刻が動かなければ、二度は読まない")
    func readsOnlyWhenTheStampMoves() throws {
        try withFile { url in
            let moment = Date(timeIntervalSince1970: 1000)
            try place(#"{"revision":1}"#, at: url, moment)
            let file = WatchedFile<Payload>(url: url)
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
            let file = WatchedFile<Payload>(url: url)
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
            let file = WatchedFile<Payload>(url: url)
            #expect(file.changed() == nil)

            try place(#"{"revision":7}"#, at: url, moment)
            #expect(file.changed() != nil)
            #expect(file.changed() == nil)
        }
    }
}
