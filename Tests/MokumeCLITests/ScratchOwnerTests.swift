// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation
import MokumeTestSupport
import Testing

/// 検査の一時の区画の持ち主 (``ScratchOwner``・#3298)。
///
/// **持ち主は別に立てる** — 全検査が分け持つ ``TestScratch/owner`` の `removeAll()` を呼ぶと、
/// 並走する他の検査の区画まで消す。ここの持ち主の親 (`base`) は、検査ごとの空の区画にする。
@Suite("検査の一時の区画の持ち主")
struct ScratchOwnerTests {
    /// 持ち主ごとの親。この親そのものも共有の持ち主 (``TestScratch``) が見ている。
    private func makeOwner() throws -> ScratchOwner {
        ScratchOwner(base: try TestScratch.directory("mokume-scratch-owner"))
    }

    @Test("作った区画は親の直下に在り、後始末で消える。何度作っても残らない")
    func aDirectoryIsRemovedWithItsOwner() throws {
        let owner = try makeOwner()
        let first = try owner.directory("mokume-mcp")
        let second = try owner.directory("mokume-mcp")
        #expect(first != second)
        #expect(first.deletingLastPathComponent().standardizedFileURL == owner.base.standardizedFileURL)
        try Data("x".utf8).write(to: first.appendingPathComponent("request.json"))
        #expect(FileManager.default.fileExists(atPath: first.path))

        #expect(owner.removeAll().isEmpty)
        #expect(!FileManager.default.fileExists(atPath: first.path), "中身ごと消えていない")
        #expect(!FileManager.default.fileExists(atPath: second.path))
        // 親の中に何も残らない (持ち主が作ったものだけを数える)
        #expect(try FileManager.default.contentsOfDirectory(atPath: owner.base.path).isEmpty)
    }

    @Test("検査が途中で throw しても、作った区画は後始末の対象に載っている")
    func aDirectoryCreatedBeforeAThrowIsStillOwned() throws {
        struct Boom: Error {}
        let owner = try makeOwner()
        func failingTest() throws {
            _ = try owner.directory("mokume-store")
            throw Boom()
        }
        #expect(throws: Boom.self) { try failingTest() }
        let names = try FileManager.default.contentsOfDirectory(atPath: owner.base.path)
        #expect(names.count == 1, "throw の前に作った区画が見つからない: \(names)")
        let url = owner.base.appendingPathComponent(try #require(names.first))
        #expect(FileManager.default.fileExists(atPath: url.path))
        #expect(owner.count == 1)
        owner.removeAll()
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }

    @Test("場所だけの登録は作らず、拡張子を持てる。書かれなくても後始末は失敗しない")
    func aPathIsRegisteredWithoutBeingCreated() throws {
        let owner = try makeOwner()
        let unwritten = owner.path("mokume-sound", pathExtension: "wav")
        let written = owner.path("mokume-sound", pathExtension: "wav")
        #expect(unwritten.pathExtension == "wav")
        #expect(unwritten.lastPathComponent.hasPrefix("mokume-sound-"))
        #expect(!FileManager.default.fileExists(atPath: unwritten.path), "登録しただけで作った")
        try Data("riff".utf8).write(to: written)

        #expect(owner.removeAll().isEmpty, "書かれなかった場所を失敗に数えた")
        #expect(!FileManager.default.fileExists(atPath: written.path))
    }

    @Test("検査が自分で先に消した場所は、後始末の失敗に数えない")
    func aPathRemovedByTheTestIsNotAFailure() throws {
        let owner = try makeOwner()
        let url = try owner.directory("mokume-input")
        try FileManager.default.removeItem(at: url)
        #expect(owner.removeAll().isEmpty)
    }

    @Test("消せない場所があっても、残りは消し、消せなかった場所を返す")
    func anUnremovableEntryDoesNotStopTheRest() throws {
        let owner = try makeOwner()
        let locked = try owner.directory("mokume-locked")
        let inside = locked.appendingPathComponent("inner", isDirectory: true)
        try FileManager.default.createDirectory(at: inside, withIntermediateDirectories: true)
        let other = try owner.directory("mokume-other")
        // 親を書けなくすると、中の項目を消せない
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: locked.path)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: locked.path)
        }

        let failed = owner.removeAll()
        #expect(!FileManager.default.fileExists(atPath: other.path), "1 つ消せなかっただけで、残りを消さなかった")
        #expect(
            failed.map(\.lastPathComponent).allSatisfy { $0.hasPrefix("mokume-locked-") },
            "消せなかった場所の名乗りが違う: \(failed)")
    }

    @Test("名前を決める場所と、別の方法で作った場所も預けられる")
    func namedAndAdoptedPathsAreOwned() throws {
        let owner = try makeOwner()
        let named = owner.path(named: "mokume-svg-\(UUID().uuidString)-a.svg")
        try Data("<svg/>".utf8).write(to: named)
        let adopted = owner.base.appendingPathComponent("adopted", isDirectory: true)
        try FileManager.default.createDirectory(at: adopted, withIntermediateDirectories: true)
        owner.adopt(adopted)

        #expect(owner.removeAll().isEmpty)
        #expect(!FileManager.default.fileExists(atPath: named.path))
        #expect(!FileManager.default.fileExists(atPath: adopted.path))
        #expect(owner.count == 0, "後始末した分を持ち続けている")
    }

    /// **全検査が分け持つ持ち主 (``TestScratch``) は、プロセスの終わりに預かった区画を消す。**
    /// 1 本の検査の中からは「終わり」が見えないので、子のプロセス (exit test) に区画を作らせ、
    /// 子が終わった後の親から見る。後始末を `atexit` へ頼む 1 行を外すと、ここだけが赤くなる。
    @Test("プロセスが終わると、共有の持ち主が預かった区画は中身ごと消える")
    func theSharedOwnerCleansUpWhenTheProcessEnds() async throws {
        let result = await #expect(processExitsWith: .success, observing: [\.standardOutputContent]) {
            let directory = try TestScratch.directory("mokume-exit-check")
            try Data("x".utf8).write(to: directory.appendingPathComponent("request.json"))
            let file = TestScratch.path("mokume-exit-check", pathExtension: "wav")
            try Data("riff".utf8).write(to: file)
            print("OWNED \(directory.path)")
            print("OWNED \(file.path)")
        }
        let output = String(decoding: try #require(result).standardOutputContent, as: UTF8.self)
        let paths = output.split(separator: "\n").filter { $0.hasPrefix("OWNED ") }
            .map { String($0.dropFirst("OWNED ".count)) }
        #expect(paths.count == 2, "子が作った場所を名乗らなかった。標準出力:\n\(output)")
        for path in paths {
            #expect(!FileManager.default.fileExists(atPath: path), "子が終わったのに残っている: \(path)")
        }
    }
}
