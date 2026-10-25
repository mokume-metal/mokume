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
                    writer.send(JSONRPC.pingResponse(id: id))
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
    ///
    /// **表の印がこの要求のものであるときだけ外す。** 答えを書いてから外すまでの隙に、同じ `id` の
    /// 新しい要求が読まれて表を上書きしていることがある。鍵だけで消すと、新しい要求の取り消しが
    /// 登録ごと消える。
    func retire(_ item: Item) {
        guard let key = item.key, let token = item.cancellation else { return }
        condition.withLock {
            if registry[key] === token { registry[key] = nil }
        }
    }
}

/// 取り消して、区画に置いたままにした要求。区画ごとに最後の 1 件だけを覚える。
///
/// 取り消しは窓口の待ちを切るだけで、スケッチには届かない ([#3030](https://github.com/mokume-metal/mokume/issues/3030))。
/// 続けて撮る観測は撮り終えるまで区画を塞ぐので、その間に置いた次の要求が時間切れになったとき、
/// 「応えない」と取り違えずに、前に取り消した要求をまだ撮っていると案内するための記憶である。
/// **道具を走らせる手だけが触る** (読み取りの手は触らない) ので、鍵は持たない。
final class AbandonedRequests {
    private var ids: [String: String] = [:]

    init() {}

    /// 区画に置いたまま待ちを切った。
    func abandon(facet: URL, id: String) { ids[facet.path] = id }

    /// 区画のどれかの要求に答えが返った。塞いでいたものは終わっている。
    func clear(facet: URL) { ids[facet.path] = nil }

    /// その区画で、取り消したまま塞いでいるかもしれない要求の識別子。
    func id(for facet: URL) -> String? { ids[facet.path] }
}
