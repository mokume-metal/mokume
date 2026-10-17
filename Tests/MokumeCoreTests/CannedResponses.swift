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
        /// 200 の見出しを返した後、本文を `every` ごとに 1 バイトずつ返し、返し終えたら閉じる。
        /// **音沙汰の無い間は `every` より長くならない** — 受け口の時間切れ
        /// (`URLRequest.timeoutInterval`) は、データが届くたびに数え直すので切れない (#2264)。
        case trickle(body: Data, every: Duration)
        /// 繋がったまま、何も返さない。
        case silent
    }

    private static let replies = Mutex<[String: Reply]>([:])

    /// 応答の進み。URL ごとに持つ。
    private struct Progress {
        /// 刻んで返す応答 (``Reply/trickle(body:every:)``) が、これまでに返した本文のバイト数。
        var delivered = 0
        /// 刻んだ 1 バイトずつを返した時刻。
        var arrivals: [ContinuousClock.Instant] = []
        /// 検査が打ち切ったか (``cut(_:)``)。
        var cut = false
        /// 受け口がこの応答を止めたか (``stopLoading()``)。受け取りを取り消したときも、
        /// 返し終えたときも止める。
        var stopped = false
    }

    private static let progress = Mutex<[String: Progress]>([:])

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

    /// 遅い応答を打ち切る。**検査の側が自分の期限を越えたときの止め方** — 次の刻みで「取り消した」
    /// (`URLError.cancelled`) で終わるので、期限で返らない実装でも、待っている受け取りが返る。
    static func cut(_ url: String) {
        progress.withLock { $0[url, default: Progress()].cut = true }
    }

    /// 刻んで返す応答が、これまでに返した本文のバイト数。
    static func delivered(_ url: String) -> Int {
        progress.withLock { $0[url]?.delivered ?? 0 }
    }

    /// 刻んで返す応答が、1 バイトずつを返した時刻。
    static func arrivals(_ url: String) -> [ContinuousClock.Instant] {
        progress.withLock { $0[url]?.arrivals ?? [] }
    }

    /// 受け口がその URL の応答を止めたか。止めるのは受け口の側の糸で、取り消しから少し遅れる。
    static func stopped(_ url: String) -> Bool {
        progress.withLock { $0[url]?.stopped ?? false }
    }

    /// 遅い応答を刻む時計。`startLoading()` を呼んだ糸の run loop に置く — `client` へは
    /// その糸から伝え、``stopLoading()`` (同じ糸で呼ばれる) が止める。
    private var ticker: Timer?

    /// 刻んで返す応答が、本文のどこまで返したか。刻みは同じ糸で進むので、錠は要らない。
    private var offset = 0

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host()?.hasSuffix(".test") == true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url else { return }
        let reply = Self.replies.withLock { $0[url.absoluteString] } ?? .fail(.cannotFindHost)
        switch reply {
        case .answer(let status, let body):
            client?.urlProtocol(self, didReceive: Self.response(url, status), cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: body)
            client?.urlProtocolDidFinishLoading(self)
        case .fail(let code):
            client?.urlProtocol(self, didFailWithError: URLError(code))
        case .trickle(let body, let every):
            client?.urlProtocol(self, didReceive: Self.response(url, 200), cacheStoragePolicy: .notAllowed)
            keepTicking(every: every) { this in
                guard this.offset < body.count else {
                    this.client?.urlProtocolDidFinishLoading(this)
                    return false
                }
                this.client?.urlProtocol(this, didLoad: Data(body.dropFirst(this.offset).prefix(1)))
                this.offset += 1
                let now = ContinuousClock.now
                Self.progress.withLock {
                    $0[url.absoluteString, default: Progress()].delivered += 1
                    $0[url.absoluteString, default: Progress()].arrivals.append(now)
                }
                return true
            }
        case .silent:
            // 何も返さないが、打ち切りを見るために刻みだけは回す
            keepTicking(every: .milliseconds(20)) { _ in true }
        }
    }

    override func stopLoading() {
        ticker?.invalidate()
        guard let url = request.url?.absoluteString else { return }
        Self.progress.withLock { $0[url, default: Progress()].stopped = true }
    }

    private static func response(_ url: URL, _ status: Int) -> HTTPURLResponse {
        HTTPURLResponse(
            url: url, statusCode: status, httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/octet-stream"])!
    }

    /// `every` ごとに `step` を呼ぶ。`step` が `false` を返したら止める。検査が打ち切っていたら
    /// (``cut(_:)``)、`step` を呼ばずに「取り消した」で終える。
    private func keepTicking(every: Duration, _ step: @escaping @Sendable (CannedResponses) -> Bool) {
        let key = request.url?.absoluteString ?? ""
        let timer = Timer(timeInterval: every / .seconds(1), repeats: true) { [weak self] timer in
            guard let self else { return timer.invalidate() }
            if Self.progress.withLock({ $0[key]?.cut == true }) {
                timer.invalidate()
                self.client?.urlProtocol(self, didFailWithError: URLError(.cancelled))
            } else if !step(self) {
                timer.invalidate()
            }
        }
        RunLoop.current.add(timer, forMode: .common)
        ticker = timer
    }
}
