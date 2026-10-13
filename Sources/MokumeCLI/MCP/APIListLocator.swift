// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation
import mokume

/// 公開 API の一覧の在処。
///
/// **窓口では組み立てない。** 組み立てるのは `make api-list` の仕事で、その結果は版ごとに
/// Release の資産として配られる (一覧はリポジトリへ置かない — ADR-0001 原則 8)。ここがするのは
/// 取り置きを先に見て、無ければ**依存として解決された版**のものを取ってきて取り置くことだけ。
/// 組み立てを窓口の中で起こすと、1 回の呼び出しが数分のビルドになる。
///
/// 取り置きが要るのは、**窓口が毎回ネットワークに依存しないため**である。手元にあるものを
/// 読める限り、飛行機の中でもスケッチは書ける。
struct APIListLocator {
    /// 資産の置き場。
    static let releases = "https://github.com/mokume-metal/mokume/releases/download"
    /// 依存の識別子。**完全一致で選ぶ** — 前方一致にすると、別の依存 (`mokume-*`) が先に
    /// 並んでいるときに取り違える。綴りの正典は [DependencyVersion]。
    static let identity = DependencyVersion.identity
    /// 取ってくるのを諦めるまで。窓口は同期で答えるので、上限が無いと応答ごと固まる。
    /// **呼んでから返るまでの総時間**の上限で、少しずつ返し続ける応答でも越えたら取り消す
    /// (``download(_:limit:)``・#2407)。
    nonisolated static let fetchLimit: TimeInterval = 10

    /// 作業ディレクトリ (`Facets` と同じ基準)。
    let directory: URL
    /// 取ってくる手。検査から差し替える。
    var fetch: (URL) throws -> Data = { try APIListLocator.download($0) }

    /// どこから得たか。**応答に載せる** — 取り置きを読んでいるのか、いま取ってきたのかが
    /// 分からないと、古いものを新しいと信じる余地が残る。
    enum Source {
        case cached(URL)
        case downloaded(URL, from: URL)

        var text: String {
            switch self {
            case .cached(let url): "cached (\(url.path))"
            case .downloaded(let url, let remote): "fetched and cached (\(remote) → \(url.path))"
            }
        }
    }

    /// 得られなかったとき。**次の一手を持つ** — 窓口の失敗は、そこで手が止まらない形にする。
    struct Missing: Error {
        let advice: String
    }

    /// 取り置きの区画。`.mokume/` は ADR-0018 決定 2 の共通の屋根で、ひな形の `.gitignore` が
    /// 既に外している。
    ///
    /// **屋根の綴りは持たない。** 共通の屋根である以上、綴りの正典は ``WorkDirectory`` 1 つで
    /// ある — 手打ちすると、屋根を動かした日にここだけが取り残される (#814)。
    var facet: URL { WorkDirectory.facet(Self.facetName, under: directory) }

    /// 取り置きの区画の名前。
    static let facetName = "reference"

    /// 一覧を読む。
    func read() throws -> (text: String, source: Source) {
        let version = resolvedVersion()
        let cache = cacheURL(for: version)
        if let text = try? String(contentsOf: cache, encoding: .utf8), !text.isEmpty {
            return (text, .cached(cache))
        }
        guard let version else {
            throw Missing(
                advice: advice(
                    reason: """
                        Cannot tell which version is depended on: `Package.resolved` has no pin
                        for `\(Self.identity)` (this happens when you point at mokume by path
                        while developing it).
                        """, cache: cache))
        }

        let remote = Self.assetURL(version: version)
        let data: Data
        do {
            data = try fetch(remote)
        } catch {
            throw Missing(
                advice: advice(
                    reason: """
                        Could not fetch the asset for this version (\(remote)): \(error)
                        Besides having no network, this also happens when **that version has no
                        such asset attached** (the list started shipping after v0.1.0).
                        """, cache: cache))
        }
        guard let text = String(data: data, encoding: .utf8), !text.isEmpty else {
            throw Missing(
                advice: advice(reason: "what came back could not be read (\(remote))", cache: cache))
        }
        // 取り置けなくても、いま得たものは返す。**答えを返すほうが先** (ADR-0018 決定 3)
        try? AtomicFile.write(data, to: cache)
        return (text, .downloaded(cache, from: remote))
    }

    /// 依存として解決された版。パスで指しているときは pin が無いので `nil`。
    ///
    /// **読み方は [DependencyVersion] が持つ。** 切り分けの口も同じものを読むので、
    /// 実装は 1 つにする。
    func resolvedVersion() -> String? { DependencyVersion.resolved(forPackageAt: directory) }

