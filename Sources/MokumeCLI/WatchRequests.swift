// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation
import mokume

/// 見張りに置かれる要求 (区画 `watch`・[#3565](https://github.com/mokume-metal/mokume/issues/3565))。
///
/// 区画の要求に**見張り自身が**答える初めての形である。ほかの区画 (観測・入力・つまみ) は走らせている子が答える。
/// 作法は同じで、`id` を echo する応答を書き、同じ `id` は二度処理しない (``RequestFile``)。
///
/// `action` は文字列のまま持つ。**知らない値も読めた要求として受け、``WatchReport/Reason/unknownAction``
/// で断る** — 型で弾くと、`id` だけ読めた要求と区別が付かず、理由が `unreadable` に潰れる。
struct WatchRequest: ExchangeRequest, Equatable {
    let id: String
    let action: String

    /// この段で受ける動作。`send` は後の段 (#3566) が足す。
    enum Action: String {
        case audition
        case leave
    }

    var known: Action? { Action(rawValue: action) }
}

/// 見張りの応答 (区画 `watch` の `report.json`)。
///
/// 受けたか・断った理由と、いまの本番と試聴の子の番号と刻印を名乗る。**断った応答にも、いまの役を載せる** —
/// 書き手は断られた理由と、いま何が起きているかを同じ 1 枚で読める。
struct WatchReport: Encodable, Equatable {
    /// この形式の版。**先頭の格納プロパティである** (``InputReport`` と同じ)。
    let schemaVersion = 1

    let id: String
    /// 要求が名乗った動作。読めなかった要求では省く。
    let action: String?
    /// 受けたか。
    let accepted: Bool
    /// 断った理由。受けたときは省く。
    let reason: Reason?
    /// 解けなかった理由の 1 行 (`reason` が `unreadable` のときだけ)。
    let detail: String?
    /// 試聴に入っているか。
    let auditioning: Bool
    /// 本番の世代 (作品の窓が映す版)。居なければ省く。
    let production: Generation?
    /// 試聴の世代 (プレビューが映す版)。居なければ省く。
    let audition: Generation?

    /// 断った理由。**綴りは `Schemas/watch-report.schema.json` の `enum` と揃える。**
    enum Reason: String, Encodable, CaseIterable {
        /// 試聴に入っていないのに出る要求だった。
        case notAuditioning
        /// 既に試聴に入っている。
        case alreadyAuditioning
        /// プレビューが無い (窓を出せなかった見張り)。試聴の相手が居ない。
        case noPreview
        /// 走っている本番が無い。試聴は本番を守るためのもので、守る相手が居ない。
        case noProduction
        /// 作品の窓が映している本番の子が、目録で自分の番号を名乗らない (古いライブラリ)。試聴の版と本番を、番号で
        /// 区別して別の窓に出し分けられない。入ると、試聴の版が作品の窓にも出て、窓の入力は本番へ届く。
        case unidentifiedGeneration
        /// 知らない動作。
        case unknownAction
        /// 要求の形として解けなかった (`id` だけ読めた)。
        case unreadable
    }

    /// 世代の名乗り。
    struct Generation: Encodable, Equatable {
        /// 子の番号。
        let pid: Int32
        /// その子を起こしたときの、ソースの世代の刻印。無ければ省く。
        let stamp: String?
    }
}
