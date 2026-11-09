// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Darwin
import Foundation
import MokumeTestSupport
import Testing

@testable import MokumeCore

/// 名乗りと目録 ([ADR-0049] 決定 2・3・5・[#3919])。
///
/// [ADR-0049]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0049-share-frames-to-other-processes.md
/// [#3919]: https://github.com/mokume-metal/mokume/issues/3919
@Suite("名乗りと目録")
@MainActor
struct FrameListingTests {
    // MARK: - bootstrap

    @Test("登録した名前は同じ名前空間から引け、受信の権利を手放すと引けなくなる")
    func checkInThenLookUpThenRelease() throws {
        let name = FrameAnnouncement.serviceName(pid: getpid(), window: "test")
        let receive = try Bootstrap.checkIn(name).get()
        #expect(receive != 0)
        let send = try #require(Bootstrap.lookUp(name), "登録した名前を引けない")
        Bootstrap.releaseSend(send)
        // 同じ名前の 2 度目の登録は断られる (名前は実行ごとに一意にする理由)
        if case .success(let again) = Bootstrap.checkIn(name) {
            Bootstrap.releaseReceive(again)
            Issue.record("同じ名前を 2 度登録できた")
        }
        Bootstrap.releaseReceive(receive)
        // launchd が名前を外すのは受信の権利の死を知った後なので、期限つきで待つ
        let deadline = Date().addingTimeInterval(5)
        var stillThere = true
        while Date() < deadline {
            guard let port = Bootstrap.lookUp(name) else { stillThere = false; break }
            Bootstrap.releaseSend(port)
            usleep(10_000)
        }
        #expect(!stillThere, "手放した名前がまだ引ける")
    }

    @Test("名前は実行ごとに一意で、pid とウィンドウを含む")
    func serviceNamesAreUnique() {
        let a = FrameAnnouncement.serviceName(pid: 42, window: "main")
        let b = FrameAnnouncement.serviceName(pid: 42, window: "main")
        #expect(a != b)
        #expect(a.hasPrefix("org.mokume.frames.42."))
        #expect(a.hasSuffix(".main"))
    }

    // MARK: - 名乗り

    @Test("名乗ると目録に 1 件が載り、その名前を引ける。下ろすと消える")
    func announceListsAndWithdrawRemoves() throws {
        let directory = try TestScratch.directory("mokume-frames")
        let announcement = try #require(
            FrameAnnouncement.announce(
                sketch: "Bricks", identity: "/work/Bricks", title: "Bricks and ball", in: directory,
                warn: { Issue.record("名乗れなかった: \($0)") }))
        let entries = FrameListing.entries(in: directory)
        #expect(entries == [announcement.entry])
        let entry = try #require(entries.first)
        #expect(entry.sketch == "Bricks")
        #expect(entry.window == "main")
        #expect(entry.identity == "/work/Bricks")
        #expect(entry.title == "Bricks and ball")
        #expect(entry.pid == getpid())
        #expect(entry.startedAt == ProcessRecord.startTime(of: getpid()))
        #expect(entry.schemaVersion == FrameListing.schemaVersion)
        let send = try #require(Bootstrap.lookUp(entry.serviceName), "目録の名前を引けない")
        Bootstrap.releaseSend(send)

        announcement.update(sketch: "Bricks", title: "Renamed")
        #expect(FrameListing.entries(in: directory).map(\.title) == ["Renamed"])
        #expect(FrameListing.entries(in: directory).map(\.serviceName) == [entry.serviceName])

