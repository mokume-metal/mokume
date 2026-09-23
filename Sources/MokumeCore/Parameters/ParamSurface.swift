// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation
import Observation

/// 外から置かれる、値を書き換える要求。
struct ParamRequest: ExchangeRequest {
    let id: String
    let values: [Entry]

    /// 1 件ぶん。**書く側 (道具・保存) と同じ形を読む** (``NamedParamValue``)。
    typealias Entry = NamedParamValue

    /// 当てる順に並べた書き込み。**名前順で、同じ名前は書いた順**
    /// ([ADR-0030] 決定 3)。
    ///
    /// **同じ名前の前後を並べ替えの安定性に預けない。** 標準ライブラリは `sorted(by:)`
    /// が安定であることを保証していない。名前だけを鍵にすると同じ名前の 2 件は「等しい」
    /// になり、どちらが後に当たるか — つまりどちらの値が残るか — が並べ替えの実装で
    /// 決まる。破れても両方の書き込みは成功しているので、応答には何も出ない (#858)。
    ///
    /// [ADR-0030]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0030-parameter-surfaces.md
    var valuesInApplicationOrder: [Entry] {
        values.indices.sorted(by: appliesBefore).map { values[$0] }
    }

    /// `values` の `i` 件目を `j` 件目より先に当てるか。
    ///
    /// **書いた位置を第 2 の鍵にする** ので、異なる 2 件は必ずどちらかが先になる。
    /// 引き分けが無ければ、並べ替えが安定かどうかは結果に出ない。
    func appliesBefore(_ i: Int, _ j: Int) -> Bool {
        (values[i].name, i) < (values[j].name, j)
    }
}

/// つまみの面が返す応答。
///
/// **現在の値と宣言の両方を載せる。** 読み手が範囲や候補を別の面へ探しに行かなくて
/// 済むようにするため ([ADR-0030] 決定 2)。
///
/// [ADR-0030]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0030-parameter-surfaces.md
struct ParamReport: Encodable {
    /// この形式の版。**先頭の格納プロパティである** — 合成の `encode` は宣言順に
    /// 書き出すので、置き場所が鍵の並びを決める。
    let schemaVersion = 2

    /// 内容が変わるたびに進む番号。
    let revision: Int
    /// 区画で直近に応えた要求の識別子。**前の起動が応えたものも含む** (#1143)。区画で
    /// まだ 1 つも応えていなければ省略される。
    let id: String?
    /// 宣言。**並びは書いた順**で、面の情報の一部として保つ。
    let params: [ParamDeclaration]
    /// 入らなかった書き込みと、その理由。
    let rejected: [Rejection]
    /// 範囲へ収めて入れた書き込み。
    let clamped: [Clamp]
    /// 保存から戻せずに捨てた値と、その理由。**起動したときだけ入りうる**
    /// ([ADR-0030](https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0030-parameter-surfaces.md) 決定 6)。
    let discarded: [Rejection]

    /// 入らなかった 1 件。
    struct Rejection: Encodable, Equatable {
        let name: String
        let reason: Reason

        enum Reason: String, Encodable {
            /// 宣言されていない名前。
            case unknownName
            /// 宣言と型が違う。
            case typeMismatch
            /// 許した候補の外。
            case notInChoices
        }
    }

    /// 範囲へ収めた 1 件。
    ///
    /// **値の形は宣言の型に従う** — 数は数、組は成分の配列で、`params` の値と同じ
    /// 書き方をする (`ParamValue.Body`)。組は成分ごとに収めても 1 件で丸ごと載せ、
    /// 範囲の内側だった成分は書いた値と入った値が同じになる。数だけだった形から
    /// 組を載せられる形へ変えたので、版は 2 である ([#859](https://github.com/mokume-metal/mokume/issues/859)・
    /// [ADR-0018](https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0018-observation-and-control-surface.md) 決定 5 の「型の変更」)。
    struct Clamp: Encodable, Equatable {
        let name: String
        let requested: ParamValue
        let value: ParamValue

        private enum CodingKeys: String, CodingKey {
            case name, requested, value
        }

        func encode(to encoder: any Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(name, forKey: .name)
            try container.encode(ParamValue.Body(requested), forKey: .requested)
            try container.encode(ParamValue.Body(value), forKey: .value)
        }
    }
}

