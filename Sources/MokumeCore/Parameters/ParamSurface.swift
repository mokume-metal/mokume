// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation
import Observation

/// 外から置かれる、値を書き換える要求。
struct ParamRequest: ExchangeRequest {
    let id: String
    let values: [Entry]

    /// 1 件ぶん。**書く側 (道具・保存) と同じ形を読む** (``NamedParamValue``)。
    ///
    /// **読めなかった 1 件は、要求を道連れにせず、読めなかったことを抱える。** 要素を
    /// そのまま ``NamedParamValue`` で解くと、`Double` に収まらない数 (`1e400`)・知らない
    /// `type`・型に合わない値のどれか 1 件が配列ごと・要求ごとのデコードを失敗させ、
    /// `RequestFile.pending()` が要求を確定させて捨てる。書いた側には応答も警告も返らず、
    /// 同じ要求の他の値も入らない ([#2496](https://github.com/mokume-metal/mokume/issues/2496))。
    /// 入力の面の ``InputRequest/Entry`` と同じ形で、1 件ずつ緩く読み、読めなかった 1 件は
    /// ``ParamSurface`` が理由つきで `rejected` に載せる ([ADR-0030] 決定 2)。
    ///
    /// 読めなかった理由は 2 つに分ける。`float`・`vec2`・`vec3`・`color` の数が `Double`
    /// に収まらないとき (`JSONDecoder` が数を読む瞬間に断る) は ``ParamReport/Rejection/Reason/notFinite``
    /// — 置き場が `1e300` を断るのと同じ「有限の数にならない」である。それ以外 (知らない
    /// `type`・値が型の形でない・`int` に収まらない数・成分の数が違う) は
    /// ``ParamReport/Rejection/Reason/typeMismatch``。
    ///
    /// **理由を決める順は、名前が先** である。名前が読めて宣言に無いなら、読めなかった中身が
    /// どうであれ ``ParamReport/Rejection/Reason/unknownName`` (綴りの誤りが先に直せる)。
    /// 宣言のある名前なら、上の理由で載せる。
    ///
    /// **名前が読めない 1 件は、名指しする相手が無い**ので、名前を空にして `typeMismatch` に
    /// 載せる (宣言されていない名前としても、読めた 1 件の名前が空であっても、応答の形は同じ)。
    ///
    /// **要求の外枠が読めないときも、`id` を読めれば応える** ([#2550](https://github.com/mokume-metal/mokume/issues/2550))。
    /// `values` が配列でない・欠けた・`null` の要求は、名前の読めない 1 件だけを持つ要求として当てる
    /// (``ParamSurface`` が `rejected` に名前を空にして `typeMismatch` で載せる)。名指しする相手が
    /// 無いのは名前の読めない 1 件と同じで、応答の形も理由の列挙も変えずに「届いたが読めなかった」が
    /// 伝わる ([ADR-0030] 決定 2・3)。`id` が読めない要求 (欠け・文字列でない・JSON でない) は、
    /// echo する相手が無いので応えない (``RequestFile``)。
    ///
    /// [ADR-0030]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0030-parameter-surfaces.md
    struct Entry: Decodable, Equatable {
        let name: String
        let reading: Reading

        enum Reading: Equatable {
            case value(ParamValue)
            /// 名前は読めたが、中身が読めなかった。名前が宣言に無ければ `unknownName` が先。
            case unreadable(ParamReport.Rejection.Reason)
            /// 名前が読めなかった。名指しする相手が無いので、名前は空で `typeMismatch`。
            case nameless
        }

        init(name: String, value: ParamValue) {
            self.name = name
            reading = .value(value)
        }

        /// 名前の読めない 1 件。外枠が読めない要求は、これだけを持つ要求として当てる (#2550)。
        static var nameless: Entry { Entry(name: "", reading: .nameless) }

        private init(name: String, reading: Reading) {
            self.name = name
            self.reading = reading
        }

        private enum CodingKeys: String, CodingKey {
            case name, type
        }

        init(from decoder: any Decoder) throws {
            // 要素がオブジェクトでない・名前が文字列でないときは、名指しできない
            guard let container = try? decoder.container(keyedBy: CodingKeys.self),
                let name = try? container.decode(String.self, forKey: .name)
            else {
                self.name = ""
                reading = .nameless
                return
            }
            self.name = name
            do {
                reading = .value(try NamedParamValue(from: decoder).value)
            } catch {
                let typeName = (try? container.decode(String.self, forKey: .type))
                    .flatMap(ParamTypeName.init(rawValue:))
                reading = .unreadable(Self.reason(unreadableBecauseOf: error, typeName: typeName))
            }
        }

