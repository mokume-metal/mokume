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
        /// **`"id": null` はここまで届かない。** MCP 2024-11-05 の basic は request の ID に
        /// null を禁じ、`null` の `id` の答えは読めない行を断る誤り (`id: null`) と繋ぎ手から
        /// 見分けが付かないので、``JSONRPC/parse(_:)`` が -32600 で断る
        /// ([#2353](https://github.com/mokume-metal/mokume/issues/2353)・#2317 の A3 を変えた)。
        /// ここへ届く `id` は、無い (通知) か、String か Number である。
        var expectsResponse: Bool { id != nil }
    }

    /// 1 行を読んだ結果。
    enum Line {
        /// 手続きの呼び出し (通知を含む)。
        case call(Call)
        /// 呼び出しとして読めなかった。通知かどうかによらず、この誤りの 1 行で答える。
        case refused(reply: String)
        /// 相手からの応答 (`method` が無く、`result` か `error` を持つ)。答えずに読み飛ばす。
        ///
        /// JSON-RPC 2.0 は応答に答えない。窓口は自分から要求を出さないので、届く応答は
        /// 残らず余分なものである。誤りを返すと、相手の `id` の空間に別の答えが紛れうる
        case response
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
    /// ない行 (`5` など) も、壊れた JSON ではなく形の誤りとして断る。
    ///
    /// **応答の形の行は断らずに読み飛ばす** (`Line.response`)。`method` が無いことだけで
    /// 断ると、応答にまで誤りを返してしまう。`method` も `result` も `error` も無い行
    /// (`{"id":3}`) は応答ではないので、形の誤りとして断る
    ///
    /// **呼び出しの封筒も検める** ([#2353](https://github.com/mokume-metal/mokume/issues/2353)・
    /// JSON-RPC 2.0 §4・§5.1)。`jsonrpc` は `"2.0"`、`id` は String か Number (要求では
    /// Null も不可 — MCP 2024-11-05 の basic)、`params` はオブジェクト (省くのは可) でなければ、
    /// 通知かどうかを見ずに -32600 で断る。答えの `id` は読める `id` (String・Number) があれば
    /// それ、無ければ `null` — 型の違う `id` をそのまま載せると、繋ぎ手が型で検めたときに
    /// 答えを誤りとして受け取る。通知 (`id` が無い行) に黙るのは、封筒が正しいときだけである
    static func parse(_ line: String) -> Line {
        // **`Double` に収まらない数は、符号によらず読めない行として断る** (#2476)。
        // `JSONSerialization` は正の側 (`1e400`) は投げるが、負の側 (`-1e400`) は投げずに
        // `-inf` で読む。通すと `id` が JSON に戻せず `lastResort` へ落ち、引数の数は `-inf` の
        // まま道具へ渡る。読めた木を歩いて、有限でない数が 1 つでもあれば同じ失敗にする。
        //
        // **見るのは木に残った数だけ。** 同じキーを 2 度書いた行の、後ろの値は木から落ちる
        // (`{"id":1,"id":-1e400}`) ので、断れない。道具へ渡るのは残った有限の値だけで、
        // `-inf` は届かない。落ちた数まで断るには、文字から探す読み手 (`MokumeCore` の
        // `JSONFile`) と同じ走査が要り、`MokumeCLI` から使える口が無い
        guard
            let object = try? JSONSerialization.jsonObject(
                with: Data(line.utf8), options: [.fragmentsAllowed]),
            allNumbersAreFinite(object)
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
        // `method` と `result` を両方持つ行は応答ではない。呼び出しとして `method` を見る
        if fields["method"] == nil, fields["result"] != nil || fields["error"] != nil {
            return .response
        }
        let readableID = readableID(fields["id"])
        func refuse(_ message: String) -> Line {
            .refused(
                reply: failure(
                    id: readableID, code: invalidRequest, message: "invalid request: " + message))
        }
        guard let method = fields["method"] as? String else {
            return refuse("method must be a string")
        }
        guard fields["jsonrpc"] as? String == "2.0" else {
            return refuse(#"jsonrpc must be "2.0""#)
        }
        switch fields["id"] {
        case nil: break
        case is NSNull: return refuse("id must not be null in a request (omit it for a notification)")
        default:
            guard readableID != nil else { return refuse("id must be a string or a number") }
        }
        // 省くのは可 (`params` の無い要求)。`null` や配列は、黙って空に倒さず断る
        var params: [String: Any] = [:]
        if let given = fields["params"] {
            guard let object = given as? [String: Any] else {
                return refuse("params must be an object")
            }
            params = object
        }
        return .call(Call(id: fields["id"], method: method, params: params))
    }

    /// 答えに載せてよい `id` (String か Number)。読めなければ `nil` で、答えの `id` は `null`。
    ///
    /// 真偽は数ではない — `JSONSerialization` は `true` も `NSNumber` で渡すので、型で外す。
    private static func readableID(_ value: Any?) -> Any? {
        switch value {
        case let text as String: text
        case let number as NSNumber where CFGetTypeID(number) != CFBooleanGetTypeID(): number
        default: nil
        }
    }

    /// 読んだ木の数が、残らず有限か。
    ///
    /// `isValidJSONObject` は使わない — 最上位が数や文字列だけの行 (断片) には偽を返すので、
    /// `-1e400` 単独の行と配列の中の数を同じ物差しで見られない。真偽は `NSNumber` で届き
    /// `doubleValue` が有限なので、見分けずにそのまま見てよい。
    private static func allNumbersAreFinite(_ value: Any) -> Bool {
        switch value {
        case let members as [String: Any]: members.values.allSatisfy(allNumbersAreFinite)
        case let items as [Any]: items.allSatisfy(allNumbersAreFinite)
        case let number as NSNumber: number.doubleValue.isFinite
        default: true
        }
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
