// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation

/// 外から送られてくる入力の要求。
struct InputRequest: ExchangeRequest {
    let id: String
    let events: [RawInputEvent]
}

/// 送られた入力に対する応答。
///
/// **何件が届いて、何件が捨てられたかを返す。** 「送ったのに効かない」の切り分けが
/// これだけで済む — 知らない種別を送っていたのか、溜めきれずに捨てられたのかが分かる。
struct InputReport: Encodable, Equatable {
    static let schemaVersion = 1

    let id: String
    /// 受け取った数。
    let accepted: Int
    /// 知らない種別・解けなかったもの。
    let ignored: Int
    /// 溜めきれずに捨てた数 (このスケッチが起動してからの累計)。
    let dropped: Int

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, id, accepted, ignored, dropped
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(Self.schemaVersion, forKey: .schemaVersion)
        try container.encode(id, forKey: .id)
        try container.encode(accepted, forKey: .accepted)
        try container.encode(ignored, forKey: .ignored)
        try container.encode(dropped, forKey: .dropped)
    }
}

/// 外から送られた入力を受け取る区画 (`.mokume/input`)。
///
/// **標準入力を使わない。** 標準入力は走らせている親が握る資源なので、見張っている
/// 道具に相乗りしている窓口からは使えなくなる — 「観測はできるのに入力だけ届かない」
/// という非対称は、通り道を 1 つに揃えなかったことの帰結でしかない。
/// 観測と同じ区画の流儀に乗せれば、その非対称は最初から生まれない ([ADR-0018] 決定 1)。
///
/// [ADR-0018]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0018-observation-and-control-surface.md
@MainActor
final class InputInbox {
    static let requestFileName = "request.json"
    static let reportFileName = "report.json"

    let directory: URL
    private let requests: RequestFile<InputRequest>
    private let reportURL: URL

    /// 区画があるときだけ働く (観測と同じ)。
    static func makeIfEnabled(at directory: URL = WorkDirectory.facet("input")) -> InputInbox? {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory),
            isDirectory.boolValue
        else { return nil }
        return InputInbox(directory: directory)
    }

    init(directory: URL) {
        self.directory = directory
        self.requests = RequestFile(url: directory.appendingPathComponent(Self.requestFileName))
        self.reportURL = directory.appendingPathComponent(Self.reportFileName)
    }

    /// 要求が来ていれば流し込み、応答を書く。
    @discardableResult
    func drain(into state: InputState) -> InputReport? {
        guard let request = requests.pending() else { return nil }
        // 応えようとしたことは、応答を書けたかどうかによらず記録する (観測と同じ)
        defer { requests.markHandled(request.id) }
        var accepted = 0
        var ignored = 0
        for raw in request.events {
            // **知らない種別は捨てるが、その 1 件だけ。** 残りは通す
            guard let event = raw.event else {
                ignored += 1
                continue
            }
            state.enqueue(event)
            accepted += 1
        }
        let report = InputReport(
            id: request.id, accepted: accepted, ignored: ignored, dropped: state.droppedEvents)
        write(report)
        return report
    }

    private func write(_ report: InputReport) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(report) else { return }
        try? AtomicFile.write(data, to: reportURL)
    }
}
