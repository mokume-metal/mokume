// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation
import mokume

/// エージェントの窓口。
///
/// 標準入出力で行区切りの JSON-RPC をやりとりする。手続きは 3 つだけ —
/// 繋ぎ始めの挨拶・道具立ての一覧・呼び出し。
struct MCPServer {
    /// 名乗る版。手続きの版であって、この道具の版ではない。
    static let protocolVersion = "2024-11-05"

    let tools: Tools
    /// 1 行読む。終わりなら `nil`。
    var readLine: () -> String?
    /// 1 行書く。
    var write: (String) -> Void

    /// 終わりが来るまで応え続ける。
    func serve() {
        while let line = readLine() {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            guard let call = JSONRPC.parse(trimmed) else {
                // **1 行の壊れで繋がりを切らない。** 切ると、繋いでいる側からは
                // 何が起きたのか分からなくなる
                continue
            }
            guard let response = respond(to: call) else { continue }
            write(response)
        }
    }

    /// 1 つの呼び出しに答える。答えを返さない通知なら `nil`。
    func respond(to call: JSONRPC.Call) -> String? {
        switch call.method {
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
                return JSONRPC.failure(id: call.id, code: -32602, message: "name が要ります")
            }
            let arguments = call.params["arguments"] as? [String: Any] ?? [:]
            let outcome = tools.call(name, arguments: arguments)
            return JSONRPC.response(
                id: call.id,
                result: [
                    "content": [["type": "text", "text": outcome.text]],
                    "isError": outcome.isError,
                ])
        default:
            // 通知 (答えを待たないもの) には黙って従う
            guard call.expectsResponse else { return nil }
            return JSONRPC.failure(
                id: call.id, code: -32601, message: "知らない手続きです: \(call.method)")
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
    /// [ADR-0018]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0018-observation-and-control-surface.md
    static func directories(
        arguments: [String],
        environment: [String: String] = ProcessInfo.processInfo.environment,
        currentDirectory: URL = URL(
            fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
    ) -> (package: URL, facets: URL) {
        let package = arguments.first.map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? currentDirectory
        // 区画の基準を決める計算は、走らせる口と同じ 1 つを通る (#791)
        return (
            package,
            Invocation.facetBase(
                under: package, workDirectory: WorkDirectory.given(environment: environment))
        )
    }

    static func run(_ arguments: [String]) throws(CommandFailure) {
        let directories = directories(arguments: arguments)
        // 基準を環境変数が決めたのかどうかは、応えないときの案内が名乗る (#380)
        let given = WorkDirectory.given != nil
        let server = MCPServer(
            tools: Tools(
                facets: Facets(directory: directories.facets, workDirectoryGiven: given),
                packageDirectory: directories.package),
            readLine: { Swift.readLine(strippingNewline: true) },
            write: { line in
                print(line)
            })
        server.serve()
    }
}
