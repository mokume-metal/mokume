// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation
import MokumeTestSupport
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
            write: { recorder.record($0) })
        return (server, recorder)
    }

    /// 窓口の読みは別の手で走る (#2355) ので、読みと書きは鍵の内側に置く。
    nonisolated final class Recorder: @unchecked Sendable {
        private let lock = NSLock()
        private var lines: [String]
        private var answered: [String] = []
        init(lines: [String]) { self.lines = lines }
        func next() -> String? { lock.withLock { lines.isEmpty ? nil : lines.removeFirst() } }
        func record(_ line: String) { lock.withLock { answered.append(line) } }
        var written: [String] { lock.withLock { answered } }
    }

    private func makeDirectory() throws -> URL {
        try TestScratch.directory("mokume-mcp")
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

    /// `initialize` を 1 回送った応えの `result` と、窓口が書いた行の数。
    private func initialize(
        package: URL, beforeServing: () throws -> Void = {}
    ) throws -> (result: [String: Any], lines: Int) {
        let recorder = Recorder(lines: [#"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}"#])
        let server = MCPServer(
            tools: Tools(facets: Facets(directory: package, waitLimit: 0.2), makeID: { "fixed" }),
            readLine: { recorder.next() },
            write: { recorder.record($0) })
        try beforeServing()
        server.serve()
        let result = try decode(try #require(recorder.written.first))["result"] as? [String: Any]
        return (try #require(result), recorder.written.count)
    }

    @Test("スケッチでない場所で立てた窓口は、挨拶の `instructions` で場所と起こし直す手を名乗る")
    func introducesItselfOutsideASketch() throws {
        let place = try makePlace(sketch: false)
        defer { try? FileManager.default.removeItem(at: place) }
        let (result, lines) = try initialize(package: place)

        let text = try #require(result["instructions"] as? String, "\(result)")
        #expect(text.contains(place.path), "\(text)")
        #expect(text.contains(InterfacePlace.notASketchHeading), "\(text)")
        #expect(text.contains("\(Command.name) mcp <sketch directory>"), "\(text)")
        // 応えは 1 行だけ。標準出力に伝言以外を書かない
        #expect(lines == 1)
    }

    @Test("スケッチの場所で立てた窓口は、挨拶の `instructions` で場所だけを名乗る")
    func introducesItselfInsideASketch() throws {
        let place = try makeSketch()
        defer { try? FileManager.default.removeItem(at: place) }
        let (result, _) = try initialize(package: place)

        let text = try #require(result["instructions"] as? String, "\(result)")
        #expect(text.contains(place.path), "\(text)")
        // 場所を言う 1 行だけ。繋いだ全セッションのシステムプロンプトに入りうる
        #expect(!text.contains(InterfacePlace.notASketchHeading), "\(text)")
        #expect(!text.contains("\(Command.name) mcp <sketch directory>"), "\(text)")
        #expect(!text.contains("\n"), "\(text)")
        // 挨拶のほかの欄は広げない
        #expect(Set(result.keys) == ["protocolVersion", "capabilities", "serverInfo", "instructions"])
        #expect(Set((result["serverInfo"] as? [String: Any] ?? [:]).keys) == ["name", "version"])
    }

    /// **名乗る事実は組んだ時点の ``InterfacePlace`` で、後から追わない** (#2797・#2487)。
    @Test("窓口を立てた後に `Package.swift` が置かれても、名乗りは立てた時点のまま")
    func introductionDoesNotFollowLaterChanges() throws {
        let place = try makePlace(sketch: false)
        defer { try? FileManager.default.removeItem(at: place) }
        let (result, _) = try initialize(package: place) {
            try "// 後から置いた\n".write(
                to: place.appendingPathComponent("Package.swift"), atomically: true, encoding: .utf8)
        }
        let text = try #require(result["instructions"] as? String, "\(result)")
        #expect(text.contains(InterfacePlace.notASketchHeading), "\(text)")
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

    /// 取り消しは窓口の待ちだけを切り、置いた列はスケッチが撮り終えるまで区画を塞ぐ (#3030・ADR-0018 決定 3)。
    /// 呼び手が取り消してよいかを決める道具の説明に、その決まりが書かれていること。
    @Test("observe の説明は、取り消しが待ちだけを切り、次の呼び出しが撮り終えた後ろで待つことを名乗る")
    func observeDescriptionSaysCancellationOnlyEndsTheWait() {
        let description = Tools.ToolName.observe.description
        #expect(description.contains("Cancelling a call ends only the wait"), "\(description)")
        #expect(description.contains("taken to the end"), "\(description)")
        #expect(description.contains("the next call waits behind it"), "\(description)")
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

    @Test("id のある呼び出しには、id の形 (数・文字列) によらず同じ id で答える")
    func answersWithTheCallersID() throws {
        let (server, recorder) = makeServer(
            directory: try makeDirectory(),
            input: [
                #"{"jsonrpc":"2.0","id":7,"method":"tools/list"}"#,
                #"{"jsonrpc":"2.0","id":"seven","method":"tools/list"}"#,
            ])
        server.serve()

        let answers = try recorder.written.map(decode)
        #expect(answers.map(idOf) == ["7", "\"seven\""])
        #expect(answers.allSatisfy { $0["result"] != nil && $0["error"] == nil })
    }

    /// **`"id": null` の要求は断る** ([#2353](https://github.com/mokume-metal/mokume/issues/2353))。
    /// #2317 の A3 は「`null` の `id` にも答える」と決めていたが、MCP 2024-11-05 の basic は
    /// request の ID に null を禁じ、`id: null` の答えは読めない行を断る誤り (`id: null`) と
    /// 繋ぎ手から見分けが付かない。道具も走らせない。
    @Test("id が null の要求は、道具を走らせずに -32600 で断る")
    func refusesARequestWhoseIDIsNull() throws {
        let directory = try makeDirectory()
        let (server, recorder) = makeServer(
            directory: directory,
            input: [
                #"{"jsonrpc":"2.0","id":null,"method":"tools/list"}"#,
                #"{"jsonrpc":"2.0","id":null,"method":"tools/call","params":{"name":"observe","arguments":{}}}"#,
            ])
        server.serve()

        let answers = try recorder.written.map(decode)
        #expect(answers.map(idOf) == ["null", "null"])
        #expect(answers.map(errorCode) == [-32600, -32600])
        #expect(answers.allSatisfy { $0["result"] == nil })
        #expect(!FileManager.default.fileExists(atPath: observeRequest(in: directory).path))
        // 型の違う `id` とは別の言い方で、`null` を名指す (省けば通知になる)
        let message = refusal(#"{"jsonrpc":"2.0","id":null,"method":"tools/list"}"#)?.message
        #expect(message?.contains("id must not be null") == true, "\(String(describing: message))")
    }

    // ------------------------------------- 呼び出しの形の検め (#2353・JSON-RPC 2.0 §4・§5.1)

    /// 行ごとの前後。`reply` は断りの 1 行を JSON に読んだもの。
    private func refusal(_ line: String) -> (id: String, code: Int?, message: String?)? {
        guard case .refused(let reply) = JSONRPC.parse(line),
            let object = try? JSONSerialization.jsonObject(with: Data(reply.utf8)) as? [String: Any]
        else { return nil }
        let error = object["error"] as? [String: Any]
        return (idOf(object), error?["code"] as? Int, error?["message"] as? String)
    }

    @Test(
        "呼び出しの形の行は、符号 -32600 で断り、読める id があればそれで答える",
        arguments: [
            // (行, 答えの id)
            (#"{"id":1,"method":"tools/list"}"#, "1"),
            (#"{"jsonrpc":"1.0","id":2,"method":"tools/list"}"#, "2"),
            (#"{"jsonrpc":2,"id":"two","method":"tools/list"}"#, "\"two\""),
            (#"{"jsonrpc":"2.0","id":{"a":1},"method":"tools/list"}"#, "null"),
            (#"{"jsonrpc":"2.0","id":[1],"method":"tools/list"}"#, "null"),
            (#"{"jsonrpc":"2.0","id":true,"method":"tools/list"}"#, "null"),
            (#"{"jsonrpc":"2.0","id":3,"method":"tools/call","params":[1]}"#, "3"),
            (#"{"jsonrpc":"2.0","id":3,"method":"tools/call","params":"x"}"#, "3"),
            (#"{"jsonrpc":"2.0","id":3,"method":"tools/call","params":7}"#, "3"),
            (#"{"jsonrpc":"2.0","id":null,"method":"tools/list"}"#, "null"),
            // 通知の形 (`id` 無し) も、形が違えば通知かどうかを見ずに断る
            (#"{"method":"notifications/initialized"}"#, "null"),
            (#"{"jsonrpc":"1.0","method":"notifications/initialized"}"#, "null"),
            (#"{"jsonrpc":"2.0","method":"notifications/initialized","params":[]}"#, "null"),
            // `method` が文字列でない行の断りも、型の違う `id` をそのまま載せない
            (#"{"jsonrpc":"2.0","id":{"a":1},"method":5}"#, "null"),
        ])
    func refusesALineWhoseEnvelopeIsWrong(line: String, id: String) throws {
        let refused = try #require(refusal(line), "断っていない: \(line)")
        #expect(refused.code == -32600, "\(line)")
        #expect(refused.id == id, "\(line)")
        #expect(refused.message?.hasPrefix("invalid request: ") == true, "\(line)")
    }

    /// **「`NSNumber` だが真偽でない」の判定は 1 つ** (`id` も道具の引数もここを通る)。
    @Test("数の判定は、真偽を数と読まない")
    func aBooleanIsNotANumber() {
        #expect(JSONRPC.number(1) != nil)
        #expect(JSONRPC.number(1.5) != nil)
        #expect(JSONRPC.number(true) == nil)
        #expect(JSONRPC.number(false) == nil)
        #expect(JSONRPC.number("1") == nil)
        #expect(JSONRPC.number(nil) == nil)
        // JSON から読んだ真偽・数も同じ
        let object = try? JSONSerialization.jsonObject(with: Data(#"{"t":true,"n":1}"#.utf8))
        let fields = object as? [String: Any]
        #expect(JSONRPC.number(fields?["t"]) == nil)
        #expect(JSONRPC.number(fields?["n"]) != nil)
    }

    /// 通知で `params` が `null` でも黙る (省略と同じ)。
    @Test("params が null の通知は、省略と同じに黙る")
    func staysSilentForANotificationWithNullParams() throws {
        let (server, recorder) = makeServer(
            directory: try makeDirectory(),
            input: [#"{"jsonrpc":"2.0","method":"notifications/initialized","params":null}"#])
        server.serve()
        #expect(recorder.written.isEmpty)
    }

    @Test(
        "形の正しい呼び出しと通知は、いままでどおり呼び出しとして読む",
        arguments: [
            #"{"jsonrpc":"2.0","id":7,"method":"tools/list"}"#,
            #"{"jsonrpc":"2.0","id":"seven","method":"tools/list"}"#,
            #"{"jsonrpc":"2.0","id":1.5,"method":"tools/list"}"#,
            // `params` を省いたもの・空のオブジェクト・`null` (省いたのと同じに読む。
            // `arguments`・`scale` の `null` が省略と同じなのと揃える・#2393)
            #"{"jsonrpc":"2.0","id":8,"method":"ping"}"#,
            #"{"jsonrpc":"2.0","id":9,"method":"initialize","params":{}}"#,
            #"{"jsonrpc":"2.0","id":10,"method":"ping","params":null}"#,
            // 通知
            #"{"jsonrpc":"2.0","method":"notifications/initialized"}"#,
        ])
    func readsAWellFormedCall(line: String) {
        guard case .call = JSONRPC.parse(line) else {
            Issue.record("呼び出しとして読めていない: \(line)")
            return
        }
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

    /// `Double` に収まらない数は、符号によらず読めない行として断る (#2476)。`JSONSerialization` は
    /// 正の側 (`1e400`) は投げるが、負の側 (`-1e400`) は投げずに `-inf` で読むので、通すと `id` が
    /// JSON に戻せず `lastResort` (`id` が `null`・-32603) へ落ち、引数の数は `-inf` のまま道具へ渡る。
    /// 書く位置 (id・引数・配列の中・最上位・通知) によらず、`1e400` と同じ失敗にする。
    nonisolated private static let unfitLines: [String] = {
        func call(id: String = "1", arguments: String = "{}") -> String {
            #"{"jsonrpc":"2.0","id":"# + id
                + #","method":"tools/call","params":{"name":"observe","arguments":"# + arguments + "}}"
        }
        return [
            call(id: "-1e400"), call(id: "-1.8e308"), call(id: "-1E400"),
            call(id: "-1e+400"), call(id: "-0.5e999999999"),
            call(arguments: #"{"scale":-1e400}"#),
            call(arguments: #"{"events":[1,[2,{"x":-1e400}]]}"#),
            call(arguments: #"{"events":[-1.8e308]}"#),
            // 通知 (id が無い) でも、壊れた行として答える
            #"{"jsonrpc":"2.0","method":"tools/call","params":{"name":"observe","arguments":{"scale":-1e400}}}"#,
            // 応答の形の行の中でも
            #"{"jsonrpc":"2.0","id":-1e400,"result":{}}"#,
            // 最上位が数だけの行も、形の誤りではなく読めない行
            "-1e400",
        ]
    }()

    @Test("Double に収まらない負の数が木に残る行は、道具を走らせずに -32700 で断る", arguments: unfitLines)
    func refusesNegativeNumbersThatDoNotFit(line: String) throws {
        let directory = try makeDirectory()
        let (server, recorder) = makeServer(
            directory: directory,
            input: [line, #"{"jsonrpc":"2.0","id":2,"method":"tools/list"}"#])
        server.serve()

        // 1 行目は誤りの 1 行 (id は読めないので null)。lastResort (-32603) へは落ちない。
        // 繋がりは切れず、次の呼び出しには答える
        try #require(recorder.written.count == 2)
        let refused = try decode(recorder.written[0])
        #expect(errorCode(refused) == JSONRPC.parseError)
        #expect(idOf(refused) == "null")
        #expect(idOf(try decode(recorder.written[1])) == "2")
        // 道具は走っていない。走ると観測の区画に要求が置かれる
        #expect(!FileManager.default.fileExists(atPath: observeRequest(in: directory).path))
    }

    @Test("収まらない数の断りは、正の側 (1e400) と負の側 (-1e400) で同じ失敗になる")
    func refusesBothSignsAlike() throws {
        // 応答の組み立ては鍵の並びを決めないので、文字ではなく読んだ中身で比べる
        func reply(_ line: String) throws -> NSDictionary {
            guard case .refused(let reply) = JSONRPC.parse(line) else {
                Issue.record("断られていない: \(line)")
                return [:]
            }
            return try decode(reply) as NSDictionary
        }
        let positive = try reply(#"{"jsonrpc":"2.0","id":1e400,"method":"tools/list"}"#)
        let negative = try reply(#"{"jsonrpc":"2.0","id":-1e400,"method":"tools/list"}"#)
        #expect(positive.count == 3)
        #expect(positive == negative)
        #expect(try reply("1e400") == reply("-1e400"))
    }

    /// **限界の明示。** 同じキーを 2 度書いた行の、後ろの値は読み手が木から落とすので、木を歩く
    /// 検めには見えない (`1e400` を同じ位置に置くと `JSONSerialization` が行ごと投げて断られる)。
    /// 道具へ渡るのは残った有限の値だけで、`-inf` は届かない。文字から探す読み手 (`MokumeCore` の
    /// `JSONFile`) なら落ちた数も断れるが、`MokumeCLI` から使える口が無い (#2476)。ここは**いま
    /// 断られない**ことを固定する — 将来塞ぐなら、この検査を断る側へ書き換える。
    @Test(
        "同じキーを 2 度書いて、後ろの収まらない負の数が木から落ちる行は、いまは断らず残った値で答える",
        arguments: [
            #"{"jsonrpc":"2.0","id":1,"id":-1e400,"method":"tools/list"}"#,
            #"{"jsonrpc":"2.0","id":1,"method":"tools/list","params":{"a":2,"a":{"x":-1e400}}}"#,
        ])
    func doesNotSeeNumbersDroppedFromTheTree(line: String) throws {
        let (server, recorder) = makeServer(directory: try makeDirectory(), input: [line])
        server.serve()

        try #require(recorder.written.count == 1)
        let answer = try decode(recorder.written[0])
        #expect(errorCode(answer) == nil)
        #expect(idOf(answer) == "1")
        #expect(answer["result"] != nil)
    }

    @Test("Double の最小値・最大値ちょうどの数は、これまでどおり読める")
    func readsTheExtremesThatFit() throws {
        let directory = try makeDirectory()
        let (server, recorder) = makeServer(
            directory: directory,
            input: [
                #"{"jsonrpc":"2.0","id":-1.7976931348623157e308,"method":"tools/list"}"#,
                #"{"jsonrpc":"2.0","id":1.7976931348623157e308,"method":"tools/list"}"#,
                #"{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"reference","arguments":{"name":"x","extra":-1.7976931348623157e308}}}"#,
            ])
        server.serve()

        let answers = try recorder.written.map(decode)
        try #require(answers.count == 3)
        #expect(answers.map(errorCode) == [nil, nil, nil])
        #expect(answers.allSatisfy { $0["result"] != nil })
        #expect(idOf(answers[2]) == "3")
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
        let directory = try makeSketch()
        let tools = Tools(facets: Facets(directory: directory, waitLimit: 0.2), makeID: { "fixed" })
        // 誰も応えないので待ちの上限に達する。上限は短くしてある
        let outcome = tools.call("build_status", arguments: [:])
        #expect(outcome.isError)
        #expect(outcome.text.contains("watch"))
    }

    @Test("区画を起動より後に作っていたら、起動し直すことと、その理由を答える")
    func tellsToRestartWhenTheFacetWasMissing() throws {
        let directory = try makeSketch()
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
        let directory = try makeSketch()
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
            // **MOKUME_WORK_DIR があれば、窓口をどこで立てたかは応えない原因にならない** (#2487)。
            // パッケージの場所 (`split`) に Package.swift は無いが、区画の基準は場所に依らないので、
            // 4 つ目 (スケッチでない場所) も、2 の「窓口をスケッチの場所で起こす」手も出さない
            #expect(outcome.text.contains("three possibilities"), "\(outcome.text)")
            #expect(!outcome.text.contains("4. "), "\(outcome.text)")
            #expect(!outcome.text.contains(InterfacePlace.notASketchHeading))
            #expect(!outcome.text.contains("mcp <sketch directory>"))
        }
    }

    @Test("基準を決めたものの言い方が、環境変数の有無で変わる")
    func tellsWhoDecidedTheFacetBase() throws {
        let directory = try makeSketch()
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
        let directory = try makeSketch()
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
        let directory = try makeSketch()
        let tools = Tools(facets: Facets(directory: directory, waitLimit: 0.2), makeID: { "fixed" })
        let outcome = tools.call(
            "input", arguments: ["events": [["type": "keyDown", "key": "a"]]])
        #expect(outcome.isError)
        #expect(outcome.text.contains("Restart it"))
        #expect(outcome.text.contains(".mokume/input"))
        #expect(!outcome.text.contains(".mokume/observe"))
    }

    // MARK: - スケッチでない場所で立てた窓口 (#2487)

    /// 窓口を立てる場所。`sketch` なら中身の無い `Package.swift` を置く。
    private func makePlace(sketch: Bool) throws -> URL {
        let place = try makeDirectory()
        if sketch {
            try "// 中身の無い宣言\n".write(
                to: place.appendingPathComponent("Package.swift"), atomically: true,
                encoding: .utf8)
        }
        return place
    }

    /// スケッチの場所 (`Package.swift` がある)。**スケッチの中の答えを見る検査はここで組む** —
    /// `Package.swift` の無い場所で組むと、スケッチでない場所の答えを受けたまま緑になる (#2487)。
    private func makeSketch() throws -> URL { try makePlace(sketch: true) }

    /// 区画へ往復する道具 (`roundTrip` を通る口のすべて) を、誰も走っていない区画で呼ぶ。
    ///
    /// **区画の基準 (`base`) と窓口を立てた場所 (`package`) を別々に渡せる** — 判定がどちらの
    /// 軸を見ているかを、検査が固定できるようにする。
    private func callUnanswered(
        _ tool: String, base: URL, package: URL, given: Bool = false, facetExisted: Bool = false
    ) throws -> (text: String, isError: Bool) {
        let entry = tool == "observe" ? StartupReads.observe : StartupReads.input
        if facetExisted {
            try FileManager.default.createDirectory(
                at: WorkDirectory.facet(entry.key, under: base), withIntermediateDirectories: true)
        }
        let tools = Tools(
            facets: Facets(directory: base, waitLimit: 0.2, workDirectoryGiven: given),
            packageDirectory: package, makeID: { "fixed" })
        let arguments: [String: Any] =
            tool == "observe" ? [:] : ["events": [["type": "keyDown", "code": 0]]]
        return tools.call(tool, arguments: arguments)
    }

    /// **スケッチでない場所で立てた窓口は、応えないときにそのことと起こし直す手を言う**
    /// ([#2487](https://github.com/mokume-metal/mokume/issues/2487))。`claude mcp add mokume -- mokume mcp`
    /// は打った場所で起こすので、`Package.swift` の無い場所でも立つ (#2321 の決定で受ける)。
    /// そこでは区画の基準もその場所になり、自分の場所で走るスケッチとは噛み合わない。
    ///
    /// 区画は今どおり作る (案 B)。組み上げた実行ファイルをこの場所から起こした使い方は正しく
    /// 繋がるので、断らずに 4 つ目の可能性として足す。**答えの中の 1・2 も同じ事実から組む** —
    /// 「窓口の場所 = スケッチの場所」のまま 1 行だけ足すと、1 (起動し直せば区画を拾う) と
    /// 基準の 1 行 (スケッチの場所を使っている) が 4 と食い違う。
    @Test(
        "スケッチでない場所で立てた窓口は、応えないとき Package.swift が無いことと mcp <sketch directory> の手を答え、1・2 もその場所の話として言う",
        arguments: ["observe", "input"], [false, true])
    func tellsWhenStartedOutsideASketch(tool: String, facetExisted: Bool) throws {
        let place = try makePlace(sketch: false)
        defer { try? FileManager.default.removeItem(at: place) }
        let outcome = try callUnanswered(
            tool, base: place, package: place, facetExisted: facetExisted)
        let text = outcome.text

        #expect(outcome.isError)
        #expect(text.contains("four possibilities"), "\(text)")
        // 4 — 場所のパスを名指して Package.swift が無いと言い、起こし直す手を言う
        #expect(text.contains("4. \(InterfacePlace.notASketchHeading)"), "\(text)")
        #expect(text.contains("There is no Package.swift in \(place.path)"), "\(text)")
        #expect(text.contains("\(Command.name) mcp <sketch directory>"), "\(text)")
        // 1 — 窓口の場所の話として言う。スケッチの場所の言い方 (起動し直せば拾う) を言わない
        if facetExisted {
            #expect(text.contains("1. Nothing started from this interface's directory is running"))
            #expect(!text.contains("1. Nothing is running yet"))
        } else {
            #expect(
                text.contains(
                    "1. A sketch started from this interface's directory launched without"))
            #expect(!text.contains("The facet is there now, so it does not need creating again"))
            // 区画を作った回は、作ったことを名乗る (当初の完了条件 2 の「作ったことを名乗る」)
            #expect(text.contains("this call created it"))
        }
        // 2 — 基準の 1 行は「スケッチの場所」と言い切らない。窓口をスケッチの場所で起こす手を載せる
        #expect(text.contains("2. The interface and the sketch disagree on the facet base"))
        #expect(!text.contains("sketch's own directory"), "\(text)")
        #expect(text.contains("using the directory it was started for"))
        #expect(text.contains("starting this interface in the sketch's directory also makes them agree"))
        // 3 は残る
        #expect(text.contains("3. The mokume the sketch depends on"))
    }

    /// 裏側。**スケッチの場所で立てた窓口では、4 つ目を出さず、1 はスケッチの言い方のまま。**
    /// 2 の「窓口をスケッチの場所で起こす」手は、`MOKUME_WORK_DIR` が無ければここでも載る —
    /// 本当の条件は区画の基準が割れていることで、別のスケッチの場所で立った窓口も同じ形で
    /// 割れるため (`Package.swift` の有無はその代理でしかない)。
    @Test(
        "スケッチの場所で立てた窓口の案内は、従来どおりの 3 つで、4 つ目を足さない",
        arguments: ["observe", "input"], [false, true])
    func keepsTheThreePossibilitiesInASketch(tool: String, facetExisted: Bool) throws {
        let place = try makeSketch()
        defer { try? FileManager.default.removeItem(at: place) }
        let outcome = try callUnanswered(
            tool, base: place, package: place, facetExisted: facetExisted)
        let text = outcome.text

        #expect(outcome.isError)
        #expect(text.contains("three possibilities"), "\(text)")
        #expect(!text.contains("4. "), "\(text)")
        #expect(!text.contains(InterfacePlace.notASketchHeading))
        #expect(!text.contains("There is no Package.swift"))
        #expect(
            text.contains(
                facetExisted
                    ? "1. Nothing is running yet"
                    : "The facet is there now, so it does not need creating again"))
        #expect(text.contains("starting this interface in the sketch's directory also makes them agree"))
        #expect(text.contains("\(Command.name) mcp <sketch directory>"))
    }

    /// **`MOKUME_WORK_DIR` があれば、窓口をどこで立てたかは応えない原因にならない** — 区画の
    /// 基準が場所に依らないので、4 つ目も 2 の場所の手も出さず、1 はスケッチの言い方のまま。
    @Test(
        "MOKUME_WORK_DIR があれば、スケッチでない場所で立てた窓口でも 4 つ目を出さない",
        arguments: ["observe", "input"])
    func noFourthWhenTheWorkDirectoryIsGiven(tool: String) throws {
        let base = try makeDirectory()
        let package = try makePlace(sketch: false)
        defer {
            try? FileManager.default.removeItem(at: base)
            try? FileManager.default.removeItem(at: package)
        }
        let outcome = try callUnanswered(tool, base: base, package: package, given: true)
        let text = outcome.text

        #expect(outcome.isError)
        #expect(text.contains("three possibilities"), "\(text)")
        #expect(!text.contains("4. "), "\(text)")
        #expect(!text.contains(InterfacePlace.notASketchHeading))
        #expect(!text.contains("mcp <sketch directory>"))
        #expect(text.contains("**Restart it.** The facet is there now"))
        #expect(text.contains("pointed at by MOKUME_WORK_DIR"))
    }

    /// **判定は「窓口を立てた場所」の軸で見る。区画の基準の軸ではない** (#2487 の反証 5)。
    /// 本番では `MOKUME_WORK_DIR` が無ければ 2 つは同じ場所に重なるので、重ねたままの検査では
    /// 区画の基準を見る誤りも緑になる。ここは軸を固定するために、あえて 2 つをずらして組む。
    @Test("スケッチかどうかは、区画の基準ではなく窓口を立てた場所で決まる")
    func judgesThePlaceWhereTheInterfaceWasStarted() throws {
        let sketch = try makeSketch()
        let elsewhere = try makePlace(sketch: false)
        defer {
            try? FileManager.default.removeItem(at: sketch)
            try? FileManager.default.removeItem(at: elsewhere)
        }
        // 区画の基準はスケッチ、窓口を立てた場所はスケッチでない → 4 つ目が出る
        let outside = try callUnanswered("observe", base: sketch, package: elsewhere)
        #expect(outside.text.contains("There is no Package.swift in \(elsewhere.path)"), "\(outside.text)")
        // 区画の基準はスケッチでない、窓口を立てた場所はスケッチ → 出ない
        let inside = try callUnanswered("observe", base: elsewhere, package: sketch)
        #expect(!inside.text.contains(InterfacePlace.notASketchHeading), "\(inside.text)")

        // 版を読むのもパッケージの場所 (区画の基準 = MOKUME_WORK_DIR に依らない)
        for (base, package, expected) in [(sketch, elsewhere, true), (elsewhere, sketch, false)] {
            let tools = Tools(
                facets: Facets(directory: base, waitLimit: 0.2, workDirectoryGiven: true),
                packageDirectory: package, makeID: { "fixed" })
            let outcome = tools.call("reference", arguments: ["name": Tools.apiDocument])
            #expect(
                outcome.text.contains(InterfacePlace.notASketchHeading) == expected,
                "package=\(package.path): \(outcome.text)")
        }
    }

    /// 兄弟 — **直近の作り直しの記録が無いときも、同じ手を添える。** 区画の基準がスケッチでない
    /// 場所に落ちていれば、走っている `watch` の記録は読めない。「watch が走っていない」とだけ
    /// 言うと、走っている `watch` を探しに行かせる。**ただし組み上げた実行ファイルをその場所から
    /// 起こす使い方では作り直しが無いので、そう言い分ける** (反証 8)。`MOKUME_WORK_DIR` があれば
    /// 記録の在処は場所に依らないので添えない。
    @Test("スケッチでない場所で立てた窓口は、作り直しの記録が無いときも、起こし直す手を添える")
    func buildStatusTellsWhenStartedOutsideASketch() throws {
        for (sketch, given, expected) in [(false, false, true), (true, false, false), (false, true, false)] {
            let place = try makePlace(sketch: sketch)
            defer { try? FileManager.default.removeItem(at: place) }
            let tools = Tools(
                facets: Facets(directory: place, waitLimit: 0.2, workDirectoryGiven: given),
                packageDirectory: place, makeID: { "fixed" })
            let outcome = tools.call("build_status", arguments: [:])
            let label = "sketch=\(sketch) given=\(given): \(outcome.text)"

            #expect(outcome.isError)
            #expect(outcome.text.contains("No build has been recorded yet"))
            #expect(outcome.text.contains("There is no Package.swift in \(place.path)") == expected, "\(label)")
            #expect(outcome.text.contains("\(Command.name) mcp <sketch directory>") == expected, "\(label)")
            // 組み上げた実行ファイルをこの場所から起こす使い方には、記録が無いのが当然だと言う
            #expect(outcome.text.contains("is never rebuilt") == expected, "\(label)")
        }
    }

    /// 兄弟 — **公開 API の一覧の版が引けないときも、同じ手を添える。** スケッチでない場所には
    /// `Package.resolved` も無いので版は引けないが、その理由を「パスで mokume を指しているとき」
    /// とだけ言うと、原因を取り違えさせる。**取りに行けない回は場所のせいではないので添えない**
    /// (反証 9)。
    @Test("スケッチでない場所で立てた窓口は、公開 API の一覧の版が引けないときだけ、起こし直す手を添える")
    func apiReferenceTellsWhenStartedOutsideASketch() throws {
        for sketch in [false, true] {
            let place = try makePlace(sketch: sketch)
            defer { try? FileManager.default.removeItem(at: place) }
            let outcome = makeTools(directory: place, fetches: Fetches())
                .call("reference", arguments: ["name": Tools.apiDocument])

            #expect(outcome.isError)
            #expect(outcome.text.contains("Cannot tell which version is depended on"))
            #expect(
                outcome.text.contains("There is no Package.swift in \(place.path)") == !sketch,
                "sketch=\(sketch): \(outcome.text)")
            #expect(
                outcome.text.contains("\(Command.name) mcp <sketch directory>") == !sketch,
                "sketch=\(sketch): \(outcome.text)")
        }

        // 版は引けたが取りに行けない — スケッチでない場所でも、場所の手は添えない
        let place = try makePlace(sketch: false)
        defer { try? FileManager.default.removeItem(at: place) }
        try writeResolved(place, pins: pin("mokume", "0.1.0"))
        let fetches = Fetches()
        fetches.answer = .failure(APIListLocator.FetchFailure("the response was 404"))
        let outcome = makeTools(directory: place, fetches: fetches)
            .call("reference", arguments: ["name": Tools.apiDocument])
        #expect(outcome.isError)
        #expect(outcome.text.contains("the response was 404"))
        #expect(!outcome.text.contains(InterfacePlace.notASketchHeading), "\(outcome.text)")
    }

    /// 兄弟 — **区画を置けなかった回も、場所の手を添える** (反証 1)。窓口は在る場所なら受けるので、
    /// 読み取り専用の場所でも立つ。書き込めるか・容量・`MOKUME_WORK_DIR` だけを言うと、場所を
    /// 渡す手が抜ける。スケッチの場所なら、従来どおりの答えのまま。
    @Test("スケッチでない書けない場所で立てた窓口は、置けなかったときも起こし直す手を添える")
    func unwritablePlaceTellsWhenStartedOutsideASketch() throws {
        for sketch in [false, true] {
            let place = try makePlace(sketch: sketch)
            chmod(place.path, 0o555)
            defer {
                chmod(place.path, 0o755)
                try? FileManager.default.removeItem(at: place)
            }
            let outcome = try callUnanswered("observe", base: place, package: place)
            let label = "sketch=\(sketch): \(outcome.text)"

            #expect(outcome.isError)
            #expect(outcome.text.hasPrefix("Could not place the request: "), "\(label)")
            #expect(outcome.text.contains("There is no Package.swift in \(place.path)") == !sketch, "\(label)")
            #expect(outcome.text.contains("\(Command.name) mcp <sketch directory>") == !sketch, "\(label)")
        }
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

    /// `null` は省略と同じに読む (#2393。省略できる欄に `null` を入れる呼び手が断られないように)。
    @Test("null の縮尺は、省いたのと同じに読む")
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

    /// 観測を頼み、誰も応えない区画へ置かれた要求を読む (置かれていなければ `nil`)。
    private func placedObservation(_ json: String) throws -> [String: Any]? {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let tools = Tools(facets: Facets(directory: directory, waitLimit: 0.2), makeID: { "fixed" })
        // 誰も応えないので上限まで待って諦めるが、要求は置かれている
        _ = tools.call("observe", arguments: try decode(json))
        guard let data = try? Data(contentsOf: observeRequest(in: directory)) else { return nil }
        return try JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    /// **省略可能な欄の `null` は省略と同じ** (#2393)。`time`・`count`・`every` も、これまでの
    /// 道具の誤りではなく、`scale` と同じに読む。省略と読んだ欄は区画の要求に書かない。
    @Test(
        "null の時刻・枚数・間隔は、省いたのと同じに読み、要求に null のキーを書かない",
        arguments: [
            (#"{"time":null}"#, ["id"]),
            (#"{"count":null,"every":null}"#, ["id"]),
            (#"{"time":3,"count":null}"#, ["id", "time"]),
            (#"{"time":3,"every":null}"#, ["id", "time"]),
            (#"{"time":null,"scale":null,"count":null,"every":null}"#, ["id"]),
            (#"{"count":2,"every":null}"#, ["count", "id"]),
        ])
    func readsNullOptionalFieldsAsOmitted(json: String, keys: [String]) throws {
        let request = try #require(try placedObservation(json), "\(json)")
        #expect(request.keys.sorted() == keys, "\(json)")
        #expect(!request.values.contains { $0 is NSNull }, "\(json)")
    }

    /// 上の反対側。`null` を受けても、**型の違う値は断ったまま** (#2408)。
    @Test(
        "時刻・枚数・間隔・縮尺の型違いは、null を受けるようになっても要求を置かずに断る",
        arguments: [
            (#"{"time":"3"}"#, "time must be finite, non-negative seconds within the Float range"),
            (#"{"time":true}"#, "time must be finite, non-negative seconds within the Float range"),
            (#"{"count":true}"#, "count must be a whole number"),
            (#"{"every":"2"}"#, "every must be a whole number"),
            (#"{"scale":"0.5"}"#, "scale must be a finite number"),
            (#"{"time":3,"count":"1"}"#, "A specified time requires count=1 and every=1"),
        ])
    func stillRefusesWrongTypesAlongsideNull(json: String, reason: String) throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let tools = Tools(facets: Facets(directory: directory, waitLimit: 0.2), makeID: { "fixed" })
        let outcome = tools.call("observe", arguments: try decode(json))
        #expect(outcome.isError, "\(json)")
        #expect(outcome.text == reason, "\(json)")
        #expect(!FileManager.default.fileExists(atPath: observeRequest(in: directory).path), "\(json)")
    }

    /// **知らない名前の引数は、道具を走らせずに断る** (#2486)。黙って捨てると、`scal` の
    /// 綴り違いが等倍で撮る頼みに化ける。断る文面は知らない名前と、受ける名前を言う。
    @Test("observe の知らない引数は、区画に要求を書かずに、受ける名前を添えて断る")
    func refusesAnUnknownObserveArgument() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let tools = Tools(facets: Facets(directory: directory, waitLimit: 0.2), makeID: { "fixed" })
        let outcome = tools.call("observe", arguments: try decode(#"{"scal":0.5}"#))
        #expect(outcome.isError)
        #expect(
            outcome.text == "Unknown argument: scal. observe accepts count, every, scale, time.",
            "\(outcome.text)")
        #expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent(".mokume").path))
    }

    @Test(
        "どの道具も、知らない引数を断る (値が null でも、知っている名前と並んでいても)",
        arguments: [
            ("build_status", #"{"x":1}"#, "Unknown argument: x. build_status takes no arguments."),
            ("build_status", #"{"x":null}"#, "Unknown argument: x. build_status takes no arguments."),
            ("reference", #"{"nam":"api"}"#, "Unknown argument: nam. reference accepts name."),
            ("input", #"{"events":[],"evnts":[]}"#, "Unknown argument: evnts. input accepts events."),
            // 知っている名前の `null` は余りに数えない。数えるのは知らない名前だけ
            ("observe", #"{"scale":null,"scal":1}"#,
                "Unknown argument: scal. observe accepts count, every, scale, time."),
            ("observe", #"{"b":1,"a":null}"#,
                "Unknown arguments: a, b. observe accepts count, every, scale, time."),
        ])
    func refusesUnknownArgumentsOfEveryTool(tool: String, json: String, reason: String) throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let tools = Tools(facets: Facets(directory: directory, waitLimit: 0.2), makeID: { "fixed" })
        let outcome = tools.call(tool, arguments: try decode(json))
        #expect(outcome.isError, "\(tool) \(json)")
        #expect(outcome.text == reason, "\(tool) \(json)")
        // 区画へは何も書いていない
        #expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent(".mokume").path))
    }

    /// 範囲は `arguments` の直下だけ。`input` の出来事の中の余りの欄は、区画の読み手が扱う (#1132)。
    /// 必須の `events` の `null` は省略ではなく、従来どおりの文面で断る。
    @Test("input の出来事の中の余りの欄は断らず、events が null なら従来の文面で断る")
    func surplusCheckStopsAtTheTopLevel() throws {
        let tools = Tools(
            facets: Facets(directory: try makeDirectory(), waitLimit: 0.2), makeID: { "fixed" })
        let inside = tools.call(
            "input", arguments: try decode(#"{"events":[{"type":"keyDown","code":1,"extra":true}]}"#))
        #expect(!inside.text.hasPrefix("Unknown argument"), "\(inside.text)")
        let missing = tools.call("input", arguments: try decode(#"{"events":null}"#))
        #expect(missing.isError)
        #expect(missing.text == "events needs an array of events")
    }

    @Test("tools/list の道具はどれも、余りの引数を additionalProperties: false で断ると名乗る")
    func listedToolsDeclareNoAdditionalProperties() throws {
        let (server, recorder) = makeServer(
            directory: try makeDirectory(),
            input: [#"{"jsonrpc":"2.0","id":2,"method":"tools/list"}"#])
        server.serve()
        let result = try decode(try #require(recorder.written.first))["result"] as? [String: Any]
        let tools = try #require(result?["tools"] as? [[String: Any]])
        try #require(tools.count == 4)
        for tool in tools {
            let schema = try #require(tool["inputSchema"] as? [String: Any])
            #expect(schema["additionalProperties"] as? Bool == false, "\(tool["name"] ?? "?")")
        }
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

    /// **場所は在るものを渡す** — 窓口は在らない場所を断る (#2321)。区画の基準
    /// (`elsewhere`) は在らなくてよい: スケッチが書くときに作る。
    @Test("区画は環境変数が決め、パッケージの場所は引数が決める")
    func splitsTheFacetBaseFromThePackageDirectory() throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let cwd = root.appendingPathComponent("cwd", isDirectory: true)
        let sketch = root.appendingPathComponent("sketch", isDirectory: true).path
        for place in [cwd.path, sketch] {
            try FileManager.default.createDirectory(
                atPath: place, withIntermediateDirectories: true)
        }
        let elsewhere = "/elsewhere"

        // 区画はスケッチが書く場所。スケッチは環境変数に従うので、引数より強い
        let both = try MCPCommand.directories(
            arguments: [sketch], environment: ["MOKUME_WORK_DIR": elsewhere],
            currentDirectory: cwd)
        #expect(both.package.path == sketch)
        #expect(both.facets.path == elsewhere)

        // 環境変数が無ければ、渡された場所が両方を兼ねる (いままでどおり)
        let given = try MCPCommand.directories(
            arguments: [sketch], environment: [:], currentDirectory: cwd)
        #expect(given.package.path == sketch)
        #expect(given.facets.path == sketch)

        // 引数も無ければ作業ディレクトリ
        let neither = try MCPCommand.directories(
            arguments: [], environment: [:], currentDirectory: cwd)
        #expect(neither.package.path == cwd.path)
        #expect(neither.facets.path == cwd.path)

        // 環境変数はパッケージの場所を動かさない (Package.swift も .build/ もそこにある)
        let environmentOnly = try MCPCommand.directories(
            arguments: [], environment: ["MOKUME_WORK_DIR": elsewhere], currentDirectory: cwd)
        #expect(environmentOnly.package.path == cwd.path)
        #expect(environmentOnly.facets.path == elsewhere)
    }

    // ---------------------------------------------------------- 場所の解き方 (#2497)

    /// **場所は渡された基準から解く。** 相対の `URL` のまま持ち回ると、`directoryExists` が
    /// プロセスの作業ディレクトリから解いてしまい、渡した基準が無視される。
    @Test("相対の場所は、渡された基準から絶対パスに解く")
    func aRelativePlaceIsResolvedFromTheGivenBase() throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        for name in ["sub", "a", "x"] {
            try FileManager.default.createDirectory(
                at: root.appendingPathComponent(name, isDirectory: true),
                withIntermediateDirectories: true)
        }

        let sub = try MCPCommand.directories(
            arguments: ["sub"], environment: [:], currentDirectory: root)
        #expect(sub.package.path == root.appendingPathComponent("sub").path)
        #expect(sub.package.baseURL == nil, "相対の URL のまま: \(sub.package)")
        #expect(sub.facets.path == sub.package.path)

        // `..` は畳む (`GivenPath.resolve` と同じ)
        let up = try MCPCommand.directories(
            arguments: ["../x"], environment: [:],
            currentDirectory: root.appendingPathComponent("a", isDirectory: true))
        #expect(up.package.path == root.appendingPathComponent("x").path)
        #expect(!up.package.pathComponents.contains(".."))
        #expect(up.package.baseURL == nil)
    }

    /// 引用して打たれた `~` はシェルが展開しないので、道具が home へ展開する
    /// (`GivenPath.resolve` と同じ)。在らない場所は断るので、断る道が展開済みであることで見る。
    @Test("引用された ~ は home の下に展開する")
    func aQuotedTildeIsExpanded() throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let missing = "~/mokume-no-such-place-\(UUID().uuidString)"
        let thrown = #expect(throws: CommandFailure.self) {
            try MCPCommand.directories(
                arguments: [missing], environment: [:], currentDirectory: root)
        }
        let expanded = try GivenPath.resolve(missing, from: root).path
        #expect(expanded.hasPrefix(NSHomeDirectory()))
        #expect(thrown == .directoryNotFound(path: expanded))
    }

    // ---------------------------------------------------------- 引数の解き方 (#2321)

    /// **引数を取る口は、共有の解き手を通す** (`Arguments.parse`・#680・#814)。窓口だけが
    /// 最初の引数をそのまま場所にしていて、`mcp --help` は `--help` という場所の窓口として
    /// 標準入力を待っていた ([#2321](https://github.com/mokume-metal/mokume/issues/2321))。
    /// 断る文面は `run --help` と同じ形 (`Unknown option: …` と使い方)。
    @Test("知らない選択肢は、使い方を出して止まる", arguments: ["--help", "-h", "--version", "-c"])
    func anUnknownOptionIsRefused(option: String) throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let thrown = #expect(throws: CommandFailure.self) {
            try MCPCommand.directories(arguments: [option], environment: [:], currentDirectory: root)
        }
        guard case .usage(let text) = thrown else {
            Issue.record("使い方の誤りとして止まっていない: \(String(describing: thrown))")
            return
        }
        #expect(text.hasPrefix("Unknown option: \(option)\n"), "知らない選択肢を名指していない: \(text)")
        #expect(text.contains("Usage: "), "使い方を出していない: \(text)")
    }

    /// 位置引数は 1 つまで。`bundle` / `run` と同じ文面で、2 つ目を名指す。
    @Test("場所は 1 つだけ受け、2 つ目を名指して止まる")
    func onlyOneDirectoryIsTaken() throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(throws: CommandFailure.usage("Only one directory: b")) {
            try MCPCommand.directories(
                arguments: [root.path, "b"], environment: [:], currentDirectory: root)
        }
        // 1 つ目が在らなくても、余りを先に言う (本文の `mcp /nonexistent a b`)
        #expect(throws: CommandFailure.usage("Only one directory: a")) {
            try MCPCommand.directories(
                arguments: ["/nonexistent-\(UUID().uuidString)", "a", "b"], environment: [:],
                currentDirectory: root)
        }
    }

    /// **繋ぐ前に言う。** 繋がってから `observe` などが「答えが無い」と言うのでは、原因が
    /// 場所にあると気付けない。ファイルを指したときも、ディレクトリとしては在らない。
    @Test("在らない場所は、その道を名乗って止まる")
    func aMissingPlaceIsRefused() throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let missing = root.appendingPathComponent("nonexistent", isDirectory: true)
        let file = root.appendingPathComponent("notes.txt")
        try "not a directory".write(to: file, atomically: true, encoding: .utf8)

        for place in [missing.path, file.path] {
            let thrown = #expect(throws: CommandFailure.self) {
                try MCPCommand.directories(
                    arguments: [place], environment: [:], currentDirectory: root)
            }
            #expect(thrown == .directoryNotFound(path: place))
            #expect(thrown?.message.contains(place) == true, "在らない場所の道を名乗っていない")
        }
        // 作業ディレクトリが消えていれば、それも同じく言う。**場所を省いた結果なので、
        // 省けとは勧めない** (反証の指摘)
        let gone = #expect(throws: CommandFailure.self) {
            try MCPCommand.directories(arguments: [], environment: [:], currentDirectory: missing)
        }
        #expect(gone == .directoryNotFound(path: missing.path))
        #expect(gone?.message.contains("leave it out") == false, "省いた結果に省けと勧めている")
    }

    /// **`Package.swift` は求めない。** `claude mcp add mokume -- mokume mcp` は打った場所で
    /// 起こすので、スケッチでない場所で起こされうる (README)。求める方向へ広げると、その
    /// 起こし方を壊す。
    @Test("在る場所なら、Package.swift が無くても受ける")
    func anExistingPlaceWithoutAPackageIsTaken() throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("Package.swift").path))
        let given = try MCPCommand.directories(
            arguments: [root.path], environment: [:], currentDirectory: root)
        #expect(given.package.path == root.path)
        let typedHere = try MCPCommand.directories(
            arguments: [], environment: [:], currentDirectory: root)
        #expect(typedHere.package.path == root.path)
    }

    /// **口そのものが、窓口を回す (標準入力を読む) 前に止まる。** 回す手続きを差し替えて、
    /// 回されたかを見る — 本物を回すと、検査が標準入力を待って固まる。
    ///
    /// **掃除の置き場も差し替える** (#3298)。既定の共有の一時の場所は、他のプロセスや過去の実行が
    /// 積んだ項目の全体 (数万になりうる) を走査する。ここは引数の検査で、その中身に左右されない。
    @Test("引数の誤りでは、口は窓口を回さずに止まる")
    func theDoorStopsBeforeServing() throws {
        let root = try makeDirectory()
        let scratch = try makeDirectory()
        let wrong = [
            ["--help"], [root.path, "b"], [root.appendingPathComponent("nonexistent").path],
        ]
        for arguments in wrong {
            var served = false
            #expect(throws: CommandFailure.self, "\(arguments) で止まらなかった") {
                try MCPCommand.run(arguments, scratch: scratch) { _ in served = true }
            }
            #expect(!served, "\(arguments) で窓口を回した")
        }
        // 裏側: 在る場所なら回す
        var served = false
        try MCPCommand.run([root.path], scratch: scratch) { _ in served = true }
        #expect(served)
    }

    /// **回収の保証は、口が持つ** (#3298・条件 3)。`sweepStale` 単体の検査 (`ObservationCopyTests`) は、
    /// 口がそれを呼ぶことまでは見ない — 口から掃除を外しても緑のままだった。渡した置き場の中の
    /// 古い置き場だけを、口が窓口を回す前に消す。
    @Test("窓口が立つときに、渡した置き場の持ち主の居ない古い写しの置き場を掃く")
    func theDoorSweepsTheGivenScratchBeforeServing() throws {
        let root = try makeDirectory()
        let scratch = try makeDirectory()
        // 走っているはずのない pid (macOS の pid は 99999 まで)
        let dead = scratch.appendingPathComponent(
            "\(ObservationCopies.prefix)4000011-\(UUID().uuidString.lowercased())", isDirectory: true)
        let mine = scratch.appendingPathComponent(
            "\(ObservationCopies.prefix)\(getpid())-\(UUID().uuidString.lowercased())", isDirectory: true)
        let unrelated = scratch.appendingPathComponent("mokume-observe-4000011-aaaa", isDirectory: true)
        for url in [dead, mine, unrelated] {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }

        var sweptBeforeServing: Bool?
        try MCPCommand.run([root.path], scratch: scratch) { _ in
            sweptBeforeServing = !FileManager.default.fileExists(atPath: dead.path)
        }
        #expect(sweptBeforeServing == true, "窓口を回す前に、持ち主の居ない置き場を掃かなかった")
        #expect(FileManager.default.fileExists(atPath: mine.path), "生きている持ち主の置き場を消した")
        #expect(FileManager.default.fileExists(atPath: unrelated.path), "写しの置き場でない項目を消した")
    }

    /// **掃く場所の決め方は、純粋な関数が持つ** (#3298)。渡されなければ共有の一時の場所、渡されたら
    /// そのまま。`run` が決めた場所を掃くことは、上の `theDoorSweepsTheGivenScratchBeforeServing` が
    /// 実行で見る。**見えない穴**: `Command.dispatch` が場所を渡さないこと (製品の呼び口が省略のまま
    /// 呼ぶこと) はここでは見ない — 検査から呼ぶ口は `scratch:` を渡すので、製品の呼び口が省略を
    /// 渡し損ねても (別の場所を渡しても) 緑のままになる。
    @Test("掃く場所は、渡されなければ共有の一時の場所、渡されればその場所")
    func theScratchToSweepDefaultsToTheSharedTemporaryDirectory() throws {
        #expect(
            MCPCommand.scratchToSweep(given: nil).standardizedFileURL
                == FileManager.default.temporaryDirectory.standardizedFileURL)
        let given = try makeDirectory()
        #expect(MCPCommand.scratchToSweep(given: given) == given)
    }

    /// 引数の誤りでは、掃除まで進まない (在らない場所に窓口を立てる前に断る)。
    @Test("引数の誤りでは、置き場を掃かない")
    func aWrongArgumentSweepsNothing() throws {
        let scratch = try makeDirectory()
        let dead = scratch.appendingPathComponent(
            "\(ObservationCopies.prefix)4000012-\(UUID().uuidString.lowercased())", isDirectory: true)
        try FileManager.default.createDirectory(at: dead, withIntermediateDirectories: true)
        #expect(throws: CommandFailure.self) {
            try MCPCommand.run(["--help"], scratch: scratch) { _ in }
        }
        #expect(FileManager.default.fileExists(atPath: dead.path), "誤りの口が掃いた")
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
        let other = try makeSketch()
        try writeResolved(other, pins: pin("mokume-extras", "9.9.9"))
        let otherFetches = Fetches()
        let outcome = makeTools(directory: other, fetches: otherFetches)
            .call("reference", arguments: ["name": "api"])
        #expect(outcome.isError)
        #expect(otherFetches.urls.isEmpty)
    }

    @Test("版が引けなければ、組み立てて置く一手を添えて答える")
    func explainsHowToBuildTheListWhenTheVersionIsUnknown() throws {
        let directory = try makeSketch()  // Package.resolved が無い = パスで指している (スケッチの場所で)
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

    /// `null` は省略と同じに読む (#2393)。型の違う値 (上) は断ったまま。
    @Test("null の文書の名前は、省いたのと同じに一覧を返す")
    func readsANullDocumentNameAsOmitted() throws {
        let tools = makeTools(directory: try makeDirectory(), fetches: Fetches())
        let outcome = tools.call("reference", arguments: try decode(#"{"name":null}"#))
        #expect(!outcome.isError)
        #expect(outcome.text.contains("Documents this interface serves"))
    }

    /// 仕様の置き場の隣 (1 つ上) と、置き場の中のサブディレクトリに、`*.schema.json` を置いた
    /// 消費側。**どれも一覧 (`SchemasLocator.names(in:)`) には載らない。**
    private func consumerWithStrayDocuments() throws -> (tools: Tools, outside: URL) {
        let consumer = try ConsumerFixture.make()
        let manager = FileManager.default
        let outside = consumer.schemas.deletingLastPathComponent()
            .appendingPathComponent("outside.schema.json")
        try Data("OUTSIDE-SECRET".utf8).write(to: outside)
        let nested = consumer.schemas.appendingPathComponent("nested", isDirectory: true)
        try manager.createDirectory(at: nested, withIntermediateDirectories: true)
        try Data("NESTED-SECRET".utf8).write(to: nested.appendingPathComponent("inner.schema.json"))
        let tools = Tools(
            facets: Facets(directory: consumer.work, waitLimit: 0.2), makeID: { "fixed" })
        return (tools, outside)
    }

    /// `name` を検めずに `<置き場>/<name>.schema.json` へ繋ぐと、`../` で置き場の外の
    /// `*.schema.json` を読める (#2395)。**配っている一覧に無い名前は読まない** という約束を、
    /// 綴りの検め (`../`・区切り・絶対パス…) ではなく一覧との照合で守るので、兄弟の綴りも同じ表で見る。
    @Test(
        "一覧に無い文書の名前は、置き場の外や中のサブディレクトリを指していても読まずに断る",
        arguments: [
            "../outside", "..", ".", "", "a/b", "nested/inner", "/nested/inner",
            "../Schemas/observe-report", "observe-report/../../outside",
            "observe-report\0",
        ])
    func refusesDocumentNamesNotInTheList(name: String) throws {
        let (tools, _) = try consumerWithStrayDocuments()
        let outcome = tools.call("reference", arguments: ["name": name])
        #expect(outcome.isError)
        #expect(outcome.text == "There is no document by that name: \(name)")
        #expect(!outcome.text.contains("SECRET"))
    }

    /// 先頭が区切りの名前は、置き場の外には出ないが、`<置き場>/<name>.schema.json` への繋ぎが
    /// 区切りを 1 つに畳むので、**一覧の綴りと違うまま置き場の中を読める** (`/observe-report` は
    /// `observe-report` と同じファイルを開く)。直す前に赤になる綴り。絶対パスそのもの
    /// (`/private/…/outside`) は繋ぎの後も置き場の中の在らない場所を指すので、直す前から
    /// 読めず、この検査の入力にはならない。
    @Test(
        "先頭が区切りの名前は、一覧の綴りと違うので、置き場の中を指していても読まずに断る",
        arguments: ["/observe-report", "//observe-report", "/nested/inner", "Observe-Report"])
    func refusesNamesThatOnlyResolveToAListedFile(name: String) throws {
        let (tools, _) = try consumerWithStrayDocuments()
        let outcome = tools.call("reference", arguments: ["name": name])
        #expect(outcome.isError)
        #expect(outcome.text == "There is no document by that name: \(name)")
    }

    @Test("絶対パスで置き場の外のファイルを指す名前も、読まずに断る")
    func refusesAnAbsolutePathName() throws {
        // 繋ぎが置き場の中へ畳むので、直す前でも読めない (守りの検査。赤になる入力は上の表)
        let (tools, outside) = try consumerWithStrayDocuments()
        let name = String(outside.path.dropLast(".schema.json".count))
        let outcome = tools.call("reference", arguments: ["name": name])
        #expect(outcome.isError)
        #expect(outcome.text == "There is no document by that name: \(name)")
        #expect(!outcome.text.contains("SECRET"))
    }

    @Test("一覧にある名前は、置き場の外にファイルがあっても従来どおり読める")
    func stillServesNamesInTheList() throws {
        let (tools, _) = try consumerWithStrayDocuments()
        let outcome = tools.call("reference", arguments: ["name": "observe-report"])
        #expect(!outcome.isError)
        #expect(outcome.text.contains("observe-report"))
        // 一覧は置き場の 1 つ上のファイルを含まない
        let catalog = tools.call("reference", arguments: [:])
        #expect(catalog.text.contains("- observe-report"))
        #expect(!catalog.text.contains("outside"))
    }

    /// **組めなかった応答を空行で返さない。**
    ///
    /// 行区切りの JSON-RPC で空行を書くと、繋いでいる側からは「まだ応答が来ていない」
    /// と見分けが付かず、呼び出しが返らないまま待ち続ける。
    @Test("組めない応答は、空行ではなく失敗として返る")
    func unencodableResultsBecomeFailures() throws {
        // JSONSerialization は非数を受け付けない
        let line = JSONRPC.response(id: .number(7), result: ["value": Double.nan])
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
        let line = JSONRPC.failure(id: .number(NSNumber(value: Double.nan)), code: -32602, message: "だめ")

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
        let place = TestScratch.path("mokume-blocked")
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
