// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation
import mokume

/// 区画への読み書き。
///
/// **窓口は決して起こさない** — 走っているスケッチを立ち上げることも、作り直すことも
/// しない。所有はいつでも見張っている道具の側にあり、ここは区画のファイルを読み書き
/// するだけの薄い層である。
///
/// その代わり**待ちの上限はここにだけ置く**。ADR-0018 が「壁時計で完了を判断しない」と
/// 決めているのは応答する相手が居る前提の話で、誰も走っていない場合は待つ以外に
/// 知る方法が無い。
struct Facets {
    /// 見に行く間隔。
    static let pollInterval: TimeInterval = 0.05
    /// 走っているスケッチを待つ既定の上限。
    static let defaultWaitLimit: TimeInterval = 5

    let directory: URL
    /// 走っているスケッチを待つ上限。検査からは短くする。
    var waitLimit: TimeInterval = defaultWaitLimit
    /// 区画の基準を `MOKUME_WORK_DIR` が決めたか。
    ///
    /// **応えないときの案内が名乗る。** 走らせる側と食い違っていても症状は「誰も応えない」
    /// でしかなく、それは「まだ起動していない」と見分けが付かない (#380 着手条件 2)。
    var workDirectoryGiven: Bool = false

    // 区画の名前も ``StartupReads`` から取る。窓口の側で綴りを持つと、スケッチが見る
    // 場所と黙って食い違いうる (#380)
    var observeFacet: URL { facet(StartupReads.observe) }
    var inputFacet: URL { facet(StartupReads.input) }

    // 区画の URL の組み立ても ``WorkDirectory`` を通す。`.mokume` の綴りをここに持つと、
    // スケッチが書く場所と黙って割れうる (#814)
    func facet(_ entry: StartupReads.Entry) -> URL {
        WorkDirectory.facet(entry.key, under: directory)
    }
    // 作り直しの記録の在処も、書く側と同じ綴りから出す (#730)
    var buildStatus: URL { BuildReport.statusURL(under: directory) }

    /// 要求を置き、同じ識別子の応答が返るまで待つ。
    ///
    /// - Returns: 応答。誰も応えなければ `nil`。
    /// - Parameter extraWait: 応答が返るまでにフレームが何枚も進む要求 (続けて撮る観測
    ///   など) で、``waitLimit`` に**足す**ぶん。上書きではなく加算にしてある —
    ///   上書きにすると、検査が短く設定した上限を呼ぶ側が知らずに戻してしまう。
    /// - Throws: 置けなかったときだけ。**型が付いているので、窓口は `\(error)` を
    ///   そのまま返さずに済む** — untyped だったころは `NSCocoaErrorDomain Code=513 …`
    ///   がエージェントへ届いていた。`CommandFailure` は「どの失敗にも次に何をすれば
    ///   よいかを書く」と宣言しているのに、窓口の 2 箇所だけがその規律の外だった。
    func exchange(
        facet: URL, request: [String: Any], id: String, extraWait: TimeInterval = 0,
        sleep: (TimeInterval) -> Void = { Thread.sleep(forTimeInterval: $0) },
        now: () -> Date = { Date() }
    ) throws(CommandFailure) -> [String: Any]? {
        let waitLimit = self.waitLimit + max(0, extraWait)
        let requestURL = WorkDirectory.requestURL(under: facet)
        do {
            try FileManager.default.createDirectory(at: facet, withIntermediateDirectories: true)
            // 鍵の並びは ``AtomicFile/writeJSON(_:to:)`` と揃える。ここは辞書を直に
            // 書くので `Encodable` の口を通せない (#989)。**形を先に見る** — JSON に
            // できない値を渡すと `JSONSerialization` は Swift の error ではなく ObjC の
            // 例外を出すので、`try` では捕まらず窓口ごと落ちる
            guard JSONSerialization.isValidJSONObject(request) else {
                throw CommandFailure.facetUnwritable(
                    path: requestURL.path, reason: "the request is not in a shape that turns into JSON")
            }
            let data = try JSONSerialization.data(withJSONObject: request, options: [.sortedKeys])
            try AtomicFile.write(data, to: requestURL)
        } catch let failure as CommandFailure {
            throw failure
        } catch {
            throw CommandFailure.facetUnwritable(path: requestURL.path, reason: "\(error)")
        }
        let reportURL = WorkDirectory.reportURL(under: facet)

        let deadline = now().addingTimeInterval(waitLimit)
        while now() < deadline {
            if let report = read(reportURL), report["id"] as? String == id {
                return report
            }
            sleep(Self.pollInterval)
        }
        return nil
    }