/// 宣言した値を外から読み書きする区画 (`.mokume/params`)。
///
/// 観測と入力が使っている規約 ([ADR-0018] 決定 3 — 原子的な書き込み・要求ごとの
/// 識別子と echo・失敗しても必ず応答・知らない鍵は無視) にそのまま乗る。**新しい
/// 通信路も新しい規約も作らない** ([ADR-0030] 決定 2)。
///
/// ## 値が変わっていないフレームの費用
///
/// **要求のファイルの最終更新時刻を 1 回見るだけ**である。応答を書き直すのは、
/// 要求に応えたときと、値が実際に変わったときに限る。値が変わったことは Observation
/// が知らせるので ([ADR-0013] 決定 1)、フレームごとに値を数え直さない。
///
/// [ADR-0013]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0013-parameter-model.md
/// [ADR-0018]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0018-observation-and-control-surface.md
/// [ADR-0030]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0030-parameter-surfaces.md
@MainActor
final class ParamSurface: DeclarationWatcher {
    let directory: URL
    private let requests: RequestFile<ParamRequest>
    private let reportURL: URL
    /// 見張る先 (``DeclarationWatcher``)。
    let registry: ParamRegistry

    /// 内容が変わるたびに進む番号。まだ 1 度も書いていなければ `nil`。
    ///
    /// **起動しただけでも進む。** プロセスが変われば宣言そのもの (つまみの数・範囲・
    /// 候補) が変わりうるので、「内容が変われば番号も変わる」を保つ
    /// ([ADR-0030](https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0030-parameter-surfaces.md) 決定 2)。
    ///
    /// **だからプロセスの中だけで数えない。** 起動し直すたびに 1 から数えると、起動した
    /// きりの前の世代と、つまみが増えた次の世代が同じ番号で違う宣言を書き、前の世代が
    /// 進めていれば番号が戻る。番号で写しの鮮度を見る書き手は、どちらでも気付けない
    /// ([#1458](https://github.com/mokume-metal/mokume/issues/1458))。最初に書くときに、
    /// 区画に残っていた応答の番号 (``revisionLeft(in:)``) の続きから数える。
    ///
    /// **読むのは作った時点ではなく、最初に書く直前である。** 作ってから最初に書くまで
    /// (保存からの復元と `setup()`) の間にも、前の世代は書き足しうる。それでも切り替えで
    /// 2 世代が重なっている間の単調さまでは保たない — 重なりが持つ代償の範囲である
    /// ([#1433](https://github.com/mokume-metal/mokume/issues/1433))。
    private(set) var revision: Int?
    private var lastHandledID: String?
    /// 値が変わったことを Observation から受け取る印。
    private var valuesChanged = false

    /// 値が変わったという知らせを受けた。**印を立てるだけ** — 実際の書き出しは
    /// 次のフレームで行う (描いている最中にファイルを書かない)。
    func declarationsChanged() { valuesChanged = true }

    /// 区画があるときだけ働く (観測・入力と同じ。区画の名前は ``StartupReads`` が正典)。
    static func makeIfEnabled(
        for registry: ParamRegistry,
        store: ParamStore? = nil,
        at directory: URL = WorkDirectory.facet(StartupReads.params.key)
    ) -> ParamSurface? {
        guard WorkDirectory.directoryExists(at: directory) else { return nil }
        return ParamSurface(directory: directory, registry: registry, store: store)
    }

    init(directory: URL, registry: ParamRegistry, store: ParamStore? = nil) {
        self.directory = directory
        let requests = RequestFile<ParamRequest>(facet: directory, handover: .keepsCreationRecord)
        self.requests = requests
        self.reportURL = requests.reportURL
        // **応えた識別子を起動をまたいで持ち越す。** 起動は応答を書き直す (``start(after:)``)
        // ので、持ち越さないと書き直した応答が識別子を落とし、次の起動で応えた書き込みが
        // もう一度当たる (#1143)。**init で受け取る** — 保存から戻すのは作った後なので、
        // 持ち越した識別子の書き込みは戻した値に入っている
        self.lastHandledID = requests.lastHandledID
        self.registry = registry
        self.store = store
        // **見張りは持ち主と同時に立つ。** 書き出しの経路で張っていたころは、
        // そこを通らない道ができた瞬間に死んだ (#994 の 12)
        watchDeclarations()
    }

    /// 検査から 1 行で組むための入口。
    convenience init(directory: URL, sketch: any Sketch) {
        self.init(directory: directory, registry: ParamRegistry(of: sketch))
    }

    /// 保存。外からの書き込みを即時に書き出させるために持つ。
    private let store: ParamStore?

