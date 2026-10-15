// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation
import Synchronization
import Testing

@testable import MokumeCLI

/// 検査の中で、URL の応答を差し替える (#2407)。**外のネットワークへ出ない。**
///
/// `URLProtocol` として登録し、**この検査が表に置いた URL だけ**を横取りする。名前は予約済みの
/// `.example` (RFC 2606) で、置いていない URL は横取りしないので外へ問い合わせもしない。本体は
/// `URLSession.shared` で受け取り、共有の受け口は登録した `URLProtocol` を引くので、本体に
/// 差し替えの口は要らない。応答は URL ごとに 1 つ置き、URL は置くたびに別の名前にするので、
/// 並んで走る検査が互いの応答を踏まない。
///
/// **`MokumeCoreTests` の `CannedResponses` と同じ形だが、共有しない。** 検査の対象が別の
/// ターゲット (`MokumeCLITests`) で、Swift Package は検査のターゲットをまたいだ共有を持たない
/// ので、必要な 3 つの応答 (すぐ返る・少しずつ返し続ける・何も返さない) だけの写しを置く。
/// **登録した `URLProtocol` は、同じプロセスで走る検査全部の要求から引かれる** — 両方が
/// 「`.test` で終わるホストは全部引き受ける」と書くと、後に登録した側が相手の URL まで引き受け
/// (`cannotFindHost` で返し)、登録の順で相手の suite が赤くなる。そのため、名前を `.test` から
/// 外し、`canInit` を自分が置いた URL だけに絞って、相手の URL に触れないようにしてある。
nonisolated final class CannedHTTP: URLProtocol, @unchecked Sendable {
    enum Reply: Sendable {
        /// 状態と本文ですぐ答える。
        case answer(status: Int, body: Data)
        /// 200 の見出しを返した後、本文を `every` ごとに 1 バイトずつ返し、返し終えたら閉じる。
        /// **音沙汰の無い間は `every` より長くならない** — 受け口の時間切れ
        /// (`URLRequest.timeoutInterval`) は、データが届くたびに数え直すので切れない (#2264)。
        case trickle(body: Data, every: Duration)
        /// 繋がったまま、何も返さない。
        case silent
    }

    /// 応答の進み。URL ごとに持つ。
    private struct Progress {
        var reply: Reply?
        /// 刻んで返した本文のバイト数。
        var delivered = 0
        /// 刻んだ 1 バイトずつを返した時刻。
        var arrivals: [ContinuousClock.Instant] = []
        /// 検査が打ち切ったか (``cut(_:)``)。
        var cut = false
        /// 受け口がこの応答を止めたか。受け取りを取り消したときも、返し終えたときも止める。
        var stopped = false
        /// 受け口が要求に載せた期限 (`URLRequest.timeoutInterval`)。
        var timeout: TimeInterval?
    }

    private static let state = Mutex<[String: Progress]>([:])

    private static let installed: Bool = {
        URLProtocol.registerClass(CannedHTTP.self)
        return true
    }()

    static func serve(_ reply: Reply) -> URL {
        _ = installed
        let url = URL(string: "https://canned-\(UUID().uuidString.lowercased()).example/asset.md")!
        state.withLock { $0[url.absoluteString] = Progress(reply: reply) }
        return url
    }

    /// 遅い応答を打ち切る。**検査の側が自分の期限を越えたときの止め方** — 次の刻みで
    /// 「取り消した」で終わるので、期限で返らない実装でも、待っている受け取りが返る。
    static func cut(_ url: URL) {
        state.withLock { $0[url.absoluteString]?.cut = true }
    }

    static func delivered(_ url: URL) -> Int { state.withLock { $0[url.absoluteString]?.delivered ?? 0 } }
    static func arrivals(_ url: URL) -> [ContinuousClock.Instant] {
        state.withLock { $0[url.absoluteString]?.arrivals ?? [] }
    }
    static func stopped(_ url: URL) -> Bool { state.withLock { $0[url.absoluteString]?.stopped ?? false } }
    static func timeout(of url: URL) -> TimeInterval? { state.withLock { $0[url.absoluteString]?.timeout } }

    private var ticker: Timer?
    private var offset = 0

    /// 自分が表に置いた URL だけ引き受ける。同じプロセスの別の `URLProtocol` (`MokumeCoreTests` の
    /// `CannedResponses` など) の URL には触れない。
    override class func canInit(with request: URLRequest) -> Bool {
        guard let key = request.url?.absoluteString else { return false }
        return state.withLock { $0[key] != nil }
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url else { return }
        let key = url.absoluteString
        let timeout = request.timeoutInterval
        let reply = Self.state.withLock { table -> Reply? in
            table[key]?.timeout = timeout
            return table[key]?.reply
        }
        switch reply {
        case .answer(let status, let body):
            client?.urlProtocol(self, didReceive: Self.response(url, status), cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: body)
            client?.urlProtocolDidFinishLoading(self)
        case .trickle(let body, let every):
            client?.urlProtocol(self, didReceive: Self.response(url, 200), cacheStoragePolicy: .notAllowed)
            keepTicking(key: key, every: every) { this in
                guard this.offset < body.count else {
                    this.client?.urlProtocolDidFinishLoading(this)
                    return false
                }
                this.client?.urlProtocol(this, didLoad: Data(body.dropFirst(this.offset).prefix(1)))
                this.offset += 1
                let now = ContinuousClock.now
                Self.state.withLock {
                    $0[key]?.delivered += 1
                    $0[key]?.arrivals.append(now)
                }
                return true
            }
        case .silent:
            // 何も返さないが、打ち切りを見るために刻みだけは回す
            keepTicking(key: key, every: .milliseconds(20)) { _ in true }
        case nil:
            client?.urlProtocol(self, didFailWithError: URLError(.cannotFindHost))
        }
    }

    override func stopLoading() {
        ticker?.invalidate()
        guard let key = request.url?.absoluteString else { return }
        Self.state.withLock { $0[key]?.stopped = true }
    }

    private static func response(_ url: URL, _ status: Int) -> HTTPURLResponse {
        HTTPURLResponse(
            url: url, statusCode: status, httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/octet-stream"])!
    }

    /// `every` ごとに `step` を呼ぶ。`step` が `false` を返したら止める。検査が打ち切っていたら
    /// `step` を呼ばずに「取り消した」で終える。
    private func keepTicking(key: String, every: Duration, _ step: @escaping @Sendable (CannedHTTP) -> Bool) {
        let timer = Timer(timeInterval: every / .seconds(1), repeats: true) { [weak self] timer in
            guard let self else { return timer.invalidate() }
            if Self.state.withLock({ $0[key]?.cut == true }) {
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

/// 公開 API の一覧を取ってくる手 (`APIListLocator.download`) の期限 (#2407)。
///
/// 窓口は同期で答えるので、取ってくる間は MCP の応答ごと固まる。`fetchLimit` が約束する
/// 「10 秒で諦める」は、**呼んでから返るまでの総時間**で数えなければ守れない。
/// `URLRequest.timeoutInterval` は音沙汰の無い間の期限で、データが届くたびに数え直すので、
/// 少しずつ返し続ける応答には切れない。
@Suite("公開 API の一覧を取ってくる手の期限")
struct APIListDownloadTests {
    /// `download(_:limit:)` を、期限を `limit` に縮めて別の糸で走らせ、結果とかかった時間を返す。
    ///
    /// **待つ側 (この検査) も期限を持つ。** `limit` に 3 秒足した時間を越えたら応答を打ち切って
    /// (``CannedHTTP/cut(_:)``) `nil` を返す — 期限で返らない実装でも、検査は止まらずに赤になる。
    /// `.timeLimit` は使わない (main actor の上で検査全体の秒数を縛るため)。
    private func downloadOffMain(
        _ url: URL, limit: TimeInterval? = nil
    ) -> (outcome: Result<Data, Error>, called: ContinuousClock.Instant, took: Duration)? {
        // 受け取りの糸が書き、合図を待った後にだけ読む (打ち切ったときは読まない)
        nonisolated final class Box: @unchecked Sendable {
            var outcome: Result<Data, Error>?
            var called = ContinuousClock.now
            var took = Duration.zero
        }
        let box = Box()
        let returned = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            let clock = ContinuousClock()
            let start = clock.now
            box.called = start
            box.outcome = Result {
                if let limit { try APIListLocator.download(url, limit: limit) } else { try APIListLocator.download(url) }
            }
            box.took = clock.now - start
            returned.signal()
        }
        let patience = (limit ?? 0.5) + 3
        guard returned.wait(timeout: .now() + patience) == .success else {
            CannedHTTP.cut(url)
            _ = returned.wait(timeout: .now() + patience)
            return nil
        }
        return box.outcome.map { ($0, box.called, box.took) }
    }

    private func described(_ outcome: Result<Data, Error>) -> String? {
        if case .failure(let error) = outcome { String(describing: error) } else { nil }
    }

    @Test("少しずつ返し続ける応答でも、呼んでからの総時間が期限を越えたら取り消して、秒数を名乗る失敗を投げる")
    func tricklePastLimitFails() throws {
        // 20 ミリ秒ごとに 1 バイト。音沙汰の無い間は期限に届かないので、受け口の時間切れでは切れない。
        // **ただしそれは、呼んでから返るまで、期限以上の空白が 1 度も無かった回に限る** — 並列の
        // 負荷の下では、届き始めるまでに期限が過ぎる回がある (#2689)。その回は受け口の時間切れでも
        // 同じ文面で返り、総時間で切る実装かを見分けられないので、新しい応答でやり直す
        let limit: TimeInterval = 0.3
        for _ in 1...5 {
            let url = CannedHTTP.serve(.trickle(body: Data(repeating: 0x20, count: 100_000), every: .milliseconds(20)))
            let returned = try #require(
                downloadOffMain(url, limit: limit), "期限で返らず、検査の側の期限で打ち切った")
            let marks = [returned.called] + CannedHTTP.arrivals(url) + [returned.called + returned.took]
            let longestSilence = zip(marks, marks.dropFirst()).map { $1 - $0 }.max() ?? .zero
            guard longestSilence < .seconds(limit) else { continue }
            #expect(described(returned.outcome) == "no complete answer came back within 0.3 seconds")
            #expect(returned.took >= .seconds(limit))
            // 諦めた受け取りは取り消すので、受け口が応答を止める。止めるのは受け口の糸で少し遅れる
            let until = ContinuousClock.now + .seconds(2)
            while !CannedHTTP.stopped(url), ContinuousClock.now < until { Thread.sleep(forTimeInterval: 0.01) }
            #expect(CannedHTTP.stopped(url), "期限を越えた受け取りを取り消していない")
            return
        }
        try Test.cancel("5 回とも、期限 0.3 秒以上の空白を挟まずに本文を返し続けられなかった (前提の不成立)")
    }

    @Test("何も返さない応答も、期限で返って同じ失敗を投げる")
    func silencePastLimitFails() throws {
        let url = CannedHTTP.serve(.silent)
        let returned = try #require(
            downloadOffMain(url, limit: 0.3), "期限で返らず、検査の側の期限で打ち切った")
        #expect(described(returned.outcome) == "no complete answer came back within 0.3 seconds")
        #expect(returned.took >= .milliseconds(300))
    }

    @Test("受け口の時間切れは、期限の間に答えが完結しなかった失敗に畳む。他の誤りは受け口の事情のまま")
    func sessionTimeoutFoldsIntoTheSameFailure() {
        // 受け口の時計と待つ側の期限は同じ値で競るので、どちらが先に切れても文面が揺れない
        let overdue = String(describing: APIListLocator.overdue(limit: 10))
        #expect(overdue == "no complete answer came back within 10 seconds")
        #expect(String(describing: APIListLocator.failure(of: URLError(.timedOut), limit: 10)) == overdue)
        let timedOut = NSError(domain: NSURLErrorDomain, code: NSURLErrorTimedOut)
        #expect(String(describing: APIListLocator.failure(of: timedOut, limit: 10)) == overdue)
        let refused = URLError(.cannotConnectToHost)
        #expect((APIListLocator.failure(of: refused, limit: 10) as? URLError)?.code == .cannotConnectToHost)
    }

    @Test("有限でない・桁外れの期限でも、失敗の文面を組むところで落ちない")
    func overdueNeverTrapsOnOddLimits() {
        // `Int(limit)` は無限大・非数・Int に収まらない値で落ちる。期限として渡る値ではないが、落ちる口を残さない
        #expect(String(describing: APIListLocator.overdue(limit: .infinity)) == "no complete answer came back within inf seconds")
        #expect(String(describing: APIListLocator.overdue(limit: .nan)) == "no complete answer came back within nan seconds")
        #expect(String(describing: APIListLocator.overdue(limit: 1e30)).hasPrefix("no complete answer came back within "))
        #expect(String(describing: APIListLocator.overdue(limit: 0.3)) == "no complete answer came back within 0.3 seconds")
    }

    @Test("受け口の期限は待つ期限と同じ値で、既定では fetchLimit (10 秒) 1 か所から来る")
    func theTwoLimitsAreOneValue() throws {
        #expect(APIListLocator.fetchLimit == 10)
        // 縮めた期限は、要求の期限にもそのまま載る。すぐ返るので待たないが、期限の内に受け口へ
        // 要求が届かないと見られないので、負荷の下でも収まる長さにしておく (#2689)
        let shrunk = CannedHTTP.serve(.answer(status: 200, body: Data("x".utf8)))
        _ = try #require(downloadOffMain(shrunk, limit: 5))
        #expect(CannedHTTP.timeout(of: shrunk) == 5)
        // 既定は fetchLimit。待たずに済むよう、すぐ返る応答で見る
        let standard = CannedHTTP.serve(.answer(status: 200, body: Data("x".utf8)))
        _ = try #require(downloadOffMain(standard))
        #expect(CannedHTTP.timeout(of: standard) == APIListLocator.fetchLimit)
    }

    @Test("期限より早く返る応答は、少しずつ届いても読める")
    func trickleWithinLimitIsRead() throws {
        let body = Data("# public api\n".utf8)
        let url = CannedHTTP.serve(.trickle(body: body, every: .milliseconds(10)))
        let returned = try #require(downloadOffMain(url, limit: 5), "期限で返らず、検査の側の期限で打ち切った")
        #expect(try returned.outcome.get() == body)
        #expect(CannedHTTP.delivered(url) == body.count)
    }

    @Test("すぐ返る 200 は本文を返し、200 でない状態は状態の数を添えて断る (これまでどおり)")
    func statusIsStillChecked() throws {
        let body = Data("# public api\n".utf8)
        let ok = CannedHTTP.serve(.answer(status: 200, body: body))
        #expect(try #require(downloadOffMain(ok)).outcome.get() == body)

        let missing = CannedHTTP.serve(.answer(status: 404, body: Data("Not Found".utf8)))
        let refused = try #require(downloadOffMain(missing))
        #expect(described(refused.outcome) == "the response was 404")
    }
}
