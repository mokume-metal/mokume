// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation

/// 外から送られてくる入力の要求。
///
/// **`events` が読めない要求 (配列でない・欠けた・`null`) も、`id` を読めれば応える**
/// ([#2550](https://github.com/mokume-metal/mokume/issues/2550))。解けなかった 1 件だけを持つ要求として
/// 流し (``InputInbox/drain(into:)``)、`ignored` に 1 と数える — 解けなかったものを数える、
/// 1 件の読めなさと同じ意味である (#1132)。
struct InputRequest: ExchangeRequest {
    let id: String
    let events: [Entry]
    /// 要求の最上位にあった、読まない鍵 (名前順)。**要求は失敗させず、応答の `warnings` で名乗る**
    /// ([#2843](https://github.com/mokume-metal/mokume/issues/2843))。
    let unknownKeys: [String]

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case id, events
    }

    /// 読む鍵 (宣言順)。スキーマ (`input-request.schema.json`) の最上位の `properties` と同じ集合で、
    /// 名乗りの文面が並べる。一致は検査が見る。
    static var readKeys: [String] { UnknownKeys.readKeys(CodingKeys.self) }

    init(id: String, events: [Entry], unknownKeys: [String] = []) {
        self.id = id
        self.events = events
        self.unknownKeys = unknownKeys
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        events = try container.decode([Entry].self, forKey: .events)
        unknownKeys = try UnknownKeys.names(in: decoder, known: CodingKeys.self)
    }

    /// 並んだ 1 件。**解けなかった 1 件は、要求を道連れにせず `nil` になる。**
    ///
    /// 要素をそのまま ``RawInputEvent`` で解くと、`type` の欠けた 1 件や型の違う値が
    /// 配列ごと・要求ごとのデコードを失敗させ、応答が書かれないまま黙る。送り手には
    /// 「走っていない」と見分けが付かない ([#1132](https://github.com/mokume-metal/mokume/issues/1132))。
    /// 失敗をここで吸収すれば、知らない種別と同じ経路で `ignored` に数えられる。
    ///
    /// **知らない鍵は、解けなかった 1 件でも数える** ([#2843](https://github.com/mokume-metal/mokume/issues/2843))。
    /// `tpye` のような綴りの誤りは、その 1 件が `ignored` に数えられた理由としてこそ効く。
    struct Entry: Decodable {
        let event: InputEvent?
        /// この 1 件にあった、読まない鍵 (名前順)。
        let unknownKeys: [String]
        /// この 1 件の種別が読む鍵。名乗りの文面が並べる (``RawInputEvent/readKeys(forType:)``)。
        let readKeys: [String]

        init(from decoder: Decoder) throws {
            event = (try? RawInputEvent(from: decoder))?.event
            // 種別は、解けなかった 1 件でも読めれば読む鍵を絞れる
            let type = try? decoder.container(keyedBy: RawInputEvent.CodingKeys.self)
                .decodeIfPresent(String.self, forKey: .type)
            readKeys = RawInputEvent.readKeys(forType: type ?? nil)
            unknownKeys = (try? UnknownKeys.names(in: decoder, readKeys: readKeys)) ?? []
        }

        /// 解けなかった 1 件。`events` の読めない要求は、これだけを持つ要求として流す (#2550)。
        static var unreadable: Entry { Entry(event: nil) }

        private init(event: InputEvent?) {
            self.event = event
            self.unknownKeys = []
            self.readKeys = RawInputEvent.readKeys
        }
    }

    /// 要求の最上位の、読まない鍵。**`events` が読めず要求として解けなかったときのために、ファイルの
    /// 中身から最上位だけを数える** — `evnts` の綴りの誤りは、`events` が欠けた要求としてこそ起きる。
    static func unknownKeys(inFile data: Data?) -> [String] {
        guard let data, let top = try? JSONDecoder().decode(TopLevel.self, from: data) else {
            return []
        }
        return top.unknownKeys
    }

    private struct TopLevel: Decodable {
        let unknownKeys: [String]
        init(from decoder: any Decoder) throws {
            unknownKeys = try UnknownKeys.names(in: decoder, known: CodingKeys.self)
        }
    }

    /// 知らない鍵の名乗り。要求の最上位が先、出来事が `events[i]` の位置つきで続く。
    ///
    /// **出来事の名乗りは ``namedEventLimit`` 件で切る。** 数千件の出来事が同じ綴りの誤りを持っても、
    /// 応答の `warnings` を同じ数の行で埋めない。残りは件数だけ言う。
    var unknownKeyWarnings: [String] {
        var warnings: [String] = []
        if let top = UnknownKeys.warning(unknown: unknownKeys, in: "request", known: Self.readKeys) {
            warnings.append(top)
        }
        let spelled = events.enumerated().filter { !$0.element.unknownKeys.isEmpty }
        for (index, entry) in spelled.prefix(Self.namedEventLimit) {
            if let line = UnknownKeys.warning(unknown: entry.unknownKeys, in: "event", known: entry.readKeys) {
                warnings.append("events[\(index)]: \(line)")
            }
        }
        let rest = spelled.count - Self.namedEventLimit
        if rest > 0 {
            warnings.append("\(rest) more events also carried keys that were not read")
        }
        return warnings
    }

    /// 名乗る出来事の数の上限。
    static let namedEventLimit = 5
}

