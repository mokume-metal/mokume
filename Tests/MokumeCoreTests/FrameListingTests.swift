// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Darwin
import Foundation
import IOSurface
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
        if stillThere, let port = Bootstrap.lookUp(name) {
            Bootstrap.releaseSend(port)
        } else {
            stillThere = false
        }
        #expect(!stillThere, "名前を手放していない: \(name) が 5 秒後も引ける (受信の権利を手放していないか、launchd が名前を外すのが遅れている)")
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

    // MARK: - 送り手の待ち行列 (#4060)

    /// 名乗りの受信の port の待ち行列の上限。
    private func queueLimit(of port: mach_port_t) -> mach_port_msgcount_t? {
        var limits = mach_port_limits_t()
        var count = mach_msg_type_number_t(MemoryLayout<mach_port_limits_t>.size / MemoryLayout<natural_t>.size)
        let code = withUnsafeMutablePointer(to: &limits) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                mach_port_get_attributes(mach_task_self_, port, MACH_PORT_LIMITS_INFO, $0, &count)
            }
        }
        return code == KERN_SUCCESS ? limits.mpl_qlimit : nil
    }

    /// **受け手が上限まで繋いで面を全部返しても、送り手が読む前に落ちない数を待ち行列に持つ** (#4060)。OS の既定
    /// (測ると 2) のままだと、送り手が忙しい間に 3 通目の `release` から落ち、返した面が戻らない。
    @Test("名乗った送り手の port の待ち行列の上限は、受け手の上限 × (面の枚数の上限 + 2) である")
    func theSketchPortQueuesEveryRelease() throws {
        let directory = try TestScratch.directory("mokume-frames")
        let announcement = try #require(
            FrameAnnouncement.announce(
                sketch: "S", identity: "/s", title: "S", in: directory,
                warn: { Issue.record("名乗れなかった: \($0)") }))
        defer { announcement.withdraw() }
        #expect(FrameLink.sketchQueueLimit == FrameLink.receiverLimit * (FrameLink.surfaceCountRange.upperBound + 2))
        #expect(FrameLink.sketchQueueLimit <= Int(MACH_PORT_QLIMIT_MAX))
        #expect(queueLimit(of: announcement.receivePort) == mach_port_msgcount_t(FrameLink.sketchQueueLimit))
        // 約束の文が同じ数と決め方を言う (2 つの上限が変わったら文も直す)
        let contract = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent("Schemas/frame-link.md"), encoding: .utf8)
        let stated =
            "The sketch's port queues \(FrameLink.sketchQueueLimit) messages: \(FrameLink.receiverLimit) receivers × "
            + "(\(FrameLink.surfaceCountRange.upperBound) surfaces + 2)"
        #expect(contract.contains(stated), "Schemas/frame-link.md が待ち行列の上限を言わない: \(stated)")
    }

    /// **上限を越える連投はまだ落ちるが、送りは待たずに戻る** (#4060 の代償・ADR-0049 決定 4)。送り手が 1 通も読まない
    /// 間に、受け手と同じ名前を引いて上限ちょうどまで送れ、次の 1 通は `MACH_SEND_TIMED_OUT` で戻る。
    @Test("送り手が読まない間、受け手は上限の数までちょうど送れ、次の 1 通は待たずに落ちる")
    func aBurstPastTheLimitIsDroppedWithoutWaiting() throws {
        let directory = try TestScratch.directory("mokume-frames")
        let announcement = try #require(
            FrameAnnouncement.announce(
                sketch: "S", identity: "/s", title: "S", in: directory,
                warn: { Issue.record("名乗れなかった: \($0)") }))
        defer { announcement.withdraw() }
        let service = try #require(Bootstrap.lookUp(announcement.entry.serviceName))
        defer { Bootstrap.releaseSend(service) }
        var payload = FrameLink.Payload()
        payload.append(UInt32(0))
        payload.append(UInt32(0))
        var sent = 0
        var result = KERN_SUCCESS
        // 上限を越えるまで送る (送り手は読まない)。数えるのは送れた通数
        while sent <= FrameLink.sketchQueueLimit {
            result = FrameLink.send(.release, to: service, payload: payload)
            guard result == KERN_SUCCESS else { break }
            sent += 1
        }
        #expect(sent == FrameLink.sketchQueueLimit, "送れた通数: \(sent)")
        #expect(result == MACH_SEND_TIMED_OUT, "上限を越えた 1 通の戻り値: \(result)")
    }

    /// **待ち行列の上限は送り手の port に入る通数の上限で、受け入れた受け手の数とは別である** (#4060 の反証)。受け入れて
    /// いない受け手の connect (5 人目・送り直し・作り直した port に残った古い connect) も同じ枠に入り、その分だけ
    /// release が先に落ちる。約束の文はこの範囲で言い切る (`Schemas/frame-link.md`)。
    @Test("受け入れていない受け手の connect も送り手の待ち行列の枠を使い、その数だけ release の入る数が減る")
    func unacceptedConnectsShareTheQueue() throws {
        let directory = try TestScratch.directory("mokume-frames")
        let announcement = try #require(
            FrameAnnouncement.announce(
                sketch: "S", identity: "/s", title: "S", in: directory,
                warn: { Issue.record("名乗れなかった: \($0)") }))
        defer { announcement.withdraw() }
        let service = try #require(Bootstrap.lookUp(announcement.entry.serviceName))
        defer { Bootstrap.releaseSend(service) }
        // 送り手が読まない間に、受け入れられていない受け手が 3 通の connect を送る (port を作り直すたびの 1 通など)
        var reply: mach_port_t = 0
        mach_port_allocate(mach_task_self_, MACH_PORT_RIGHT_RECEIVE, &reply)
        defer { mach_port_mod_refs(mach_task_self_, reply, MACH_PORT_RIGHT_RECEIVE, -1) }
        let connects = 3
        for _ in 0..<connects {
            let surfaces = (0..<FrameLink.surfaceCountRange.lowerBound).compactMap { _ in
                IOSurfaceCreate(
                    [
                        kIOSurfaceWidth: 16, kIOSurfaceHeight: 8, kIOSurfacePixelFormat: FrameLink.surfaceFormat,
                        kIOSurfaceBytesPerElement: 8,
                    ] as [CFString: Any] as CFDictionary)
            }
            try #require(FrameLink.connect(to: service, reply: reply, surfaces: surfaces) == KERN_SUCCESS)
        }
        var payload = FrameLink.Payload()
        payload.append(UInt32(1))
        payload.append(UInt32(0))
        var released = 0
        while released <= FrameLink.sketchQueueLimit,
            FrameLink.send(.release, to: service, payload: payload) == KERN_SUCCESS
        {
            released += 1
        }
        #expect(released == FrameLink.sketchQueueLimit - connects, "connect の後に入った release: \(released)")
    }

    /// **上限を上げられない port でも名乗りは続け、診断に 1 行だけ言う** (#4060 の崩れたときの移り先・ADR-0020 決定 5)。
    /// 受信の権利を持たない名前 (死んだ名前) を登録の結果に差し替えて、設定を断らせる。
    @Test("待ち行列の上限を上げられなければ、既定のまま名乗って目録に載せ、診断に 1 行だけ出す")
    func aQueueLimitThatCannotBeRaisedKeepsTheAnnouncement() throws {
        let directory = try TestScratch.directory("mokume-frames")
        var said: [String] = []
        let announcement = try #require(
            FrameAnnouncement.announce(
                sketch: "S", identity: "/s", title: "S", in: directory, warn: { said.append($0) },
                checkIn: { _ in
                    var port: mach_port_t = 0
                    mach_port_allocate(mach_task_self_, MACH_PORT_RIGHT_RECEIVE, &port)
                    mach_port_insert_right(mach_task_self_, port, port, mach_msg_type_name_t(MACH_MSG_TYPE_MAKE_SEND))
                    // 受信の権利を手放すと、残った送信の権利は死んだ名前になる
                    mach_port_mod_refs(mach_task_self_, port, MACH_PORT_RIGHT_RECEIVE, -1)
                    return .success(port)
                }),
            "上限を上げられないだけで名乗りをやめた: \(said)")
        defer {
            // 下ろしは受信の権利を手放そうとするだけなので、死んだ名前の参照は検査が返す
            let name = announcement.receivePort
            announcement.withdraw()
            FrameLink.releaseName(name)
        }
        #expect(said.count == 1, "\(said)")
        #expect(said.first?.contains("keeps running") == true, "走り続けることを言わない: \(said)")
        #expect(
            said.first?.contains("never written to again") == true, "返された面が戻らなくなりうることを言わない: \(said)")
        #expect(FrameListing.entries(in: directory).map(\.serviceName) == [announcement.entry.serviceName])
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
