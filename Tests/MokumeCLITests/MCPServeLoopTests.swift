// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation
import MokumeTestSupport
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
        let directory = try TestScratch.directory("mokume-serve")
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

    /// 識別子を順に返す作り手 (取り消した要求と次の要求を見分ける)。
    nonisolated final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var names: [String]
        init(_ names: [String]) { self.names = names }
        func next() -> String { lock.withLock { names.isEmpty ? "extra" : names.removeFirst() } }
    }

    /// 要求が区画に置かれたら取り消す手 (置かれる前に取り消すと、置かずに戻ってしまう)。
    private func cancelOncePlaced(_ token: Cancellation, in facets: Facets) {
        let request = WorkDirectory.requestURL(under: facets.observeFacet)
        DispatchQueue.global().async {
            let deadline = Date().addingTimeInterval(10)
            while !FileManager.default.fileExists(atPath: request.path), Date() < deadline {
                Thread.sleep(forTimeInterval: 0.005)
            }
            token.cancel()
        }
    }

    /// **取り消しはスケッチへ届かない** (#3030) ので、続けて撮る観測は撮り終えるまで区画を塞ぐ。
    /// その間に置いた次の要求の時間切れを、「応えない」と取り違えない。
    @Test("取り消した観測の次の呼び出しが時間切れになったら、前の要求をまだ撮っていると案内する")
    func explainsTheSketchIsStillOnTheCancelledRequest() throws {
        let directory = try TestScratch.directory("mokume-serve")
        defer { try? FileManager.default.removeItem(at: directory) }
        let facets = Facets(directory: directory, waitLimit: 0.3)
        let ids = Counter(["first", "second", "third"])
        let tools = Tools(facets: facets, makeID: { ids.next() })

        let token = Cancellation()
        cancelOncePlaced(token, in: facets)
        let cancelled = tools.call("observe", arguments: [:], cancellation: token)
        #expect(cancelled.text == "The call was cancelled")

        // スケッチはまだ first を撮っていて、second は拾われない
        let blocked = tools.call("observe", arguments: [:])
        #expect(blocked.isError)
        #expect(blocked.text.contains("cancelled earlier (id first)"), "\(blocked.text)")
        #expect(!blocked.text.contains("possibilities"), "起動し直しを勧める案内になっている")

        // first の応答が出ていれば、塞いでいたものは終わっている。いまの無応答は別の理由
        try Data(#"{"id":"first"}"#.utf8).write(to: WorkDirectory.reportURL(under: facets.observeFacet))
        let afterwards = tools.call("observe", arguments: [:])
        #expect(afterwards.text.contains("possibilities"), "\(afterwards.text)")
        #expect(!afterwards.text.contains("cancelled earlier"), "\(afterwards.text)")
    }

    /// 置く前に取り消されていたら、置かない。取り消された入力が区画へ届くと、スケッチはそれを
    /// 実行してしまう。
    @Test("取り消しが先に立っていた呼び出しは、要求を区画に置かずに戻る")
    func aCancelledCallPlacesNothing() throws {
        let directory = try TestScratch.directory("mokume-serve")
        defer { try? FileManager.default.removeItem(at: directory) }
        let facets = Facets(directory: directory, waitLimit: 5)
        let tools = Tools(facets: facets, makeID: { "fixed" })
        let token = Cancellation()
        token.cancel()

        let event = #"{"events":[{"type":"keyDown","code":1}]}"#
        let input = tools.call("input", arguments: try JSONSerialization.jsonObject(with: Data(event.utf8)) as? [String: Any] ?? [:], cancellation: token)
        let observe = tools.call("observe", arguments: [:], cancellation: token)
        #expect(input.text == "The call was cancelled")
        #expect(observe.text == "The call was cancelled")
        #expect(!FileManager.default.fileExists(atPath: WorkDirectory.requestURL(under: facets.inputFacet).path))
        #expect(!FileManager.default.fileExists(atPath: WorkDirectory.requestURL(under: facets.observeFacet).path))
        // 置いていないので、塞いでいる要求も覚えない
        #expect(tools.abandoned.id(for: facets.inputFacet) == nil)
        #expect(tools.abandoned.id(for: facets.observeFacet) == nil)
    }

    /// 答えを書いてから表を外すまでの隙に、同じ id の新しい要求が読まれて表を上書きする。
    /// 鍵だけで外すと、その新しい要求の取り消しが登録ごと消える。
    @Test("同じ id の新しい要求の取り消しは、前の要求を外しても残る")
    func retiringAnOldRequestKeepsTheNewOneWithTheSameId() throws {
        let inbox = Inbox()
        let writer = SerialWriter { _ in }
        let twice = Script([.line(list(1)), .line(list(1))])
        inbox.feed(readLine: { twice.next() }, writer: writer)
        let old = try #require(inbox.next())
        let new = try #require(inbox.next())
        #expect(old.cancellation !== new.cancellation)

        inbox.retire(old)  // 前の要求の答えを書いた後
        // 同じ id の取り消しは、いま登録されている新しい要求に届く
        let cancelling = Script([.line(cancel("1"))])
        inbox.feed(readLine: { cancelling.next() }, writer: writer)
        #expect(new.cancellation?.isCancelled == true)
        #expect(old.cancellation?.isCancelled == false)
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
