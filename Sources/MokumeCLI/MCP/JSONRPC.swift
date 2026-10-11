// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation

/// 標準入出力でやりとりする JSON-RPC の 1 往復。
///
/// 手続きは行区切りの JSON で流れる。**呼び出しとして読めなかった行には誤りを 1 行返し、
/// 繋がりは切らない** — 1 行の壊れで窓口ごと落ちると、繋いでいる側からは原因が分からない。
/// 黙って落とすのもいけない。`id` を読める行に黙ると、繋いでいる側は来ない答えを待ち
/// 続ける (JSON-RPC 2.0 §5・#2317)。
enum JSONRPC {
    /// 受け取った呼び出し。
    struct Call {
        let id: Any?
        let method: String
        let params: [String: Any]

        /// 応答を返すべき呼び出しか。返り値を待たない通知には `id` が無い。
        ///
        /// `"id": null` は通知ではない (`NSNull` が入る)。JSON-RPC 2.0 §4 は `id` に
        /// Null を許しており、答えはその `null` で返る。
        var expectsResponse: Bool { id != nil }
    }

    /// 1 行を読んだ結果。
    enum Line {
        /// 手続きの呼び出し (通知を含む)。
        case call(Call)
        /// 呼び出しとして読めなかった。通知かどうかによらず、この誤りの 1 行で答える。
        case refused(reply: String)
    }

    /// JSON として読めない行の符号。
    static let parseError = -32700
    /// JSON だが呼び出しの形でない行の符号。
    static let invalidRequest = -32600

    /// 1 行を呼び出しとして解く。
    ///
    /// **呼び出しの形でない行は、通知かどうかを見ずに断る。** 通知かどうかを決める `id`
    /// も読めているとは限らないので、JSON-RPC 2.0 §5 は誤りを返し、`id` を読めなければ
    /// `null` にすると決めている。束 (配列) は扱わない — 名乗る版 (MCP 2024-11-05) は
    /// 束を含まないので、中身によらず 1 行で断る。JSON としては読めるがオブジェクトで
    /// ない行 (`5` など) も、壊れた JSON ではなく形の誤りとして断る
    static func parse(_ line: String) -> Line {
        guard
            let object = try? JSONSerialization.jsonObject(
                with: Data(line.utf8), options: [.fragmentsAllowed])
        else {
            return .refused(
                reply: failure(
                    id: nil, code: parseError, message: "parse error: the line is not JSON"))
        }
        guard let fields = object as? [String: Any] else {
            return .refused(
                reply: failure(
                    id: nil, code: invalidRequest,
                    message: "invalid request: expected one JSON object (batches are not supported)"
                ))
        }
        guard let method = fields["method"] as? String else {
            return .refused(
                reply: failure(
                    id: fields["id"], code: invalidRequest,
                    message: "invalid request: method must be a string"))
        }
        return .call(
            Call(
                id: fields["id"], method: method,
                params: fields["params"] as? [String: Any] ?? [:]))
    }

    /// JSON-RPC の「内側で転んだ」符号。
    static let internalError = -32603

    /// 結果を返す 1 行。
    ///
    /// **組めなかったら失敗として返す。** 空行を返すと、繋いでいる側からは
    /// 「応答が来ない」と見分けが付かず、呼び出しが返らないまま待ち続ける。
    static func response(id: Any?, result: [String: Any]) -> String {
        line(["jsonrpc": "2.0", "id": id ?? NSNull(), "result": result])
            ?? failure(id: id, code: internalError, message: "could not turn the reply into JSON")
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
        + #"{"code":-32603,"message":"could not turn the reply into JSON"}}"#

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
