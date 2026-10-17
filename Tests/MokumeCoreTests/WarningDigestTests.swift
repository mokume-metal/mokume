// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation
import MokumeDiagnostics
import Testing

@testable import MokumeCore

/// スケッチが言った警告の溜め場 (``WarningDigest``) の振る舞い (#2761)。GPU は要らない。
///
/// 検査は ``Diagnostics/digest`` へ自分の溜め場を差して走る。溜め場はプロセスで 1 つなので、
/// 差さないと、並んで走る検査が互いの警告を取り合う。
@MainActor
@Suite("スケッチが言った警告の溜め場")
struct WarningDigestTests {
    /// 検査が自分の溜め場だけを見る。
    private func scoped<Result>(
        limit: Int = WarningDigest.defaultLimit, _ body: (WarningDigest) throws -> Result
    ) rethrows -> Result {
        let digest = WarningDigest(limit: limit)
        return try Diagnostics.$digest.withValue(digest) { try body(digest) }
    }

    @Test("言った順に返し、返したら空になる")
    func handsOutInOrderAndEmpties() {
        scoped { _ in
            Diagnostics.warn("first")
            Diagnostics.warn("second")
            #expect(Diagnostics.takeUnreported() == ["first", "second"])
            #expect(Diagnostics.takeUnreported().isEmpty, "2 度目の観測にも載った")
            Diagnostics.warn("third")
            #expect(Diagnostics.takeUnreported() == ["third"])
        }
    }

    @Test("上限ちょうどまでは名乗らず、越えたら最初の上限ぶんと越えた数の 1 行になる")
    func capsAtTheLimitAndNamesTheRest() {
        scoped(limit: 3) { _ in
            for number in 1...3 { Diagnostics.warn("line \(number)") }
            #expect(Diagnostics.takeUnreported() == ["line 1", "line 2", "line 3"])

            for number in 1...10 { Diagnostics.warn("line \(number)") }
            let taken = Diagnostics.takeUnreported()
            #expect(taken.count == 4, "上限 + 1 行に収まっていない: \(taken.count)")
            #expect(Array(taken.prefix(3)) == ["line 1", "line 2", "line 3"], "最初の側を残していない")
            #expect(taken.last == WarningDigest.overflowNotice(kept: 3, dropped: 7))

            // 名乗った後は数え直す。越えなかった次の回に、前の数が残らない
            Diagnostics.warn("again")
            #expect(Diagnostics.takeUnreported() == ["again"])
        }
    }

