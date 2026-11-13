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

    // MARK: - 受け付ける面の大きさ (#3949)

    /// **大きさは任意の欄** ([#3949])。載せた項目には鍵が増え、載せない項目 (旧い送り手と同じ形) には鍵ごと無い。
    ///
    /// [#3949]: https://github.com/mokume-metal/mokume/issues/3949
    @Test("大きさを添えて名乗ると最初の 1 件から載り、変わると書き換わる。添えなければ鍵ごと無い")
    func theSizeIsListedAndRewritten() throws {
        let directory = try TestScratch.directory("mokume-frames")
        let announcement = try #require(
            FrameAnnouncement.announce(
                sketch: "Bricks", identity: "/work/Bricks", title: "Bricks", width: 173, height: 97, in: directory,
                warn: { Issue.record("名乗れなかった: \($0)") }))
        defer { announcement.withdraw() }
        let file = FrameListing.url(for: announcement.entry.serviceName, in: directory)
        func written() throws -> [String: Any] {
            try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        }
        #expect(try written()["width"] as? Int == 173)
        #expect(try written()["height"] as? Int == 97)
        #expect(FrameListing.entries(in: directory).map(\.width) == [173])

        announcement.recordSize(width: 211, height: 103)
        #expect(FrameListing.entries(in: directory).map { [$0.width, $0.height] } == [[211, 103]])

        // 題を書き換えても大きさは残る
        announcement.update(sketch: "Bricks", title: "Renamed")
        #expect(FrameListing.entries(in: directory).map { [$0.width, $0.height] } == [[211, 103]])

        // 添えない名乗り (と、片方だけの名乗り) は、旧い送り手と同じく鍵ごと書かない
        let unsized = try #require(
            FrameAnnouncement.announce(
                sketch: "Old", identity: "/work/Old", title: "Old", width: 16, in: directory,
                warn: { Issue.record("名乗れなかった: \($0)") }))
        defer { unsized.withdraw() }
        let old = try #require(
            try JSONSerialization.jsonObject(
                with: Data(contentsOf: FrameListing.url(for: unsized.entry.serviceName, in: directory)))
                as? [String: Any])
        #expect(old["width"] == nil && old["height"] == nil, "大きさの無い項目に鍵を書いた: \(old)")
    }

    @Test("大きさの無い旧い項目も同じ版として読め、大きさの載った項目は大きさごと読む")
    func olderEntriesStillRead() throws {
        let directory = try TestScratch.directory("mokume-frames")
        let base = """
            "schemaVersion": 1, "sketch": "S", "window": "main", "identity": "/s", "title": "S", "pid": 1,
            "startedAt": 1
            """
        try Data("{\(base), \"serviceName\": \"org.mokume.frames.1.a.main\"}".utf8)
            .write(to: directory.appendingPathComponent("org.mokume.frames.1.a.main.json"))
        try Data("{\(base), \"serviceName\": \"org.mokume.frames.1.c.main\", \"width\": 16, \"height\": 8}".utf8)
            .write(to: directory.appendingPathComponent("org.mokume.frames.1.c.main.json"))
        let entries = FrameListing.entries(in: directory)
        #expect(entries.map(\.serviceName) == ["org.mokume.frames.1.a.main", "org.mokume.frames.1.c.main"])
        #expect(entries.map(\.width) == [nil, 16])
        #expect(entries.map(\.height) == [nil, 8])
        #expect(entries.allSatisfy { $0.schemaVersion == 1 })
    }

    /// **Schema が断る大きさは、項目ごと捨てずに大きさの無い項目として読む** (#3949)。Schema の `dependentRequired`
    /// (片方だけ)・`minimum: 1` (0・負)・`integer` (小数・桁の多い端数・真偽値・文字列) の代表例。旧い送り手の項目と同じに
    /// 扱うので、名前で繋げ、大きさは別に知っていれば使える。
    @Test(
        "Schema が断る大きさの項目は、大きさの無い項目として読む",
        arguments: [
            "\"width\": 16", "\"height\": 8", "\"width\": 0, \"height\": 8", "\"width\": 16, \"height\": 0",
            "\"width\": -16, \"height\": 8", "\"width\": 16, \"height\": -1", "\"width\": 2.5, \"height\": 8",
            "\"width\": 1.00000000000000000000001, \"height\": 8", "\"width\": true, \"height\": 8",
            "\"width\": \"16\", \"height\": 8", "\"width\": null, \"height\": 8",
        ])
    func sizesTheSchemaRefusesReadAsUnsized(_ size: String) throws {
        let json = """
            {"schemaVersion": 1, "sketch": "S", "window": "main", "identity": "/s", "title": "S", "pid": 1,
             "startedAt": 1, "serviceName": "org.mokume.frames.1.a.main", \(size)}
            """
        let entry = try JSONDecoder().decode(FrameListing.Entry.self, from: Data(json.utf8))
        #expect(entry.width == nil && entry.height == nil, "\(size) を大きさとして読んだ: \(entry)")
        #expect(entry.serviceName == "org.mokume.frames.1.a.main")
    }

    /// 大きさの読みを緩めても、必須の欄の整数でない値は今までどおり断る (#4015)。境界の 1×1 は大きさとして読む。
    @Test("1×1 は大きさとして読み、必須の欄の整数でない値は断る")
    func theSmallestSizeReadsAndRequiredFieldsStayStrict() throws {
        func entry(_ fields: String) throws -> FrameListing.Entry {
            try JSONDecoder().decode(
                FrameListing.Entry.self,
                from: Data(
                    """
                    {"schemaVersion": 1, "sketch": "S", "window": "main", "identity": "/s", "title": "S",
                     "serviceName": "org.mokume.frames.1.a.main", \(fields)}
                    """.utf8))
        }
        let smallest = try entry("\"pid\": 1, \"startedAt\": 1, \"width\": 1, \"height\": 1")
        #expect([smallest.width, smallest.height] == [1, 1])
        #expect(throws: (any Error).self) { try entry("\"pid\": 1.5, \"startedAt\": 1, \"width\": 16, \"height\": 8") }
        #expect(throws: (any Error).self) { try entry("\"startedAt\": 1, \"width\": 16, \"height\": 8") }
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
