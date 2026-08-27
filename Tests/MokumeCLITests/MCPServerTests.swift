// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation
import Testing

@testable import MokumeCLI

@Suite("エージェントの窓口")
struct MCPServerTests {
    /// やりとりを記録する窓口を組む。
    private func makeServer(directory: URL, input: [String]) -> (MCPServer, Recorder) {
        let recorder = Recorder(lines: input)
        let server = MCPServer(
            tools: Tools(facets: Facets(directory: directory), makeID: { "fixed" }),
            readLine: { recorder.next() },
            write: { recorder.written.append($0) })
        return (server, recorder)
    }

    final class Recorder: @unchecked Sendable {
        private var lines: [String]
        var written: [String] = []
        init(lines: [String]) { self.lines = lines }
        func next() -> String? { lines.isEmpty ? nil : lines.removeFirst() }
    }

    private func makeDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("mokume-mcp-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func decode(_ line: String) throws -> [String: Any] {
        try #require(
            try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
    }

    @Test("繋ぎ始めの挨拶に、手続きの版と道具があることを答える")
    func answersTheHandshake() throws {
        let (server, recorder) = makeServer(
            directory: try makeDirectory(),
            input: [#"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}"#])
        server.serve()

        let result = try decode(try #require(recorder.written.first))["result"] as? [String: Any]
        #expect(result?["protocolVersion"] as? String == MCPServer.protocolVersion)
        #expect((result?["capabilities"] as? [String: Any])?["tools"] != nil)
    }

    @Test("道具立ての一覧を返す")
    func listsTheTools() throws {
        let (server, recorder) = makeServer(
            directory: try makeDirectory(),
            input: [#"{"jsonrpc":"2.0","id":2,"method":"tools/list"}"#])
        server.serve()

        let result = try decode(try #require(recorder.written.first))["result"] as? [String: Any]
        let tools = try #require(result?["tools"] as? [[String: Any]])
        #expect(Set(tools.compactMap { $0["name"] as? String })
            == ["observe", "build_status", "input", "reference"])
        // 説明の無い道具は、繋いだ側から使い道が分からない
        #expect(tools.allSatisfy { ($0["description"] as? String)?.isEmpty == false })
    }

    @Test("1 行の壊れで繋がりを切らない")
    func survivesAMalformedLine() throws {
        let (server, recorder) = makeServer(
            directory: try makeDirectory(),
            input: ["これは JSON ではない", #"{"jsonrpc":"2.0","id":3,"method":"tools/list"}"#])
        server.serve()

        // 壊れた行は落とすが、その次の呼び出しには答える
        #expect(recorder.written.count == 1)
        let answered = try #require(recorder.written.first)
        #expect(try decode(answered)["id"] as? Int == 3)
    }

    @Test("答えを待たない通知には、何も返さない")
    func staysSilentForNotifications() throws {
        let (server, recorder) = makeServer(
            directory: try makeDirectory(),
            input: [#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#])
        server.serve()
        #expect(recorder.written.isEmpty)
    }

    @Test("知らない手続きには、知らないと答える")
    func refusesUnknownMethods() throws {
        let (server, recorder) = makeServer(
            directory: try makeDirectory(),
            input: [#"{"jsonrpc":"2.0","id":9,"method":"nope"}"#])
        server.serve()
        let error = try decode(try #require(recorder.written.first))["error"] as? [String: Any]
        #expect(error?["code"] as? Int == -32601)
    }

    @Test("走っているスケッチが無ければ、何をすればよいかを添えて答える")
    func explainsWhenNothingIsRunning() throws {
        let directory = try makeDirectory()
        let tools = Tools(facets: Facets(directory: directory, waitLimit: 0.2), makeID: { "fixed" })
        // 誰も応えないので待ちの上限に達する。上限は短くしてある
        let outcome = tools.call("build_status", arguments: [:])
        #expect(outcome.isError)
        #expect(outcome.text.contains("watch"))
    }

    @Test("直近の作り直しの結果を、そのまま返す")
    func readsTheBuildStatus() throws {
        let directory = try makeDirectory()
        let status = directory.appendingPathComponent(".mokume/build/status.json")
        try FileManager.default.createDirectory(
            at: status.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(#"{"schemaVersion":1,"ok":false,"status":1,"output":"error: 何か"}"#.utf8)
            .write(to: status)

        let tools = Tools(facets: Facets(directory: directory, waitLimit: 0.2), makeID: { "fixed" })
        let outcome = tools.call("build_status", arguments: [:])
        #expect(!outcome.isError)
        #expect(outcome.text.contains("error: 何か"))
    }

    @Test("観測を頼むと、区画へ要求が置かれる")
    func writesTheObservationRequest() throws {
        let directory = try makeDirectory()
        let tools = Tools(facets: Facets(directory: directory, waitLimit: 0.2), makeID: { "fixed" })
        // 誰も応えないので上限まで待って諦めるが、要求は置かれている
        _ = tools.call("observe", arguments: ["scale": 0.5])

        let request = try #require(
            try JSONSerialization.jsonObject(
                with: try Data(
                    contentsOf: directory.appendingPathComponent(".mokume/observe/request.json")))
                as? [String: Any])
        #expect(request["id"] as? String == "fixed")
        #expect(request["scale"] as? Double == 0.5)
    }

    @Test("面の仕様を、手元にあるものから返す")
    func servesTheSchemasItHasAtHand() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Schemas")
        let names = SchemasLocator.names(in: root)
        #expect(names.contains("observe-report"))
        #expect(names.contains("input-request"))
        #expect(SchemasLocator.contents(of: "observe-report", in: root)?.contains("schemaVersion") == true)
        #expect(SchemasLocator.contents(of: "そんなものは無い", in: root) == nil)
    }
}