    /// 最初の応答を書き、値の変化を見張り始める。
    ///
    /// 保存から戻せなかったものは、**最初の応答に載せる** ([ADR-0030] 決定 6)。診断は
    /// 端末にしか出ないので、外から読む側にも同じことが見えている必要がある。
    ///
    /// [ADR-0030]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0030-parameter-surfaces.md
    func start(after restoration: ParamStore.Restoration = .init()) {
        publish(clamped: restoration.clamped, discarded: restoration.discarded)
    }

    /// 要求が来ていれば書き込み、応答を書く。値が変わっていれば応答を書き直す。
    @discardableResult
    func drain() -> ParamReport? {
        if let request = requests.pending() {
            // 応えようとしたことは、応答を書けたかどうかによらず記録する (観測と同じ)
            defer { requests.markHandled(request.id) }
            return apply(request)
        }
        guard valuesChanged else { return nil }
        return publish()
    }

    /// 書き込みを当てる。
    ///
    /// **1 つの要求の中は名前順に処理する。** 並びが辞書の順に依ると、同じ要求で
    /// 結果が揺れ、しかも環境によって再現しない ([ADR-0030] 決定 3)。同じ名前は
    /// 書いた順に当たるので、後のほうが残る (`ParamRequest.valuesInApplicationOrder`)。
    ///
    /// [ADR-0030]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0030-parameter-surfaces.md
    private func apply(_ request: ParamRequest) -> ParamReport {
        var rejected: [ParamReport.Rejection] = []
        var clamped: [ParamReport.Clamp] = []
        for entry in request.valuesInApplicationOrder {
            guard let outcome = registry.write(entry.value, to: entry.name) else {
                rejected.append(.init(name: entry.name, reason: .unknownName))
                continue
            }
            switch outcome {
            case .applied:
                break
            case .clamped(let requested, let applied):
                clamped.append(.init(name: entry.name, requested: requested, value: applied))
            case .typeMismatch:
                rejected.append(.init(name: entry.name, reason: .typeMismatch))
            case .notInChoices:
                rejected.append(.init(name: entry.name, reason: .notInChoices))
            }
        }
        lastHandledID = request.id
        // **外からの書き込みは待たせずに保存する** (ADR-0030 決定 6)。書いた側は反映を
        // 見に来るので、静かになるのを待ってから書くと、そのぶん待たせることになる。
        // **保存は応答より先に書く** — 次の起動は応答にある識別子を「応えた」として
        // 見送るので、応答に載った書き込みは保存にも入っていなければならない (#1143)
        store?.flushNow()
        // **1 つも入らなくても応答は書く。** 「届いたが全部断られた」と「届いていない」
        // が外から区別できる形にする (ADR-0030 決定 2)
        return publish(rejected: rejected, clamped: clamped)
    }

    /// いまの姿を書き出す。
    @discardableResult
    private func publish(
        rejected: [ParamReport.Rejection] = [], clamped: [ParamReport.Clamp] = [],
        discarded: [ParamReport.Rejection] = []
    ) -> ParamReport {
        let revision = Self.advanced(self.revision ?? Self.revisionLeft(in: reportURL))
        self.revision = revision
        valuesChanged = false
        let declarations = registry.declarations
        let report = ParamReport(
            revision: revision, id: lastHandledID, params: declarations,
            rejected: rejected, clamped: clamped, discarded: discarded)
        write(report)
        return report
    }

    /// 次の番号。**進められなければ 1 から数え直す。**
    ///
    /// 区画に残っていた数の続きから数えるので、足す相手は外から置けるものである。
    /// `Int.max` が置かれていただけで起動が落ちる形にしない。
    private static func advanced(_ revision: Int) -> Int {
        let (next, overflowed) = revision.addingReportingOverflow(1)
        return overflowed ? 1 : next
    }

    /// 区画に残っていた応答の番号。無い・読めない・解けない・番号でない (Schema の
    /// `minimum: 1` を割る) ときは 0 で、そのとき最初の番号は 1 になる。
    private static func revisionLeft(in reportURL: URL) -> Int {
        guard let data = try? Data(contentsOf: reportURL),
            let left = try? JSONDecoder().decode(LeftReport.self, from: data)
        else { return 0 }
        return max(left.revision, 0)
    }

    /// 残っていた応答のうち、ここが読むのは番号だけ。識別子は ``RequestFile`` が読む。
    private struct LeftReport: Decodable {
        let revision: Int
    }

    private func write(_ report: ParamReport) {
        AtomicFile.publishJSON(report, to: reportURL, "the knob reply")
    }
}
