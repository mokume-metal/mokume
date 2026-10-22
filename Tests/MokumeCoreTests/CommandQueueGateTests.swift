// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation
import Metal
import MokumeDiagnostics
import Testing

@testable import MokumeCore

/// GPU の待ちが期限を越えたプロセスでは、新しい発行口を作らない
/// ([#2052](https://github.com/mokume-metal/mokume/issues/2052))。GPU を要する。
///
/// #2052 の手順は次の 3 つで、これが約 5 分繰り返されて、止まった発行口が溜まった。
///
/// 1. 待ちを期限で打ち切る
/// 2. 土台を畳む
/// 3. 次の検査が新しい土台 (= 新しい発行口) を作る
///
/// ここでは 1・2 を差し込みで起こし、3 が起きないことを見る。
///
/// **GPU には何も投入しない。** 期限切れは、番号だけを進めた答えの来ない投入
/// (`addUnansweredSubmissionForTesting()`) を待たせて作る。GPU を本当に詰まらせる検査は書かない
/// (#1999・#2052 で、手元機ごと落ちた)。
///
/// **関所は検査ごとに作る。** プロセスで 1 つの関所 (`CommandQueueGate.process`) に印を立てると、
/// 同じプロセスの残りの GPU の検査が、すべて断られる。
@Suite(
    "待ちの期限切れの後の発行口",
    .enabled(
        if: RenderDevice.isAvailable,
        "この世代のコマンド構造に対応した GPU が無い実行環境ではスキップする")
)
struct CommandQueueGateTests {
    @Test("待ちを打ち切って畳んだ後は、2 つ目の土台を作らず、理由を名乗って断る")
    func noSecondFoundationAfterAWaitGaveUp() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw RenderFailure.deviceUnavailable }
        let gate = CommandQueueGate()
        try takeDownWithoutAnAnswer(on: device, through: gate)

        #expect(gate.isClosed, "土台が待ちを打ち切って畳まれたのに、印が立っていない")
        // 最初の赤から原因を辿れるよう、どの待ちがどの期限を越えたかを控える。畳む時の待ちは投げない
        // ので、控えが無いと原因の検査は緑のまま埋もれる
        #expect(gate.closure?.wait == .takingDown, "控えた待ちの種類が違う: \(String(describing: gate.closure))")
        #expect(gate.closure?.limit == .milliseconds(50))
        let failure = #expect(throws: RenderFailure.self) {
            _ = try RenderDevice(device: device, slotCount: 1, queueGate: gate)
        }
        #expect(failure == .gpuNotResponding, "名乗りが違う: \(String(describing: failure))")
        // 投げたことだけを見ると、作ってから投げる形に崩れても緑のままになる
        #expect(gate.queuesMade == 1, "印が立った後に発行口を作った (計 \(gate.queuesMade) 本)")

        // 検査の条件 (`isAvailable`) を評価し直しても、使い捨ての発行口を作らない
        #expect(!RenderDevice.isAvailable(on: device, through: gate))
        #expect(gate.queuesMade == 1, "使える環境かを問うだけで発行口を作った (計 \(gate.queuesMade) 本)")

        // 期限を越えて手放した発行口は、環ではなく、押し出されない置き場で持つ (#2235)
        #expect(gate.heldQueueCount == 1, "期限切れで手放した発行口を、押し出されない置き場で持っていない")
        #expect(gate.retiredQueueCount == 0, "期限切れで手放した発行口が、押し出される環に入っている")
    }

    /// 答えの来ない投入 (検査の差し込み) の期限切れは、記録を書かない。**書くと、検査のたびに本物の置き場へ
    /// 記録が残り、以後の検査・計測が止まる** (#2235)。知らせを黙らせているのと同じ条件である。
    @Test("記録が在るプロセスの関所は、発行口を作らずに断る。isAvailable は装置の有無を答え、GPU の suite を飛ばさない")
    func aRecordStopsNewQueues() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw RenderFailure.deviceUnavailable }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("wait-expired.json")
        let gate = CommandQueueGate(expiryRecord: ExpiryRecord(path: path, wrapper: nil))
        _ = try gate.makeQueue(on: device)
        #expect(gate.queuesMade == 1)

        try Data("{}".utf8).write(to: path)
        let failure = #expect(throws: RenderFailure.self) {
            _ = try RenderDevice(device: device, slotCount: 1, queueGate: gate)
        }
        #expect(failure == .gpuNotResponding, "名乗りが違う: \(String(describing: failure))")
        #expect(gate.queuesMade == 1, "記録が在るのに発行口を作った (計 \(gate.queuesMade) 本)")

        // **記録だけがあるとき `isAvailable` は、発行口を作らずに「装置は在る」と答える。** `false` にすると、
        // `.enabled(if: RenderDevice.isAvailable, …)` の GPU の suite が「GPU が無い実行環境」として全部飛び、
        // `swift test` が緑で終わる。suite は走って、上の土台の断りで赤になる (記録で止まる = 名乗って赤)
        #expect(RenderDevice.isAvailable(on: device, through: gate), "記録のせいで GPU の suite が飛ぶ")
        #expect(gate.queuesMade == 1, "使える環境かを問うだけで発行口を作った (計 \(gate.queuesMade) 本)")
        // 装置が無ければ、記録があっても偽 (GPU が無い環境は今までどおり飛ばす)
        #expect(!RenderDevice.isAvailable(on: nil, through: gate))

        // このプロセス自身の印は、今までどおり偽 (記録の有無によらない)
        let own = CommandQueueGate(expiryRecord: ExpiryRecord(path: path, wrapper: nil))
        #expect(own.close(after: .finishing, limit: .seconds(5), writesRecord: false))
        #expect(!RenderDevice.isAvailable(on: device, through: own))
    }

    @Test("検査の差し込みの期限切れは、記録を持つ関所でも記録を書かない")
    func aTestInjectedExpiryWritesNoRecord() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw RenderFailure.deviceUnavailable }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("wait-expired.json")
        let gate = CommandQueueGate(expiryRecord: ExpiryRecord(path: path, wrapper: nil))
        try takeDownWithoutAnAnswer(on: device, through: gate)

        #expect(gate.isClosed)
        #expect(gate.closure?.wait == .takingDown)
        #expect(!FileManager.default.fileExists(atPath: path.path), "差し込みの期限切れが記録を書いた")
    }

    /// 期限切れで手放した発行口は、後から環の上限より多くが手放されても解放されない (#2235)。
    /// 実行中の仕事を載せたまま集合ごと解放すると、「実行中のものが終わる前に土台を畳まない」の約束を、
    /// 期限切れの枝だけが破る。
    @Test("期限切れで手放した発行口は、後から上限より多くが手放されても、関所が持ち続ける")
    func aQueueRetiredPastTheDeadlineOutlivesTheRing() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw RenderFailure.deviceUnavailable }
        let gate = CommandQueueGate()
        weak var expired: AnyObject?
        weak var ordinary: AnyObject?
        do {
            let queue = try gate.makeQueue(on: device)
            expired = queue as AnyObject
            gate.retire(queue, pastDeadline: true)
        }
        do {
            let queue = try gate.makeQueue(on: device)
            ordinary = queue as AnyObject
            gate.retire(queue)
        }
        for _ in 0..<(CommandQueueGate.retiredQueueLimit + 1) {
            gate.retire(try gate.makeQueue(on: device))
        }
        #expect(gate.retiredQueueCount == CommandQueueGate.retiredQueueLimit)
        #expect(gate.heldQueueCount == 1)
        #expect(ordinary == nil, "環に入れた発行口が、上限を越えても解放されない (対照が成り立たない)")
        #expect(expired != nil, "期限切れで手放した発行口が、環から押し出されて解放された")
    }

    /// 発行口を解放した直後に、同じプロセスの別の土台へ投入した仕事が打ち切られる (#2054)。
    /// 解放を後ろへずらすので、手放した発行口は関所が持ち、持つ本数は上限で頭打ちになる。
    @Test("手放した土台の発行口は、後から上限の本数が手放されるまで関所が持つ")
    func retiredQueuesOutliveTheirFoundation() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw RenderFailure.deviceUnavailable }
        let gate = CommandQueueGate()
        let limit = CommandQueueGate.retiredQueueLimit
        for made in 1...(limit + 2) {
            do {
                let gpu = try RenderDevice(device: device, slotCount: 1, queueGate: gate)
                #expect(gate.retiredQueueCount == min(made - 1, limit), "生きている土台の発行口を数えた")
                _ = gpu
            }
            // 手放した直後に解放すると、次の土台の仕事が打ち切られる
            #expect(
                gate.retiredQueueCount == min(made, limit),
                "\(made) 本目の土台を手放した後に、関所が持つ発行口が \(gate.retiredQueueCount) 本")
        }
        #expect(gate.queuesMade == limit + 2)
        #expect(!gate.isClosed)
    }

    /// 土台を作り、答えの来ない投入を 1 本足して手放す。`deinit` が待ちを打ち切る (上の手順 1・2)。
    ///
    /// 手放すのは、この関数を抜けるときである。検査は main actor で走るので、`isolated deinit` は
    /// その場で走り終わる。
    private func takeDownWithoutAnAnswer(on device: any MTLDevice, through gate: CommandQueueGate) throws {
        let gpu = try RenderDevice(device: device, slotCount: 1, queueGate: gate)
        gpu.signalWaitLimit = .milliseconds(50)
        gpu.addUnansweredSubmissionForTesting()
        #expect(!gpu.isIdle, "答えの来ない投入を足したのに、終わっていると読める — 畳むときに待たない")
        #expect(gate.queuesMade == 1)
        #expect(!gate.isClosed, "まだ何も待っていないのに、印が立っている")
    }
}

