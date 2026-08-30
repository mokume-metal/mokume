// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation
import Observation

/// 外から置かれる、値を書き換える要求。
struct ParamRequest: ExchangeRequest {
    let id: String
    let values: [Entry]

    struct Entry: Decodable {
        let name: String
        let value: ParamValue

        private enum CodingKeys: String, CodingKey {
            case name
        }

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            name = try container.decode(String.self, forKey: .name)
            // 型と値は 1 つの組として読む (`{"type", "value"}`)。同じ書き方を
            // 観測の値・応答の値と分け合う
            value = try ParamValue(from: decoder)
        }
    }
}

/// つまみの面が返す応答。
///
/// **現在の値と宣言の両方を載せる。** 読み手が範囲や候補を別の面へ探しに行かなくて
/// 済むようにするため ([ADR-0030] 決定 2)。
///
/// [ADR-0030]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0030-parameter-surfaces.md
struct ParamReport: Encodable {
    static let schemaVersion = 1

    /// 内容が変わるたびに進む番号。
    let revision: Int
    /// 直近に応えた要求の識別子。まだ 1 つも応えていなければ省略される。
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
    struct Clamp: Encodable, Equatable {
        let name: String
        let requested: Double
        let value: Double
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, revision, id, params, rejected, clamped, discarded
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(Self.schemaVersion, forKey: .schemaVersion)
        try container.encode(revision, forKey: .revision)
        try container.encodeIfPresent(id, forKey: .id)
        try container.encode(params, forKey: .params)
        try container.encode(rejected, forKey: .rejected)
        try container.encode(clamped, forKey: .clamped)
        try container.encode(discarded, forKey: .discarded)
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
final class ParamSurface {
    static let requestFileName = "request.json"
    static let reportFileName = "report.json"

    let directory: URL
    private let requests: RequestFile<ParamRequest>
    private let reportURL: URL
    private let registry: ParamRegistry

    /// 内容が変わるたびに進む番号。
    ///
    /// **起動しただけでも進む。** プロセスが変われば宣言そのもの (つまみの数・範囲・
    /// 候補) が変わりうるので、「内容が変われば番号も変わる」を保つ
    /// ([ADR-0030](https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0030-parameter-surfaces.md) 決定 2)。
    private(set) var revision = 0
    private var lastHandledID: String?
    /// 値が変わったことを Observation から受け取る印。
    private var valuesChanged = false

    /// 区画があるときだけ働く (観測・入力と同じ。区画の名前は ``StartupReads`` が正典)。
    static func makeIfEnabled(
        for registry: ParamRegistry,
        store: ParamStore? = nil,
        at directory: URL = WorkDirectory.facet(StartupReads.params.key)
    ) -> ParamSurface? {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory),
            isDirectory.boolValue
        else { return nil }
        return ParamSurface(directory: directory, registry: registry, store: store)
    }

    init(directory: URL, registry: ParamRegistry, store: ParamStore? = nil) {
        self.directory = directory
        self.requests = RequestFile(url: directory.appendingPathComponent(Self.requestFileName))
        self.reportURL = directory.appendingPathComponent(Self.reportFileName)
        self.registry = registry
        self.store = store
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
    /// 結果が揺れ、しかも環境によって再現しない ([ADR-0030] 決定 3)。
    ///
    /// [ADR-0030]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0030-parameter-surfaces.md
    private func apply(_ request: ParamRequest) -> ParamReport {
        var rejected: [ParamReport.Rejection] = []
        var clamped: [ParamReport.Clamp] = []
        for entry in request.values.sorted(by: { $0.name < $1.name }) {
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
        // 見に来るので、静かになるのを待ってから書くと、そのぶん待たせることになる
        store?.flushNow()
        // **1 つも入らなくても応答は書く。** 「届いたが全部断られた」と「届いていない」
        // が外から区別できる形にする (ADR-0030 決定 2)
        return publish(rejected: rejected, clamped: clamped)
    }

    /// いまの姿を書き出し、次の変化を見張り直す。
    @discardableResult
    private func publish(
        rejected: [ParamReport.Rejection] = [], clamped: [ParamReport.Clamp] = [],
        discarded: [ParamReport.Rejection] = []
    ) -> ParamReport {
        revision += 1
        valuesChanged = false
        let declarations = registry.declarations
        let report = ParamReport(
            revision: revision, id: lastHandledID, params: declarations,
            rejected: rejected, clamped: clamped, discarded: discarded)
        write(report)
        watchValues()
        return report
    }

    /// 値が変わったことを Observation から受け取る。
    ///
    /// **フレームごとに値を数え直さない。** 見張りは 1 回きりなので、知らせを受けた
    /// 後に張り直す。
    private func watchValues() {
        withObservationTracking {
            _ = registry.declarations
        } onChange: { [weak self] in
            // 知らせは隔離の外から届く。印を立てるだけにして、実際の書き出しは
            // 次のフレームで行う (描いている最中にファイルを書かない)
            Task { @MainActor [weak self] in
                self?.valuesChanged = true
            }
        }
    }

    private func write(_ report: ParamReport) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes, .sortedKeys]
        guard let data = try? encoder.encode(report) else { return }
        try? AtomicFile.write(data, to: reportURL)
    }
}