/// 送られた入力に対する応答。
///
/// **何件が届いて、何件が捨てられたかを返す。** 「送ったのに効かない」の切り分けの入口で、
/// 知らない種別を送っていたのか、溜めきれずに捨てられたのかが分かる。
///
/// **これだけでは済まないことがある** ([#2731](https://github.com/mokume-metal/mokume/issues/2731))。
/// `accepted` に数えた移動・スクロールでも、当てるとき (フレームの頭) の状態で位置・差・和が
/// 有限でなくなるなら、``InputState`` が捨てる。応答の時点ではまだ分からないので数には載らず、
/// 知らせは標準エラーの警告に 1 度だけ出る。
struct InputReport: Encodable, Equatable {
    /// この形式の版。**先頭の格納プロパティである** — 合成の `encode` は宣言順に
    /// 書き出すので、置き場所が鍵の並びを決める。
    let schemaVersion = 1

    let id: String
    /// 受け取った数。
    let accepted: Int
    /// 知らない種別・解けなかったもの。
    let ignored: Int
    /// 溜めきれずに捨てた数 (このスケッチが起動してからの累計)。
    let dropped: Int
    /// 読まなかった鍵の名乗り ([#2843](https://github.com/mokume-metal/mokume/issues/2843))。
    /// **無ければ鍵ごと書かない** — 知らない鍵の無い応答は、足す前のバイトのままである。
    let warnings: [String]?

    init(id: String, accepted: Int, ignored: Int, dropped: Int, warnings: [String] = []) {
        self.id = id
        self.accepted = accepted
        self.ignored = ignored
        self.dropped = dropped
        self.warnings = warnings.isEmpty ? nil : warnings
    }
}

/// 外から送られた入力を受け取る区画 (`.mokume/input`)。
///
/// **標準入力を使わない。** 標準入力は走らせている親が握る資源なので、見張っている
/// 道具に相乗りしている窓口からは使えなくなる — 「観測はできるのに入力だけ届かない」
/// という非対称は、通り道を 1 つに揃えなかったことの帰結でしかない。
/// 観測と同じ区画の流儀に乗せれば、その非対称は最初から生まれない ([ADR-0018] 決定 1)。
///
/// [ADR-0018]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0018-observation-and-control-surface.md
@MainActor
final class InputInbox {
    let directory: URL
    private let requests: RequestFile<InputRequest>
    private let reportURL: URL

    /// 区画があるときだけ働く (観測と同じ。区画の名前は ``StartupReads`` が正典)。
    static func makeIfEnabled(
        at directory: URL = WorkDirectory.facet(StartupReads.input.key)
    ) -> InputInbox? {
        guard WorkDirectory.directoryExists(at: directory) else { return nil }
        return InputInbox(directory: directory)
    }

    init(directory: URL) {
        self.directory = directory
        self.requests = RequestFile(facet: directory, handover: .rereadsReport)
        self.reportURL = requests.reportURL
    }

    /// 要求が来ていれば流し込み、応答を書く。
    @discardableResult
    func drain(into state: InputState) -> InputReport? {
        guard let pending = requests.pending() else { return nil }
        // 応えようとしたことは、応答を書けたかどうかによらず記録する (観測と同じ)
        defer { requests.markHandled(pending.id) }
        let request: InputRequest
        switch pending {
        case .request(let read):
            request = read
        case .unreadable(let id, _):
            // **`events` が読めない要求にも応える** (#2550)。解けなかった 1 件だけを持つ要求として
            // 流すので、`accepted == 0`・`ignored == 1` が返り、何も流れ込まない。最上位の知らない鍵
            // (`evnts`) は、解けなかった要求だからこそ名乗る (#2843)
            request = InputRequest(
                id: id, events: [.unreadable],
                unknownKeys: InputRequest.unknownKeys(inFile: try? Data(contentsOf: requests.url)))
        }
        var accepted = 0
        var ignored = 0
        for entry in request.events {
            // **知らない種別も解けなかったものも捨てるが、その 1 件だけ。** 残りは通す
            guard let event = entry.event else {
                ignored += 1
                continue
            }
            state.enqueue(event)
            accepted += 1
        }
        let report = InputReport(
            id: request.id, accepted: accepted, ignored: ignored, dropped: state.droppedEvents,
            warnings: request.unknownKeyWarnings)
        write(report)
        return report
    }

    private func write(_ report: InputReport) {
        AtomicFile.publishJSON(report, to: reportURL, "the input reply")
    }
}