        /// 読めなかった理由。
        private static func reason(unreadableBecauseOf error: any Error, typeName: ParamTypeName?)
            -> ParamReport.Rejection.Reason
        {
            switch typeName {
            case .float, .vec2, .vec3, .color:
                // **ここで読む数が読めない理由は、桁あふれだけ** (`1e400`)。`JSONDecoder` は数を
                // 読む瞬間に断り (文書の走査は通るので、この 1 件だけが断られる)、入れ子の読みの
                // 中では `DecodingError` に包まれる前の内部の誤りが漏れ出る。こちらが投げる誤りは、
                // 型の不一致・欠け・成分の数の違いのどれも `DecodingError` なので、それ以外が
                // 出たら数の桁あふれと読む (`ParameterUnreadableEntryTests` が固定する)
                return error is DecodingError ? .typeMismatch : .notFinite
            case .int, .bool, .string, nil:
                return .typeMismatch
            }
        }
    }

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
            /// 有限の数でない (NaN・無限)。宣言の型へ読み替えると収まらず無限になる数も含む。
            case notFinite
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
/// **要求のファイルの最終更新時刻を 1 回見て、値が変わった印を 1 つ取るだけ**である。応答を書き直すのは、
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
    /// 値が変わったという印 (``DeclarationWatcher``)。
    let declarationNotice = DeclarationNotice()

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
    /// 値が変わったので、応答を書き直す必要がある。
    private var valuesChanged = false

    /// 値が変わったという印を取った。**書き直す必要を控えるだけ** — 書き出しは印を
    /// 取った ``drain()`` / ``flushIfChanged()`` の中で行う。どちらもフレームの境目で
    /// 呼ばれるので、描いている最中にファイルを書かない。
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
    ///
    /// **値が変わったかは、ここで印を取って知る** (``DeclarationWatcher``)。main actor を
    /// 譲らずに回すループでも、`draw` の中で変えた値が次のフレームのここで届く (#1704)。
    @discardableResult
    func drain() -> ParamReport? {
        takeDeclarationChange()
        if let pending = requests.pending() {
            // 応えようとしたことは、応答を書けたかどうかによらず記録する (観測と同じ)
            defer { requests.markHandled(pending.id) }
            switch pending {
            case .request(let request):
                return apply(request)
            case .unreadable(let id, _):
                // **外枠が読めない要求にも応える** (#2550)。名前の読めない 1 件だけを持つ要求として
                // 当てるので、`rejected` に名前の無い `typeMismatch` が 1 件載り、値は何も変わらない
                return apply(ParamRequest(id: id, values: [.nameless]))
            }
        }
        guard valuesChanged else { return nil }
        return publish()
    }

    /// 値が変わっていれば応答を書き直す。**要求は見ない。** 終わるときに呼ぶ。
    ///
    /// 最後のフレームで変わった値は、次の ``drain()`` が来ないので、ここで書かないと
    /// 区画に届かないまま終わる (保存の ``ParamStore/flushIfPending()`` と同じ理由)。
    /// 要求を見ないのは、応えた結果を次の起動へ持ち越す手当て (保存を先に書く・#1143)
    /// を閉じる間際に通さないためで、置かれた要求は次の起動が応える。
    @discardableResult
    func flushIfChanged() -> ParamReport? {
        takeDeclarationChange()
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
            // **読めなかった 1 件は、その 1 件だけ理由つきで載せ、残りは当てる** (#2496)
            let value: ParamValue
            switch entry.reading {
            case .value(let read):
                value = read
            case .unreadable(let reason):
                // **名前が先** — 綴りを間違えた書き手には、中身の誤りより先にそれを伝える
                rejected.append(
                    .init(name: entry.name, reason: registry.declares(entry.name) ? reason : .unknownName))
                continue
            case .nameless:
                rejected.append(.init(name: "", reason: .typeMismatch))
                continue
            }
            guard let outcome = registry.write(value, to: entry.name) else {
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
            case .notFinite:
                rejected.append(.init(name: entry.name, reason: .notFinite))
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
        // **書く姿には、立っている印の変化がもう入っている** ので下ろす。残すと、自分が
        // 当てた書き込み (外からの要求・保存からの復元・setup) の印で、次の drain() が
        // 同じ中身をもう 1 度書く (#1704)
        coverDeclarationChange()
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
