// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation

/// 標準入出力でやりとりする JSON-RPC の 1 往復。
///
/// 手続きは行区切りの JSON で流れる。**読めなかった行は落とすが、繋がりは切らない** —
/// 1 行の壊れで窓口ごと落ちると、繋いでいる側からは原因が分からない。
enum JSONRPC {
    /// 受け取った呼び出し。
    struct Call {
        let id: Any?
        let method: String
        let params: [String: Any]

        /// 応答を返すべき呼び出しか。返り値を待たない通知には `id` が無い。
        var expectsResponse: Bool { id != nil }
    }

    /// 1 行を呼び出しとして解く。
    static func parse(_ line: String) -> Call? {
        guard let data = line.data(using: .utf8),
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let method = object["method"] as? String
        else { return nil }
        return Call(
            id: object["id"], method: method, params: object["params"] as? [String: Any] ?? [:])
    }

    /// 結果を返す 1 行。
    static func response(id: Any?, result: [String: Any]) -> String {
        line(["jsonrpc": "2.0", "id": id ?? NSNull(), "result": result])
    }

    /// 失敗を返す 1 行。
    static func failure(id: Any?, code: Int, message: String) -> String {
        line([
            "jsonrpc": "2.0", "id": id ?? NSNull(),
            "error": ["code": code, "message": message],
        ])
    }

    private static func line(_ object: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.withoutEscapingSlashes]),
            let text = String(data: data, encoding: .utf8)
        else { return "" }
        return text
    }
}