    /// JSON を読む。無い・壊れているときは `nil`。
    func read(_ url: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: url),
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return object
    }

    /// 区画がディレクトリとして在るか。
    ///
    /// **要求を置く前に見る。** ``exchange`` は待つ前に区画を自分で作るので、後から見ても
    /// 必ず在る。走っているスケッチが観測を持っているかどうかは、**この呼び出しが区画を
    /// 作ったのかどうか**にそのまま出る。
    ///
    /// 判定そのものは ``WorkDirectory/directoryExists(at:)`` が持つ — かつてここは
    /// 「`FrameObserver.makeIfEnabled` と同じ形にする」と文章で約束していたが、守る機械は
    /// 居なかった (#814)。**道具とライブラリで割れると下の `notRunning` が嘘をつく** —
    /// `existed` は区画を作ったのがこの呼び出し自身かどうかで案内を出し分けるので、割れた
    /// 側では「起動し直せ」と言われた先で「まだ立ち上がっていない」と言われる (#380 の形)。
    func hasFacet(_ facet: URL) -> Bool {
        WorkDirectory.directoryExists(at: facet)
    }

    /// 走っているスケッチが応えないときの答え。**その場で直せるところまで書く。**
    ///
    /// 応えない理由は**打つ手の違う 2 つ**に分かれ、`existed` (要求を置く前に区画が在ったか)
    /// が 1 つ目を絞る:
    ///
    /// - **在らせたのがこの呼び出し自身** — 走っているスケッチは区画を持っていない。
    ///   区画を見るのは起動の瞬間だけなので、**起動し直す**以外に直らない
    ///   ([#227](https://github.com/mokume-metal/mokume/issues/227))
    /// - **元から在った** — 区画を作る順序は合っているので、走っていないか応答が止まっている
    ///
    /// **2 つ目はどちらの側でも起きる** — 走らせる側と窓口で区画の基準が割れていると、互いに
    /// 別の区画を見る。症状は上のどちらとも同じ形で出るのに、**起動し直しても直らない**
    /// ([#380](https://github.com/mokume-metal/mokume/issues/380))。実際に踏むと、案内どおり
    /// 起動し直した先で「まだ立ち上がっていない」と言われる — `watch` は走っているのに、である。
    ///
    /// 文面は読む時点ごとに書き足さず、**起動の瞬間に決まるものの一覧を名指す**。一覧
    /// (``StartupReads``) に増えたものは `reference` の `startup` に自動で並ぶ。
    func notRunning(
        _ entry: StartupReads.Entry, existed: Bool, packageDirectory: URL? = nil
    ) -> String {
        // **読めたなら原因は確定している。** 候補を 3 つ並べる前に、そう言う
        if let package = packageDirectory,
            DependencyFacets.lacks(entry, forPackageAt: package) == true
        {
            return lacksFacet(entry)
        }
        let path = facet(entry).path
        let opening = existed
            ? """
            The running sketch did not answer. \(entry.name) (\(path)) was already there
            before the request was placed, so this is not about the order facets are created in.
            There are three possibilities, and each takes a different move.

            1. Nothing is running yet, or it has stopped answering
               Start `\(Command.name) watch` in the sketch's directory, then call again.
            """
            : """
            The running sketch did not answer. \(entry.name) (\(path)) was not there when
            the request was placed, so this call created it.
            There are three possibilities, and each takes a different move.

            1. The sketch launched without \(entry.name)
               \(entry.note).
               **Restart it.** The facet is there now, so it does not need creating again.

                   \(Command.name) watch <sketch directory>
            """
        return """
            \(opening)

            2. The interface and the sketch disagree on the facet base
               What this interface is looking at:

                   \(StartupReadsReport.baseLine(base: directory, given: workDirectoryGiven))

               If the "\(StartupReads.workDirectory.name)" that `watch` names as it starts
               differs from that, the two are looking at different facets.
               **Restarting will not fix that one.** Start both `watch` and the interface
               under the same \(StartupReads.workDirectory.key).

            3. The mokume the sketch depends on is a version without \(entry.name)
               Facets have been added over time, so a sketch pinned to an older version can
               be missing one. **Restarting will not fix that one either.** Which facets the
               pinned version lacks is named by

                   \(Command.name) doctor <sketch directory>

            What gets decided at launch is listed in `reference`, under `\(Tools.startupDocument)`.
            """
    }
    /// 依存がその面を持たないと読めたときの答え。
    ///
    /// **候補を並べない。** 原因が確定しているので、並べると読み手に選ばせることになる。
    /// 書くのは打つ手だけで、どちらも走らせる側を変えるものである — 窓口の側では直らない。
    func lacksFacet(_ entry: StartupReads.Entry) -> String {
        """
        The running sketch did not answer. **The mokume this sketch depends on does not have
        \(entry.name)** — that facet arrived in a later version, and it is not in the spec
        (`Schemas/`) of the version pinned here.

        **Restarting will not fix this.** There are two moves, and both change the running side.

        1. Raise the sketch's mokume dependency to a version that has this facet
        2. Do without this facet

        `\(Command.name) doctor <sketch directory>` lists which facets the pinned version lacks.
        """
    }
}