    @Test("同じ文を毎フレーム言う口でも、応答の行数は上限 + 1 に収まる")
    func aMouthThatRepeatsEveryFrameIsBounded() {
        scoped { _ in
            for _ in 0..<1_000 { Diagnostics.warn("endDraw(): could not finish drawing") }
            let taken = Diagnostics.takeUnreported()
            #expect(taken.count == WarningDigest.defaultLimit + 1)
            #expect(
                taken.last
                    == WarningDigest.overflowNotice(
                        kept: WarningDigest.defaultLimit, dropped: 1_000 - WarningDigest.defaultLimit))
        }
    }

    @Test("名乗る行は完全な文で、数を差し込むだけ")
    func theOverflowNoticeIsOneSentenceWithNumbers() {
        let text = WarningDigest.overflowNotice(kept: 20, dropped: 1)
        #expect(!text.contains("\n"), "標準エラーと同じく 1 行")
        #expect(text.contains("20") && text.contains("1"))
    }

    @Test("別々のスレッドから言っても、数は合う")
    func countsAcrossThreads() async {
        let digest = WarningDigest(limit: 50)
        await withTaskGroup(of: Void.self) { group in
            for worker in 0..<8 {
                group.addTask {
                    for number in 0..<100 { digest.record("\(worker)-\(number)") }
                }
            }
        }
        let taken = digest.takeUnreported()
        #expect(taken.count == 51)
        #expect(taken.last == WarningDigest.overflowNotice(kept: 50, dropped: 750))
    }

    @Test("差した溜め場の外へは漏れない")
    func aScopedDigestDoesNotLeak() {
        scoped { _ in
            Diagnostics.warn("inside")
            Diagnostics.$digest.withValue(WarningDigest()) {
                Diagnostics.warn("nested")
                #expect(Diagnostics.takeUnreported() == ["nested"])
            }
            #expect(Diagnostics.takeUnreported() == ["inside"])
        }
    }

    // MARK: - 口ごとの経路 (完了条件 5〜8)

    /// `WarningLog.warnOnce` を通る警告は、言った回の 1 度だけ溜まる。
    @Test("WarningLog.warnOnce を通る警告は 1 度だけ載り、2 度目の観測には載らない")
    func warnOnceMouthsAreCarriedOnce() {
        scoped { _ in
            var log = WarningLog<String>()
            for _ in 0..<3 { log.warnOnce("key", "said through warnOnce") }
            #expect(Diagnostics.takeUnreported() == ["said through warnOnce"])
            log.warnOnce("key", "said through warnOnce")
            #expect(Diagnostics.takeUnreported().isEmpty)
        }
    }

    /// 標準エラーの 1 行は、溜め場を足しても今までどおり 1 度だけ出る (完了条件 2)。標準エラーは
    /// プロセスのものなので、子のプロセスで言わせて読む。
    @Test("標準エラーの 1 行は、載せるようになった後も 1 度だけ出る")
    func standardErrorStillGetsOneLine() async throws {
        let result = await #expect(processExitsWith: .success, observing: [\.standardErrorContent]) {
            var log = WarningLog<String>()
            for _ in 0..<3 { log.warnOnce("key", "said once on standard error") }
            Diagnostics.warn("said directly on standard error")
            _ = Diagnostics.takeUnreported()
        }
        guard let result else { return }
        let errors = String(decoding: result.standardErrorContent, as: UTF8.self)
        let lines = errors.split(separator: "\n")
        #expect(lines.filter { $0.contains("said once on standard error") }.count == 1, "\(errors)")
        #expect(lines.filter { $0.contains("said directly on standard error") }.count == 1, "\(errors)")
    }

    /// `Diagnostics.warn` を直に呼ぶ口は、呼んだ数だけ溜まる (控えは呼ぶ側のもの)。
    @Test("Diagnostics.warn を直に呼ぶ警告は、呼んだ回に載り、2 度目の観測には載らない")
    func directMouthsAreCarriedOnce() {
        scoped { _ in
            Diagnostics.warn("said directly")
            #expect(Diagnostics.takeUnreported() == ["said directly"])
            #expect(Diagnostics.takeUnreported().isEmpty)
        }
    }

    /// `OutsideRun` は `WarningLog` を通って `Diagnostics.warn` へ言う。載せる口を別に持つと 2 度載る。
    @Test("OutsideRun の行は、1 度だけ載る (経路を 1 つに畳んである)")
    func outsideRunLinesAreCarriedExactlyOnce() throws {
        let log = OutsideRun()
        try scoped { _ in
            try OutsideRun.$current.withValue(log) {
                OutsideRunTests.Painter().circle(0, 0, 10)
                OutsideRunTests.Painter().circle(0, 0, 10)
                let taken = Diagnostics.takeUnreported()
                #expect(taken.count == 1, "OutsideRun の 1 つの警告が \(taken.count) 行載った: \(taken)")
                let line = try #require(taken.first)
                #expect(line.hasPrefix("circle(_:_:_:) only works inside setup()"))
                #expect(log.messages == taken, "検査が読む控えと、載った行が同じ文面")
                #expect(Diagnostics.takeUnreported().isEmpty)
            }
        }
    }

    /// 例: `draw()` の中で `loadImage` を呼んだ後の観測に、#2744 の警告が 1 度載る。
    @Test("draw() の中の同期の読み込みの警告 (#2744) も、1 度載る")
    func blockingLoadNoticeIsCarried() {
        scoped { _ in
            let loads = BlockingLoads()
            for _ in 0..<3 {
                loads.isDrawing = true
                loads.notice("loadImage(_:)", instead: "requestImage(_:)")
                loads.isDrawing = false
            }
            #expect(
                Diagnostics.takeUnreported()
                    == [BlockingLoads.notice("loadImage(_:)", instead: "requestImage(_:)")])
        }
    }

    // MARK: - 範囲 (完了条件 8)

    static let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()

    /// 標準エラーへ直に書く場所は、そこから警告が溜め場を素通りする。
    /// スケッチのプロセスが言う警告は、MokumeCore・Audio・Camera・Network・Gamepad のすべてで
    /// `Diagnostics.warn` を通る。**通らない書き方を足すと、その警告だけが観測に載らない。**
    static let directWriteAllowlist = [
        "Sources/MokumeDiagnostics/Diagnostics.swift":
            "溜め場へ控える側 (warn の本体)",
        "Sources/MokumeCore/Display/SketchApplication.swift":
            "起動に失敗して終わるときの最後の 1 文。スケッチが走り出す前で、観測を答える相手が居ない",
    ]

    @Test("スケッチのプロセスの警告は、すべて Diagnostics.warn を通る")
    func everySketchModuleWarnsThroughDiagnostics() throws {
        let modules = ["MokumeCore", "MokumeAudio", "MokumeCamera", "MokumeNetwork", "MokumeGamepad", "MokumeDiagnostics"]
        let marks = ["FileHandle.standardError", "fputs(", "stderr"]
        var found: Set<String> = []
        for module in modules {
            let directory = Self.root.appendingPathComponent("Sources/\(module)")
            let files = try #require(
                FileManager.default.enumerator(at: directory, includingPropertiesForKeys: nil),
                "\(module) を読めない")
            for case let file as URL in files where file.pathExtension == "swift" {
                let text = try String(contentsOf: file, encoding: .utf8)
                let code = text.split(separator: "\n", omittingEmptySubsequences: false)
                    .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
                if code.contains(where: { line in marks.contains { line.contains($0) } }) {
                    found.insert(String(file.path.dropFirst(Self.root.path.count + 1)))
                }
            }
        }
        #expect(
            found == Set(Self.directWriteAllowlist.keys),
            "標準エラーへ直に書く場所が一覧とずれている: \(found.symmetricDifference(Self.directWriteAllowlist.keys).sorted())")
    }
}
