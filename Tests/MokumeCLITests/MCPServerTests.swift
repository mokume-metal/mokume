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

    /// このリポジトリの `Schemas/`。**検査の実行ファイルからは辿れない** (道具の実行ファイルと
    /// 深さが違う) ので、ソースの位置から引く。
    private func schemasRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Schemas")
    }

    @Test("面の仕様を、手元にあるものから返す")
    func servesTheSchemasItHasAtHand() throws {
        let root = schemasRoot()
        let names = SchemasLocator.names(in: root)
        #expect(names.contains("observe-report"))
        #expect(names.contains("input-request"))
        #expect(SchemasLocator.contents(of: "observe-report", in: root)?.contains("schemaVersion") == true)
        #expect(SchemasLocator.contents(of: "そんなものは無い", in: root) == nil)
    }

    // ---------------------------------------------------------- 公開 API の一覧

    /// 取ってきた回数と宛先を記録する。**検査はネットワークに触らない。**
    final class Fetches: @unchecked Sendable {
        var urls: [URL] = []
        var answer: Result<Data, Error> = .success(Data("# mokume v0.2.0 の公開 API\n".utf8))
        func fetch(_ url: URL) throws -> Data {
            urls.append(url)
            return try answer.get()
        }
    }

    struct Refused: Error {}

    /// 依存の pin 1 つぶん。
    private func pin(_ identity: String, _ version: String) -> String {
        """
        {"identity":"\(identity)","kind":"remoteSourceControl",\
        "location":"https://example.com/\(identity).git",\
        "state":{"revision":"0000","version":"\(version)"}}
        """
    }

    private func writeResolved(_ directory: URL, pins: String...) throws {
        try Data(#"{"pins":[\#(pins.joined(separator: ","))],"version":3}"#.utf8)
            .write(to: directory.appendingPathComponent("Package.resolved"))
    }

    private func makeTools(directory: URL, fetches: Fetches) -> Tools {
        Tools(
            facets: Facets(directory: directory, waitLimit: 0.2),
            apiList: APIListLocator(directory: directory, fetch: fetches.fetch),
            makeID: { "fixed" })
    }

    @Test("取り置きがあれば、取りに行かずにそれを返す")
    func servesTheCachedAPIList() throws {
        let directory = try makeDirectory()
        let cache = directory.appendingPathComponent(".mokume/reference/mokume-api.md")
        try FileManager.default.createDirectory(
            at: cache.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("# 取り置かれた一覧\n".utf8).write(to: cache)

        let fetches = Fetches()
        fetches.answer = .failure(Refused())  // 取りに行ったら落ちる
        let outcome = makeTools(directory: directory, fetches: fetches)
            .call("reference", arguments: ["name": "api"])

        #expect(!outcome.isError)
        #expect(fetches.urls.isEmpty)
        #expect(outcome.text.contains("出所: 取り置き"))
        #expect(outcome.text.contains("# 取り置かれた一覧"))
    }

    @Test("解決された版の資産を取ってきて取り置き、次からは取りに行かない")
    func downloadsTheAssetForTheResolvedVersionOnce() throws {
        let directory = try makeDirectory()
        try writeResolved(directory, pins: pin("mokume", "0.2.0"))
        let fetches = Fetches()
        let tools = makeTools(directory: directory, fetches: fetches)

        let first = tools.call("reference", arguments: ["name": "api"])
        #expect(!first.isError)
        #expect(first.text.contains("出所: 取ってきて取り置いた"))
        #expect(
            fetches.urls.map(\.absoluteString) == [
                "https://github.com/mokume-metal/mokume/releases/download/v0.2.0/mokume-api-v0.2.0.md"
            ])
        #expect(
            FileManager.default.fileExists(
                atPath: directory.appendingPathComponent(
                    ".mokume/reference/mokume-api-v0.2.0.md"
                ).path))

        let second = tools.call("reference", arguments: ["name": "api"])
        #expect(second.text.contains("出所: 取り置き"))
        #expect(fetches.urls.count == 1)
    }

    @Test("依存の識別子は完全一致で選ぶ")
    func matchesThePackageIdentityExactly() throws {
        let directory = try makeDirectory()
        // 前方一致で選ぶと、先に並んでいるこちらの版を取ってしまう
        try writeResolved(directory, pins: pin("mokume-extras", "9.9.9"), pin("mokume", "0.2.0"))
        let fetches = Fetches()
        _ = makeTools(directory: directory, fetches: fetches)
            .call("reference", arguments: ["name": "api"])
        #expect(fetches.urls.first?.absoluteString.contains("v0.2.0") == true)

        // 名前が似ているだけの依存しかなければ、版は引けない
        let other = try makeDirectory()
        try writeResolved(other, pins: pin("mokume-extras", "9.9.9"))
        let otherFetches = Fetches()
        let outcome = makeTools(directory: other, fetches: otherFetches)
            .call("reference", arguments: ["name": "api"])
        #expect(outcome.isError)
        #expect(otherFetches.urls.isEmpty)
    }

    @Test("版が引けなければ、組み立てて置く一手を添えて答える")
    func explainsHowToBuildTheListWhenTheVersionIsUnknown() throws {
        let directory = try makeDirectory()  // Package.resolved が無い = パスで指している
        let fetches = Fetches()
        let outcome = makeTools(directory: directory, fetches: fetches)
            .call("reference", arguments: ["name": "api"])

        #expect(outcome.isError)
        #expect(fetches.urls.isEmpty)
        #expect(outcome.text.contains("Package.resolved"))
        // 次の一手は、そのまま打てる形で入っている
        #expect(
            outcome.text.contains(
                "make api-list OUT=\"\(directory.appendingPathComponent(".mokume/reference/mokume-api.md").path)\""
            ))
    }

    @Test("資産を取ってこられなければ、理由と一手を添えて答える")
    func explainsWhenTheAssetCannotBeFetched() throws {
        let directory = try makeDirectory()
        try writeResolved(directory, pins: pin("mokume", "0.1.0"))
        let fetches = Fetches()
        fetches.answer = .failure(APIListLocator.FetchFailure("応答が 404 でした"))

        let outcome = makeTools(directory: directory, fetches: fetches)
            .call("reference", arguments: ["name": "api"])
        #expect(outcome.isError)
        #expect(outcome.text.contains("応答が 404 でした"))
        #expect(outcome.text.contains("make api-list"))
        // 取れなかったものを取り置かない
        #expect(
            !FileManager.default.fileExists(
                atPath: directory.appendingPathComponent(
                    ".mokume/reference/mokume-api-v0.1.0.md"
                ).path))
    }

    @Test("配る文書の一覧に、公開 API と面の仕様の両方が出る")
    func listsBothTheAPIListAndTheSchemas() throws {
        let directory = try makeDirectory()
        let tools = makeTools(directory: directory, fetches: Fetches())

        let catalog = tools.catalog(schemas: schemasRoot())
        #expect(catalog.contains("- api"))
        #expect(catalog.contains("- observe-report"))

        // 引数なしの呼び出しでも同じものが返る (面の仕様の在処は実行のされ方で決まる)
        let outcome = tools.call("reference", arguments: [:])
        #expect(!outcome.isError)
        #expect(outcome.text.contains("- api"))
    }
}
