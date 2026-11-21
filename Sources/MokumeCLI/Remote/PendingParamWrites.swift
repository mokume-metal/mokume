// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation
import mokume

/// スマホから届いたつまみの書き込みを、つまみの面の要求 (`.mokume/params/request.json`) に束ねる。
///
/// **面の要求は 1 枚のファイルで、子はフレームの頭に最新の 1 枚だけを読む。** 書き込みを 1 件ずつ
/// 要求にすると、子が読む前に次の要求が前の要求を置き換え、別のつまみへの書き込みが消える
/// (`size` を動かした直後に `trails` を切り替えると、`size` が届かない)。そこで、子の応答が
/// echo して確かめるまでの書き込みを名前ごとに持ち、要求を置くたびに**まだ確かめていない全部**を
/// 載せる。
///
/// 応答の echo の読み方は窓のつまみ (`RemoteParams`) と同じ向きにする:
///
/// - 最後に置いた要求 → 載せた値は届いた
/// - 前に置いた自分の要求 → 載せた値のうち、いまも同じものは届いた
/// - 要求を置く前からあった識別子 → まだ (置く前の姿)
/// - **それ以外** → 自分の要求の後に別の書き手 (窓・外の道具) が書いた。後勝ち (ADR-0030 決定 2) で
///   その書き手の値に任せ、まだ確かめていない書き込みは捨てる
nonisolated struct PendingParamWrites {
    /// まだ確かめていない、名前ごとの最新の値。届いた順に並べる。
    private(set) var pending: [NamedParamValue] = []
    /// 前の要求の後に新しい書き込みが来た。次の拍で要求を置く。
    private(set) var needsWrite = false
    /// 置いた要求ごとに載せた値。古い順。
    private var sent: [(id: String, values: [NamedParamValue])] = []
    /// 待つ間に要求を置くたび、置く直前に応答が echo していた識別子。
    private var echoesBeforeWriting: Set<String?> = []

    /// まだ確かめていない書き込みがあるか。
    var isSettled: Bool { pending.isEmpty && sent.isEmpty }

    /// 書き込みを 1 件受ける。同じ名前の前の値は置き換える。
    mutating func record(_ write: NamedParamValue) {
        pending.removeAll { $0.name == write.name }
        pending.append(write)
        needsWrite = true
    }

    /// 置くべき要求があれば、その識別子と値を返し、置いたものとして控える。
    ///
    /// - Parameters:
    ///   - echoNow: 置く直前に応答が echo している識別子。
    ///   - id: 新しい要求の識別子。
    mutating func nextRequest(echoNow: String?, id: String) -> [NamedParamValue]? {
        guard needsWrite, !pending.isEmpty else { return nil }
        echoesBeforeWriting.insert(echoNow)
        sent.append((id, pending))
        needsWrite = false
        return pending
    }

    /// 応答を読んだ。`echo` はその応答が echo した識別子。
    mutating func observe(echo: String?) {
        guard !sent.isEmpty else { return }
        if let echo, let index = sent.firstIndex(where: { $0.id == echo }) {
            // 自分の要求が届いた。載せた値のうち、その後に動いていないものを確かめ済みにする
            let arrived = sent[index].values
            pending.removeAll { write in arrived.contains(write) }
            sent.removeFirst(index + 1)
            if sent.isEmpty { echoesBeforeWriting.removeAll() }
            return
        }
        if echoesBeforeWriting.contains(echo) { return }
        // 別の書き手の要求への応答。後勝ちで、こちらの書き込みは諦める
        pending.removeAll()
        sent.removeAll()
        echoesBeforeWriting.removeAll()
        needsWrite = false
    }
}

/// スマホのページが送る書き込み 1 件 (`{"name", "type", "value"}`) を読む。
///
/// 色だけはページの欄の `#rrggbb` で届くので、いまの不透明度を保って作業空間の色にする。
/// それ以外は面の要求と同じ読み方 (`NamedParamValue`) にそのまま通す — 型の名乗りと値の
/// 形を知っているのはあちらだけにする。
nonisolated enum RemoteWrite {
    static func parse(_ body: Data, knobs: [RemoteKnobs.Knob]) -> NamedParamValue? {
        guard let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
            let name = object["name"] as? String, let type = object["type"] as? String
        else { return nil }
        if type == "color", let hex = object["value"] as? String {
            var alpha: Float = 1
            if let knob = knobs.first(where: { $0.name == name }), case .color(_, let current) = knob.value {
                alpha = Float(current)
            }
            guard let color = RemoteColor.color(hex: hex, alpha: alpha) else { return nil }
            return NamedParamValue(name: name, value: .color(color))
        }
        guard let data = try? JSONSerialization.data(withJSONObject: object) else { return nil }
        return try? JSONDecoder().decode(NamedParamValue.self, from: data)
    }
}