    /// 取り置きの置き場。版が引けないときは**手で置くための枠**を指す。
    func cacheURL(for version: String?) -> URL {
        let name = version.map { "mokume-api-v\($0).md" } ?? "mokume-api.md"
        return facet.appendingPathComponent(name)
    }

    /// 資産の在処。タグは版に `v` を付けたもの。
    static func assetURL(version: String) -> URL {
        URL(string: "\(releases)/v\(version)/mokume-api-v\(version).md")!
    }

    /// 得られなかった理由と、そこからの一手。
    private func advice(reason: String, cache: URL) -> String {
        """
        The public API list is not available here.

        \(reason)

        Build it in the mokume repository and put it here, and it is returned from then on:

          make api-list OUT="\(cache.path)"
        """
    }

    /// 既定の取り方。
    ///
    /// **状態を見る。** 見ないと、資産の無い版で返る 404 の本文をそのまま一覧として
    /// 取り置いてしまう。
    ///
    /// **期限は呼んでから返るまでの総時間で数える** (#2407)。窓口は同期で答えるので、取ってくる
    /// 間は MCP の応答ごと固まる。`URLRequest.timeoutInterval` は音沙汰の無い間の期限で、データが
    /// 届くたびに数え直すので、少しずつ返し続ける応答には切れない。だから待つ側も `limit` で
    /// 諦め、取り消して失敗を投げる。要求の期限も同じ値にする — 何も返さない応答でどちらが先に
    /// 切れても、同じ失敗 (``failure(of:limit:)``) になる。
    ///
    /// - Parameter limit: 取ってくるのを諦めるまで。製品の経路では ``fetchLimit`` のまま。
    ///   **検査だけが縮める** — 期限を越える応答を作る検査が、毎回 10 秒待たずに済むように。
    nonisolated static func download(_ url: URL, limit: TimeInterval = fetchLimit) throws -> Data {
        // 受け取りの仕事と待つ側の間で結果を渡す箱。**書くのは受け取りの仕事が 1 度だけで、
        // 読むのは合図を待った後だけ** — 合図が前後を決めるので、錠は要らない。期限で諦めた
        // ときは読まない (取り消した受け取りも後から書くが、もう誰も見ない)
        final class Box: @unchecked Sendable {
            var outcome: Result<Data, Error> = .failure(FetchFailure("no response came back"))
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = limit
        let box = Box()
        let semaphore = DispatchSemaphore(value: 0)
        let task = URLSession.shared.dataTask(with: request) { data, response, error in
            defer { semaphore.signal() }
            if let error {
                box.outcome = .failure(failure(of: error, limit: limit))
                return
            }
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard status == 200 else {
                box.outcome = .failure(FetchFailure("the response was \(status)"))
                return
            }
            box.outcome = .success(data ?? Data())
        }
        let deadline = DispatchTime.now() + limit
        task.resume()
        guard semaphore.wait(timeout: deadline) == .success else {
            task.cancel()
            throw overdue(limit: limit)
        }
        return try box.outcome.get()
    }

    /// 期限 `limit` の間に答えが完結しなかったときの失敗。
    ///
    /// 待つ側が期限で諦めたときと、受け口の時計が切れたとき (``failure(of:limit:)``) の両方が
    /// これを投げる。文面は「`limit` の間に答えが完結しなかった」とだけ名乗り、どちらの時計が
    /// 切れたか (呼んでからの総時間か、音沙汰の無い間か) は言わない — どちらが切れても
    /// 偽りにならない言い方である。
    nonisolated static func overdue(limit: TimeInterval) -> FetchFailure {
        let seconds = limit == limit.rounded() ? "\(Int(limit))" : "\(limit)"
        return FetchFailure("no complete answer came back within \(seconds) seconds")
    }

    /// 受け口が投げた誤りを、失敗にする。**受け口の時間切れ (`URLError.timedOut`) は
    /// ``overdue(limit:)`` に畳む。** 他の誤りは、受け口が名乗った事情をそのまま渡す。
    ///
    /// 受け口の時計 (`URLRequest.timeoutInterval`、音沙汰の無い間) は `limit` に揃えてある。
    /// 切れたのなら、呼んでから `limit` 以上経って、答えはまだ完結していない。
    nonisolated static func failure(of error: any Error, limit: TimeInterval) -> any Error {
        guard (error as? URLError)?.code == .timedOut else { return error }
        return overdue(limit: limit)
    }

    nonisolated struct FetchFailure: Error, CustomStringConvertible {
        let description: String
        init(_ description: String) { self.description = description }
    }
}
