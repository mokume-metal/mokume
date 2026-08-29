// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation

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

    let directory: URL
    /// 走っているスケッチを待つ上限。検査からは短くする。
    var waitLimit: TimeInterval = 5

    var observeFacet: URL { directory.appendingPathComponent(".mokume/observe", isDirectory: true) }
    var inputFacet: URL { directory.appendingPathComponent(".mokume/input", isDirectory: true) }
    var buildStatus: URL { directory.appendingPathComponent(".mokume/build/status.json") }

    /// 要求を置き、同じ識別子の応答が返るまで待つ。
    ///
    /// - Returns: 応答。誰も応えなければ `nil`。
    func exchange(
        facet: URL, request: [String: Any], id: String,
        sleep: (TimeInterval) -> Void = { Thread.sleep(forTimeInterval: $0) },
        now: () -> Date = { Date() }
    ) throws -> [String: Any]? {
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
    /// 応えない理由は 2 つあり、**打つ手が違う**。`existed` (要求を置く前に区画が在ったか) が
    /// 両者を分ける:
    ///
    /// - **在らせたのがこの呼び出し自身** — 走っているスケッチは観測を持っていない。
    ///   区画を見るのは起動の瞬間だけなので、**起動し直す**以外に直らない
    /// - **元から在った** — 区画は揃っているので、走っていないか応答が止まっている
    ///
    /// 以前はこの区別が無く、どちらにも「`watch` を起動してから呼び直す」とだけ答えていた。
    /// 前者の人が案内どおりにしても直らず、実装を読むまで原因に辿り着けなかった
    /// ([#227](https://github.com/mokume-metal/mokume/issues/227))。
    static func notRunning(facet: URL, existed: Bool) -> String {
        let name = facet.lastPathComponent
        guard existed else {
            return """
                走っているスケッチが応えませんでした。要求を置こうとしたとき \(name) の区画
                (\(facet.path)) が無かったので、この呼び出しで作りました。

                **スケッチを起動し直してください。** 区画があるかを見るのは起動の瞬間だけなので、
                走っている最中に作っても、いま走っているスケッチは拾いません。区画はもう在るので、
                作り直す必要はありません。

                    mokume-cli watch <スケッチの場所>
                """
        }
        return """
            走っているスケッチが応えませんでした。\(name) の区画 (\(facet.path)) は要求を置く前から
            在ったので、順序の問題ではありません。まだ立ち上がっていないか、応答が止まっています。
            スケッチのディレクトリで `mokume-cli watch` を起動してから、もう一度呼んでください。
            """
    }
}
