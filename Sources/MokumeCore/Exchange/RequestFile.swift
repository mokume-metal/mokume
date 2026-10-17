// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation
import MokumeDiagnostics

/// 外から置かれる要求が持つもの。
nonisolated protocol ExchangeRequest: Decodable {
    /// この要求の識別子。応答はこれを echo する。
    var id: String { get }
}

/// まだ応えていない要求 (``RequestFile/pending()``)。
///
/// **`id` だけ読めた要求も、応える相手として渡す** ([#2550])。要求の型として解けなくても
/// (つまみの `values` が配列でない・入力の `events` が欠けた・観測の `scale` が文字列)、`id` を
/// 読めれば echo する相手がいる。応えないと、書き手には「届いたが読めなかった」と「走っていない」の
/// 見分けが付かない ([ADR-0018] 決定 3「失敗しても必ず応答する」・[ADR-0030] 決定 2)。応え方
/// (どの語彙で理由を載せるか) は区画ごとに違うので、ここは理由を添えて渡すだけにする。列挙に
/// してあるので、区画を足しても読めない要求の扱いを書き落とせない。
///
/// [#2550]: https://github.com/mokume-metal/mokume/issues/2550
/// [ADR-0018]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0018-observation-and-control-surface.md
/// [ADR-0030]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0030-parameter-surfaces.md
nonisolated enum PendingRequest<Request: ExchangeRequest> {
    /// 解けた要求。
    case request(Request)
    /// `id` は読めたが、要求の形として解けなかった。`reason` は解けなかった理由の 1 行
    /// (`DecodingError: … (at scale)`)。
    case unreadable(id: String, reason: String)

    /// 応答が echo する識別子。
    var id: String {
        switch self {
        case .request(let request): request.id
        case .unreadable(let id, _): id
        }
    }

    /// 解けた要求。解けなかったなら `nil`。
    var request: Request? {
        if case .request(let request) = self { return request }
        return nil
    }
}

extension PendingRequest: Equatable where Request: Equatable {}

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
/// | 解けず、`id` も読めない (欠け・文字列でない・JSON でない・途中で切れた) | する | 壊れた要求は再読しても直らない。echo する相手も無いので応えない |
/// | 解けないが、`id` は読める | ``markHandled(_:)`` まで待つ | 応える相手がいる。理由を添えて渡す (``PendingRequest/unreadable(id:reason:)``・[#2550](https://github.com/mokume-metal/mokume/issues/2550)) |
/// | 応えた識別子と同じ (このプロセスが応えたもの、または作った時点・引き継いだ時点で応答に残っていたもの) | する | 既に応えている |
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
/// ## 応えるのは 1 世代だけ
///
/// 見張りは切り替えの瞬間だけ 2 世代を重ねる ([#1150](https://github.com/mokume-metal/mokume/pull/1150))。
/// **区画に応えるのは、その区画の権利 (``FacetClaim``) を持つプロセスだけである** — 先に
/// 居る世代が消えるまで持ち、次の世代はそこで引き継ぐ。持っていない間の ``pending()`` は
/// 何も返さず、最終更新時刻も確定させない (引き継いだ後に拾えるように)。分けていなかった
/// 頃は、両方の世代が同じ要求に応え、列の観測が区画の上で並走した
/// ([#1162](https://github.com/mokume-metal/mokume/issues/1162))。
///
/// ## 引き継いだ時点で、応答を読み直すか
///
/// 権利を分けても、**次の世代が作られた後に前の世代が応えた要求**は残る。どちらの世代にも
/// 「応えた記録が無い」要求ではなく、前の世代の応答が記録として置かれている。それを
/// 見送るかは、区画が状態を戻すかで分かれる (``Handover``)。
///
/// - **状態を戻す区画 (つまみ) は、作った時点の 1 回だけ読む。** 次の世代は作った後に
///   保存から値を戻すので、その後に前の世代が応えた書き込みは**戻した値に入っていない**。
///   引き継いだ時点の応答で照らすと、それを「応えた」として見送り、画面に残る世代から
///   書き込みが落ちる (#1143)。作った時点の応答が持つ識別子なら、戻した状態に入っている
/// - **状態を戻さない区画 (観測・入力) は、引き継いだ時点で読み直す。** 前の世代が応えた
///   要求にもう一度応えると、読み手には 2 つの世代の応答が順に届く — 目録は前の世代の
///   ものを掴んだ後に次の世代の絵へ置き換わり、入力は 2 度流れる (#1162)
///
/// 帰結として、**識別子は区画が残っている間は使い回せない**。
///
/// [ADR-0018]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0018-observation-and-control-surface.md
@MainActor
final class RequestFile<Request: ExchangeRequest> {
    /// 引き継いだ時点で、前の世代の応答を読み直すか (「引き継いだ時点で、応答を読み直すか」)。
    enum Handover {
        /// 読み直す。状態を戻さない区画 (観測・入力) が選ぶ。
        case rereadsReport
        /// 読み直さず、作った時点の応答だけを記録とする。状態を戻す区画 (つまみ) が選ぶ。
        case keepsCreationRecord
    }

