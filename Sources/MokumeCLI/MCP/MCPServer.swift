// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation
import mokume

/// エージェントの窓口。
///
/// 標準入出力で行区切りの JSON-RPC をやりとりする。手続きは 4 つだけ —
/// 繋ぎ始めの挨拶・生きているかの確かめ (`ping`)・道具立ての一覧・呼び出し。
///
/// **読みと実行を分ける** ([#2355](https://github.com/mokume-metal/mokume/issues/2355))。
/// 読み取りは 1 本の手 (``Inbox/feed(readLine:writer:)``) が受け持ち、道具を走らせる手 (``serve()``)
/// は従来どおり 1 本ずつ、届いた順に走らせて答える。読み取りの手が**その場で済ませる**のは 2 つだけ:
///
/// - `ping` — 道具が走っている間も、空の結果で速やかに答える (MCP 2024-11-05 の Ping)
/// - `notifications/cancelled` — 実行中 (または走るのを待っている) 要求の ``Cancellation`` を立てる。
///   走っている道具は区画を待つ合間に印を見て待ちを切り、**取り消された要求には答えない**
///   (MCP の取り消しの扱い)。知らない `id`・答え終えた `id` の取り消しは何もしない
///
/// それ以外 (`initialize`・`tools/list`・`tools/call`・壊れた行への誤り) は、読んだ順に 1 本ずつ答える。
/// 区画は要求も応答も 1 枚しか持たないので、道具を並行には走らせない。標準出力へ書くのは
/// ``SerialWriter`` の 1 か所で、2 つの手の書き込みが 1 行の中で混ざらない。
///
/// **取り消しが切れるのは区画を待つ道具 (`observe`・`input`) の待ち。** 置いた要求は区画に残り、
/// スケッチが後から応えうる (次の要求が置き換える)。**続けて撮る観測を取り消すと、スケッチは撮り終える
/// まで区画を塞ぐ** (取り消しはスケッチへ届かない・#3030)。窓口はそれを覚え (``AbandonedRequests``)、
/// 次の呼び出しがその間に時間切れになったら「応えない」ではなく、前に取り消した要求をまだ撮っていると
/// 案内する。公開 API の取得のように区画を待たない道具は、
/// 走り終えるまで切れない — その間も `ping` には答える。
struct MCPServer {
    /// 名乗る版。手続きの版であって、この道具の版ではない。
    static let protocolVersion = "2024-11-05"

    let tools: Tools
    /// 1 行読む。終わりなら `nil`。**読み取りの手から呼ばれる** (呼ぶ手は 1 本だけ)。
    var readLine: @Sendable () -> String?
    /// 1 行書く。**2 つの手から呼ばれるが、``SerialWriter`` が 1 行ずつに直列化する。**
    var write: @Sendable (String) -> Void

    /// 終わりが来るまで応え続ける。
    func serve() {
        let writer = SerialWriter(write)
        let inbox = Inbox()
        let readLine = self.readLine
        Thread.detachNewThread { inbox.feed(readLine: readLine, writer: writer) }
        while let item = inbox.next() {
            // 走る前に取り消されていたら、走らせず答えない
            if item.cancellation?.isCancelled != true {
                answer(item, writer: writer)
            }
            // 答えを書いた後に外す。**同じ印のときだけ** (``Inbox/retire(_:)``)
            inbox.retire(item)
        }
    }

    /// 積まれた 1 件に答える。
    private func answer(_ item: Inbox.Item, writer: SerialWriter) {
        switch JSONRPC.parse(item.line) {
        case .call(let call):
            guard let response = respond(to: call, cancellation: item.cancellation) else { return }
            // **走っている間に取り消された要求には答えない。** 取り消した側は答えを待っていない
            guard item.cancellation?.isCancelled != true else { return }
            writer.send(response)
        case .refused(let reply):
            // **1 行の壊れで繋がりを切らない。** 切ると、繋いでいる側からは
            // 何が起きたのか分からなくなる。黙りもしない — 誤りを 1 行返して次の行へ
            // 進む。黙ると、繋いでいる側は来ない答えを待ち続ける (#2317)
            writer.send(reply)
        case .response:
            // 応答には答えない。窓口は要求を出さないので、待っている応答も無い
            return
        }
    }

    /// 1 つの呼び出しに答える。答えを返さない通知なら `nil`。
    ///
    /// **通知かどうかは、手続きの名前を見る前にここで 1 度だけ決める。** 名前ごとの枝で
    /// 決めると、枝を足すたびに判断が漏れうる — `initialize`・`tools/list`・`tools/call`
    /// の枝が通知にも `"id": null` で答え、`tools/call` は道具まで走らせていた (#2317)。
    /// MCP 2024-11-05 の通知 (`notifications/` の 4 つ) に、下の枝の名前のものは無い。
    /// 名前によらず、知らない通知と同じく黙って捨てる
    func respond(to call: JSONRPC.Call, cancellation: Cancellation? = nil) -> String? {
        // JSON-RPC 2.0 §4.1 — 通知には、手続きの名前によらず答えない
        guard call.expectsResponse else { return nil }
        switch call.method {
        case "ping":
            // 空の結果で速やかに答える (MCP 2024-11-05 の Ping・#2318)。窓口は挨拶の
            // 前後で状態を変えないので、挨拶の前でも同じ答えになる
            return JSONRPC.pingResponse(id: call.id)
        case "initialize":
            return JSONRPC.response(
                id: call.id,
                result: [
                    "protocolVersion": Self.protocolVersion,
                    "capabilities": ["tools": [:] as [String: Any]],
                    // **繋いだ側が古い窓口を判別できる唯一の手掛かり。** 接続は
                    // 張ったまま保たれるので、道具を更新しても繋がっている窓口は
                    // 古いままである (#634)
                    "serverInfo": ["name": "mokume", "version": ToolVersion.describe()],
                ])
        case "tools/list":
            return JSONRPC.response(id: call.id, result: ["tools": Tools.definitions])
        case "tools/call":
            guard let name = call.params["name"] as? String else {
                return JSONRPC.failure(id: call.id, code: -32602, message: "name is required")
            }
            // **オブジェクトでない引数は、道具を走らせずに断る。** 黙って空に倒すと、
            // `"arguments":"x"` が引数なしの頼みに化けて道具が走る (#2319)。省いたときと
            // `null` は「渡していない」と読み、従来どおり空の引数で走らせる
            let arguments: [String: Any]
            switch call.params["arguments"] {
            case nil, is NSNull: arguments = [:]
            case let object as [String: Any]: arguments = object
            default:
                return JSONRPC.failure(
                    id: call.id, code: -32602, message: "arguments must be an object")
            }
            let outcome = tools.call(name, arguments: arguments, cancellation: cancellation)
            return JSONRPC.response(
                id: call.id,
                result: [
                    "content": [["type": "text", "text": outcome.text]],
                    "isError": outcome.isError,
                ])
        default:
            return JSONRPC.failure(
                id: call.id, code: -32601, message: "no such method: \(call.method)")
        }
    }
}

