// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation
import Synchronization
import Testing

@testable import MokumeCLI

/// `swift build` の段数の行の読み (#4121)。
@Suite("組み立ての段数を読む")
struct BuildProgressParseTests {
    @Test(
        "Swift Build と旧ビルドシステムの段数の行を読む",
        arguments: [
            // Swift Build が実際に出す形。`/` の両側は U+2009 (細い空白)
            ("[2\u{2009}/\u{2009}5] progdemo-product", BuildProgress(done: 2, total: 5)),
            ("[113\u{2009}/\u{2009}201]", BuildProgress(done: 113, total: 201)),
            ("[19 / 24]", BuildProgress(done: 19, total: 24)),
            ("[40 / 44] probe-product", BuildProgress(done: 40, total: 44)),
            ("[12/345] Compiling Sketch main.swift", BuildProgress(done: 12, total: 345)),
            ("[0 / 7]", BuildProgress(done: 0, total: 7)),
            ("[44 / 44]", BuildProgress(done: 44, total: 44)),
        ])
    func readsStepLines(line: String, expected: BuildProgress) {
        #expect(BuildProgress.parse(line) == expected)
    }

    @Test(
        "段数でない行・辻褄の合わない段数は読まない",
        arguments: [
            "[Planning deferred tasks]",
            "Building for debugging...",
            "Build complete! (1.72s)",
            "[5 / 3]",
            "[0 / 0]",
            "[1 / ]",
            "[/ 3]",
            "[1 / 3",
            " [1 / 3]",
            "error: [1 / 3]",
            "[１ / ３]",
            "",
        ])
    func ignoresOtherLines(line: String) {
        #expect(BuildProgress.parse(line) == nil)
    }
}

@Suite("管の断片を行に割る")
struct LineSplitterTests {
    @Test("行の途中で割れた断片は、次の断片とつないで 1 行にする")
    func joinsALineSplitAcrossChunks() {
        var lines = LineSplitter()
        #expect(lines.feed(Data("[1 / 3]\n[2 /".utf8)) == ["[1 / 3]"])
        #expect(lines.feed(Data(" 3]\r\n".utf8)) == ["[2 / 3]"])
        #expect(lines.finish() == nil)
    }

    /// **UTF-8 の文字の途中で割れても化けない。** 改行のバイトは多バイト文字の中に現れないので、
    /// 行を割るのは完結した行だけになる。
    @Test("多バイト文字の途中で割れた断片も、文字を化けさせない")
    func keepsMultibyteCharactersWhole() {
        let bytes = Array("木目\n".utf8)
        var lines = LineSplitter()
        #expect(lines.feed(Data(bytes[..<2])).isEmpty)
        #expect(lines.feed(Data(bytes[2...])) == ["木目"])
    }

    @Test("改行で閉じていない最後の行は、終わりに返す")
    func returnsTheUnterminatedTail() {
        var lines = LineSplitter()
        #expect(lines.feed(Data("a\nb".utf8)) == ["a"])
        #expect(lines.finish() == "b")
        #expect(lines.finish() == nil)
    }
}

@Suite("作り直しの出力から段数を拾う")
struct CaptureProgressTests {
    nonisolated final class Collected: Sendable {
        let steps = Mutex<[BuildProgress]>([])
    }

    /// **段数を拾っても、返す出力は 1 バイトも変えない。** 記録 (`build-status`) と MCP はこの出力を読む。
    @Test("段数を順に拾い、出力の全文はそのまま返す")
    func reportsStepsAndKeepsTheOutput() throws {
        // `\342\200\211` は U+2009 (細い空白) の UTF-8。Swift Build が実際に出す形
        let script = "printf 'Building for debugging...\\n[1\\342\\200\\211/\\342\\200\\2114]\\n'; sleep 0.1; "
            + "printf '[3 / 6] app\\n' >&2; printf 'Build complete!\\n[6 / 6]'"
        let collected = Collected()
        let withProgress = try RunCommand.capture(
            shell(script), capturing: true, errors: .merge,
            progress: { step in collected.steps.withLock { $0.append(step) } })
        let without = try RunCommand.capture(shell(script), capturing: true, errors: .merge)

        #expect(
            collected.steps.withLock { $0 }
                == [
                    BuildProgress(done: 1, total: 4), BuildProgress(done: 3, total: 6),
                    BuildProgress(done: 6, total: 6),
                ])
        #expect(withProgress.output == without.output)
        #expect(withProgress.status == 0)
    }

    private func shell(_ script: String) -> Process {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", script]
        return process
    }
}

@Suite("段数を main actor へ届ける")
@MainActor
struct BuildProgressMailboxTests {
    nonisolated final class Queue: Sendable {
        let pending = Mutex<[@Sendable () -> Void]>([])

        func run() {
            let work = pending.withLock { pending in
                defer { pending.removeAll() }
                return pending
            }
            work.forEach { $0() }
        }
    }

    /// **積む配達は 1 つまで、届けるのは最新の値。** 行ごとに積むと、大きな組み立てで main が溢れる。
    @Test("配達を待つ間に置かれた段数は、最新の 1 つにまとめて届ける")
    func coalescesToTheLatest() {
        let queue = Queue()
        let mailbox = BuildProgressMailbox(schedule: { work in queue.pending.withLock { $0.append(work) } })
        var delivered: [BuildProgress] = []
        mailbox.deliver = { delivered.append($0) }

        mailbox.post(BuildProgress(done: 1, total: 9))
        mailbox.post(BuildProgress(done: 2, total: 9))
        mailbox.post(BuildProgress(done: 3, total: 12))
        #expect(queue.pending.withLock { $0.count } == 1)
        queue.run()
        #expect(delivered == [BuildProgress(done: 3, total: 12)])

        // 届けた後に置かれた段数は、新しく配達を積む
        mailbox.post(BuildProgress(done: 4, total: 12))
        #expect(queue.pending.withLock { $0.count } == 1)
        queue.run()
        #expect(delivered == [BuildProgress(done: 3, total: 12), BuildProgress(done: 4, total: 12)])
    }

    /// 本番の配達口 (`DispatchQueue.main`) を通っても届く。
    @Test("既定の配達口で、main actor の受け手へ届く")
    func deliversThroughTheMainQueue() async {
        let mailbox = BuildProgressMailbox()
        var delivered: [BuildProgress] = []
        mailbox.deliver = { delivered.append($0) }

        await Task.detached { mailbox.post(BuildProgress(done: 7, total: 8)) }.value
        // 積んだ順に走るので、後から積んだこの合図より前に配達は済んでいる
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
        #expect(delivered == [BuildProgress(done: 7, total: 8)])
    }
}
