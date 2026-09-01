// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation

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
            case .cached(let url): "取り置き (\(url.path))"
            case .downloaded(let url, let remote): "取ってきて取り置いた (\(remote) → \(url.path))"
            }
        }
    }

    /// 得られなかったとき。**次の一手を持つ** — 窓口の失敗は、そこで手が止まらない形にする。
    struct Missing: Error {
        let advice: String
    }

    /// 取り置きの区画。`.mokume/` は ADR-0018 決定 2 の共通の屋根で、ひな形の `.gitignore` が
    /// 既に外している。
    var facet: URL { directory.appendingPathComponent(".mokume/reference", isDirectory: true) }

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
                        依存している版が引けません。`Package.resolved` に `\(Self.identity)` の
                        pin がないためです (開発中の本体をパスで指しているときはこうなります)。
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
                        この版の資産を取ってこられませんでした (\(remote)): \(error)
                        ネットワークが無いときのほか、**その版に資産が付いていない**ときにも起きます
                        (一覧を配り始めたのは v0.1.0 より後)。
                        """, cache: cache))
        }
        guard let text = String(data: data, encoding: .utf8), !text.isEmpty else {
            throw Missing(
                advice: advice(reason: "取ってきたものが読めませんでした (\(remote))", cache: cache))
        }
        // 取り置けなくても、いま得たものは返す。**答えを返すほうが先** (ADR-0018 決定 3)
        try? AtomicWrite.write(data, to: cache)
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
        公開 API の一覧が手元にありません。

        \(reason)

        mokume のリポジトリで組み立てて置けば、次からはそれが返ります:

          make api-list OUT="\(cache.path)"
        """
    }

    /// 既定の取り方。
    ///
    /// **状態を見る。** 見ないと、資産の無い版で返る 404 の本文をそのまま一覧として
    /// 取り置いてしまう。
    nonisolated static func download(_ url: URL) throws -> Data {
        final class Box: @unchecked Sendable {
            var outcome: Result<Data, Error> = .failure(FetchFailure("応答がありませんでした"))
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = fetchLimit
        let box = Box()
        let semaphore = DispatchSemaphore(value: 0)
        URLSession.shared.dataTask(with: request) { data, response, error in
            defer { semaphore.signal() }
            if let error {
                box.outcome = .failure(error)
                return
            }
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard status == 200 else {
                box.outcome = .failure(FetchFailure("応答が \(status) でした"))
                return
            }
            box.outcome = .success(data ?? Data())
        }.resume()
        // 上限は要求に載せてある。待ち自体には上限を置かない (二重に持つと食い違う)
        semaphore.wait()
        return try box.outcome.get()
    }

    nonisolated struct FetchFailure: Error, CustomStringConvertible {
        let description: String
        init(_ description: String) { self.description = description }
    }
}
