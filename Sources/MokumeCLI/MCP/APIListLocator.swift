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
///
/// **取り置きの名前は、依存の同一性に追随する** (``cacheURL(for:)``)。版は `mokume-api-v<版>.md`、
/// 枝・改訂は `mokume-api-rev-<改訂の先頭 12 字>.md` で、依存を上げれば別の名前になり、古い一覧は
/// 返らない。**追随できない (鍵が無い) 状態だけ共通名 `mokume-api.md`** を読み、そこから返す回は
/// 答えが鍵の無いことを名乗る (``Source/cached(_:keyed:)``・#3478)。
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
        /// 取り置きから。`keyed` は、その名前に依存の版・改訂が入っているか。**入っていない (共通名) 一覧は、
        /// 何から組んだものか分からない**ので、答えがそう名乗る (#3478)。
        case cached(URL, keyed: Bool)
        case downloaded(URL, from: URL)

        var text: String {
            switch self {
            case .cached(let url, let keyed):
                // 頭の `cached (…)` は変えない (検査も読み手も頭で見ている)
                keyed
                    ? "cached (\(url.path))"
                    : """
                    cached (\(url.path)) — a list put here by hand, tied to no version or revision, \
                    so it may differ from the dependency in use
                    """
            case .downloaded(let url, let remote): "fetched and cached (\(remote) → \(url.path))"
            }
        }
    }

    /// 得られなかったとき。**次の一手を持つ** — 窓口の失敗は、そこで手が止まらない形にする。
    struct Missing: Error {
        let advice: String
        /// 得られなかった理由の種類。**答えに添える手を分けるために持つ** — 版が引けないのは
        /// 窓口がスケッチでない場所で立ったせいでもありうるが、取りに行けない・読めないのは
        /// 場所のせいではない (#2487)。
        var cause: Cause

        enum Cause: Equatable {
            /// 依存の版が引けない (`Package.resolved` に pin が無い)
            case versionUnknown
            /// 資産を取ってこられなかった
            case fetchFailed
            /// 取ってきたものが読めなかった
            case unreadable
        }
    }

    /// 取り置きの区画。`.mokume/` は ADR-0018 決定 2 の共通の屋根で、ひな形の `.gitignore` が
    /// 既に外している。
    ///
    /// **屋根の綴りは持たない。** 共通の屋根である以上、綴りの正典は ``WorkDirectory`` 1 つで
    /// ある — 手打ちすると、屋根を動かした日にここだけが取り残される (#814)。
    var facet: URL { WorkDirectory.facet(Self.facetName, under: directory) }

    /// 取り置きの区画の名前。
    static let facetName = "reference"

    /// 依存の版の状態。**読み方は [DependencyVersion] が持つ** (`doctor` と写しを作らない)。
    func versionState() -> DependencyVersion.State { DependencyVersion.state(forPackageAt: directory) }

    /// 一覧を読む。
    func read() throws -> (text: String, source: Source) {
        let state = versionState()
        let version: String? = if case .version(let found) = state { found } else { nil }
        let cache = cacheURL(for: state)
        if let text = try? String(contentsOf: cache, encoding: .utf8), !text.isEmpty {
            return (text, .cached(cache, keyed: Self.isKeyed(state)))
        }
        // **版の形でなければ取りに行かない** (``DependencyVersion/isVersion(_:)``)。URL を作れない版も同じ
        guard let version, let remote = Self.assetURL(version: version) else {
            throw Missing(advice: unknownVersionAdvice(state, cache: cache), cause: .versionUnknown)
        }
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
                        """, cache: cache),
                cause: .fetchFailed)
        }
        guard let text = String(data: data, encoding: .utf8), !text.isEmpty else {
            throw Missing(
                advice: advice(reason: "what came back could not be read (\(remote))", cache: cache),
                cause: .unreadable)
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

    /// 取り置きの置き場。**名前は依存の同一性から作る** — 版は `mokume-api-v<版>.md`、枝・改訂は
    /// `mokume-api-rev-<先頭 12 字>.md` (12 字の計算は ``BuildDirectory/revisionSegment(_:)`` のもの)。
    /// 鍵にできるものが無い状態 (パスで指す・未解決・読めない・`Package.swift` が無い) は、
    /// **手で置くための枠**の共通名 `mokume-api.md` を指す。
    ///
    /// **読む側 (``read()``) も案内の `OUT=` も、この 1 つの計算を通る。** 改訂の名前が無いときに共通名へ
    /// 落ちて読むと、前の改訂の一覧を今のものとして返す (#3478)。
    func cacheURL(for state: DependencyVersion.State) -> URL {
        facet.appendingPathComponent(Self.keyedName(for: state) ?? Self.sharedName)
    }

    /// 鍵の無い取り置きの共通名 (手で置くための枠)。
    static let sharedName = "mokume-api.md"

    /// 取り置きの名前に、依存の版・改訂が入るか。
    static func isKeyed(_ state: DependencyVersion.State) -> Bool { keyedName(for: state) != nil }

    /// 版・改訂が入る取り置きの名前。**名前の 1 段にしてよい形でなければ `nil`** (``DependencyVersion/isVersion(_:)``・
    /// ``DependencyVersion/isRevision(_:)``) — 状態を作る側が検めているが、名前を作るここでも同じ判定を通す (#3535)。
    /// ``cacheURL(for:)`` と ``isKeyed(_:)`` はこれ 1 つから決まるので、名前と「鍵が入るか」は食い違わない。
    private static func keyedName(for state: DependencyVersion.State) -> String? {
        switch state {
        case .version(let version) where DependencyVersion.isVersion(version):
            "mokume-api-v\(version).md"
        case .revision(let revision) where DependencyVersion.isRevision(revision):
            "mokume-api-\(BuildDirectory.revisionSegment(revision)).md"
        case .version, .revision, .unresolved, .notPinned, .unreadable, .malformed, .noPackage: nil
        }
    }

    /// 資産の在処。タグは版に `v` を付けたもの。**版の形でなければ (URL を作れなければ) `nil`** — 取りに行かない。
    static func assetURL(version: String) -> URL? {
        guard DependencyVersion.isVersion(version) else { return nil }
        return URL(string: "\(releases)/v\(version)/mokume-api-v\(version).md")
    }

    /// 版が引けなかった理由ごとの答え (#3419)。**`Cannot tell which version is depended on` の
    /// 段落は理由が違っても同じ文**で、続きがその理由に合う一手になる (その前の 1 行目は、
    /// 解決するだけで直る `.unresolved` だけ `not available yet.`)。本体の開発の手順
    /// (`make api-list`) を先に出すのは、本体の開発を示す事実がある回だけ。確かめられない回は、
    /// 条件をつけて両方を示す。
    ///
    /// **依存を解決する手は、道具の既定と同じ置き場を使うものだけを勧める。** 裸の
    /// `swift package resolve` は `--scratch-path` を渡さないので、スケッチ直下に約 200MB の
    /// `.build/` を作る。`run` / `watch` は解決を共有の置き場 (`BuildDirectory.resolveSegment`) へ
    /// 固定しているので、`Package.resolved` だけがスケッチ直下にでき、`.build/` は作られない。
    private func unknownVersionAdvice(_ state: DependencyVersion.State, cache: URL) -> String {
        let head = "Cannot tell which version is depended on"
        // 案内のコマンドは `GivenPath.shellWord` で包む。二重引用は `$` と `` ` `` を解く
        let run = "\(Command.name) run \(GivenPath.shellWord(directory))"
        let makeList = Self.buildCommand(cache: cache)
        switch state {
        case .unresolved:
            return """
                The public API list is not available yet.

                \(head): this sketch has not resolved its dependencies yet
                (there is no `Package.resolved`), which is normal right after
                `\(Command.name) new`. Build it once — `\(Command.name) run` and `\(Command.name) watch`
                resolve the dependencies as part of building, in the shared build directory
                (not under the sketch) — then ask again; the list for the resolved version
                is fetched and kept:

                  \(run)

                If the sketch points at mokume by path (while developing mokume), there is no version
                to resolve. Build the list in the mokume repository and put it here instead:

                  \(makeList)
                """
        case .notPinned:
            return """
                The public API list is not available here.

                \(head): `Package.resolved` has no pin for `\(Self.identity)`.
                That is how it looks when the sketch points at mokume by path (while developing
                mokume): build the list in the mokume repository and put it here, and it is
                returned from then on:

                  \(makeList)

                If the dependency on mokume was added or changed recently, build the sketch
                again (it resolves the dependencies) and ask again:

                  \(run)
                """
        case .unreadable:
            return """
                The public API list is not available here.

                \(head): `Package.resolved` is there but could not be read
                (damaged, or in a form this tool does not know), so whether it pins
                `\(Self.identity)` is unknown. If it is damaged, remove it, build the sketch
                (it writes the file again) and ask again:

                  \(run)

                If the sketch points at mokume by path (while developing mokume), build the list
                in the mokume repository and put it here instead:

                  \(makeList)
                """
        case .revision(let revision):
            let segment = BuildDirectory.revisionSegment(revision)
            // 共通名に一覧が在っても、改訂の鍵を持たないので読まない。**読まないことを、答えが名乗る** (#3478)
            let shared = facet.appendingPathComponent(Self.sharedName)
            let sharedNote =
                if let text = try? String(contentsOf: shared, encoding: .utf8), !text.isEmpty {
                    """


                    A list is kept under the shared name (\(shared.path)), but that name carries no
                    revision, so it is not read for a pinned revision. Put the list for this revision
                    under the name above instead.
                    """
                } else { "" }
            return """
                The public API list is not available here.

                \(head): `\(Self.identity)` is pinned to a branch or revision
                (\(segment)), not to a release, and the list is published per release.
                Depend on a release version and build the sketch again, or build the list from the
                revision in use in the mokume repository and put it here (the file name carries the
                revision, so a list kept for another revision is never returned for this one):

                  \(Self.buildCommand(cache: cache, version: segment))\(sharedNote)
                """
        case .malformed(let pin):
            // **どんな形なら受けるかだけを名乗り、弾いた値は出さない。** この答えは LLM のクライアントが読み、
            // `Package.resolved` は第三者のリポジトリから来うる。値は人が端末で読む `doctor` が見せる。
            // 壊れているとも、パスで指しているとも決めつけない
            return """
                The public API list is not available here.

                \(head): the pin for `\(Self.identity)` in `Package.resolved` is not in a form this tool can use
                as a name (\(DependencyVersion.rule(for: pin))). The value is shown by
                `\(Command.name) doctor \(GivenPath.shellWord(directory))`. Fix that pin line (by hand, or write it again
                with `swift package update \(Self.identity)`), then ask again. Removing `Package.resolved` and
                building also works, but it drops the pins of the other dependencies too, so they may
                move to other versions:

                  \(run)

                If the sketch points at mokume by path (while developing mokume), build the list
                in the mokume repository and put it here instead:

                  \(makeList)
                """
        case .noPackage:
            return """
                The public API list is not available here.

                \(head): there is no `Package.swift` in \(directory.path) to read it from.
                """
        case .version:
            // 版があるときはここへ来ない
            return advice(reason: head, cache: cache)
        }
    }

    /// 本体のリポジトリで一覧を組み立てて、取り置きの場所へ置く手。
    ///
    /// `version` を渡すと、組み上がる一覧の見出し (`# mokume <version> の公開 API`) にそれが出る。改訂のときは
    /// 改訂の名前を渡す — 名前だけでなく、中身も、どの改訂のものかを名乗る (#3478)。
    static func buildCommand(cache: URL, version: String? = nil) -> String {
        let pin = version.map { " VERSION=\(GivenPath.shellWord(quoting: $0))" } ?? ""
        return "make api-list OUT=\(GivenPath.shellWord(cache))\(pin)"
    }

    /// 得られなかった理由と、そこからの一手。
    private func advice(reason: String, cache: URL) -> String {
        """
        The public API list is not available here.

        \(reason)

        Build it in the mokume repository and put it here, and it is returned from then on:

          \(Self.buildCommand(cache: cache))
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
        // 整数の秒は小数点なしで書く。`Int(limit)` は無限大・非数・Int に収まらない値で落ちるので、
        // 収まる範囲の有限の値だけ変換する (今の呼び元は有限の 10 秒だが、落ちる口を残さない)
        let seconds = limit.isFinite && abs(limit) < 1e15 && limit == limit.rounded() ? "\(Int(limit))" : "\(limit)"
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
