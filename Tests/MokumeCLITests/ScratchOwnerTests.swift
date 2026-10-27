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
        // 預けた場所の親が書けないと、権限を戻すやり直しでも消せない (権限を戻すのは預けた場所とその
        // 中だけ)。**親はこの持ち主に預けない** — 預けると、親ごと権限を戻して消してしまう
        let lockedParent = try TestScratch.directory("mokume-locked-parent")
        let stuck = lockedParent.appendingPathComponent("stuck", isDirectory: true)
        try FileManager.default.createDirectory(at: stuck, withIntermediateDirectories: true)
        owner.adopt(stuck)
        let other = try owner.directory("mokume-other")
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: lockedParent.path)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: lockedParent.path)
        }

        let failed = owner.removeAll()
        #expect(!FileManager.default.fileExists(atPath: other.path), "1 つ消せなかっただけで、残りを消さなかった")
        // root では権限が効かず、消せてしまう
        if getuid() != 0 {
            #expect(failed == [stuck], "消せなかった場所を返していない (常に空を返しても緑になる): \(failed)")
            #expect(FileManager.default.fileExists(atPath: stuck.path))
        }
    }

    /// 検査が区画を書けなくしている間にプロセスが殺されると、書き込み権の無い区画が残る (#3298)。
    private func lockedTree(in base: URL) throws -> (top: URL, inner: URL) {
        let top = base.appendingPathComponent("locked-\(UUID().uuidString)", isDirectory: true)
        let inner = top.appendingPathComponent("inner", isDirectory: true)
        try FileManager.default.createDirectory(at: inner, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: inner.appendingPathComponent("request.json"))
        // 内側から先に閉じる (外を閉じると内に入れない)
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: inner.path)
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: top.path)
        return (top, inner)
    }

    @Test("書き込み権を落とした区画も、権限を戻して消す")
    func aReadOnlyDirectoryIsRemovedAfterRestoringAccess() throws {
        let owner = try makeOwner()
        let (top, inner) = try lockedTree(in: owner.base)
        owner.adopt(top)
        defer {
            for url in [top, inner] {
                try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
            }
        }

        #expect(owner.removeAll().isEmpty, "書けない区画を消せなかった")
        #expect(!FileManager.default.fileExists(atPath: top.path))
    }

    @Test("権限を戻すとき、symlink の指す先の権限は変えない")
    func restoringAccessDoesNotFollowSymlinks() throws {
        let owner = try makeOwner()
        let target = try owner.directory("mokume-target")
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: target.path)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: target.path)
        }
        let (top, inner) = try lockedTree(in: owner.base)
        defer {
            for url in [top, inner] {
                try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
            }
        }
        // 区画の中の symlink (書けない区画の中には作れないので、権限を戻した後で作って閉じ直す)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: inner.path)
        try FileManager.default.createSymbolicLink(
            atPath: inner.appendingPathComponent("link").path, withDestinationPath: target.path)
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: inner.path)
        owner.adopt(top)

        #expect(ScratchRemoval.remove(top))
        let mode = try #require(
            FileManager.default.attributesOfItem(atPath: target.path)[.posixPermissions] as? NSNumber)
        #expect(mode.uint16Value & 0o777 == 0o500, "symlink の指す先の権限を変えた")
        #expect(FileManager.default.fileExists(atPath: target.path), "symlink の指す先を消した")
    }

    @Test("ぶら下がった symlink も、在る場所として消す")
    func aDanglingSymlinkIsRemoved() throws {
        let owner = try makeOwner()
        let link = owner.path("mokume-dangling")
        try FileManager.default.createSymbolicLink(
            atPath: link.path, withDestinationPath: owner.base.appendingPathComponent("nowhere").path)
        #expect(!FileManager.default.fileExists(atPath: link.path), "前提: 指す先が無い")
        #expect((try? FileManager.default.destinationOfSymbolicLink(atPath: link.path)) != nil)

        #expect(owner.removeAll().isEmpty)
        #expect(
            (try? FileManager.default.destinationOfSymbolicLink(atPath: link.path)) == nil,
            "symlink そのものが残った")
    }

    // MARK: - 死んだ検査の親の掃除

    private func parent(_ pid: pid_t, in base: URL, tail: String = "\(UUID().uuidString)") throws -> URL {
        let url = base.appendingPathComponent("\(ScratchSweep.prefix)\(pid)-\(tail)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: url.appendingPathComponent("request.json"))
        return url
    }

    @Test("持ち主の pid が死んでいる親だけを、中身ごと掃く。生きている親・別の接頭辞・壊れた名前は残す")
    func onlyDeadOwnersParentsAreSwept() throws {
        let base = try TestScratch.directory("mokume-sweep-check")
        // 走っているはずのない pid (macOS の pid は 99999 まで)
        let dead = try parent(4_000_021, in: base)
        let mine = try parent(getpid(), in: base)
        let others = [
            base.appendingPathComponent("mokume-picture-copies-4000021-aaaa", isDirectory: true),
            base.appendingPathComponent("mokume-observe-4000021-bbbb", isDirectory: true),
            base.appendingPathComponent("\(ScratchSweep.prefix)notapid-cccc", isDirectory: true),
            base.appendingPathComponent("\(ScratchSweep.prefix)", isDirectory: true),
            base.appendingPathComponent("\(ScratchSweep.prefix)0-dddd", isDirectory: true),
            // 符号つきは pid と読まない・UUID でない末尾・人が置いた名前は触らない
            base.appendingPathComponent("\(ScratchSweep.prefix)-5-\(UUID().uuidString)", isDirectory: true),
            base.appendingPathComponent("\(ScratchSweep.prefix)+5-\(UUID().uuidString)", isDirectory: true),
            base.appendingPathComponent("\(ScratchSweep.prefix)4000021-notes", isDirectory: true),
            base.appendingPathComponent("\(ScratchSweep.prefix)4000021-", isDirectory: true),
            base.appendingPathComponent("\(ScratchSweep.prefix)4000021", isDirectory: true),
            base.appendingPathComponent("\(ScratchSweep.prefix)4_000_021-\(UUID().uuidString)", isDirectory: true),
        ]
        for url in others {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }

        let removed = ScratchSweep.sweepDead(in: base)
        #expect(removed.map(\.lastPathComponent) == [dead.lastPathComponent])
        #expect(!FileManager.default.fileExists(atPath: dead.path), "死んだ持ち主の親が残った")
        for url in [mine] + others {
            #expect(FileManager.default.fileExists(atPath: url.path), "消してはいけない: \(url.lastPathComponent)")
        }
    }

    @Test("消せない区画を含む死んだ親も、権限を戻して掃く")
    func aDeadParentWithAReadOnlyEntryIsSwept() throws {
        let base = try TestScratch.directory("mokume-sweep-check")
        let dead = try parent(4_000_026, in: base)
        let (top, inner) = try lockedTree(in: dead)
        defer {
            for url in [top, inner] {
                try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
            }
        }

        let removed = ScratchSweep.sweepDead(in: base)
        #expect(removed.map(\.lastPathComponent) == [dead.lastPathComponent], "書けない区画のせいで、死んだ親が残った")
        #expect(!FileManager.default.fileExists(atPath: dead.path))
    }

    @Test("名前の読み方: 数字だけの pid と UUID の末尾だけを持ち主として読む")
    func ownerPidIsReadStrictly() {
        let uuid = UUID().uuidString
        #expect(ScratchSweep.ownerPid(ofName: "\(ScratchSweep.prefix)123-\(uuid)") == 123)
        #expect(ScratchSweep.ownerPid(ofName: "\(ScratchSweep.prefix)123-\(uuid.lowercased())") == 123)
        for name in [
            "\(ScratchSweep.prefix)-5-\(uuid)", "\(ScratchSweep.prefix)+5-\(uuid)",
            "\(ScratchSweep.prefix)0-\(uuid)", "\(ScratchSweep.prefix)5-x",
            "\(ScratchSweep.prefix)5-\(uuid)-extra", "\(ScratchSweep.prefix)99999999999999999999-\(uuid)",
            "mokume-picture-copies-5-\(uuid)",
        ] {
            #expect(ScratchSweep.ownerPid(ofName: name) == nil, "pid と読んだ: \(name)")
        }
    }

    @Test("生死の判定は差し替えられ、生きているとされた pid の親は掃かない")
    func theLivenessJudgementDecidesWhatIsSwept() throws {
        let base = try TestScratch.directory("mokume-sweep-check")
        let deadOne = try parent(4_000_022, in: base)
        let aliveOne = try parent(4_000_023, in: base)

        ScratchSweep.sweepDead(in: base, isAlive: { $0 == 4_000_023 })
        #expect(!FileManager.default.fileExists(atPath: deadOne.path))
        #expect(FileManager.default.fileExists(atPath: aliveOne.path), "生きているとされた親を消した")

        ScratchSweep.sweepDead(in: base, isAlive: { _ in false })
        #expect(!FileManager.default.fileExists(atPath: aliveOne.path))
    }

    @Test("既定の判定は、自分の pid を生きていると読み、居ない pid を死んでいると読む")
    func theDefaultJudgementReadsThisProcessAsAlive() {
        #expect(ScratchSweep.processExists(getpid()))
        #expect(!ScratchSweep.processExists(4_000_024))
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
    @Test("プロセスが終わると、共有の持ち主が預かった区画と親は消える。最初の使用では、死んだ検査の親を掃く")
    func theSharedOwnerCleansUpWhenTheProcessEnds() async throws {
        // 子の最初の使用が掃く対象。持ち主の pid は居ない。名前は 1 つで、別のセッションの掃除が
        // 先に消しても (この検査の前提には要らないので) 赤にならない
        let decoy = FileManager.default.temporaryDirectory.appendingPathComponent(
            "\(ScratchSweep.prefix)4000025-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: decoy, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: decoy) }

        let result = await #expect(processExitsWith: .success, observing: [\.standardOutputContent]) {
            let directory = try TestScratch.directory("mokume-exit-check")
            try Data("x".utf8).write(to: directory.appendingPathComponent("request.json"))
            let file = TestScratch.path("mokume-exit-check", pathExtension: "wav")
            try Data("riff".utf8).write(to: file)
            print("OWNED \(directory.path)")
            print("OWNED \(file.path)")
            print("OWNED \(TestScratch.root.path)")
        }
        let output = String(decoding: try #require(result).standardOutputContent, as: UTF8.self)
        let paths = output.split(separator: "\n").filter { $0.hasPrefix("OWNED ") }
            .map { String($0.dropFirst("OWNED ".count)) }
        #expect(paths.count == 3, "子が作った場所を名乗らなかった。標準出力:\n\(output)")
        for path in paths {
            #expect(!FileManager.default.fileExists(atPath: path), "子が終わったのに残っている: \(path)")
        }
        #expect(!FileManager.default.fileExists(atPath: decoy.path), "子の最初の使用が、死んだ検査の親を掃かなかった")
        // 生きている (この) 検査の親は、子の掃除に巻き込まれない
        #expect(FileManager.default.fileExists(atPath: TestScratch.root.path))
        #expect(!paths.contains(TestScratch.root.path), "子と親が同じ親を使っている")
    }
}
