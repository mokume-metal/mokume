// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation
import Testing
import mokume

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

    @Test("区画を起動より後に作っていたら、起動し直すことと、その理由を答える")
    func tellsToRestartWhenTheFacetWasMissing() throws {
        let directory = try makeDirectory()
        let tools = Tools(facets: Facets(directory: directory, waitLimit: 0.2), makeID: { "fixed" })
        // 区画が無いまま観測を頼む。要求は置かれるが、走っているスケッチは観測を持っていない
        let outcome = tools.call("observe", arguments: [:])
        #expect(outcome.isError)
        // 打つ手 — 案内どおりにすれば直る形になっていること (#227)
        #expect(outcome.text.contains("この呼び出しで作りました"))
        #expect(outcome.text.contains("**起動し直してください。**"))
        // 理由 — これが無いと「走っている最中に作れば拾われる」と読まれる
        #expect(outcome.text.contains("走っている最中に作っても"))
        // 区画はこの呼び出しが作ったので、mkdir を促してはならない
        #expect(!outcome.text.contains("mkdir"))
    }

    @Test("区画が先から在れば、順序ではなく立ち上がっていない側を答える")
    func tellsToLaunchWhenTheFacetWasAlreadyThere() throws {
        let directory = try makeDirectory()
        try FileManager.default.createDirectory(
            at: directory.appendingPathComponent(".mokume/observe", isDirectory: true),
            withIntermediateDirectories: true)

        let tools = Tools(facets: Facets(directory: directory, waitLimit: 0.2), makeID: { "fixed" })
        let outcome = tools.call("observe", arguments: [:])
        #expect(outcome.isError)
        // 順序は合っているので、そう言い切る。区画を作り直させる案内も出してはならない
        #expect(outcome.text.contains("区画を作る順序の問題ではありません"))
        #expect(!outcome.text.contains("この呼び出しで作りました"))
        #expect(outcome.text.contains("watch"))
    }

    @Test("区画の基準が割れているときの手も、どちらの案内にも出る")
    func namesTheFacetBaseInBothAnswers() throws {
        // #380 の着手条件 2 — watch と窓口で MOKUME_WORK_DIR が食い違うと、両者は別の区画を
        // 見る。症状は上の 2 本と同じ「誰も応えない」でしかないのに、**起動し直しても直らない**。
        // 手元で踏むと、案内どおり起動し直した先で「まだ立ち上がっていない」と言われる
        // (watch は走っているのに、である)。だから基準は両方の案内に出す
        let split = try makeDirectory()
        for existed in [false, true] {
            let directory = try makeDirectory()
            if existed {
                try FileManager.default.createDirectory(
                    at: directory.appendingPathComponent(".mokume/observe", isDirectory: true),
                    withIntermediateDirectories: true)
            }
            let tools = Tools(
                facets: Facets(directory: directory, waitLimit: 0.2, workDirectoryGiven: true),
                packageDirectory: split, makeID: { "fixed" })
            let outcome = tools.call("observe", arguments: [:])
            #expect(outcome.isError)
            // 窓口が見ている基準そのもの — watch が名乗る 1 行と突き合わせられる
            #expect(outcome.text.contains(directory.path))
            // 何がそれを決めたか。これが無いと、どちらを直せばよいか分からない
            #expect(outcome.text.contains("MOKUME_WORK_DIR"))
            // 起動し直しても直らない場合があること
            #expect(outcome.text.contains("起動し直しても直りません"))
            // 一覧への辿り口 (読む時点ごとに文面を書き足す形にしない)
            #expect(outcome.text.contains(Tools.startupDocument))
        }
    }

    @Test("基準を決めたものの言い方が、環境変数の有無で変わる")
    func tellsWhoDecidedTheFacetBase() throws {
        let directory = try makeDirectory()
        let given = Tools(
            facets: Facets(directory: directory, waitLimit: 0.2, workDirectoryGiven: true),
            makeID: { "fixed" })
        #expect(given.call("observe", arguments: [:]).text.contains("が指している"))

        let notGiven = Tools(
            facets: Facets(directory: directory, waitLimit: 0.2, workDirectoryGiven: false),
            makeID: { "fixed" })
        #expect(notGiven.call("observe", arguments: [:]).text.contains("は未設定"))
    }

    @Test("起動の瞬間に決まるものを、reference が一覧で配る")
    func servesTheStartupList() throws {
        let directory = try makeDirectory()
        let tools = Tools(facets: Facets(directory: directory, waitLimit: 0.2), makeID: { "fixed" })

        let outcome = tools.call("reference", arguments: ["name": Tools.startupDocument])
        #expect(!outcome.isError)
        // 一覧に居るものが**全部**出る。載せ忘れた読み手はここにも出ない
        for entry in StartupReads.all {
            #expect(outcome.text.contains(entry.name))
            #expect(outcome.text.contains(entry.key))
        }
        // 配っているものの一覧にも並ぶ (辿り着ける入口は 1 つ)
        #expect(tools.catalog(schemas: nil).contains(Tools.startupDocument))
    }

    @Test("入力でも同じ切り分けが効き、案内はその区画を名指す")
    func tellsToRestartForTheInputFacetToo() throws {
        let directory = try makeDirectory()
        let tools = Tools(facets: Facets(directory: directory, waitLimit: 0.2), makeID: { "fixed" })
        let outcome = tools.call(
            "input", arguments: ["events": [["type": "keyDown", "key": "a"]]])
        #expect(outcome.isError)
        #expect(outcome.text.contains("起動し直して"))
        #expect(outcome.text.contains(".mokume/input"))
        #expect(!outcome.text.contains(".mokume/observe"))
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

    /// 依存として mokume を引いた消費側の配置を模す。
    ///
    /// - Parameters:
    ///   - name: 依存の `packageRef.name`。取り違えの検査から変える
    ///   - local: パスで指した依存 (実体は作業ディレクトリの外) を模すなら `true`
    private func makeConsumer(name: String = "mokume", local: Bool = false) throws -> (
        work: URL, schemas: URL
    ) {
        let work = try makeDirectory()
        let package = try local
            ? makeDirectory()
            : work.appendingPathComponent(".build/checkouts/mokume", isDirectory: true)
        let schemas = package.appendingPathComponent("Schemas", isDirectory: true)
        try FileManager.default.createDirectory(at: schemas, withIntermediateDirectories: true)
        try Data(#"{"$id":"observe-report"}"#.utf8)
            .write(to: schemas.appendingPathComponent("observe-report.schema.json"))

        // 実測した形 (version 7)。パスで指したものは絶対パスがそのまま載る
        let state = local
            ? "{\"name\":\"fileSystem\",\"path\":\"\(package.path)\"}"
            : "{\"name\":\"sourceControlCheckout\",\"checkoutState\":{\"revision\":\"0000\"}}"
        let document = """
            {"object":{"artifacts":[],"dependencies":[{"basedOn":null,\
            "packageRef":{"identity":"\(local ? package.lastPathComponent : name)",\
            "kind":"\(local ? "fileSystem" : "remoteSourceControl")",\
            "location":"https://example.com/\(name).git","name":"\(name)"},\
            "state":\(state),"subpath":"mokume"}],"prebuilts":[]},"version":7}
            """
        let build = work.appendingPathComponent(".build", isDirectory: true)
        try FileManager.default.createDirectory(at: build, withIntermediateDirectories: true)
        try Data(document.utf8).write(to: build.appendingPathComponent("workspace-state.json"))
        return (work, schemas)
    }

    /// 消費側では届かない場所。実行ファイル起点の探索が当たらないことを保証する。
    private let nowhere = URL(fileURLWithPath: "/nowhere/bin/mokume-cli")

    @Test("依存として引いた消費側から、解決された実体の仕様を読む")
    func findsTheSchemasInTheResolvedDependency() throws {
        let consumer = try makeConsumer()
        let found = SchemasLocator.directory(
            workDirectory: consumer.work, executable: nowhere)
        #expect(found?.path == consumer.schemas.path)
        #expect(SchemasLocator.names(in: try #require(found)) == ["observe-report"])
    }

    @Test("パスで指した依存でも、実体の場所から仕様を読む")
    func findsTheSchemasInAPathDependency() throws {
        // パスで指すと identity は末尾のディレクトリ名になる。引くのは name の完全一致
        let consumer = try makeConsumer(local: true)
        let found = SchemasLocator.directory(
            workDirectory: consumer.work, executable: nowhere)
        #expect(found?.path == consumer.schemas.path)
    }

    @Test("名前の似た依存を取り違えない")
    func doesNotMistakeASimilarlyNamedDependency() throws {
        let consumer = try makeConsumer(name: "mokume-extras")
        #expect(
            SchemasLocator.directory(workDirectory: consumer.work, executable: nowhere) == nil)
    }

    @Test("依存から引けなければ、実行ファイルの位置から探す")
    func fallsBackToTheExecutable() throws {
        let repository = schemasRoot().deletingLastPathComponent()
        // このリポジトリの中で走らせたとき (.build/debug/mokume-cli)
        let executable = repository.appendingPathComponent(".build/debug/mokume-cli")
        let found = SchemasLocator.directory(
            workDirectory: try makeDirectory(), executable: executable)
        #expect(found?.path == schemasRoot().path)
    }

    @Test("仕様が見つからないときは、見た場所を並べて答える")
    func listsWhereItLookedForTheSchemas() throws {
        let consumer = try makeConsumer()
        // 実体はあるが、そこに Schemas/ が無い状態
        try FileManager.default.removeItem(at: consumer.schemas)

        let tools = Tools(
            facets: Facets(directory: consumer.work, waitLimit: 0.2), makeID: { "fixed" })
        let text = tools.schemasMissing()
        #expect(text.contains(consumer.schemas.path))
        #expect(text.contains("swift build"))

        let outcome = tools.call("reference", arguments: ["name": "observe-report"])
        #expect(outcome.isError)
        #expect(outcome.text.contains(consumer.schemas.path))
    }

    // ---------------------------------------------------------- 基準ディレクトリ

    @Test("区画は環境変数が決め、パッケージの場所は引数が決める")
    func splitsTheFacetBaseFromThePackageDirectory() {
        let cwd = URL(fileURLWithPath: "/cwd", isDirectory: true)
        let sketch = "/sketch"
        let elsewhere = "/elsewhere"

        // 区画はスケッチが書く場所。スケッチは環境変数に従うので、引数より強い
        let both = MCPCommand.directories(
            arguments: [sketch], environment: ["MOKUME_WORK_DIR": elsewhere],
            currentDirectory: cwd)
        #expect(both.package.path == sketch)
        #expect(both.facets.path == elsewhere)

        // 環境変数が無ければ、渡された場所が両方を兼ねる (いままでどおり)
        let given = MCPCommand.directories(
            arguments: [sketch], environment: [:], currentDirectory: cwd)
        #expect(given.package.path == sketch)
        #expect(given.facets.path == sketch)

        // 引数も無ければ作業ディレクトリ
        let neither = MCPCommand.directories(
            arguments: [], environment: [:], currentDirectory: cwd)
        #expect(neither.package.path == cwd.path)
        #expect(neither.facets.path == cwd.path)

        // 環境変数はパッケージの場所を動かさない (Package.swift も .build/ もそこにある)
        let environmentOnly = MCPCommand.directories(
            arguments: [], environment: ["MOKUME_WORK_DIR": elsewhere], currentDirectory: cwd)
        #expect(environmentOnly.package.path == cwd.path)
        #expect(environmentOnly.facets.path == elsewhere)
    }

    @Test("区画が別の場所でも、区画は区画から・仕様はパッケージの場所から読む")
    func readsEachAxisFromItsOwnBase() throws {
        let consumer = try makeConsumer()
        let work = try makeDirectory()
        let status = work.appendingPathComponent(".mokume/build/status.json")
        try FileManager.default.createDirectory(
            at: status.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(#"{"schemaVersion":1,"ok":true,"status":0,"output":""}"#.utf8).write(to: status)

        let tools = Tools(
            facets: Facets(directory: work, waitLimit: 0.2),
            packageDirectory: consumer.work, makeID: { "fixed" })

        // 作り直しの記録は区画から
        let build = tools.call("build_status", arguments: [:])
        #expect(!build.isError)
        // 面の仕様は、依存を解決したパッケージの場所から
        let catalog = tools.call("reference", arguments: [:])
        #expect(catalog.text.contains("- observe-report"))
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
