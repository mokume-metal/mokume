// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation

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
                    "serverInfo": ["name": "mokume", "version": "0"],
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
    static func run(_ arguments: [String]) throws(CommandFailure) {
        let directory = URL(
            fileURLWithPath: arguments.first ?? FileManager.default.currentDirectoryPath,
            isDirectory: true)
        let server = MCPServer(
            tools: Tools(facets: Facets(directory: directory)),
            readLine: { Swift.readLine(strippingNewline: true) },
            write: { line in
                print(line)
            })
        server.serve()
    }
}
