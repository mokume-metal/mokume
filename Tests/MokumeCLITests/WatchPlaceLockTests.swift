// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Darwin
import Foundation
import Testing
import mokume

@testable import MokumeCLI
@testable import MokumeCore

/// 同じ場所の 2 本目の見張りは断る ([#2093](https://github.com/mokume-metal/mokume/issues/2093))。
///
/// 見張りは場所の区画を自分 1 本のものとして作り直し・畳むので、2 本が並ぶと 1 本目の窓が 2 本目の
/// 子を映し、止めると 1 本目の次の世代が自分の窓を開いた。場所の錠 (`flock`) を先に取れた 1 本だけが
/// 見張る。錠は**開いた記述ごと**なので、検査が錠ファイルを自分で開いて掛ければ、同じプロセスの中でも
/// 「別の見張りが持っている」を作れる。
@Suite("同じ場所の 2 本目の見張り", .signalStateKept)
struct WatchPlaceLockTests {
    private func makeSketch() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("mokume-watch-place-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        try Data(#"// swift-tools-version: 6.2"#.utf8)
            .write(to: url.appendingPathComponent("Package.swift"))
        return url
    }

    /// 別の見張りが持っている錠。**検査が錠ファイルを自分で開いて掛ける。**
    nonisolated private final class OtherWatch {
        private var descriptor: Int32 = -1

        init(holding base: URL) throws {
            try FileManager.default.createDirectory(
                at: WorkDirectory.root(under: base), withIntermediateDirectories: true)
            let opened = open(
                WatchPlaceLock.lockURL(under: base).path, O_RDONLY | O_CREAT | O_CLOEXEC, 0o644)
            #expect(opened >= 0)
            #expect(flock(opened, LOCK_EX | LOCK_NB) == 0, "別の見張りが既に持っている")
            descriptor = opened
        }

        func leave() {
            guard descriptor >= 0 else { return }
            close(descriptor)
            descriptor = -1
        }

        deinit { leave() }
    }

    private func rootEntries(of base: URL) -> [String] {
        let names = try? FileManager.default.contentsOfDirectory(
            atPath: WorkDirectory.root(under: base).path)
        return (names ?? []).sorted()
    }

    // MARK: - 錠

    @Test("先客が居る場所では断り、手放せば取れる")
    func theSecondClaimIsRefusedUntilTheFirstLetsGo() throws {
        let base = try makeSketch()
        let first = try WatchPlaceLock.claim(under: base)

        do {
            _ = try WatchPlaceLock.claim(under: base)
            Issue.record("先客が居るのに取れた")
        } catch {
            guard case .alreadyWatching(let place, let pid) = error else {
                Issue.record("別の失敗になった: \(error)")
                return
            }
            #expect(place == WorkDirectory.root(under: base).path)
            #expect(error.message.contains(place))
            // 診断のために、先客の pid が錠ファイルに書かれていて、断る文面が名乗る
            #expect(pid == getpid(), "先客の pid を名乗っていない: \(String(describing: pid))")
            #expect(error.message.contains("pid \(getpid())"))
            #expect(error.message.contains(StartupReads.workDirectory.key), "分ける手段を言っていない")
            #expect(error.exitCode != 0)
        }

        first.release()
        let again = try WatchPlaceLock.claim(under: base)
        again.release()
    }

    @Test("持っているものが消えれば (記述が閉じれば) 取れる")
    func aLockIsReleasedWhenItsHolderGoesAway() throws {
        let base = try makeSketch()
        var first: WatchPlaceLock? = try WatchPlaceLock.claim(under: base)
        #expect(first != nil)
        first = nil
        let second = try WatchPlaceLock.claim(under: base)
        second.release()
    }

    @Test("場所が違えば、互いに断らない")
    func differentPlacesDoNotRefuseEachOther() throws {
        let one = try makeSketch()
        let other = try makeSketch()
        let first = try WatchPlaceLock.claim(under: one)
        let second = try WatchPlaceLock.claim(under: other)
        // 同じスケッチでも、区画の基準 (MOKUME_WORK_DIR) を分ければ別の場所になる
        let moved = one.appendingPathComponent("elsewhere", isDirectory: true)
        let third = try WatchPlaceLock.claim(under: moved)
        for lock in [first, second, third] { lock.release() }
    }

    /// **確かめられなければ、取れたことにする** (`FacetClaim` と同じ向き)。断るほうへ倒すと、錠を置けない
    /// 場所では見張りが 1 本も始まらない。
    @Test("錠を置けない場所では、断らずに見張り始める")
    func aPlaceThatCannotHoldALockDoesNotRefuse() throws {
        let base = try makeSketch()
        // `.mokume` の場所を普通のファイルに塞ぐ — 場所を作れず、錠も置けない
        try Data("ファイル".utf8).write(to: WorkDirectory.root(under: base))
        let lock = try WatchPlaceLock.claim(under: base)
        lock.release()
    }

