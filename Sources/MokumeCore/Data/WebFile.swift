// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation

/// URL の向こうの本文を受け取る。JSON (``Sketch/loadJSONObject(_:)``) と XML
/// (``Sketch/loadXML(_:)``) が、名前が `http://` か `https://` で始まるときに使う。
///
/// **受け取るのは `URLSession.shared` で、差し替えの口を持たない。** 検査は検査の側で
/// `URLProtocol` を登録し、予約済みの名前 (`.test`) だけを横取りして応答を返す。本体に
/// 差し替えの口を作ると、検査のためだけの道が面か内部に残る。共有の受け口は登録した
/// `URLProtocol` を引くので、それで足りる (#2070)。
///
/// **2xx 以外の状態は、届かなかったものとして投げる** (``DataFailure/unreachable(url:reason:)``)。
/// 404 の本文 (多くは HTML の案内) を JSON として読むと、「壊れた JSON」という的外れな
/// 理由で落ちる。
///
/// 隔離の外で走れる形にしてあるのは、待たない読み込みが受け取りを別の仕事として待つため
/// ([ADR-0010] 決定 6)。
///
/// [ADR-0010]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0010-concurrency-model.md
nonisolated enum WebFile {
    /// 名前が URL なら、その URL。URL でなければ `nil` (呼ぶ側がファイルとして探す)。
    ///
    /// URL と読むのは `http://` か `https://` で始まる名前だけ (大文字と小文字は問わない)。
    /// それ以外の綴り (`file://` を含む) はファイルの名前として探す。
    static func url(_ path: String) throws(DataFailure) -> URL? {
        let lowered = path.lowercased()
        guard lowered.hasPrefix("http://") || lowered.hasPrefix("https://") else { return nil }
        guard let url = URL(string: path), let host = url.host(), !host.isEmpty else {
            throw .unreachable(url: path, reason: "this is not a URL that can be requested")
        }
        return url
    }

    /// 本文を受け取る。**受け取るまで、他の仕事を止めない。**
    static func fetch(_ url: URL, path: String) async throws(DataFailure) -> Data {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: URLRequest(url: url))
        } catch {
            throw .unreachable(url: path, reason: reason(of: error))
        }
        return try accept(data, response, path: path)
    }

    /// 本文を受け取る。**受け取るまで (届かないと分かるまで) 返らない。**
    ///
    /// 同期の読み込み (``Sketch/loadJSONObject(_:)``) のための道で、待つ上限は `URLRequest` の
    /// 既定 (60 秒)。受け取りは共有の受け口の側の仕事で返ってくるので、呼んだ側 (main actor)
    /// を塞いで待っても詰まらない。
    static func fetchWaiting(_ url: URL, path: String) throws(DataFailure) -> Data {
        // 受け取りの仕事と待つ側の間で結果を渡す箱。**書くのは受け取りの仕事が 1 度だけで、
        // 読むのは合図を待った後だけ** — 合図が前後を決めるので、錠は要らない
        final class Box: @unchecked Sendable {
            var outcome: Result<Data, DataFailure>
            init(_ outcome: Result<Data, DataFailure>) { self.outcome = outcome }
        }
        let box = Box(.failure(.unreachable(url: path, reason: "no response came back")))
        let arrived = DispatchSemaphore(value: 0)
        URLSession.shared.dataTask(with: URLRequest(url: url)) { data, response, error in
            defer { arrived.signal() }
            if let error {
                box.outcome = .failure(.unreachable(url: path, reason: reason(of: error)))
                return
            }
            guard let response else { return }
            box.outcome = Result { () throws(DataFailure) in
                try accept(data ?? Data(), response, path: path)
            }
        }.resume()
        arrived.wait()
        return try box.outcome.get()
    }

    /// 受け取った応答を確かめて、本文を返す。2xx 以外の状態なら投げる。
    private static func accept(_ data: Data, _ response: URLResponse, path: String) throws(DataFailure) -> Data {
        guard let http = response as? HTTPURLResponse else { return data }
        guard (200..<300).contains(http.statusCode) else {
            let phrase = HTTPURLResponse.localizedString(forStatusCode: http.statusCode)
            throw .unreachable(url: path, reason: "the server answered \(http.statusCode) (\(phrase))")
        }
        return data
    }

    /// 受け取れなかった事情を、人が読む 1 文にする。
    private static func reason(of error: any Error) -> String {
        (error as NSError).localizedDescription
    }
}
