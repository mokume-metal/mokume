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
            guard case .alreadyWatching(let place) = error else {
                Issue.record("別の失敗になった: \(error)")
                return
            }
            #expect(place == WorkDirectory.root(under: base).path)
            #expect(error.message.contains(place))
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
        // **待つ側が期限を持つ。** 残ったら殺す
        defer { if holder.isRunning { kill(holder.processIdentifier, SIGKILL) } }
        let line = output.fileHandleForReading.availableData
        try #require(String(data: line, encoding: .utf8) == "held\n", "前任が錠を取れていない")

        // 生きている間は断る
        #expect(throws: CommandFailure.alreadyWatching(place: WorkDirectory.root(under: base).path)) {
            _ = try WatchPlaceLock.claim(under: base)
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
        #expect(throws: CommandFailure.alreadyWatching(place: WorkDirectory.root(under: root).path)) {
            try WatchCommand.run([root.path], watching: { _, _ in reachedTheLoop = true })
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

    @Test("見張りが終われば、次の見張りが同じ場所で始められる")
    func theNextWatchStartsOnceTheFirstHasEnded() throws {
        let root = try makeSketch()
        for round in 1...2 {
            let kept = SignalState.current()
            defer { kept.restore() }
            var reachedTheLoop = false
            try WatchCommand.run([root.path], watching: { _, _ in reachedTheLoop = true })
            #expect(reachedTheLoop, "\(round) 回目が断られた (錠を手放していない)")
        }
    }
}
