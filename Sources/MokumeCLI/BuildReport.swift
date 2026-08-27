// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation

/// 直近の作り直しの結果。
///
/// 観測 ([ADR-0018]) と同じ流儀で `.mokume/build/` に書く — 別の置き場も別の形も
/// 作らず、区画をもう 1 つ足すだけにする。窓口はこれを読むだけでよくなる。
///
/// [ADR-0018]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0018-observation-and-control-surface.md
struct BuildReport: Encodable, Equatable {
    static let schemaVersion = 1

    /// 分解した所要時間 (ミリ秒)。
    struct Timings: Encodable, Equatable {
        /// 保存から気付くまで。最初の作り直しでは省く。
        var detectMs: Double?
        /// 作り直しにかかった時間。
        var buildMs: Double
        /// 差し替え (古いものを終えて新しいものが立ち上がるまで)。失敗したときは省く。
        var relaunchMs: Double?
    }

    /// 作り直せたか。
    let ok: Bool
    /// 作り直しの終了コード。
    let status: Int32
    /// 出力 (失敗の内容を含む)。**成否によらず載せる** — 警告は成功しても読みたい。
    let output: String
    /// この作り直しが対象にしたソースの世代。
    let stamp: String?
    /// どの構成で作ったか。数字がどの土俵のものか分からないと比べられない。
    let configuration: String
    /// 分解した所要時間。
    let timings: Timings

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, ok, status, output, stamp, configuration, timings
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(Self.schemaVersion, forKey: .schemaVersion)
        try container.encode(ok, forKey: .ok)
        try container.encode(status, forKey: .status)
        try container.encode(output, forKey: .output)
        try container.encodeIfPresent(stamp, forKey: .stamp)
        try container.encode(configuration, forKey: .configuration)
        try container.encode(timings, forKey: .timings)
    }

    /// 1 行の要約。端末に出す形で、測定の道具もこれを読める。
    var summary: String {
        var parts = ["build_ms=\(round(timings.buildMs))"]
        if let detect = timings.detectMs { parts.insert("detect_ms=\(round(detect))", at: 0) }
        if let relaunch = timings.relaunchMs { parts.append("relaunch_ms=\(round(relaunch))") }
        parts.append("configuration=\(configuration)")
        if let stamp { parts.append("stamp=\(stamp)") }
        return (ok ? "作り直した: " : "作り直しに失敗: ") + parts.joined(separator: " ")
    }

    private func round(_ value: Double) -> String {
        String(format: "%.1f", value)
    }
}
