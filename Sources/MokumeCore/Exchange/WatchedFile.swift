// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation

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
/// いるが、確定の契機を 3 つ持つ — 解けない要求は捨てる / 同じ識別子は二度処理しない /
/// 応えようとするまで待つ。**その 3 分岐自体が [ADR-0018] 決定 3 の規約**なので、要求を
/// 持たない読み手には引き受けさせない。ここが持つのは「取り込めたときだけ確定する」だけ
/// である ([ADR-0008] 決定 6 — 畳むのは、割れたときに黙って壊れるところに限る)。
///
/// [ADR-0008]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0008-mechanism-needs-demonstrated-harm.md
/// [ADR-0018]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0018-observation-and-control-surface.md
/// [#987]: https://github.com/mokume-metal/mokume/issues/987
/// [#1048]: https://github.com/mokume-metal/mokume/issues/1048
@MainActor
final class WatchedFile<Value: Decodable> {
    let url: URL
    /// もう読んだことにした改訂の最終更新時刻。
    private var readAt: Date?

    init(url: URL) {
        self.url = url
    }

    /// 前に読んだときから変わっていれば、読んで解いて返す。
    ///
    /// 読めなかった・解けなかったときは**確定させない**ので、次に呼べば同じ改訂を掴み
    /// 直せる。書き手が置き終わっていれば、そこで読める。
    ///
    /// - Returns: 新しい中身。変わっていない・まだ読めないなら `nil`。
    func changed() -> Value? {
        let modified = (try? FileManager.default.attributesOfItem(atPath: url.path))?[
            .modificationDate] as? Date
        guard let modified, modified != readAt else { return nil }
        guard let data = try? Data(contentsOf: url),
            let value = try? JSONDecoder().decode(Value.self, from: data)
        else { return nil }
        readAt = modified
        return value
    }
}
