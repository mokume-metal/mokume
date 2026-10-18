// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation
import MokumeDiagnostics
import Testing

@testable import MokumeCore

/// OS の事情 (POSIX の失敗の番号) を人が読む文にする所を 1 つにする ([#2839])。
///
/// **同じ事情は、どの口でも同じ C の文面で名乗る。** 読む側 (`unopenable`) と書く側 (`unwritable`)・
/// URL (`unreachable`)・``Diagnostics/reason(_:)`` で作り方が割れていると、同じ `Is a directory` が
/// 口によって別の文面になり、書く側などは言語の設定に左右されうる (`localizedDescription`)。
///
/// 言語の設定を日本語にして確かめる代わりに、**偽の説明 (`NSLocalizedDescriptionKey`) を持たせた
/// 失敗**を渡す。この機械の検査の走り手は、言語の設定が日本語でも地域化を持たないので
/// `localizedDescription` が英語のまま返り、設定を変えても違いが見えないためである。偽の説明が
/// 出てこなければ、`localizedDescription` を通っていない。
///
/// [#2839]: https://github.com/mokume-metal/mokume/issues/2839
@Suite("OS の事情の文面")
struct PosixReasonTests {
    /// 偽の説明。`localizedDescription` を通ると、これが文面に出る。
    static let fake = "FAKE LOCALIZED DESCRIPTION"

    /// Foundation のファイルの失敗の形 (Cocoa の失敗の下に POSIX の失敗) を、偽の説明付きで作る。
    /// `depth` は POSIX の失敗までの段の数。
    static func nested(_ code: Int32, depth: Int = 1) -> NSError {
        var failure = NSError(
            domain: NSPOSIXErrorDomain, code: Int(code), userInfo: [NSLocalizedDescriptionKey: fake])
        for _ in 0..<depth {
            failure = NSError(
                domain: NSCocoaErrorDomain, code: NSFileWriteUnknownError,
                userInfo: [NSLocalizedDescriptionKey: fake, NSUnderlyingErrorKey: failure])
        }
        return failure
    }

    @Test(
        "代表の番号は C の文面、引けない番号は error <番号> になる",
        arguments: [EISDIR, EACCES, ENOENT])
    func representativeCodes(_ code: Int32) {
        #expect(Diagnostics.posixReason(code) == String(cString: strerror(code)))
    }

    @Test("範囲の外の番号は error <番号> になる")
    func outOfRangeCode() {
        #expect(Diagnostics.posixReason(100_000) == "error 100000")
    }

    @Test("POSIX の番号は、失敗そのものからも、下の失敗を辿った先からも取り出す")
    func codeIsFoundAtAnyDepth() {
        #expect(Diagnostics.posixCode(in: Self.nested(EISDIR, depth: 0)) == EISDIR)
        #expect(Diagnostics.posixCode(in: Self.nested(EACCES, depth: 1)) == EACCES)
        #expect(Diagnostics.posixCode(in: Self.nested(ENOENT, depth: 3)) == ENOENT)
        #expect(Diagnostics.posixCode(in: URLError(.cannotConnectToHost)) == nil)
    }

    @Test("POSIX の領域でも Int32 に収まらない番号は、落ちずに POSIX として扱わない")
    func codeOutsideInt32IsNotPosix() {
        let huge = NSError(
            domain: NSPOSIXErrorDomain, code: Int(Int32.max) + 1, userInfo: [NSLocalizedDescriptionKey: Self.fake])
        #expect(Diagnostics.posixCode(in: huge) == nil)
        #expect(Diagnostics.failureText(huge) == Self.fake)
    }

    @Test("HTTP の状態の句は、地域化されない RFC の句か、百の位の分類")
    func statusPhrasesAreNotLocalized() {
        #expect(WebFile.statusPhrase(404) == "Not Found")
        #expect(WebFile.statusPhrase(503) == "Service Unavailable")
        #expect(WebFile.statusPhrase(499) == "client error")
        #expect(WebFile.statusPhrase(599) == "server error")
    }

