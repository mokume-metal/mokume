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

    /// 走っているスケッチが見つからないときの答え。**何をすればよいかまで書く。**
    static let notRunning = """
        走っているスケッチが見つかりません。応答が返らないのは、まだ立ち上がっていないか、
        観測の区画 (.mokume/observe) が無いためです。スケッチのディレクトリで
        `mokume-cli watch` を起動してから、もう一度呼んでください。
        """
}