    /// **見張りが `SIGKILL` で消えても、錠はカーネルが外す。** 後始末を通らずに消えた前任の場所では、
    /// 残った区画は作り直してよい — 道具からの合図も pid も要らない。
    @Test("後始末を通らずに消えた前任の場所では取れる")
    func aKilledPredecessorLeavesThePlaceOpen() throws {
        let base = try makeSketch()
        try FileManager.default.createDirectory(
            at: WorkDirectory.root(under: base), withIntermediateDirectories: true)
        let holder = Process()
        holder.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
        holder.arguments = [
            "-MFcntl=:flock", "-e",
            #"open(my $f, ">>", $ARGV[0]) or exit 2; flock($f, LOCK_EX | LOCK_NB) or exit 3; $| = 1; print "held\n"; sleep 60;"#,
            WatchPlaceLock.lockURL(under: base).path,
        ]
        let output = Pipe()
        holder.standardOutput = output
        try holder.run()
        // **待つ側が期限を持つ。** 越えたら殺す (読みは別の走りで、`.timeLimit` は使わない)
        defer { if holder.isRunning { kill(holder.processIdentifier, SIGKILL) } }
        let got = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var line = Data()
        DispatchQueue.global().async {
            line = output.fileHandleForReading.availableData
            got.signal()
        }
        guard got.wait(timeout: .now() + 10) == .success else {
            kill(holder.processIdentifier, SIGKILL)
            Issue.record("前任の模擬が錠を取ったと名乗らないまま期限を越えた")
            return
        }
        try #require(String(data: line, encoding: .utf8) == "held\n", "前任が錠を取れていない")

        // 生きている間は断る
        do {
            _ = try WatchPlaceLock.claim(under: base)
            Issue.record("生きている前任が居るのに取れた")
        } catch {
            guard case .alreadyWatching = error else {
                Issue.record("別の失敗になった: \(error)")
                return
            }
        }
        // 後始末を通らずに消える
        kill(holder.processIdentifier, SIGKILL)
        holder.waitUntilExit()
        let lock = try WatchPlaceLock.claim(under: base)
        lock.release()
    }

    // MARK: - 見張りの口

    /// **断った回は、場所に何も触れない。** 区画 `viewport` を消さず (1 本目の窓が指す目録のまま)、窓口が
    /// 使う区画も足さず、巡回にも入らない。
    @Test("同じ場所で見張りが走っていれば、2 本目は場所に触れずに断る")
    func aSecondWatchRefusesWithoutTouchingThePlace() throws {
        let kept = SignalState.current()
        defer { kept.restore() }
        let root = try makeSketch()
        let other = try OtherWatch(holding: root)
        defer { other.leave() }
        // 1 本目が置いていったもの: 目録と、窓口が使う区画の 1 つ
        let viewport = WorkDirectory.facet(StartupReads.viewport.key, under: root)
        try FileManager.default.createDirectory(at: viewport, withIntermediateDirectories: true)
        let manifest = viewport.appendingPathComponent(SharedFrameSurface.manifestName)
        let placed = Data(#"{"schemaVersion":1,"ids":[140,150],"width":8,"height":8}"#.utf8)
        try placed.write(to: manifest)
        try FileManager.default.createDirectory(
            at: WorkDirectory.facet(StartupReads.observe.key, under: root),
            withIntermediateDirectories: true)
        let before = rootEntries(of: root)

        var reachedTheLoop = false
        do {
            try WatchCommand.run([root.path], watching: { _, _ in reachedTheLoop = true })
            Issue.record("先客が居るのに見張り始めた")
        } catch {
            guard case .alreadyWatching(let place, _) = error else {
                Issue.record("別の失敗になった: \(error)")
                return
            }
            #expect(place.hasSuffix("/.mokume"))
        }

        #expect(!reachedTheLoop, "断ったのに巡回へ入った")
        #expect(try Data(contentsOf: manifest) == placed, "1 本目の目録に触れた")
        #expect(rootEntries(of: root) == before, "断った回が場所の顔ぶれを変えた")
        #expect(!WatchCommand.refusesThrottling, "断った回が間引きの断りを立てたまま")
    }

    /// 前任が後始末を通らずに消えた場所では、これまでどおり見張り始め、残った区画を作り直す。
    @Test("前任が消えた場所では見張り始め、残った区画は作り直される")
    func aWatchStartsWhereThePredecessorWasKilled() throws {
        let kept = SignalState.current()
        defer { kept.restore() }
        let root = try makeSketch()
        // 前任の残したもの。錠のファイルは在るが、誰も持っていない
        let other = try OtherWatch(holding: root)
        other.leave()
        let viewport = WorkDirectory.facet(StartupReads.viewport.key, under: root)
        try FileManager.default.createDirectory(at: viewport, withIntermediateDirectories: true)
        let manifest = viewport.appendingPathComponent(SharedFrameSurface.manifestName)
        try Data("死んだ面を指す目録".utf8).write(to: manifest)

        var reachedTheLoop = false
        try WatchCommand.run([root.path], watching: { _, _ in reachedTheLoop = true })

        #expect(reachedTheLoop, "前任が消えているのに断った")
        #expect(
            (try? Data(contentsOf: manifest)) != Data("死んだ面を指す目録".utf8),
            "死んだ前任の目録を引き継いだ")
    }