    @Test("Diagnostics.reason は、下に POSIX の事情があれば C の文面、無ければ今の説明のまま")
    func diagnosticsReason() {
        let reason = Diagnostics.reason(Self.nested(EISDIR, depth: 2))
        #expect(reason == "NSCocoaErrorDomain \(NSFileWriteUnknownError): Is a directory")
        #expect(!reason.contains(Self.fake))
        let foreign = NSError(domain: NSCocoaErrorDomain, code: 4, userInfo: [NSLocalizedDescriptionKey: Self.fake])
        #expect(Diagnostics.reason(foreign) == "NSCocoaErrorDomain 4: \(Self.fake)")
    }

    @Test("URL から受け取れない事情は、下に POSIX の事情があれば C の文面、受け口の失敗は今の説明のまま")
    func webReason() {
        let url = "https://posix.test/data"
        #expect(
            WebFile.failure(of: Self.nested(ECONNREFUSED), path: url, limit: .seconds(60))
                == .unreachable(url: url, reason: String(cString: strerror(ECONNREFUSED))))
        let refused = URLError(.cannotConnectToHost)
        #expect(
            WebFile.failure(of: refused, path: url, limit: .seconds(60))
                == .unreachable(url: url, reason: refused.localizedDescription))
    }

    // MARK: - 書く側

    final class Bare: Sketch {
        init() {}
        func draw() {}
    }

    /// 書き出しの置き場。外した権利は `defer` で戻す。
    static func folder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("mokume-posix-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    static func table(in folder: URL) throws -> Table {
        let source = folder.appendingPathComponent("in.csv")
        try Data("a,b\n1,2\n".utf8).write(to: source)
        return try Bare().loadTable(source.path, header: true)
    }

    @Test("ディレクトリへ書くと unwritable の理由が Is a directory で、読む側の unopenable と同じ語になる")
    func writingOntoDirectoryNamesIt() throws {
        let folder = try Self.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let table = try Self.table(in: folder)
        let out = folder.appendingPathComponent("out.csv")
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: false)

        let written = #expect(throws: DataFailure.self) { try Bare().saveTable(table, out.path) }
        #expect(written == .unwritable(path: out.path, reason: String(cString: strerror(EISDIR))))
        let read = #expect(throws: DataFailure.self) { _ = try Bare().loadTable(out.path, header: true) }
        guard case .unwritable(_, let writeReason) = written, case .unopenable(_, _, let readReason) = read else {
            Issue.record("書く側か読む側の case が違う: \(String(describing: written)) / \(String(describing: read))")
            return
        }
        #expect(writeReason == readReason)
    }

    /// 書く権利の無い置き場の中の、ディレクトリを指す symlink へ書く。下の失敗は書く権利の無さ
    /// (EACCES) で、`Is a directory` と偽らない (symlink を辿って行き先を見ると偽る)。
    @Test("書く権利の無い置き場の、ディレクトリを指す symlink へ書くと、Permission denied のまま")
    func writingOntoLinkToDirectoryInLockedFolder() throws {
        let folder = try Self.folder()
        let elsewhere = try Self.folder()
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: folder.path)
            try? FileManager.default.removeItem(at: folder)
            try? FileManager.default.removeItem(at: elsewhere)
        }
        let table = try Self.table(in: elsewhere)
        let out = folder.appendingPathComponent("out.csv")
        try FileManager.default.createSymbolicLink(at: out, withDestinationURL: elsewhere)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: folder.path)
        try #require(!FileManager.default.isWritableFile(atPath: folder.path), "書く権利を外せていない")

        let written = #expect(throws: DataFailure.self) { try Bare().saveTable(table, out.path) }
        #expect(written == .unwritable(path: out.path, reason: String(cString: strerror(EACCES))))
    }

    @Test("書く権利の無い置き場へ書くと、unwritable の理由は C の文面 (Permission denied)")
    func writingWithoutPermissionNamesIt() throws {
        let folder = try Self.folder()
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: folder.path)
            try? FileManager.default.removeItem(at: folder)
        }
        let table = try Self.table(in: folder)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: folder.path)
        // root で走ると権利を外しても書ける。書けてしまうと、検査が見たいものを見ていない
        try #require(!FileManager.default.isWritableFile(atPath: folder.path), "書く権利を外せていない")

        let out = folder.appendingPathComponent("out.csv").path
        let written = #expect(throws: DataFailure.self) { try Bare().saveTable(table, out) }
        #expect(written == .unwritable(path: out, reason: String(cString: strerror(EACCES))))
    }
}
