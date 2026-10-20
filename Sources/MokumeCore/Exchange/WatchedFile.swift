// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation
import MokumeDiagnostics

/// 区画のファイルを、最終更新時刻で気付いて読む。
///
/// **確定は取り込めたときだけ。** 最終更新時刻は「この改訂はもう読んだ」という印なので、
/// 読む前に控えると、書き手が置いている途中を **1 回掴んだだけでその改訂が永久に読み
/// 飛ばされる** — 次に最終更新時刻が動く (= 次の書き込みが起きる) まで、更新時刻の照合が
/// 弾き続けるためである。
///
/// 症状はどちらの読み手でも「落ちも警告も出ないまま、古いものが表示され続ける」だけで、
/// 実際に 2 箇所とも同じ 1 点を落としていた ([#987] のつまみ・[#1048] の目録)。目録に
/// 至っては書かれるのが走り出しの 1 回だけなので、直る契機そのものが来ない。だから
/// **控える時機を呼び手に委ねず、ここで持つ** — 呼び手が忘れることが、塞ぐべき実害である。
///
/// **要求が無いときのコストは、最終更新時刻を 1 回見るだけ。** 中身を読むのも解くのも、
/// 更新されていたときだけである。
///
/// ## ``RequestFile`` とは、この 1 点だけを共有する
///
/// あちらは同じ穴を [#221](https://github.com/mokume-metal/mokume/issues/221) で先に塞いで
/// いるが、確定の契機を 3 つ持つ — `id` も読めない要求は捨てる / 同じ識別子は二度処理しない /
/// 応えようとするまで待つ (`id` だけ読めた要求も、応える相手として待つ・#2550)。**その 3 分岐自体が [ADR-0018] 決定 3 の規約**なので、要求を
/// 持たない読み手には引き受けさせない。ここが持つのは「取り込めたときだけ確定する」だけ
/// である ([ADR-0008] 決定 6 — 畳むのは、割れたときに黙って壊れるところに限る)。
///
/// ## 読めない改訂は、改訂ごとに 1 度名乗る
///
/// **確定させないことと、黙ることは別である** ([#2889](https://github.com/mokume-metal/mokume/issues/2889))。
/// 読めない改訂を黙って捨て続けると、つまみが 1 つも並ばない・目録が古いまま、のどちらも理由を言わずに
/// 続く ([ADR-0018] 決定 6「補ったら名乗る・黙って寛容にならない」)。**同じ改訂は読み直すたびには
/// 名乗らず**、最後に解けなかった改訂の最終更新時刻を 1 つ控えて、初めて解けなかったときだけ
/// ``onUnreadable`` を呼ぶ。時計は見ない — 書き手は原子的に置く ([ADR-0018] 決定 3) ので、
/// 同じ改訂が解けないのは形が読み手と食い違っているとき (版のずれなど) で、1 回目で決まる。
///
/// [ADR-0008]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0008-mechanism-needs-demonstrated-harm.md
/// [ADR-0018]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0018-observation-and-control-surface.md
/// [#987]: https://github.com/mokume-metal/mokume/issues/987
/// [#1048]: https://github.com/mokume-metal/mokume/issues/1048
@MainActor
final class WatchedFile<Value: Decodable> {
    let url: URL
    /// もう読んだことにした改訂の最終更新時刻。
    private var readAt: FileStamp?
    /// 解けなかったと名乗った改訂の最終更新時刻。**同じ改訂では繰り返さない** (確定ではない)。
    private var unreadableAt: FileStamp?

    /// 読めない改訂を初めて掴んだときに、その理由 (1 行) を受け取る。**改訂ごとに 1 度。**
    ///
    /// 読み手が名乗る文面は ``UnreadableRevision/notice(of:at:reason:)`` で組む。
    /// 読み手が「いま読めていない」ことを別の用途 (前の世代を畳む判断など) に使う口でもある。
    var onUnreadable: ((_ reason: String) -> Void)?

    init(url: URL, onUnreadable: ((_ reason: String) -> Void)? = nil) {
        self.url = url
        self.onUnreadable = onUnreadable
    }

    /// 前に読んだときから変わっていれば、読んで解いて返す。
    ///
    /// 読めなかった・解けなかったときは**確定させない**ので、次に呼べば同じ改訂を掴み
    /// 直せる。書き手が置き終わっていれば、そこで読める。読めなかった改訂は、**初めて掴んだときに
    /// 1 度だけ** ``onUnreadable`` で知らせる。
    ///
    /// - Returns: 新しい中身。変わっていない・まだ読めないなら `nil`。
    func changed() -> Value? {
        let modified = FileStamp.of(url)
        guard let modified, modified != readAt else { return nil }
        let value: Value
        do {
            let data = try Data(contentsOf: url)
            value = try JSONDecoder().decode(Value.self, from: data)
        } catch {
            if unreadableAt != modified {
                unreadableAt = modified
                onUnreadable?(Diagnostics.reason(error))
            }
            return nil
        }
        readAt = modified
        unreadableAt = nil
        return value
    }
}

/// 読めない改訂を名乗る文面。**読み手 2 つ (つまみの応答・目録) が同じ文面を使う** — 候補の言い方が
/// 片方だけ違う・片方だけ落ちる、を作らないため ([#2889](https://github.com/mokume-metal/mokume/issues/2889))。
enum UnreadableRevision {
    /// - Parameters:
    ///   - subject: 読めなかったもの (「the knob report」など)。
    ///   - url: そのファイル。
    ///   - reason: 読めなかった理由 (``Diagnostics/reason(_:)``)。
    ///
    /// **版のずれは断定しない** (候補として挙げる)。同じ形の失敗は版のずれ以外でも起きうる。
    static func notice(of subject: String, at url: URL, reason: String) -> String {
        "\(subject) (\(url.path)) could not be read: \(reason). "
            + "The sketch may depend on a different version of mokume than this tool — "
            + "try `mokume doctor <sketch directory>` (said once for this revision)"
    }
}