    /// **錠は巡回の間ずっと持ち、終われば手放す。** `claim` の戻りを持ち続けなければ (Swift は最後に使った
    /// ところで手放す)、巡回の間に別の見張りが入れてしまう。
    @Test("錠は巡回の間は持たれ、見張りが終われば手放されて次の見張りが始められる")
    func theLockIsHeldWhileWatchingAndFreeOnceItEnds() throws {
        let root = try makeSketch()
        // 取った錠の持ち主を、検査の終わりまで生かす。手放すのが持ち主の消滅 (`deinit`) だけでなく、
        // 見張りの終わりの `release()` であることを見る
        var heldLocks: [WatchPlaceLock] = []
        defer { heldLocks.removeAll() }
        for round in 1...2 {
            let kept = SignalState.current()
            defer { kept.restore() }
            var refusedInside = false
            var reachedTheLoop = false
            try WatchCommand.run([root.path], watching: { _, _ in
                reachedTheLoop = true
                // 巡回の中で別の見張りが同じ場所に入ろうとする
                do {
                    _ = try WatchPlaceLock.claim(under: root)
                } catch {
                    if let failure = error as? CommandFailure, case .alreadyWatching = failure {
                        refusedInside = true
                    }
                }
            }, claiming: { (base: URL) throws(CommandFailure) -> WatchPlaceLock in
                let lock = try WatchPlaceLock.claim(under: base)
                heldLocks.append(lock)
                return lock
            })
            #expect(heldLocks.count == round)
            #expect(reachedTheLoop, "\(round) 回目が断られた (錠を手放していない)")
            #expect(refusedInside, "\(round) 回目の巡回の間、錠を持っていない")
        }
    }

    /// 宣言の不備で始まらない回は、場所を作らない (錠は宣言の検査より後に取る)。
    @Test("宣言の不備で始まらない回は、場所 (.mokume) を作らない")
    func aWatchThatCannotStartLeavesNoPlace() throws {
        let kept = SignalState.current()
        defer { kept.restore() }
        let root = try makeSketch()
        let assets = root.appendingPathComponent("Sources/demo/assets", isDirectory: true)
        try FileManager.default.createDirectory(at: assets, withIntermediateDirectories: true)
        try Data("画像のつもり".utf8).write(to: assets.appendingPathComponent("picture.png"))

        #expect(throws: CommandFailure.resourcesNotDeclared(directory: "Sources/demo/assets")) {
            try WatchCommand.run([root.path], watching: { _, _ in })
        }
        #expect(
            !FileManager.default.fileExists(atPath: WorkDirectory.root(under: root).path),
            "始まらなかった回が場所を作った")
    }

    /// **掛けた直後に場所を消されても、並ばない。** 掛けたのは消えたファイルの錠で、同じパスに別の見張りが
    /// 作ったファイルの錠とは別物である。開いたファイルとパスが指すファイルが違えば、取り直す。
    @Test("錠を掛けた直後に場所を消され、別の見張りが取り直したら、断る")
    func aRaceThatReplacesTheLockFileIsNotMistakenForHolding() throws {
        let base = try makeSketch()
        var other: OtherWatch?
        defer { other?.leave() }
        do {
            _ = try WatchPlaceLock.claim(
                under: base,
                afterLocking: {
                    guard other == nil else { return }
                    // 錠ファイルごと場所を消し、別の見張りが同じパスに作り直して錠を持つ
                    try? FileManager.default.removeItem(at: WorkDirectory.root(under: base))
                    other = try? OtherWatch(holding: base)
                })
            Issue.record("消えたファイルの錠で、別の見張りと並んだ")
        } catch {
            guard case .alreadyWatching = error else {
                Issue.record("別の失敗になった: \(error)")
                return
            }
        }
        #expect(other != nil)
    }

    @Test("錠を掛けた直後にファイルだけ消されたら、取り直して取れる")
    func aVanishedLockFileIsTakenAgain() throws {
        let base = try makeSketch()
        var first = true
        let lock = try WatchPlaceLock.claim(
            under: base,
            afterLocking: {
                guard first else { return }
                first = false
                try? FileManager.default.removeItem(at: WatchPlaceLock.lockURL(under: base))
            })
        // 取り直した錠は、いまのパスが指すファイルのものである: 別の見張りは断られる
        do {
            _ = try WatchPlaceLock.claim(under: base)
            Issue.record("取り直した錠が効いていない")
        } catch {
            guard case .alreadyWatching = error else {
                Issue.record("別の失敗になった: \(error)")
                return
            }
        }
        lock.release()
    }
}
