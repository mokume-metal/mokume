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

    /// JSON-RPC の「内側で転んだ」符号。
    static let internalError = -32603

    /// 結果を返す 1 行。
    ///
    /// **組めなかったら失敗として返す。** 空行を返すと、繋いでいる側からは
    /// 「応答が来ない」と見分けが付かず、呼び出しが返らないまま待ち続ける。
    static func response(id: Any?, result: [String: Any]) -> String {
        line(["jsonrpc": "2.0", "id": id ?? NSNull(), "result": result])
            ?? failure(id: id, code: internalError, message: "応答を JSON にできませんでした")
    }

    /// 失敗を返す 1 行。**この 1 行は必ず返る。**
    static func failure(id: Any?, code: Int, message: String) -> String {
        line([
            "jsonrpc": "2.0", "id": id ?? NSNull(),
            "error": ["code": code, "message": message],
        ]) ?? lastResort
    }

    /// 呼び出しの `id` すら JSON へ戻せなかったときの 1 行。
    ///
    /// **組み立てを通らないので、失敗しようがない。** `id` を落とすので相手は
    /// どの呼び出しへの応答かを照合できなくなるが、黙るよりはよい。
    private static let lastResort = #"{"jsonrpc":"2.0","id":null,"error":"#
        + #"{"code":-32603,"message":"応答を JSON にできませんでした"}}"#

    /// JSON の 1 行に組む。組めなければ `nil`。
    ///
    /// **`try?` だけでは足りない。** `JSONSerialization` は JSON にできない値
    /// (非数・無限大・JSON でない型) を渡されると Swift の error ではなく ObjC の例外を
    /// 出すので、`try?` は素通りし**プロセスごと落ちる**。先に形を見る。
    private static func line(_ object: [String: Any]) -> String? {
        guard JSONSerialization.isValidJSONObject(object),
            let data = try? JSONSerialization.data(
                withJSONObject: object, options: [.withoutEscapingSlashes])
        else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