    let url: URL
    /// 応答の置き場。区画の持ち主が書き、ここは作った時点と引き継いだ時点にだけ読む。
    let reportURL: URL
    /// もう見たことにした要求の最終更新時刻。
    private var lastModification: FileStamp?
    /// 拾って返したが、まだ応えていない要求の最終更新時刻。
    private var handingOver: FileStamp?
    /// 最後に応えた要求の識別子。**前の起動が応えたものから始まる** (「プロセスをまたぐ」)。
    private(set) var lastHandledID: String?

    /// 応える権利。
    private let claim: FacetClaim
    private let handover: Handover
    /// 権利を持っているか。**持つまでは要求を拾わない。**
    private var holdsClaim: Bool

    /// 最終更新時刻を見た回数。コストを検査が測るために持つ。
    private(set) var pollCount = 0
    /// 中身を実際に読んだ回数。
    private(set) var readCount = 0

    /// 区画の要求を見張る。**区画の持ち主が状態を戻すより前に作る** — 作った時点の応答が
    /// 持つ識別子を「応えた」とみなすので、戻した状態がそれを含んでいる必要がある。
    ///
    /// 権利もここで取りに行く。取れなければ、以後 ``pending()`` のたびに取りに行く。
    init(facet: URL, handover: Handover) {
        self.url = WorkDirectory.requestURL(under: facet)
        self.reportURL = WorkDirectory.reportURL(under: facet)
        self.handover = handover
        self.claim = FacetClaim.shared(for: facet)
        self.holdsClaim = claim.holds()
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

    /// まだ応えていない要求があれば返す。**`id` だけ読めた要求も返す** (``PendingRequest``)。
    func pending() -> PendingRequest<Request>? {
        pollCount += 1
        guard takeOverIfFree() else { return nil }
        guard let modified = modificationDate() else { return nil }
        guard modified != lastModification else { return nil }

        readCount += 1
        guard let data = try? Data(contentsOf: url) else {
            // 書き手が置いている途中を掴んだ。**確定させずに**次の機会に拾い直す
            return nil
        }
        let pending: PendingRequest<Request>
        do {
            pending = .request(try JSONDecoder().decode(Request.self, from: data))
        } catch {
            // **`id` を読めれば、解けなかった理由を添えて応える相手として渡す** (#2550)。読めなければ
            // 壊れた要求で走っているスケッチを止めず、再読しても直らないので、ここで確定させて捨てる
            guard let id = (try? JSONDecoder().decode(Identified.self, from: data))?.id else {
                lastModification = modified
                return nil
            }
            pending = .unreadable(id: id, reason: Diagnostics.reason(error))
        }
        guard pending.id != lastHandledID else {
            lastModification = modified
            return nil
        }
        handingOver = modified
        return pending
    }

    /// 解けなかった要求のうち、ここが読み直すのは識別子だけ。**文字列でなければ読めない**
    /// (`{"id":5}` に echo する識別子は無い)。
    private struct Identified: Decodable {
        let id: String
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

    /// 権利を持っているか。**いま引き継いだなら、選んだとおりに応答を読み直す。**
    private func takeOverIfFree() -> Bool {
        if holdsClaim { return true }
        guard claim.holds() else { return false }
        holdsClaim = true
        if handover == .rereadsReport {
            lastHandledID = Self.answeredID(in: reportURL)
        }
        return true
    }

    private func modificationDate() -> FileStamp? {
        FileStamp.of(url)
    }
}
