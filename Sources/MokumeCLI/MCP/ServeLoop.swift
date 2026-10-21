// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation

// 窓口の読みと実行の分け方 ([#2355](https://github.com/mokume-metal/mokume/issues/2355))。
//
// 読み取りの手 (``Inbox/feed(readLine:writer:)``) と、道具を走らせる手 (``MCPServer/serve()``) が
// 触るものを、ここに集める。**どれも `nonisolated`** — `MokumeCLI` は main actor 既定だが、読み取りの
// 手は main actor の外で走る。状態を持つ型は鍵の内側でだけ触る。

/// 取り消しの印。実行中の道具が、待ちの合間に見る。
nonisolated final class Cancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var raised = false

    init() {}

    /// 取り消す。何度呼んでも同じ。
    func cancel() { lock.withLock { raised = true } }

    var isCancelled: Bool { lock.withLock { raised } }
}

/// 標準出力へ書く唯一の口。
///
/// **書き手は 2 つある** — 読み取りの手 (`ping` への即答) と、道具を走らせる手 (答え)。1 行は 1 つの
/// 答えで完結しなければならない (行区切りの JSON)。2 つの書き手が重なっても、鍵が 1 行ずつに直列化する。
nonisolated final class SerialWriter: @unchecked Sendable {
    private let lock = NSLock()
    private let write: @Sendable (String) -> Void

    init(_ write: @escaping @Sendable (String) -> Void) { self.write = write }

    func send(_ line: String) {
        lock.withLock { write(line) }
    }
}

/// 読み取りの手が積み、道具を走らせる手が 1 本ずつ取り出す、届いた順の行の列。
///
/// **要求の `id` を引いて取り消しの印を渡す表も、同じ鍵の内側で持つ。** 積まれた (まだ走っていない)
/// 要求も、走っている要求も、表に在るあいだは取り消せる。答え終えた要求は表から外すので、終わった
/// `id` の取り消しは何も起こさない。
nonisolated final class Inbox: @unchecked Sendable {
    /// 走らせる 1 件。
    struct Item: Sendable {
        let line: String
        /// 要求 (`id` のある呼び出し) のときの、取り消しの印と表の鍵。通知や読めなかった行は `nil`。
        let cancellation: Cancellation?
        let key: String?
    }

    private let condition = NSCondition()
    private var items: [Item] = []
    private var registry: [String: Cancellation] = [:]
    private var finished = false

    init() {}

    /// 標準入力の続きを読んで振り分ける。**読み取りの手で走る。** 終わりが来たら列を閉じる。
    ///
    /// - `ping` の要求は、その場で空の結果を書く (MCP 2024-11-05 の Ping は速やかな応答を求める。
    ///   道具が走っている間も届く)。
    /// - `notifications/cancelled` は、`requestId` の要求の印を立てる。知らない・終わった `id` は
    ///   何も起こさない。通知なので答えない。
    /// - それ以外は、読んだ順に積む。壊れた行への誤りも、ここでは答えずに積み、順に答える。
    func feed(readLine: @Sendable () -> String?, writer: SerialWriter) {
        while let line = readLine() {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            guard case .call(let call) = JSONRPC.parse(trimmed) else {
                push(Item(line: trimmed, cancellation: nil, key: nil))
                continue
            }
            if let id = call.id {
                if call.method == "ping" {
                    writer.send(JSONRPC.response(id: id, result: [:]))
                    continue
                }
                let token = Cancellation()
                push(Item(line: trimmed, cancellation: token, key: id.key), registering: token)
            } else if call.method == "notifications/cancelled" {
                if let raw = call.params["requestId"], let id = JSONRPC.ID(raw) { cancel(key: id.key) }
            } else {
                push(Item(line: trimmed, cancellation: nil, key: nil))
            }
        }
        finish()
    }

    private func push(_ item: Item, registering token: Cancellation? = nil) {
        condition.withLock {
            if let token, let key = item.key { registry[key] = token }
            items.append(item)
            condition.signal()
        }
    }

    private func cancel(key: String) {
        let token = condition.withLock { registry[key] }
        token?.cancel()
    }

    /// 入力の終わり。積まれた分を取り出し終えると、`next()` が `nil` を返す。
    private func finish() {
        condition.withLock {
            finished = true
            condition.broadcast()
        }
    }

    /// 次の 1 件。無ければ来るまで待つ。入力が終わって積まれた分も無ければ `nil`。
    func next() -> Item? {
        condition.withLock {
            while items.isEmpty && !finished { condition.wait() }
            return items.isEmpty ? nil : items.removeFirst()
        }
    }

    /// 答え終えた (または読み飛ばした) 要求を表から外す。以後その `id` の取り消しは何もしない。
    func retire(_ item: Item) {
        guard let key = item.key else { return }
        condition.withLock { registry[key] = nil }
    }
}