/// 窓口を立てる。
enum MCPCommand {
    /// 引数と環境から、2 つの基準を決める。
    ///
    /// **区画は環境変数がいちばん強い。** 区画はスケッチが書く場所で、スケッチは
    /// `MOKUME_WORK_DIR` に従う ([ADR-0018] 決定 2)。窓口が引数を優先すると、書き先と
    /// 食い違って噛み合わない。
    ///
    /// **パッケージの場所は環境変数に動かされない。** `Package.swift` も `.build/` も
    /// そこにあり、動かすとビルドも面の仕様の解決も行き先を失う。
    ///
    /// **引数は共有の解き手で解く** (``Arguments``・#680・#814)。最初の引数をそのまま
    /// 場所にしていた頃は、`mcp --help` が `--help` という場所の窓口として標準入力を待ち、
    /// 余る引数も黙って受けていた ([#2321](https://github.com/mokume-metal/mokume/issues/2321))。
    ///
    /// **在らない場所は、繋ぐ前に断る。** 繋がってから道具が「答えが無い」と言うのでは、
    /// 原因が場所にあると気付けない。**`Package.swift` は求めない** — `claude mcp add mokume
    /// -- mokume mcp` は打った場所で起こすので、スケッチでない場所で起こされうる。
    ///
    /// 断るときは投げるだけで、標準出力には何も書かない (MCP の stdio は標準出力に伝言以外を
    /// 書くことを禁じている)。失敗は `main.swift` が標準エラーへ書く。
    ///
    /// [ADR-0018]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0018-observation-and-control-surface.md
    static func directories(
        arguments: [String],
        environment: [String: String] = ProcessInfo.processInfo.environment,
        currentDirectory: URL? = GivenPath.currentDirectory
    ) throws(CommandFailure) -> (package: URL, facets: URL) {
        let parsed = try Arguments.parse(
            arguments, positionalIsPlace: true, surplus: .reject { "Only one directory: \($0)" })
        // **場所は受け取った時点で 1 度だけ絶対パスにする** (``GivenPath``・#2497)。相対の
        // `URL` のまま持ち回ると、在るかの判定も道具たちも、その時点の作業ディレクトリから
        // 渡された基準を無視して解く。省略は走らせた場所
        let package = try GivenPath.resolve(parsed.positional ?? ".", from: currentDirectory)
        // 在るかの判定は 1 本を通す (`ObjCBool` の受け渡しを写さない・#988)
        guard WorkDirectory.directoryExists(at: package) else {
            throw .directoryNotFound(path: package.path)
        }
        // 区画の基準を決める計算は、走らせる口と同じ 1 つを通る (#791)。環境変数の相対の綴りも、
        // 走らせた場所が読めない回は引数の場所と同じ失敗で止める (#2497)
        let workDirectory = try GivenPath.workDirectory(
            environment: environment, from: currentDirectory)
        // 共有の置き場の根も同じ約束を負う (道具が呼ばれた後では止められないので、立てる前に確かめる)
        _ = try BuildDirectory.root(
            environment: environment, home: URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true),
            currentDirectory: currentDirectory)
        return (package, Invocation.facetBase(under: package, workDirectory: workDirectory))
    }

    /// - Parameter serving: 窓口を回す手続き。**検査から差し替える** — 既定は標準入力が
    ///   閉じるまで読み続けるので、回す前に止まることを確かめる検査がここで固まらないように
    ///   する (`WatchCommand.run(_:watching:)` と同じ作法)。
    static func run(
        _ arguments: [String], serving: (MCPServer) -> Void = { $0.serve() }
    ) throws(CommandFailure) {
        // **窓口を立てる前に解く。** 立ててからでは、誤りを言う前に標準入力を待つ
        let directories = try directories(arguments: arguments)
        // 基準を環境変数が決めたのかどうかは、応えないときの案内が名乗る (#380)
        let given = WorkDirectory.given != nil
        // 窓口を立てた場所と、そこがスケッチかも同じく起動の時点で決め、案内が名乗る (#2487)
        let place = InterfacePlace.at(directories.package)
        let server = MCPServer(
            tools: Tools(
                facets: Facets(
                    directory: directories.facets, workDirectoryGiven: given, place: place),
                packageDirectory: directories.package),
            readLine: { Swift.readLine(strippingNewline: true) },
            write: { line in
                print(line)
            })
        serving(server)
    }
}
