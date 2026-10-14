// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation

/// URL の向こうの本文を受け取る。JSON (``SketchPart/loadJSONObject(_:)``) と XML
/// (``SketchPart/loadXML(_:)``) が、名前が `http://` か `https://` で始まるときに使う。
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
    ///
    /// 期限は受け口の側の音沙汰の無い間 (`URLRequest.timeoutInterval` = `limit`) だけで、呼んでからの
    /// 総時間は数えない — 待つ間も窓を塞がないので、同期版 (``fetchWaiting(_:path:limit:)``) の
    /// ような上限は要らない。切れたときは同期版と同じ失敗 (``overdue(path:limit:)``) で投げる。
    /// 待たない読み込みの失敗は同期版と同じ、という約束 (``SketchPart/requestJSONObject(_:)``) のため
    /// である (#2264)。
    ///
    /// - Parameter limit: 受け口の期限。製品の経路では ``waitLimit`` のまま (`URLRequest` の既定と
    ///   同じ 60 秒)。**検査だけが縮める。**
    static func fetch(_ url: URL, path: String, limit: Duration = waitLimit) async throws(DataFailure) -> Data {
        let data: Data
        let response: URLResponse
        var request = URLRequest(url: url)
        request.timeoutInterval = limit / .seconds(1)
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw failure(of: error, path: path, limit: limit)
        }
        return try accept(data, response, path: path)
    }

    /// 同期の受け取り (``fetchWaiting(_:path:limit:)``) が待つ上限。**呼んでから返るまでの
    /// 総時間で数える** (#2264)。
    ///
    /// ``SketchPart/loadJSONObject(_:)`` の説明が名乗る「最長 60 秒」はこの値で、変えるなら説明も
    /// 同じく直す。`URLRequest.timeoutInterval` だけでは上限にならない — あれは音沙汰の無い間の
    /// 期限で、データが届くたびに数え直すので、少しずつ返し続けるサーバには切れない。
    ///
    /// 待たない受け取り (``fetch(_:path:limit:)``) も同じ値を、音沙汰の無い間の期限にだけ使う。
    static let waitLimit: Duration = .seconds(60)

    /// 本文を受け取る。**受け取り終わるか、届かないと分かるか、`limit` が過ぎるまで返らない。**
    ///
    /// 同期の読み込み (``SketchPart/loadJSONObject(_:)``) のための道。受け取りは共有の受け口の側の
    /// 仕事で返ってくるので、呼んだ側 (main actor) を塞いで待っても詰まらない。
    ///
    /// 呼んでから `limit` までに受け取り終わらなければ、受け取りを取り消して
    /// ``DataFailure/unreachable(url:reason:)`` を投げる。少しずつ届き続けていても待ち続けない。
    ///
    /// - Parameter limit: 待つ上限。製品の経路では ``waitLimit`` のまま。**検査だけが縮める**
    ///   — 期限を越える応答を作る検査が、毎回 60 秒待たずに済むように (`RenderDevice` の
    ///   `signalWaitLimit` と同じ形)。
    static func fetchWaiting(_ url: URL, path: String, limit: Duration = waitLimit) throws(DataFailure) -> Data {
        // 受け取りの仕事と待つ側の間で結果を渡す箱。**書くのは受け取りの仕事が 1 度だけで、
        // 読むのは合図を待った後だけ** — 合図が前後を決めるので、錠は要らない。期限で諦めた
        // ときは読まない (取り消した受け取りも後から書くが、もう誰も見ない)
        final class Box: @unchecked Sendable {
            var outcome: Result<Data, DataFailure>
            init(_ outcome: Result<Data, DataFailure>) { self.outcome = outcome }
        }
        let box = Box(.failure(.unreachable(url: path, reason: "no response came back")))
        let arrived = DispatchSemaphore(value: 0)
        let seconds = limit / .seconds(1)
        // 受け口の側の期限 (音沙汰の無い間) も同じ値にする。そちらが切れたときも同じ失敗に畳む
        // (``failure(of:path:limit:)``) ので、何も返さないサーバで、どちらが先に切れても文面が揺れない
        var request = URLRequest(url: url)
        request.timeoutInterval = seconds
        let task = URLSession.shared.dataTask(with: request) { data, response, error in
            defer { arrived.signal() }
            if let error {
                box.outcome = .failure(failure(of: error, path: path, limit: limit))
                return
            }
            guard let response else { return }
            box.outcome = Result { () throws(DataFailure) in
                try accept(data ?? Data(), response, path: path)
            }
        }
        let deadline = DispatchTime.now() + seconds
        task.resume()
        guard arrived.wait(timeout: deadline) == .success else {
            task.cancel()
            throw overdue(path: path, limit: limit)
        }
        return try box.outcome.get()
    }

    /// 期限 `limit` の間に答えが完結しなかったときの失敗。
    ///
    /// 同期の待ちが期限で諦めたときと、受け口の時計が切れたとき (``failure(of:path:limit:)``) の
    /// 両方がこれを投げる。文面は「`limit` の間に答えが完結しなかった」とだけ名乗り、どちらの
    /// 時計が切れたか (呼んでからの総時間か、音沙汰の無い間か) は言わない — どちらが切れても
    /// 偽りにならない言い方である。
    static func overdue(path: String, limit: Duration) -> DataFailure {
        .unreachable(url: path, reason: "no complete answer came back within \(limit)")
    }

    /// 受け口が投げた誤りを、失敗にする。**受け口の時間切れ (`URLError.timedOut`) は
    /// ``overdue(path:limit:)`` に畳む。** 他の誤りは、受け口が名乗った事情をそのまま理由にする。
    ///
    /// 受け口の時計 (`URLRequest.timeoutInterval`、音沙汰の無い間) は `limit` に揃えてある。それが
    /// 切れたのなら、呼んでから `limit` 以上経って、答えはまだ完結していない。
    static func failure(of error: any Error, path: String, limit: Duration) -> DataFailure {
        guard (error as? URLError)?.code == .timedOut else {
            return .unreachable(url: path, reason: reason(of: error))
        }
        return overdue(path: path, limit: limit)
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
