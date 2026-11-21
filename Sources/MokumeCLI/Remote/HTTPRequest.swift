// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation

/// `--remote` の受け口に届いた HTTP/1.1 の要求 1 件。
///
/// 受け口が話すのは、ページ・状態の配信 (Server-Sent Events)・つまみの書き込みの 3 つだけなので、
/// 解釈も要求行・ヘッダ・`Content-Length` の本文に限る。chunked の本文と継続行は断る。
nonisolated struct HTTPRequest: Equatable, Sendable {
    let method: String
    /// クエリを除いたパス (`/events`)。
    let path: String
    /// クエリの値。同じ鍵が 2 度あれば後のもの。
    let query: [String: String]
    /// 鍵は小文字にそろえる。
    let headers: [String: String]
    let body: Data

    /// 解釈の結果。
    enum Parse: Equatable {
        /// まだ届ききっていない。続きを読む。
        case incomplete
        /// 1 件そろった。`consumed` は使ったバイト数。
        case complete(HTTPRequest, consumed: Int)
        /// 上限を超えた。読むのをやめて断る。
        case tooLarge
        /// HTTP として読めない。
        case invalid(String)
    }

    /// 1 件の要求の上限 (ヘッダと本文の合計)。つまみの書き込みは 1 件ずつなので、これで余る。
    static let limit = 64 * 1024

    /// 受け取ったバイト列の先頭から、要求を 1 件読む。
    static func parse(_ data: Data, limit: Int = limit) -> Parse {
        let separator = Data("\r\n\r\n".utf8)
        guard let end = data.range(of: separator) else {
            return data.count > limit ? .tooLarge : .incomplete
        }
        guard end.lowerBound <= limit else { return .tooLarge }
        guard let head = String(data: data[data.startIndex..<end.lowerBound], encoding: .utf8) else {
            return .invalid("the request head is not UTF-8")
        }
        var lines = head.components(separatedBy: "\r\n")
        let parts = lines.removeFirst().split(separator: " ", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[2].hasPrefix("HTTP/1."), !parts[0].isEmpty, parts[1].hasPrefix("/") else {
            return .invalid("the request line is not \"METHOD /path HTTP/1.x\"")
        }
        var headers: [String: String] = [:]
        for line in lines {
            guard let colon = line.firstIndex(of: ":"), !line.hasPrefix(" "), !line.hasPrefix("\t") else {
                return .invalid("a header line has no name")
            }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            headers[name] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        if headers["transfer-encoding"] != nil { return .invalid("chunked bodies are not accepted") }
        let length: Int
        if let given = headers["content-length"] {
            guard let number = Int(given), number >= 0 else { return .invalid("Content-Length is not a number") }
            length = number
        } else {
            length = 0
        }
        let bodyStart = end.upperBound
        guard bodyStart - data.startIndex + length <= limit else { return .tooLarge }
        guard data.endIndex - bodyStart >= length else { return .incomplete }
        let (path, query) = split(target: String(parts[1]))
        let request = HTTPRequest(
            method: String(parts[0]), path: path, query: query, headers: headers,
            body: Data(data[bodyStart..<(bodyStart + length)]))
        return .complete(request, consumed: bodyStart - data.startIndex + length)
    }

    /// 要求の対象をパスとクエリに分ける。
    static func split(target: String) -> (path: String, query: [String: String]) {
        guard let mark = target.firstIndex(of: "?") else { return (target, [:]) }
        var query: [String: String] = [:]
        for pair in target[target.index(after: mark)...].split(separator: "&") {
            let halves = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            let key = decode(String(halves[0]))
            query[key] = halves.count > 1 ? decode(String(halves[1])) : ""
        }
        return (String(target[..<mark]), query)
    }

    private static func decode(_ text: String) -> String {
        text.replacingOccurrences(of: "+", with: " ").removingPercentEncoding ?? text
    }
}
