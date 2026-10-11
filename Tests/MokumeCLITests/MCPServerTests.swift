// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation
import Testing
import mokume

@testable import MokumeCLI

@Suite("エージェントの窓口")
struct MCPServerTests {
    /// やりとりを記録する窓口を組む。
    ///
    /// 待ちの上限は短くしてある。道具を走らせてしまう誤り (#2317) を、検査が既定の
    /// 5 秒を待たずに見られるようにするため。
    private func makeServer(directory: URL, input: [String]) -> (MCPServer, Recorder) {
        let recorder = Recorder(lines: input)
        let server = MCPServer(
            tools: Tools(facets: Facets(directory: directory, waitLimit: 0.2), makeID: { "fixed" }),
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

    /// 観測の区画に置かれる要求。道具が走ったかどうかは、これが在るかで分かる。
    private func observeRequest(in directory: URL) -> URL {
        directory.appendingPathComponent(".mokume/observe/request.json")
    }

    private func decode(_ line: String) throws -> [String: Any] {
        try #require(
            try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
    }

    /// 答えの `id` を、比べられる綴りにする (数はそのまま・文字列は引用符付き・`null`)。
    private func idOf(_ object: [String: Any]) -> String {
        switch object["id"] {
        case nil: "absent"
        case is NSNull: "null"
        case let text as String: "\"\(text)\""
        case let number as NSNumber: number.stringValue
        default: "unreadable"
        }
    }

    /// 誤りの答えの符号。誤りでなければ `nil`。
    private func errorCode(_ object: [String: Any]) -> Int? {
        (object["error"] as? [String: Any])?["code"] as? Int
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
        // 繋いだ側が「古い窓口に繋がっている」と気付ける唯一の手掛かり (#634)
        let info = result?["serverInfo"] as? [String: Any]
        #expect(info?["version"] as? String == ToolVersion.describe())
        #expect(info?["version"] as? String != "0")
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

    @Test("1 行の壊れで繋がりを切らず、壊れた行には誤りを 1 行返す")
    func survivesAMalformedLine() throws {
        let (server, recorder) = makeServer(
            directory: try makeDirectory(),
            input: ["これは JSON ではない", #"{"jsonrpc":"2.0","id":3,"method":"tools/list"}"#])
        server.serve()

        // 壊れた行には id を読めないので null で -32700 を返し、その次の呼び出しにも答える。
        // 黙ると、繋いでいる側からは答えが来ないのか遅れているのか見分けが付かない (#2317)
        try #require(recorder.written.count == 2)
        let refused = try decode(recorder.written[0])
        #expect(refused["jsonrpc"] as? String == "2.0")
        #expect(idOf(refused) == "null")
        #expect(errorCode(refused) == -32700)
        let answered = try decode(recorder.written[1])
        #expect(idOf(answered) == "3")
        #expect(answered["result"] != nil)
    }

    @Test(
        "答えを待たない通知には、名前によらず何も返さず、道具も走らせない",
        arguments: [
            #"{"jsonrpc":"2.0","method":"notifications/initialized"}"#,
            #"{"jsonrpc":"2.0","method":"initialize","params":{}}"#,
            #"{"jsonrpc":"2.0","method":"tools/list"}"#,
            #"{"jsonrpc":"2.0","method":"tools/call","params":{"name":"observe","arguments":{}}}"#,
            #"{"jsonrpc":"2.0","method":"ping"}"#,
        ])
    func staysSilentForNotifications(notification: String) throws {
        let directory = try makeDirectory()
        let (server, recorder) = makeServer(directory: directory, input: [notification])
        server.serve()
        // JSON-RPC 2.0 §4.1 — 通知には、手続きの名前によらず答えない (#2317)
        #expect(recorder.written.isEmpty)
        // 通知の tools/call は道具を走らせない。走らせると観測の区画に要求が置かれる
        #expect(
            !FileManager.default.fileExists(
                atPath: directory.appendingPathComponent(".mokume/observe/request.json").path))
    }

    @Test("id のある呼び出しには、id の形 (数・文字列・null) によらず同じ id で答える")
    func answersWithTheCallersID() throws {
        let (server, recorder) = makeServer(
            directory: try makeDirectory(),
            input: [
                #"{"jsonrpc":"2.0","id":7,"method":"tools/list"}"#,
                #"{"jsonrpc":"2.0","id":"seven","method":"tools/list"}"#,
                #"{"jsonrpc":"2.0","id":null,"method":"tools/list"}"#,
            ])
        server.serve()

        let answers = try recorder.written.map(decode)
        #expect(answers.map(idOf) == ["7", "\"seven\"", "null"])
        #expect(answers.allSatisfy { $0["result"] != nil && $0["error"] == nil })
    }

    @Test("呼び出しの形でない行には、読める id で -32600 を返し、空行は読み飛ばす")
    func refusesLinesThatAreNotCalls() throws {
        let (server, recorder) = makeServer(
            directory: try makeDirectory(),
            input: [
                // method が文字列でない・無い。id は読めるので、その id で返す
                #"{"jsonrpc":"2.0","id":2,"method":5}"#,
                #"{"jsonrpc":"2.0","id":3}"#,
                // id も読めなければ null で返す
                #"{"jsonrpc":"2.0","method":5}"#,
                // 束は扱わない (名乗る版 2024-11-05 は束を含まない)。中身によらず 1 行で断る
                #"[{"jsonrpc":"2.0","id":4,"method":"tools/list"}]"#,
                // JSON としては読めるがオブジェクトでない行も、壊れた JSON ではなく形の誤り
                "5",
                // 空行は従来どおり読み飛ばす
                "",
                "   ",
                #"{"jsonrpc":"2.0","id":5,"method":"tools/list"}"#,
            ])
        server.serve()

        let answers = try recorder.written.map(decode)
        #expect(answers.map(idOf) == ["2", "3", "null", "null", "null", "5"])
        #expect(answers.map(errorCode) == [-32600, -32600, -32600, -32600, -32600, nil])
        #expect(answers.last?["result"] != nil)
    }

    @Test("応答の形の行 (method が無く result か error を持つ) には答えず、読み飛ばす")
    func ignoresResponses() throws {
        let (server, recorder) = makeServer(
            directory: try makeDirectory(),
            input: [
                // 窓口は自分から要求を出さないので、届く応答は残らず余分なもの。誤りを返すと、
                // 相手の id の空間に別の答えが紛れうる (JSON-RPC 2.0 は応答に答えない)
                #"{"jsonrpc":"2.0","id":1,"result":{}}"#,
                #"{"jsonrpc":"2.0","id":1,"error":{"code":-32601,"message":"no"}}"#,
                #"{"jsonrpc":"2.0","id":null,"error":{"code":-32700,"message":"no"}}"#,
                // method と result の両方を持つ行は応答ではない。呼び出しとして method を見る
                #"{"jsonrpc":"2.0","id":8,"method":"ping","result":{}}"#,
                // method が文字列でなければ、result を持っていても形の誤り
                #"{"jsonrpc":"2.0","id":9,"method":5,"result":{}}"#,
            ])
        server.serve()

        let answers = try recorder.written.map(decode)
        #expect(answers.map(idOf) == ["8", "9"])
        #expect(answers.map(errorCode) == [nil, -32600])
    }

    @Test("id のある tools/call は、窓口越しに道具を走らせ、その id で結果を返す")
    func runsAToolForACall() throws {
        let directory = try makeDirectory()
        // スケッチ側の応答を待たずに済む道具を選ぶ (作り直しの記録を読むだけ)
        let status = directory.appendingPathComponent(".mokume/build/status.json")
        try FileManager.default.createDirectory(
            at: status.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(#"{"schemaVersion":1,"ok":false,"status":1,"output":"error: 何か"}"#.utf8)
            .write(to: status)
        let (server, recorder) = makeServer(
            directory: directory,
            input: [
                #"{"jsonrpc":"2.0","id":11,"method":"tools/call","params":{"name":"build_status","arguments":{}}}"#
            ])
        server.serve()

        // 通知を落とす判断の反対側 — 要求なら道具が走り、答えが返る (#2317)
        try #require(recorder.written.count == 1)
        let answer = try decode(recorder.written[0])
        #expect(idOf(answer) == "11")
        let result = try #require(answer["result"] as? [String: Any])
        #expect(result["isError"] as? Bool == false)
        let content = try #require(result["content"] as? [[String: Any]])
        #expect((content.first?["text"] as? String)?.contains("error: 何か") == true)
    }

    /// 黙って空の引数に倒すと、`"arguments":"x"` が引数なしの頼みに化けて道具が走る
    /// (`observe` なら等倍で 1 枚撮る)。隣の `name is required` と同じ符号で断る (#2319)。
    /// 空の配列 `[]` も断る — 空の連想配列を `[]` と書き出すエンコーダ (PHP の
    /// `json_encode([])` など) では、これまで通っていた呼び出しが断られるようになる。
    /// 変更の記録 (`changelog.d/`) がそれを名乗る。
    @Test(
        "tools/call の arguments がオブジェクトでなければ、道具を走らせずに -32602 で断る",
        arguments: [#""x""#, "[1]", "[]", "5", "true"])
    func refusesToolArgumentsThatAreNotAnObject(value: String) throws {
        let directory = try makeDirectory()
        let (server, recorder) = makeServer(
            directory: directory,
            input: [
                #"{"jsonrpc":"2.0","id":12,"method":"tools/call","params":{"name":"observe","arguments":"#
                    + value + "}}"
            ])
        server.serve()

        try #require(recorder.written.count == 1)
        let answer = try decode(recorder.written[0])
        #expect(idOf(answer) == "12")
        #expect(errorCode(answer) == -32602)
        #expect(answer["result"] == nil)
        // 道具は走っていない。走ると観測の区画に要求が置かれる
        #expect(!FileManager.default.fileExists(atPath: observeRequest(in: directory).path))
    }

    /// 上の断りの反対側。`null` は「渡していない」以上の意図を運ばないので、省略と同じに読む。
    @Test(
        "tools/call の arguments を省くか null にすると、従来どおり空の引数で道具を走らせる",
        arguments: [
            #"{"jsonrpc":"2.0","id":13,"method":"tools/call","params":{"name":"observe"}}"#,
            #"{"jsonrpc":"2.0","id":13,"method":"tools/call","params":{"name":"observe","arguments":null}}"#,
        ])
    func runsAToolWithoutArguments(line: String) throws {
        let directory = try makeDirectory()
        let (server, recorder) = makeServer(directory: directory, input: [line])
        server.serve()

        // 誰も応えないので道具は失敗の結果を返すが、走って要求を置いている
        try #require(recorder.written.count == 1)
        let answer = try decode(recorder.written[0])
        #expect(idOf(answer) == "13")
        #expect(errorCode(answer) == nil)
        #expect(answer["result"] != nil)
        let request = try #require(
            try JSONSerialization.jsonObject(with: Data(contentsOf: observeRequest(in: directory)))
                as? [String: Any])
        // 空の引数で走った — 縮尺も時刻も枚数も置かれていない
        #expect(request.keys.sorted() == ["id"])
    }

    @Test("ping には、繋ぎ始めの挨拶より前でも空の結果で答える")
    func answersPingWithAnEmptyResult() throws {
        let (server, recorder) = makeServer(
            directory: try makeDirectory(),
            input: [#"{"jsonrpc":"2.0","id":6,"method":"ping"}"#])
        server.serve()

        // MCP 2024-11-05 の Ping — 受け手は空の結果で速やかに答えなければならない (#2318)
        try #require(recorder.written.count == 1)
        let answer = try decode(recorder.written[0])
        #expect(answer["jsonrpc"] as? String == "2.0")
        #expect(idOf(answer) == "6")
        #expect(answer["error"] == nil)
        let result = try #require(answer["result"] as? [String: Any])
        #expect(result.isEmpty)
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
        #expect(outcome.text.contains("this call created it"))
        #expect(outcome.text.contains("**Restart it.**"))
        // 理由 — これが無いと「走っている最中に作れば拾われる」と読まれる
        #expect(outcome.text.contains("Creating it while the sketch runs has no effect"))
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
        #expect(outcome.text.contains("not about the order facets are created in"))
        #expect(!outcome.text.contains("this call created it"))
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
            #expect(outcome.text.contains("Restarting will not fix that one"))
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
        #expect(given.call("observe", arguments: [:]).text.contains("pointed at by"))

        let notGiven = Tools(
            facets: Facets(directory: directory, waitLimit: 0.2, workDirectoryGiven: false),
            makeID: { "fixed" })
        #expect(notGiven.call("observe", arguments: [:]).text.contains("is unset"))
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
        #expect(outcome.text.contains("Restart it"))
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

    /// スキーマの外の組は窓口の外から届きうる (エージェントがスキーマを守るとは限らない)。
    /// 丸めずに掛けると Int が溢れ、窓口のプロセスごと落ちる (#2045)。
    @Test("スキーマの外の枚数・間隔でも、待ちの見積もりは撮る側が丸めた組で数えて溢れない")
    func extraWaitClampsLikeTheShootingSide() {
        let (top, step) = (ObservationRequest.maximumCount, ObservationRequest.maximumEvery)
        // (頼んだ枚数, 頼んだ間隔, 撮る側が撮る枚数, 撮る間隔)
        let cases: [(Int?, Int?, Int, Int)] = [
            (3, Int.max, 3, step),
            (Int.max, 3, top, 3),
            (Int.max, Int.max, top, step),
            (Int.min, Int.min, 1, 1),
            (top + 1, step + 1, top, step),
            (nil, nil, 1, 1),
        ]
        for (count, every, shots, gap) in cases {
            // 撮る側の丸めとも突き合わせる。写した式どうしを比べるだけでは、ずれに気付けない
            let limits = ObservationRequest(id: "", count: count ?? 1, every: every ?? 1).clamped()
            #expect((limits.count, limits.every) == (shots, gap))
            #expect(
                Tools.extraWait(count: count, every: every) == Double((shots - 1) * gap + 1) / 30,
                "count \(String(describing: count)), every \(String(describing: every))")
        }
    }

    @Test("範囲の中の枚数・間隔は、撮り終えるまでに進むフレームを 30fps で換算する")
    func extraWaitInsideTheRangeCountsTheFrames() {
        // 3 枚を 2 フレームおき: 1 枚目 + 2 × 2 = 5 フレーム
        #expect(Tools.extraWait(count: 3, every: 2) == 5.0 / 30)
        #expect(Tools.extraWait(count: 1, every: 1) == 1.0 / 30)
    }

    /// JSON の数は、整数でも小数でも文字列でも届く。黙って 1 へ倒すと、頼みが毎フレーム
    /// 1 枚に化けて撮る側の警告にも載らない (#2045)。
    @Test("枚数・間隔の引数は、整数なら範囲で切らずに読み、整数でなければ断る")
    func readsTheSeriesArgumentsAsWholeNumbers() throws {
        let json = #"{"a": 3, "b": 3.0, "c": 0, "d": -5, "e": 1e19, "f": 9223372036854775808,"#
            + #" "g": -9223372036854775809, "h": 2.5, "i": 1e300, "j": "3", "k": true}"#
        let values = try #require(
            try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        let refused = Tools.SeriesArgument.refused("count must be a whole number")
        let expected: [(String, Tools.SeriesArgument)] = [
            ("a", .value(3)), ("b", .value(3)), ("c", .value(0)), ("d", .value(-5)),
            // 1e300 も整数 (大きな浮動小数はみな整数) で、上限より大きい側に寄る
            ("e", .value(.max)), ("f", .value(.max)), ("g", .value(.min)), ("i", .value(.max)),
            ("h", refused), ("j", refused), ("k", refused),
        ]
        for (key, answer) in expected {
            #expect(Tools.seriesArgument(values[key], key: "count") == answer, "\(key)")
        }
        #expect(Tools.seriesArgument(nil, key: "count") == .omitted)
    }

    @Test("範囲の外の枚数・間隔は切らずに要求へ置き、撮る側が切ったことを名乗れるようにする")
    func passesOutOfRangeSeriesThrough() throws {
        let directory = try makeDirectory()
        let tools = Tools(facets: Facets(directory: directory, waitLimit: 0.2), makeID: { "fixed" })
        // 誰も応えないので上限まで待って諦めるが、要求は置かれている
        _ = tools.call("observe", arguments: ["count": 0, "every": -5])

        let request = try #require(
            try JSONSerialization.jsonObject(
                with: try Data(
                    contentsOf: directory.appendingPathComponent(".mokume/observe/request.json")))
                as? [String: Any])
        #expect(request["count"] as? Int == 0)
        #expect(request["every"] as? Int == -5)
    }

    @Test("整数でない枚数・間隔は、要求を置かずに断る")
    func refusesSeriesThatAreNotWholeNumbers() throws {
        let directory = try makeDirectory()
        let tools = Tools(facets: Facets(directory: directory, waitLimit: 0.2), makeID: { "fixed" })
        let outcome = tools.call("observe", arguments: ["count": 3, "every": 2.5])
        #expect(outcome.isError)
        #expect(outcome.text == "every must be a whole number")
        #expect(
            !FileManager.default.fileExists(
                atPath: directory.appendingPathComponent(".mokume/observe/request.json").path))
    }

    /// 数でない縮尺を黙って落とすと等倍の頼みに化け、真偽値は `NSNumber` 経由で 1 に読める。
    /// どちらも撮る側の警告に載らない (#2319)。`-1e400` は JSON の読み手が `-inf` に読み、
    /// 通すと区画を作った後で書けずに、置き場所のせいにした案内が返る。**引数は JSON から
    /// 読む** — Swift の `true` は JSON の `true` と違う型で届き、`-inf` は JSON の外から
    /// 渡しても読み手の癖を再現できない。
    @Test(
        "数でない・有限でない縮尺は、区画に触れずに断る",
        arguments: [
            #"{"scale":"0.5","time":1}"#, #"{"scale":true}"#, #"{"scale":false}"#,
            #"{"scale":[0.5]}"#, #"{"scale":-1e400}"#,
        ])
    func refusesScalesThatAreNotFiniteNumbers(json: String) throws {
        let directory = try makeDirectory()
        let tools = Tools(facets: Facets(directory: directory, waitLimit: 0.2), makeID: { "fixed" })
        let outcome = tools.call("observe", arguments: try decode(json))
        #expect(outcome.isError)
        #expect(outcome.text == "scale must be a finite number")
        // 要求を置く前に断る。区画のディレクトリも作らない
        #expect(
            !FileManager.default.fileExists(
                atPath: directory.appendingPathComponent(".mokume/observe").path))
    }

    /// `null` の方針は #2393 で決める。それまでは、`as? Double` が外れて省略と同じに
    /// なっていた従来の読み方を変えない (省略できる欄に `null` を入れる呼び手が断られないように)。
    @Test("null の縮尺は、従来どおり省いたのと同じに読む")
    func readsANullScaleAsOmitted() throws {
        let directory = try makeDirectory()
        let tools = Tools(facets: Facets(directory: directory, waitLimit: 0.2), makeID: { "fixed" })
        // 誰も応えないので上限まで待って諦めるが、要求は置かれている
        _ = tools.call("observe", arguments: try decode(#"{"scale":null}"#))

        let request = try #require(
            try JSONSerialization.jsonObject(with: Data(contentsOf: observeRequest(in: directory)))
                as? [String: Any])
        #expect(request.keys.sorted() == ["id"])
    }

    @Test("範囲の外の縮尺は切らずに要求へ置き、撮る側が切ったことを名乗れるようにする")
    func passesOutOfRangeScalesThrough() throws {
        // 範囲 (0 を越え 1 以下) の外は、撮る側が等倍で書いて警告で名乗る (observe-request の約束)
        for (json, expected) in [(#"{"scale":0}"#, 0.0), (#"{"scale":2}"#, 2.0), (#"{"scale":-0.5}"#, -0.5)] {
            let directory = try makeDirectory()
            let tools = Tools(facets: Facets(directory: directory, waitLimit: 0.2), makeID: { "fixed" })
            // 誰も応えないので上限まで待って諦めるが、要求は置かれている
            _ = tools.call("observe", arguments: try decode(json))

            let request = try #require(
                try JSONSerialization.jsonObject(with: Data(contentsOf: observeRequest(in: directory)))
                    as? [String: Any])
            #expect(request["scale"] as? Double == expected, "\(json)")
        }
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

    /// 消費側では届かない場所。実行ファイル起点の探索が当たらないことを保証する。
    private let nowhere = URL(fileURLWithPath: "/nowhere/bin/mokume-cli")

    @Test("依存として引いた消費側から、解決された実体の仕様を読む")
    func findsTheSchemasInTheResolvedDependency() throws {
        let consumer = try ConsumerFixture.make()
        let found = SchemasLocator.directory(
            workDirectory: consumer.work, executable: nowhere)
        #expect(found?.path == consumer.schemas.path)
        #expect(SchemasLocator.names(in: try #require(found)) == ["observe-report"])
    }

    @Test("パスで指した依存でも、実体の場所から仕様を読む")
    func findsTheSchemasInAPathDependency() throws {
        // パスで指すと identity は末尾のディレクトリ名になる。引くのは name の完全一致
        let consumer = try ConsumerFixture.make(local: true)
        let found = SchemasLocator.directory(
            workDirectory: consumer.work, executable: nowhere)
        #expect(found?.path == consumer.schemas.path)
    }

    @Test("名前の似た依存を取り違えない")
    func doesNotMistakeASimilarlyNamedDependency() throws {
        let consumer = try ConsumerFixture.make(name: "mokume-extras")
        #expect(
            SchemasLocator.directory(workDirectory: consumer.work, executable: nowhere) == nil)
    }

    /// 実在する場所の、実体の絶対パス。無ければ `nil`。
    ///
    /// **在処はパスの綴りで比べない。** リンクを含む場所に置いた木では、同じ場所が 2 通りに
    /// 綴られる — `#filePath` は実体 (`/private/tmp/…`) を渡すが、`resolvingSymlinksInPath()`
    /// は `/private` を剥がして `/tmp/…` を返す (#1255)。`realpath(3)` は剥がさないので、
    /// 両辺をこれに通せば綴りの差だけが消える。
    private func realPath(_ url: URL?) -> String? {
        guard let url, let resolved = realpath(url.path, nil) else { return nil }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    @Test("依存から引けなければ、実行ファイルの位置から探す")
    func fallsBackToTheExecutable() throws {
        let repository = schemasRoot().deletingLastPathComponent()
        // このリポジトリの中で走らせたとき (.build/debug/mokume-cli)
        let executable = repository.appendingPathComponent(".build/debug/mokume-cli")
        let found = SchemasLocator.directory(
            workDirectory: try makeDirectory(), executable: executable)
        #expect(found != nil)
        #expect(realPath(found) == realPath(schemasRoot()))
    }

    @Test("実行ファイルがリンク越しでも、実体の場所から探す")
    func followsTheExecutableThroughASymlink() throws {
        // 置き場所によらず見えるよう、リンクは一時ディレクトリの中に作る。リンクを解かなければ
        // bin/ から上を探すことになり、そこには Schemas/ が無い
        let root = try makeDirectory()
        let manager = FileManager.default
        let repository = root.appendingPathComponent("repo", isDirectory: true)
        let schemas = repository.appendingPathComponent("Schemas", isDirectory: true)
        try manager.createDirectory(at: schemas, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: schemas.appendingPathComponent("observe-report.schema.json"))
        // 解くには実体が要る (実在しないパスは resolvingSymlinksInPath() が何も解かない)
        let target = repository.appendingPathComponent(".build/debug/mokume-cli")
        try manager.createDirectory(
            at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data().write(to: target)
        let bin = root.appendingPathComponent("bin", isDirectory: true)
        try manager.createDirectory(at: bin, withIntermediateDirectories: true)
        let link = bin.appendingPathComponent("mokume-cli")
        try manager.createSymbolicLink(at: link, withDestinationURL: target)

        let found = SchemasLocator.directory(workDirectory: try makeDirectory(), executable: link)
        #expect(found != nil)
        #expect(realPath(found) == realPath(schemas))
    }

    @Test("仕様が見つからないときは、見た場所を並べて答える")
    func listsWhereItLookedForTheSchemas() throws {
        let consumer = try ConsumerFixture.make()
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
        let consumer = try ConsumerFixture.make()
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
        #expect(outcome.text.contains("Source: cached"))
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
        #expect(first.text.contains("Source: fetched and cached"))
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
        #expect(second.text.contains("Source: cached"))
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
        fetches.answer = .failure(APIListLocator.FetchFailure("the response was 404"))

        let outcome = makeTools(directory: directory, fetches: fetches)
            .call("reference", arguments: ["name": "api"])
        #expect(outcome.isError)
        #expect(outcome.text.contains("the response was 404"))
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

    /// 文字列でない名前を「引数なし」に倒すと、頼んだ文書の代わりに一覧が成功として返り、
    /// 頼み方を誤ったことに気付けない (#2319)。省いたとき一覧になるのは上の検査が見る。
    @Test(
        "文字列でない文書の名前は、一覧に倒さずに断る",
        arguments: [#"{"name":5}"#, #"{"name":true}"#, #"{"name":["api"]}"#])
    func refusesDocumentNamesThatAreNotStrings(json: String) throws {
        let tools = makeTools(directory: try makeDirectory(), fetches: Fetches())
        let outcome = tools.call("reference", arguments: try decode(json))
        #expect(outcome.isError)
        #expect(outcome.text.hasPrefix("name must be a string"))
        #expect(!outcome.text.contains("Documents this interface serves"))
    }

    /// `null` の方針は #2393 で決める。それまでは、`as? String` が外れて省略と同じに
    /// なっていた従来の読み方を変えない。
    @Test("null の文書の名前は、従来どおり省いたのと同じに一覧を返す")
    func readsANullDocumentNameAsOmitted() throws {
        let tools = makeTools(directory: try makeDirectory(), fetches: Fetches())
        let outcome = tools.call("reference", arguments: try decode(#"{"name":null}"#))
        #expect(!outcome.isError)
        #expect(outcome.text.contains("Documents this interface serves"))
    }

    /// **組めなかった応答を空行で返さない。**
    ///
    /// 行区切りの JSON-RPC で空行を書くと、繋いでいる側からは「まだ応答が来ていない」
    /// と見分けが付かず、呼び出しが返らないまま待ち続ける。
    @Test("組めない応答は、空行ではなく失敗として返る")
    func unencodableResultsBecomeFailures() throws {
        // JSONSerialization は非数を受け付けない
        let line = JSONRPC.response(id: 7, result: ["value": Double.nan])
        #expect(!line.isEmpty)

        let object = try decode(line)
        #expect(object["id"] as? Int == 7)
        #expect(object["result"] == nil)
        let failure = try #require(object["error"] as? [String: Any])
        #expect(failure["code"] as? Int == JSONRPC.internalError)
    }

    /// 失敗の 1 行だけは、何があっても組めなければならない — そこが空になると、
    /// **失敗を伝える手段そのものが無くなる。**
    @Test("id すら組めなくても、失敗の 1 行は返る")
    func theFailureLineIsAlwaysBuildable() throws {
        let line = JSONRPC.failure(id: Double.nan, code: -32602, message: "だめ")

        let object = try decode(line)
        // どの呼び出しへの応答かは照合できなくなるが、黙るよりはよい
        #expect(object["id"] is NSNull)
        let failure = try #require(object["error"] as? [String: Any])
        #expect(failure["code"] as? Int == JSONRPC.internalError)
    }
}

/// 区画へ置けなかったときに、窓口が何を返すか。
///
/// `Facets.exchange` は untyped `throws` だったので、窓口は `\(error)` をそのまま
/// 返していた — `NSCocoaErrorDomain Code=513 …` がエージェントへ届いていたということで、
/// `CommandFailure` が「**どの失敗にも次に何をすればよいかを書く**」と宣言している
/// のに、窓口の 2 箇所だけがその規律の外だった ([#994](https://github.com/mokume-metal/mokume/issues/994) の 6)。
@Suite("区画へ置けなかったとき")
struct FacetExchangeFailureTests {
    /// 親がファイルなので、区画のディレクトリを作れない置き場。
    private func blockedPlace() throws -> URL {
        let place = FileManager.default.temporaryDirectory
            .appendingPathComponent("mokume-blocked-\(UUID().uuidString)", isDirectory: false)
        try Data().write(to: place)
        return place
    }

    @Test("型の付いた失敗になり、次に何をすればよいかを言う")
    func theFailureSaysWhatToDo() throws {
        let facets = Facets(directory: try blockedPlace())
        var thrown: CommandFailure?
        do {
            _ = try facets.exchange(
                facet: facets.observeFacet, request: ["id": "x"], id: "x")
        } catch {
            thrown = error
        }

        let failure = try #require(thrown)
        guard case .facetUnwritable = failure else {
            Issue.record("置けなかった失敗として返っていない: \(failure)")
            return
        }
        // **生の Error を素通しさせない。** 打つ手が書かれていることを見る
        #expect(failure.message.contains("written to"))
        #expect(!failure.message.hasPrefix("Error Domain="))
    }

    @Test("窓口の答えにも、打つ手が出る")
    func theWindowPassesTheAdviceOn() throws {
        let tools = Tools(facets: Facets(directory: try blockedPlace()), makeID: { "x" })
        let outcome = tools.call("observe", arguments: [:])
        #expect(outcome.isError)
        // **打つ手が出ている。** 生の Error は原因として添えるだけで、答えの本体では
        // ない — 素通しだったころは、届くのがそれ 1 行だけだった
        #expect(outcome.text.contains("written to"))
        #expect(outcome.text.contains("MOKUME_WORK_DIR"))
        #expect(outcome.text.hasPrefix("Could not place the request: "))
    }
}
