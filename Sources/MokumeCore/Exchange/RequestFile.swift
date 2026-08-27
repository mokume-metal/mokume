// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation

/// 外から置かれる要求が持つもの。
nonisolated protocol ExchangeRequest: Decodable {
    /// この要求の識別子。応答はこれを echo する。
    var id: String { get }
}

/// 要求のファイルを見張る。
///
/// [ADR-0018] 決定 3 の規約 — 最終更新時刻で気付く / 知らない鍵は無視する /
/// **同じ識別子は二度処理しない** — を、区画によらず 1 か所で守る。区画が増えるたびに
/// 同じ流儀を書き写すと、写した先から少しずつずれていく。
///
/// **要求が無いときのコストは、最終更新時刻を 1 回見るだけ。** 中身を読むのも
/// 解くのも、更新されていたときだけである。
///
/// [ADR-0018]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0018-observation-and-control-surface.md
@MainActor
final class RequestFile<Request: ExchangeRequest> {
    let url: URL
    private var lastModification: Date?
    private var lastHandledID: String?

    /// 最終更新時刻を見た回数。コストを検査が測るために持つ。
    private(set) var pollCount = 0
    /// 中身を実際に読んだ回数。
    private(set) var readCount = 0

    init(url: URL) {
        self.url = url
    }

    /// まだ応えていない要求があれば返す。
    func pending() -> Request? {
        pollCount += 1
        guard let modified = modificationDate() else { return nil }
        guard modified != lastModification else { return nil }
        lastModification = modified

        readCount += 1
        guard let data = try? Data(contentsOf: url),
            let request = try? JSONDecoder().decode(Request.self, from: data)
        else {
            // 壊れた要求で走っているスケッチを止めない。書き手が原子的に置いて
            // いないときにもここへ来る
            return nil
        }
        guard request.id != lastHandledID else { return nil }
        return request
    }

    /// 応えた識別子を覚える。
    func markHandled(_ id: String) {
        lastHandledID = id
    }

    private func modificationDate() -> Date? {
        try? FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date
    }
}
