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
/// ## 最終更新時刻を確定させる時機
///
/// 最終更新時刻は「この要求はもう見た」という印なので、**確定させた瞬間にその要求は
/// 二度と拾えなくなる**。だから確定は経路ごとに分ける。
///
/// | 経路 | 確定するか | 理由 |
/// | --- | --- | --- |
/// | 読めない | しない | 書き手が置いている途中を掴んだだけ。次に拾えばよい |
/// | 解けない | する | 壊れた要求は再読しても直らない |
/// | 応えた識別子と同じ | する | 既に応えている |
/// | 拾えた | ``markHandled(_:)`` まで待つ | 応えようとするまでは、まだ見たことにしない |
///
/// 読む前に確定させると、書き手が原子的に置いていない一瞬を 1 回掴んだだけで
/// **その要求が永久に失われ、応答も書かれない** ([#221](https://github.com/mokume-metal/mokume/issues/221))。
///
/// [ADR-0018]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0018-observation-and-control-surface.md
@MainActor
final class RequestFile<Request: ExchangeRequest> {
    let url: URL
    /// もう見たことにした要求の最終更新時刻。
    private var lastModification: Date?
    /// 拾って返したが、まだ応えていない要求の最終更新時刻。
    private var handingOver: Date?
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

        readCount += 1
        guard let data = try? Data(contentsOf: url) else {
            // 書き手が置いている途中を掴んだ。**確定させずに**次の機会に拾い直す
            return nil
        }
        guard let request = try? JSONDecoder().decode(Request.self, from: data) else {
            // 壊れた要求で走っているスケッチを止めない。再読しても直らないので、
            // ここで確定させて捨てる
            lastModification = modified
            return nil
        }
        guard request.id != lastHandledID else {
            lastModification = modified
            return nil
        }
        handingOver = modified
        return request
    }

    /// 応えようとしたことを記録する。
    ///
    /// **応答を書けたかどうかによらず呼ぶ。** 書き込みに失敗したときに記録しないと、
    /// 同じ要求を毎フレーム拾い直し、壊れた書き込み先の上でループになる。
    func markHandled(_ id: String) {
        lastHandledID = id
        if let handingOver {
            lastModification = handingOver
            self.handingOver = nil
        }
    }

    private func modificationDate() -> Date? {
        try? FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date
    }
}
