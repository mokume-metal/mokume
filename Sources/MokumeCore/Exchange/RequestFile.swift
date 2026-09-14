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
/// | 応えた識別子と同じ (このプロセスが応えたもの、または作った時点で応答に残っていたもの) | する | 既に応えている |
/// | 拾えた | ``markHandled(_:)`` まで待つ | 応えようとするまでは、まだ見たことにしない |
///
/// 読む前に確定させると、書き手が原子的に置いていない一瞬を 1 回掴んだだけで
/// **その要求が永久に失われ、応答も書かれない** ([#221](https://github.com/mokume-metal/mokume/issues/221))。
///
/// **要求を持たない読み手は ``WatchedFile`` を使う。** 表のうち共有できるのは 1 行目
/// (読めなければ確定させない) だけで、残りの 3 行は「要求に応える」という、この型に固有の
/// 契約である。共有した 1 点を落として同じ穴に落ちたのが [#987](https://github.com/mokume-metal/mokume/issues/987) と
/// [#1048](https://github.com/mokume-metal/mokume/issues/1048) である。
///
/// ## プロセスをまたぐ
///
/// 要求のファイルは応えた後も残るので、プロセスの中の記憶だけで「二度処理しない」を
/// 守ると、**起動し直すたびに応えた要求がもう一度届く** — `watch` は保存のたびに
/// プロセスを差し替えるので、保存するたびに過去の入力が再生される
/// ([#1143](https://github.com/mokume-metal/mokume/issues/1143))。
///
/// **記録は応答そのものである。** 応答が同じ識別子を echo していれば応えており、
/// していなければ応えていない。応えた記録を別のファイルに持たない — 読み手が完了を
/// 知る印と、書き手が「応えた」とみなす印が割れないようにするためである。だから応答が
/// 無い・別の識別子を持つ・書けなかった・書き終える前に落ちた要求は、起動し直した先で
/// 応え直す。どれも読み手に応答が届いていない。
///
/// **応答を読むのは作った時点の 1 回だけ。** 要求を見つけるたびに照らす形は採らない。
/// 見張りは切り替えの瞬間だけ 2 世代を重ねる ([#1150](https://github.com/mokume-metal/mokume/pull/1150)) ので、
/// 次の世代が作られた後に前の世代が応えた要求は、**次の世代が戻した状態に入っていない**。
/// 見つけた時点で照らすと、それを「応えた」として見送ってしまう。作った時点の応答が
/// 持つ識別子なら、区画の持ち主が状態を戻すより前に応えたものなので、戻した状態に
/// 入っている。
///
/// 帰結として、**識別子は区画が残っている間は使い回せない**。
///
/// [ADR-0018]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0018-observation-and-control-surface.md
@MainActor
final class RequestFile<Request: ExchangeRequest> {
    let url: URL
    /// 応答の置き場。区画の持ち主が書き、ここは作った時点で 1 回だけ読む。
    let reportURL: URL
    /// もう見たことにした要求の最終更新時刻。
    private var lastModification: Date?
    /// 拾って返したが、まだ応えていない要求の最終更新時刻。
    private var handingOver: Date?
    /// 最後に応えた要求の識別子。**前の起動が応えたものから始まる** (「プロセスをまたぐ」)。
    private(set) var lastHandledID: String?

    /// 最終更新時刻を見た回数。コストを検査が測るために持つ。
    private(set) var pollCount = 0
    /// 中身を実際に読んだ回数。
    private(set) var readCount = 0

    /// 区画の要求を見張る。**区画の持ち主が状態を戻すより前に作る** — 作った時点の応答が
    /// 持つ識別子を「応えた」とみなすので、戻した状態がそれを含んでいる必要がある。
    init(facet: URL) {
        self.url = WorkDirectory.requestURL(under: facet)
        self.reportURL = WorkDirectory.reportURL(under: facet)
        self.lastHandledID = Self.answeredID(in: reportURL)
    }

    /// 応答が echo している識別子。無い・読めない・解けないときは `nil` (応えた記録が無い)。
    private static func answeredID(in reportURL: URL) -> String? {
        guard let data = try? Data(contentsOf: reportURL) else { return nil }
        return (try? JSONDecoder().decode(Answer.self, from: data))?.id
    }

    /// 応答のうち、ここが読むのは識別子だけ。区画ごとに形が違っても、`id` は共通である。
    private struct Answer: Decodable {
        let id: String?
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
