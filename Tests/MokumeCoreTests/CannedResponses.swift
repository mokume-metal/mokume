// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation
import Synchronization

/// 検査の中で、URL の応答を差し替える (#2070)。**外のネットワークへ出ない。**
///
/// `URLProtocol` として登録し、予約済みの `.test` の名前 (RFC 6761) の要求だけを横取りする。
/// 本体は `URLSession.shared` で受け取り、共有の受け口は登録した `URLProtocol` を引くので、
/// 本体に差し替えの口は要らない。
///
/// 応答は URL ごとに 1 つ置き、URL は置くたびに別の名前にする — 並んで走る検査が互いの
/// 応答を踏まない。置いていない `.test` の URL には「名前が引けない」で答える (横取りし損ねて
/// 外へ問い合わせに行くことが無いように、`.test` は全部ここで止める)。
nonisolated final class CannedResponses: URLProtocol, @unchecked Sendable {
    /// 置いておく応答。
    enum Reply: Sendable {
        /// 状態と本文で答える。
        case answer(status: Int, body: Data)
        /// 繋がらなかったことにする。
        case fail(URLError.Code)
    }

    private static let replies = Mutex<[String: Reply]>([:])

    /// 登録は 1 度だけ。最初に応答を置いたときに行う。
    private static let installed: Bool = {
        URLProtocol.registerClass(CannedResponses.self)
        return true
    }()

    /// 応答を置き、その応答を返す URL を返す。
    static func serve(_ reply: Reply, file: String = "data") -> String {
        _ = installed
        let url = "https://canned-\(UUID().uuidString.lowercased()).test/\(file)"
        replies.withLock { $0[url] = reply }
        return url
    }

    /// 本文を 200 で返す URL。
    static func serve(_ body: String, status: Int = 200) -> String {
        serve(.answer(status: status, body: Data(body.utf8)))
    }

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host()?.hasSuffix(".test") == true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url else { return }
        let reply = Self.replies.withLock { $0[url.absoluteString] } ?? .fail(.cannotFindHost)
        switch reply {
        case .answer(let status, let body):
            let response = HTTPURLResponse(
                url: url, statusCode: status, httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/octet-stream"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: body)
            client?.urlProtocolDidFinishLoading(self)
        case .fail(let code):
            client?.urlProtocol(self, didFailWithError: URLError(code))
        }
    }

    override func stopLoading() {}
}
