// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation
import Testing
import mokume

@testable import MokumeCLI

/// 窓口の読みと実行の分け方 ([#2355](https://github.com/mokume-metal/mokume/issues/2355))。
///
/// **順序で見る。時間では見ない。** 道具を待たせたまま `ping` を流し、その答えが先に書かれることを
/// 見る。待たせ方は「誰も応えない区画への `observe`」で、取り消されるか上限 (下では 10 秒) が来るまで
/// 戻らない。流すタイミングは時計ではなく、区画に要求が置かれた (= 道具が待ちに入った) こと・答えが
/// 書かれたことを見て決める。
@Suite("窓口の読みと実行の分け方")
struct MCPServeLoopTests {
    /// 読み取りの手が順に読む脚本。`wait` の段は条件が成り立つまで (上限つきで) 読むのを止める。
    nonisolated final class Script: @unchecked Sendable {
        enum Step: Sendable {
            case line(String)
            case wait(@Sendable () -> Bool)
        }

        private let lock = NSLock()
        private var steps: [Step]

        init(_ steps: [Step]) { self.steps = steps }

        func next() -> String? {
            while true {
                let step: Step? = lock.withLock { steps.isEmpty ? nil : steps.removeFirst() }
                switch step {
                case nil: return nil
                case .line(let text)?: return text
                case .wait(let condition)?:
                    // 条件が成り立たないまま上限が来ても、先へ進む (検査が赤になるだけで固まらない)
                    let deadline = Date().addingTimeInterval(15)
                    while !condition(), Date() < deadline { Thread.sleep(forTimeInterval: 0.005) }
                }
            }
        }
    }

    nonisolated final class Answers: @unchecked Sendable {
        private let lock = NSLock()
        private var lines: [String] = []
        func record(_ line: String) { lock.withLock { lines.append(line) } }
        var all: [String] { lock.withLock { lines } }
    }

    private static let observeCall = #"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"observe","arguments":{}}}"#

