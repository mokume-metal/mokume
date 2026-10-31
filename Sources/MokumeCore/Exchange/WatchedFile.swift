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
/// **書きかけを掴む前提は、この性質を守る理由であって、いまの書き手の事実ではない。**
/// 道具の側が読む 2 つのファイル (つまみの応答・目録) の書き手は ``AtomicFile`` の
/// ``AtomicFile/publishJSON(_:to:_:)`` で、同じディレクトリの一時ファイルを `rename(2)` 1 回で置き換える
/// ので、書きかけは読み手から見えない ([ADR-0018] 決定 3)。確定させない性質は、原子的に置かない書き手 (ほかの道具・
/// 手で置いたファイル・将来の書き手) と、上の 2 件の過去の実害に備えて残している。
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
/// ``onUnreadable`` を呼ぶ。時計は見ない。
///
/// **この名乗りは、書き手が原子的に置くことを前提にしている。** 書きかけが見えないので、同じ改訂が
/// 解けないのは形が読み手と食い違っているとき (版のずれなど) で、1 回目で決まる。**原子的に置かない
/// 書き手を足すときは、この口の使い方を見直すこと** — 置いている途中の一瞬で名乗ってしまい、
/// ``onUnreadable`` の知らせで前の世代を畳むような使い方 (#2928) は、書きかけを理由に世代を畳んでしまう。
///
/// **読めなかった理由で分ける。** 在るはずのファイルが消えていた (`lstat` の後に消えた) のは黙る
/// (消えたことは次の改訂が知らせる)。ファイルとして読めない (権限・置き場がディレクトリ) のは理由だけを
/// 名乗り、版の案内は付けない。解けない (JSON として読めない・型に合わない) ときだけ、版のずれを
/// 候補として挙げる (``UnreadableRevision``)。
///
/// **名乗りの口は必須の引数である。** 省略できると、新しい読み手が渡し忘れて従来どおり黙る
/// — 控える時機を呼び手に委ねないのと同じ理由で、名乗る・名乗らないを呼び手に明示させる。
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
    /// 読めなかったと知らせた改訂の最終更新時刻。**同じ改訂では繰り返さない** (確定ではない)。
    private var unreadableAt: FileStamp?
    /// 読めない改訂を初めて掴んだときに、その失敗を受け取る。**改訂ごとに 1 度。**
    private let onUnreadable: (UnreadableRevision.Failure) -> Void

    /// - Parameter onUnreadable: 読めない改訂を初めて掴んだときの知らせ。**必須** — 名乗らない読み手は
    ///   空の閉包を明示する。名乗る文面は ``UnreadableRevision/notice(of:at:failure:saidBy:)`` で組む。
    init(url: URL, onUnreadable: @escaping (UnreadableRevision.Failure) -> Void) {
        self.url = url
        self.onUnreadable = onUnreadable
    }

    /// 前に読んだときから変わっていれば、読んで解いて返す。
    ///
    /// 読めなかった・解けなかったときは**確定させない**ので、次に呼べば同じ改訂を掴み
    /// 直せる。読めなかった改訂は、**初めて掴んだときに 1 度だけ** ``onUnreadable`` で知らせる
    /// (掴んだ後に消えていたときを除く)。
    ///
    /// - Returns: 新しい中身。変わっていない・まだ読めないなら `nil`。
    func changed() -> Value? {
        let modified = FileStamp.of(url)
        guard let modified, modified != readAt else { return nil }
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            // 時刻を見た後に消えた。消えたことは次の改訂 (置き直し) が知らせるので、ここでは黙る
            return nil
        } catch {
            announce(.cannotRead(reason: Diagnostics.reason(error)), at: modified)
            return nil
        }
        let value: Value
        do {
            value = try JSONDecoder().decode(Value.self, from: data)
        } catch {
            announce(.cannotDecode(reason: Diagnostics.reason(error)), at: modified)
            return nil
        }
        readAt = modified
        unreadableAt = nil
        return value
    }

    private func announce(_ failure: UnreadableRevision.Failure, at modified: FileStamp) {
        guard unreadableAt != modified else { return }
        unreadableAt = modified
        onUnreadable(failure)
    }
}

/// 読めない改訂の失敗と、それを名乗る文面。**読み手 2 つ (つまみの応答・目録) が同じ文面を使う** —
/// 候補の言い方が片方だけ違う・片方だけ落ちる、を作らないため ([#2889](https://github.com/mokume-metal/mokume/issues/2889))。
enum UnreadableRevision {
    /// 読めなかった改訂の失敗。**何が読めなかったかで、案内が変わる。**
    enum Failure: Equatable {
        /// ファイルとして読めない (権限が無い・置き場がディレクトリ)。版の形とは関係が無い。
        case cannotRead(reason: String)
        /// 読めたが解けない (JSON でない・型に合わない・版が違う)。
        case cannotDecode(reason: String)

        /// 読めなかった理由 (``Diagnostics/reason(_:)``)。
        var reason: String {
            switch self {
            case .cannotRead(let reason), .cannotDecode(let reason): reason
            }
        }
    }

    /// - Parameters:
    ///   - subject: 読めなかったもの (「the knob report」など)。
    ///   - url: そのファイル。
    ///   - failure: 読めなかった失敗。
    ///   - saidBy: 同じ改訂を名乗る主体が複数あるときの言い方 (「each window」など)。1 つなら `nil`。
    ///
    /// **版のずれは断定しない** (候補として挙げる)。解けない形は版のずれ以外でも起きうる。**ファイルとして
    /// 読めない失敗には付けない** — 権限や置き場の事情に、版の案内は的外れである。
    static func notice(
        of subject: String, at url: URL, failure: Failure, saidBy: String? = nil
    ) -> String {
        let once = "(said once for this revision" + (saidBy.map { " by \($0)" } ?? "") + ")"
        switch failure {
        case .cannotRead(let reason):
            return "\(subject) (\(url.path)) could not be read: \(reason) \(once)"
        case .cannotDecode(let reason):
            return "\(subject) (\(url.path)) could not be read: \(reason). "
                + "The sketch may depend on a different version of mokume than this tool — "
                + "try `mokume doctor <sketch directory>` \(once)"
        }
    }
}