/// 印を立てた後の名乗り。GPU は要らない (関所だけを相手にする)。
///
/// 見ているのは 2 つ (#2052 の反証)。
/// - **描きすぎの場合もあると名乗る。** 期限を越えた待ちからは、重い 1 フレームと答えない GPU を
///   見分けられない。同じ期限切れで `.timedOut` が「描きすぎ」と言うので、片方だけを言い切ると食い違う
/// - **最初に期限を越えた待ちを添える。** 印が立つと、以後の GPU の検査はすべて同じ断りで赤になる。
///   どの赤からも、原因の待ちの種類・期限・時刻が読めなければならない
///
/// `RenderFailure.gpuNotResponding.description` がプロセスの関所を読むことは、ここでは確かめない。
/// 確かめるにはプロセスの関所に印を立てることになり、同じプロセスの残りの GPU の検査が断られる。
@Suite("期限切れの後の名乗り")
struct CommandQueueGateWordingTests {
    private static let first = Date(timeIntervalSince1970: 1_791_000_000)

    @Test("関所が控えるのは最初に期限を越えた待ちだけ")
    func theGateKeepsTheFirstWaitOnly() {
        let gate = CommandQueueGate()
        #expect(gate.closure == nil)
        #expect(gate.close(after: .finishing, limit: .seconds(5), at: Self.first))
        #expect(!gate.close(after: .takingDown, limit: .seconds(5), at: Self.first + 60))
        #expect(gate.closure == .init(wait: .finishing, limit: .seconds(5), date: Self.first))
        #expect(gate.isClosed)
    }