    private func ping(_ id: Int) -> String { #"{"jsonrpc":"2.0","id":\#(id),"method":"ping"}"# }
    private func list(_ id: Int) -> String { #"{"jsonrpc":"2.0","id":\#(id),"method":"tools/list"}"# }
    private func cancel(_ id: String) -> String {
        #"{"jsonrpc":"2.0","method":"notifications/cancelled","params":{"requestId":\#(id)}}"#
    }

    private func ids(_ answers: [String]) throws -> [String] {
        try answers.map {
            let object = try #require(try JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any])
            return "\(object["id"] ?? "absent")"
        }
    }

    /// 脚本を読ませて、窓口が書いた行を返す。区画は誰も応えない (`observe` は取り消されるまで待つ)。
    private func serve(
        _ steps: (_ requestPlaced: @escaping @Sendable () -> Bool, _ answered: @escaping @Sendable (Int) -> Bool)
            -> [Script.Step]
    ) throws -> [String] {
        try serveInspecting(steps).answers
    }

    /// ``serve(_:)`` に加えて、入力の区画へ要求が置かれたかを返す。
    private func serveInspecting(
        _ steps: (_ requestPlaced: @escaping @Sendable () -> Bool, _ answered: @escaping @Sendable (Int) -> Bool)
            -> [Script.Step]
    ) throws -> (answers: [String], inputRequestPlaced: Bool) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("mokume-serve-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        // 待ちの上限。取り消しが効かなければ、この長さの後に `observe` の答えが書かれて赤になる
        let facets = Facets(directory: directory, waitLimit: 10)
        let request = WorkDirectory.requestURL(under: facets.observeFacet)
        let answers = Answers()
        let script = Script(
            steps(
                { FileManager.default.fileExists(atPath: request.path) },
                { answers.all.count >= $0 }))
        let server = MCPServer(
            tools: Tools(facets: facets, makeID: { "fixed" }),
            readLine: { script.next() }, write: { answers.record($0) })
        server.serve()
        let inputRequest = WorkDirectory.requestURL(under: facets.inputFacet)
        return (answers.all, FileManager.default.fileExists(atPath: inputRequest.path))
    }

    @Test("道具が待っている間に届いた ping に、先に答え、取り消された要求には答えない")
    func answersPingWhileAToolIsRunning() throws {
        let written = try serve { placed, answered in
            [
                .line(Self.observeCall), .wait(placed),
                .line(ping(2)), .wait({ answered(1) }),
                .line(cancel("1")),
            ]
        }
        // ping の答えだけ。observe の答えは、取り消されたので書かれない
        #expect(try ids(written) == ["2"], "\(written)")
        #expect(written.first?.contains(#""result":{}"#) == true)
    }

    @Test("取り消しは実行中の道具の待ちを切り、その後に届いた要求には答える")
    func cancelReachesTheRunningToolAndLaterCallsAreAnswered() throws {
        let written = try serve { placed, _ in
            [.line(Self.observeCall), .wait(placed), .line(cancel("1")), .line(list(3))]
        }
        #expect(try ids(written) == ["3"], "\(written)")
        #expect(written.first?.contains("observe") == true)
    }

    @Test("走るのを待っている要求も、取り消せば走らせず答えない")
    func cancelledQueuedCallsNeverRun() throws {
        // 2 は 1 の後ろで待つ入力の頼み。2 を取り消してから 1 を取り消す (読む順)
        let queued = #"{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"input","arguments":{"events":[]}}}"#
        let (written, inputRequestPlaced) = try serveInspecting { placed, _ in
            [.line(Self.observeCall), .wait(placed), .line(queued), .line(cancel("2")), .line(cancel("1"))]
        }
        #expect(written.isEmpty, "\(written)")
        // 走らせていない — 走っていれば、取り消されていても入力の区画に要求を置く
        #expect(!inputRequestPlaced)
    }

    @Test("答え終えた id・知らない id の取り消しは、何も起こさず何も書かない")
    func cancellingFinishedOrUnknownIdsDoesNothing() throws {
        let written = try serve { _, answered in
            [
                .line(list(1)), .wait({ answered(1) }),
                // 答え終えた 1・知らない 99・文字列の "2" (数の 2 とは別の id)・読めない requestId
                .line(cancel("1")), .line(cancel("99")), .line(cancel(#""2""#)), .line(cancel("null")),
                .line(list(2)),
            ]
        }
        #expect(try ids(written) == ["1", "2"], "\(written)")
        #expect(written.allSatisfy { $0.contains("tools") })
    }

    @Test("文字列の id と数の id は、別の id として引く")
    func stringAndNumberIdsAreDistinct() {
        #expect(JSONRPC.ID.string("1").key != JSONRPC.ID.number(1).key)
        #expect(JSONRPC.ID.number(1).key == JSONRPC.ID.number(1.0).key)
    }

    /// 2 つの手が同時に書いても、標準出力の 1 行は 1 つの答えで完結する。書き口は 1 文字ずつ
    /// 別々に書くので、鍵が無ければ行は混ざる。
    @Test("2 つの手から同時に書いても、行が混ざらない")
    func writesFromTwoThreadsDoNotInterleave() {
        nonisolated final class Sink: @unchecked Sendable {
            private let lock = NSLock()
            private var text = ""
            func put(_ character: Character) {
                lock.withLock { text.append(character) }
                // 書き手が入れ替わる隙を作る
                sched_yield()
            }
            var contents: String { lock.withLock { text } }
        }
        let sink = Sink()
        let writer = SerialWriter { line in
            for character in line { sink.put(character) }
            sink.put("\n")
        }
        let line = { (letter: String) in String(repeating: letter, count: 60) }
        let (a, b) = (line("a"), line("b"))
        DispatchQueue.concurrentPerform(iterations: 2) { index in
            for _ in 0..<100 { writer.send(index == 0 ? a : b) }
        }
        let lines = sink.contents.split(separator: "\n", omittingEmptySubsequences: false).dropLast()
        #expect(lines.count == 200)
        #expect(lines.allSatisfy { $0 == a || $0 == b }, "行が混ざった")
    }
}
