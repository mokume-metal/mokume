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

    func facet(_ entry: StartupReads.Entry) -> URL {
        directory.appendingPathComponent(".mokume/\(entry.key)", isDirectory: true)
    }
    var buildStatus: URL { directory.appendingPathComponent(".mokume/build/status.json") }

    /// 要求を置き、同じ識別子の応答が返るまで待つ。
    ///
    /// - Returns: 応答。誰も応えなければ `nil`。
    /// - Parameter extraWait: 応答が返るまでにフレームが何枚も進む要求 (続けて撮る観測
    ///   など) で、``waitLimit`` に**足す**ぶん。上書きではなく加算にしてある —
    ///   上書きにすると、検査が短く設定した上限を呼ぶ側が知らずに戻してしまう。
    func exchange(
        facet: URL, request: [String: Any], id: String, extraWait: TimeInterval = 0,
        sleep: (TimeInterval) -> Void = { Thread.sleep(forTimeInterval: $0) },
        now: () -> Date = { Date() }
    ) throws -> [String: Any]? {
        let waitLimit = self.waitLimit + max(0, extraWait)
        try FileManager.default.createDirectory(at: facet, withIntermediateDirectories: true)
        let reportURL = facet.appendingPathComponent("report.json")
        let data = try JSONSerialization.data(withJSONObject: request)
        try AtomicWrite.write(data, to: facet.appendingPathComponent("request.json"))

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
    /// 作ったのかどうか**にそのまま出る。判定は `FrameObserver.makeIfEnabled` と同じ形にする。
    func hasFacet(_ facet: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: facet.path, isDirectory: &isDirectory)
            && isDirectory.boolValue
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
            走っているスケッチが応えませんでした。\(entry.name) (\(path)) は
            要求を置く前から在ったので、区画を作る順序の問題ではありません。
            考えられるのは 3 つで、打つ手が違います。

            1. まだ立ち上がっていないか、応答が止まっている
               スケッチのディレクトリで `\(Command.name) watch` を起動してから、
               もう一度呼んでください。
            """
            : """
            走っているスケッチが応えませんでした。要求を置こうとしたとき\(entry.name)
            (\(path)) が無かったので、この呼び出しで作りました。
            考えられるのは 3 つで、打つ手が違います。

            1. スケッチが\(entry.name)を持たないまま立ち上がっている
               \(entry.note)。
               **起動し直してください。** 区画はもう在るので、作り直す必要はありません。

                   \(Command.name) watch <スケッチの場所>
            """
        return """
            \(opening)

            2. 窓口とスケッチで区画の基準が割れている
               この窓口が見ているのは、

                   \(StartupReadsReport.baseLine(base: directory, given: workDirectoryGiven))

               です。`watch` が起動のときに名乗る「\(StartupReads.workDirectory.name)」が
               これと違うなら、両者は別の区画を見ています。
               **そのときは起動し直しても直りません。** `watch` と窓口の両方を、
               同じ \(StartupReads.workDirectory.key) の下で起動し直してください。

            3. 依存している mokume が\(entry.name)を持たない版である
               面は版によって増えているので、古い版を固定したスケッチには無いことがあります。
               **そのときも起動し直しても直りません。** 依存している版が持たない面は、

                   \(Command.name) doctor <スケッチの場所>

               が名乗ります。

            起動の瞬間に決まるものは `reference` の `\(Tools.startupDocument)` に一覧があります。
            """
    }
    /// 依存がその面を持たないと読めたときの答え。
    ///
    /// **候補を並べない。** 原因が確定しているので、並べると読み手に選ばせることになる。
    /// 書くのは打つ手だけで、どちらも走らせる側を変えるものである — 窓口の側では直らない。
    func lacksFacet(_ entry: StartupReads.Entry) -> String {
        """
        走っているスケッチが応えませんでした。**スケッチが依存している mokume は\(entry.name)を
        持ちません** — この面はもっと新しい版で足されたもので、依存として引かれている版の
        仕様 (`Schemas/`) にありません。

        **起動し直しても直りません。** 打つ手は 2 つで、どちらも走らせる側を変えることになります。

        1. スケッチが依存する mokume を、この面を持つ版まで上げる
        2. この面を使わずに済ませる

        依存している版が持たない面は `\(Command.name) doctor <スケッチの場所>` が一覧で名乗ります。
        """
    }
}