    @Test("最初に印を立てたときだけ、書き先があれば期限切れの記録を 1 つ書く")
    func theFirstClosureWritesOneRecord() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("wait-expired.json")
        let gate = CommandQueueGate(expiryRecord: ExpiryRecord(path: path, wrapper: 4321))
        #expect(!FileManager.default.fileExists(atPath: path.path), "印を立てる前に書いている")

        #expect(gate.close(after: .finishing, limit: .seconds(5), at: Self.first))
        let data = try Data(contentsOf: path)
        let record = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(record["event"] as? String == "wait-expired")
        #expect(record["wait"] as? String == CommandQueueGate.Wait.finishing.phrase)
        #expect(record["limit"] as? String == "\(Duration.seconds(5))")
        #expect(record["gpu_slot_pid"] as? Int == 4321)
        #expect(record["pid"] as? Int == Int(ProcessInfo.processInfo.processIdentifier))
        #expect(record["cwd"] as? String == FileManager.default.currentDirectoryPath)
        #expect(record["time"] as? String == ExpiryRecord.timestamp(Self.first))
        #expect(record["command"] is [String])

        // 2 回目の期限切れは、記録を書き換えない (最初の 1 件を残す)
        #expect(!gate.close(after: .takingDown, limit: .seconds(5), at: Self.first + 60))
        #expect(try Data(contentsOf: path) == data)
    }

    @Test("既にある記録は上書きしない・書き先が使えなくても投げない・書き先が無ければ何も書かない")
    func theRecordIsNeverOverwrittenAndNeverThrows() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("wait-expired.json")
        try Data("older".utf8).write(to: path)
        let record = ExpiryRecord(path: path, wrapper: nil)
        #expect(record.write(after: .allocator, limit: .seconds(5)) == .alreadyThere)
        #expect(try String(contentsOf: path, encoding: .utf8) == "older", "既にある記録を上書きした")

        // 置き場が無くても、投げずに書かない
        let missing = ExpiryRecord(path: directory.appendingPathComponent("absent/wait-expired.json"), wrapper: nil)
        guard case .failed(let reason, _) = missing.write(after: .allocator, limit: .seconds(5)) else {
            Issue.record("置き場が無いのに、書けなかったと言わない")
            return
        }
        #expect(!reason.isEmpty)

        // 環境変数が無い (`gpu-slot.py` の外) か空なら、記録を持たない = 何も書かない
        #expect(ExpiryRecord.fromEnvironment([:]) == nil)
        #expect(ExpiryRecord.fromEnvironment([ExpiryRecord.variable: ""]) == nil)
        // 鍵は `gpu-slot.py` が子へ渡す名前と同じ (利用者の一覧には載せない・許可の行に理由がある)
        #expect(ExpiryRecord.variable == "MOKUME_GPU_SLOT_EXPIRY_RECORD")
        let given = ExpiryRecord.fromEnvironment([
            ExpiryRecord.variable: path.path, ExpiryRecord.wrapperVariable: "77",
        ])
        #expect(given == ExpiryRecord(path: path, wrapper: 77))
        // 書き先を持たない関所 (検査が自前で作るもの) は、印を立てても何も書かない
        let plain = CommandQueueGate()
        #expect(plain.close(after: .finishing, limit: .seconds(5), at: Self.first))
        #expect(try String(contentsOf: path, encoding: .utf8) == "older")
    }

    @Test("記録を持つ関所は、記録が在れば印が立っているのと同じに扱う。記録を持たない関所は何も読まない")
    func aRecordThatIsThereCountsAsTheMark() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("wait-expired.json")
        let gate = CommandQueueGate(expiryRecord: ExpiryRecord(path: path, wrapper: nil))
        let plain = CommandQueueGate()
        #expect(!gate.isClosed)

        // 別のプロセスが書いた記録 (このプロセスは印を立てていない)
        try Data("{}".utf8).write(to: path)
        #expect(gate.isClosed, "記録が在るのに、発行口を作れる関所のままである")
        #expect(gate.closure == nil, "このプロセスは印を立てていない")
        #expect(!plain.isClosed, "記録を持たない関所が、記録を読んだ")

        // 消せば、また作れる (記録は人が消す)
        try FileManager.default.removeItem(at: path)
        #expect(!gate.isClosed)

        // 壊れたシンボリックリンクも「在る」(中身を読まない)
        try FileManager.default.createSymbolicLink(atPath: path.path, withDestinationPath: "/nonexistent-target")
        #expect(gate.isClosed)
    }

    @Test("プロセスの関所は、環境の書き先から記録を書き・読む配線を持つ")
    func theProcessGateIsWiredToTheEnvironment() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("wait-expired.json")

        // 作り方 (`forProcess`) が環境から記録をつなぐ: 書き先が渡されれば、最初の印で書き、在れば閉じている
        let wired = CommandQueueGate.forProcess(environment: [ExpiryRecord.variable: path.path])
        #expect(wired.expiryRecordPath == path)
        #expect(wired.close(after: .finishing, limit: .seconds(5)))
        #expect(FileManager.default.fileExists(atPath: path.path), "環境の書き先へ記録を書いていない")
        #expect(CommandQueueGate.forProcess(environment: [ExpiryRecord.variable: path.path]).isClosed)

        // 渡されなければ、書かず・読まない
        let unwired = CommandQueueGate.forProcess(environment: [:])
        #expect(unwired.expiryRecordPath == nil)
        #expect(!unwired.isClosed)

        // 本物の `process` が `forProcess` で作られ、このプロセスの環境をつないでいる。`gpu-slot.py` の下
        // (環境に書き先がある) なら、配線を外すと、ここが赤になる
        #expect(
            CommandQueueGate.process.expiryRecordPath == ExpiryRecord.fromEnvironment()?.path,
            "プロセスの関所に、環境の記録がつながっていない")
    }

    @Test("記録を書けなかったときは、1 度名乗る。差し込みの期限切れは書かず、名乗らない")
    func aFailedWriteIsSaidOnce() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let unwritable = ExpiryRecord(path: directory.appendingPathComponent("absent/wait-expired.json"), wrapper: nil)

        let said = Diagnostics.$digest.withValue(WarningDigest()) { () -> [String] in
            let gate = CommandQueueGate(expiryRecord: unwritable)
            #expect(gate.close(after: .finishing, limit: .seconds(5), at: Self.first))
            #expect(!gate.close(after: .takingDown, limit: .seconds(5), at: Self.first + 60))
            return Diagnostics.takeUnreported()
        }
        #expect(said.count == 1, "\(said)")
        #expect(said.first?.contains("will not be stopped by it") == true, "\(said)")
        #expect(said.first?.contains(unwritable.path.path) == true, "\(said)")

        // 検査の差し込み (`writesRecord: false`) は、書かず、名乗らない
        let path = directory.appendingPathComponent("wait-expired.json")
        let silent = Diagnostics.$digest.withValue(WarningDigest()) { () -> [String] in
            let gate = CommandQueueGate(expiryRecord: ExpiryRecord(path: path, wrapper: nil))
            #expect(gate.close(after: .finishing, limit: .seconds(5), at: Self.first, writesRecord: false))
            return Diagnostics.takeUnreported()
        }
        #expect(silent.isEmpty, "\(silent)")
        #expect(!FileManager.default.fileExists(atPath: path.path), "差し込みの期限切れが記録を書いた")
    }

    @Test("作った後に書き損ねたときは、止まらないとは言わず、読めない記録が残ると言う")
    func aHalfWrittenRecordIsNamedForWhatItIs() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("wait-expired.json")
        let record = ExpiryRecord(path: path, wrapper: nil)

        // ディスクが満杯の形: 開けて作った後に、書く口が失敗する
        let outcome = record.write(
            after: .finishing, limit: .seconds(5), rawWrite: { _, _, _ in
                errno = ENOSPC
                return -1
            })
        guard case .failed(let reason, let createdFile) = outcome else {
            Issue.record("書き損ねたのに、書けたと言う: \(outcome)")
            return
        }
        #expect(createdFile, "作った後の失敗なのに、作っていないと言う")
        #expect(reason.contains("space"), Comment(rawValue: reason))
        #expect(FileManager.default.fileExists(atPath: path.path), "空か途中のファイルが残る (gpu-slot.py が読めない記録として止める)")

        let notice = CommandQueueGate.recordFailureNotice(at: path, reason: reason, createdFile: true)
        #expect(notice.contains("an unreadable one is left"), Comment(rawValue: notice))
        #expect(!notice.contains("will not be stopped by it"), "止まらないとは言えない: \(notice)")
        let none = CommandQueueGate.recordFailureNotice(at: path, reason: reason)
        #expect(none.contains("will not be stopped by it"), Comment(rawValue: none))

        // 関所は、その形でも 1 度だけ名乗る
        let said = Diagnostics.$digest.withValue(WarningDigest()) { () -> [String] in
            let gate = CommandQueueGate(
                expiryRecord: ExpiryRecord(path: directory.appendingPathComponent("absent/wait-expired.json"), wrapper: nil))
            #expect(gate.close(after: .finishing, limit: .seconds(5), at: Self.first))
            return Diagnostics.takeUnreported()
        }
        #expect(said.count == 1, "\(said)")
    }

    @Test("別のプロセスの記録があるときの断りは、起こし直しではなく、人が確かめて記録を消すよう言う")
    func theRefusalForARecordPointsAtTheRecord() {
        let text = RenderFailure.notResponding(after: nil, record: "/slots/wait-expired.json")
        #expect(text.contains("/slots/wait-expired.json"))
        #expect(text.contains("A person checks that the GPU answers"), "\(text)")
        #expect(!text.contains("start the process again"), "記録は起こし直しでは消えない")
        // 別の回の記録なので、「このプロセスの前」とは言わない。検査の記録を読む側が畳む頭の句
        #expect(text.hasPrefix("A wait for the GPU went past its limit in another run under gpu-slot.py"), "\(text)")
        #expect(!text.contains("earlier in this process"), "\(text)")

        // このプロセス自身が印を立てて記録も書いた回: 起こし直しとは言わず、記録を消すと言う
        let closure = CommandQueueGate.Closure(wait: .finishing, limit: .seconds(5), date: Self.first)
        let own = RenderFailure.notResponding(after: closure, record: "/slots/wait-expired.json")
        #expect(own.hasPrefix("A wait for the GPU went past its limit earlier in this process"), "\(own)")
        #expect(own.contains("the first was"), "\(own)")
        #expect(own.contains("stops later runs too"), "\(own)")
        #expect(own.contains("A person checks that the GPU answers"), "\(own)")
        #expect(!own.contains("start the process again"), "\(own)")
        // 記録を書いたプロセスが印を立てた時の 1 行も、起こし直せとは言わない
        let notice = RenderDevice.closingNotice(after: .finishing, limit: .seconds(5), record: "/slots/wait-expired.json")
        #expect(notice.contains("/slots/wait-expired.json"), "\(notice)")
        #expect(notice.contains("a person checks that the GPU answers"), "\(notice)")
        #expect(!notice.contains("start it again"), "\(notice)")
        #expect(!notice.contains("\n"))
        // 印を立てたプロセスの断りは、今までどおり起こし直しへ送る
        let plain = RenderFailure.notResponding(after: nil)
        #expect(plain.contains("start the process again"))
    }

    @Test("断りの 1 行目が、最初に期限を越えた待ちの種類・期限・時刻を名乗る")
    func theRefusalNamesTheFirstWait() {
        let closure = CommandQueueGate.Closure(wait: .takingDown, limit: .seconds(5), date: Self.first)
        let text = RenderFailure.notResponding(after: closure)
        let headline = String(text.prefix { $0 != "\n" })
        #expect(headline.contains("while taking down a drawing foundation"), "\(headline)")
        #expect(headline.contains("past \(Duration.seconds(5))"), "\(headline)")
        #expect(
            headline.contains(Self.first.formatted(Date.ISO8601FormatStyle(timeZone: .current))), "\(headline)")
        // 控えが無ければ、添えるものは無い
        #expect(!RenderFailure.notResponding(after: nil).contains("the first was"))
    }

    @Test("断りも印を立てた時の 1 行も、描きすぎの場合もあると名乗って起こし直しへ送る")
    func bothSidesNameTheHeavyFrameToo() {
        let refusal = RenderFailure.notResponding(after: nil)
        let notice = RenderDevice.closingNotice(after: .finishing, limit: .seconds(5))
        for text in [refusal, notice] {
            #expect(text.contains("one frame drawing too much"), "\(text)")
            #expect(text.contains("stopped answering"), "\(text)")
            #expect(text.contains("start"), "\(text)")
        }
        #expect(notice.contains("while waiting for the GPU to finish"))
        #expect(!notice.contains("\n"), "印を立てた時の警告が 1 行に収まっていない")
    }

    @Test("描けるようになっても、印が残っていれば言い添える")
    func theRecoveryNoticeMentionsTheMark() {
        let plain = SketchApplication.recoveryNotice(skipped: 3, gate: nil)
        #expect(plain == "Drawing has recovered (3 frames were skipped)")
        let closure = CommandQueueGate.Closure(wait: .finishing, limit: .seconds(5), date: Self.first)
        let marked = SketchApplication.recoveryNotice(skipped: 3, gate: closure)
        #expect(marked.hasPrefix(plain))
        #expect(marked.contains("still sets up no new drawing foundation"), "\(marked)")
        #expect(!marked.contains("\n"))
    }
}
