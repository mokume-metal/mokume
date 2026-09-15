// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation
import Testing

@testable import MokumeCLI

/// 宣言から導いたものの持ち回り。
///
/// **数えているのは `swift` の本数である。** 本物の導き手は `swift package dump-package` と
/// `swift build --show-bin-path` を 1 本ずつ起こすので、ここで導き手が呼ばれた回数を固定
/// すれば、起こす本数がそのまま固定される — `swift` を 1 本も起こさずに
/// ([#1067](https://github.com/mokume-metal/mokume/issues/1067))。
@Suite("宣言から導いたものの持ち回り")
struct BuildResolutionTests {
    /// 導いた回数を数える替え玉。
    ///
    /// **糸をまたいで数えない。** `current()` は同じ糸から順に呼ぶので鍵は要らないが、
    /// 送れる形にはしておく (導き手は `Sendable` として持ち回る)。
    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        var resolved: Int { lock.withLock { count } }

        func resolution(for directory: URL) -> BuildResolution {
            lock.withLock { count += 1 }
            return BuildResolution(
                context: BuildContext(
                    configuration: nil, place: .inPackage(.localDependency), product: "sketch"),
                binPath: directory.appendingPathComponent("bin", isDirectory: true))
        }
    }

    private func makeSketch(manifest: String = "// swift-tools-version: 6.2\n") throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("mokume-resolver-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try write(manifest, to: directory)
        return directory
    }

    private func write(_ manifest: String, to directory: URL) throws {
        try Data(manifest.utf8).write(
            to: directory.appendingPathComponent("Package.swift", isDirectory: false))
    }

    @Test("宣言が変わっていなければ、導き直さない")
    func anUnchangedManifestIsNotResolvedAgain() throws {
        let directory = try makeSketch()
        defer { try? FileManager.default.removeItem(at: directory) }
        let counter = Counter()
        let resolver = BuildResolver(directory: directory) { counter.resolution(for: $0) }

        let first = try resolver.current()
        let second = try resolver.current()

        #expect(counter.resolved == 1, "宣言が変わっていないのに導き直している")
        #expect(first == second)
    }

    /// **持ち回ったままにすると、product を改名した回に前の名前の実行ファイルを探す。**
    /// 症状は「作り直しは通ったのに、建っていないと言われる」である (#1067 の完了条件 3)。
    @Test("宣言が変わったら、導き直す")
    func aChangedManifestIsResolvedAgain() throws {
        let directory = try makeSketch()
        defer { try? FileManager.default.removeItem(at: directory) }
        let counter = Counter()
        let resolver = BuildResolver(directory: directory) { counter.resolution(for: $0) }

        _ = try resolver.current()
        try write("// swift-tools-version: 6.2\n// changed\n", to: directory)
        _ = try resolver.current()

        #expect(counter.resolved == 2, "宣言が変わったのに持ち回ったものを返している")
    }

    /// **世代は中身から導く。** 時刻や大きさで振ると、**中身を変えずに保存しただけ**の回に
    /// `swift` を 2 本起こすことになる — 編集器は保存のたびに時刻を進めるので、これは
    /// 珍しい操作ではない (``SourceStamp`` が全体に対してやっているのと同じ流儀)。
    @Test("中身が同じまま書き直された宣言は、導き直さない")
    func aManifestRewrittenWithTheSameContentsIsNotResolvedAgain() throws {
        let original = "// swift-tools-version: 6.2\n"
        let directory = try makeSketch(manifest: original)
        defer { try? FileManager.default.removeItem(at: directory) }
        let counter = Counter()
        let resolver = BuildResolver(directory: directory) { counter.resolution(for: $0) }

        _ = try resolver.current()
        try write(original, to: directory)
        _ = try resolver.current()

        #expect(counter.resolved == 1, "中身ではなく時刻や大きさで世代を見ている")
    }

    /// **読めない間も導き直さない。** `Package.swift` を壊した状態から直していく途中は、
    /// 導いても同じ「宣言が読めなかった」に落ちる — 直した回に世代が変わって導き直される。
    @Test("宣言が読めない間は、導き直さない")
    func anUnreadableManifestIsNotResolvedAgain() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("mokume-resolver-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let counter = Counter()
        let resolver = BuildResolver(directory: directory) { counter.resolution(for: $0) }

        _ = try resolver.current()
        _ = try resolver.current()
        #expect(counter.resolved == 1)

        // 置かれたら、そこで導き直す
        try write("// swift-tools-version: 6.2\n", to: directory)
        _ = try resolver.current()
        #expect(counter.resolved == 2, "宣言が置かれたのに、読めなかったときのものを返している")
    }

    /// 導き手が投げた回は、持ち回らない — 次の `current()` がもう 1 度試す。
    /// **投げたものを持ち回る形にすると、直しても直らない。**
    @Test("導けなかった回は、持ち回らない")
    func aFailedResolutionIsNotCarried() throws {
        let directory = try makeSketch()
        defer { try? FileManager.default.removeItem(at: directory) }
        let counter = Counter()
        var fails = true
        let resolver = BuildResolver(directory: directory) {
            directory throws(CommandFailure) in
            if fails { throw .toolchainMissing("swift") }
            return counter.resolution(for: directory)
        }

        #expect(throws: CommandFailure.toolchainMissing("swift")) { try resolver.current() }
        fails = false
        _ = try resolver.current()
        #expect(counter.resolved == 1, "導けなかった回のあと、導き直していない")
    }
}