        announcement.withdraw()
        #expect(FrameListing.entries(in: directory).isEmpty)
        #expect(announcement.isWithdrawn)
        announcement.withdraw()  // 2 度目は何もしない
    }

    /// **名乗れない環境では名乗らずに走り続け、診断に 1 行だけ出す** (App Sandbox を付けた `.app` など)。登録が
    /// 通ってから目録に置くので、断られた回は目録に何も残らない。
    @Test("登録を断られたら、目録に置かず、診断に 1 行だけ出して nil を返す")
    func aRefusedCheckInListsNothing() throws {
        let directory = try TestScratch.directory("mokume-frames")
        var said: [String] = []
        let announcement = FrameAnnouncement.announce(
            sketch: "S", identity: "/s", title: "S", in: directory, warn: { said.append($0) },
            checkIn: { _ in .failure(.refused(KERN_DENIED)) })
        #expect(announcement == nil)
        #expect(said.count == 1)
        #expect(said.first?.contains("keeps running") == true, "走り続けることを言わない: \(said)")
        #expect(FrameListing.entries(in: directory).isEmpty, "断られたのに目録に置いた")
    }

    @Test("名乗るときに、死んだ送り手の項目を掃除する")
    func announceSweepsDeadEntries() throws {
        let directory = try TestScratch.directory("mokume-frames")
        let dead = try deadProcess()
        try FrameListing.place(entry(pid: dead.pid, startedAt: dead.startedAt, name: "dead"), in: directory)
        let announcement = try #require(
            FrameAnnouncement.announce(
                sketch: "S", identity: "/s", title: "S", in: directory, warn: { _ in }))
        defer { announcement.withdraw() }
        #expect(FrameListing.entries(in: directory).map(\.serviceName) == [announcement.entry.serviceName])
    }

    // MARK: - 掃除

    @Test("掃除は、居ない pid と起動の時刻が違う pid の項目だけを消す")
    func sweepRemovesOnlyDeadEntries() throws {
        let directory = try TestScratch.directory("mokume-frames")
        let me = getpid()
        let started = try #require(ProcessRecord.startTime(of: me))
        let dead = try deadProcess()
        try FrameListing.place(entry(pid: me, startedAt: started, name: "alive"), in: directory)
        // 引けない名前でも、プロセスが生きていれば残す (別の名前空間から名乗った送り手)
        try FrameListing.place(entry(pid: me, startedAt: started, name: "elsewhere"), in: directory)
        try FrameListing.place(entry(pid: dead.pid, startedAt: dead.startedAt, name: "gone"), in: directory)
        // pid は居るが、起動の時刻が違う (pid が使い回された)
        try FrameListing.place(entry(pid: me, startedAt: started - 1, name: "reused"), in: directory)
        // 読めない項目は消さない
        try Data("not json".utf8).write(to: directory.appendingPathComponent("future.json"))

        let removed = FrameListing.sweep(in: directory)
        #expect(Set(removed) == ["gone", "reused"])
        #expect(FrameListing.entries(in: directory).map(\.serviceName) == ["alive", "elsewhere"])
        #expect(FileManager.default.fileExists(atPath: directory.appendingPathComponent("future.json").path))
    }

    // MARK: - 置き場

    @Test("検査の中では、手元の目録ではなく検査のプロセスごとの置き場を使う")
    func testsUseTheirOwnDirectory() throws {
        #expect(FrameListing.directory != FrameListing.userDirectory)
        let run = try #require(FrameListing.testRun(), "この検査のプロセスを検査と判定しない")
        #expect(FrameListing.directory == FrameListing.directory(forTestRun: run))
    }

    @Test("祖先に検査のプロセスがあれば、その pid の置き場を使う。無ければ手元の置き場")
    func ancestorsDecideTheDirectory() {
        let tree: [pid_t: (arguments: [String], parent: pid_t)] = [
            30: (["/work/.build/debug/sketch"], 20),
            20: (["/usr/local/bin/mokume", "watch"], 10),
            10: (["/usr/bin/swiftpm-testing-helper", "/w/MokumeCLITests.xctest/Contents/MacOS/MokumeCLITests"], 1),
            40: (["/bin/zsh"], 1),
            50: (["/work/.build/debug/sketch"], 40),
        ]
        let find = { (pid: pid_t) in
            FrameListing.testRun(
                from: pid, arguments: { tree[$0]?.arguments ?? [] }, parent: { tree[$0]?.parent })
        }
        #expect(find(30) == 10)
        #expect(find(10) == 10)
        #expect(find(50) == nil)
        // 輪になった答えでも止まる
        #expect(FrameListing.testRun(from: 7, arguments: { _ in [] }, parent: { $0 == 7 ? 8 : 7 }) == nil)
    }

    /// `run` の子は解いた形、`watch` の道具は渡された形でパッケージの場所を知る。そろえないと、同じ作品が起こし方で
    /// 別の作品に見える (#3919 の実走で `/tmp` と `/private/tmp` に割れた)。
    @Test("作品を見分ける欄は、シンボリックリンクを解いた形にそろう")
    func identityResolvesSymlinks() throws {
        let real = try TestScratch.directory("mokume-identity")
        let link = real.deletingLastPathComponent().appendingPathComponent("link-\(UUID().uuidString)")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
        defer { try? FileManager.default.removeItem(at: link) }
        #expect(FrameListing.identity(ofPackageAt: link) == FrameListing.identity(ofPackageAt: real))
        #expect(FrameListing.identity(ofPackageAt: URL(fileURLWithPath: "/tmp")) == "/private/tmp")
        #expect(FrameListing.identity(ofPackageAt: real).hasPrefix("/private/"), "/private を剥がした")
        // 在らない場所は、整えた形のまま
        #expect(FrameListing.identity(ofPackageAt: URL(fileURLWithPath: "/nowhere/a/../b")) == "/nowhere/b")
    }

    @Test("手元の置き場は利用者のライブラリの下で、一時の置き場ではない")
    func userDirectoryIsUnderLibrary() {
        #expect(FrameListing.userDirectory.path.hasSuffix("/Library/Application Support/mokume/frames"))
    }

    // MARK: - 補助

    private func entry(pid: pid_t, startedAt: Int64, name: String) -> FrameListing.Entry {
        FrameListing.Entry(
            sketch: "S", identity: "/s", title: "S", pid: pid, startedAt: startedAt, serviceName: name)
    }

    /// 起こして終わらせた (もう居ない) プロセスの pid と起動の時刻。
    private func deadProcess() throws -> (pid: pid_t, startedAt: Int64) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/true")
        try process.run()
        let pid = process.processIdentifier
        let started = ProcessRecord.startTime(of: pid) ?? 1
        process.waitUntilExit()
        return (pid, started)
    }
}
